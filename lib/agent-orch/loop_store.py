#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


VALID_ROLES = {"explore", "implement"}
VALID_STATES = {
    "created",
    "dispatching",
    "worker_running",
    "worker_collected",
    "reviewing",
    "manual_gate",
    "auto_fix_dispatching",
    "completed",
    "failed",
    "stopped",
    "failed_max_iterations",
}


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


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        if message.startswith("the following arguments are required:"):
            fail("missing_arg", message)
        if message.startswith("unrecognized arguments:"):
            fail("unknown_arg", message)
        fail("invalid_args", message)


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_text_file(path, name):
    file_path = Path(path).expanduser().resolve(strict=False)
    if not file_path.is_file():
        fail("missing_file", f"{name} file does not exist: {file_path}")
    return file_path, file_path.read_text(encoding="utf-8")


def resolve_repo(repo):
    repo_path = Path(repo).expanduser().resolve(strict=False)
    if not repo_path.is_dir():
        fail("missing_repo", f"repo does not exist: {repo_path}")
    result = subprocess.run(
        ["git", "-C", str(repo_path), "rev-parse", "--show-toplevel"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail("invalid_repo", f"repo is not a git repository: {repo_path}")
    return Path(result.stdout.strip())


def new_loop_id():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return f"{stamp}-{uuid.uuid4().hex[:6]}"


def load_loop(loop_dir):
    loop_path = Path(loop_dir).expanduser().resolve(strict=False) / "loop.json"
    if not loop_path.is_file():
        fail("loop_not_found", f"loop not found: {loop_path.parent}")
    try:
        with loop_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        fail("loop_state_invalid", f"loop state is invalid JSON: {loop_path}: {exc}")
    if not isinstance(payload, dict):
        fail("loop_state_invalid", "loop state must be a JSON object")
    return loop_path, payload


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def create_command(args):
    if args.role not in VALID_ROLES:
        fail("invalid_role", "role must be explore or implement")
    if args.auto_fix and args.max_iterations is None:
        fail("missing_arg", "--max-iterations is required when --auto-fix is present")
    if args.max_iterations is not None and args.max_iterations < 1:
        fail("invalid_args", "--max-iterations must be at least 1")

    repo_path = resolve_repo(args.repo)
    task_file, task_statement = read_text_file(args.task_file, "task")
    acceptance_file, acceptance_criteria = read_text_file(args.acceptance_file, "acceptance")

    loop_id = new_loop_id()
    loop_dir = repo_path / ".superpowers" / "agent-orch" / "loops" / loop_id
    iteration_dir = loop_dir / "iterations" / "1"
    now = utc_now()

    loop_payload = {
        "schema_version": 1,
        "loop_id": loop_id,
        "provider": args.provider,
        "role": args.role,
        "state": "created",
        "current_iteration": 1,
        "auto_fix": args.auto_fix,
        "max_iterations": args.max_iterations,
        "created_at": now,
        "updated_at": now,
        "repo_path": str(repo_path),
    }
    task_payload = {
        "schema_version": 1,
        "loop_id": loop_id,
        "iteration": 1,
        "provider": args.provider,
        "role": args.role,
        "repo_path": str(repo_path),
        "task_statement": task_statement,
        "acceptance_criteria": acceptance_criteria,
        "task_source": {
            "task_file": str(task_file),
            "acceptance_file": str(acceptance_file),
        },
    }

    write_json(loop_dir / "loop.json", loop_payload)
    write_json(iteration_dir / "task.json", task_payload)

    print_json({
        "loop_id": loop_id,
        "state": loop_payload["state"],
        "status": loop_payload["state"],
        "current_iteration": loop_payload["current_iteration"],
        "loop_dir": str(loop_dir),
    })
    return 0


def status_command(args):
    loop_path, loop_payload = load_loop(args.loop_dir)
    print_json({
        "loop_id": loop_payload["loop_id"],
        "state": loop_payload["state"],
        "status": loop_payload["state"],
        "current_iteration": loop_payload["current_iteration"],
        "loop_dir": str(loop_path.parent),
        "repo_path": loop_payload["repo_path"],
        "provider": loop_payload["provider"],
        "role": loop_payload["role"],
        "auto_fix": loop_payload["auto_fix"],
        "max_iterations": loop_payload["max_iterations"],
    })
    return 0


def collect_command(args):
    loop_path, loop_payload = load_loop(args.loop_dir)
    iteration = loop_payload["current_iteration"]
    iteration_dir = loop_path.parent / "iterations" / str(iteration)
    report_path = iteration_dir / "report.json"
    report_status = None
    changed_files = []
    tests_run = []
    if report_path.is_file():
        try:
            with report_path.open("r", encoding="utf-8") as handle:
                report = json.load(handle)
            report_status = report.get("status")
            changed_files = report.get("files_changed", [])
            tests_run = report.get("tests_run", [])
            if not isinstance(changed_files, list):
                changed_files = []
            if not isinstance(tests_run, list):
                tests_run = []
        except Exception:
            report_status = "failed"
    diff_summary_path = iteration_dir / "diff_summary"
    diff_summary = ""
    if diff_summary_path.is_file():
        diff_summary = diff_summary_path.read_text(encoding="utf-8")
    payload = {
        "loop_id": loop_payload["loop_id"],
        "state": loop_payload["state"],
        "status": loop_payload["state"],
        "current_iteration": iteration,
        "loop_dir": str(loop_path.parent),
        "repo_path": loop_payload["repo_path"],
        "iteration_dir": str(iteration_dir),
        "task_path": str(iteration_dir / "task.json"),
        "report_path": str(report_path),
        "report_status": report_status,
        "changed_files": changed_files,
        "tests_run": tests_run,
        "diff_summary": diff_summary,
    }
    print_json(payload)
    return 0


def set_state_command(args):
    if args.state not in VALID_STATES:
        fail("invalid_state", f"unsupported loop state: {args.state}")
    loop_path, loop_payload = load_loop(args.loop_dir)
    loop_payload["state"] = args.state
    loop_payload["updated_at"] = utc_now()
    write_json(loop_path, loop_payload)
    print_json({
        "loop_id": loop_payload["loop_id"],
        "state": loop_payload["state"],
        "status": loop_payload["state"],
        "current_iteration": loop_payload["current_iteration"],
        "loop_dir": str(loop_path.parent),
    })
    return 0


def build_parser():
    parser = JsonArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    create = subparsers.add_parser("create")
    create.add_argument("--repo", required=True)
    create.add_argument("--provider", required=True)
    create.add_argument("--role", required=True)
    create.add_argument("--task-file", required=True)
    create.add_argument("--acceptance-file", required=True)
    create.add_argument("--auto-fix", action="store_true")
    create.add_argument("--max-iterations", type=int)
    create.set_defaults(func=create_command)

    status = subparsers.add_parser("status")
    status.add_argument("--loop-dir", required=True)
    status.set_defaults(func=status_command)

    collect = subparsers.add_parser("collect")
    collect.add_argument("--loop-dir", required=True)
    collect.set_defaults(func=collect_command)

    set_state = subparsers.add_parser("set-state")
    set_state.add_argument("--loop-dir", required=True)
    set_state.add_argument("--state", required=True)
    set_state.set_defaults(func=set_state_command)

    return parser


def main(argv):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        return args.func(args)
    except AgentOrchError as exc:
        print_error(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
