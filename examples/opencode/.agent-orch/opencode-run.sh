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
  printf 'missing required opencode-run argument\n' >&2
  exit 2
fi

opencode_bin="${AGENT_ORCH_OPENCODE_BIN:-opencode}"
mkdir -p "${task_dir}" "$(dirname "${report_path}")"

stdout_path="${task_dir}/opencode.stdout"
stderr_path="${task_dir}/opencode.stderr"
prompt_text="$(cat "${prompt_file}")"

set +e
"${opencode_bin}" run --format json --dir "${workspace_path}" "${prompt_text}" > "${stdout_path}" 2> "${stderr_path}"
opencode_status="$?"
set -e

python3 - "${report_path}" "${prompt_file}" "${stdout_path}" "${stderr_path}" "${workspace_path}" "${opencode_status}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

report_path, prompt_file, stdout_path, stderr_path, workspace_path, status_text = sys.argv[1:]
exit_code = int(status_text)

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

summary_prefix = "OpenCode completed task" if exit_code == 0 else "OpenCode failed task"
summary_source = prompt.replace("\n", " ")
if len(summary_source) > 180:
    summary_source = summary_source[:177] + "..."

payload = {
    "status": "completed" if exit_code == 0 else "failed",
    "summary": f"{summary_prefix}: {summary_source}",
    "files_changed": changed_files,
    "tests_run": [],
    "open_questions": [],
    "risks": [] if exit_code == 0 else ["opencode exited nonzero"],
    "notes": [
        f"opencode_exit_code={exit_code}",
        f"stdout={stdout_path}",
        f"stderr={stderr_path}",
    ],
}
if stdout:
    payload["notes"].append("stdout preview: " + stdout[:500].replace("\n", " "))
if stderr:
    payload["notes"].append("stderr preview: " + stderr[:500].replace("\n", " "))
if exit_code != 0:
    payload["error_code"] = "opencode_failed"

Path(report_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

exit "${opencode_status}"
