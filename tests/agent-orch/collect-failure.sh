#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
BAD_PROVIDER_DIR="${TEST_TMPDIR}/bad-provider"
INCONSISTENT_PROVIDER_DIR="${TEST_TMPDIR}/inconsistent-provider"
PARTIAL_PROVIDER_DIR="${TEST_TMPDIR}/partial-provider"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise crash-safe report synthesis.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
The wrapper records a valid failed report for provider failure modes.
EOF

run_failure_case() {
  local worker="$1"
  local expect_raw="$2"
  local expected_timed_out="$3"
  local expect_signal="$4"
  local run_output="${TEST_TMPDIR}/${worker}-run.json"
  local collect_output="${TEST_TMPDIR}/${worker}-collect.json"

  AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  AGENT_ORCH_TIMEOUT_SECS=1 \
    "${ROOT_DIR}/bin/agent-orch" run \
    --worker "${worker}" \
    --repo "${TMP_REPO}" \
    --mode worktree \
    --task-file "${TASK_FILE}" \
    --acceptance-file "${ACCEPTANCE_FILE}" > "${run_output}"

  local task_id
  task_id="$(python3 - "${run_output}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"

  local task_dir
  task_dir="$(python3 - "${run_output}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"

  "${ROOT_DIR}/bin/agent-orch" collect \
    --task-id "${task_id}" \
    --repo "${TMP_REPO}" > "${collect_output}"

  assert_file_exists "${task_dir}/report.json"
  assert_file_exists "${task_dir}/provider-result.json"
  assert_json_value "${run_output}" "status" "failed"
  assert_json_value "${task_dir}/report.json" "status" "failed"
  assert_json_value "${collect_output}" "task_id" "${task_id}"
  assert_json_value "${collect_output}" "report_path" "${task_dir}/report.json"
  assert_json_value "${task_dir}/provider-result.json" "timed_out" "${expected_timed_out}"

  if [[ "${expect_raw}" == "yes" ]]; then
    assert_file_exists "${task_dir}/report.raw"
    assert_json_value "${task_dir}/report.json" "diagnostics.raw_report_path" "${task_dir}/report.raw"
    cp "${task_dir}/report.raw" "${TEST_TMPDIR}/${worker}.first-raw"
    printf 'second invalid payload\n' > "${task_dir}/report.json"
    "${ROOT_DIR}/bin/agent-orch" collect \
      --task-id "${task_id}" \
      --repo "${TMP_REPO}" > "${collect_output}"
    cmp "${TEST_TMPDIR}/${worker}.first-raw" "${task_dir}/report.raw"
  elif [[ -e "${task_dir}/report.raw" ]]; then
    printf 'did not expect report.raw for %s\n' "${worker}" >&2
    exit 1
  fi

  python3 - "${task_dir}/report.json" "${expect_signal}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

diagnostics = report["diagnostics"]
if diagnostics["stdout_path"] is None or diagnostics["stderr_path"] is None:
    raise SystemExit("expected stdout/stderr paths")

expect_signal = sys.argv[2] == "yes"
if expect_signal and diagnostics["signal"] is None:
    raise SystemExit("expected non-null signal")
if not expect_signal and diagnostics["signal"] is not None:
    raise SystemExit("expected null signal")
PY
}

run_failure_case fake-missing-report no False no
run_failure_case fake-invalid-report yes False no
run_failure_case fake-timeout no True no
run_failure_case fake-signal no False yes

mkdir -p "${INCONSISTENT_PROVIDER_DIR}"
cat > "${INCONSISTENT_PROVIDER_DIR}/fake-completed-nonzero.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_dir="$1"
cat > "${task_dir}/report.json" <<'JSON'
{"status":"completed","summary":"inconsistent provider result","files_changed":[],"tests_run":[],"open_questions":[],"risks":[],"notes":[]}
JSON
exit 42
EOF
chmod +x "${INCONSISTENT_PROVIDER_DIR}/fake-completed-nonzero.sh"
agent_orch_write_fixture_manifest "${INCONSISTENT_PROVIDER_DIR}" "fake-completed-nonzero" "fake-completed-nonzero.sh"

INCONSISTENT_RUN_OUTPUT="${TEST_TMPDIR}/completed-nonzero-run.json"
INCONSISTENT_COLLECT_OUTPUT="${TEST_TMPDIR}/completed-nonzero-collect.json"
AGENT_ORCH_PROVIDER_DIR="${INCONSISTENT_PROVIDER_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-completed-nonzero \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${INCONSISTENT_RUN_OUTPUT}"

INCONSISTENT_TASK_ID="$(python3 - "${INCONSISTENT_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"
INCONSISTENT_TASK_DIR="$(python3 - "${INCONSISTENT_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
assert_json_value "${INCONSISTENT_RUN_OUTPUT}" "status" "failed"
assert_json_value "${INCONSISTENT_TASK_DIR}/report.json" "status" "failed"
assert_json_value "${INCONSISTENT_TASK_DIR}/report.json" "diagnostics.exit_code" "42"
"${ROOT_DIR}/bin/agent-orch" collect \
  --task-id "${INCONSISTENT_TASK_ID}" \
  --repo "${TMP_REPO}" > "${INCONSISTENT_COLLECT_OUTPUT}"
assert_json_value "${INCONSISTENT_TASK_DIR}/status.json" "status" "failed"
assert_json_value "${INCONSISTENT_COLLECT_OUTPUT}" "task_id" "${INCONSISTENT_TASK_ID}"

mkdir -p "${PARTIAL_PROVIDER_DIR}"
cat > "${PARTIAL_PROVIDER_DIR}/fake-partial-nonzero.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_dir="$1"
cat > "${task_dir}/report.json" <<'JSON'
{"status":"partial","summary":"partial progress with open questions","files_changed":["README.md"],"tests_run":[],"open_questions":["needs coordinator review"],"risks":[],"notes":[]}
JSON
exit 42
EOF
chmod +x "${PARTIAL_PROVIDER_DIR}/fake-partial-nonzero.sh"
agent_orch_write_fixture_manifest "${PARTIAL_PROVIDER_DIR}" "fake-partial-nonzero" "fake-partial-nonzero.sh"

PARTIAL_RUN_OUTPUT="${TEST_TMPDIR}/partial-nonzero-run.json"
PARTIAL_COLLECT_OUTPUT="${TEST_TMPDIR}/partial-nonzero-collect.json"
AGENT_ORCH_PROVIDER_DIR="${PARTIAL_PROVIDER_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-partial-nonzero \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${PARTIAL_RUN_OUTPUT}"

PARTIAL_TASK_ID="$(python3 - "${PARTIAL_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"
PARTIAL_TASK_DIR="$(python3 - "${PARTIAL_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
assert_json_value "${PARTIAL_RUN_OUTPUT}" "status" "partial"
assert_json_value "${PARTIAL_TASK_DIR}/report.json" "status" "partial"
assert_json_value "${PARTIAL_TASK_DIR}/report.json" "summary" "partial progress with open questions"
"${ROOT_DIR}/bin/agent-orch" collect \
  --task-id "${PARTIAL_TASK_ID}" \
  --repo "${TMP_REPO}" > "${PARTIAL_COLLECT_OUTPUT}"
assert_json_value "${PARTIAL_TASK_DIR}/status.json" "status" "partial"
assert_contains "${PARTIAL_COLLECT_OUTPUT}" "README.md"

mkdir -p "${BAD_PROVIDER_DIR}"
cat > "${BAD_PROVIDER_DIR}/fake-bad-shebang.sh" <<'EOF'
#!/not/a/real/interpreter
EOF
chmod +x "${BAD_PROVIDER_DIR}/fake-bad-shebang.sh"
agent_orch_write_fixture_manifest "${BAD_PROVIDER_DIR}" "fake-bad-shebang" "fake-bad-shebang.sh"

BAD_RUN_OUTPUT="${TEST_TMPDIR}/bad-shebang-run.json"
AGENT_ORCH_PROVIDER_DIR="${BAD_PROVIDER_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-bad-shebang \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${BAD_RUN_OUTPUT}"

BAD_TASK_DIR="$(python3 - "${BAD_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
assert_json_value "${BAD_RUN_OUTPUT}" "status" "failed"
assert_file_exists "${BAD_TASK_DIR}/provider-result.json"
assert_file_exists "${BAD_TASK_DIR}/stderr.log"
assert_json_value "${BAD_TASK_DIR}/provider-result.json" "exit_code" "127"
assert_contains "${BAD_TASK_DIR}/stderr.log" "failed to launch provider"

SUCCESS_RUN_OUTPUT="${TEST_TMPDIR}/success-for-repair-run.json"
SUCCESS_COLLECT_OUTPUT="${TEST_TMPDIR}/success-for-repair-collect.json"
AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${SUCCESS_RUN_OUTPUT}"

SUCCESS_TASK_ID="$(python3 - "${SUCCESS_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"
SUCCESS_TASK_DIR="$(python3 - "${SUCCESS_RUN_OUTPUT}" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["task_dir"])
PY
)"
rm -f "${SUCCESS_TASK_DIR}/report.json"
"${ROOT_DIR}/bin/agent-orch" collect \
  --task-id "${SUCCESS_TASK_ID}" \
  --repo "${TMP_REPO}" > "${SUCCESS_COLLECT_OUTPUT}"
assert_json_value "${SUCCESS_TASK_DIR}/report.json" "status" "failed"
assert_json_value "${SUCCESS_TASK_DIR}/status.json" "status" "failed"

printf 'collect-failure.sh: ok\n'
