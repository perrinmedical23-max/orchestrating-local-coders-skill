#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
PROMPT_OUTPUT="${TEST_TMPDIR}/prompt-output.json"
UNSUPPORTED_ERR="${TEST_TMPDIR}/unsupported.err"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Implement the fixture-backed worktree run path.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The provider writes a completed report and all wrapper artifacts exist.
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
TASK_DIR="${TMP_REPO}/.superpowers/agent-orch/tasks/${TASK_ID}"

assert_file_exists "${TASK_DIR}"
assert_file_exists "${TASK_DIR}/task.json"
assert_file_exists "${TASK_DIR}/metadata.json"
assert_file_exists "${TASK_DIR}/status.json"
assert_file_exists "${TASK_DIR}/report.json"
assert_file_exists "${TASK_DIR}/provider-result.json"
assert_file_exists "${TASK_DIR}/stdout.log"
assert_file_exists "${TASK_DIR}/stderr.log"
assert_file_exists "${TASK_DIR}/git.diffstat"
assert_file_exists "${TASK_DIR}/diff_summary"

assert_json_value "${RUN_OUTPUT}" "status" "completed"
assert_json_value "${RUN_OUTPUT}" "task_dir" "${TASK_DIR}"
assert_json_value "${RUN_OUTPUT}" "report_path" "${TASK_DIR}/report.json"
assert_json_value "${TASK_DIR}/status.json" "status" "completed"
assert_json_value "${TASK_DIR}/report.json" "status" "completed"
assert_json_value "${TASK_DIR}/provider-result.json" "exit_code" "0"
assert_json_value "${TASK_DIR}/metadata.json" "repo_path" "${TMP_REPO}"
assert_contains "${TASK_DIR}/task.json" "Implement the fixture-backed worktree run path."
assert_contains "${TASK_DIR}/task.json" "The provider writes a completed report"

WORKTREE_PATH="$(python3 - "${TASK_DIR}/metadata.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["worktree_path"])
PY
)"
assert_file_exists "${WORKTREE_PATH}"
assert_json_value "${TASK_DIR}/metadata.json" "branch_name" "agent-orch/${TASK_ID}"

if AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
  --repo "${TMP_REPO}" \
  --mode inplace \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" 2> "${UNSUPPORTED_ERR}"; then
  printf 'expected --mode inplace to fail\n' >&2
  exit 1
fi
assert_contains "${UNSUPPORTED_ERR}" '"error":"unsupported_mode"'

PROMPT_TEXT="Implement the prompt supplied task contract."
AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
  --repo "${TMP_REPO}" \
  --prompt "${PROMPT_TEXT}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${PROMPT_OUTPUT}"

PROMPT_TASK_DIR="$(python3 - "${PROMPT_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"

assert_json_value "${PROMPT_OUTPUT}" "status" "completed"
assert_contains "${PROMPT_TASK_DIR}/task.json" "${PROMPT_TEXT}"
assert_json_value "${PROMPT_TASK_DIR}/task.json" "task_source.prompt" "${PROMPT_TEXT}"

printf 'run-worktree.sh: ok\n'
