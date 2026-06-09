agent_orch_abs_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

agent_orch_json_value() {
  local path="$1"
  local key="$2"
  python3 - "$path" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle)

for part in sys.argv[2].split("."):
    value = value[part]

print(value)
PY
}

agent_orch_new_task_id() {
  local stamp
  local suffix
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  suffix="$(printf '%s' "${stamp}-$$-${RANDOM}" | sha256sum | cut -c 1-6)"
  printf '%s-%s\n' "${stamp}" "${suffix}"
}

agent_orch_resolve_repo() {
  local repo="$1"
  if [[ ! -d "${repo}" ]]; then
    die "missing_repo" "repo does not exist: ${repo}"
  fi
  if ! git -C "${repo}" rev-parse --show-toplevel >/dev/null 2>&1; then
    die "invalid_repo" "repo is not a git repository: ${repo}"
  fi
  git -C "${repo}" rev-parse --show-toplevel
}

agent_orch_create_task_dir() {
  local repo_path="$1"
  local task_id="$2"
  local output_dir="$3"
  local task_root

  if [[ -n "${output_dir}" ]]; then
    task_root="$(agent_orch_abs_path "${output_dir}")"
  else
    task_root="${repo_path}/.superpowers/agent-orch/tasks"
  fi

  mkdir -p "${task_root}/${task_id}"
  printf '%s\n' "${task_root}/${task_id}"
}

agent_orch_resolve_task_dir() {
  local task_id="$1"
  local repo="$2"
  local task_dir="$3"
  local locator_count=0
  local resolved_task_dir

  [[ -n "${task_id}" ]] || die "missing_arg" "--task-id is required"

  if [[ -n "${repo}" ]]; then
    locator_count=$((locator_count + 1))
  fi
  if [[ -n "${task_dir}" ]]; then
    locator_count=$((locator_count + 1))
  fi
  if [[ "${locator_count}" -ne 1 ]]; then
    die "invalid_args" "provide exactly one locator: --repo or --task-dir"
  fi

  if [[ -n "${repo}" ]]; then
    local repo_path
    repo_path="$(agent_orch_resolve_repo "${repo}")"
    resolved_task_dir="${repo_path}/.superpowers/agent-orch/tasks/${task_id}"
  else
    resolved_task_dir="$(agent_orch_abs_path "${task_dir}")"
  fi

  if [[ ! -d "${resolved_task_dir}" || ! -f "${resolved_task_dir}/status.json" || ! -f "${resolved_task_dir}/metadata.json" ]]; then
    die "task_not_found" "task not found: ${task_id}"
  fi

  local stored_task_id
  stored_task_id="$(agent_orch_json_value "${resolved_task_dir}/status.json" "task_id")"
  if [[ "${stored_task_id}" != "${task_id}" ]]; then
    die "task_not_found" "task not found: ${task_id}"
  fi

  printf '%s\n' "${resolved_task_dir}"
}

agent_orch_write_task_json() {
  local path="$1"
  local task_id="$2"
  local worker="$3"
  local mode="$4"
  local repo_path="$5"
  local workspace_path="$6"
  local task_statement="$7"
  local task_file="$8"
  local prompt="$9"
  local acceptance_file="${10}"
  local acceptance_criteria="${11}"

  python3 - \
    "$path" \
    "$task_id" \
    "$worker" \
    "$mode" \
    "$repo_path" \
    "$workspace_path" \
    "$task_statement" \
    "$task_file" \
    "$prompt" \
    "$acceptance_file" \
    "$acceptance_criteria" <<'PY'
import json
import sys

(
    path,
    task_id,
    worker,
    mode,
    repo_path,
    workspace_path,
    task_statement,
    task_file,
    prompt,
    acceptance_file,
    acceptance_criteria,
) = sys.argv[1:]

payload = {
    "task_id": task_id,
    "worker": worker,
    "mode": mode,
    "repo_path": repo_path,
    "workspace_path": workspace_path,
    "task_statement": task_statement,
    "acceptance_criteria": acceptance_criteria,
    "task_source": {
        "task_file": task_file or None,
        "prompt": prompt or None,
        "acceptance_file": acceptance_file,
    },
    "constraints": {
        "allow_merge": False,
        "allow_cherry_pick": False,
        "v1_worktree_only": True,
    },
    "report_requirements": {
        "path": "report.json",
        "format": "json",
    },
    "finalization": {
        "must_write_report": True,
    },
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

agent_orch_write_status_json() {
  local path="$1"
  local task_id="$2"
  local status="$3"
  local worker="$4"
  local mode="$5"
  local repo_path="$6"
  local worktree_path="$7"
  local report_path="$8"

  python3 - "$path" "$task_id" "$status" "$worker" "$mode" "$repo_path" "$worktree_path" "$report_path" <<'PY'
import json
import sys

path, task_id, status, worker, mode, repo_path, worktree_path, report_path = sys.argv[1:]
payload = {
    "task_id": task_id,
    "status": status,
    "worker": worker,
    "mode": mode,
    "repo_path": repo_path,
    "worktree_path": worktree_path,
    "report_path": report_path,
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

agent_orch_report_status() {
  local report_path="$1"
  python3 - "$report_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        report = json.load(handle)
    print(report.get("status", "failed"))
except Exception:
    print("failed")
PY
}

agent_orch_print_run_result() {
  local task_id="$1"
  local status="$2"
  local task_dir="$3"
  local report_path="$4"

  python3 - "$task_id" "$status" "$task_dir" "$report_path" <<'PY'
import json
import sys

task_id, status, task_dir, report_path = sys.argv[1:]
print(json.dumps({
    "task_id": task_id,
    "status": status,
    "task_dir": task_dir,
    "report_path": report_path,
}, separators=(",", ":")))
PY
}

agent_orch_print_status_result() {
  local task_dir="$1"

  python3 - "${task_dir}" <<'PY'
import json
import sys
from pathlib import Path

task_dir = Path(sys.argv[1])
with (task_dir / "status.json").open("r", encoding="utf-8") as handle:
    status = json.load(handle)
with (task_dir / "metadata.json").open("r", encoding="utf-8") as handle:
    metadata = json.load(handle)

payload = {
    "task_id": status["task_id"],
    "status": status["status"],
    "mode": status["mode"],
    "worker": status.get("worker"),
    "repo_path": metadata["repo_path"],
    "worktree_path": metadata["worktree_path"],
    "report_path": str(task_dir / "report.json"),
    "log_paths": {
        "stdout": str(task_dir / "stdout.log"),
        "stderr": str(task_dir / "stderr.log"),
    },
}

print(json.dumps(payload, separators=(",", ":")))
PY
}
