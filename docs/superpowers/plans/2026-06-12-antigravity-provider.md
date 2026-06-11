# Antigravity Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a copy-ready Antigravity provider template backed by `agy --print`, with deterministic tests and skill guidance.

**Architecture:** Reuse the existing v2 provider-config and loop machinery. The target repo opts in by committing `.agent-orch/providers.json` and `.agent-orch/agy-run.sh`; `agent-orch` then runs the wrapper from the worker worktree. `agy-run.sh` owns the Antigravity-specific CLI contract, model selection, readiness sentinel, and conversion from `agy` output to `report.json`.

**Tech Stack:** Bash, Python 3 standard library, JSON provider config, git worktrees, existing `agent-orch` shell tests.

---

## Scope

This plan implements the approved design in `docs/superpowers/specs/2026-06-12-antigravity-provider-design.md`.

In scope:

- reusable Antigravity provider template
- `agy-run.sh` wrapper
- deterministic `fake-agy` fixture
- deterministic provider check + loop start test
- skill/README/routing docs
- docs assertions and default test-suite inclusion

Out of scope:

- automatic Antigravity auth
- browser auth flow
- new `plan` loop role
- direct Windows `antigravity` binary support
- automatic merge/integration
- optional real Antigravity smoke test

## File Structure

- Create `examples/antigravity/.agent-orch/providers.json`
  - Copy-ready provider config for target repos.
  - Defines provider id `antigravity`.
  - Points command template at `{workspace_path}/.agent-orch/agy-run.sh`.

- Create `examples/antigravity/.agent-orch/agy-run.sh`
  - Parses wrapper arguments.
  - Reads `prompt.md` and `task.json`.
  - Uses `AGENT_ORCH_ANTIGRAVITY_BIN:-agy`.
  - Uses `AGENT_ORCH_ANTIGRAVITY_MODEL:-Gemini 3.5 Flash (High)`.
  - Uses `AGY_OK` sentinel for readiness.
  - Writes `report.json`.

- Create `tests/fixtures/bin/fake-agy`
  - Deterministic fake backend for default tests.
  - Accepts `--print`, `--model`, and prompt argument.
  - Supports success and failure modes through env vars.
  - Records argv/prompt/model for test assertions.

- Create `tests/agent-orch/antigravity-template.sh`
  - Copies template into a temp repo.
  - Commits `.agent-orch` files to temp repo `HEAD`.
  - Runs `provider check`.
  - Runs one `loop start --role explore`.
  - Verifies readiness sentinel and completed report.

- Modify `tests/agent-orch/run-all.sh`
  - Add `antigravity-template.sh`.

- Modify `README.md`
  - Document copy-ready Antigravity setup and readiness command.

- Modify `skills/coordinating-local-agents/SKILL.md`
  - Document Antigravity provider usage and model guidance.

- Modify `skills/coordinating-local-agents/references/routing-guidelines.md`
  - Document Antigravity as explicit-config follow-up provider.

- Modify `tests/agent-orch/skill-docs.sh`
  - Assert Antigravity docs mention template files, readiness, auth fail-fast, model defaults, and planner guidance.

---

## Task 1: Antigravity Template And Deterministic Test

**Files:**
- Create: `examples/antigravity/.agent-orch/providers.json`
- Create: `examples/antigravity/.agent-orch/agy-run.sh`
- Create: `tests/fixtures/bin/fake-agy`
- Create: `tests/agent-orch/antigravity-template.sh`
- Modify: `tests/agent-orch/run-all.sh`

- [ ] **Step 1: Write the deterministic fake `agy` fixture**

Create `tests/fixtures/bin/fake-agy`:

```bash
#!/usr/bin/env bash
set -euo pipefail

mode="${FAKE_AGY_MODE:-success}"
model=""
prompt=""
print_mode="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --print|--prompt|-p)
      print_mode="true"
      shift
      ;;
    --model)
      [[ "$#" -ge 2 ]] || exit 2
      model="$2"
      shift 2
      ;;
    *)
      if [[ -z "${prompt}" ]]; then
        prompt="$1"
      else
        prompt="${prompt} $1"
      fi
      shift
      ;;
  esac
done

if [[ "${print_mode}" != "true" ]]; then
  printf 'fake agy expected --print\n' >&2
  exit 2
fi

if [[ -n "${FAKE_AGY_LOG:-}" ]]; then
  mkdir -p "$(dirname "${FAKE_AGY_LOG}")"
  {
    printf 'model=%s\n' "${model}"
    printf 'prompt=%s\n' "${prompt}"
  } >> "${FAKE_AGY_LOG}"
fi

case "${mode}" in
  bad-readiness)
    printf 'NOT_OK\n'
    exit 0
    ;;
  nonzero)
    printf 'fake agy failed\n' >&2
    exit 17
    ;;
esac

if [[ "${prompt}" == "Respond with exactly: AGY_OK" ]]; then
  printf 'AGY_OK\n'
else
  printf 'Fake Antigravity completed task for prompt: %s\n' "${prompt}"
fi
```

- [ ] **Step 2: Write the failing template test**

Create `tests/agent-orch/antigravity-template.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
CHECK_OUTPUT="${TEST_TMPDIR}/provider-check.json"
CHECK_LOG="${TEST_TMPDIR}/fake-agy-check.log"
START_OUTPUT="${TEST_TMPDIR}/loop-start.json"
START_LOG="${TEST_TMPDIR}/fake-agy-start.log"
BAD_OUT="${TEST_TMPDIR}/bad-readiness.out"
BAD_ERR="${TEST_TMPDIR}/bad-readiness.err"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-antigravity@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch antigravity"
cp -R "${ROOT_DIR}/examples/antigravity/.agent-orch" "${TMP_REPO}/.agent-orch"
printf '# Antigravity template fixture\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md .agent-orch
git -C "${TMP_REPO}" commit -qm "Initial antigravity fixture"

AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
AGENT_ORCH_ANTIGRAVITY_MODEL="Gemini 3.5 Flash (High)" \
FAKE_AGY_LOG="${CHECK_LOG}" \
PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" provider check \
  --provider antigravity \
  --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"

assert_json_value "${CHECK_OUTPUT}" "provider_id" "antigravity"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "config_path" "${TMP_REPO}/.agent-orch/providers.json"
assert_json_array_contains "${CHECK_OUTPUT}" "command_template" "{workspace_path}/.agent-orch/agy-run.sh"
assert_contains "${CHECK_LOG}" "model=Gemini 3.5 Flash (High)"
assert_contains "${CHECK_LOG}" "prompt=Respond with exactly: AGY_OK"

if AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
  FAKE_AGY_MODE="bad-readiness" \
  PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
    "${ROOT_DIR}/bin/agent-orch" provider check \
    --provider antigravity \
    --repo "${TMP_REPO}" > "${BAD_OUT}" 2> "${BAD_ERR}"; then
  printf 'expected bad readiness sentinel to fail\n' >&2
  exit 1
fi
assert_contains "${BAD_ERR}" '"error":"provider_not_ready"'

cat > "${TASK_FILE}" <<'EOF'
Explore README.md and summarize the repository.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The worker report completes without modifying files.
EOF

AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
AGENT_ORCH_ANTIGRAVITY_MODEL="Gemini 3.5 Flash (High)" \
FAKE_AGY_LOG="${START_LOG}" \
PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider antigravity \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${START_OUTPUT}"

assert_json_value "${START_OUTPUT}" "report_status" "completed"
assert_json_value "${START_OUTPUT}" "error_code" "None"
assert_contains "${START_LOG}" "model=Gemini 3.5 Flash (High)"
assert_contains "${START_LOG}" "Role: explore"

printf 'antigravity-template.sh: ok\n'
```

- [ ] **Step 3: Add the test to the default suite**

Modify `tests/agent-orch/run-all.sh`:

```bash
tests=(
  ...
  "opencode-template.sh"
  "antigravity-template.sh"
)
```

- [ ] **Step 4: Run the failing test**

Run:

```bash
bash tests/agent-orch/antigravity-template.sh
```

Expected: FAIL because `examples/antigravity/.agent-orch/` and/or `fake-agy` do not exist yet.

- [ ] **Step 5: Create the provider config template**

Create `examples/antigravity/.agent-orch/providers.json`:

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

- [ ] **Step 6: Create `agy-run.sh`**

Create `examples/antigravity/.agent-orch/agy-run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

prompt_file=""
task_json=""
workspace_path=""
report_path=""
task_dir=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --prompt-file)
      [[ "$#" -ge 2 ]] || exit 2
      prompt_file="$2"
      shift 2
      ;;
    --task-json)
      [[ "$#" -ge 2 ]] || exit 2
      task_json="$2"
      shift 2
      ;;
    --workspace-path)
      [[ "$#" -ge 2 ]] || exit 2
      workspace_path="$2"
      shift 2
      ;;
    --report|--report-path)
      [[ "$#" -ge 2 ]] || exit 2
      report_path="$2"
      shift 2
      ;;
    --task-dir)
      [[ "$#" -ge 2 ]] || exit 2
      task_dir="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${prompt_file}" || -z "${task_json}" || -z "${workspace_path}" || -z "${report_path}" || -z "${task_dir}" ]]; then
  printf 'missing required agy-run argument\n' >&2
  exit 2
fi

antigravity_bin="${AGENT_ORCH_ANTIGRAVITY_BIN:-agy}"
antigravity_model="${AGENT_ORCH_ANTIGRAVITY_MODEL:-Gemini 3.5 Flash (High)}"
mkdir -p "${task_dir}" "$(dirname "${report_path}")"

stdout_path="${task_dir}/agy.stdout"
stderr_path="${task_dir}/agy.stderr"
prompt_text="$(cat "${prompt_file}")"

readiness="false"
if python3 - "${task_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
raise SystemExit(0 if payload.get("task") == "provider readiness smoke" else 1)
PY
then
  readiness="true"
  prompt_text="Respond with exactly: AGY_OK"
fi

set +e
"${antigravity_bin}" --print --model "${antigravity_model}" "${prompt_text}" > "${stdout_path}" 2> "${stderr_path}"
agy_status="$?"
set -e

python3 - "${report_path}" "${prompt_file}" "${stdout_path}" "${stderr_path}" "${workspace_path}" "${agy_status}" "${readiness}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

report_path, prompt_file, stdout_path, stderr_path, workspace_path, status_text, readiness_text = sys.argv[1:]
exit_code = int(status_text)
readiness = readiness_text == "true"

prompt = Path(prompt_file).read_text(encoding="utf-8", errors="replace").strip()
stdout = Path(stdout_path).read_text(encoding="utf-8", errors="replace").strip()
stderr = Path(stderr_path).read_text(encoding="utf-8", errors="replace").strip()

changed_files = []
try:
    git_status = subprocess.run(
        ["git", "-C", workspace_path, "status", "--porcelain=v1", "--untracked-files=all"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    changed_files = [
        line[3:]
        for line in git_status.stdout.splitlines()
        if len(line) > 3 and line[3:]
    ]
except Exception:
    changed_files = []

ready_ok = readiness and exit_code == 0 and stdout.strip() == "AGY_OK"
if readiness and not ready_ok:
    status = "failed"
    error_code = "antigravity_not_ready"
    summary = "Antigravity readiness failed"
elif exit_code == 0:
    status = "completed"
    error_code = None
    summary_source = prompt.replace("\n", " ")
    if len(summary_source) > 180:
        summary_source = summary_source[:177] + "..."
    summary = f"Antigravity completed task: {summary_source}"
else:
    status = "failed"
    error_code = "antigravity_failed"
    summary = "Antigravity failed task"

payload = {
    "status": status,
    "summary": summary,
    "files_changed": changed_files,
    "tests_run": [],
    "open_questions": [],
    "risks": [] if status == "completed" else ["antigravity exited nonzero or failed readiness"],
    "notes": [
        f"agy_exit_code={exit_code}",
        f"stdout={stdout_path}",
        f"stderr={stderr_path}",
    ],
}
if stdout:
    payload["notes"].append("stdout preview: " + stdout[:500].replace("\n", " "))
if stderr:
    payload["notes"].append("stderr preview: " + stderr[:500].replace("\n", " "))
if error_code:
    payload["error_code"] = error_code

Path(report_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if [[ "${readiness}" == "true" ]]; then
  normalized="$(tr -d '\r' < "${stdout_path}" | sed -e 's/[[:space:]]*$//')"
  if [[ "${agy_status}" -ne 0 || "${normalized}" != "AGY_OK" ]]; then
    exit 1
  fi
fi

exit "${agy_status}"
```

- [ ] **Step 7: Set executable bits**

Run:

```bash
chmod +x examples/antigravity/.agent-orch/agy-run.sh tests/fixtures/bin/fake-agy tests/agent-orch/antigravity-template.sh
```

- [ ] **Step 8: Run the targeted test**

Run:

```bash
bash tests/agent-orch/antigravity-template.sh
```

Expected:

```text
antigravity-template.sh: ok
```

- [ ] **Step 9: Run the full suite**

Run:

```bash
bash tests/agent-orch/run-all.sh
```

Expected: all tests print `: ok`, including `antigravity-template.sh: ok`.

- [ ] **Step 10: Commit**

Run:

```bash
git add examples/antigravity/.agent-orch/providers.json \
  examples/antigravity/.agent-orch/agy-run.sh \
  tests/fixtures/bin/fake-agy \
  tests/agent-orch/antigravity-template.sh \
  tests/agent-orch/run-all.sh
git commit -m "Add Antigravity provider template"
```

---

## Task 2: Skill And README Guidance

**Files:**
- Modify: `README.md`
- Modify: `skills/coordinating-local-agents/SKILL.md`
- Modify: `skills/coordinating-local-agents/references/routing-guidelines.md`
- Modify: `tests/agent-orch/skill-docs.sh`

- [ ] **Step 1: Add failing docs assertions**

Modify `tests/agent-orch/skill-docs.sh` to assert:

```bash
assert_contains "${SKILL_MD}" "examples/antigravity/.agent-orch/providers.json"
assert_contains "${SKILL_MD}" "examples/antigravity/.agent-orch/agy-run.sh"
assert_contains "${SKILL_MD}" "agent-orch provider check --provider antigravity"
assert_contains "${SKILL_MD}" "Gemini 3.5 Flash (High)"
assert_contains "${SKILL_MD}" "AGENT_ORCH_ANTIGRAVITY_MODEL"
assert_contains "${SKILL_MD}" "Claude Opus 4.6 (Thinking)"
assert_contains "${SKILL_MD}" "planning helper"
assert_contains "${ROUTING_GUIDELINES}" "provider id is \`antigravity\`"
assert_contains "${ROUTING_GUIDELINES}" "authenticate \`agy\` manually"
assert_contains "${README}" "examples/antigravity/.agent-orch/providers.json"
assert_contains "${README}" "agent-orch provider check --provider antigravity"
assert_contains "${RUN_ALL}" "antigravity-template.sh"
```

- [ ] **Step 2: Run docs test to verify failure**

Run:

```bash
bash tests/agent-orch/skill-docs.sh
```

Expected: FAIL because Antigravity docs are not written yet.

- [ ] **Step 3: Update README**

Add a short Antigravity section after the OpenCode optional-provider instructions:

````markdown
Antigravity can be used through `agy` after explicit per-repo provider setup:

```bash
mkdir -p <repo>/.agent-orch
cp examples/antigravity/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/antigravity/.agent-orch/agy-run.sh <repo>/.agent-orch/agy-run.sh
git -C <repo> add .agent-orch/providers.json .agent-orch/agy-run.sh
git -C <repo> commit -m "Add Antigravity agent-orch provider config"
agent-orch provider check --provider antigravity --repo <repo>
```

The Antigravity template uses `AGENT_ORCH_ANTIGRAVITY_MODEL`, defaulting to `Gemini 3.5 Flash (High)`. Authenticate `agy` manually before readiness; `agent-orch` does not start auth flows.
````

- [ ] **Step 4: Update skill quick instructions**

Modify `skills/coordinating-local-agents/SKILL.md` under the v2 loop section:

````markdown
Antigravity is also available as an explicit-config provider template after `agy` is already authenticated:

```bash
mkdir -p <repo>/.agent-orch
cp examples/antigravity/.agent-orch/providers.json <repo>/.agent-orch/providers.json
cp examples/antigravity/.agent-orch/agy-run.sh <repo>/.agent-orch/agy-run.sh
git -C <repo> add .agent-orch/providers.json .agent-orch/agy-run.sh
git -C <repo> commit -m "Add Antigravity agent-orch provider config"
agent-orch provider check --provider antigravity --repo <repo>
```

Use `Gemini 3.5 Flash (High)` for Antigravity `explore` and `implement` by default; override with `AGENT_ORCH_ANTIGRAVITY_MODEL`. `Claude Opus 4.6 (Thinking)` is a planning helper for Codex, not an `agent-orch` loop role.
````

- [ ] **Step 5: Update routing guidelines**

Add an Antigravity subsection to `skills/coordinating-local-agents/references/routing-guidelines.md`:

```markdown
## Antigravity Provider Boundary

The provider id is `antigravity`; the backend CLI is `agy`. Use it only after copying and committing the explicit provider config into the target repo.

Run `agent-orch provider check --provider antigravity --repo <repo>` before dispatch. If readiness fails, authenticate `agy` manually and retry. The wrapper must not start auth, open a browser, or prompt for credentials.

Use `Gemini 3.5 Flash (High)` for `explore` and `implement` worker tasks by default. `Claude Opus 4.6 (Thinking)` can help Codex planning, but it is not a loop role.
```

- [ ] **Step 6: Run docs tests**

Run:

```bash
bash tests/agent-orch/skill-docs.sh
```

Expected:

```text
skill-docs.sh: ok
```

- [ ] **Step 7: Run focused provider docs/template tests**

Run:

```bash
bash tests/agent-orch/antigravity-template.sh
bash tests/agent-orch/opencode-template.sh
```

Expected:

```text
antigravity-template.sh: ok
opencode-template.sh: ok
```

- [ ] **Step 8: Commit**

Run:

```bash
git add README.md \
  skills/coordinating-local-agents/SKILL.md \
  skills/coordinating-local-agents/references/routing-guidelines.md \
  tests/agent-orch/skill-docs.sh
git commit -m "Document Antigravity provider usage"
```

---

## Task 3: Final Verification

**Files:**
- No intended source edits unless verification exposes a bug.

- [ ] **Step 1: Run full deterministic suite**

Run:

```bash
bash tests/agent-orch/run-all.sh
```

Expected: every test prints `: ok`, including:

```text
opencode-template.sh: ok
antigravity-template.sh: ok
```

- [ ] **Step 2: Run shell syntax checks**

Run:

```bash
bash -n bin/agent-orch lib/agent-orch/*.sh examples/opencode/.agent-orch/opencode-run.sh examples/antigravity/.agent-orch/agy-run.sh tests/agent-orch/*.sh tests/fixtures/bin/fake-agy tests/fixtures/bin/fake-opencode tests/test-helpers.sh scripts/install-skill.sh
```

Expected: no output and exit code `0`.

- [ ] **Step 3: Run Python compile checks**

Run:

```bash
python3 -m py_compile lib/agent-orch/*.py
```

Expected: no output and exit code `0`.

- [ ] **Step 4: Clean generated Python cache**

Run:

```bash
find . \( -name __pycache__ -o -name '*.pyc' -o -name '.DS_Store' \) -print -exec rm -rf {} +
find . \( -name __pycache__ -o -name '*.pyc' -o -name '.DS_Store' \) -print
```

Expected: first command may print removed cache paths; second command prints nothing.

- [ ] **Step 5: Check git status**

Run:

```bash
git status --short --branch
```

Expected: branch is clean after commits.

- [ ] **Step 6: Commit any verification fixes only if needed**

If verification required fixes, commit them:

```bash
git add <fixed-files>
git commit -m "Verify Antigravity provider template"
```

Expected: no commit is needed if Tasks 1 and 2 were correct.
