# Agent Orch CCB Borrowings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the useful short-term lessons from `SeemSeam/claude_codex_bridge` into `orchestrating-local-coders-skill` as a v1.1 executable plan, while recording mid-term v2 follow-up work without expanding v1 beyond a thin Codex-controlled wrapper and deterministic fixture providers.

**Architecture:** Keep `agent-orch` as the control-plane CLI and task-state store. Borrow CCB's contract ideas, not its daemon/tmux/mailbox architecture: provider manifests, explicit runtime binding fields, attempt diagnostics, project-scoped doctor/bundle output, and later named-agent routing through config.

**Tech Stack:** Bash CLI wrapper, Python 3 standard library helpers, git worktrees, JSON state artifacts, shell integration tests.

---

## Source Borrowings

Use these CCB ideas as design inputs:

- `lib/provider_core/contracts.py` and `lib/provider_core/manifests.py`: provider identity and capability should be explicit metadata, not inferred from command names.
- `lib/agents/runtime_binding.py`: runtime identity should be represented as nullable fields with a derived `binding_status`.
- `docs/ccbd-diagnostics-contract.md`: diagnostics should preserve enough local evidence for another process to understand failures without interactive access.
- `docs/final-target-agent-first-multi-mount.md` and `docs/agent-mailbox-kernel-design.md`: useful as cautionary examples, but out of scope for this repo's short-term plan.

Do not port CCB's daemon, tmux pane model, mailbox kernel, hot reload machinery, role packs, or real provider adapters into this plan.

Use these `openai/codex-plugin-cc` ideas as additional design inputs:

- `plugins/codex/scripts/lib/state.mjs`: state should have a version, a deterministic workspace scope, stable per-job/task files, and bounded index growth.
- `plugins/codex/scripts/lib/tracked-jobs.mjs`: execution records should preserve phase, timestamps, pid/exit state when applicable, final output, and an append-only progress log.
- `plugins/codex/scripts/lib/job-control.mjs`: status should be compact by default, include phase/progress preview/action hints, and reject ambiguous short ids.
- `plugins/codex/commands/setup.md`: readiness checks should be explicit setup/doctor output, not implicit failures during task execution.
- `plugins/codex/commands/result.md` and `plugins/codex/skills/codex-result-handling/SKILL.md`: result presentation must preserve the helper payload and must not invent substitute answers after a failed or malformed worker run.

Do not port the Claude Code plugin packaging, app-server bridge, stop hook review gate, background process broker, Codex auth setup, or npm install flow into v1.1.

## File Map

Existing files to modify:

- `bin/agent-orch`: add new subcommands and wire new helper scripts.
- `lib/agent-orch/provider.sh`: keep fixture provider resolution, add manifest lookup.
- `lib/agent-orch/task-store.sh`: add metadata/status fields while preserving v1 output shape.
- `lib/agent-orch/launch.py`: write provider-result diagnostics into attempt paths when enabled.
- `lib/agent-orch/report.py`: ensure synthetic failure can reference attempt diagnostics.
- `tests/test-helpers.sh`: add a helper for temporary fixture provider manifests.
- `tests/agent-orch/run-worktree.sh`: add manifests for ad hoc temporary providers.
- `tests/agent-orch/collect-failure.sh`: add manifests for ad hoc temporary providers.
- `tests/agent-orch/provider-boundary.sh`: add manifests for ad hoc temporary providers.
- `tests/agent-orch/run-all.sh`: include new targeted tests.
- `tests/agent-orch/skill-docs.sh`: extend skill-document validation only after first making the validation fail.
- `skills/coordinating-local-agents/SKILL.md`: document new safe usage, after validation exists.
- `skills/coordinating-local-agents/references/task-contract.md`: document provider manifest and runtime binding fields.
- `skills/coordinating-local-agents/references/report-schema.md`: document attempts and diagnostic artifact locations.
- `skills/coordinating-local-agents/references/routing-guidelines.md`: document named-agent routing boundaries.
- `skills/coordinating-local-agents/references/result-handling.md`: add result/status presentation rules if a separate reference is clearer than expanding `report-schema.md`.
- `README.md`: update status/scope and commands.

New files to add:

- `lib/agent-orch/provider_manifest.py`: validate and normalize provider manifest JSON.
- `lib/agent-orch/doctor.py`: produce diagnostics summaries and bundles.
- `tests/agent-orch/provider-manifest.sh`
- `tests/agent-orch/runtime-binding.sh`
- `tests/agent-orch/attempts.sh`
- `tests/agent-orch/doctor.sh`
- `tests/fixtures/providers/manifests/fake-success.json`
- `tests/fixtures/providers/manifests/fake-missing-report.json`
- `tests/fixtures/providers/manifests/fake-invalid-report.json`
- `tests/fixtures/providers/manifests/fake-timeout.json`
- `tests/fixtures/providers/manifests/fake-signal.json`

## Scope Guardrails

- v1.1 remains fixture-provider only.
- Real `claude`, `opencode`, `codex`, `gemini`, or other local CLI adapters remain follow-up until their local command contracts are explicitly pinned.
- `--mode worktree` remains the only execution mode.
- `inplace`, daemon mode, tmux panes, interactive sessions, mailbox messaging, and autonomous multi-agent routing remain follow-up.
- Named-agent config is mid-term follow-up only in this plan; it may later map names to fixture providers, but must not imply production adapters.
- Background execution, cancel, resume, and review-gate behavior are mid-term follow-up only; v1.1 remains synchronous `run` plus task-scoped `status`/`collect`/`cleanup`.

## Phase A: Short-Term v1.1

### Task 1: Add Provider Manifests For Fixture Providers

Purpose: make provider identity and capabilities explicit without changing the execution model.

Manifest schema for v1.1 fixture providers:

```json
{
  "schema_version": 1,
  "provider_id": "fake-success",
  "provider_kind": "fixture",
  "command": "fake-success.sh",
  "capabilities": {
    "worktree": true,
    "writes_report": true,
    "streams_stdout": true,
    "supports_timeout": true
  },
  "description": "Deterministic success fixture provider."
}
```

Rules:

- `schema_version` must be integer `1`.
- `provider_id` must match the worker id passed to `--worker`.
- `provider_kind` must be exactly `fixture` in v1.1.
- `command` is the executable filename under `AGENT_ORCH_PROVIDER_DIR`; it must not contain `/`.
- `capabilities` must be a JSON object with boolean values only.
- Required capability keys are `worktree`, `writes_report`, `streams_stdout`, and `supports_timeout`.
- Extra capability keys are allowed only if they are boolean.
- Missing manifest for a fixture provider fails with `provider_manifest_missing`.
- Invalid manifest fails with `provider_manifest_invalid`.
- Non-fixture provider kinds fail with `unsupported_provider_kind`.

`lib/agent-orch/provider_manifest.py` command I/O:

```bash
python3 lib/agent-orch/provider_manifest.py resolve --provider fake-success --provider-dir tests/fixtures/providers
```

Prints normalized JSON on stdout:

```json
{
  "provider_id": "fake-success",
  "provider_kind": "fixture",
  "provider_command": "/abs/path/tests/fixtures/providers/fake-success.sh",
  "manifest_path": "/abs/path/tests/fixtures/providers/manifests/fake-success.json",
  "capabilities": {
    "worktree": true,
    "writes_report": true,
    "streams_stdout": true,
    "supports_timeout": true
  }
}
```

```bash
python3 lib/agent-orch/provider_manifest.py validate --manifest tests/fixtures/providers/manifests/fake-success.json --provider fake-success --provider-dir tests/fixtures/providers
```

Prints the same normalized JSON when valid. On failure it writes a concise diagnostic to stderr and exits non-zero; callers map the stderr prefix to the wrapper error code.

- [ ] Add a failing test in `tests/agent-orch/provider-manifest.sh`.
- [ ] The test creates a temporary git repo, points `AGENT_ORCH_PROVIDER_DIR` at `tests/fixtures/providers`, and asserts `agent-orch run --worker fake-success ...` records manifest data.
- [ ] Expected metadata/status fields:
  - `provider_id`
  - `provider_kind` with value `fixture`
  - `provider_command`
  - `capabilities`
  - `manifest_path`
- [ ] Add fixture manifests under `tests/fixtures/providers/manifests/`.
- [ ] Add a test helper such as `agent_orch_write_fixture_manifest <provider-dir> <provider-id> <command>` in `tests/test-helpers.sh`.
- [ ] Update existing ad hoc provider tests to create manifests before `agent-orch run`:
  - `tests/agent-orch/provider-boundary.sh` for `fake-boundary`
  - `tests/agent-orch/collect-failure.sh` for `fake-completed-nonzero`, `fake-partial-nonzero`, and `fake-bad-shebang`
  - `tests/agent-orch/run-worktree.sh` for `fake-controlled-fail`
- [ ] Do not add a compatibility exception for missing fixture manifests; after Task 1, missing manifests are always a provider setup error.
- [ ] Implement `lib/agent-orch/provider_manifest.py` with the `resolve` and `validate` subcommands defined above.
- [ ] Wire `provider.sh` and `task-store.sh` so `run` stores normalized manifest fields in `metadata.json` and `status.json`.
- [ ] Fail fast with `provider_manifest_invalid` when a fixture manifest is malformed.

Verify:

```bash
bash tests/agent-orch/provider-manifest.sh
```

Expected output:

```text
provider-manifest.sh: ok
```

Commit:

```bash
git add lib/agent-orch/provider_manifest.py lib/agent-orch/provider.sh lib/agent-orch/task-store.sh tests/test-helpers.sh tests/agent-orch/provider-manifest.sh tests/agent-orch/provider-boundary.sh tests/agent-orch/collect-failure.sh tests/agent-orch/run-worktree.sh tests/fixtures/providers/manifests
git commit -m "Add fixture provider manifests"
```

### Task 2: Add Runtime Binding Fields Without Session Support

Purpose: borrow CCB's runtime-binding clarity while keeping v1 task-only.

- [ ] Add a failing test in `tests/agent-orch/runtime-binding.sh`.
- [ ] Assert `status` output includes:
  - `runtime_ref`
  - `session_ref`
  - `workspace_path`
  - `binding_status`
- [ ] For fixture worktree execution, expected values are:
  - `runtime_ref`: task id or deterministic `task:<task-id>`
  - `session_ref`: `null`
  - `workspace_path`: worktree path
  - `binding_status`: `partial`
- [ ] Do not introduce session lookup or session ids as v1 behavior.
- [ ] Update `agent_orch_write_status_json` and status rendering to include these fields.
- [ ] Update `collect` output only if it already echoes status metadata; otherwise leave `collect` focused on `report.json`.

Verify:

```bash
bash tests/agent-orch/runtime-binding.sh
```

Expected output:

```text
runtime-binding.sh: ok
```

Commit:

```bash
git add lib/agent-orch/task-store.sh tests/agent-orch/runtime-binding.sh
git commit -m "Record runtime binding fields"
```

### Task 3: Introduce Attempt Diagnostics While Preserving v1 Paths

Purpose: separate execution attempts from task identity so crash/missing-report diagnostics have a stable home.

- [ ] Add a failing test in `tests/agent-orch/attempts.sh`.
- [ ] Keep existing top-level compatibility artifacts:
  - `stdout.log`
  - `stderr.log`
  - `provider-result.json`
  - `report.json`
  - `report.raw` when available
- [ ] Add attempt-scoped artifacts under `attempts/1/`:
  - `stdout.log`
  - `stderr.log`
  - `provider-result.json`
  - `report.json` or synthetic report copy
  - `report.raw` when available
  - `progress.log` with wrapper lifecycle lines such as `starting`, `provider_running`, `finalizing`, and terminal status
- [ ] Ensure `provider-result.json` remains wrapper-owned diagnostic artifact.
- [ ] Add `phase` to `status.json`, using a small enum: `starting`, `running`, `finalizing`, `done`, `failed`.
- [ ] Keep `phase` diagnostic-only; do not add background polling semantics in v1.1.
- [ ] Ensure synthetic failed `report.json` references attempt diagnostics.
- [ ] Do not add retry scheduling in v1.1; this is only a state layout and diagnostics improvement.

Verify:

```bash
bash tests/agent-orch/attempts.sh
bash tests/agent-orch/collect-failure.sh
```

Expected output:

```text
attempts.sh: ok
collect-failure.sh: ok
```

Commit:

```bash
git add bin/agent-orch lib/agent-orch/launch.py lib/agent-orch/report.py tests/agent-orch/attempts.sh
git commit -m "Add attempt diagnostics"
```

### Task 4: Add Doctor And Bundle Diagnostics

Purpose: give Codex a cheap way to inspect a task or export failure evidence.

- [ ] Add a failing test in `tests/agent-orch/doctor.sh`.
- [ ] Add `agent-orch doctor --task-id <id> --repo <repo>`.
- [ ] Output a JSON summary with:
  - task id, status, worker, provider id, provider kind
  - mode, repo path, worktree path
  - runtime binding fields
  - phase and last four progress lines when available
  - report status and report path
  - provider-result summary
  - artifact existence booleans for stdout/stderr/report/report.raw/diffstat/attempts
- [ ] Add a `readiness` object to doctor output:
  - `provider_dir.exists`
  - `provider_manifest.valid`
  - `provider_command.executable`
  - `repo.valid_git_repo`
  - `worktree.exists`
- [ ] Readiness must be best-effort diagnostics. It must not install CLIs, authenticate tools, mutate git config, or create providers.
- [ ] Add `agent-orch doctor --task-id <id> --repo <repo> --bundle <path>`.
- [ ] Bundle can be a directory or `.tar.gz`; choose the smallest implementation that is deterministic and easy to test.
- [ ] Bundle must include diagnostic artifacts, not the full worktree.
- [ ] Missing optional artifacts must be reported as absent, not fail the command.

Verify:

```bash
bash tests/agent-orch/doctor.sh
```

Expected output:

```text
doctor.sh: ok
```

Commit:

```bash
git add bin/agent-orch lib/agent-orch/doctor.py tests/agent-orch/doctor.sh
git commit -m "Add task diagnostics command"
```

### Task 5: Update Skill Docs With Writing-Skills TDD

Purpose: teach Codex how to use the new contracts without turning the skill into a workflow dump.

- [ ] First edit `tests/agent-orch/skill-docs.sh` or add a focused skill validation test so it fails for the current skill docs.
- [ ] The failing validation must assert:
  - frontmatter contains only `name` and `description`
  - description starts with `Use when`
  - skill mentions fixture-provider-only v1.1
  - skill marks real Claude/OpenCode adapters follow-up-only
  - skill describes `doctor` as diagnostics, not scheduling authority
  - skill keeps sessions follow-up-only
  - skill requires Codex to preserve `collect`/`doctor` output evidence and not invent a substitute worker answer after failed, missing, or malformed output
  - skill describes compact status/result presentation rules: status can summarize, collect/result payloads must preserve worker report details
- [ ] Run the validation and confirm it fails before editing the skill.
- [ ] Update `skills/coordinating-local-agents/SKILL.md` and references to describe provider manifests, runtime binding fields, attempts, progress preview, doctor/bundle, and result-handling boundaries.
- [ ] Keep the skill concise and trigger-oriented; move detail into references.
- [ ] Re-run validation and confirm it passes.

Verify:

```bash
bash tests/agent-orch/skill-docs.sh
```

Expected red output before doc edits:

```text
missing expected skill contract: ...
```

Expected green output after doc edits:

```text
skill-docs.sh: ok
```

Commit:

```bash
git add tests/agent-orch/skill-docs.sh skills/coordinating-local-agents/SKILL.md skills/coordinating-local-agents/references
git commit -m "Document diagnostics-oriented orchestration contracts"
```

### Task 6: Refresh README And Full v1.1 Check

Purpose: make repo-level docs match the implemented short-term surface.

- [ ] Update `README.md` current status from active implementation to implemented v1 plus planned v1.1/v2 boundaries.
- [ ] Add examples for:
  - `agent-orch doctor --task-id <id> --repo <repo>`
  - `agent-orch doctor --task-id <id> --repo <repo> --bundle <path>`
- [ ] Add a scope note that provider manifests describe fixture providers in v1.1 and do not bless production CLI adapters.
- [ ] Add a note that v1.1 borrows setup/status/result contract ideas from `openai/codex-plugin-cc`, but not its plugin packaging, app-server bridge, auth setup, npm install flow, or background broker.
- [ ] Add new test scripts to `tests/agent-orch/run-all.sh`.
- [ ] Run the full test suite.

Verify:

```bash
bash tests/agent-orch/run-all.sh
```

Expected output includes:

```text
run-worktree.sh: ok
status.sh: ok
collect-success.sh: ok
collect-failure.sh: ok
cleanup.sh: ok
skill-docs.sh: ok
provider-boundary.sh: ok
provider-manifest.sh: ok
runtime-binding.sh: ok
attempts.sh: ok
doctor.sh: ok
```

Commit:

```bash
git add README.md tests/agent-orch/run-all.sh
git commit -m "Refresh v1.1 diagnostics documentation"
```

## Mid-Term Follow-Up Backlog

The items below are not part of this executable v1.1 plan. Convert each item into its own reviewed implementation plan before coding.

- Project agent config: add a zero-dependency `.agent-orch/agents.json` that maps explicit names such as `reviewer` to fixture providers only. `--agent` and `--worker` must be mutually exclusive, and Codex must still choose the named agent explicitly.
- Provider readiness checks: add `agent-orch provider check --provider <id> --repo <repo>` as a preflight diagnostics command. Fixture providers can pass; planned real providers must return `unsupported_provider` until pinned local CLI contracts exist.
- Real adapter contract spec: document the minimum future contract for Claude/OpenCode adapters, including non-interactive invocation form, working directory behavior, exit code contract, stdout/stderr behavior, report-writing behavior, timeout/signal behavior, authentication assumptions, and permission assumptions.
- Named-agent documentation: update README and skill references only after the config feature exists. Named agents are aliases over explicit worker selection, not autonomous routing.
- Task index and retention: add a versioned task index with deterministic repo scope and bounded index size. Do not auto-delete worktrees or reports without explicit cleanup flags.
- Background lifecycle: add background `run`, compact status listing, unambiguous short-id matching, `cancel`, and `resume` only after the synchronous v1.1 task model is stable.
- Review gate: consider an explicit opt-in review gate only as a monitored follow-up. It must warn about long-running loops and usage cost, and it must not be enabled by default.

## Final Verification

Run from repo root:

```bash
bash tests/agent-orch/run-all.sh
git status --short
```

Expected output:

```text
run-worktree.sh: ok
status.sh: ok
collect-success.sh: ok
collect-failure.sh: ok
cleanup.sh: ok
skill-docs.sh: ok
provider-boundary.sh: ok
provider-manifest.sh: ok
runtime-binding.sh: ok
attempts.sh: ok
doctor.sh: ok
```

`git status --short` should be clean after the final commit.

## Rollback Plan

- Revert each task commit independently if a later task exposes contract drift.
- If attempt paths break existing consumers, keep top-level compatibility artifacts as the source of truth and treat `attempts/1/` as optional diagnostics until fixed.
- If doctor/bundle output becomes too broad, revert Task 4 and keep Tasks 1-3 as the minimal v1.1 contract improvement.

## Open Decisions For Implementation

- Bundle format: directory copy is simplest and easiest to test; `.tar.gz` is more portable. Pick one in Task 4 and document it.
- `runtime_ref` exact string: use `task:<task-id>` unless existing naming conventions suggest a simpler task id field during implementation.
- Mid-term config format: prefer JSON for zero dependency when the follow-up config plan is written. TOML can be revisited only if the project accepts a Python-version requirement or dependency.
