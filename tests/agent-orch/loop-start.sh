#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
START_OUTPUT="${TEST_TMPDIR}/loop-start-output.json"
STATUS_OUTPUT="${TEST_TMPDIR}/loop-status-output.json"
COLLECT_OUTPUT="${TEST_TMPDIR}/loop-collect-output.json"
EXPLORE_OUTPUT="${TEST_TMPDIR}/loop-explore-output.json"
EXPLORE_STATUS_OUTPUT="${TEST_TMPDIR}/loop-explore-status-output.json"
EXPLORE_COLLECT_OUTPUT="${TEST_TMPDIR}/loop-explore-collect-output.json"
MISSING_REPO="${TEST_TMPDIR}/missing-repo"
NON_GIT_REPO="${TEST_TMPDIR}/non-git"
BIN_DIR="${ROOT_DIR}/tests/fixtures/bin"
UNSUPPORTED_REPO="${TEST_TMPDIR}/unsupported-role-repo"
UNSUPPORTED_ERR="${TEST_TMPDIR}/unsupported-role.err"
UNSUPPORTED_OUT="${TEST_TMPDIR}/unsupported-role.out"
WORKER_FAILURE_OUTPUT="${TEST_TMPDIR}/worker-failure-output.json"

mkdir -p "${TMP_REPO}/.agent-orch"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TMP_REPO}/.agent-orch/providers.json" <<'JSON'
{
  "schema_version": 1,
  "providers": {
    "opencode": {
      "provider_id": "opencode",
      "provider_kind": "external_cli",
      "supported_roles": ["explore", "implement"],
      "command_template": ["fake-opencode", "run", "--prompt-file", "{prompt_file}", "--report", "{report_path}"],
      "capabilities": {
        "worktree": true,
        "writes_report": true,
        "supports_readonly": true,
        "supports_timeout": true
      }
    }
  }
}
JSON

cat > "${TASK_FILE}" <<'EOF'
Create the skeleton loop state for an implementation task.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Loop start writes loop.json and the first iteration task artifact.
EOF

PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider opencode \
  --role implement \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${START_OUTPUT}"

LOOP_ID="$(python3 - "${START_OUTPUT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["loop_id"])
PY
)"

LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${LOOP_ID}"
LOOP_JSON="${LOOP_DIR}/loop.json"
TASK_JSON="${LOOP_DIR}/iterations/1/task.json"
ITERATION_DIR="${LOOP_DIR}/iterations/1"
PROMPT_MD="${ITERATION_DIR}/prompt.md"
REPORT_JSON="${ITERATION_DIR}/report.json"
STDOUT_LOG="${ITERATION_DIR}/stdout.log"
STDERR_LOG="${ITERATION_DIR}/stderr.log"
PROVIDER_RESULT="${ITERATION_DIR}/provider-result.json"
DIFF_SUMMARY="${ITERATION_DIR}/diff_summary"

assert_json_value "${START_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${START_OUTPUT}" "state" "worker_collected"
assert_json_value "${START_OUTPUT}" "status" "worker_collected"
assert_json_value "${START_OUTPUT}" "current_iteration" "1"
assert_json_value "${START_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_json_value "${START_OUTPUT}" "report_status" "completed"
assert_file_exists "${LOOP_JSON}"
assert_file_exists "${TASK_JSON}"
assert_file_exists "${PROMPT_MD}"
assert_file_exists "${REPORT_JSON}"
assert_file_exists "${STDOUT_LOG}"
assert_file_exists "${STDERR_LOG}"
assert_file_exists "${PROVIDER_RESULT}"
assert_file_exists "${DIFF_SUMMARY}"
assert_json_value "${REPORT_JSON}" "status" "completed"
assert_json_array_contains "${REPORT_JSON}" "files_changed" "fake-opencode-output.txt"
assert_contains "${DIFF_SUMMARY}" "fake-opencode-output.txt"

"${ROOT_DIR}/bin/agent-orch" loop status \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" > "${STATUS_OUTPUT}"

assert_json_value "${STATUS_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${STATUS_OUTPUT}" "state" "worker_collected"
assert_json_value "${STATUS_OUTPUT}" "status" "worker_collected"
assert_json_value "${STATUS_OUTPUT}" "current_iteration" "1"
assert_json_value "${STATUS_OUTPUT}" "loop_dir" "${LOOP_DIR}"

"${ROOT_DIR}/bin/agent-orch" loop collect \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" > "${COLLECT_OUTPUT}"

assert_json_value "${COLLECT_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${COLLECT_OUTPUT}" "state" "worker_collected"
assert_json_value "${COLLECT_OUTPUT}" "status" "worker_collected"
assert_json_value "${COLLECT_OUTPUT}" "current_iteration" "1"
assert_json_value "${COLLECT_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_json_value "${COLLECT_OUTPUT}" "task_path" "${TASK_JSON}"
assert_json_value "${COLLECT_OUTPUT}" "report_status" "completed"
assert_json_array_contains "${COLLECT_OUTPUT}" "changed_files" "fake-opencode-output.txt"

python3 - "${LOOP_JSON}" "${LOOP_ID}" "${TMP_REPO}" <<'PY'
import json
import sys

path, loop_id, repo = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

required = {
    "schema_version",
    "loop_id",
    "provider",
    "role",
    "state",
    "current_iteration",
    "auto_fix",
    "max_iterations",
    "created_at",
    "updated_at",
    "repo_path",
}
missing = sorted(required - data.keys())
if missing:
    raise SystemExit(f"missing loop.json fields: {missing}")

assert data["schema_version"] == 1
assert data["loop_id"] == loop_id
assert data["provider"] == "opencode"
assert data["role"] == "implement"
assert data["state"] == "worker_collected"
assert data["current_iteration"] == 1
assert data["auto_fix"] is False
assert data["max_iterations"] is None
assert data["repo_path"] == repo
assert data["worker_report_status"] == "completed"
assert isinstance(data["created_at"], str) and data["created_at"]
assert isinstance(data["updated_at"], str) and data["updated_at"]
PY

PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider opencode \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${EXPLORE_OUTPUT}"

EXPLORE_LOOP_ID="$(python3 - "${EXPLORE_OUTPUT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["loop_id"])
PY
)"
EXPLORE_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${EXPLORE_LOOP_ID}"
EXPLORE_ITERATION_DIR="${EXPLORE_LOOP_DIR}/iterations/1"
EXPLORE_TASK_JSON="${EXPLORE_ITERATION_DIR}/task.json"
EXPLORE_REPORT_JSON="${EXPLORE_ITERATION_DIR}/report.json"
EXPLORE_DIFF_SUMMARY="${EXPLORE_ITERATION_DIR}/diff_summary"

assert_json_value "${EXPLORE_OUTPUT}" "state" "worker_collected"
assert_json_value "${EXPLORE_OUTPUT}" "status" "worker_collected"
assert_json_value "${EXPLORE_OUTPUT}" "current_iteration" "1"
assert_json_value "${EXPLORE_OUTPUT}" "report_status" "completed"
assert_file_exists "${EXPLORE_ITERATION_DIR}/prompt.md"
assert_file_exists "${EXPLORE_TASK_JSON}"
assert_file_exists "${EXPLORE_REPORT_JSON}"
assert_file_exists "${EXPLORE_ITERATION_DIR}/stdout.log"
assert_file_exists "${EXPLORE_ITERATION_DIR}/stderr.log"
assert_file_exists "${EXPLORE_ITERATION_DIR}/provider-result.json"
assert_file_exists "${EXPLORE_DIFF_SUMMARY}"
assert_json_value "${EXPLORE_REPORT_JSON}" "status" "completed"

if [[ -s "${EXPLORE_DIFF_SUMMARY}" ]]; then
  printf 'expected explore diff_summary to be empty, got:\n' >&2
  cat "${EXPLORE_DIFF_SUMMARY}" >&2
  exit 1
fi

python3 - "${EXPLORE_REPORT_JSON}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)
if report.get("files_changed") != []:
    raise SystemExit(f"expected explore files_changed to be empty, got {report.get('files_changed')}")
PY

"${ROOT_DIR}/bin/agent-orch" loop status \
  --loop-id "${EXPLORE_LOOP_ID}" \
  --repo "${TMP_REPO}" > "${EXPLORE_STATUS_OUTPUT}"
assert_json_value "${EXPLORE_STATUS_OUTPUT}" "state" "worker_collected"

"${ROOT_DIR}/bin/agent-orch" loop collect \
  --loop-id "${EXPLORE_LOOP_ID}" \
  --repo "${TMP_REPO}" > "${EXPLORE_COLLECT_OUTPUT}"
assert_json_value "${EXPLORE_COLLECT_OUTPUT}" "state" "worker_collected"
assert_json_value "${EXPLORE_COLLECT_OUTPUT}" "report_status" "completed"

PATH="${BIN_DIR}:${PATH}" FAKE_OPENCODE_MODE=worker-nonzero-missing-report \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${WORKER_FAILURE_OUTPUT}"

WORKER_FAILURE_REPORT="$(python3 - "${WORKER_FAILURE_OUTPUT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["report_path"])
PY
)"
assert_json_value "${WORKER_FAILURE_OUTPUT}" "state" "worker_collected"
assert_json_value "${WORKER_FAILURE_OUTPUT}" "report_status" "failed"
assert_json_value "${WORKER_FAILURE_REPORT}" "status" "failed"

python3 - "${WORKER_FAILURE_REPORT}" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

if not report.get("error_code"):
    raise SystemExit("expected synthetic report error_code")
diagnostics = report.get("diagnostics")
if not isinstance(diagnostics, dict):
    raise SystemExit("expected synthetic report diagnostics")
if diagnostics.get("exit_code") != 19:
    raise SystemExit(f"expected exit_code 19, got {diagnostics.get('exit_code')}")
for key in ("stdout_path", "stderr_path"):
    path = diagnostics.get(key)
    if not path or not Path(path).exists():
        raise SystemExit(f"expected existing diagnostics {key}, got {path}")
PY

mkdir -p "${UNSUPPORTED_REPO}/.agent-orch"
git -C "${UNSUPPORTED_REPO}" init -q
git -C "${UNSUPPORTED_REPO}" config user.email "agent-orch-test@example.com"
git -C "${UNSUPPORTED_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${UNSUPPORTED_REPO}/README.md"
git -C "${UNSUPPORTED_REPO}" add README.md
git -C "${UNSUPPORTED_REPO}" commit -qm "Initial commit"

cat > "${UNSUPPORTED_REPO}/.agent-orch/providers.json" <<'JSON'
{
  "schema_version": 1,
  "providers": {
    "mini": {
      "provider_id": "mini",
      "provider_kind": "external_cli",
      "supported_roles": ["explore"],
      "command_template": ["fake-opencode", "run", "--prompt-file", "{prompt_file}", "--report", "{report_path}"],
      "capabilities": {
        "worktree": true,
        "writes_report": true,
        "supports_readonly": true,
        "supports_timeout": true
      }
    }
  }
}
JSON

if PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider mini \
  --role implement \
  --repo "${UNSUPPORTED_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${UNSUPPORTED_OUT}" 2> "${UNSUPPORTED_ERR}"; then
  printf 'expected unsupported role loop start to fail\n' >&2
  exit 1
fi

python3 - "${UNSUPPORTED_ERR}" <<'PY'
import json
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
    raise SystemExit("expected JSON error on stderr")
payload = json.loads(lines[-1])
if payload.get("error") != "provider_config_invalid":
    raise SystemExit(f"expected provider_config_invalid, got {payload.get('error')}")
loop_dir = payload.get("loop_dir")
if not loop_dir:
    raise SystemExit("expected loop_dir in unsupported role error")
with Path(loop_dir, "loop.json").open("r", encoding="utf-8") as handle:
    loop = json.load(handle)
if loop.get("state") != "failed":
    raise SystemExit(f"expected unsupported role loop state failed, got {loop.get('state')}")
PY

assert_agent_orch_error "missing_arg" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" \
    --auto-fix

assert_agent_orch_error "missing_arg" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}"

assert_agent_orch_error "unknown_arg" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" \
    --unknown-loop-arg

assert_agent_orch_error "missing_repo" \
  "${ROOT_DIR}/bin/agent-orch" loop status \
    --loop-id "${LOOP_ID}" \
    --repo "${MISSING_REPO}"

mkdir -p "${NON_GIT_REPO}"
assert_agent_orch_error "invalid_repo" \
  "${ROOT_DIR}/bin/agent-orch" loop collect \
    --loop-id "${LOOP_ID}" \
    --repo "${NON_GIT_REPO}"

printf 'loop-start.sh: ok\n'
