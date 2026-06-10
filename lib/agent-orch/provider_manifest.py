#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


REQUIRED_CAPABILITIES = ("worktree", "writes_report", "streams_stdout", "supports_timeout")


class ManifestError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def fail(code, message):
    raise ManifestError(code, message)


def load_manifest(path):
    if not path.exists():
        fail("provider_manifest_missing", f"provider manifest does not exist: {path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        fail("provider_manifest_invalid", f"provider manifest is invalid JSON: {path}: {exc}")
    if not isinstance(payload, dict):
        fail("provider_manifest_invalid", f"provider manifest must be a JSON object: {path}")
    return payload


def normalize_manifest(provider, provider_dir, manifest_path):
    provider = str(provider or "").strip()
    if not provider or "/" in provider:
        fail("invalid_worker", "worker must name a fixture provider")

    provider_dir = Path(provider_dir).expanduser().resolve(strict=False)
    manifest_path = Path(manifest_path).expanduser().resolve(strict=False)
    payload = load_manifest(manifest_path)

    if payload.get("schema_version") != 1:
        fail("provider_manifest_invalid", "provider manifest schema_version must be 1")
    if payload.get("provider_id") != provider:
        fail("provider_manifest_invalid", "provider manifest provider_id must match worker")
    if payload.get("provider_kind") != "fixture":
        fail("unsupported_provider_kind", "v1.1 supports only fixture provider manifests")

    command = payload.get("command")
    if not isinstance(command, str) or not command.strip() or "/" in command:
        fail("provider_manifest_invalid", "provider manifest command must be an executable filename")
    command = command.strip()

    capabilities = payload.get("capabilities")
    if not isinstance(capabilities, dict):
        fail("provider_manifest_invalid", "provider manifest capabilities must be an object")
    for key in REQUIRED_CAPABILITIES:
        if key not in capabilities:
            fail("provider_manifest_invalid", f"provider manifest missing capability: {key}")
    normalized_capabilities = {}
    for key, value in capabilities.items():
        if not isinstance(value, bool):
            fail("provider_manifest_invalid", f"provider manifest capability must be boolean: {key}")
        normalized_capabilities[key] = value

    provider_command = provider_dir / command
    if not provider_command.is_file() or not provider_command.stat().st_mode & 0o111:
        fail("missing_provider", f"fixture provider is not executable: {provider_command}")

    return {
        "provider_id": provider,
        "provider_kind": "fixture",
        "provider_command": str(provider_command),
        "manifest_path": str(manifest_path),
        "capabilities": normalized_capabilities,
    }


def command_resolve(args):
    provider_dir = Path(args.provider_dir).expanduser().resolve(strict=False)
    manifest_path = provider_dir / "manifests" / f"{args.provider}.json"
    return normalize_manifest(args.provider, provider_dir, manifest_path)


def command_validate(args):
    provider_dir = Path(args.provider_dir).expanduser().resolve(strict=False)
    manifest_path = Path(args.manifest).expanduser().resolve(strict=False)
    return normalize_manifest(args.provider, provider_dir, manifest_path)


def main(argv):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--provider", required=True)
    resolve.add_argument("--provider-dir", required=True)
    resolve.set_defaults(func=command_resolve)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    validate.add_argument("--provider", required=True)
    validate.add_argument("--provider-dir", required=True)
    validate.set_defaults(func=command_validate)

    args = parser.parse_args(argv)
    try:
        payload = args.func(args)
    except ManifestError as exc:
        print(f"{exc.code}\t{exc.message}", file=sys.stderr)
        return 1

    print(json.dumps(payload, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
