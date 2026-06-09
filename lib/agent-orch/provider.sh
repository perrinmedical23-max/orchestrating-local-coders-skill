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
  local resolved_provider_path

  case "${worker}" in
    */*|"")
      die "invalid_worker" "worker must name a fixture provider"
      ;;
  esac

  provider_dir="$(agent_orch_abs_path "${provider_dir}")"
  resolved_provider_path="${provider_dir}/${worker}.sh"

  if [[ ! -x "${resolved_provider_path}" ]]; then
    die "missing_provider" "fixture provider is not executable: ${resolved_provider_path}"
  fi

  printf -v "${__out_var}" '%s' "${resolved_provider_path}"
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
