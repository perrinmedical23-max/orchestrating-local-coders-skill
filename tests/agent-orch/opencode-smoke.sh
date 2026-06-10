#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

if [[ "${AGENT_ORCH_REAL_OPENCODE:-}" != "1" ]]; then
  printf 'opencode-smoke.sh: skipped; set AGENT_ORCH_REAL_OPENCODE=1 to run real OpenCode smoke\n'
  exit 0
fi

if ! command -v opencode >/dev/null 2>&1; then
  printf 'opencode-smoke.sh: skipped; opencode not found on PATH\n'
  exit 0
fi

SOURCE_REPO="${AGENT_ORCH_OPENCODE_SMOKE_REPO:-${ROOT_DIR}}"
SOURCE_CONFIG="${SOURCE_REPO}/.agent-orch/providers.json"

if [[ ! -f "${SOURCE_CONFIG}" ]]; then
  printf 'opencode-smoke.sh: skipped; missing repo-local provider config: %s\n' "${SOURCE_CONFIG}"
  exit 0
fi

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
CHECK_OUTPUT="${TEST_TMPDIR}/provider-check.json"
START_OUTPUT="${TEST_TMPDIR}/loop-start.json"

mkdir -p "${TMP_REPO}/.agent-orch"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-smoke@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch smoke"
cp "${SOURCE_CONFIG}" "${TMP_REPO}/.agent-orch/providers.json"
printf '# OpenCode smoke fixture\n\nTemporary repository for agent-orch OpenCode smoke.\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md .agent-orch/providers.json
git -C "${TMP_REPO}" commit -qm "Initial smoke fixture"

"${ROOT_DIR}/bin/agent-orch" provider check \
  --provider opencode \
  --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"
assert_json_value "${CHECK_OUTPUT}" "provider_id" "opencode"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "config_path" "${TMP_REPO}/.agent-orch/providers.json"

cat > "${TASK_FILE}" <<'EOF'
Explore the temporary repository and summarize what README.md contains. Do not modify files.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The worker report exists and summarizes README.md without changing repository files.
EOF

"${ROOT_DIR}/bin/agent-orch" loop start \
  --provider opencode \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${START_OUTPUT}"

assert_json_value "${START_OUTPUT}" "state" "worker_collected"
assert_json_value "${START_OUTPUT}" "status" "worker_collected"
assert_json_value "${START_OUTPUT}" "current_iteration" "1"
assert_json_value "${START_OUTPUT}" "report_status" "completed"
assert_json_value "${START_OUTPUT}" "error_code" "None"

REPORT_PATH="$(python3 - "${START_OUTPUT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["report_path"])
PY
)"
assert_file_exists "${REPORT_PATH}"

python3 - "${START_OUTPUT}" "${REPORT_PATH}" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    report = json.load(handle)

if output.get("changed_files") != []:
    raise SystemExit(f"expected no changed_files in loop output, got {output.get('changed_files')}")

if report.get("status") != "completed":
    raise SystemExit(f"expected completed worker report, got {report.get('status')}")
if report.get("error_code"):
    raise SystemExit(f"expected no worker report error_code, got {report.get('error_code')}")
if "diagnostics" in report:
    raise SystemExit("expected real worker report without synthetic diagnostics")
if report.get("files_changed") != []:
    raise SystemExit(f"expected no report files_changed, got {report.get('files_changed')}")

summary = report.get("summary", "")
notes = report.get("notes", [])
if not isinstance(summary, str) or not isinstance(notes, list):
    raise SystemExit("expected report summary string and notes list")
combined = " ".join([summary, *[str(note) for note in notes]]).lower()
if not any(marker in combined for marker in ("readme", "explor", "temporary repository", "smoke fixture")):
    raise SystemExit("expected report summary or notes to mention README or the requested exploration")

workspace_audit_path = output.get("workspace_audit_path")
if not workspace_audit_path:
    raise SystemExit("expected workspace_audit_path in loop output")
with Path(workspace_audit_path).open("r", encoding="utf-8") as handle:
    audit = json.load(handle)
if audit.get("status") != "passed":
    raise SystemExit(f"expected workspace audit to pass, got {audit.get('status')}")
if audit.get("error_code"):
    raise SystemExit(f"expected no workspace audit error_code, got {audit.get('error_code')}")
if audit.get("worktree_diff") != []:
    raise SystemExit(f"expected clean worktree diff, got {audit.get('worktree_diff')}")
if audit.get("worktree_untracked") != []:
    raise SystemExit(f"expected no worktree untracked files, got {audit.get('worktree_untracked')}")
PY

STATUS_OUTPUT="$(git -C "${TMP_REPO}" status --porcelain=v1 --untracked-files=all)"
if [[ -n "${STATUS_OUTPUT}" ]]; then
  while IFS= read -r status_line; do
    status_path="${status_line:3}"
    case "${status_path}" in
      .superpowers/agent-orch/loops/*)
        ;;
      *)
        printf 'unexpected repository change after OpenCode smoke: %s\n' "${status_line}" >&2
        exit 1
        ;;
    esac
  done <<< "${STATUS_OUTPUT}"
fi

printf 'opencode-smoke.sh: ok\n'
