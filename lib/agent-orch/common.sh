die() {
  local code="$1"
  local message="$2"
  printf '{"status":"failed","error":"%s","message":"%s"}\n' "$code" "$message" >&2
  exit 1
}
