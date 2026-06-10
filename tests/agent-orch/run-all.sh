#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tests=(
  "run-worktree.sh"
  "status.sh"
  "collect-success.sh"
  "collect-failure.sh"
  "cleanup.sh"
  "skill-docs.sh"
  "provider-boundary.sh"
  "provider-manifest.sh"
  "runtime-binding.sh"
  "attempts.sh"
  "doctor.sh"
)

for test_name in "${tests[@]}"; do
  test_path="${ROOT_DIR}/tests/agent-orch/${test_name}"
  if [[ ! -f "${test_path}" ]]; then
    printf 'missing test: %s\n' "${test_path}" >&2
    exit 1
  fi
  bash "${test_path}"
done
