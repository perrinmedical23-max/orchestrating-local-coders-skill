# Worker Task Contract

Workers receive a normalized task directory from `agent-orch`, not loose CLI arguments. The task directory contains `task.json`, logs, provider metadata, and the required `report.json` output path.

## Required Task Fields

`task.json` must give the worker enough context to act without reading coordinator state:

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

## Worker Rules

- Work only in `workspace_path`.
- Do not edit the coordinator's primary checkout.
- Do not merge, cherry-pick, push, or otherwise integrate results.
- Keep changes scoped to the task statement and acceptance criteria.
- Run relevant checks when practical and record them in `report.json`.
- Write `report.json` even for partial or failed work.

Codex reviews collected artifacts and is the only actor that integrates results.
