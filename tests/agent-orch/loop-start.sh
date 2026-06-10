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
MISSING_REPO="${TEST_TMPDIR}/missing-repo"
NON_GIT_REPO="${TEST_TMPDIR}/non-git"

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

"${ROOT_DIR}/bin/agent-orch" loop start \
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

assert_json_value "${START_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${START_OUTPUT}" "state" "created"
assert_json_value "${START_OUTPUT}" "status" "created"
assert_json_value "${START_OUTPUT}" "current_iteration" "1"
assert_json_value "${START_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_file_exists "${LOOP_JSON}"
assert_file_exists "${TASK_JSON}"

if [[ -e "${LOOP_DIR}/iterations/1/report.json" || -e "${LOOP_DIR}/iterations/1/provider-result.json" ]]; then
  printf 'did not expect worker execution artifacts during skeleton loop start\n' >&2
  exit 1
fi

"${ROOT_DIR}/bin/agent-orch" loop status \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" > "${STATUS_OUTPUT}"

assert_json_value "${STATUS_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${STATUS_OUTPUT}" "state" "created"
assert_json_value "${STATUS_OUTPUT}" "status" "created"
assert_json_value "${STATUS_OUTPUT}" "current_iteration" "1"
assert_json_value "${STATUS_OUTPUT}" "loop_dir" "${LOOP_DIR}"

"${ROOT_DIR}/bin/agent-orch" loop collect \
  --loop-id "${LOOP_ID}" \
  --repo "${TMP_REPO}" > "${COLLECT_OUTPUT}"

assert_json_value "${COLLECT_OUTPUT}" "loop_id" "${LOOP_ID}"
assert_json_value "${COLLECT_OUTPUT}" "state" "created"
assert_json_value "${COLLECT_OUTPUT}" "status" "created"
assert_json_value "${COLLECT_OUTPUT}" "current_iteration" "1"
assert_json_value "${COLLECT_OUTPUT}" "loop_dir" "${LOOP_DIR}"
assert_json_value "${COLLECT_OUTPUT}" "task_path" "${TASK_JSON}"

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
assert data["state"] == "created"
assert data["current_iteration"] == 1
assert data["auto_fix"] is False
assert data["max_iterations"] is None
assert data["repo_path"] == repo
assert isinstance(data["created_at"], str) and data["created_at"]
assert isinstance(data["updated_at"], str) and data["updated_at"]
PY

"${ROOT_DIR}/bin/agent-orch" loop start \
  --provider opencode \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${EXPLORE_OUTPUT}"

assert_json_value "${EXPLORE_OUTPUT}" "state" "created"
assert_json_value "${EXPLORE_OUTPUT}" "current_iteration" "1"

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
