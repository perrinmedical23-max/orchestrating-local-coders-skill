#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
BIN_DIR="${ROOT_DIR}/tests/fixtures/bin"
REVIEW_FIXTURES="${ROOT_DIR}/tests/fixtures/reviews"

mkdir -p "${TMP_REPO}/.agent-orch"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TMP_REPO}/.agent-orch/providers.json" <<'JSON'
{
  "schema_version": 1,
  "providers": {
    "opencode": {
      "provider_id": "opencode",
      "provider_kind": "external_cli",
      "supported_roles": ["explore", "implement"],
      "command_template": ["fake-opencode", "run", "--prompt-file", "{prompt_file}", "--report", "{report_path}"],
      "capabilities": {
        "worktree": true,
        "writes_report": true,
        "supports_readonly": true,
        "supports_timeout": true
      }
    }
  }
}
JSON

cat > "${TASK_FILE}" <<'EOF'
Create a deterministic worker artifact and keep changes focused.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The generated worker artifact exists and the loop can continue only through an explicit continuation command.
EOF

json_get() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key.split("."):
    value = value[part]
print(value)
PY
}

assert_file_absent() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    printf 'expected file to be absent: %s\n' "${path}" >&2
    exit 1
  fi
}

assert_json_not_null() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key.split("."):
    value = value[part]
if value is None:
    raise SystemExit(f"expected {key} to be non-null")
PY
}

assert_json_null() {
  local path="$1"
  local key="$2"
  python3 - "${path}" "${key}" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key.split("."):
    value = value[part]
if value is not None:
    raise SystemExit(f"expected {key} to be null, got {value!r}")
PY
}

start_loop() {
  local output_path="$1"
  shift
  PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" \
    "$@" > "${output_path}"
}

record_review() {
  local loop_id="$1"
  local reviewer="$2"
  local fixture="$3"
  local output_path="$4"
  "${ROOT_DIR}/bin/agent-orch" loop review \
    --loop-id "${loop_id}" \
    --repo "${TMP_REPO}" \
    --reviewer "${reviewer}" \
    --review-file "${fixture}" > "${output_path}"
}

record_blocking_reviews() {
  local loop_id="$1"
  local prefix="$2"
  record_review "${loop_id}" correctness "${REVIEW_FIXTURES}/correctness-blocked.json" "${TEST_TMPDIR}/${prefix}-correctness.json"
  record_review "${loop_id}" integration "${REVIEW_FIXTURES}/integration-passed.json" "${TEST_TMPDIR}/${prefix}-integration.json"
}

decide_loop() {
  local loop_id="$1"
  local output_path="$2"
  "${ROOT_DIR}/bin/agent-orch" loop decide \
    --loop-id "${loop_id}" \
    --repo "${TMP_REPO}" > "${output_path}"
}

continue_loop() {
  local loop_id="$1"
  local output_path="$2"
  PATH="${BIN_DIR}:${PATH}" "${ROOT_DIR}/bin/agent-orch" loop continue \
    --loop-id "${loop_id}" \
    --repo "${TMP_REPO}" > "${output_path}"
}

assert_agent_orch_error "missing_arg" \
  "${ROOT_DIR}/bin/agent-orch" loop start \
    --provider opencode \
    --role implement \
    --repo "${TMP_REPO}" \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" \
    --auto-fix

MALFORMED_LOOP_ID="malformed-loop-state"
MALFORMED_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${MALFORMED_LOOP_ID}"
MALFORMED_OUT="${TEST_TMPDIR}/malformed-loop-state.out"
MALFORMED_ERR="${TEST_TMPDIR}/malformed-loop-state.err"
mkdir -p "${MALFORMED_LOOP_DIR}"
cat > "${MALFORMED_LOOP_DIR}/loop.json" <<'JSON'
{"current_iteration":1,"auto_fix":true,"max_iterations":2}
JSON

if "${ROOT_DIR}/bin/agent-orch" loop continue \
  --loop-id "${MALFORMED_LOOP_ID}" \
  --repo "${TMP_REPO}" > "${MALFORMED_OUT}" 2> "${MALFORMED_ERR}"; then
  printf 'expected malformed loop continue to fail\n' >&2
  exit 1
fi

python3 - "${MALFORMED_ERR}" <<'PY'
import json
import sys
from pathlib import Path

stderr = Path(sys.argv[1]).read_text(encoding="utf-8")
if "Traceback" in stderr:
    raise SystemExit("expected structured error without traceback")
lines = [line.strip() for line in stderr.splitlines() if line.strip()]
if not lines:
    raise SystemExit("expected JSON error on stderr")
payload = json.loads(lines[-1])
if payload.get("error") != "loop_state_invalid":
    raise SystemExit(f"expected loop_state_invalid, got {payload.get('error')}")
if not payload.get("path"):
    raise SystemExit("expected loop state error path")
PY

AUTO_START="${TEST_TMPDIR}/auto-start.json"
AUTO_DECIDE="${TEST_TMPDIR}/auto-decide.json"
AUTO_CONTINUE="${TEST_TMPDIR}/auto-continue.json"
start_loop "${AUTO_START}" --auto-fix --max-iterations 2
AUTO_LOOP_ID="$(json_get "${AUTO_START}" "loop_id")"
AUTO_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${AUTO_LOOP_ID}"
record_blocking_reviews "${AUTO_LOOP_ID}" "auto"
decide_loop "${AUTO_LOOP_ID}" "${AUTO_DECIDE}"

AUTO_NEXT_TASK="${AUTO_LOOP_DIR}/iterations/1/next_task.json"
assert_json_value "${AUTO_DECIDE}" "decision" "auto_fix_ready"
assert_json_value "${AUTO_DECIDE}" "state" "worker_collected"
assert_json_not_null "${AUTO_DECIDE}" "next_task_path"
assert_json_value "${AUTO_DECIDE}" "next_task_path" "${AUTO_NEXT_TASK}"
assert_file_exists "${AUTO_NEXT_TASK}"
python3 - "${AUTO_NEXT_TASK}" "${ACCEPTANCE_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    task = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    acceptance = handle.read()
if task.get("original_acceptance_criteria") != acceptance:
    raise SystemExit("expected original acceptance criteria to be preserved")
blockers = task.get("blocker_summaries")
if not isinstance(blockers, list) or len(blockers) != 1:
    raise SystemExit(f"expected one blocker summary, got {blockers!r}")
blocker = blockers[0]
expected = {
    "reviewer": "correctness",
    "file": "src/example.py",
    "line": 12,
    "issue": "The result is not persisted.",
    "recommendation": "Persist the result before returning success.",
}
for key, value in expected.items():
    if blocker.get(key) != value:
        raise SystemExit(f"expected blocker {key}={value!r}, got {blocker.get(key)!r}")
if "Fix only the blocking reviewer findings" not in task.get("task_statement", ""):
    raise SystemExit("expected focused fix task statement")
PY
assert_file_absent "${AUTO_LOOP_DIR}/iterations/2"

continue_loop "${AUTO_LOOP_ID}" "${AUTO_CONTINUE}"
AUTO_ITERATION_2="${AUTO_LOOP_DIR}/iterations/2"
assert_json_value "${AUTO_CONTINUE}" "current_iteration" "2"
assert_json_value "${AUTO_CONTINUE}" "state" "worker_collected"
assert_json_value "${AUTO_LOOP_DIR}/loop.json" "current_iteration" "2"
assert_json_value "${AUTO_LOOP_DIR}/loop.json" "state" "worker_collected"
assert_file_absent "${AUTO_NEXT_TASK}"
assert_file_exists "${AUTO_LOOP_DIR}/iterations/1/next_task.consumed.json"
assert_file_exists "${AUTO_ITERATION_2}/task.json"
assert_file_exists "${AUTO_ITERATION_2}/prompt.md"
assert_file_exists "${AUTO_ITERATION_2}/report.json"
assert_file_exists "${AUTO_ITERATION_2}/stdout.log"
assert_file_exists "${AUTO_ITERATION_2}/stderr.log"
assert_file_exists "${AUTO_ITERATION_2}/provider-result.json"
assert_file_exists "${AUTO_ITERATION_2}/diff_summary"
assert_file_exists "${AUTO_ITERATION_2}/metadata.json"
assert_file_absent "${AUTO_ITERATION_2}/reviews"
assert_json_value "${AUTO_ITERATION_2}/task.json" "source_iteration" "1"
assert_json_value "${AUTO_ITERATION_2}/metadata.json" "branch_name" "agent-orch/loop-${AUTO_LOOP_ID}-2"

STALE_START="${TEST_TMPDIR}/stale-start.json"
STALE_DECIDE_1="${TEST_TMPDIR}/stale-decide-1.json"
STALE_DECIDE_2="${TEST_TMPDIR}/stale-decide-2.json"
start_loop "${STALE_START}" --auto-fix --max-iterations 2
STALE_LOOP_ID="$(json_get "${STALE_START}" "loop_id")"
STALE_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${STALE_LOOP_ID}"
record_blocking_reviews "${STALE_LOOP_ID}" "stale-1"
decide_loop "${STALE_LOOP_ID}" "${STALE_DECIDE_1}"
STALE_NEXT_TASK="${STALE_LOOP_DIR}/iterations/1/next_task.json"
assert_json_value "${STALE_DECIDE_1}" "decision" "auto_fix_ready"
assert_file_exists "${STALE_NEXT_TASK}"
record_review "${STALE_LOOP_ID}" correctness "${REVIEW_FIXTURES}/correctness-needs-human.json" "${TEST_TMPDIR}/stale-needs-human.json"
decide_loop "${STALE_LOOP_ID}" "${STALE_DECIDE_2}"
assert_json_value "${STALE_DECIDE_2}" "decision" "manual_gate"
assert_json_value "${STALE_DECIDE_2}" "state" "manual_gate"
assert_json_null "${STALE_DECIDE_2}" "next_task_path"
assert_file_absent "${STALE_NEXT_TASK}"
assert_file_exists "${STALE_LOOP_DIR}/iterations/1/next_task.stale.json"
assert_agent_orch_error "next_task_missing" \
  "${ROOT_DIR}/bin/agent-orch" loop continue \
    --loop-id "${STALE_LOOP_ID}" \
    --repo "${TMP_REPO}"
cp "${STALE_LOOP_DIR}/iterations/1/next_task.stale.json" "${STALE_NEXT_TASK}"
assert_agent_orch_error "next_task_stale" \
  "${ROOT_DIR}/bin/agent-orch" loop continue \
    --loop-id "${STALE_LOOP_ID}" \
    --repo "${TMP_REPO}"

NO_AUTO_START="${TEST_TMPDIR}/no-auto-start.json"
start_loop "${NO_AUTO_START}"
NO_AUTO_LOOP_ID="$(json_get "${NO_AUTO_START}" "loop_id")"
assert_agent_orch_error "auto_fix_not_enabled" \
  "${ROOT_DIR}/bin/agent-orch" loop continue \
    --loop-id "${NO_AUTO_LOOP_ID}" \
    --repo "${TMP_REPO}"

MAX_START="${TEST_TMPDIR}/max-start.json"
MAX_DECIDE="${TEST_TMPDIR}/max-decide.json"
start_loop "${MAX_START}" --auto-fix --max-iterations 1
MAX_LOOP_ID="$(json_get "${MAX_START}" "loop_id")"
MAX_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${MAX_LOOP_ID}"
record_blocking_reviews "${MAX_LOOP_ID}" "max"
decide_loop "${MAX_LOOP_ID}" "${MAX_DECIDE}"
assert_json_value "${MAX_DECIDE}" "decision" "max_iterations_reached"
assert_json_value "${MAX_DECIDE}" "state" "failed_max_iterations"
assert_json_value "${MAX_LOOP_DIR}/loop.json" "state" "failed_max_iterations"
assert_file_absent "${MAX_LOOP_DIR}/iterations/1/next_task.json"
assert_agent_orch_error "max_iterations_reached" \
  "${ROOT_DIR}/bin/agent-orch" loop continue \
    --loop-id "${MAX_LOOP_ID}" \
    --repo "${TMP_REPO}"

REPEAT_START="${TEST_TMPDIR}/repeat-start.json"
REPEAT_DECIDE_1="${TEST_TMPDIR}/repeat-decide-1.json"
REPEAT_CONTINUE="${TEST_TMPDIR}/repeat-continue.json"
REPEAT_ERR="${TEST_TMPDIR}/repeat.err"
REPEAT_OUT="${TEST_TMPDIR}/repeat.out"
start_loop "${REPEAT_START}" --auto-fix --max-iterations 3
REPEAT_LOOP_ID="$(json_get "${REPEAT_START}" "loop_id")"
REPEAT_LOOP_DIR="${TMP_REPO}/.superpowers/agent-orch/loops/${REPEAT_LOOP_ID}"
record_blocking_reviews "${REPEAT_LOOP_ID}" "repeat-1"
decide_loop "${REPEAT_LOOP_ID}" "${REPEAT_DECIDE_1}"
continue_loop "${REPEAT_LOOP_ID}" "${REPEAT_CONTINUE}"
record_blocking_reviews "${REPEAT_LOOP_ID}" "repeat-2"

if "${ROOT_DIR}/bin/agent-orch" loop decide \
  --loop-id "${REPEAT_LOOP_ID}" \
  --repo "${TMP_REPO}" > "${REPEAT_OUT}" 2> "${REPEAT_ERR}"; then
  printf 'expected repeated blocker decide to fail\n' >&2
  exit 1
fi

python3 - "${REPEAT_ERR}" <<'PY'
import json
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
    raise SystemExit("expected JSON error on stderr")
payload = json.loads(lines[-1])
if payload.get("error") != "repeated_blocker":
    raise SystemExit(f"expected repeated_blocker, got {payload.get('error')}")
PY

assert_json_value "${REPEAT_LOOP_DIR}/loop.json" "state" "stopped"
assert_json_value "${REPEAT_LOOP_DIR}/iterations/2/decision.json" "decision" "repeated_blocker"
assert_file_absent "${REPEAT_LOOP_DIR}/iterations/2/next_task.json"

printf 'loop-auto-fix.sh: ok\n'
