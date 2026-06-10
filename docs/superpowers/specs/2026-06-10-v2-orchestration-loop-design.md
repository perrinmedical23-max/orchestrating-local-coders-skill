# V2 Orchestration Loop Design

## Goal

Build a Codex-led orchestration loop inspired by `superpowers:subagent-driven-development`: Codex remains the coordinator and integrator, delegates bounded work to local external agents, launches Codex-owned review subagents, and optionally repeats a bounded fix loop.

The v2 design defines a multi-provider contract, but the MVP implements only one real external adapter: OpenCode. Claude Code and Antigravity are contract-only follow-up providers until their local CLI contracts are pinned and readiness-checked.

## Non-Goals

- No daemon, tmux pane management, mailbox kernel, or autonomous routing.
- No automatic merge, cherry-pick, push, or integration by workers.
- No unbounded auto-fix loop.
- No implementation of Claude Code or Antigravity adapters in the MVP.
- No automatic discovery of local CLI behavior. Real providers require explicit command templates and readiness checks.

## Architecture

V2 extends the existing v1.1 `agent-orch` wrapper and state store with a loop layer.

High-level flow:

```text
Codex coordinator
  -> agent-orch dispatch role=explore|implement provider=opencode
  -> OpenCode runs in isolated worktree via explicit command template
  -> wrapper collects report.json + diagnostics
  -> Codex launches two review subagents
       - correctness reviewer
       - integration reviewer
  -> coordinator decides:
       - stop for manual gate
       - or, if --auto-fix enabled and iterations remain, dispatch a fix task
  -> final collect / cleanup remains Codex-owned
```

Responsibility boundaries:

- `agent-orch` owns local execution, state artifacts, readiness, diagnostics, loop records, and failure finalization.
- Codex owns planning, provider selection, review orchestration, loop decisions, and integration.
- OpenCode is a worker provider only. It works inside `workspace_path` and returns artifacts.
- Codex review subagents review worker output but do not edit code.

## Provider Contract

Providers declare:

- `provider_id`
- `provider_kind`
- `supported_roles`
- `command_template`
- `capabilities`

Supported roles in v2 MVP:

- `explore`: read-only investigation. The provider returns a structured report and should not modify files.
- `implement`: write-capable work in the assigned worktree. The provider must produce `report.json`.

Provider rules:

- Execute in the wrapper-provided `workspace_path`.
- Do not edit the coordinator checkout.
- Do not merge, cherry-pick, push, or integrate results.
- Return completion through `report.json`, stdout/stderr logs, and provider-result diagnostics.
- Any provider that cannot satisfy the contract must fail readiness and must not run.

## OpenCode MVP Adapter

OpenCode is the only real external adapter in the MVP.

The adapter does not auto-detect CLI behavior. A repo-local config provides an explicit command template:

Config path:

```text
.agent-orch/providers.json
```

Schema:

```json
{
  "schema_version": 1,
  "providers": {
    "opencode": {
      "provider_id": "opencode",
      "provider_kind": "external_cli",
      "supported_roles": ["explore", "implement"],
      "command_template": ["opencode", "run", "--non-interactive", "--prompt-file", "{prompt_file}"],
      "capabilities": {
        "worktree": true,
        "writes_report": true,
        "supports_readonly": true,
        "supports_timeout": true
      }
    }
  }
}
```

Rules:

- `schema_version` must be integer `1`.
- `providers.opencode.provider_id` must be `opencode`.
- `provider_kind` must be `external_cli`.
- `supported_roles` must include both `explore` and `implement` for the OpenCode MVP.
- `command_template` must be an array of strings.
- `capabilities` values must be booleans.
- Missing config fails with `provider_config_missing`.
- Invalid config fails with `provider_config_invalid`.
- Unknown provider id fails with `unknown_provider`.

Allowed placeholders should be explicit and minimal:

- `{prompt_file}`
- `{task_dir}`
- `{task_json}`
- `{workspace_path}`
- `{report_path}`

Readiness checks must validate:

- executable exists
- template placeholders are valid
- command can run in a temporary worktree
- command does not require an interactive TTY
- exit behavior is deterministic enough for wrapper control
- report production or wrapper-enforced report finalization is possible

If readiness fails, `agent-orch loop start` fails before launching OpenCode with `provider_not_ready` and preserves the readiness report.

## CLI Surface And Ownership

V2 loop uses new commands instead of overloading v1.1 `run`.

Required command shape:

```bash
agent-orch provider check --provider opencode --repo <repo>
agent-orch loop start --provider opencode --role explore|implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md> [--auto-fix --max-iterations <n>]
agent-orch loop continue --loop-id <id> --repo <repo>
agent-orch loop status --loop-id <id> --repo <repo>
agent-orch loop collect --loop-id <id> --repo <repo>
agent-orch loop review --loop-id <id> --repo <repo> --reviewer correctness|integration --review-file <review.json>
agent-orch loop decide --loop-id <id> --repo <repo>
```

Ownership:

- `agent-orch provider check` validates config and readiness. It does not dispatch work.
- `agent-orch loop start` creates loop state, stores loop options, and runs the first worker iteration.
- `agent-orch loop continue` runs the next generated fix task inside an existing loop. It requires `loop decide` to have produced `next_task.json`.
- Codex launches review subagents outside the wrapper.
- `agent-orch loop review` records reviewer outputs from Codex-owned reviewers.
- `agent-orch loop decide` applies deterministic loop rules using stored reports and reviews.
- `agent-orch` may generate `next_task.json` during `decide`, but Codex must explicitly call `agent-orch loop continue` to launch the next worker iteration.

Loop options:

- `--auto-fix` is accepted only on `loop start`.
- `--max-iterations <n>` is required when `--auto-fix` is present.
- `loop start` stores these options in `loop.json`.
- `loop decide` reads `loop.json` to determine whether it may generate `next_task.json`.
- `loop continue` must fail with `auto_fix_not_enabled` if the loop was not started with `--auto-fix`.
- `loop continue` must fail with `max_iterations_reached` if another worker iteration would exceed `--max-iterations`.

This keeps local execution and loop state machine in the wrapper while preserving Codex as the planner, reviewer launcher, and integration owner.

## Loop State

V2 adds loop state above v1.1 task artifacts.

Loop states:

- `created`
- `dispatching`
- `worker_running`
- `worker_collected`
- `reviewing`
- `manual_gate`
- `auto_fix_dispatching`
- `completed`
- `failed`
- `stopped`
- `failed_max_iterations`

Each iteration stores:

```text
iterations/1/
  task.json
  report.json
  provider-result.json
  stdout.log
  stderr.log
  diff_summary
  reviews/
    correctness.json
    integration.json
```

Review decision rules:

- Both reviewers pass: loop can complete.
- Any reviewer blocks: enter `manual_gate`, unless explicit auto-fix is enabled and iterations remain.
- Any reviewer returns `needs_human`: enter `manual_gate`.
- Malformed reviewer output: preserve raw output and treat as `needs_human`.
- Max iterations reached while blockers remain: enter `failed_max_iterations`; no more automatic dispatch.

`--auto-fix` is opt-in on `loop start`. `--max-iterations` is required when auto-fix is enabled and is persisted in `loop.json`.

## Review Outputs

Correctness reviewer output:

```json
{
  "status": "passed|blocked|needs_human",
  "summary": "...",
  "blocking_findings": [
    {
      "severity": "high",
      "file": "path/to/file",
      "line": 123,
      "issue": "...",
      "recommendation": "..."
    }
  ],
  "tests_required": [],
  "residual_risks": []
}
```

Integration reviewer output:

```json
{
  "status": "passed|blocked|needs_human",
  "summary": "...",
  "acceptance_match": "met|partial|not_met|unclear",
  "blocking_findings": [],
  "integration_risks": [],
  "suggested_next_task": null
}
```

Reviewer invocation boundary:

- Runtime reviewers are Codex subagents launched by Codex, not by `agent-orch`.
- Test reviewers are fixture JSON files passed to `agent-orch loop review`.
- `agent-orch loop review` validates and records reviewer JSON but never invokes a model.
- Review artifacts live under `iterations/<n>/reviews/<reviewer>.json`.
- Malformed reviewer output is saved as `iterations/<n>/reviews/<reviewer>.raw` and normalized to `needs_human`.
- Missing required reviewer before `decide` returns `review_missing`.
- Reviewer ids are limited to `correctness` and `integration` in MVP.

This boundary lets tests exercise the full loop deterministically without real Codex subagents, while runtime Codex still owns subagent launch and prompt construction.

Auto-fix task generation uses only:

- reviewer blockers
- original task statement
- acceptance criteria
- current diff summary
- prior iteration report

Generated fix tasks must be narrower than the original task. Repeated blockers stop the auto-fix loop and surface to the user.

## Failure Handling

Failure behavior extends v1.1 synthetic reports and diagnostics.

- Readiness failure: no worker launch; produce `provider_not_ready` and preserve readiness details.
- Worker exits nonzero with valid `partial|failed` report: preserve worker report.
- Worker exits nonzero with `completed` report: wrapper produces synthetic failed report.
- Missing or invalid report: wrapper produces synthetic failed report and preserves stdout/stderr/provider-result/raw report when available.
- Reviewer crash or malformed JSON: preserve raw reviewer output, mark reviewer as `needs_human`, and enter manual gate.
- Repeated blocker: stop auto-fix with `repeated_blocker`.
- Max iterations reached: stop auto-fix and enter `failed_max_iterations`.
- Workspace violation: mark `workspace_violation`, block auto-fix, and require human review.

All failures must include machine-readable `error_code` and artifact paths. Cleanup remains explicit through cleanup flags.

## Testing Strategy

Default tests must be deterministic and must not require real OpenCode.

Test layers:

1. Contract tests with fixtures:
   - fixture external provider for `explore` and `implement`
   - fixture reviewers for `passed`, `blocked`, `needs_human`, and malformed JSON
   - state machine, iteration artifacts, manual gate, auto-fix max iteration behavior

2. OpenCode readiness tests:
   - fake `opencode` binary
   - command template parsing
   - missing executable
   - bad placeholder
   - interactive-only behavior
   - nonzero readiness smoke

3. Optional real OpenCode smoke:
   - manual test only
   - not part of `bash tests/agent-orch/run-all.sh`
   - requires explicit repo-local provider config

Success criteria:

- Full default suite passes without real OpenCode.
- OpenCode adapter cannot run until readiness passes.
- Auto-fix loop is bounded.
- Malformed reviewer output cannot be treated as passed.
- Worker and reviewer failures preserve diagnostics and do not trigger automatic integration.

## Implementation Planning Decisions

- Repo-local provider config path is `.agent-orch/providers.json`.
- V2 loop uses new `agent-orch loop ...` commands and does not overload v1.1 `run`.
- Runtime reviewer invocation is Codex-owned; wrapper records review files through `agent-orch loop review`.
- Deterministic loop decisioning lives in `agent-orch loop decide`; Codex decides whether to launch the next worker iteration or stop for the user.
- Subsequent auto-fix iterations run through `agent-orch loop continue --loop-id <id>`, not a new `loop start`.
- OpenCode MVP must support both `explore` and `implement`; neither role is optional in the MVP contract.
