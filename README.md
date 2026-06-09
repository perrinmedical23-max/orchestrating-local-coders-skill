# orchestrating-local-coders-skill

Skill and wrapper design work for a Codex-led local orchestration workflow that delegates bounded tasks to Claude Code and OpenCode while keeping planning, validation, and integration under Codex control.

## Current Status

- Design spec written: `docs/specs/2026-06-10-coordinating-local-agents-design.md`
- Wrapper core under active implementation
- Coordinating skill available under `skills/coordinating-local-agents/`

## Scope

Version 1 is centered on:

- a Codex-facing skill for delegation discipline
- a thin shell wrapper for local worker orchestration
- worktree-only isolation
- structured worker result collection
- deterministic fixture providers

Real `claude` and `opencode` adapters, sessions, and inplace execution are follow-up work.

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
