# Antigravity Provider Design

## Goal

Add a follow-up provider path that lets Codex delegate bounded local work to Antigravity through the `agy` CLI while keeping the existing `agent-orch` authority model:

- Codex remains planner, reviewer launcher, decision maker, and integrator.
- Antigravity is a worker provider only.
- Work runs in the wrapper-created git worktree.
- The provider returns evidence through `report.json`, stdout/stderr logs, and existing loop artifacts.

This design exists because `opencodego` is no longer the available OpenCode path on this machine. The usable local entrypoint is `agy`, which reports a headless `--print` mode and successfully returned from:

```bash
agy --print "Respond with exactly: AGY_OK"
```

The Windows `antigravity` binary is not the provider entrypoint for this design. In WSL it resolved to a Windows Electron binary and failed with a V8 snapshot mismatch during `antigravity --help`, so it is not a reliable headless contract.

## Non-Goals

- No automatic Antigravity authentication.
- No browser-driven auth flow in `agent-orch`.
- No new loop role such as `plan`.
- No automatic merge, cherry-pick, push, or integration.
- No direct dependency on the Windows `antigravity` executable.
- No replacement of the existing OpenCode template in this change.

## Provider Identity

The provider id is:

```text
antigravity
```

The implementation uses `agy` as the command-line backend. The name `antigravity` is used at the skill and `agent-orch` provider layer because that is the worker concept Codex is routing to; `agy` is an implementation detail.

Supported loop roles remain the existing v2 roles:

- `explore`
- `implement`

Planner support is documentation-only in this design. `Claude Opus 4.6 (Thinking)` may be recommended as a planning helper for Codex, but it does not become an `agent-orch loop start --role plan` role.

## Model Routing

The Antigravity worker template should default to:

```text
Gemini 3.5 Flash (High)
```

The default must be overridable with:

```bash
AGENT_ORCH_ANTIGRAVITY_MODEL="<model name>"
```

Recommended routing guidance:

- Use `Gemini 3.5 Flash (High)` for Antigravity `explore` and `implement` worker tasks.
- Use `Claude Opus 4.6 (Thinking)` as a manual/planning helper for Codex when higher-level decomposition is useful.
- Do not add a planner role to the loop state machine for this provider.

## Auth And Readiness

Authentication is fail-fast.

`agent-orch provider check --provider antigravity --repo <repo>` should only pass when the configured command can run non-interactively. If `agy` is missing, not authenticated, prompts for auth, times out, or requires an interactive session, readiness fails with the existing provider-not-ready path.

The wrapper must not:

- start an auth flow
- open a browser
- prompt for credentials
- block waiting for user input
- silently continue after auth failure

The expected user action is to authenticate `agy` outside `agent-orch`, then retry provider readiness.

## Template Files

Add a reusable explicit provider template:

```text
examples/antigravity/.agent-orch/providers.json
examples/antigravity/.agent-orch/agy-run.sh
```

The template is copy-ready, not auto-enabled. Users install it per target repository:

```bash
mkdir -p <repo>/.agent-orch
cp examples/antigravity/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/antigravity/.agent-orch/agy-run.sh <repo>/.agent-orch/agy-run.sh
git -C <repo> add .agent-orch/providers.json .agent-orch/agy-run.sh
git -C <repo> commit -m "Add Antigravity agent-orch provider config"
```

This preserves the explicit provider config contract. A target repo opts in by owning its `.agent-orch/providers.json`.

The copied files must be present in the target repo `HEAD` before readiness or loop execution. `agent-orch provider check` and `agent-orch loop start` create temporary git worktrees from `HEAD`; if `.agent-orch/agy-run.sh` is only an uncommitted working-tree file, it will not exist at `{workspace_path}/.agent-orch/agy-run.sh`.

## Provider Config Shape

The Antigravity template uses the existing provider schema:

```json
{
  "schema_version": 1,
  "providers": {
    "antigravity": {
      "provider_id": "antigravity",
      "provider_kind": "external_cli",
      "supported_roles": ["explore", "implement"],
      "command_template": [
        "bash",
        "{workspace_path}/.agent-orch/agy-run.sh",
        "--prompt-file",
        "{prompt_file}",
        "--task-json",
        "{task_json}",
        "--workspace-path",
        "{workspace_path}",
        "--report",
        "{report_path}",
        "--task-dir",
        "{task_dir}"
      ],
      "capabilities": {
        "worktree": true,
        "writes_report": true,
        "supports_readonly": true,
        "supports_timeout": true
      }
    }
  }
}
```

The wrapper script is committed into the target repo and therefore exists inside the worker worktree at:

```text
{workspace_path}/.agent-orch/agy-run.sh
```

## `agy-run.sh` Contract

`agy-run.sh` accepts the same wrapper arguments as the OpenCode template:

```bash
agy-run.sh \
  --prompt-file <prompt.md> \
  --task-json <task.json> \
  --workspace-path <worktree> \
  --report <report.json> \
  --task-dir <iteration-dir>
```

It invokes `agy` in headless mode through the configurable binary variable:

```bash
antigravity_bin="${AGENT_ORCH_ANTIGRAVITY_BIN:-agy}"
antigravity_model="${AGENT_ORCH_ANTIGRAVITY_MODEL:-Gemini 3.5 Flash (High)}"
"${antigravity_bin}" --print --model "${antigravity_model}" "${prompt_text}"
```

The prompt is passed as the `--print` argument. Do not use an unspecified stdin contract for the initial implementation; the pinned local evidence is argument-form `agy --print`.

Readiness must be mechanically testable. During provider readiness, `task_json` contains the existing wrapper readiness marker:

```json
{"task": "provider readiness smoke"}
```

When `agy-run.sh` sees this readiness marker, it must ignore the generic readiness prompt and call `agy` with:

```text
Respond with exactly: AGY_OK
```

Readiness succeeds only if `agy` exits `0` and normalized stdout is exactly:

```text
AGY_OK
```

Any other output, timeout, auth prompt, interactive prompt, or nonzero exit produces a failed report with `error_code: antigravity_not_ready` or `antigravity_failed` and the wrapper exits nonzero for the readiness invocation. This lets `provider check` fail rather than treating arbitrary zero-exit output as readiness.

The script owns conversion from `agy` output to `report.json`:

- for normal worker tasks, exit code `0` produces a `completed` report
- for normal worker tasks, nonzero exit produces a `failed` report with `error_code: antigravity_failed`
- stdout/stderr previews are recorded in report notes
- changed files are collected from `git status --porcelain` inside `workspace_path`

The script should support a test override:

```bash
AGENT_ORCH_ANTIGRAVITY_BIN=<path-or-command>
```

Default:

```bash
AGENT_ORCH_ANTIGRAVITY_BIN=agy
```

This lets deterministic tests exercise the template with a fake `agy` binary without requiring real Antigravity auth.

## Skill Guidance

The `coordinating-local-agents` skill should document Antigravity as a follow-up real provider template, not as a default route.

Skill guidance should say:

- use `antigravity` only after explicit provider config is copied into the target repo
- run `agent-orch provider check --provider antigravity --repo <repo>` before dispatch
- if readiness fails, authenticate `agy` manually and retry
- use `Gemini 3.5 Flash (High)` for `explore` and `implement`
- consider `Claude Opus 4.6 (Thinking)` for Codex-side planning, but do not dispatch it as a loop role

## Testing

Add deterministic tests that do not require real Antigravity auth:

```text
tests/fixtures/bin/fake-agy
tests/agent-orch/antigravity-template.sh
```

The test should:

1. Create a temporary git repo.
2. Copy `examples/antigravity/.agent-orch/` into the temp repo.
3. Commit `.agent-orch/providers.json` and `.agent-orch/agy-run.sh` into the temp repo so worktrees created from `HEAD` contain the wrapper.
4. Put `fake-agy` on `PATH` or set `AGENT_ORCH_ANTIGRAVITY_BIN=fake-agy`.
5. Run `agent-orch provider check --provider antigravity --repo <tmp-repo>`.
6. Assert readiness used the `AGY_OK` sentinel path.
7. Run one `loop start --provider antigravity --role explore`.
8. Assert `report_status == completed`.
9. Assert no default test requires real `agy` auth.

Optional real smoke can be added later, but it must be opt-in and skip clearly unless an explicit env var is set.

## Acceptance Criteria

- A target repo can opt into Antigravity by copying the template files into `.agent-orch/`.
- The copied provider config and wrapper are committed into target repo `HEAD` before readiness and worker execution.
- `agent-orch provider check --provider antigravity` validates the copied config and fails fast when `agy` is missing, unauthenticated, interactive, or timed out.
- Provider readiness is not satisfied by arbitrary zero-exit output; the wrapper verifies the `AGY_OK` sentinel during readiness.
- `agent-orch loop start --provider antigravity --role explore|implement` uses the existing v2 loop flow without adding new states or roles.
- The default test suite remains deterministic and does not require real Antigravity auth.
- Skill docs clearly distinguish worker execution from Codex-owned planning, review, and integration.
