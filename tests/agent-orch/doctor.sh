#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
DOCTOR_OUTPUT="${TEST_TMPDIR}/doctor-output.json"
BUNDLE_DIR="${TEST_TMPDIR}/bundle"
BUNDLE_OUTPUT="${TEST_TMPDIR}/bundle-output.json"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise task diagnostics.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Doctor reports task evidence and exports a diagnostics-only bundle.
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

"${ROOT_DIR}/bin/agent-orch" doctor \
  --task-id "${TASK_ID}" \
  --repo "${TMP_REPO}" > "${DOCTOR_OUTPUT}"

assert_json_value "${DOCTOR_OUTPUT}" "task_id" "${TASK_ID}"
assert_json_value "${DOCTOR_OUTPUT}" "status" "completed"
assert_json_value "${DOCTOR_OUTPUT}" "phase" "done"
assert_json_value "${DOCTOR_OUTPUT}" "worker" "fake-success"
assert_json_value "${DOCTOR_OUTPUT}" "provider_id" "fake-success"
assert_json_value "${DOCTOR_OUTPUT}" "provider_kind" "fixture"
assert_json_value "${DOCTOR_OUTPUT}" "runtime_ref" "task:${TASK_ID}"
assert_json_value "${DOCTOR_OUTPUT}" "binding_status" "partial"
assert_json_value "${DOCTOR_OUTPUT}" "report.status" "completed"
assert_json_value "${DOCTOR_OUTPUT}" "provider_result.exit_code" "0"
assert_json_value "${DOCTOR_OUTPUT}" "artifacts.stdout" "True"
assert_json_value "${DOCTOR_OUTPUT}" "artifacts.stderr" "True"
assert_json_value "${DOCTOR_OUTPUT}" "artifacts.report" "True"
assert_json_value "${DOCTOR_OUTPUT}" "artifacts.attempts" "True"
assert_json_value "${DOCTOR_OUTPUT}" "readiness.provider_dir.exists" "True"
assert_json_value "${DOCTOR_OUTPUT}" "readiness.provider_manifest.valid" "True"
assert_json_value "${DOCTOR_OUTPUT}" "readiness.provider_command.executable" "True"
assert_json_value "${DOCTOR_OUTPUT}" "readiness.repo.valid_git_repo" "True"
assert_json_value "${DOCTOR_OUTPUT}" "readiness.worktree.exists" "True"
assert_contains "${DOCTOR_OUTPUT}" "provider_running"

"${ROOT_DIR}/bin/agent-orch" doctor \
  --task-id "${TASK_ID}" \
  --repo "${TMP_REPO}" \
  --bundle "${BUNDLE_DIR}" > "${BUNDLE_OUTPUT}"

assert_json_value "${BUNDLE_OUTPUT}" "bundle_path" "${BUNDLE_DIR}"
assert_file_exists "${BUNDLE_DIR}/status.json"
assert_file_exists "${BUNDLE_DIR}/metadata.json"
assert_file_exists "${BUNDLE_DIR}/task.json"
assert_file_exists "${BUNDLE_DIR}/report.json"
assert_file_exists "${BUNDLE_DIR}/provider-result.json"
assert_file_exists "${BUNDLE_DIR}/stdout.log"
assert_file_exists "${BUNDLE_DIR}/stderr.log"
assert_file_exists "${BUNDLE_DIR}/git.diffstat"
assert_file_exists "${BUNDLE_DIR}/attempts/1/progress.log"
if [[ -e "${BUNDLE_DIR}/README.md" ]]; then
  printf 'bundle must not copy worktree files\n' >&2
  exit 1
fi
if [[ -e "${BUNDLE_DIR}/.git" ]]; then
  printf 'bundle must not copy git metadata\n' >&2
  exit 1
fi

printf 'doctor.sh: ok\n'
