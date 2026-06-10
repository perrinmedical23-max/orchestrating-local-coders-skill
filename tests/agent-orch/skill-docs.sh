#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/tests/test-helpers.sh"

SKILL_DIR="${ROOT_DIR}/skills/coordinating-local-agents"
SKILL_MD="${SKILL_DIR}/SKILL.md"
TASK_CONTRACT="${SKILL_DIR}/references/task-contract.md"
REPORT_SCHEMA="${SKILL_DIR}/references/report-schema.md"
ROUTING_GUIDELINES="${SKILL_DIR}/references/routing-guidelines.md"
RESULT_HANDLING="${SKILL_DIR}/references/result-handling.md"
INSTALL_SCRIPT="${ROOT_DIR}/scripts/install-skill.sh"
README="${ROOT_DIR}/README.md"
RUN_ALL="${ROOT_DIR}/tests/agent-orch/run-all.sh"

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq "${unexpected}" "${path}"; then
    printf 'expected %s not to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

assert_file_exists "${SKILL_MD}"
assert_file_exists "${TASK_CONTRACT}"
assert_file_exists "${REPORT_SCHEMA}"
assert_file_exists "${ROUTING_GUIDELINES}"
assert_file_exists "${RESULT_HANDLING}"
assert_file_exists "${INSTALL_SCRIPT}"

python3 - "${SKILL_MD}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if not text.startswith("---\n"):
    raise SystemExit("SKILL.md must start with YAML frontmatter")

try:
    _, frontmatter, body = text.split("---\n", 2)
except ValueError:
    raise SystemExit("SKILL.md frontmatter is not closed")

fields = {}
for line in frontmatter.splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()

if fields.get("name") != "coordinating-local-agents":
    raise SystemExit("SKILL.md must define name: coordinating-local-agents")
if set(fields) != {"name", "description"}:
    raise SystemExit("SKILL.md frontmatter must contain only name and description")

description = fields.get("description", "")
if not description:
    raise SystemExit("SKILL.md must define description")

if not description.startswith("Use when"):
    raise SystemExit("SKILL.md description must start with Use when")
description_lower = description.lower()
if "delegate" not in description_lower:
    raise SystemExit("SKILL.md description must be trigger-oriented")

if len(description.split()) > 40:
    raise SystemExit("SKILL.md description should stay concise")

if not body.strip():
    raise SystemExit("SKILL.md must include body instructions")
PY

for command_name in run status collect cleanup; do
  assert_contains "${SKILL_MD}" "agent-orch ${command_name}"
done

for reference in task-contract.md report-schema.md routing-guidelines.md result-handling.md; do
  assert_contains "${SKILL_MD}" "references/${reference}"
done

assert_contains "${SKILL_MD}" "Real \`claude\` and \`opencode\` adapters"
assert_contains "${SKILL_MD}" "follow-up work only"
assert_contains "${SKILL_MD}" "fixture-provider-only v1.1"
assert_contains "${SKILL_MD}" "sessions"
assert_contains "${SKILL_MD}" "\`--mode inplace\`"
assert_contains "${SKILL_MD}" "\`unsupported_mode\`"
assert_contains "${SKILL_MD}" "Codex-only"
assert_contains "${SKILL_MD}" "agent-orch doctor"
assert_contains "${SKILL_MD}" "diagnostics"
assert_contains "${SKILL_MD}" "not scheduling authority"
assert_contains "${SKILL_MD}" "Do not invent a substitute worker answer"
assert_contains "${SKILL_MD}" "status can summarize"
assert_contains "${SKILL_MD}" "collect output must preserve"
assert_contains "${SKILL_MD}" "agent-orch provider check"
assert_contains "${SKILL_MD}" "agent-orch loop start"
assert_contains "${SKILL_MD}" "agent-orch loop review"
assert_contains "${SKILL_MD}" "agent-orch loop decide"
assert_contains "${SKILL_MD}" "agent-orch loop continue"
assert_contains "${SKILL_MD}" " --reviewer correctness"
assert_contains "${SKILL_MD}" " --reviewer integration"
assert_contains "${SKILL_MD}" "manual gate default"
assert_contains "${SKILL_MD}" "\`--auto-fix --max-iterations\`"

assert_contains "${SKILL_MD}" "wrapper core"
assert_contains "${SKILL_MD}" "worktree execution"
assert_contains "${SKILL_MD}" "task state"
assert_contains "${SKILL_MD}" "synthetic failed reports"
assert_contains "${SKILL_MD}" "deterministic fixture providers"
assert_contains "${SKILL_MD}" "skill install path"

assert_contains "${SKILL_MD}" "\`status\`, \`collect\`, and \`cleanup\` are task-only"
assert_contains "${SKILL_MD}" "\`--task-id\`"
assert_contains "${SKILL_MD}" "\`--repo\` or \`--task-dir\` only to locate the task store"

assert_contains "${TASK_CONTRACT}" "\`task_id\`"
assert_contains "${TASK_CONTRACT}" "\`workspace_path\`"
assert_contains "${TASK_CONTRACT}" "\`task_statement\`"
assert_contains "${TASK_CONTRACT}" "\`acceptance_criteria\`"
assert_contains "${TASK_CONTRACT}" "\`constraints\`"
assert_contains "${TASK_CONTRACT}" "\`report_requirements\`"
assert_contains "${TASK_CONTRACT}" "\`finalization\`"
assert_contains "${TASK_CONTRACT}" "Provider and runtime binding details are not part of the v1.1 task payload"
assert_contains "${TASK_CONTRACT}" "\`metadata.json\`"
assert_contains "${TASK_CONTRACT}" "\`status.json\`"
assert_contains "${TASK_CONTRACT}" "\`agent-orch status\` and \`agent-orch doctor\`"
assert_contains "${TASK_CONTRACT}" "\`loop_id\`"
assert_contains "${TASK_CONTRACT}" "\`iteration\`"
assert_contains "${TASK_CONTRACT}" "\`provider\`"
assert_contains "${TASK_CONTRACT}" "\`role\`"
assert_contains "${TASK_CONTRACT}" "\`current_iteration\`"
assert_contains "${TASK_CONTRACT}" "\`auto_fix\`"
assert_contains "${TASK_CONTRACT}" "\`max_iterations\`"
assert_contains "${TASK_CONTRACT}" "\`reviews/correctness.json\`"
assert_contains "${TASK_CONTRACT}" "\`reviews/integration.json\`"
assert_contains "${TASK_CONTRACT}" "\`decision.json\`"
assert_contains "${TASK_CONTRACT}" "\`next_task.json\`"
assert_contains "${TASK_CONTRACT}" "\`next_task.consumed.json\`"
assert_contains "${TASK_CONTRACT}" "\`agent-orch loop continue\`"
assert_contains "${TASK_CONTRACT}" "Work only in \`workspace_path\`"
assert_contains "${TASK_CONTRACT}" "Do not merge, cherry-pick"
assert_contains "${TASK_CONTRACT}" "Codex reviews collected artifacts"
assert_not_contains "${TASK_CONTRACT}" "\`loop_iteration\`"
assert_not_contains "${TASK_CONTRACT}" "\`loop_options\`"
assert_not_contains "${TASK_CONTRACT}" "\`manual_gate_reason\`"

assert_contains "${REPORT_SCHEMA}" "\`completed\`"
assert_contains "${REPORT_SCHEMA}" "\`partial\`"
assert_contains "${REPORT_SCHEMA}" "\`failed\`"
assert_contains "${REPORT_SCHEMA}" "Synthetic Failed Reports"
assert_contains "${REPORT_SCHEMA}" "exits nonzero"
assert_contains "${REPORT_SCHEMA}" "times out"
assert_contains "${REPORT_SCHEMA}" "killed by signal"
assert_contains "${REPORT_SCHEMA}" "omits \`report.json\`"
assert_contains "${REPORT_SCHEMA}" "invalid JSON"
assert_contains "${REPORT_SCHEMA}" "wrapper artifact"
assert_contains "${REPORT_SCHEMA}" "\`attempts/1/\`"
assert_contains "${REPORT_SCHEMA}" "\`progress.log\`"
assert_contains "${REPORT_SCHEMA}" "\`provider-result.json\` remains wrapper-owned"
assert_contains "${REPORT_SCHEMA}" "\`report.raw\` when available"

assert_contains "${RESULT_HANDLING}" "Status output can be summarized"
assert_contains "${RESULT_HANDLING}" "Collect output must preserve"
assert_contains "${RESULT_HANDLING}" "Doctor output is diagnostics"
assert_contains "${RESULT_HANDLING}" "Do not invent a substitute worker answer"
assert_contains "${RESULT_HANDLING}" "failed, missing, or malformed"
assert_contains "${RESULT_HANDLING}" "manual gate default"
assert_contains "${RESULT_HANDLING}" "\`agent-orch loop review\`"
assert_contains "${RESULT_HANDLING}" "\`agent-orch loop decide\`"
assert_contains "${RESULT_HANDLING}" "\`--auto-fix --max-iterations\`"
assert_contains "${RESULT_HANDLING}" "no automatic merge/integration"
assert_contains "${RESULT_HANDLING}" "\`review_missing\`"
assert_contains "${RESULT_HANDLING}" "does not write \`decision.json\`"
assert_contains "${RESULT_HANDLING}" "leaves the loop state at \`worker_collected\`"

assert_contains "${ROUTING_GUIDELINES}" "Codex chooses workers explicitly in v1"
assert_contains "${ROUTING_GUIDELINES}" "deterministic fixture providers only"
assert_contains "${ROUTING_GUIDELINES}" "Real \`claude\` and \`opencode\` adapters are follow-up work only"
assert_contains "${ROUTING_GUIDELINES}" "\`inplace\` execution"
assert_contains "${ROUTING_GUIDELINES}" "not part of v1"
assert_contains "${ROUTING_GUIDELINES}" "OpenCode MVP only"
assert_contains "${ROUTING_GUIDELINES}" "Claude Code and Antigravity follow-up only"
assert_contains "${ROUTING_GUIDELINES}" "agent-orch provider check"

assert_contains "${INSTALL_SCRIPT}" "ln -s"
assert_contains "${INSTALL_SCRIPT}" "\${HOME}/.agents/skills"
assert_contains "${INSTALL_SCRIPT}" "coordinating-local-agents"

setup_temp_dir
TEST_HOME="${TEST_TMPDIR}/home"
mkdir -p "${TEST_HOME}"
HOME="${TEST_HOME}" bash "${INSTALL_SCRIPT}" >/dev/null
HOME="${TEST_HOME}" bash "${INSTALL_SCRIPT}" >/dev/null
installed_path="${TEST_HOME}/.agents/skills/coordinating-local-agents"
if [[ ! -L "${installed_path}" ]]; then
  printf 'expected installed skill to be a symlink: %s\n' "${installed_path}" >&2
  exit 1
fi
installed_target="$(readlink "${installed_path}")"
if [[ "${installed_target}" != "${SKILL_DIR}" ]]; then
  printf 'expected symlink target %s, got %s\n' "${SKILL_DIR}" "${installed_target}" >&2
  exit 1
fi

assert_contains "${README}" "bash scripts/install-skill.sh"
assert_contains "${README}" "~/.agents/skills/coordinating-local-agents"
assert_contains "${README}" "restart Codex"
assert_contains "${README}" "agent-orch provider check"
assert_contains "${README}" "agent-orch loop start"
assert_contains "${README}" "agent-orch loop review"
assert_contains "${README}" "agent-orch loop decide"
assert_contains "${README}" "agent-orch loop continue"
assert_contains "${README}" " --reviewer correctness"
assert_contains "${README}" " --reviewer integration"
assert_contains "${README}" "OpenCode MVP only"
assert_contains "${README}" "Claude Code and Antigravity follow-up only"
assert_contains "${README}" "manual gate default"
assert_contains "${README}" "\`--auto-fix --max-iterations\`"
assert_contains "${README}" "no automatic merge/integration"

assert_contains "${RUN_ALL}" "skill-docs.sh"

printf 'skill-docs.sh: ok\n'
