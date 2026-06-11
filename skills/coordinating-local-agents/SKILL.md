---
name: coordinating-local-agents
description: Use when Codex should delegate a bounded local coding, investigation, or validation task to an explicit worker through agent-orch while retaining review and integration authority.
---

# Coordinating Local Agents

Use this skill when a task is bounded, independently checkable, and worth isolating in a worker worktree. Do not delegate unclear product decisions, broad refactors without acceptance criteria, credentialed production actions, or changes that Codex cannot validate afterward.

Before dispatch, define the task statement, acceptance criteria, target repo, worker, and validation plan. Keep the worker scoped to its assigned worktree and make integration a Codex-only decision.

## V1.1 Wrapper

Use `agent-orch` for the fixture-provider-only v1.1 flow:

```bash
agent-orch run --worker <fixture-provider> --repo <repo> --mode worktree --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch status --task-id <task-id> --repo <repo>
agent-orch collect --task-id <task-id> --repo <repo>
agent-orch doctor --task-id <task-id> --repo <repo>
agent-orch cleanup --task-id <task-id> --repo <repo> --remove-worktree
```

V1.1 supports wrapper core, worktree execution, task state, `run`/`status`/`collect`/`cleanup`/`doctor`, provider manifests, runtime binding diagnostics, attempt artifacts, progress preview, report validation, synthetic failed reports, deterministic fixture providers, and this skill install path. Real `claude` and `opencode` adapters, sessions, and `--mode inplace` are follow-up work only.

`status`, `collect`, and `cleanup` are task-only in v1: pass `--task-id`; use `--repo` or `--task-dir` only to locate the task store. `--mode inplace` must fail with `unsupported_mode`.

`agent-orch doctor` is diagnostics, not scheduling authority. status can summarize progress; collect output must preserve worker report details. Do not invent a substitute worker answer if the report is failed, missing, or malformed.

## V2 Loop

Use the v2 loop when dispatching OpenCode MVP work through an explicit provider config:

```bash
# one-time per target repo
mkdir -p <repo>/.agent-orch
cp examples/opencode/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/opencode/.agent-orch/opencode-run.sh <repo>/.agent-orch/opencode-run.sh

agent-orch provider check --provider opencode --repo <repo>
agent-orch loop start --provider opencode --role explore|implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer correctness --review-file <correctness-review.json>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer integration --review-file <integration-review.json>
agent-orch loop decide --loop-id <loop-id> --repo <repo>
```

Antigravity is also available as an explicit-config provider template after `agy` is already authenticated:

```bash
mkdir -p <repo>/.agent-orch
cp examples/antigravity/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/antigravity/.agent-orch/agy-run.sh <repo>/.agent-orch/agy-run.sh
git -C <repo> add .agent-orch/providers.json .agent-orch/agy-run.sh
git -C <repo> commit -m "Add Antigravity agent-orch provider config"
agent-orch provider check --provider antigravity --repo <repo>
```

The default Antigravity worker model is `Gemini 3.5 Flash (High)` for `explore` and `implement`; override it with `AGENT_ORCH_ANTIGRAVITY_MODEL`. Auth is manual and fail-fast: authenticate `agy` manually before readiness; `agent-orch` must not start auth flows. `Claude Opus 4.6 (Thinking)` is a Codex planning helper, not an `agent-orch` loop role. Antigravity remains an explicit-config provider template, not a default automatic route.

The manual gate default is to stop after review/decision output for Codex inspection. Bounded continuation is explicit: pass `--auto-fix --max-iterations` on `loop start`, then run `agent-orch loop continue --loop-id <loop-id> --repo <repo>` only when `loop decide` creates a current `next_task.json`. There is no automatic merge/integration.

Claude Code remains follow-up only. Do not route tasks to any provider automatically from this MVP.

Read the references as needed:

- [Task Contract](references/task-contract.md) for worker prompt and task-state requirements.
- [Report Schema](references/report-schema.md) for `report.json` fields and failure semantics.
- [Routing Guidelines](references/routing-guidelines.md) for worker selection boundaries.
- [Result Handling](references/result-handling.md) for status, collect, and doctor presentation rules.
