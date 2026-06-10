#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
PROVIDER_DIR="${TEST_TMPDIR}/providers"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
UNKNOWN_OUT="${TEST_TMPDIR}/unknown.out"
UNKNOWN_ERR="${TEST_TMPDIR}/unknown.err"
README="${ROOT_DIR}/README.md"

mkdir -p "${TMP_REPO}" "${PROVIDER_DIR}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise the provider boundary.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The provider receives task_dir and task.json and runs inside the assigned workspace.
EOF

cat > "${PROVIDER_DIR}/fake-boundary.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'expected exactly task_dir and task.json, got %s args\n' "$#" >&2
  exit 2
fi

task_dir="$1"
task_json="$2"

python3 - "${task_dir}" "${task_json}" "$(pwd)" <<'PY'
import json
import sys

task_dir, task_json, cwd = sys.argv[1:]
with open(task_json, "r", encoding="utf-8") as handle:
    task = json.load(handle)

if task["workspace_path"] != cwd:
    raise SystemExit(f"expected cwd {task['workspace_path']}, got {cwd}")
if task["worker"] != "fake-boundary":
    raise SystemExit("unexpected worker")
if task["mode"] != "worktree":
    raise SystemExit("unexpected mode")
if task["report_requirements"]["path"] != "report.json":
    raise SystemExit("unexpected report path")
if task["constraints"]["v1_worktree_only"] is not True:
    raise SystemExit("expected v1 worktree-only constraint")
if task_dir == cwd:
    raise SystemExit("task_dir should be state storage, not workspace cwd")
PY

printf 'boundary cwd: %s\n' "$(pwd)"
cat > "${task_dir}/report.json" <<'JSON'
{"status":"completed","summary":"boundary fixture success","files_changed":[],"tests_run":[],"open_questions":[],"risks":[],"notes":[]}
JSON
EOF
chmod +x "${PROVIDER_DIR}/fake-boundary.sh"
agent_orch_write_fixture_manifest "${PROVIDER_DIR}" "fake-boundary" "fake-boundary.sh"

AGENT_ORCH_PROVIDER_DIR="${PROVIDER_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-boundary \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${RUN_OUTPUT}"

TASK_DIR="$(python3 - "${RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"

assert_json_value "${RUN_OUTPUT}" "status" "completed"
assert_json_value "${TASK_DIR}/status.json" "status" "completed"
assert_json_value "${TASK_DIR}/provider-result.json" "provider" "fake-boundary"
assert_json_value "${TASK_DIR}/provider-result.json" "exit_code" "0"
assert_json_value "${TASK_DIR}/report.json" "summary" "boundary fixture success"
assert_contains "${TASK_DIR}/stdout.log" "boundary cwd:"

if AGENT_ORCH_PROVIDER_DIR="${PROVIDER_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker does-not-exist \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${UNKNOWN_OUT}" 2> "${UNKNOWN_ERR}"; then
  printf 'expected missing provider to fail\n' >&2
  exit 1
fi

python3 - "${UNKNOWN_ERR}" <<'PY'
import json
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
if len(lines) != 1:
    raise SystemExit(f"expected one JSON error line, got {len(lines)}")
payload = json.loads(lines[0])
if payload.get("status") != "failed":
    raise SystemExit("expected failed status")
if payload.get("error") != "provider_manifest_missing":
    raise SystemExit(f"expected provider_manifest_missing, got {payload.get('error')}")
if "does-not-exist.json" not in payload.get("message", ""):
    raise SystemExit("expected manifest path in error message")
PY

assert_contains "${README}" "Runtime dependencies: \`bash\`, \`git\`, and \`python3\`."
assert_contains "${README}" "bash tests/agent-orch/run-all.sh"
assert_contains "${README}" "AGENT_ORCH_PROVIDER_DIR"
assert_contains "${README}" "worktree-only v1"
assert_contains "${README}" "bash scripts/install-skill.sh"
assert_contains "${README}" "deterministic fixture-provider v1.1 scope"
assert_contains "${README}" "Real \`claude\` and \`opencode\` adapters are follow-up work once local CLI contracts are explicitly pinned."

printf 'provider-boundary.sh: ok\n'
