#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
BIN_DIR="${ROOT_DIR}/tests/fixtures/bin"
REVIEW_FIXTURES="${ROOT_DIR}/tests/fixtures/reviews"

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
Create a deterministic worker artifact.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Loop decide applies reviewer outcomes without launching providers.
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

start_loop() {
  local output_path="$1"
  PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${output_path}"
}

record_review() {
  local loop_id="$1"
  local reviewer="$2"
  local fixture="$3"
  local output_path="$4"
  "${ROOT_DIR}/bin/agent-orch" loop review \
    --loop-id "${loop_id}" \
    --repo "${TMP_REPO}" \
    --reviewer "${reviewer}" \
    --review-file "${fixture}" > "${output_path}"
}

decide_loop() {
  local loop_id="$1"
  local output_path="$2"
  "${ROOT_DIR}/bin/agent-orch" loop decide \
    --loop-id "${loop_id}" \
    --repo "${TMP_REPO}" > "${output_path}"
}

assert_decision_state() {
  local loop_id="$1"
  local output_path="$2"
  local expected_state="$3"
  local expected_decision="$4"
  local loop_dir="${TMP_REPO}/.superpowers/agent-orch/loops/${loop_id}"
  local decision_json="${loop_dir}/iterations/1/decision.json"

  assert_json_value "${output_path}" "loop_id" "${loop_id}"
  assert_json_value "${output_path}" "state" "${expected_state}"
  assert_json_value "${output_path}" "current_iteration" "1"
  assert_json_value "${output_path}" "decision" "${expected_decision}"
  assert_json_null "${output_path}" "next_task_path"
  assert_json_value "${loop_dir}/loop.json" "state" "${expected_state}"
  assert_file_exists "${decision_json}"
  assert_json_value "${decision_json}" "loop_id" "${loop_id}"
  assert_json_value "${decision_json}" "state" "${expected_state}"
  assert_json_value "${decision_json}" "decision" "${expected_decision}"
  assert_json_value "${decision_json}" "current_iteration" "1"
  assert_file_absent "${loop_dir}/iterations/1/next_task.json"
}

PASSED_START="${TEST_TMPDIR}/passed-start.json"
PASSED_DECIDE="${TEST_TMPDIR}/passed-decide.json"
start_loop "${PASSED_START}"
PASSED_LOOP_ID="$(json_get "${PASSED_START}" "loop_id")"
record_review "${PASSED_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-passed.json" "${TEST_TMPDIR}/passed-correctness.json"
record_review "${PASSED_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/passed-integration.json"
decide_loop "${PASSED_LOOP_ID}" "${PASSED_DECIDE}"
assert_decision_state "${PASSED_LOOP_ID}" "${PASSED_DECIDE}" "completed" "completed"
assert_json_value "${PASSED_DECIDE}" "reviewer_statuses.correctness" "passed"
assert_json_value "${PASSED_DECIDE}" "reviewer_statuses.integration" "passed"

BLOCKED_START="${TEST_TMPDIR}/blocked-start.json"
BLOCKED_DECIDE="${TEST_TMPDIR}/blocked-decide.json"
start_loop "${BLOCKED_START}"
BLOCKED_LOOP_ID="$(json_get "${BLOCKED_START}" "loop_id")"
record_review "${BLOCKED_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-blocked.json" "${TEST_TMPDIR}/blocked-correctness.json"
record_review "${BLOCKED_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/blocked-integration.json"
decide_loop "${BLOCKED_LOOP_ID}" "${BLOCKED_DECIDE}"
assert_decision_state "${BLOCKED_LOOP_ID}" "${BLOCKED_DECIDE}" "manual_gate" "manual_gate"
assert_json_array_contains "${BLOCKED_DECIDE}" "blocking_reviewers" "correctness"

NEEDS_HUMAN_START="${TEST_TMPDIR}/needs-human-start.json"
NEEDS_HUMAN_DECIDE="${TEST_TMPDIR}/needs-human-decide.json"
start_loop "${NEEDS_HUMAN_START}"
NEEDS_HUMAN_LOOP_ID="$(json_get "${NEEDS_HUMAN_START}" "loop_id")"
record_review "${NEEDS_HUMAN_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-needs-human.json" "${TEST_TMPDIR}/needs-human-correctness.json"
record_review "${NEEDS_HUMAN_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/needs-human-integration.json"
decide_loop "${NEEDS_HUMAN_LOOP_ID}" "${NEEDS_HUMAN_DECIDE}"
assert_decision_state "${NEEDS_HUMAN_LOOP_ID}" "${NEEDS_HUMAN_DECIDE}" "manual_gate" "manual_gate"
assert_json_array_contains "${NEEDS_HUMAN_DECIDE}" "blocking_reviewers" "correctness"

MISSING_START="${TEST_TMPDIR}/missing-start.json"
start_loop "${MISSING_START}"
MISSING_LOOP_ID="$(json_get "${MISSING_START}" "loop_id")"
MISSING_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${MISSING_LOOP_ID}"
record_review "${MISSING_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-passed.json" "${TEST_TMPDIR}/missing-correctness.json"
assert_agent_orch_error "review_missing" \
  "${ROOT_DIR}/bin/agent-orch" loop decide \
    --loop-id "${MISSING_LOOP_ID}" \
    --repo "${TMP_REPO}"
assert_json_value "${MISSING_LOOP_DIR}/loop.json" "state" "worker_collected"
assert_file_absent "${MISSING_LOOP_DIR}/iterations/1/decision.json"

MALFORMED_START="${TEST_TMPDIR}/malformed-start.json"
MALFORMED_DECIDE="${TEST_TMPDIR}/malformed-decide.json"
start_loop "${MALFORMED_START}"
MALFORMED_LOOP_ID="$(json_get "${MALFORMED_START}" "loop_id")"
MALFORMED_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${MALFORMED_LOOP_ID}"
record_review "${MALFORMED_LOOP_ID}" correctness "${REVIEW_FIXTURES}/malformed-review.txt" "${TEST_TMPDIR}/malformed-correctness.json"
record_review "${MALFORMED_LOOP_ID}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/malformed-integration.json"
decide_loop "${MALFORMED_LOOP_ID}" "${MALFORMED_DECIDE}"
assert_decision_state "${MALFORMED_LOOP_ID}" "${MALFORMED_DECIDE}" "manual_gate" "manual_gate"
assert_json_array_contains "${MALFORMED_DECIDE}" "blocking_reviewers" "correctness"
assert_json_value "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.json" "status" "needs_human"
assert_json_value "${MALFORMED_LOOP_DIR}/iterations/1/reviews/correctness.json" "error_code" "review_json_invalid"

printf 'loop-decide.sh: ok\n'
