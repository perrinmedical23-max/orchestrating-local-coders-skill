#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
COLLECT_OUTPUT="${TEST_TMPDIR}/collect-output.json"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Implement the fixture-backed collect success path.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Collect returns the worker report data and task artifacts.
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

"${ROOT_DIR}/bin/agent-orch" collect \
  --task-id "${TASK_ID}" \
  --repo "${TMP_REPO}" > "${COLLECT_OUTPUT}"

assert_json_value "${COLLECT_OUTPUT}" "task_id" "${TASK_ID}"
assert_json_value "${COLLECT_OUTPUT}" "task_dir" "${TASK_DIR}"
assert_json_value "${COLLECT_OUTPUT}" "worktree_path" "${WORKTREE_PATH}"
assert_json_value "${COLLECT_OUTPUT}" "report_path" "${TASK_DIR}/report.json"
assert_json_value "${TASK_DIR}/report.json" "status" "completed"
assert_json_value "${TASK_DIR}/report.json" "summary" "fixture success"

python3 - "${COLLECT_OUTPUT}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert isinstance(data["changed_files"], list)
assert isinstance(data["diff_summary"], str)
assert isinstance(data["tests_run"], list)
PY

if [[ -e "${TASK_DIR}/report.raw" ]]; then
  printf 'did not expect report.raw for valid success report\n' >&2
  exit 1
fi

printf 'collect-success.sh: ok\n'
