#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
STATUS_OUTPUT="${TEST_TMPDIR}/status-output.json"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise runtime binding fields.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Status output includes task-bound runtime fields without v1 sessions.
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
  --repo "${TMP_REPO}" > "${STATUS_OUTPUT}"

assert_json_value "${TASK_DIR}/status.json" "runtime_ref" "task:${TASK_ID}"
assert_json_value "${TASK_DIR}/status.json" "session_ref" "None"
assert_json_value "${TASK_DIR}/status.json" "workspace_path" "${WORKTREE_PATH}"
assert_json_value "${TASK_DIR}/status.json" "binding_status" "partial"
assert_json_value "${STATUS_OUTPUT}" "runtime_ref" "task:${TASK_ID}"
assert_json_value "${STATUS_OUTPUT}" "session_ref" "None"
assert_json_value "${STATUS_OUTPUT}" "workspace_path" "${WORKTREE_PATH}"
assert_json_value "${STATUS_OUTPUT}" "binding_status" "partial"

printf 'runtime-binding.sh: ok\n'
