#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "${ROOT_DIR}/tests/agent-orch/run-worktree.sh"
bash "${ROOT_DIR}/tests/agent-orch/status.sh"
bash "${ROOT_DIR}/tests/agent-orch/collect-success.sh"
bash "${ROOT_DIR}/tests/agent-orch/collect-failure.sh"
bash "${ROOT_DIR}/tests/agent-orch/cleanup.sh"
