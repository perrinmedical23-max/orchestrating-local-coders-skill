#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
MISSING_TARGET_OUTPUT="${TEST_TMPDIR}/missing-target-output.json"
MULTIPLE_TARGETS_OUTPUT="${TEST_TMPDIR}/multiple-targets-output.json"

cat > "${TASK_FILE}" <<'EOF'
Implement cleanup behavior for task artifacts.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Cleanup removes only the explicitly requested task artifact.
EOF

create_repo() {
  local repo_path="$1"

  mkdir -p "${repo_path}"
  git -C "${repo_path}" init -q
  git -C "${repo_path}" config user.email "agent-orch-test@example.com"
  git -C "${repo_path}" config user.name "agent-orch test"
  printf 'initial\n' > "${repo_path}/README.md"
  git -C "${repo_path}" add README.md
  git -C "${repo_path}" commit -qm "Initial commit"
}

run_fixture_task() {
  local repo_path="$1"
  local output_path="$2"

  AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
    "${ROOT_DIR}/bin/agent-orch" run \
    --worker fake-success \
    --repo "${repo_path}" \
    --mode worktree \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${output_path}"
}

json_field() {
  local path="$1"
  local key="$2"

  python3 - "${path}" "${key}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in sys.argv[2].split("."):
    value = value[part]

print(value)
PY
}

assert_path_missing() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    printf 'expected path to be removed: %s\n' "${path}" >&2
    exit 1
  fi
}

REMOVE_WORKTREE_REPO="${TEST_TMPDIR}/remove-worktree-repo"
REMOVE_WORKTREE_OUTPUT="${TEST_TMPDIR}/remove-worktree-run.json"
create_repo "${REMOVE_WORKTREE_REPO}"
run_fixture_task "${REMOVE_WORKTREE_REPO}" "${REMOVE_WORKTREE_OUTPUT}"
REMOVE_WORKTREE_TASK_ID="$(json_field "${REMOVE_WORKTREE_OUTPUT}" "task_id")"
REMOVE_WORKTREE_TASK_DIR="$(json_field "${REMOVE_WORKTREE_OUTPUT}" "task_dir")"
REMOVE_WORKTREE_PATH="$(json_field "${REMOVE_WORKTREE_TASK_DIR}/metadata.json" "worktree_path")"

"${ROOT_DIR}/bin/agent-orch" cleanup \
  --task-id "${REMOVE_WORKTREE_TASK_ID}" \
  --repo "${REMOVE_WORKTREE_REPO}" \
  --remove-worktree > "${TEST_TMPDIR}/remove-worktree-cleanup.json"

assert_path_missing "${REMOVE_WORKTREE_PATH}"
assert_file_exists "${REMOVE_WORKTREE_TASK_DIR}"
assert_file_exists "${REMOVE_WORKTREE_TASK_DIR}/metadata.json"

REMOVE_STATE_REPO="${TEST_TMPDIR}/remove-state-repo"
REMOVE_STATE_OUTPUT="${TEST_TMPDIR}/remove-state-run.json"
create_repo "${REMOVE_STATE_REPO}"
run_fixture_task "${REMOVE_STATE_REPO}" "${REMOVE_STATE_OUTPUT}"
REMOVE_STATE_TASK_ID="$(json_field "${REMOVE_STATE_OUTPUT}" "task_id")"
REMOVE_STATE_TASK_DIR="$(json_field "${REMOVE_STATE_OUTPUT}" "task_dir")"
REMOVE_STATE_WORKTREE_PATH="$(json_field "${REMOVE_STATE_TASK_DIR}/metadata.json" "worktree_path")"

"${ROOT_DIR}/bin/agent-orch" cleanup \
  --task-id "${REMOVE_STATE_TASK_ID}" \
  --task-dir "${REMOVE_STATE_TASK_DIR}" \
  --remove-state > "${TEST_TMPDIR}/remove-state-cleanup.json"

assert_path_missing "${REMOVE_STATE_TASK_DIR}"
assert_file_exists "${REMOVE_STATE_WORKTREE_PATH}"

ALL_REPO="${TEST_TMPDIR}/all-repo"
ALL_OUTPUT="${TEST_TMPDIR}/all-run.json"
create_repo "${ALL_REPO}"
run_fixture_task "${ALL_REPO}" "${ALL_OUTPUT}"
ALL_TASK_ID="$(json_field "${ALL_OUTPUT}" "task_id")"
ALL_TASK_DIR="$(json_field "${ALL_OUTPUT}" "task_dir")"
ALL_WORKTREE_PATH="$(json_field "${ALL_TASK_DIR}/metadata.json" "worktree_path")"

"${ROOT_DIR}/bin/agent-orch" cleanup \
  --task-id "${ALL_TASK_ID}" \
  --repo "${ALL_REPO}" \
  --all > "${TEST_TMPDIR}/all-cleanup.json"

assert_path_missing "${ALL_WORKTREE_PATH}"
assert_path_missing "${ALL_TASK_DIR}"

if "${ROOT_DIR}/bin/agent-orch" cleanup \
  --task-id "${REMOVE_WORKTREE_TASK_ID}" \
  --repo "${REMOVE_WORKTREE_REPO}" > "${MISSING_TARGET_OUTPUT}" 2>&1; then
  printf 'expected cleanup without a removal target to fail\n' >&2
  exit 1
fi
assert_json_value "${MISSING_TARGET_OUTPUT}" "error" "invalid_args"

if "${ROOT_DIR}/bin/agent-orch" cleanup \
  --task-id "${REMOVE_WORKTREE_TASK_ID}" \
  --repo "${REMOVE_WORKTREE_REPO}" \
  --remove-worktree \
  --remove-state > "${MULTIPLE_TARGETS_OUTPUT}" 2>&1; then
  printf 'expected cleanup with multiple removal targets to fail\n' >&2
  exit 1
fi
assert_json_value "${MULTIPLE_TARGETS_OUTPUT}" "error" "invalid_args"

printf 'cleanup.sh: ok\n'
