#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

BIN_DIR="${ROOT_DIR}/tests/fixtures/bin"
REVIEW_FIXTURES="${ROOT_DIR}/tests/fixtures/reviews"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"

cat > "${TASK_FILE}" <<'EOF'
Exercise deterministic failure finalization.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Failure outputs include machine-readable error codes and artifact paths.
EOF

json_get() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key.split("."):
    value = value[part]
print(value)
PY
}

assert_json_null() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key.split("."):
    value = value[part]
if value is not None:
    raise SystemExit(f"expected {key} to be null, got {value!r}")
PY
}

assert_file_absent() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    printf 'expected file to be absent: %s\n' "${path}" >&2
    exit 1
  fi
}

assert_json_missing() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
parts = key.split(".")
for part in parts[:-1]:
    value = value[part]
if parts[-1] in value:
    raise SystemExit(f"expected {key} to be absent")
PY
}

init_repo() {
  local repo="$1"
  mkdir -p "${repo}/.agent-orch"
  git -C "${repo}" init -q
  git -C "${repo}" config user.email "agent-orch-test@example.com"
  git -C "${repo}" config user.name "agent-orch test"
  printf 'initial\n' > "${repo}/README.md"
  git -C "${repo}" add README.md
  git -C "${repo}" commit -qm "Initial commit"

  cat > "${repo}/.agent-orch/providers.json" <<'JSON'
{
  "schema_version": 1,
  "providers": {
    "opencode": {
      "provider_id": "opencode",
      "provider_kind": "external_cli",
      "supported_roles": ["explore", "implement"],
      "command_template": ["fake-opencode", "run", "--prompt-file", "{prompt_file}", "--task-json", "{task_json}", "--report", "{report_path}"],
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
}

start_loop() {
  local repo="$1"
  local output_path="$2"
  shift 2
  PATH="${BIN_DIR}:${PATH}" "$@" "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${repo}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${output_path}"
}

record_review() {
  local repo="$1"
  local loop_id="$2"
  local reviewer="$3"
  local fixture="$4"
  local output_path="$5"
  "${ROOT_DIR}/bin/agent-orch" loop review \
    --loop-id "${loop_id}" \
    --repo "${repo}" \
    --reviewer "${reviewer}" \
    --review-file "${fixture}" > "${output_path}"
}

decide_loop() {
  local repo="$1"
  local loop_id="$2"
  local output_path="$3"
  "${ROOT_DIR}/bin/agent-orch" loop decide \
    --loop-id "${loop_id}" \
    --repo "${repo}" > "${output_path}"
}

assert_worker_artifacts() {
  local output_path="$1"
  local expected_status="$2"
  local expected_error_code="$3"
  local expected_report_error_code="${4:-${expected_error_code}}"

  assert_json_value "${output_path}" "report_status" "${expected_status}"
  assert_json_value "${output_path}" "error_code" "${expected_error_code}"
  for key in iteration_dir report_path stdout_path stderr_path provider_result_path workspace_audit_path; do
    local artifact_path
    artifact_path="$(json_get "${output_path}" "${key}")"
    assert_file_exists "${artifact_path}"
  done

  local report_path
  report_path="$(json_get "${output_path}" "report_path")"
  assert_json_value "${report_path}" "status" "${expected_status}"
  if [[ "${expected_report_error_code}" == "__absent__" ]]; then
    assert_json_missing "${report_path}" "error_code"
  elif [[ "${expected_status}" == "failed" ]]; then
    assert_json_value "${report_path}" "error_code" "${expected_report_error_code}"
  fi
}

assert_decision_worker_artifacts() {
  local output_path="$1"
  local iteration_dir="$2"

  for key in stdout_path stderr_path provider_result_path workspace_audit_path; do
    local artifact_path
    artifact_path="$(json_get "${output_path}" "${key}")"
    assert_file_exists "${artifact_path}"
  done
  assert_json_value "${output_path}" "stdout_path" "${iteration_dir}/stdout.log"
  assert_json_value "${output_path}" "stderr_path" "${iteration_dir}/stderr.log"
  assert_json_value "${output_path}" "provider_result_path" "${iteration_dir}/provider-result.json"
  assert_json_value "${output_path}" "workspace_audit_path" "${iteration_dir}/workspace-audit.json"

  if [[ -f "${iteration_dir}/report.raw" ]]; then
    assert_json_value "${output_path}" "raw_report_path" "${iteration_dir}/report.raw"
  fi
}

READINESS_REPO="${TEST_TMPDIR}/readiness-repo"
READINESS_OUT="${TEST_TMPDIR}/readiness.out"
READINESS_ERR="${TEST_TMPDIR}/readiness.err"
READINESS_MARKER="${TEST_TMPDIR}/readiness-worker-launched"
init_repo "${READINESS_REPO}"

if PATH="${BIN_DIR}:${PATH}" FAKE_OPENCODE_MODE=nonzero FAKE_OPENCODE_LAUNCH_MARKER="${READINESS_MARKER}" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${READINESS_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${READINESS_OUT}" 2> "${READINESS_ERR}"; then
  printf 'expected readiness failure\n' >&2
  exit 1
fi

python3 - "${READINESS_ERR}" "${READINESS_REPO}" <<'PY'
import json
import sys
from pathlib import Path

stderr_path, repo = sys.argv[1:]
lines = [line.strip() for line in Path(stderr_path).read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
    raise SystemExit("expected JSON readiness error")
payload = json.loads(lines[-1])
if payload.get("error") != "provider_not_ready" or payload.get("error_code") != "provider_not_ready":
    raise SystemExit(f"expected provider_not_ready, got {payload}")
loop_dir = Path(payload["loop_dir"])
if not loop_dir.is_dir():
    raise SystemExit(f"expected loop_dir to exist: {loop_dir}")
readiness_path = Path(payload["readiness_path"])
if not readiness_path.is_file():
    raise SystemExit(f"expected readiness_path to exist: {readiness_path}")
if (loop_dir / "iterations" / "1").exists():
    raise SystemExit("readiness failure must not create a worker iteration")
if not str(loop_dir).startswith(str(Path(repo))):
    raise SystemExit("expected loop_dir inside test repo")
PY
assert_file_absent "${READINESS_MARKER}"

MISSING_REPO="${TEST_TMPDIR}/missing-report-repo"
MISSING_OUT="${TEST_TMPDIR}/missing-report.json"
init_repo "${MISSING_REPO}"
start_loop "${MISSING_REPO}" "${MISSING_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-missing-report
assert_worker_artifacts "${MISSING_OUT}" "failed" "provider_exit_failure"

INVALID_REPO="${TEST_TMPDIR}/invalid-report-repo"
INVALID_OUT="${TEST_TMPDIR}/invalid-report.json"
init_repo "${INVALID_REPO}"
start_loop "${INVALID_REPO}" "${INVALID_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-invalid-report
assert_worker_artifacts "${INVALID_OUT}" "failed" "provider_exit_failure"
INVALID_RAW="$(json_get "${INVALID_OUT}" "raw_report_path")"
assert_file_exists "${INVALID_RAW}"
assert_contains "${INVALID_RAW}" "this is not json"

PARTIAL_REPO="${TEST_TMPDIR}/partial-report-repo"
PARTIAL_OUT="${TEST_TMPDIR}/partial-report.json"
init_repo "${PARTIAL_REPO}"
start_loop "${PARTIAL_REPO}" "${PARTIAL_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-partial-report
assert_worker_artifacts "${PARTIAL_OUT}" "partial" "worker_partial"
assert_json_value "$(json_get "${PARTIAL_OUT}" "provider_result_path")" "exit_code" "19"

PARTIAL_NO_CODE_REPO="${TEST_TMPDIR}/partial-report-no-code-repo"
PARTIAL_NO_CODE_OUT="${TEST_TMPDIR}/partial-report-no-code.json"
init_repo "${PARTIAL_NO_CODE_REPO}"
start_loop "${PARTIAL_NO_CODE_REPO}" "${PARTIAL_NO_CODE_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-partial-report-no-error-code
assert_worker_artifacts "${PARTIAL_NO_CODE_OUT}" "partial" "worker_partial" "__absent__"
assert_json_value "$(json_get "${PARTIAL_NO_CODE_OUT}" "provider_result_path")" "exit_code" "19"

FAILED_REPO="${TEST_TMPDIR}/failed-report-repo"
FAILED_OUT="${TEST_TMPDIR}/failed-report.json"
init_repo "${FAILED_REPO}"
start_loop "${FAILED_REPO}" "${FAILED_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-failed-report
assert_worker_artifacts "${FAILED_OUT}" "failed" "worker_declared_failure"
assert_json_value "$(json_get "${FAILED_OUT}" "provider_result_path")" "exit_code" "19"

FAILED_NO_CODE_REPO="${TEST_TMPDIR}/failed-report-no-code-repo"
FAILED_NO_CODE_OUT="${TEST_TMPDIR}/failed-report-no-code.json"
init_repo "${FAILED_NO_CODE_REPO}"
start_loop "${FAILED_NO_CODE_REPO}" "${FAILED_NO_CODE_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-failed-report-no-error-code
assert_worker_artifacts "${FAILED_NO_CODE_OUT}" "failed" "worker_declared_failure" "__absent__"
assert_json_value "$(json_get "${FAILED_NO_CODE_OUT}" "provider_result_path")" "exit_code" "19"

COMPLETED_REPO="${TEST_TMPDIR}/completed-report-repo"
COMPLETED_OUT="${TEST_TMPDIR}/completed-report.json"
init_repo "${COMPLETED_REPO}"
start_loop "${COMPLETED_REPO}" "${COMPLETED_OUT}" env FAKE_OPENCODE_MODE=worker-nonzero-completed-report
assert_worker_artifacts "${COMPLETED_OUT}" "failed" "provider_exit_failure"
assert_json_value "$(json_get "${COMPLETED_OUT}" "provider_result_path")" "exit_code" "19"

MALFORMED_REPO="${TEST_TMPDIR}/malformed-review-repo"
MALFORMED_START="${TEST_TMPDIR}/malformed-start.json"
MALFORMED_REVIEW="${TEST_TMPDIR}/malformed-review.json"
MALFORMED_DECIDE="${TEST_TMPDIR}/malformed-decide.json"
init_repo "${MALFORMED_REPO}"
start_loop "${MALFORMED_REPO}" "${MALFORMED_START}" env
MALFORMED_LOOP_ID="$(json_get "${MALFORMED_START}" "loop_id")"
MALFORMED_LOOP_DIR="${MALFORMED_REPO}/.superpowers/agent-orch/loops/${MALFORMED_LOOP_ID}"
record_review "${MALFORMED_REPO}" "${MALFORMED_LOOP_ID}" correctness "${REVIEW_FIXTURES}/malformed-review.txt" "${MALFORMED_REVIEW}"
record_review "${MALFORMED_REPO}" "${MALFORMED_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/malformed-integration.json"
decide_loop "${MALFORMED_REPO}" "${MALFORMED_LOOP_ID}" "${MALFORMED_DECIDE}"
assert_json_value "${MALFORMED_REVIEW}" "status" "needs_human"
assert_json_value "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.json" "status" "needs_human"
assert_json_value "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.json" "error_code" "review_json_invalid"
assert_file_exists "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.raw"
assert_json_value "${MALFORMED_DECIDE}" "decision" "manual_gate"
assert_json_value "${MALFORMED_DECIDE}" "error_code" "review_json_invalid"
assert_json_value "${MALFORMED_DECIDE}" "loop_dir" "${MALFORMED_LOOP_DIR}"
assert_json_value "${MALFORMED_DECIDE}" "iteration_dir" "${MALFORMED_LOOP_DIR}/iterations/1"
assert_json_value "${MALFORMED_DECIDE}" "raw_review_paths.correctness" "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.raw"
assert_decision_worker_artifacts "${MALFORMED_DECIDE}" "${MALFORMED_LOOP_DIR}/iterations/1"

VIOLATION_REPO="${TEST_TMPDIR}/workspace-violation-repo"
VIOLATION_START="${TEST_TMPDIR}/workspace-violation-start.json"
VIOLATION_DECIDE="${TEST_TMPDIR}/workspace-violation-decide.json"
init_repo "${VIOLATION_REPO}"
PATH="${BIN_DIR}:${PATH}" FAKE_OPENCODE_MODE=worker-workspace-violation \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${VIOLATION_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" \
    --auto-fix \
    --max-iterations 2 > "${VIOLATION_START}"
assert_worker_artifacts "${VIOLATION_START}" "failed" "workspace_violation"
assert_file_exists "${VIOLATION_REPO}/main-checkout-violation.txt"
VIOLATION_LOOP_ID="$(json_get "${VIOLATION_START}" "loop_id")"
VIOLATION_LOOP_DIR="${VIOLATION_REPO}/.superpowers/agent-orch/loops/${VIOLATION_LOOP_ID}"
assert_json_value "${VIOLATION_LOOP_DIR}/iterations/1/workspace-audit.json" "error_code" "workspace_violation"
record_review "${VIOLATION_REPO}" "${VIOLATION_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-blocked.json" "${TEST_TMPDIR}/violation-correctness.json"
record_review "${VIOLATION_REPO}" "${VIOLATION_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/violation-integration.json"
decide_loop "${VIOLATION_REPO}" "${VIOLATION_LOOP_ID}" "${VIOLATION_DECIDE}"
assert_json_value "${VIOLATION_DECIDE}" "decision" "workspace_violation"
assert_json_value "${VIOLATION_DECIDE}" "state" "manual_gate"
assert_json_value "${VIOLATION_DECIDE}" "error_code" "workspace_violation"
assert_json_value "${VIOLATION_DECIDE}" "report_path" "${VIOLATION_LOOP_DIR}/iterations/1/report.json"
assert_json_value "${VIOLATION_DECIDE}" "iteration_dir" "${VIOLATION_LOOP_DIR}/iterations/1"
assert_decision_worker_artifacts "${VIOLATION_DECIDE}" "${VIOLATION_LOOP_DIR}/iterations/1"
assert_json_null "${VIOLATION_DECIDE}" "next_task_path"
assert_file_absent "${VIOLATION_LOOP_DIR}/iterations/1/next_task.json"

printf 'loop-failure.sh: ok\n'
