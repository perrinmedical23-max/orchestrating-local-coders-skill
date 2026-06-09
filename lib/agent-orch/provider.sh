agent_orch_provider_path() {
  local worker="$1"
  local provider_dir="${AGENT_ORCH_PROVIDER_DIR:-${ROOT_DIR}/tests/fixtures/providers}"
  local provider_path="${provider_dir}/${worker}.sh"

  case "${worker}" in
    */*|"")
      die "invalid_worker" "worker must name a fixture provider"
      ;;
  esac

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
  local started_at
  local finished_at
  local exit_code

  provider_path="$(agent_orch_provider_path "${worker}")"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  set +e
  (
    cd "${worktree_path}"
    "${provider_path}" "${task_dir}" "${task_json}"
  ) >"${stdout_path}" 2>"${stderr_path}"
  exit_code="$?"
  set -e

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - "$result_path" "$worker" "$provider_path" "$exit_code" "$started_at" "$finished_at" <<'PY'
import json
import sys

result_path, worker, provider_path, exit_code, started_at, finished_at = sys.argv[1:]
payload = {
    "worker": worker,
    "provider_path": provider_path,
    "exit_code": int(exit_code),
    "signal": None,
    "timed_out": False,
    "started_at": started_at,
    "finished_at": finished_at,
}

with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

  return "${exit_code}"
}
