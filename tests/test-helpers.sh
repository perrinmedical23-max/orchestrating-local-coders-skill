setup_temp_dir() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  trap 'rm -rf "${TEST_TMPDIR}"' EXIT
}

assert_file_exists() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    printf 'expected file to exist: %s\n' "${path}" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local expected="$2"
  if ! grep -Fq "${expected}" "${path}"; then
    printf 'expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  fi
}

assert_json_value() {
  local path="$1"
  local key="$2"
  local expected="$3"
  python3 - "$path" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in key.split("."):
    value = value[part]

if str(value) != expected:
    print(f"expected {key} to be {expected}, got {value}", file=sys.stderr)
    sys.exit(1)
PY
}
