#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
BIN_DIR="${ROOT_DIR}/tests/fixtures/bin"
CHECK_OUTPUT="${TEST_TMPDIR}/check-output.json"
RENDER_OUTPUT="${TEST_TMPDIR}/render-output.json"

mkdir -p "${TMP_REPO}" "${BIN_DIR}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

write_provider_config() {
  local repo="$1"
  local command="$2"
  mkdir -p "${repo}/.agent-orch"
  python3 - "${repo}/.agent-orch/providers.json" "${command}" <<'PY'
import json
import sys

path, command = sys.argv[1:]
payload = {
    "schema_version": 1,
    "providers": {
        "opencode": {
            "provider_id": "opencode",
            "provider_kind": "external_cli",
            "supported_roles": ["explore", "implement"],
            "command_template": [command, "run", "--non-interactive", "--prompt-file", "{prompt_file}", "--report", "{report_path}"],
            "capabilities": {
                "worktree": True,
                "writes_report": True,
                "supports_readonly": True,
                "supports_timeout": True,
            },
        }
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

write_provider_config "${TMP_REPO}" "fake-opencode"
PATH="${BIN_DIR}:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"

assert_json_value "${CHECK_OUTPUT}" "provider_id" "opencode"
assert_json_value "${CHECK_OUTPUT}" "provider_kind" "external_cli"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "config_path" "${TMP_REPO}/.agent-orch/providers.json"
assert_json_array_contains "${CHECK_OUTPUT}" "supported_roles" "explore"
assert_json_array_contains "${CHECK_OUTPUT}" "supported_roles" "implement"
assert_json_array_contains "${CHECK_OUTPUT}" "command_template" "fake-opencode"
assert_json_value "${CHECK_OUTPUT}" "readiness.executable.resolved" "True"
assert_json_value "${CHECK_OUTPUT}" "readiness.temp_worktree.created" "True"
assert_json_value "${CHECK_OUTPUT}" "readiness.non_interactive.ok" "True"
assert_json_value "${CHECK_OUTPUT}" "readiness.exit_behavior.supported" "True"
assert_json_value "${CHECK_OUTPUT}" "readiness.report_finalization.ok" "True"

PATH="${BIN_DIR}:${PATH}" FAKE_OPENCODE_MODE=noninteractive-message \
  "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${TMP_REPO}" > "${CHECK_OUTPUT}"
assert_json_value "${CHECK_OUTPUT}" "ready" "True"
assert_json_value "${CHECK_OUTPUT}" "readiness.non_interactive.ok" "True"

PROMPT_FILE="${TEST_TMPDIR}/prompt.md"
TASK_DIR="${TEST_TMPDIR}/task"
TASK_JSON="${TASK_DIR}/task.json"
WORKSPACE_PATH="${TMP_REPO}"
REPORT_PATH="${TASK_DIR}/report.json"
mkdir -p "${TASK_DIR}"
printf 'prompt\n' > "${PROMPT_FILE}"
printf '{}\n' > "${TASK_JSON}"
PATH="${BIN_DIR}:${PATH}" \
  "${ROOT_DIR}/bin/agent-orch" provider render \
    --provider opencode \
    --repo "${TMP_REPO}" \
    --prompt-file "${PROMPT_FILE}" \
    --task-dir "${TASK_DIR}" \
    --task-json "${TASK_JSON}" \
    --workspace-path "${WORKSPACE_PATH}" \
    --report-path "${REPORT_PATH}" > "${RENDER_OUTPUT}"
assert_json_array_contains "${RENDER_OUTPUT}" "command" "${PROMPT_FILE}"
assert_json_array_contains "${RENDER_OUTPUT}" "command" "${REPORT_PATH}"

MISSING_REPO="${TEST_TMPDIR}/missing-config"
mkdir -p "${MISSING_REPO}"
git -C "${MISSING_REPO}" init -q
assert_agent_orch_error "provider_config_missing" \
  "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${MISSING_REPO}"

INVALID_REPO="${TEST_TMPDIR}/invalid-placeholder"
mkdir -p "${INVALID_REPO}/.agent-orch"
git -C "${INVALID_REPO}" init -q
cat > "${INVALID_REPO}/.agent-orch/providers.json" <<'JSON'
{"schema_version":1,"providers":{"opencode":{"provider_id":"opencode","provider_kind":"external_cli","supported_roles":["explore","implement"],"command_template":["fake-opencode","{bad_placeholder}"],"capabilities":{"worktree":true,"writes_report":true,"supports_readonly":true,"supports_timeout":true}}}}
JSON
assert_agent_orch_error "provider_config_invalid" \
  env PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${INVALID_REPO}"

BOOL_SCHEMA_REPO="${TEST_TMPDIR}/bool-schema"
mkdir -p "${BOOL_SCHEMA_REPO}/.agent-orch"
git -C "${BOOL_SCHEMA_REPO}" init -q
cat > "${BOOL_SCHEMA_REPO}/.agent-orch/providers.json" <<'JSON'
{"schema_version":true,"providers":{"opencode":{"provider_id":"opencode","provider_kind":"external_cli","supported_roles":["explore","implement"],"command_template":["fake-opencode","run","--non-interactive","--prompt-file","{prompt_file}","--report","{report_path}"],"capabilities":{"worktree":true,"writes_report":true,"supports_readonly":true,"supports_timeout":true}}}}
JSON
assert_agent_orch_error "provider_config_invalid" \
  env PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${BOOL_SCHEMA_REPO}"

assert_agent_orch_error "unknown_provider" \
  env PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" provider check --provider missing --repo "${TMP_REPO}"

MISSING_EXEC_REPO="${TEST_TMPDIR}/missing-exec"
mkdir -p "${MISSING_EXEC_REPO}"
git -C "${MISSING_EXEC_REPO}" init -q
write_provider_config "${MISSING_EXEC_REPO}" "does-not-exist-opencode"
assert_agent_orch_error "provider_not_ready" \
  "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${MISSING_EXEC_REPO}"

assert_agent_orch_error "provider_not_ready" \
  env FAKE_OPENCODE_MODE=interactive PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${TMP_REPO}"

assert_agent_orch_error "provider_not_ready" \
  env FAKE_OPENCODE_MODE=nonzero PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" provider check --provider opencode --repo "${TMP_REPO}"

printf 'provider-config.sh: ok\n'
