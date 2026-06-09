agent_orch_provider_path() {
  local worker="$1"
  local provider_dir="${AGENT_ORCH_PROVIDER_DIR:-${ROOT_DIR}/tests/fixtures/providers}"
  local provider_path

  case "${worker}" in
    */*|"")
      die "invalid_worker" "worker must name a fixture provider"
      ;;
  esac

  provider_dir="$(agent_orch_abs_path "${provider_dir}")"
  provider_path="${provider_dir}/${worker}.sh"

  if [[ ! -x "${provider_path}" ]]; then
    die "missing_provider" "fixture provider is not executable: ${provider_path}"
  fi

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

  provider_path="$(agent_orch_provider_path "${worker}")"
  python3 "${ROOT_DIR}/lib/agent-orch/launch.py" \
    --provider "${worker}" \
    --cwd "${worktree_path}" \
    --stdout "${stdout_path}" \
    --stderr "${stderr_path}" \
    --result "${result_path}" \
    -- "${provider_path}" "${task_dir}" "${task_json}"
}
