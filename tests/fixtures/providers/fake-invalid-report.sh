#!/usr/bin/env bash
set -euo pipefail

task_dir="$1"
printf '{not valid json}\n' > "${task_dir}/report.json"
exit 0
