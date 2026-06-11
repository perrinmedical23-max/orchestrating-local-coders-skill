# Routing Guidelines

Codex chooses workers explicitly in v1. There is no automatic routing policy.

## V1 Providers

V1.1 supports deterministic fixture providers only. Use them to validate wrapper behavior around success, missing report, invalid report, timeout, signal termination, provider manifest validation, runtime binding diagnostics, and doctor output.

Real `claude` and `opencode` adapters are follow-up work only. Do not document or assume production adapter behavior in v1 tasks.

## V2 Provider Boundary

V2 keeps the OpenCode MVP only boundary for default routing. The implemented built-in real-provider path is `opencode` through an explicit local command template and readiness check:

```bash
mkdir -p <repo>/.agent-orch
cp examples/opencode/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/opencode/.agent-orch/opencode-run.sh <repo>/.agent-orch/opencode-run.sh
agent-orch provider check --provider opencode --repo <repo>
agent-orch loop start --provider opencode --role explore --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch loop start --provider opencode --role implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
```

OpenCode MVP must support both `explore` and `implement`. It is still a worker provider only: it works in the assigned worktree, writes artifacts, and does not own integration.

Antigravity is an explicit-config provider template, not a default automatic route. Claude Code remains follow-up only. Do not route to any provider automatically, document unconfigured providers as production-ready, or imply that Codex gives up review and integration authority.

## Antigravity Provider Boundary

The provider id is `antigravity`; the backend CLI is `agy`. Use it only after copying and committing the explicit provider config into the target repo:

```bash
mkdir -p <repo>/.agent-orch
cp examples/antigravity/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/antigravity/.agent-orch/agy-run.sh <repo>/.agent-orch/agy-run.sh
git -C <repo> add .agent-orch/providers.json .agent-orch/agy-run.sh
git -C <repo> commit -m "Add Antigravity agent-orch provider config"
agent-orch provider check --provider antigravity --repo <repo>
```

Run `agent-orch provider check --provider antigravity --repo <repo>` before dispatch. Auth is manual and fail-fast: if readiness fails, authenticate `agy` manually and retry. The wrapper must not start auth, open a browser, or prompt for credentials.

The default Antigravity worker model is `Gemini 3.5 Flash (High)` for `explore` and `implement`. Override with `AGENT_ORCH_ANTIGRAVITY_MODEL`. `Claude Opus 4.6 (Thinking)` is a Codex planning helper, but it is not an `agent-orch` loop role.

## Delegation Fit

Delegate when the work is:

- bounded to a small implementation, investigation, or validation task
- safe to isolate in a git worktree
- expressible with clear acceptance criteria
- reviewable by Codex through diff, logs, and `report.json`

Do not delegate when the task requires ambiguous product judgment, sensitive credentials, broad integration decisions, or direct edits to the coordinator checkout.

## Follow-Up Scope

Future routing may consider worker strengths, repository language, task type, session reuse, background execution, cancel/resume behavior, and `inplace` execution. Those are not part of v1.

For v2, future routing may add Claude Code, richer provider selection, or production-grade adapter contracts after readiness behavior is pinned. Those are not part of the OpenCode MVP only boundary.
