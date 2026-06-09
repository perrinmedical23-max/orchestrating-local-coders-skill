# Orchestrating Local Coders Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v1 skill and shell wrapper for Codex-led local delegation, with worktree-first execution, task-state persistence, structured reports, and crash-safe collection.

**Architecture:** Keep the runtime surface narrow: one Bash entrypoint (`bin/agent-orch`) orchestrates worktree setup, provider dispatch, task-state storage, and JSON result collection. Use small Bash libraries for git/task-store concerns plus tiny Python helpers for timeout-aware provider launching and report validation/synthesis so the shell stays thin and predictable. Version 1 stops at the wrapper core, deterministic fixture providers, and the Codex-facing skill install path. Real `claude` and `opencode` adapters are follow-up work.

**Tech Stack:** Bash, Git CLI, Python 3 standard library (`json`, `pathlib`, `sys`), Markdown

**Spec:** `docs/specs/2026-06-10-coordinating-local-agents-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `bin/agent-orch` | Create | Main CLI entrypoint for `run`, `status`, `collect`, `cleanup` |
| `lib/agent-orch/common.sh` | Create | Shared shell helpers: arg parsing primitives, JSON-safe error output, logging |
| `lib/agent-orch/task-store.sh` | Create | Task-id lookup, repo/task-dir resolution, task-state path creation |
| `lib/agent-orch/worktree.sh` | Create | Worktree creation, branch naming, teardown |
| `lib/agent-orch/provider.sh` | Create | Provider resolution and dispatch wrapper |
| `lib/agent-orch/launch.py` | Create | Run provider commands with timeout, exit-code, and signal capture |
| `lib/agent-orch/report.py` | Create | Validate worker reports and synthesize failed `report.json` |
| `skills/coordinating-local-agents/SKILL.md` | Create | Codex-facing workflow skill |
| `skills/coordinating-local-agents/references/task-contract.md` | Create | Worker prompt contract and required fields |
| `skills/coordinating-local-agents/references/report-schema.md` | Create | `report.json` schema and failure semantics |
| `skills/coordinating-local-agents/references/routing-guidelines.md` | Create | Explicit-dispatch guidance and future routing notes |
| `tests/test-helpers.sh` | Create | Shared shell assertions and temp-dir setup |
| `tests/fixtures/providers/fake-success.sh` | Create | Fixture provider that emits a valid success report |
| `tests/fixtures/providers/fake-missing-report.sh` | Create | Fixture provider that exits without writing a report |
| `tests/fixtures/providers/fake-invalid-report.sh` | Create | Fixture provider that writes malformed JSON |
| `tests/fixtures/providers/fake-signal.sh` | Create | Fixture provider that terminates by signal |
| `tests/agent-orch/run-worktree.sh` | Create | Integration test for `run` task-state + worktree flow |
| `tests/agent-orch/status.sh` | Create | Integration test for `status` lookup by `--task-id` |
| `tests/agent-orch/collect-success.sh` | Create | Integration test for success-path `collect` output |
| `tests/agent-orch/collect-failure.sh` | Create | Integration test for synthetic failure report collection |
| `tests/agent-orch/cleanup.sh` | Create | Integration test for `cleanup` removal-target behavior |
| `tests/agent-orch/skill-docs.sh` | Create | Validation script for skill frontmatter and v1 contract wording |
| `tests/agent-orch/provider-boundary.sh` | Create | Validation script for the fixture provider adapter boundary |
| `tests/agent-orch/run-all.sh` | Create | One-shot local test runner |
| `scripts/install-skill.sh` | Create | Install repo-local skill into `~/.agents/skills/` via symlink |
| `README.md` | Modify | Repository usage, test commands, install notes |

---

## Chunk 1: Runtime Foundation

### Task 1: Create the test harness and repository runtime layout

**Files:**
- Create: `bin/agent-orch`
- Create: `lib/agent-orch/common.sh`
- Create: `tests/test-helpers.sh`
- Create: `tests/agent-orch/run-all.sh`

- [ ] **Step 1: Create the shell library directories and executable entrypoint stub**

Create:

```bash
mkdir -p bin lib/agent-orch tests/agent-orch tests/fixtures/providers
touch bin/agent-orch lib/agent-orch/common.sh tests/test-helpers.sh tests/agent-orch/run-all.sh
chmod +x bin/agent-orch tests/agent-orch/run-all.sh
```

- [ ] **Step 2: Add a minimal `bin/agent-orch` command dispatcher that fails for unknown subcommands**

Start with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/lib/agent-orch/common.sh"

command_name="${1:-}"
shift || true

case "${command_name}" in
  run|status|collect|cleanup)
    die "not_implemented" "subcommand ${command_name} is not implemented yet"
    ;;
  *)
    die "unknown_command" "expected one of: run, status, collect, cleanup"
    ;;
esac
```

- [ ] **Step 3: Add common helpers for fatal JSON errors and temporary test directories**

In `lib/agent-orch/common.sh`, add:

```bash
die() {
  local code="$1"
  local message="$2"
  printf '{"status":"failed","error":"%s","message":"%s"}\n' "$code" "$message" >&2
  exit 1
}
```

In `tests/test-helpers.sh`, add helpers for `mktemp -d`, `assert_file_exists`, `assert_contains`, and `assert_json_value` using `python3`.

- [ ] **Step 4: Create `tests/agent-orch/run-all.sh` as the wrapper-core suite**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "${ROOT_DIR}/tests/agent-orch/run-worktree.sh"
bash "${ROOT_DIR}/tests/agent-orch/status.sh"
bash "${ROOT_DIR}/tests/agent-orch/collect-success.sh"
bash "${ROOT_DIR}/tests/agent-orch/collect-failure.sh"
bash "${ROOT_DIR}/tests/agent-orch/cleanup.sh"
```

- [ ] **Step 5: Run the empty harness to confirm it fails for missing wrapper-core tests**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/run-all.sh`
Expected: FAIL because the test files do not exist yet.

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/common.sh tests/test-helpers.sh tests/agent-orch/run-all.sh
git commit -m "Scaffold agent-orch runtime and test harness"
```

---

### Task 2: Implement `run` with v1 worktree-only semantics

**Files:**
- Modify: `bin/agent-orch`
- Create: `lib/agent-orch/task-store.sh`
- Create: `lib/agent-orch/worktree.sh`
- Create: `lib/agent-orch/provider.sh`
- Create: `tests/fixtures/providers/fake-success.sh`
- Create: `tests/agent-orch/run-worktree.sh`

- [ ] **Step 1: Write the failing integration test for `run`**

Create `tests/agent-orch/run-worktree.sh` to:

1. create a temp git repo
2. write a dummy task file and acceptance file
3. point provider resolution at `tests/fixtures/providers`
4. run `bin/agent-orch run --worker fake-success --repo <temp-repo> --mode worktree ...`
5. assert a task-state directory exists under `<repo>/.superpowers/agent-orch/tasks/<task-id>/`
6. assert `task.json`, `metadata.json`, `status.json`, `report.json`, `provider-result.json`, `stdout.log`, `stderr.log`, and `git.diffstat` exist
7. assert `task.json` contains embedded task statement text and embedded acceptance criteria text, not only file paths
8. assert `status.json` ends as `completed`

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/run-worktree.sh`
Expected: FAIL because `run` is not implemented.

- [ ] **Step 3: Implement v1 `run` argument parsing and fail-fast mode handling**

In `bin/agent-orch`, require:

- `--worker`
- `--repo`
- exactly one of `--task-file` or `--prompt`
- `--acceptance-file`
- optional `--output-dir` override for the task-state root

Mode behavior:

```bash
mode="worktree"
if [[ "${requested_mode}" == "inplace" ]]; then
  die "unsupported_mode" "version 1 supports only --mode worktree"
fi
```

- [ ] **Step 4: Implement task-store and worktree helpers**

In `lib/agent-orch/task-store.sh`, add functions to:

- generate task ids
- resolve repo root
- choose the task-state root:
  - default: `<repo>/.superpowers/agent-orch/tasks/`
  - override: `<output-dir>/`
- create `<task-root>/<task-id>/`

In `lib/agent-orch/worktree.sh`, add functions to:

- create a deterministic branch name such as `agent-orch/<task-id>`
- create a sibling worktree directory
- write `repo_path`, `worktree_path`, `branch_name`, `base_rev` into `metadata.json`

- [ ] **Step 5: Persist the normalized task contract**

Write `task.json` before provider dispatch. It should include at least:

```json
{
  "task_id": "20260610-abc123",
  "worker": "fake-success",
  "mode": "worktree",
  "repo_path": "/tmp/tmp.repo",
  "workspace_path": "/tmp/tmp.repo.worktrees/agent-orch-20260610-abc123",
  "task_statement": "Implement the requested behavior...",
  "acceptance_criteria": "Return a valid report and keep edits inside the worktree...",
  "task_source": {
    "task_file": "/tmp/task.md",
    "prompt": null,
    "acceptance_file": "/tmp/acceptance.md"
  },
  "constraints": {
    "allow_merge": false,
    "allow_cherry_pick": false,
    "v1_worktree_only": true
  },
  "report_requirements": {
    "path": "report.json",
    "format": "json"
  },
  "finalization": {
    "must_write_report": true
  }
}
```

If `--prompt` is used instead of `--task-file`, persist the prompt text in `task_statement` and record `task_source.prompt`.

- [ ] **Step 6: Implement provider dispatch with a fixture provider**

Use `AGENT_ORCH_PROVIDER_DIR` as a test-only override for provider lookup so tests can call `fake-success.sh`.

`tests/fixtures/providers/fake-success.sh` should:

```bash
#!/usr/bin/env bash
set -euo pipefail

task_dir="$1"
cat > "${task_dir}/report.json" <<'JSON'
{"status":"completed","summary":"fixture success","files_changed":[],"tests_run":[],"open_questions":[],"risks":[],"notes":[]}
JSON
exit 0
```

The fixture provider should receive the task directory and the normalized `task.json` path, not loose task arguments.

`run` should print machine-readable JSON to stdout so later commands can consume the task id without guessing directory names, for example:

```json
{"task_id":"20260610-abc123","status":"completed","task_dir":"/tmp/repo/.superpowers/agent-orch/tasks/20260610-abc123","report_path":"/tmp/repo/.superpowers/agent-orch/tasks/20260610-abc123/report.json"}
```

Failure-path contract for `run`:

- create task state before provider launch
- once provider execution begins, always print machine-readable JSON with at least `task_id`, `status`, `task_dir`, and `report_path`
- exit non-zero only for wrapper/preflight/orchestration failures before a usable task record exists
- exit zero when the wrapper successfully records task state, even if the worker result status is `failed`

- [ ] **Step 7: Generate diff artifacts during `run`**

After provider completion, generate diff artifacts against the worktree filesystem relative to `base_rev`, not against `HEAD` commits:

- `git.diffstat` using `git diff --stat "${base_rev}" --`
- `diff_summary` content derived from the same diff for later `collect` output

These artifacts should exist for both success and failure paths.

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/run-worktree.sh`
Expected: PASS. `run` creates task state, writes metadata, launches the fixture provider, and persists a completed report.

- [ ] **Step 9: Add negative assertions for unsupported mode and prompt path**

Extend `tests/agent-orch/run-worktree.sh` to run:

```bash
bin/agent-orch run --worker fake-success --repo "${TMP_REPO}" --mode inplace --task-file "${TASK_FILE}" --acceptance-file "${ACCEPTANCE_FILE}"
```

Expected: non-zero exit and stderr JSON containing `"error":"unsupported_mode"`.

Also extend `tests/agent-orch/run-worktree.sh` to run one success case with `--prompt` instead of `--task-file`, and assert the prompt text is embedded in `task.json`.

- [ ] **Step 10: Re-run the test**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/run-worktree.sh`
Expected: PASS including the unsupported-mode check.

- [ ] **Step 11: Commit**

```bash
git add bin/agent-orch lib/agent-orch/task-store.sh lib/agent-orch/worktree.sh lib/agent-orch/provider.sh tests/fixtures/providers/fake-success.sh tests/agent-orch/run-worktree.sh
git commit -m "Implement worktree-only run flow for agent-orch"
```

---

## Chunk 2: Task Inspection and Crash-Safe Collection

### Task 3: Implement `status` lookup by `--task-id`

**Files:**
- Modify: `bin/agent-orch`
- Modify: `lib/agent-orch/task-store.sh`
- Create: `tests/agent-orch/status.sh`

- [ ] **Step 1: Write the failing test for `status`**

Create `tests/agent-orch/status.sh` to:

1. create a temp repo
2. run the fixture-backed `run` flow to produce a completed task
3. capture the task id from the `run` JSON output
4. call `bin/agent-orch status --task-id <id> --repo <temp-repo>`
5. assert JSON fields: `task_id`, `mode`, `repo_path`, `worktree_path`, `report_path`, `status`
6. call `bin/agent-orch status --task-id <id> --task-dir <exact-task-dir>`
7. assert the same task resolves correctly via `--task-dir`

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/status.sh`
Expected: FAIL because `status` is not implemented.

- [ ] **Step 3: Implement task lookup by `--task-id`**

In `lib/agent-orch/task-store.sh`, add:

- resolution by `--repo` to `<repo>/.superpowers/agent-orch/tasks/<task-id>`
- resolution by `--task-dir` to the exact task-state root for that task
- validation that callers provide exactly one locator
- documentation and tests that tasks created with `--output-dir` are later addressed via `--task-dir`

- [ ] **Step 4: Implement `status` JSON output**

Return a single JSON object assembled from `status.json`, `metadata.json`, and `report.json` path references, for example:

```json
{
  "task_id": "20260610-abc123",
  "status": "completed",
  "mode": "worktree",
  "worker": "fake-success",
  "repo_path": "/tmp/tmp.repo",
  "worktree_path": "/tmp/tmp.repo.worktrees/agent-orch-20260610-abc123",
  "report_path": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/report.json",
  "log_paths": {
    "stdout": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stdout.log",
    "stderr": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stderr.log"
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/status.sh`
Expected: PASS. `status` resolves the task from `--task-id` plus locator and returns machine-readable JSON.

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/task-store.sh tests/agent-orch/status.sh
git commit -m "Add task status lookup by task id"
```

---

### Task 4: Implement `collect`, provider timeout handling, and synthetic failed report generation

**Files:**
- Modify: `bin/agent-orch`
- Create: `lib/agent-orch/launch.py`
- Create: `lib/agent-orch/report.py`
- Create: `tests/fixtures/providers/fake-missing-report.sh`
- Create: `tests/fixtures/providers/fake-invalid-report.sh`
- Create: `tests/fixtures/providers/fake-timeout.sh`
- Create: `tests/agent-orch/collect-success.sh`
- Create: `tests/agent-orch/collect-failure.sh`

- [ ] **Step 1: Write the failing success-path `collect` test**

Create `tests/agent-orch/collect-success.sh` to:

1. run the fixture-backed success path
2. call `agent-orch collect --task-id <id> --repo <temp-repo>`
3. assert the returned JSON includes `changed_files`, `diff_summary`, `tests_run`, `report_path`, `task_dir`
4. assert the successful worker-authored `report.json` is preserved rather than synthesized

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/collect-success.sh`
Expected: FAIL because `collect` is not implemented.

- [ ] **Step 3: Write the failing test for missing-report collection**

Create `tests/agent-orch/collect-failure.sh` with four scenarios:

1. provider exits non-zero and writes no `report.json`
2. provider exits zero but writes malformed JSON
3. provider exceeds wrapper timeout and is terminated
4. provider terminates by signal

For each scenario:

- run `agent-orch run` against the fixture provider
- capture `task_id` from the `run` JSON output even when worker status is `failed`
- call `agent-orch collect --task-id <id> --repo <temp-repo>`
- assert `report.json` exists
- assert `report.json` has `"status":"failed"`
- assert `provider-result.json` exists
- assert `report.raw` exists only for the malformed-report scenario
- assert the timeout scenario records `"timed_out": true`
- assert the signal scenario records a non-null signal

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/collect-failure.sh`
Expected: FAIL because `collect` and report synthesis are not implemented.

- [ ] **Step 5: Implement the report helper**

In `lib/agent-orch/report.py`, implement:

- `validate <report-path>`
- `synthesize-failure <report-path> <provider-result-path> <stdout-path> <stderr-path> [<raw-report-path>]`

Validation must accept worker-authored reports whose `status` is one of:

- `completed`
- `partial`
- `failed`

Failure synthesis should output:

```json
{
  "status": "failed",
  "summary": "worker did not produce a valid report",
  "files_changed": [],
  "tests_run": [],
  "open_questions": [],
  "risks": ["worker_exit_failure"],
  "notes": ["see provider-result.json", "see stdout.log", "see stderr.log"],
  "diagnostics": {
    "exit_code": 17,
    "signal": null,
    "timed_out": false,
    "stdout_path": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stdout.log",
    "stderr_path": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stderr.log",
    "raw_report_path": null
  }
}
```

- [ ] **Step 6: Implement timeout-aware provider launching**

Create `lib/agent-orch/launch.py` to:

- run the provider command in the target workspace
- enforce a fixed v1 timeout, default `1800` seconds
- allow test override with `AGENT_ORCH_TIMEOUT_SECS`
- emit JSON describing `exit_code`, `signal`, `timed_out`, `started_at`, `finished_at`, and `provider`

Shell should call it with a command array so real providers and fixture providers use the same timeout path.

- [ ] **Step 7: Capture provider termination metadata**

Update `run` so it always writes `provider-result.json` with:

- exit code
- signal when available
- timed_out
- started_at
- finished_at
- provider name

If the worker writes malformed JSON, preserve the payload in `report.raw` before synthesizing a failure report.

- [ ] **Step 8: Synthesize failed reports during `run`, not only during `collect`**

Before `run` returns, validate `report.json`. If the provider crashed, timed out, exited on signal, produced no report, or produced invalid JSON, synthesize a valid failed `report.json` immediately and leave it in task state for downstream commands.

The synthesized failure report should include diagnostic context in addition to the standard required fields, for example:

```json
{
  "status": "failed",
  "summary": "worker did not produce a valid report",
  "files_changed": [],
  "tests_run": [],
  "open_questions": [],
  "risks": ["worker_exit_failure"],
  "notes": ["see provider-result.json", "see stdout.log", "see stderr.log"],
  "diagnostics": {
    "exit_code": 17,
    "signal": null,
    "timed_out": false,
    "stdout_path": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stdout.log",
    "stderr_path": "/tmp/tmp.repo/.superpowers/agent-orch/tasks/20260610-abc123/stderr.log",
    "raw_report_path": null
  }
}
```

- [ ] **Step 9: Implement `collect`**

`collect` should:

- resolve the task by `--task-id`
- ensure `report.json` exists, validating and re-synthesizing only as a repair path if task state was corrupted after `run`
- read `task.json` and expose normalized task metadata as needed
- emit JSON containing `task_id`, `report_path`, `task_dir`, `worktree_path`, `changed_files`, `diff_summary`, `tests_run`

- [ ] **Step 10: Add fixture providers**

`fake-missing-report.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "provider crashed before report" >&2
exit 17
```

`fake-invalid-report.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
task_dir="$1"
printf '{not valid json}\n' > "${task_dir}/report.json"
exit 0
```

`fake-timeout.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
sleep 5
```

`fake-signal.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
kill -TERM $$
```

- [ ] **Step 11: Run the tests to verify they pass**

Run:

```bash
cd /home/nellen/orchestrating-local-coders-skill
bash tests/agent-orch/collect-success.sh
bash tests/agent-orch/collect-failure.sh
```

Expected: PASS. `collect-success` returns the intact worker-authored report data. `collect-failure` produces a valid failed `report.json` for crash, invalid report, timeout, and signal termination, and only the invalid-report case preserves `report.raw`.

- [ ] **Step 12: Commit**

```bash
git add bin/agent-orch lib/agent-orch/launch.py lib/agent-orch/report.py tests/fixtures/providers/fake-missing-report.sh tests/fixtures/providers/fake-invalid-report.sh tests/fixtures/providers/fake-timeout.sh tests/fixtures/providers/fake-signal.sh tests/agent-orch/collect-success.sh tests/agent-orch/collect-failure.sh
git commit -m "Add crash-safe report collection and failure synthesis"
```

---

### Task 5: Implement `cleanup` removal-target behavior

**Files:**
- Modify: `bin/agent-orch`
- Modify: `lib/agent-orch/task-store.sh`
- Modify: `lib/agent-orch/worktree.sh`
- Create: `tests/agent-orch/cleanup.sh`

- [ ] **Step 1: Write the failing cleanup test**

Create `tests/agent-orch/cleanup.sh` to cover:

- `--remove-worktree` deletes the worktree but leaves task state
- `--remove-state` deletes task state but leaves the worktree
- `--all` deletes both
- omitting a removal target fails

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/cleanup.sh`
Expected: FAIL because `cleanup` is not implemented.

- [ ] **Step 3: Implement `cleanup`**

Require:

- `--task-id`
- exactly one of `--repo` or `--task-dir`
- exactly one of `--remove-worktree`, `--remove-state`, `--all`

Use `git worktree remove --force` for worktree deletion and `rm -rf` only for the task-state directory.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/cleanup.sh`
Expected: PASS. Cleanup only removes the explicit target and leaves the other artifact intact unless `--all` is requested.

- [ ] **Step 5: Run the wrapper-core suite**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/run-all.sh`
Expected: PASS for `run-worktree`, `status`, `collect-success`, `collect-failure`, and `cleanup`.

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/task-store.sh lib/agent-orch/worktree.sh tests/agent-orch/cleanup.sh tests/agent-orch/run-all.sh
git commit -m "Implement explicit cleanup targets for task artifacts"
```

---

## Chunk 3: Skill and Real Provider Surface

### Task 6: Write the Codex skill and reference docs

**Files:**
- Create: `skills/coordinating-local-agents/SKILL.md`
- Create: `skills/coordinating-local-agents/references/task-contract.md`
- Create: `skills/coordinating-local-agents/references/report-schema.md`
- Create: `skills/coordinating-local-agents/references/routing-guidelines.md`
- Create: `scripts/install-skill.sh`
- Modify: `README.md`

- [ ] **Step 1: Write a failing content validation script**

Create `tests/agent-orch/skill-docs.sh` that asserts:

- `SKILL.md` has valid frontmatter with `name` and `description`
- the description is trigger-oriented, not workflow-summary prose
- `SKILL.md` mentions `run`, `status`, `collect`, `cleanup`
- `SKILL.md` marks `session` and `inplace` as follow-up
- reference docs exist and are linked from `SKILL.md`
- `scripts/install-skill.sh` exists and links the skill into `~/.agents/skills/`

- [ ] **Step 2: Run the validation script to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/skill-docs.sh`
Expected: FAIL because the skill docs do not exist yet.

- [ ] **Step 3: Write `SKILL.md`**

The skill should cover:

- when to delegate
- when not to delegate
- required pre-dispatch checklist
- the v1 CLI contract
- validation-before-integration behavior
- the fact that only Codex integrates results

- [ ] **Step 4: Write the reference docs**

- `task-contract.md`: required fields for worker prompts
- `report-schema.md`: `report.json` fields and synthetic failure semantics
- `routing-guidelines.md`: v1 explicit dispatch, later routing ideas
- `scripts/install-skill.sh`: creates `~/.agents/skills/coordinating-local-agents` as a symlink to the repo-local skill directory

- [ ] **Step 5: Update `README.md` with skill installation instructions**

Document:

- how to run `bash scripts/install-skill.sh`
- the resulting symlink path under `~/.agents/skills/`
- that Codex may need a restart to refresh skill discovery

- [ ] **Step 6: Run the validation script to verify it passes**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/skill-docs.sh`
Expected: PASS. The skill and references exist and reflect the v1 contract accurately.

- [ ] **Step 7: Commit**

```bash
git add skills/coordinating-local-agents scripts/install-skill.sh README.md tests/agent-orch/skill-docs.sh
git commit -m "Add coordinating-local-agents skill documentation"
```

- [ ] **Step 8: Extend `tests/agent-orch/run-all.sh` to include `skill-docs.sh`**

Append:

```bash
bash "${ROOT_DIR}/tests/agent-orch/skill-docs.sh"
```

---

### Task 7: Define the provider adapter boundary and finalize fixture-provider delivery

**Files:**
- Modify: `lib/agent-orch/provider.sh`
- Create: `tests/agent-orch/provider-boundary.sh`
- Modify: `README.md`

- [ ] **Step 1: Write a failing adapter sanity test**

Create `tests/agent-orch/provider-boundary.sh` to:

- verify the wrapper can dispatch fixture providers through a stable provider boundary
- assert provider resolution fails clearly for unknown workers
- assert `README.md` documents the v1 fixture-provider scope and follow-up status of real adapters

- [ ] **Step 2: Run the sanity test to verify it fails**

Run: `cd /home/nellen/orchestrating-local-coders-skill && bash tests/agent-orch/provider-boundary.sh`
Expected: FAIL because the provider boundary is not fully implemented/documented yet.

- [ ] **Step 3: Finalize the provider boundary around deterministic fixtures**

In `lib/agent-orch/provider.sh`, make the provider contract explicit:

- providers are shell executables resolved by worker name
- they receive `task_dir` and `task.json`
- they run inside the assigned workspace
- they may succeed, omit a report, emit an invalid report, time out, or terminate by signal
- the wrapper owns timeout enforcement, report validation, synthetic failure reports, and artifact persistence

Version 1 ends at this deterministic interface. Real `claude` and `opencode` adapters are follow-up work and should not be implemented in this task.

- [ ] **Step 4: Update `README.md`**

Document:

- the repo purpose
- local test command: `bash tests/agent-orch/run-all.sh`
- expected runtime dependencies: `bash`, `git`, `python3`
- how to point at test providers with `AGENT_ORCH_PROVIDER_DIR`
- that v1 supports only `worktree`
- the skill installation command: `bash scripts/install-skill.sh`
- that v1 uses deterministic fixture providers only
- that real `claude` and `opencode` adapters are follow-up work once local CLI contracts are explicitly pinned

- [ ] **Step 5: Run the full suite and provider boundary check**

Run:

```bash
cd /home/nellen/orchestrating-local-coders-skill
bash tests/agent-orch/provider-boundary.sh
bash tests/agent-orch/run-all.sh
```

Expected: PASS. The provider boundary is deterministic for fixture providers and does not claim unpinned production adapters.

- [ ] **Step 6: Commit**

```bash
git add lib/agent-orch/provider.sh README.md tests/agent-orch/provider-boundary.sh tests/agent-orch/run-all.sh
git commit -m "Finalize fixture provider boundary for v1"
```

- [ ] **Step 7: Extend `tests/agent-orch/run-all.sh` to include `provider-boundary.sh`**

Append:

```bash
bash "${ROOT_DIR}/tests/agent-orch/provider-boundary.sh"
```
