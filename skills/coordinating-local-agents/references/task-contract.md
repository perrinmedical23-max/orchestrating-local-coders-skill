# Worker Task Contract

Workers receive a normalized task directory from `agent-orch`, not loose CLI arguments. The task directory contains `task.json`, logs, provider metadata, and the required `report.json` output path.

## V1.1 Task Fields

V1.1 `task.json` is the worker task payload. It gives the worker task identity, workspace, instructions, constraints, report requirements, and finalization rules:

- `task_id`: stable id for this delegated task.
- `worker`: explicit provider name selected by Codex.
- `mode`: `worktree` in v1.
- `repo_path`: original repository path used to locate task state.
- `workspace_path`: worker writable worktree path.
- `task_statement`: embedded task text or prompt.
- `acceptance_criteria`: embedded validation criteria.
- `task_source`: source paths or prompt text used to build the task.
- `constraints`: integration and mode limits, including no worker merge or cherry-pick.
- `report_requirements`: `report.json` path and JSON format.
- `finalization`: must state that the worker writes a report before exiting.

Provider and runtime binding details are not part of the v1.1 task payload. They live in wrapper-owned artifacts:

- `metadata.json`: stores repo/worktree paths and provider manifest details such as `provider_id`, `provider_kind`, provider command, manifest path, and capabilities.
- `status.json`: stores task status, phase, worker, mode, runtime binding fields such as `runtime_ref`, `session_ref`, `workspace_path`, and `binding_status`, plus provider manifest details when available.
- `agent-orch status` and `agent-orch doctor`: read `metadata.json` and `status.json` to report provider/runtime diagnostics.

V2 loop tasks add loop identity and role fields without changing the worker authority boundary. `agent-orch loop start` creates the first iteration task, `agent-orch loop decide` may produce a narrower next task, and Codex remains responsible for deciding whether to continue, inspect manually, or integrate nothing.

## V2 Task Fields

V2 iteration `task.json` artifacts use the loop contract, not the v1.1 fixture task fields:

- `schema_version`: currently `1`.
- `loop_id`: stable id for the v2 orchestration loop.
- `iteration`: one-based loop iteration number.
- `provider`: provider selected for the loop; `opencode` in the OpenCode MVP.
- `role`: `explore` or `implement`.
- `repo_path`: original repository path used to locate loop state.
- `workspace_path`: worker writable worktree path after dispatch.
- `report_path`: required worker `report.json` output path after dispatch.
- `task_statement`: embedded task text or generated focused fix task.
- `acceptance_criteria`: embedded validation criteria.
- `task_source`: source task and acceptance file paths for initial iterations, or `null` values for generated continuation tasks.
- `constraints`: integration limits including no merge, cherry-pick, push, or main checkout edits.
- `report_requirements`: `report.json` path and JSON format.

Continuation tasks created by `agent-orch loop continue` also include `source_next_task_path`, `source_iteration`, `auto_fix`, `blocker_summaries`, `blocker_signature`, and `original_acceptance_criteria`.

## V2 Loop Fields

Loop state must preserve enough data to reproduce decisions:

- `loop_id`: stable id used by `agent-orch loop status`, `collect`, `review`, `decide`, and `continue`.
- `provider`: `opencode` for the OpenCode MVP.
- `role`: `explore` or `implement`; unsupported roles must fail before dispatch.
- `current_iteration`: latest collected worker iteration.
- `auto_fix`: false unless `--auto-fix` was passed to `loop start`.
- `max_iterations`: required when `--auto-fix` is present.
- `state`: loop state such as `created`, `worker_collected`, `manual_gate`, `completed`, `failed_max_iterations`, or `stopped`.

## V2 Review And Decision Artifacts

Each iteration may contain:

- `reviews/correctness.json` and `reviews/integration.json`: required recorded reviewer outputs before `agent-orch loop decide`.
- `reviews/<reviewer>.raw`: preserved malformed reviewer output when JSON validation fails.
- `decision.json`: deterministic decision output with `decision`, `state`, `current_iteration`, `blocking_reviewers`, `reviewer_statuses`, artifact paths, and optional `next_task_path`.
- `next_task.json`: generated only when `loop decide` returns `auto_fix_ready`.
- `next_task.consumed.json`: archived generated task after `agent-orch loop continue` consumes it.
- `next_task.stale.json`: archived stale generated task when a later decision no longer allows continuation.

## Worker Rules

- Work only in `workspace_path`.
- Do not edit the coordinator's primary checkout.
- Do not merge, cherry-pick, push, or otherwise integrate results.
- Keep changes scoped to the task statement and acceptance criteria.
- Run relevant checks when practical and record them in `report.json`.
- Write `report.json` even for partial or failed work.

Codex reviews collected artifacts and is the only actor that integrates results.
