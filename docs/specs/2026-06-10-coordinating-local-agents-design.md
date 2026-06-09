# Coordinating Local Agents Design

## Overview

Add a new Codex-facing skill plus a thin local shell wrapper so Codex can delegate bounded work to local Claude Code and OpenCode workers while retaining control of planning, validation, integration, and merge decisions.

This design is intentionally narrow. Version 1 solves one problem: Codex should be able to hand off implementation, investigation, or validation tasks to a local worker in an isolated workspace, collect a structured result, inspect the resulting diff, and decide what to integrate.

## Goals

- Give Codex a reusable skill for when local delegation is appropriate
- Standardize delegation through one wrapper instead of provider-specific shell snippets
- Isolate worker changes from the coordinator by default with git worktrees
- Require structured worker output so Codex can review results predictably
- Keep merge and integration authority with Codex only

## Non-Goals

- No automatic merge or cherry-pick behavior
- No automatic worker routing in v1
- No distributed or multi-host orchestration
- No scheduler, queue manager, or long-running daemon
- No requirement to use MCP, plugins, or a network protocol in v1

## Core Decisions

### Coordinator Model

Codex is the coordinator. It owns:

- task decomposition
- worker selection
- acceptance criteria
- validation of worker output
- integration and merge decisions

Claude Code and OpenCode act as bounded workers. They do not own final integration.

### Invocation Model

The first implementation uses a shell wrapper, not MCP or plugin APIs. The wrapper hides provider-specific command differences behind one command surface.

### Isolation Model

The overall design supports both `inplace` and `worktree` execution modes. The default is `worktree`.

This gives Codex two safe defaults:

- use `worktree` for implementation and risky edits
- use `inplace` only when isolation cost is not justified

Mode semantics must be explicit:

- `worktree`: the wrapper creates a dedicated git worktree for the worker and treats that worktree as the worker's only writable workspace
- `inplace`: the worker operates directly in the caller-provided `--repo` path without creating a worktree

`inplace` is an explicit exception mode. It is intended for cases where Codex deliberately accepts direct edits in the target checkout or where the target checkout is already a secondary workspace. Planning should treat it as less safe than `worktree`.

Implementation scope is narrower than the long-term design:

- v1 required implementation: `worktree`
- follow-up implementation: `inplace`

### Worker Output Model

Workers return:

- file changes in their own workspace
- a structured report file
- command logs and diff metadata

The report is mandatory even when work fails or is only partially complete.

### Authority Boundary

Only Codex may integrate results back into the main working branch. Workers may change files in their assigned workspace, but they may not merge or cherry-pick.

Default policy:

- in `worktree` mode, workers must not modify the coordinator's primary worktree
- in `inplace` mode, Codex explicitly authorizes the worker to edit the target checkout directly once that follow-up mode exists

The distinction is important: integration authority stays with Codex in both modes, but workspace isolation only exists in `worktree` mode.

## Architecture

The system has three layers.

### 1. Skill Layer

Create a new skill such as `coordinating-local-agents`.

This skill teaches Codex:

- when delegation is appropriate
- when to avoid delegation
- what task contract to provide
- how to invoke the wrapper
- how to validate and collect worker results

The skill is process guidance only. It does not embed provider-specific shell details beyond the wrapper interface.

### 2. Wrapper Layer

Provide a thin CLI wrapper, tentatively named `agent-orch`.

Responsibilities:

- normalize the command interface for Codex
- create and track task directories
- provision worktrees when requested
- invoke the selected provider script
- persist status, logs, metadata, and reports

Non-responsibilities:

- no routing policy
- no automatic approval of worker results
- no automatic merge behavior

### 3. Provider Layer

Provider-specific scripts sit behind the wrapper:

- `providers/claude.sh`
- `providers/opencode.sh`

Responsibilities:

- map the normalized task contract to each provider's CLI
- support one-shot execution
- support resumable session execution where possible
- return output in a way the wrapper can capture consistently

## CLI Surface

The full wrapper namespace may eventually expose this command set:

```bash
agent-orch run
agent-orch session start
agent-orch session send
agent-orch status
agent-orch collect
agent-orch cleanup
```

Version 1 required scope is narrower:

- `agent-orch run`
- `agent-orch status`
- `agent-orch collect`
- `agent-orch cleanup`

`session start` and `session send` are planned follow-up commands, not part of the first required deliverable.

### `agent-orch run`

Default mode for v1. Executes a one-shot task.

Expected inputs:

- `--worker claude|opencode`
- `--repo <path>`
- `--mode <mode>` optional, default `worktree`
- exactly one of `--task-file <path>` or `--prompt <text>`
- `--acceptance-file <path>` required
- `--output-dir <path>` optional

Version 1 supports only `--mode worktree`.

If `--mode inplace` is provided in v1, the wrapper must fail fast before launching a worker and return an `unsupported_mode` error.

Expected behavior:

1. create a task id
2. create a task state directory
3. create a worktree when `--mode worktree`
4. invoke the selected provider
5. wait for completion
6. persist status, logs, metadata, and report paths

### `agent-orch session start`

Planned follow-up command. Starts a worker session and returns a session identifier for follow-up interaction.

### `agent-orch session send`

Planned follow-up command. Sends follow-up instructions to an existing worker session. This exists for multi-turn correction or clarification, but it is not part of the primary v1 workflow.

### `agent-orch status`

Returns task status such as:

- `queued`
- `running`
- `completed`
- `partial`
- `failed`

Version 1 input contract:

- `--task-id <id>` required
- exactly one of:
  - `--repo <path>` to locate the default task store for that repository
  - `--task-dir <path>` to point directly at a task state root

It should return machine-readable JSON. Minimum fields:

- worker type
- repo path
- worktree path if present
- report path
- log paths
- mode
- task id

Session-aware status is follow-up-only, not part of the v1 contract.

### `agent-orch collect`

Collects the artifacts needed for Codex review without integrating anything.

Version 1 input contract:

- `--task-id <id>` required
- exactly one of:
  - `--repo <path>` to locate the default task store for that repository
  - `--task-dir <path>` to point directly at a task state root

It should return machine-readable JSON and persist artifacts on disk. Minimum fields:

- changed files
- diff summary
- report path
- declared test results from the worker
- task state directory
- worktree path when applicable

`collect` must work even when the provider crashed, timed out, was killed by signal, or failed to emit a valid worker-authored report. In those cases it should still expose the wrapper-generated failed report described below.

### `agent-orch cleanup`

Deletes temporary task artifacts and optionally removes the worktree. Cleanup should be explicit, not automatic, so Codex can inspect failures after the fact.

Version 1 input contract:

- `--task-id <id>` required
- exactly one of:
  - `--repo <path>` to locate the default task store for that repository
  - `--task-dir <path>` to point directly at a task state root
- exactly one removal target:
  - `--remove-worktree`
  - `--remove-state`
  - `--all`

## Task State Model

Each task should have a dedicated state directory. A reasonable default is:

```text
<repo>/.superpowers/agent-orch/tasks/<task-id>/
```

Here `<repo>` means the original coordinator-provided repository root passed to `--repo`, never the generated worker worktree path. Task state must survive worker worktree cleanup.

If `--output-dir` is provided, it overrides the default repo-local task root. If omitted, repo-local storage is the default.

Version 1 task directories should include:

- `task.json` - normalized task definition
- `status.json` - current state
- `metadata.json` - repo, base revision, worker, session ids
- `report.json` - worker report
- `stdout.log`
- `stderr.log`
- `git.diffstat`
- `provider-result.json` - wrapper-owned diagnostic artifact containing exit code, signal, timing, and wrapper-observed termination metadata

If the wrapper receives an invalid report from the worker, it should also preserve the raw payload when available in a diagnostic artifact such as `report.raw`.

For `worktree` mode also record:

- `repo_path`
- `worktree_path`
- `branch_name`
- `base_rev`

This layout gives Codex a stable place to inspect progress and recover from partial failures.

## Worker Task Contract

The wrapper should hand each provider a normalized task contract. At minimum it must contain:

- worker role
- scope of the task
- workspace path
- task statement
- constraints
- acceptance criteria
- required report format
- finalization instructions

The worker prompt should enforce these rules:

1. Only modify files inside the assigned workspace.
2. Do not merge or cherry-pick.
3. In v1 `worktree` mode, do not alter the coordinator's main worktree.
4. Keep changes scoped to the assigned task.
5. Always emit a structured report, even on failure.

Failure finalization has two layers:

- worker-controlled failure: the worker should still write a valid `report.json` with `status: failed`
- wrapper-controlled failure: if the worker crashes, times out, exits on signal, produces no report, or produces an invalid report, the wrapper must synthesize a valid failed `report.json`

## Worker Report Schema

Version 1 should standardize on JSON for machine-readable collection.

Minimum schema:

```json
{
  "status": "completed",
  "summary": "Implemented X and adjusted Y.",
  "files_changed": [
    "src/foo.ts",
    "tests/foo.test.ts"
  ],
  "tests_run": [
    {
      "command": "npm test -- foo.test.ts",
      "result": "passed"
    }
  ],
  "open_questions": [],
  "risks": [],
  "notes": []
}
```

Field meanings:

- `status`: `completed | partial | failed`
- `summary`: short human-readable summary
- `files_changed`: relative file paths modified by the worker
- `tests_run`: commands the worker ran and their results
- `open_questions`: unresolved decisions for Codex
- `risks`: known weaknesses, missing coverage, or concerns
- `notes`: optional extra context

Failure still requires a valid report with `status: failed`.

If the wrapper synthesizes the failure report, it should preserve as much diagnostic context as possible in the report and adjacent artifacts, including:

- exit code
- terminating signal if any
- timeout status if applicable
- paths to `stdout.log` and `stderr.log`
- path to raw invalid report content when present

## Skill Behavior

The new skill should trigger when Codex is expected to delegate implementation, investigation, or validation work to local Claude Code or OpenCode workers while retaining integration control.

It should guide Codex to:

1. keep small tasks local when delegation overhead is not justified
2. default to `worktree` mode
3. default to `run` over `session`
4. explicitly choose a worker in v1
5. define acceptance criteria before dispatch
6. validate reports and diffs before accepting results
7. treat `inplace` as follow-up functionality, not part of the first required implementation

The skill should explicitly discourage delegation when:

- the task is tiny and faster to do directly
- the work is tightly coupled to the coordinator's immediate next edit
- multiple workers would inevitably edit the same files

## Validation and Collection Flow

After a worker completes, Codex should follow this order:

1. read `report.json`
2. inspect `files_changed`
3. inspect the git diff or diff summary
4. run candidate validation against the changed code in the worker workspace
5. decide whether to integrate, revise, or discard the result
6. if Codex integrates the result, run integration validation again in the coordinator workspace

Worker completion is advisory, not authoritative. Codex must verify before integrating.

Validation location depends on execution mode:

- `worktree`: validate in the worker worktree before integration, then re-validate after integration
- `inplace`: validate directly in the target checkout because the candidate changes already live there

In version 1, only the `worktree` branch of this behavior is required. `inplace` validation semantics remain follow-up work.

## Suggested File Layout

Skill:

```text
~/.agents/skills/coordinating-local-agents/
  SKILL.md
  references/
    task-contract.md
    report-schema.md
    routing-guidelines.md
```

Wrapper:

```text
~/.codex/tools/agent-orch/
  agent-orch
  providers/
    claude.sh
    opencode.sh
  lib/
    worktree.sh
    task-store.sh
    report.sh
```

The exact paths can change during implementation, but the separation of responsibilities should remain.

## Risks

- Provider CLIs may differ substantially in session semantics
- Structured report generation may need provider-specific prompt tuning
- Worktree cleanup can become messy without explicit lifecycle rules
- Delegation overhead may outweigh benefits for small tasks

## Open Questions Deferred to Planning

- Exact command-line flags and output parsing for `claude` and `opencode`
- Whether report schema validation lives in shell, `jq`, or a small helper script
- Whether task state should live under repo-local storage or a global cache with repo references
- How much session support is realistically implementable after the v1 one-shot flow is stable

## Implementation Shape

This design is intentionally staged.

Recommended order:

1. create the skill and wrapper contract
2. implement one-shot `run` with `worktree` mode
3. add structured report capture and `collect`
4. add `status` and `cleanup`
5. optionally add minimal session support as follow-up work
6. optionally add `inplace` mode as follow-up work
7. revisit optional routing rules only after explicit dispatch is stable
