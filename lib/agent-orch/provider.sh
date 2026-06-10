# Provider boundary, v1:
# - Workers resolve to shell executables by name: <provider-dir>/<worker>.sh.
# - Providers receive exactly task_dir and task.json as positional arguments.
# - Providers run with cwd set to the assigned workspace/worktree.
# - Providers may produce a valid report, omit report.json, write invalid JSON,
#   time out, or terminate by signal.
# - The wrapper owns timeout enforcement, report validation, synthetic failed
#   reports, stdout/stderr/result artifacts, and final status persistence.
# Real claude/opencode adapters are follow-up work after their local CLI
# contracts are explicitly pinned; v1 uses deterministic fixture providers only.

agent_orch_resolve_provider_path() {
  local __out_var="$1"
  local worker="$2"
  local provider_dir="${AGENT_ORCH_PROVIDER_DIR:-${ROOT_DIR}/tests/fixtures/providers}"
  local provider_manifest_json

  agent_orch_resolve_provider_manifest_json provider_manifest_json "${worker}" "${provider_dir}"
  printf -v "${__out_var}" '%s' "$(python3 - "${provider_manifest_json}" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["provider_command"])
PY
)"
}

agent_orch_resolve_provider_manifest_json() {
  local __out_var="$1"
  local worker="$2"
  local provider_dir="${AGENT_ORCH_PROVIDER_DIR:-${ROOT_DIR}/tests/fixtures/providers}"
  local manifest_json
  local manifest_err
  local err_path

  if [[ "$#" -ge 3 ]]; then
    provider_dir="$3"
  fi

  case "${worker}" in
    */*|"")
      die "invalid_worker" "worker must name a fixture provider"
      ;;
  esac

  provider_dir="$(agent_orch_abs_path "${provider_dir}")"
  err_path="$(mktemp)"
  if ! manifest_json="$(python3 "${ROOT_DIR}/lib/agent-orch/provider_manifest.py" resolve --provider "${worker}" --provider-dir "${provider_dir}" 2> "${err_path}")"; then
    manifest_err="$(cat "${err_path}")"
    rm -f "${err_path}"
    die "$(printf '%s' "${manifest_err}" | cut -f 1)" "$(printf '%s' "${manifest_err}" | cut -f 2-)"
  fi
  rm -f "${err_path}"

  printf -v "${__out_var}" '%s' "${manifest_json}"
}

agent_orch_provider_path() {
  local worker="$1"
  local provider_path

  agent_orch_resolve_provider_path provider_path "${worker}"
  printf '%s\n' "${provider_path}"
}

agent_orch_dispatch_provider() {
  local worker="$1"
  local task_dir="$2"
  local task_json="$3"
  local worktree_path="$4"
  local provider_path
  local stdout_path="${task_dir}/stdout.log"
  local stderr_path="${task_dir}/stderr.log"
  local result_path="${task_dir}/provider-result.json"

  agent_orch_resolve_provider_path provider_path "${worker}"
  python3 "${ROOT_DIR}/lib/agent-orch/launch.py" \
    --provider "${worker}" \
    --cwd "${worktree_path}" \
    --stdout "${stdout_path}" \
    --stderr "${stderr_path}" \
    --result "${result_path}" \
    -- "${provider_path}" "${task_dir}" "${task_json}"
}
