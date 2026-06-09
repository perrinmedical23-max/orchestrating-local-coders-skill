# orchestrating-local-coders-skill

Skill and wrapper core for a Codex-led local orchestration workflow. The repo
contains the `agent-orch` shell wrapper, deterministic fixture providers, and a
Codex-facing skill for delegating bounded local coding tasks while keeping
planning, validation, and integration under Codex control.

Runtime dependencies: `bash`, `git`, and `python3`.

## Current Status

- Design spec written: `docs/specs/2026-06-10-coordinating-local-agents-design.md`
- Wrapper core under active implementation
- Coordinating skill available under `skills/coordinating-local-agents/`

## Scope

Version 1 is centered on:

- a Codex-facing skill for delegation discipline
- a thin shell wrapper for local worker orchestration
- worktree-only v1 isolation
- structured worker result collection
- deterministic fixture-provider v1 scope

V1 supports only `--mode worktree`; inplace execution is follow-up work.
Real `claude` and `opencode` adapters are follow-up work once local CLI contracts are explicitly pinned.

## Local Tests

Run the wrapper-core suite with:

```bash
bash tests/agent-orch/run-all.sh
```

The suite uses deterministic fixture providers. Point the wrapper at a provider
directory with `AGENT_ORCH_PROVIDER_DIR`; worker `fake-success` resolves to:

```text
${AGENT_ORCH_PROVIDER_DIR}/fake-success.sh
```

Providers receive the task-state directory and normalized `task.json`, then run
inside the assigned worktree workspace.

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
lib/          wrapper libraries
scripts/      local install helpers
skills/       Codex skill source
tests/        shell integration tests
```
