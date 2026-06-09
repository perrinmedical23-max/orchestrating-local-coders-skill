agent_orch_create_worktree() {
  local repo_path="$1"
  local task_id="$2"
  local metadata_path="$3"
  local branch_name="agent-orch/${task_id}"
  local base_rev
  local worktree_parent
  local worktree_path

  base_rev="$(git -C "${repo_path}" rev-parse HEAD)"
  worktree_parent="${repo_path}.worktrees"
  worktree_path="${worktree_parent}/agent-orch-${task_id}"

  mkdir -p "${worktree_parent}"
  git -C "${repo_path}" worktree add -q -b "${branch_name}" "${worktree_path}" "${base_rev}"

  python3 - "$metadata_path" "$repo_path" "$worktree_path" "$branch_name" "$base_rev" <<'PY'
import json
import sys

metadata_path, repo_path, worktree_path, branch_name, base_rev = sys.argv[1:]
payload = {
    "repo_path": repo_path,
    "worktree_path": worktree_path,
    "branch_name": branch_name,
    "base_rev": base_rev,
}

with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

  printf '%s\n' "${worktree_path}"
}

agent_orch_remove_worktree() {
  local repo_path="$1"
  local worktree_path="$2"

  if ! git -C "${repo_path}" worktree remove --force "${worktree_path}"; then
    git -C "${repo_path}" worktree prune
    if [[ -e "${worktree_path}" ]]; then
      die "worktree_remove_failed" "failed to remove worktree: ${worktree_path}"
    fi
  fi
}
