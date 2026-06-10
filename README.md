# orchestrating-local-coders-skill

Skill and wrapper core for a Codex-led local orchestration workflow. The repo
contains the `agent-orch` shell wrapper, deterministic fixture providers, and a
Codex-facing skill for delegating bounded local coding tasks while keeping
planning, validation, and integration under Codex control.

Runtime dependencies: `bash`, `git`, and `python3`.

## Current Status

- Design spec written: `docs/specs/2026-06-10-coordinating-local-agents-design.md`
- V1 wrapper core implemented
- V1.1 diagnostics surface implemented for fixture providers
- V2 orchestration loop implemented for OpenCode MVP only
- Coordinating skill available under `skills/coordinating-local-agents/`

## Scope

Version 1 and v1.1 are centered on:

- a Codex-facing skill for delegation discipline
- a thin shell wrapper for local worker orchestration
- worktree-only v1 isolation
- structured worker result collection
- deterministic fixture-provider v1.1 scope
- provider manifests for fixture providers
- runtime binding diagnostics without session support
- attempt diagnostics and synthetic failed reports
- task-scoped doctor and support bundle output
- OpenCode MVP only v2 loop commands for provider readiness, loop start,
  reviewer ingestion, deterministic decisions, and bounded continuation

V1.1 supports only `--mode worktree`; inplace execution is follow-up work.
Real `claude` and `opencode` adapters are follow-up work once local CLI contracts are explicitly pinned.

V2 supports OpenCode through explicit command templates. Claude Code and Antigravity follow-up only: they are not production adapters in this repo. The manual gate default is to stop after reviewer/decision output for Codex inspection. Auto-fix requires explicit `--auto-fix --max-iterations`; there is no automatic merge/integration.

V1.1 borrows setup/status/result contract ideas from
`openai/codex-plugin-cc`, but not its plugin packaging, app-server bridge,
auth setup, npm install flow, background broker, cancel/resume lifecycle, or
review gate.

## Local Tests

Run the wrapper-core suite with:

```bash
bash tests/agent-orch/run-all.sh
```

Default focused checks:

```bash
bash tests/agent-orch/provider-config.sh
bash tests/agent-orch/loop-start.sh
bash tests/agent-orch/loop-review.sh
bash tests/agent-orch/loop-decide.sh
bash tests/agent-orch/loop-auto-fix.sh
bash tests/agent-orch/skill-docs.sh
```

Default tests use fake OpenCode fixtures and do not require a real OpenCode install. Optional real-provider smoke is manual and should start with readiness:

```bash
mkdir -p <repo>/.agent-orch
cp examples/opencode/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/opencode/.agent-orch/opencode-run.sh <repo>/.agent-orch/opencode-run.sh
agent-orch provider check --provider opencode --repo <repo>
agent-orch loop start --provider opencode --role implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer correctness --review-file <correctness-review.json>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer integration --review-file <integration-review.json>
agent-orch loop decide --loop-id <loop-id> --repo <repo>
```

Bounded continuation is opt-in on loop creation and explicit after decisioning:

```bash
agent-orch loop start --provider opencode --role implement --repo <repo> --task-file <task.md> --acceptance-file <acceptance.md> --auto-fix --max-iterations <n>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer correctness --review-file <correctness-review.json>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer integration --review-file <integration-review.json>
agent-orch loop decide --loop-id <loop-id> --repo <repo>
agent-orch loop continue --loop-id <loop-id> --repo <repo>
```

The suite uses deterministic fixture providers. Point the wrapper at a provider
directory with `AGENT_ORCH_PROVIDER_DIR`; worker `fake-success` resolves to:

```text
${AGENT_ORCH_PROVIDER_DIR}/fake-success.sh
```

Providers receive the task-state directory and normalized `task.json`, then run
inside the assigned worktree workspace.

Inspect a task with:

```bash
agent-orch doctor --task-id <task-id> --repo <repo>
```

Export diagnostics without copying the worktree with:

```bash
agent-orch doctor --task-id <task-id> --repo <repo> --bundle <path>
```

## Skill Installation

Install the repo-local skill into Codex discovery with:

```bash
bash scripts/install-skill.sh
```

The installer creates this symlink:

```text
~/.agents/skills/coordinating-local-agents -> ./skills/coordinating-local-agents
```

You may need to restart Codex after installing so skill discovery refreshes.

## Repository Layout

```text
bin/          agent-orch CLI wrapper
docs/specs/   Design documents
docs/superpowers/plans/ Implementation plans
lib/          wrapper libraries
scripts/      local install helpers
skills/       Codex skill source
tests/        shell integration tests
```
