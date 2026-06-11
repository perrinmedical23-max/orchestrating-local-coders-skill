#!/usr/bin/env bash
set -euo pipefail

prompt_file=""
task_json=""
workspace_path=""
report_path=""
task_dir=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --prompt-file)
      [[ "$#" -ge 2 ]] || exit 2
      prompt_file="$2"
      shift 2
      ;;
    --task-json)
      [[ "$#" -ge 2 ]] || exit 2
      task_json="$2"
      shift 2
      ;;
    --workspace-path)
      [[ "$#" -ge 2 ]] || exit 2
      workspace_path="$2"
      shift 2
      ;;
    --report|--report-path)
      [[ "$#" -ge 2 ]] || exit 2
      report_path="$2"
      shift 2
      ;;
    --task-dir)
      [[ "$#" -ge 2 ]] || exit 2
      task_dir="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${prompt_file}" || -z "${task_json}" || -z "${workspace_path}" || -z "${report_path}" || -z "${task_dir}" ]]; then
  printf 'missing required agy-run argument\n' >&2
  exit 2
fi

antigravity_bin="${AGENT_ORCH_ANTIGRAVITY_BIN:-agy}"
antigravity_model="${AGENT_ORCH_ANTIGRAVITY_MODEL:-Gemini 3.5 Flash (High)}"
mkdir -p "${task_dir}" "$(dirname "${report_path}")"

stdout_path="${task_dir}/agy.stdout"
stderr_path="${task_dir}/agy.stderr"
prompt_text="$(cat "${prompt_file}")"

readiness="false"
if python3 - "${task_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
raise SystemExit(0 if payload.get("task") == "provider readiness smoke" else 1)
PY
then
  readiness="true"
  prompt_text="Respond with exactly: AGY_OK"
fi

set +e
"${antigravity_bin}" --print --model "${antigravity_model}" "${prompt_text}" > "${stdout_path}" 2> "${stderr_path}"
agy_status="$?"
set -e

python3 - "${report_path}" "${prompt_file}" "${stdout_path}" "${stderr_path}" "${workspace_path}" "${agy_status}" "${readiness}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

report_path, prompt_file, stdout_path, stderr_path, workspace_path, status_text, readiness_text = sys.argv[1:]
exit_code = int(status_text)
readiness = readiness_text == "true"

prompt = Path(prompt_file).read_text(encoding="utf-8", errors="replace").strip()
stdout = Path(stdout_path).read_text(encoding="utf-8", errors="replace").strip()
stderr = Path(stderr_path).read_text(encoding="utf-8", errors="replace").strip()

try:
    git_status = subprocess.run(
        ["git", "-C", workspace_path, "status", "--porcelain=v1", "--untracked-files=all"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    changed_files = [
        line[3:]
        for line in git_status.stdout.splitlines()
        if len(line) > 3 and line[3:]
    ]
except Exception:
    changed_files = []

ready_ok = readiness and exit_code == 0 and stdout.strip() == "AGY_OK"
if readiness and not ready_ok:
    status = "failed"
    error_code = "antigravity_not_ready"
    summary = "Antigravity readiness failed"
elif exit_code == 0:
    status = "completed"
    error_code = None
    summary_source = prompt.replace("\n", " ")
    if len(summary_source) > 180:
        summary_source = summary_source[:177] + "..."
    summary = f"Antigravity completed task: {summary_source}"
else:
    status = "failed"
    error_code = "antigravity_failed"
    summary = "Antigravity failed task"

payload = {
    "status": status,
    "summary": summary,
    "files_changed": changed_files,
    "tests_run": [],
    "open_questions": [],
    "risks": [] if status == "completed" else ["antigravity exited nonzero or failed readiness"],
    "notes": [
        f"agy_exit_code={exit_code}",
        f"stdout={stdout_path}",
        f"stderr={stderr_path}",
    ],
}
if stdout:
    payload["notes"].append("stdout preview: " + stdout[:500].replace("\n", " "))
if stderr:
    payload["notes"].append("stderr preview: " + stderr[:500].replace("\n", " "))
if error_code:
    payload["error_code"] = error_code

Path(report_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if [[ "${readiness}" == "true" ]]; then
  normalized="$(tr -d '\r' < "${stdout_path}" | sed -e 's/[[:space:]]*$//')"
  if [[ "${agy_status}" -ne 0 || "${normalized}" != "AGY_OK" ]]; then
    exit 1
  fi
fi

exit "${agy_status}"
