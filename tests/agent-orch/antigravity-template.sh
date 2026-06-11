#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
CHECK_OUTPUT="${TEST_TMPDIR}/provider-check.json"
CHECK_LOG="${TEST_TMPDIR}/fake-agy-check.log"
START_OUTPUT="${TEST_TMPDIR}/loop-start.json"
START_LOG="${TEST_TMPDIR}/fake-agy-start.log"
BAD_OUT="${TEST_TMPDIR}/bad-readiness.out"
BAD_ERR="${TEST_TMPDIR}/bad-readiness.err"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-antigravity@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch antigravity"
cp -R "${ROOT_DIR}/examples/antigravity/.agent-orch" "${TMP_REPO}/.agent-orch"
printf '# Antigravity template fixture\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md .agent-orch
git -C "${TMP_REPO}" commit -qm "Initial antigravity fixture"

AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
AGENT_ORCH_ANTIGRAVITY_MODEL="Gemini 3.5 Flash (High)" \
FAKE_AGY_LOG="${CHECK_LOG}" \
PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" provider check \
  --provider antigravity \
  --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"

assert_json_value "${CHECK_OUTPUT}" "provider_id" "antigravity"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "config_path" "${TMP_REPO}/.agent-orch/providers.json"
assert_json_array_contains "${CHECK_OUTPUT}" "command_template" "{workspace_path}/.agent-orch/agy-run.sh"
assert_contains "${CHECK_LOG}" "model=Gemini 3.5 Flash (High)"
assert_contains "${CHECK_LOG}" "prompt=Respond with exactly: AGY_OK"

if AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
  FAKE_AGY_MODE="bad-readiness" \
  PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
    "${ROOT_DIR}/bin/agent-orch" provider check \
    --provider antigravity \
    --repo "${TMP_REPO}" > "${BAD_OUT}" 2> "${BAD_ERR}"; then
  printf 'expected bad readiness sentinel to fail\n' >&2
  exit 1
fi
assert_contains "${BAD_ERR}" '"error":"provider_not_ready"'

cat > "${TASK_FILE}" <<'EOF'
Explore README.md and summarize the repository.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The worker report completes without modifying files.
EOF

AGENT_ORCH_ANTIGRAVITY_BIN="fake-agy" \
AGENT_ORCH_ANTIGRAVITY_MODEL="Gemini 3.5 Flash (High)" \
FAKE_AGY_LOG="${START_LOG}" \
PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider antigravity \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${START_OUTPUT}"

assert_json_value "${START_OUTPUT}" "report_status" "completed"
assert_json_value "${START_OUTPUT}" "error_code" "None"
assert_contains "${START_LOG}" "model=Gemini 3.5 Flash (High)"
assert_contains "${START_LOG}" "Role: explore"

printf 'antigravity-template.sh: ok\n'
