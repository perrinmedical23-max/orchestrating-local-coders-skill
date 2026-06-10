#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
INVALID_OUTPUT="${TEST_TMPDIR}/invalid-output.json"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise attempt diagnostics.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The wrapper preserves top-level artifacts and mirrors them into attempts/1.
EOF

AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${RUN_OUTPUT}"

TASK_DIR="$(python3 - "${RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
ATTEMPT_DIR="${TASK_DIR}/attempts/1"

assert_file_exists "${ATTEMPT_DIR}/stdout.log"
assert_file_exists "${ATTEMPT_DIR}/stderr.log"
assert_file_exists "${ATTEMPT_DIR}/provider-result.json"
assert_file_exists "${ATTEMPT_DIR}/report.json"
assert_file_exists "${ATTEMPT_DIR}/progress.log"
cmp "${TASK_DIR}/stdout.log" "${ATTEMPT_DIR}/stdout.log"
cmp "${TASK_DIR}/stderr.log" "${ATTEMPT_DIR}/stderr.log"
cmp "${TASK_DIR}/provider-result.json" "${ATTEMPT_DIR}/provider-result.json"
cmp "${TASK_DIR}/report.json" "${ATTEMPT_DIR}/report.json"
assert_json_value "${TASK_DIR}/status.json" "phase" "done"
assert_contains "${ATTEMPT_DIR}/progress.log" "starting"
assert_contains "${ATTEMPT_DIR}/progress.log" "provider_running"
assert_contains "${ATTEMPT_DIR}/progress.log" "finalizing"
assert_contains "${ATTEMPT_DIR}/progress.log" "done"

AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-invalid-report \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${INVALID_OUTPUT}"

INVALID_TASK_DIR="$(python3 - "${INVALID_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
INVALID_ATTEMPT_DIR="${INVALID_TASK_DIR}/attempts/1"

assert_file_exists "${INVALID_ATTEMPT_DIR}/report.raw"
assert_file_exists "${INVALID_ATTEMPT_DIR}/report.json"
assert_json_value "${INVALID_TASK_DIR}/status.json" "phase" "failed"
assert_json_value "${INVALID_ATTEMPT_DIR}/report.json" "status" "failed"
assert_contains "${INVALID_ATTEMPT_DIR}/progress.log" "failed"

printf 'attempts.sh: ok\n'
