#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
CHECK_OUTPUT="${TEST_TMPDIR}/provider-check.json"
START_OUTPUT="${TEST_TMPDIR}/loop-start.json"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-template@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch template"
cp -R "${ROOT_DIR}/examples/opencode/.agent-orch" "${TMP_REPO}/.agent-orch"
printf '# OpenCode template fixture\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md .agent-orch
git -C "${TMP_REPO}" commit -qm "Initial template fixture"

AGENT_ORCH_OPENCODE_BIN="fake-opencode" \
  PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" provider check \
  --provider opencode \
  --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"

assert_json_value "${CHECK_OUTPUT}" "provider_id" "opencode"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "config_path" "${TMP_REPO}/.agent-orch/providers.json"
assert_json_array_contains "${CHECK_OUTPUT}" "command_template" "{workspace_path}/.agent-orch/opencode-run.sh"

cat > "${TASK_FILE}" <<'EOF'
Explore README.md and summarize the repository.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The worker report completes without modifying files.
EOF

AGENT_ORCH_OPENCODE_BIN="fake-opencode" \
  PATH="${ROOT_DIR}/tests/fixtures/bin:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
  --provider opencode \
  --role explore \
  --repo "${TMP_REPO}" \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${START_OUTPUT}"

assert_json_value "${START_OUTPUT}" "report_status" "completed"
assert_json_value "${START_OUTPUT}" "error_code" "None"

printf 'opencode-template.sh: ok\n'
