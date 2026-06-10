# V2 Orchestration Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Codex-led v2 orchestration loop where Codex dispatches OpenCode explore/implement work, records loop iterations, ingests Codex-owned reviewer outputs, and supports a bounded auto-fix continuation path.

**Architecture:** Extend the existing `agent-orch` Bash CLI with focused Python helpers for provider config/readiness, loop state, external command execution, review validation, and deterministic decisioning. Keep v1.1 `run/status/collect/cleanup/doctor` behavior intact; v2 uses new `agent-orch provider ...` and `agent-orch loop ...` commands.

**Tech Stack:** Bash CLI wrapper, Python 3 standard library helpers, git worktrees, JSON state artifacts, deterministic shell tests with fake OpenCode/reviewer fixtures.

---

## Scope

Implement the v2 MVP from [V2 Orchestration Loop Design](../specs/2026-06-10-v2-orchestration-loop-design.md):

- Multi-provider contract schema pinned at `.agent-orch/providers.json`.
- Real-provider MVP shape for OpenCode through explicit command templates.
- Default tests use fake `opencode`; no default test requires real OpenCode.
- Roles: `explore` and `implement`.
- Manual gate default.
- Optional `--auto-fix --max-iterations <n>`.
- Reviewer ingestion through `agent-orch loop review`; Codex launches actual runtime reviewers outside the wrapper.
- Claude Code and Antigravity remain contract-only follow-up providers.

Do not add daemon mode, tmux, mailbox, autonomous routing, real Claude Code adapter, real Antigravity adapter, or automatic merge/integration.

## File Map

Create:

- `lib/agent-orch/provider_config.py`: load and validate `.agent-orch/providers.json`, normalize command templates, run readiness checks.
- `lib/agent-orch/loop_store.py`: create/read/update loop state and iteration paths.
- `lib/agent-orch/external_cli.py`: render command templates, create prompt files, launch external CLI providers.
- `lib/agent-orch/review.py`: validate correctness/integration reviewer JSON and normalize malformed output.
- `lib/agent-orch/loop_decide.py`: deterministic review decisioning, next task generation, max-iteration/repeated-blocker handling.
- `tests/fixtures/bin/fake-opencode`: fake OpenCode executable used by default tests.
- `tests/fixtures/reviews/correctness-passed.json`
- `tests/fixtures/reviews/integration-passed.json`
- `tests/fixtures/reviews/correctness-blocked.json`
- `tests/fixtures/reviews/integration-blocked.json`
- `tests/fixtures/reviews/correctness-needs-human.json`
- `tests/fixtures/reviews/malformed-review.txt`
- `tests/agent-orch/provider-config.sh`
- `tests/agent-orch/loop-start.sh`
- `tests/agent-orch/loop-review.sh`
- `tests/agent-orch/loop-decide.sh`
- `tests/agent-orch/loop-auto-fix.sh`
- `tests/agent-orch/opencode-smoke.sh` optional, not added to `run-all.sh`.

Modify:

- `bin/agent-orch`: add `provider check`, `loop start`, `loop continue`, `loop status`, `loop collect`, `loop review`, and `loop decide`.
- `lib/agent-orch/task-store.sh`: reuse task id/repo/task-dir utilities where possible; do not change v1.1 status/collect contracts.
- `lib/agent-orch/worktree.sh`: reuse worktree creation/removal; no semantic change unless a tiny helper is needed.
- `tests/test-helpers.sh`: add helpers for fake provider config, fake OpenCode path, and JSON assertions for arrays.
- `tests/agent-orch/run-all.sh`: add deterministic v2 tests, not optional real OpenCode smoke.
- `skills/coordinating-local-agents/SKILL.md`: document v2 loop usage after tests fail first.
- `skills/coordinating-local-agents/references/task-contract.md`: add v2 role and loop fields.
- `skills/coordinating-local-agents/references/routing-guidelines.md`: document OpenCode MVP and follow-up provider boundary.
- `skills/coordinating-local-agents/references/result-handling.md`: add reviewer output handling and manual gate rules.
- `README.md`: add v2 command examples and default/optional test commands.

## Task 1: Provider Config And Readiness

**Files:**
- Create: `lib/agent-orch/provider_config.py`
- Create: `tests/agent-orch/provider-config.sh`
- Create: `tests/fixtures/bin/fake-opencode`
- Modify: `bin/agent-orch`
- Modify: `tests/test-helpers.sh`

- [ ] **Step 1: Write failing provider config test**

Create `tests/agent-orch/provider-config.sh` that:

- creates a temp git repo
- writes `.agent-orch/providers.json`
- creates `tests/fixtures/bin/fake-opencode` on `PATH`
- runs `agent-orch provider check --provider opencode --repo <repo>`
- asserts normalized readiness JSON includes:
  - `provider_id: "opencode"`
  - `provider_kind: "external_cli"`
  - `supported_roles: ["explore","implement"]`
  - `ready: true`
  - `config_path`
  - `command_template`
- asserts missing config returns `provider_config_missing`
- asserts invalid placeholder returns `provider_config_invalid`
- asserts unknown provider returns `unknown_provider`
- asserts missing executable returns `provider_not_ready`
- asserts fake interactive-only executable returns `provider_not_ready`
- asserts fake readiness nonzero executable returns `provider_not_ready`
- asserts readiness creates a temporary worktree smoke run and records `readiness.temp_worktree`
- asserts readiness verifies report production or wrapper finalization and records `readiness.report_finalization`

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/provider-config.sh
```

Expected: fail with `unknown_command` or missing `provider check`.

- [ ] **Step 3: Implement provider config loader**

Create `lib/agent-orch/provider_config.py` with subcommands:

```bash
python3 lib/agent-orch/provider_config.py check --provider opencode --repo <repo>
python3 lib/agent-orch/provider_config.py render --provider opencode --repo <repo> --prompt-file <path> --task-dir <path> --task-json <path> --workspace-path <path> --report-path <path>
```

Validation rules:

- config path is exactly `<repo>/.agent-orch/providers.json`
- `schema_version` must be `1`
- provider id must match key and requested provider
- `provider_kind` must be `external_cli`
- OpenCode MVP must include both `explore` and `implement`
- `command_template` must be an array of strings
- allowed placeholders: `{prompt_file}`, `{task_dir}`, `{task_json}`, `{workspace_path}`, `{report_path}`
- `capabilities` values must be booleans

Readiness rules:

- resolve executable from rendered command arg 0 using `PATH`
- fail `provider_not_ready` if executable is missing or not executable
- run a smoke invocation in a temporary worktree
- run smoke without allocating a TTY
- fail `provider_not_ready` if the smoke command reports interactive-only behavior
- fail `provider_not_ready` if the smoke command exits with nondeterministic or unsupported status
- verify the smoke run can produce `report.json` or that wrapper finalization can synthesize a failed report
- include machine-readable readiness fields for executable, template, temp worktree, non-interactive behavior, exit behavior, and report finalization

- [ ] **Step 4: Wire `agent-orch provider check`**

In `bin/agent-orch`, add:

```bash
agent-orch provider check --provider opencode --repo <repo>
```

It should resolve the repo and call `provider_config.py check`.

- [ ] **Step 5: Verify provider config test passes**

Run:

```bash
bash tests/agent-orch/provider-config.sh
```

Expected:

```text
provider-config.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/provider_config.py tests/test-helpers.sh tests/agent-orch/provider-config.sh tests/fixtures/bin/fake-opencode
git commit -m "Add external provider config readiness"
```

## Task 2: Loop State Store And CLI Skeleton

**Files:**
- Create: `lib/agent-orch/loop_store.py`
- Create: `tests/agent-orch/loop-start.sh`
- Modify: `bin/agent-orch`

- [ ] **Step 1: Write failing loop start/status test**

Create `tests/agent-orch/loop-start.sh` that starts a loop in skeleton mode with fake provider config available:

```bash
agent-orch loop start --provider opencode --role implement --repo "${TMP_REPO}" --task-file "${TASK_FILE}" --acceptance-file "${ACCEPTANCE_FILE}"
```

Assert output includes:

- `loop_id`
- `status: "created"` or `state: "created"` before Task 3 wires worker execution
- `current_iteration: 1`
- `loop_dir`

Assert files exist:

```text
.superpowers/agent-orch/loops/<loop-id>/loop.json
.superpowers/agent-orch/loops/<loop-id>/iterations/1/task.json
```

Also assert:

```bash
agent-orch loop status --loop-id <id> --repo <repo>
agent-orch loop collect --loop-id <id> --repo <repo>
```

return machine-readable JSON.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-start.sh
```

Expected: fail with missing `loop` command.

- [ ] **Step 3: Implement loop store**

Create `lib/agent-orch/loop_store.py` with subcommands:

```bash
create --repo <repo> --provider <provider> --role <role> --task-file <path> --acceptance-file <path> [--auto-fix --max-iterations <n>]
status --loop-dir <path>
collect --loop-dir <path>
set-state --loop-dir <path> --state <state>
```

State root:

```text
<repo>/.superpowers/agent-orch/loops/<loop-id>
```

`loop.json` must include:

- `schema_version: 1`
- `loop_id`
- `provider`
- `role`
- `state`
- `current_iteration`
- `auto_fix`
- `max_iterations`
- `created_at`
- `updated_at`
- `repo_path`

- [ ] **Step 4: Wire CLI skeleton**

Add:

```bash
agent-orch loop start ...
agent-orch loop status ...
agent-orch loop collect ...
```

At this stage, `loop start` creates loop state and iteration task artifacts only. It does not launch the external CLI until Task 3.

- [ ] **Step 5: Verify loop state test passes**

Run:

```bash
bash tests/agent-orch/loop-start.sh
```

Expected:

```text
loop-start.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/loop_store.py tests/agent-orch/loop-start.sh
git commit -m "Add loop state commands"
```

## Task 3: External CLI Execution For Explore And Implement

**Files:**
- Create: `lib/agent-orch/external_cli.py`
- Modify: `bin/agent-orch`
- Modify: `tests/fixtures/bin/fake-opencode`
- Modify: `tests/agent-orch/loop-start.sh`

- [ ] **Step 1: Extend failing test for both roles**

In `loop-start.sh`, add:

```bash
agent-orch loop start --provider opencode --role explore ...
agent-orch loop start --provider opencode --role implement ...
```

Assert:

- explore report status is `completed`
- explore has no changed files
- implement can produce changed files
- both roles write `prompt.md`, `task.json`, `report.json`, stdout/stderr, provider-result
- `loop start` state advances from `created` to `worker_collected` after worker execution

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-start.sh
```

Expected: fail until external CLI execution is implemented.

- [ ] **Step 3: Implement template rendering and launch**

Create `lib/agent-orch/external_cli.py`:

- render command template using provider config
- write a role-specific prompt file
- run command with cwd set to `workspace_path`
- capture stdout/stderr/provider-result
- enforce timeout via existing `launch.py` or shared logic
- finalize missing/invalid reports using existing `report.py`

Prompt must include:

- role
- task statement
- acceptance criteria
- workspace path
- report path
- constraints: no merge/cherry-pick/push, no main checkout edits

- [ ] **Step 4: Wire `loop start` execution**

`loop start` should:

- create loop state
- create iteration 1
- create worktree
- run external CLI
- finalize report
- update loop state to `worker_collected` or `failed`

- [ ] **Step 5: Verify role execution**

Run:

```bash
bash tests/agent-orch/loop-start.sh
```

Expected:

```text
loop-start.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/external_cli.py tests/fixtures/bin/fake-opencode tests/agent-orch/loop-start.sh
git commit -m "Run OpenCode command templates in loops"
```

## Task 4: Reviewer Ingestion

**Files:**
- Create: `lib/agent-orch/review.py`
- Create: `tests/agent-orch/loop-review.sh`
- Create: `tests/fixtures/reviews/*.json`
- Modify: `bin/agent-orch`

- [ ] **Step 1: Write failing review ingestion test**

Create `loop-review.sh` that:

- starts a loop
- records `correctness-passed.json`
- records `integration-passed.json`
- asserts files live under `iterations/1/reviews/`
- records malformed review text
- asserts `.raw` is preserved and normalized JSON has `status: "needs_human"`
- asserts invalid reviewer id fails

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-review.sh
```

Expected: fail with missing `loop review`.

- [ ] **Step 3: Implement review validation**

Create `lib/agent-orch/review.py`:

- accepts reviewer id `correctness|integration`
- validates JSON shape
- validates `status: passed|blocked|needs_human`
- validates arrays exist
- saves valid review to `iterations/<n>/reviews/<reviewer>.json`
- saves malformed input to `<reviewer>.raw`
- writes normalized `needs_human` review JSON for malformed input

- [ ] **Step 4: Wire `agent-orch loop review`**

Add:

```bash
agent-orch loop review --loop-id <id> --repo <repo> --reviewer correctness|integration --review-file <path>
```

- [ ] **Step 5: Verify review ingestion**

Run:

```bash
bash tests/agent-orch/loop-review.sh
```

Expected:

```text
loop-review.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/review.py tests/agent-orch/loop-review.sh tests/fixtures/reviews
git commit -m "Add loop reviewer ingestion"
```

## Task 5: Decision Engine And Manual Gate

**Files:**
- Create: `lib/agent-orch/loop_decide.py`
- Create: `tests/agent-orch/loop-decide.sh`
- Modify: `bin/agent-orch`

- [ ] **Step 1: Write failing decision test**

Create `loop-decide.sh` covering:

- both reviewers passed => loop state `completed`
- one reviewer blocked with no auto-fix => loop state `manual_gate`
- reviewer `needs_human` => loop state `manual_gate`
- missing reviewer => `review_missing`
- malformed reviewer normalized as `needs_human` => `manual_gate`

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-decide.sh
```

Expected: fail with missing `loop decide`.

- [ ] **Step 3: Implement deterministic decisioning**

Create `lib/agent-orch/loop_decide.py`:

- reads `loop.json`
- reads current iteration report
- reads both review JSON files
- applies state transitions
- writes `decision.json`
- updates `loop.json`

Decision output should include:

- `loop_id`
- `state`
- `current_iteration`
- `decision`
- `blocking_reviewers`
- `next_task_path` when generated

- [ ] **Step 4: Wire `agent-orch loop decide`**

Add:

```bash
agent-orch loop decide --loop-id <id> --repo <repo>
```

- [ ] **Step 5: Verify decisioning**

Run:

```bash
bash tests/agent-orch/loop-decide.sh
```

Expected:

```text
loop-decide.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/loop_decide.py tests/agent-orch/loop-decide.sh
git commit -m "Add loop decision engine"
```

## Task 6: Bounded Auto-Fix And Loop Continue

**Files:**
- Create: `tests/agent-orch/loop-auto-fix.sh`
- Modify: `bin/agent-orch`
- Modify: `lib/agent-orch/loop_store.py`
- Modify: `lib/agent-orch/loop_decide.py`
- Modify: `lib/agent-orch/external_cli.py`

- [ ] **Step 1: Write failing auto-fix test**

Create `loop-auto-fix.sh` covering:

- `--auto-fix` without `--max-iterations` fails
- blocked reviews with auto-fix generate `next_task.json`
- `loop continue --loop-id <id>` runs iteration 2
- continuing without auto-fix fails `auto_fix_not_enabled`
- exceeding max iterations fails `max_iterations_reached`
- repeated blocker stops with `repeated_blocker`

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-auto-fix.sh
```

Expected: fail with missing `loop continue` or missing auto-fix behavior.

- [ ] **Step 3: Implement auto-fix options**

`loop start` must:

- accept `--auto-fix`
- require `--max-iterations <n>`
- store both in `loop.json`

`loop decide` must:

- generate `next_task.json` only when auto-fix is enabled, blockers exist, no reviewer is `needs_human`, and max iterations remain
- make `next_task.json` narrower than original by including blocker summaries and original acceptance criteria

- [ ] **Step 4: Implement `loop continue`**

`loop continue` must:

- require existing `next_task.json`
- create next iteration directory
- run provider with same provider and role unless `next_task.json` overrides role
- clear or archive consumed `next_task.json`
- update `current_iteration`

- [ ] **Step 5: Verify auto-fix loop**

Run:

```bash
bash tests/agent-orch/loop-auto-fix.sh
```

Expected:

```text
loop-auto-fix.sh: ok
```

- [ ] **Step 6: Commit**

```bash
git add bin/agent-orch lib/agent-orch/loop_store.py lib/agent-orch/loop_decide.py lib/agent-orch/external_cli.py tests/agent-orch/loop-auto-fix.sh
git commit -m "Add bounded loop continuation"
```

## Task 7: Workspace Violation And Failure Finalization

**Files:**
- Create: `tests/agent-orch/loop-failure.sh`
- Modify: `lib/agent-orch/external_cli.py`
- Modify: `lib/agent-orch/loop_decide.py`
- Modify: `bin/agent-orch`

- [ ] **Step 1: Write failing failure test**

Create `loop-failure.sh` covering:

- readiness fail => `provider_not_ready`, no worker launch
- missing report => synthetic failed report
- invalid report => raw output preserved
- nonzero worker with valid `partial` report => preserve worker report and status `partial`
- nonzero worker with valid `failed` report => preserve worker report and status `failed`
- nonzero worker with valid `completed` report => replace with synthetic failed report
- reviewer malformed => `needs_human`
- workspace violation => `workspace_violation`, no auto-fix
- every failure output includes machine-readable `error_code`
- every failure output includes relevant artifact paths, including report, stdout, stderr, provider-result, raw review/report when available, and loop/iteration directory

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/agent-orch/loop-failure.sh
```

Expected: fail until failure handling is complete.

- [ ] **Step 3: Implement workspace audit**

Post-run audit should compare allowed worktree paths and ensure no known coordinator checkout paths were modified. Keep this simple and deterministic:

- inspect git status in coordinator repo before/after when possible
- inspect worktree diff separately
- if coordinator checkout changed, mark `workspace_violation`

- [ ] **Step 4: Verify failure handling**

Run:

```bash
bash tests/agent-orch/loop-failure.sh
```

Expected:

```text
loop-failure.sh: ok
```

- [ ] **Step 5: Commit**

```bash
git add bin/agent-orch lib/agent-orch/external_cli.py lib/agent-orch/loop_decide.py tests/agent-orch/loop-failure.sh
git commit -m "Harden loop failure handling"
```

## Task 8: Skill And README Documentation

**Files:**
- Modify: `tests/agent-orch/skill-docs.sh`
- Modify: `skills/coordinating-local-agents/SKILL.md`
- Modify: `skills/coordinating-local-agents/references/task-contract.md`
- Modify: `skills/coordinating-local-agents/references/routing-guidelines.md`
- Modify: `skills/coordinating-local-agents/references/result-handling.md`
- Modify: `README.md`

- [ ] **Step 1: Extend skill docs validation first**

Update `tests/agent-orch/skill-docs.sh` to fail until docs mention:

- `agent-orch provider check`
- `agent-orch loop start`
- `agent-orch loop review`
- `agent-orch loop decide`
- OpenCode MVP only
- Claude Code and Antigravity follow-up only
- manual gate default
- explicit `--auto-fix --max-iterations`
- no automatic merge/integration

- [ ] **Step 2: Run validation to confirm failure**

Run:

```bash
bash tests/agent-orch/skill-docs.sh
```

Expected: fail with missing v2 loop docs.

- [ ] **Step 3: Update docs**

Keep `SKILL.md` concise. Put detailed command examples and result handling in references.

- [ ] **Step 4: Verify docs**

Run:

```bash
bash tests/agent-orch/skill-docs.sh
```

Expected:

```text
skill-docs.sh: ok
```

- [ ] **Step 5: Commit**

```bash
git add README.md tests/agent-orch/skill-docs.sh skills/coordinating-local-agents
git commit -m "Document v2 orchestration loop"
```

## Task 9: Full Suite And Optional Smoke

**Files:**
- Modify: `tests/agent-orch/run-all.sh`
- Create: `tests/agent-orch/opencode-smoke.sh`

- [ ] **Step 1: Add deterministic v2 tests to run-all**

Add these tests:

```text
provider-config.sh
loop-start.sh
loop-review.sh
loop-decide.sh
loop-auto-fix.sh
loop-failure.sh
```

Do not add `opencode-smoke.sh` to `run-all.sh`.

- [ ] **Step 2: Create optional real OpenCode smoke**

`opencode-smoke.sh` should:

- require explicit env var such as `AGENT_ORCH_REAL_OPENCODE=1`
- skip with a clear message otherwise
- require a repo-local `.agent-orch/providers.json`
- run `agent-orch provider check --provider opencode`
- run one tiny `explore` task

- [ ] **Step 3: Run full verification**

Run:

```bash
bash tests/agent-orch/run-all.sh
bash -n bin/agent-orch lib/agent-orch/*.sh tests/agent-orch/*.sh tests/test-helpers.sh scripts/install-skill.sh
python3 -m py_compile lib/agent-orch/*.py
find . -name __pycache__ -o -name '*.pyc' -o -name '.DS_Store'
```

Expected:

- all tests print `: ok`
- syntax checks pass
- `find` prints nothing after cleanup

- [ ] **Step 4: Commit**

```bash
git add tests/agent-orch/run-all.sh tests/agent-orch/opencode-smoke.sh
git commit -m "Verify v2 orchestration loop suite"
```

## Final Verification

Run:

```bash
bash tests/agent-orch/run-all.sh
git status --short
```

Expected:

- full deterministic suite passes without real OpenCode
- working tree is clean after commits

## Execution Notes

- Keep commits task-scoped.
- Do not implement real Claude Code or Antigravity adapters.
- Do not add background execution unless explicitly split into a later plan.
- Do not let `loop decide` invoke Codex subagents; Codex runtime owns subagent launch.
- Preserve v1.1 command behavior and tests throughout.
