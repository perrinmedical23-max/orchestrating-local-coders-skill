#!/usr/bin/env bash
set -euo pipefail

task_dir="$1"
task_json="$2"

if [[ ! -d "${task_dir}" ]]; then
  printf 'missing task directory: %s\n' "${task_dir}" >&2
  exit 2
fi

if [[ ! -f "${task_json}" ]]; then
  printf 'missing task json: %s\n' "${task_json}" >&2
  exit 2
fi

cat > "${task_dir}/report.json" <<'JSON'
{"status":"completed","summary":"fixture success","files_changed":[],"tests_run":[],"open_questions":[],"risks":[],"notes":[]}
JSON
