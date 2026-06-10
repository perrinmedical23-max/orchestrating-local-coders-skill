#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

setup_temp_dir

TMP_REPO="${TEST_TMPDIR}/repo"
TASK_FILE="${TEST_TMPDIR}/task.md"
ACCEPTANCE_FILE="${TEST_TMPDIR}/acceptance.md"
RUN_OUTPUT="${TEST_TMPDIR}/run-output.json"
MISSING_OUT="${TEST_TMPDIR}/missing.out"
MISSING_ERR="${TEST_TMPDIR}/missing.err"
INVALID_DIR="${TEST_TMPDIR}/invalid-providers"
INVALID_OUT="${TEST_TMPDIR}/invalid.out"
INVALID_ERR="${TEST_TMPDIR}/invalid.err"

mkdir -p "${TMP_REPO}"
git -C "${TMP_REPO}" init -q
git -C "${TMP_REPO}" config user.email "agent-orch-test@example.com"
git -C "${TMP_REPO}" config user.name "agent-orch test"
printf 'initial\n' > "${TMP_REPO}/README.md"
git -C "${TMP_REPO}" add README.md
git -C "${TMP_REPO}" commit -qm "Initial commit"

cat > "${TASK_FILE}" <<'EOF'
Exercise provider manifest metadata.
EOF

cat > "${ACCEPTANCE_FILE}" <<'EOF'
Provider manifest fields are recorded in status and metadata.
EOF

AGENT_ORCH_PROVIDER_DIR="${ROOT_DIR}/tests/fixtures/providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker fake-success \
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

assert_json_value "${TASK_DIR}/metadata.json" "provider_id" "fake-success"
assert_json_value "${TASK_DIR}/metadata.json" "provider_kind" "fixture"
assert_json_value "${TASK_DIR}/metadata.json" "capabilities.worktree" "True"
assert_json_value "${TASK_DIR}/metadata.json" "capabilities.writes_report" "True"
assert_json_value "${TASK_DIR}/status.json" "provider_id" "fake-success"
assert_json_value "${TASK_DIR}/status.json" "provider_kind" "fixture"
assert_contains "${TASK_DIR}/metadata.json" "fake-success.sh"
assert_contains "${TASK_DIR}/metadata.json" "manifests/fake-success.json"

if AGENT_ORCH_PROVIDER_DIR="${TEST_TMPDIR}/no-manifest-providers" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker no-manifest \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${MISSING_OUT}" 2> "${MISSING_ERR}"; then
  printf 'expected missing provider manifest to fail\n' >&2
  exit 1
fi
assert_contains "${MISSING_ERR}" '"error":"provider_manifest_missing"'

mkdir -p "${INVALID_DIR}/manifests"
cat > "${INVALID_DIR}/bad-kind.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${INVALID_DIR}/bad-kind.sh"
cat > "${INVALID_DIR}/manifests/bad-kind.json" <<'JSON'
{"schema_version":1,"provider_id":"bad-kind","provider_kind":"real","command":"bad-kind.sh","capabilities":{"worktree":true,"writes_report":true,"streams_stdout":true,"supports_timeout":true}}
JSON

if AGENT_ORCH_PROVIDER_DIR="${INVALID_DIR}" \
  "${ROOT_DIR}/bin/agent-orch" run \
  --worker bad-kind \
  --repo "${TMP_REPO}" \
  --mode worktree \
  --task-file "${TASK_FILE}" \
  --acceptance-file "${ACCEPTANCE_FILE}" > "${INVALID_OUT}" 2> "${INVALID_ERR}"; then
  printf 'expected unsupported provider kind to fail\n' >&2
  exit 1
fi
assert_contains "${INVALID_ERR}" '"error":"unsupported_provider_kind"'

printf 'provider-manifest.sh: ok\n'
