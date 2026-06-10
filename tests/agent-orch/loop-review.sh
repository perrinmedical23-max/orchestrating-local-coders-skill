#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
START_OUTPUT="${TEST_TMPDIR}/loop-start-output.json"
CORRECTNESS_OUTPUT="${TEST_TMPDIR}/correctness-output.json"
INTEGRATION_OUTPUT="${TEST_TMPDIR}/integration-output.json"
CORRECTNESS_BLOCKED_OUTPUT="${TEST_TMPDIR}/correctness-blocked-output.json"
INTEGRATION_BLOCKED_OUTPUT="${TEST_TMPDIR}/integration-blocked-output.json"
CORRECTNESS_NEEDS_HUMAN_OUTPUT="${TEST_TMPDIR}/correctness-needs-human-output.json"
MALFORMED_OUTPUT="${TEST_TMPDIR}/malformed-output.json"
STATUS_OUTPUT="${TEST_TMPDIR}/status-output.json"
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
Loop review records reviewer artifacts without launching any reviewer.
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
ITERATION_DIR="${LOOP_DIR}/iterations/1"
REVIEWS_DIR="${ITERATION_DIR}/reviews"
CORRECTNESS_JSON="${REVIEWS_DIR}/correctness.json"
INTEGRATION_JSON="${REVIEWS_DIR}/integration.json"
CORRECTNESS_RAW="${REVIEWS_DIR}/correctness.raw"
PROVIDER_RESULT="${ITERATION_DIR}/provider-result.json"
PROVIDER_COMMAND="${ITERATION_DIR}/provider-command.json"
PROVIDER_RESULT_BEFORE="${TEST_TMPDIR}/provider-result.before"
PROVIDER_COMMAND_BEFORE="${TEST_TMPDIR}/provider-command.before"

cp "${PROVIDER_RESULT}" "${PROVIDER_RESULT_BEFORE}"
cp "${PROVIDER_COMMAND}" "${PROVIDER_COMMAND_BEFORE}"

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer correctness \
  --review-file "${REVIEW_FIXTURES}/correctness-passed.json" > "${CORRECTNESS_OUTPUT}"

assert_json_value "${CORRECTNESS_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${CORRECTNESS_OUTPUT}" "reviewer" "correctness"
assert_json_value "${CORRECTNESS_OUTPUT}" "review_path" "${CORRECTNESS_JSON}"
assert_json_value "${CORRECTNESS_OUTPUT}" "status" "passed"
assert_json_value "${CORRECTNESS_OUTPUT}" "current_iteration" "1"
assert_json_value "${CORRECTNESS_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_file_exists "${CORRECTNESS_JSON}"
assert_json_value "${CORRECTNESS_JSON}" "status" "passed"

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer integration \
  --review-file "${REVIEW_FIXTURES}/integration-passed.json" > "${INTEGRATION_OUTPUT}"

assert_json_value "${INTEGRATION_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${INTEGRATION_OUTPUT}" "reviewer" "integration"
assert_json_value "${INTEGRATION_OUTPUT}" "review_path" "${INTEGRATION_JSON}"
assert_json_value "${INTEGRATION_OUTPUT}" "status" "passed"
assert_json_value "${INTEGRATION_OUTPUT}" "current_iteration" "1"
assert_json_value "${INTEGRATION_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_file_exists "${INTEGRATION_JSON}"
assert_json_value "${INTEGRATION_JSON}" "status" "passed"
assert_json_value "${INTEGRATION_JSON}" "acceptance_match" "met"

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer correctness \
  --review-file "${REVIEW_FIXTURES}/correctness-blocked.json" > "${CORRECTNESS_BLOCKED_OUTPUT}"

assert_json_value "${CORRECTNESS_BLOCKED_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${CORRECTNESS_BLOCKED_OUTPUT}" "reviewer" "correctness"
assert_json_value "${CORRECTNESS_BLOCKED_OUTPUT}" "review_path" "${CORRECTNESS_JSON}"
assert_json_value "${CORRECTNESS_BLOCKED_OUTPUT}" "status" "blocked"
assert_json_value "${CORRECTNESS_JSON}" "status" "blocked"
assert_json_array_contains "${CORRECTNESS_JSON}" "tests_required" "Add a regression test for persistence."

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer integration \
  --review-file "${REVIEW_FIXTURES}/integration-blocked.json" > "${INTEGRATION_BLOCKED_OUTPUT}"

assert_json_value "${INTEGRATION_BLOCKED_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${INTEGRATION_BLOCKED_OUTPUT}" "reviewer" "integration"
assert_json_value "${INTEGRATION_BLOCKED_OUTPUT}" "review_path" "${INTEGRATION_JSON}"
assert_json_value "${INTEGRATION_BLOCKED_OUTPUT}" "status" "blocked"
assert_json_value "${INTEGRATION_JSON}" "status" "blocked"
assert_json_value "${INTEGRATION_JSON}" "acceptance_match" "partial"

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer correctness \
  --review-file "${REVIEW_FIXTURES}/correctness-needs-human.json" > "${CORRECTNESS_NEEDS_HUMAN_OUTPUT}"

assert_json_value "${CORRECTNESS_NEEDS_HUMAN_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${CORRECTNESS_NEEDS_HUMAN_OUTPUT}" "reviewer" "correctness"
assert_json_value "${CORRECTNESS_NEEDS_HUMAN_OUTPUT}" "review_path" "${CORRECTNESS_JSON}"
assert_json_value "${CORRECTNESS_NEEDS_HUMAN_OUTPUT}" "status" "needs_human"
assert_json_value "${CORRECTNESS_JSON}" "status" "needs_human"
assert_json_array_contains "${CORRECTNESS_JSON}" "residual_risks" "Manual inspection is required for the ambiguous behavior."

"${ROOT_DIR}/bin/agent-orch" loop review \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" \
  --reviewer correctness \
  --review-file "${REVIEW_FIXTURES}/malformed-review.txt" > "${MALFORMED_OUTPUT}"

assert_json_value "${MALFORMED_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${MALFORMED_OUTPUT}" "reviewer" "correctness"
assert_json_value "${MALFORMED_OUTPUT}" "review_path" "${CORRECTNESS_JSON}"
assert_json_value "${MALFORMED_OUTPUT}" "status" "needs_human"
assert_file_exists "${CORRECTNESS_RAW}"
assert_contains "${CORRECTNESS_RAW}" "this is not json"
assert_json_value "${CORRECTNESS_JSON}" "status" "needs_human"
assert_json_value "${CORRECTNESS_JSON}" "error_code" "review_json_invalid"

assert_agent_orch_error "invalid_reviewer" \
  "${ROOT_DIR}/bin/agent-orch" loop review \
    --loop-id "${LOOP_ID}" \
    --repo "${TMP_REPO}" \
    --reviewer security \
    --review-file "${REVIEW_FIXTURES}/correctness-passed.json"

"${ROOT_DIR}/bin/agent-orch" loop status \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" > "${STATUS_OUTPUT}"

assert_json_value "${STATUS_OUTPUT}" "state" "worker_collected"
assert_json_value "${STATUS_OUTPUT}" "status" "worker_collected"

if [[ -e "${ITERATION_DIR}/next_task.json" ]]; then
  printf 'loop review must not decide or create next_task.json\n' >&2
  exit 1
fi

cmp -s "${PROVIDER_RESULT}" "${PROVIDER_RESULT_BEFORE}" || {
  printf 'loop review must not rerun or mutate provider-result.json\n' >&2
  exit 1
}
cmp -s "${PROVIDER_COMMAND}" "${PROVIDER_COMMAND_BEFORE}" || {
  printf 'loop review must not mutate provider-command.json\n' >&2
  exit 1
}

printf 'loop-review.sh: ok\n'
