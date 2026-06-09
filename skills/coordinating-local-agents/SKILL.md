---
name: coordinating-local-agents
description: Use when Codex should delegate a bounded local coding, investigation, or validation task to an explicit worker through agent-orch while retaining review and integration authority.
---

# Coordinating Local Agents

Use this skill when a task is bounded, independently checkable, and worth isolating in a worker worktree. Do not delegate unclear product decisions, broad refactors without acceptance criteria, credentialed production actions, or changes that Codex cannot validate afterward.

Before dispatch, define the task statement, acceptance criteria, target repo, worker, and validation plan. Keep the worker scoped to its assigned worktree and make integration a Codex-only decision.

## V1 Wrapper

Use `agent-orch` for the v1 flow:

```bash
agent-orch run --worker <fixture-provider> --repo <repo> --mode worktree --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch status --task-id <task-id> --repo <repo>
agent-orch collect --task-id <task-id> --repo <repo>
agent-orch cleanup --task-id <task-id> --repo <repo> --remove-worktree
```

V1 supports wrapper core, worktree execution, task state, `run`/`status`/`collect`/`cleanup`, report validation, synthetic failed reports, deterministic fixture providers, and this skill install path. Real `claude` and `opencode` adapters, sessions, and `--mode inplace` are follow-up work only.

`status`, `collect`, and `cleanup` are task-only in v1: pass `--task-id`; use `--repo` or `--task-dir` only to locate the task store. `--mode inplace` must fail with `unsupported_mode`.

Read the references as needed:

- [Task Contract](references/task-contract.md) for worker prompt and task-state requirements.
- [Report Schema](references/report-schema.md) for `report.json` fields and failure semantics.
- [Routing Guidelines](references/routing-guidelines.md) for worker selection boundaries.
