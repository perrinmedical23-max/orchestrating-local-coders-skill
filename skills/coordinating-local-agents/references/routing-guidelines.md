# Routing Guidelines

Codex chooses workers explicitly in v1. There is no automatic routing policy.

## V1 Providers

V1.1 supports deterministic fixture providers only. Use them to validate wrapper behavior around success, missing report, invalid report, timeout, signal termination, provider manifest validation, runtime binding diagnostics, and doctor output.

Real `claude` and `opencode` adapters are follow-up work only. Do not document or assume production adapter behavior in v1 tasks.

## V2 Provider Boundary

V2 is OpenCode MVP only. The implemented real-provider path is `opencode` through an explicit local command template and readiness check:

```bash
mkdir -p <repo>/.agent-orch
cp examples/opencode/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/opencode/.agent-orch/opencode-run.sh <repo>/.agent-orch/opencode-run.sh
agent-orch provider check --provider opencode --repo <repo>
agent-orch loop start --provider opencode --role explore --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch loop start --provider opencode --role implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
```

OpenCode MVP must support both `explore` and `implement`. It is still a worker provider only: it works in the assigned worktree, writes artifacts, and does not own integration.

Claude Code and Antigravity follow-up only. Do not route to them, document them as production-ready, or imply that their local CLI contracts are implemented.

## Delegation Fit

Delegate when the work is:

- bounded to a small implementation, investigation, or validation task
- safe to isolate in a git worktree
- expressible with clear acceptance criteria
- reviewable by Codex through diff, logs, and `report.json`

Do not delegate when the task requires ambiguous product judgment, sensitive credentials, broad integration decisions, or direct edits to the coordinator checkout.

## Follow-Up Scope

Future routing may consider worker strengths, repository language, task type, session reuse, background execution, cancel/resume behavior, and `inplace` execution. Those are not part of v1.

For v2, future routing may add Claude Code, Antigravity, richer provider selection, or production-grade adapter contracts after readiness behavior is pinned. Those are not part of the OpenCode MVP only boundary.
