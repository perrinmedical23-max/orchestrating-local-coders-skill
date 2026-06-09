#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
STATUS_BY_REPO="${TEST_TMPDIR}/status-by-repo.json"
STATUS_BY_TASK_DIR="${TEST_TMPDIR}/status-by-task-dir.json"
MISSING_OUTPUT="${TEST_TMPDIR}/missing-output.json"
MISSING_TASK_ID_OUTPUT="${TEST_TMPDIR}/missing-task-id-output.json"
MISSING_LOCATOR_OUTPUT="${TEST_TMPDIR}/missing-locator-output.json"
BOTH_LOCATORS_OUTPUT="${TEST_TMPDIR}/both-locators-output.json"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Implement the fixture-backed status lookup path.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Status resolves an existing task by task id and returns JSON.
EOF

AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${RUN_OUTPUT}"

TASK_ID="$(python3 - "${RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"

TASK_DIR="$(python3 - "${RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"

WORKTREE_PATH="$(python3 - "${TASK_DIR}/metadata.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["worktree_path"])
PY
)"

"${ROOT_DIR}/bin/agent-orch" status \
  --task-id "${TASK_ID}" \
  --repo "${TMP_REPO}" > "${STATUS_BY_REPO}"

assert_json_value "${STATUS_BY_REPO}" "task_id" "${TASK_ID}"
assert_json_value "${STATUS_BY_REPO}" "mode" "worktree"
assert_json_value "${STATUS_BY_REPO}" "repo_path" "${TMP_REPO}"
assert_json_value "${STATUS_BY_REPO}" "worktree_path" "${WORKTREE_PATH}"
assert_json_value "${STATUS_BY_REPO}" "report_path" "${TASK_DIR}/report.json"
assert_json_value "${STATUS_BY_REPO}" "status" "completed"
assert_json_value "${STATUS_BY_REPO}" "log_paths.stdout" "${TASK_DIR}/stdout.log"
assert_json_value "${STATUS_BY_REPO}" "log_paths.stderr" "${TASK_DIR}/stderr.log"

"${ROOT_DIR}/bin/agent-orch" status \
  --task-id "${TASK_ID}" \
  --task-dir "${TASK_DIR}" > "${STATUS_BY_TASK_DIR}"

assert_json_value "${STATUS_BY_TASK_DIR}" "task_id" "${TASK_ID}"
assert_json_value "${STATUS_BY_TASK_DIR}" "mode" "worktree"
assert_json_value "${STATUS_BY_TASK_DIR}" "repo_path" "${TMP_REPO}"
assert_json_value "${STATUS_BY_TASK_DIR}" "worktree_path" "${WORKTREE_PATH}"
assert_json_value "${STATUS_BY_TASK_DIR}" "report_path" "${TASK_DIR}/report.json"
assert_json_value "${STATUS_BY_TASK_DIR}" "status" "completed"

if "${ROOT_DIR}/bin/agent-orch" status \
  --task-id "missing-task" \
  --repo "${TMP_REPO}" > "${MISSING_OUTPUT}" 2>&1; then
  printf 'expected missing task lookup to fail\n' >&2
  exit 1
fi
assert_json_value "${MISSING_OUTPUT}" "error" "task_not_found"

if "${ROOT_DIR}/bin/agent-orch" status \
  --repo "${TMP_REPO}" > "${MISSING_TASK_ID_OUTPUT}" 2>&1; then
  printf 'expected status without --task-id to fail\n' >&2
  exit 1
fi
assert_json_value "${MISSING_TASK_ID_OUTPUT}" "error" "missing_arg"

if "${ROOT_DIR}/bin/agent-orch" status \
  --task-id "${TASK_ID}" > "${MISSING_LOCATOR_OUTPUT}" 2>&1; then
  printf 'expected status without locator to fail\n' >&2
  exit 1
fi
assert_json_value "${MISSING_LOCATOR_OUTPUT}" "error" "invalid_args"

if "${ROOT_DIR}/bin/agent-orch" status \
  --task-id "${TASK_ID}" \
  --repo "${TMP_REPO}" \
  --task-dir "${TASK_DIR}" > "${BOTH_LOCATORS_OUTPUT}" 2>&1; then
  printf 'expected status with both locators to fail\n' >&2
  exit 1
fi
assert_json_value "${BOTH_LOCATORS_OUTPUT}" "error" "invalid_args"

printf 'status.sh: ok\n'
