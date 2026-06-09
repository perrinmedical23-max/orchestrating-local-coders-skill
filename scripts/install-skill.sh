#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_NAME="coordinating-local-agents"
SOURCE_DIR="${ROOT_DIR}/skills/${SKILL_NAME}"
TARGET_ROOT="${HOME}/.agents/skills"
TARGET_PATH="${TARGET_ROOT}/${SKILL_NAME}"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  printf 'missing skill directory: %s\n' "${SOURCE_DIR}" >&2
  exit 1
fi

mkdir -p "${TARGET_ROOT}"

if [[ -L "${TARGET_PATH}" ]]; then
  current_target="$(readlink "${TARGET_PATH}")"
  if [[ "${current_target}" == "${SOURCE_DIR}" ]]; then
    printf 'skill already linked: %s -> %s\n' "${TARGET_PATH}" "${SOURCE_DIR}"
    exit 0
  fi
  rm "${TARGET_PATH}"
elif [[ -e "${TARGET_PATH}" ]]; then
  printf 'target exists and is not a symlink: %s\n' "${TARGET_PATH}" >&2
  exit 1
fi

ln -s "${SOURCE_DIR}" "${TARGET_PATH}"
printf 'linked skill: %s -> %s\n' "${TARGET_PATH}" "${SOURCE_DIR}"
