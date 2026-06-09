die() {
  local code="$1"
  local message="$2"
  python3 - "$code" "$message" <<'PY' >&2
import json
import sys

print(json.dumps({
    "status": "failed",
    "error": sys.argv[1],
    "message": sys.argv[2],
}, separators=(",", ":")))
PY
  exit 1
}
