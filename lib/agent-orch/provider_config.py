#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ALLOWED_PLACEHOLDERS = {
    "prompt_file",
    "task_dir",
    "task_json",
    "workspace_path",
    "report_path",
}

REQUIRED_OPENCODE_ROLES = {"explore", "implement"}


class AgentOrchError(Exception):
    def __init__(self, code, message, details=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


def fail(code, message, details=None):
    raise AgentOrchError(code, message, details)


def print_error(exc):
    payload = {
        "status": "failed",
        "error": exc.code,
        "message": exc.message,
    }
    if exc.details:
        payload.update(exc.details)
    print(json.dumps(payload, separators=(",", ":")), file=sys.stderr)


def print_json(payload):
    print(json.dumps(payload, separators=(",", ":")))


def load_config(repo):
    repo_path = Path(repo).expanduser().resolve(strict=False)
    config_path = repo_path / ".agent-orch" / "providers.json"
    if not config_path.is_file():
        fail("provider_config_missing", f"provider config does not exist: {config_path}")
    try:
        with config_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        fail("provider_config_invalid", f"provider config is invalid JSON: {config_path}: {exc}")
    if not isinstance(payload, dict):
        fail("provider_config_invalid", "provider config must be a JSON object")
    return repo_path, config_path, payload


def validate_template(command_template):
    if not isinstance(command_template, list) or not command_template:
        fail("provider_config_invalid", "command_template must be a non-empty array")
    for item in command_template:
        if not isinstance(item, str):
            fail("provider_config_invalid", "command_template must contain only strings")
        start = 0
        while True:
            open_at = item.find("{", start)
            if open_at == -1:
                break
            close_at = item.find("}", open_at + 1)
            if close_at == -1:
                fail("provider_config_invalid", f"invalid placeholder syntax in command_template: {item}")
            placeholder = item[open_at + 1:close_at]
            if placeholder not in ALLOWED_PLACEHOLDERS:
                fail("provider_config_invalid", f"unsupported command_template placeholder: {{{placeholder}}}")
            start = close_at + 1
        if "}" in item[start:]:
            fail("provider_config_invalid", f"invalid placeholder syntax in command_template: {item}")


def validate_provider(repo, provider):
    repo_path, config_path, payload = load_config(repo)
    schema_version = payload.get("schema_version")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != 1:
        fail("provider_config_invalid", "provider config schema_version must be 1")
    providers = payload.get("providers")
    if not isinstance(providers, dict):
        fail("provider_config_invalid", "provider config providers must be an object")
    if provider not in providers:
        fail("unknown_provider", f"unknown provider: {provider}")

    provider_config = providers[provider]
    if not isinstance(provider_config, dict):
        fail("provider_config_invalid", "provider config entry must be an object")
    if provider_config.get("provider_id") != provider:
        fail("provider_config_invalid", "provider_id must match requested provider")
    if provider_config.get("provider_kind") != "external_cli":
        fail("provider_config_invalid", "provider_kind must be external_cli")

    supported_roles = provider_config.get("supported_roles")
    if not isinstance(supported_roles, list) or not all(isinstance(role, str) for role in supported_roles):
        fail("provider_config_invalid", "supported_roles must be an array of strings")
    if provider == "opencode" and not REQUIRED_OPENCODE_ROLES.issubset(set(supported_roles)):
        fail("provider_config_invalid", "OpenCode MVP must support explore and implement")

    command_template = provider_config.get("command_template")
    validate_template(command_template)

    capabilities = provider_config.get("capabilities")
    if not isinstance(capabilities, dict):
        fail("provider_config_invalid", "capabilities must be an object")
    for key, value in capabilities.items():
        if not isinstance(value, bool):
            fail("provider_config_invalid", f"capability must be boolean: {key}")

    return {
        "provider_id": provider,
        "provider_kind": provider_config["provider_kind"],
        "supported_roles": supported_roles,
        "command_template": command_template,
        "capabilities": capabilities,
        "config_path": str(config_path),
        "repo_path": str(repo_path),
    }


def render_command(command_template, values):
    return [part.format(**values) for part in command_template]


def validate_report(path):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            report = json.load(handle)
    except Exception:
        return False
    if not isinstance(report, dict):
        return False
    if report.get("status") not in {"completed", "partial", "failed"}:
        return False
    if not isinstance(report.get("summary"), str):
        return False
    for key in ("files_changed", "tests_run", "open_questions", "risks", "notes"):
        if not isinstance(report.get(key), list):
            return False
    return True


def synthesize_failed_report(path):
    payload = {
        "status": "failed",
        "summary": "worker did not produce a valid report",
        "files_changed": [],
        "tests_run": [],
        "open_questions": [],
        "risks": ["worker_exit_failure"],
        "notes": ["readiness smoke synthesized failed report"],
    }
    report_path = Path(path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def resolve_executable(command):
    if not command:
        return None
    first = command[0]
    if os.sep in first:
        candidate = Path(first).expanduser()
        return str(candidate.resolve(strict=False)) if candidate.is_file() and os.access(candidate, os.X_OK) else None
    return shutil.which(first)


def create_worktree(repo_path, destination):
    subprocess.run(
        ["git", "-C", str(repo_path), "worktree", "add", "--detach", str(destination), "HEAD"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def remove_worktree(repo_path, destination):
    subprocess.run(
        ["git", "-C", str(repo_path), "worktree", "remove", "--force", str(destination)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def reports_interactive_only(returncode, output):
    if returncode == 0:
        return False
    lowered = output.lower()
    return any(
        signal in lowered
        for signal in (
            "requires an interactive tty",
            "requires a tty",
            "tty required",
            "not a tty",
            "no tty",
        )
    )


def run_readiness(config):
    readiness = {
        "executable": {"resolved": False, "path": None},
        "template": {"valid": True, "command": None},
        "temp_worktree": {"created": False, "path": None},
        "non_interactive": {"ok": False, "interactive_only": False},
        "exit_behavior": {"supported": False, "exit_code": None},
        "report_finalization": {"ok": False, "mode": None},
    }

    repo_path = Path(config["repo_path"])
    with tempfile.TemporaryDirectory(prefix="agent-orch-provider-") as temp_root:
        temp_root_path = Path(temp_root)
        worktree_path = temp_root_path / "worktree"
        task_dir = temp_root_path / "task"
        task_dir.mkdir()
        prompt_file = task_dir / "prompt.md"
        task_json = task_dir / "task.json"
        report_path = task_dir / "report.json"
        prompt_file.write_text("Readiness smoke run. Produce report.json.\n", encoding="utf-8")
        task_json.write_text(json.dumps({"task": "provider readiness smoke"}) + "\n", encoding="utf-8")

        command = render_command(
            config["command_template"],
            {
                "prompt_file": str(prompt_file),
                "task_dir": str(task_dir),
                "task_json": str(task_json),
                "workspace_path": str(worktree_path),
                "report_path": str(report_path),
            },
        )
        readiness["template"]["command"] = command

        executable = resolve_executable(command)
        readiness["executable"]["path"] = executable
        readiness["executable"]["resolved"] = bool(executable)
        if not executable:
            fail("provider_not_ready", "provider executable is missing or not executable", {"readiness": readiness})

        try:
            create_worktree(repo_path, worktree_path)
        except subprocess.CalledProcessError:
            fail("provider_not_ready", "could not create temporary readiness worktree", {"readiness": readiness})
        readiness["temp_worktree"]["created"] = True
        readiness["temp_worktree"]["path"] = str(worktree_path)

        try:
            completed = subprocess.run(
                command,
                cwd=str(worktree_path),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=15,
                check=False,
            )
        except subprocess.TimeoutExpired:
            remove_worktree(repo_path, worktree_path)
            fail("provider_not_ready", "provider readiness smoke timed out", {"readiness": readiness})
        finally:
            remove_worktree(repo_path, worktree_path)

        output = f"{completed.stdout}\n{completed.stderr}"
        interactive_only = reports_interactive_only(completed.returncode, output)
        readiness["non_interactive"]["interactive_only"] = interactive_only
        readiness["non_interactive"]["ok"] = not interactive_only
        readiness["exit_behavior"]["exit_code"] = completed.returncode
        readiness["exit_behavior"]["supported"] = completed.returncode == 0

        if interactive_only:
            fail("provider_not_ready", "provider requires interactive behavior during readiness smoke", {"readiness": readiness})
        if completed.returncode != 0:
            fail("provider_not_ready", "provider readiness smoke exited with unsupported status", {"readiness": readiness})

        if validate_report(report_path):
            readiness["report_finalization"]["ok"] = True
            readiness["report_finalization"]["mode"] = "provider_report"
        else:
            synthesize_failed_report(report_path)
            readiness["report_finalization"]["ok"] = validate_report(report_path)
            readiness["report_finalization"]["mode"] = "synthetic_failure_report"
        if not readiness["report_finalization"]["ok"]:
            fail("provider_not_ready", "provider readiness report finalization failed", {"readiness": readiness})

    return readiness


def check_command(args):
    config = validate_provider(args.repo, args.provider)
    readiness = run_readiness(config)
    payload = {
        "provider_id": config["provider_id"],
        "provider_kind": config["provider_kind"],
        "supported_roles": config["supported_roles"],
        "ready": True,
        "config_path": config["config_path"],
        "command_template": config["command_template"],
        "capabilities": config["capabilities"],
        "readiness": readiness,
    }
    print_json(payload)
    return 0


def render_command_output(args):
    config = validate_provider(args.repo, args.provider)
    command = render_command(
        config["command_template"],
        {
            "prompt_file": args.prompt_file,
            "task_dir": args.task_dir,
            "task_json": args.task_json,
            "workspace_path": args.workspace_path,
            "report_path": args.report_path,
        },
    )
    print_json({
        "provider_id": config["provider_id"],
        "provider_kind": config["provider_kind"],
        "config_path": config["config_path"],
        "command": command,
    })
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check")
    check.add_argument("--provider", required=True)
    check.add_argument("--repo", required=True)
    check.set_defaults(func=check_command)

    render = subparsers.add_parser("render")
    render.add_argument("--provider", required=True)
    render.add_argument("--repo", required=True)
    render.add_argument("--prompt-file", required=True)
    render.add_argument("--task-dir", required=True)
    render.add_argument("--task-json", required=True)
    render.add_argument("--workspace-path", required=True)
    render.add_argument("--report-path", required=True)
    render.set_defaults(func=render_command_output)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except AgentOrchError as exc:
        print_error(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
