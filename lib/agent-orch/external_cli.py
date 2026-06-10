#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import loop_store
import provider_config
import report


ROOT_DIR = Path(__file__).resolve().parents[2]
VALID_ROLES = {"explore", "implement"}


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


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def update_loop_state(loop_path, state, extra=None):
    try:
        with loop_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return
    payload["state"] = state
    payload["updated_at"] = utc_now()
    if extra:
        payload.update(extra)
    write_json(loop_path, payload)


def create_worktree(repo_path, loop_id, iteration_dir):
    base_rev = subprocess.check_output(["git", "-C", str(repo_path), "rev-parse", "HEAD"], text=True).strip()
    worktree_parent = repo_path.parent / f"{repo_path.name}.worktrees"
    worktree_path = worktree_parent / f"agent-orch-loop-{loop_id}-1"
    branch_name = f"agent-orch/loop-{loop_id}-1"

    worktree_parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "-C", str(repo_path), "worktree", "add", "-q", "-b", branch_name, str(worktree_path), base_rev],
        check=True,
    )
    metadata = {
        "repo_path": str(repo_path),
        "worktree_path": str(worktree_path),
        "branch_name": branch_name,
        "base_rev": base_rev,
    }
    write_json(iteration_dir / "metadata.json", metadata)
    return worktree_path, base_rev


def write_prompt(path, role, task_statement, acceptance_criteria, workspace_path, report_path):
    path.write_text(
        "\n".join(
            [
                f"Role: {role}",
                "",
                "Task Statement:",
                task_statement,
                "",
                "Acceptance Criteria:",
                acceptance_criteria,
                "",
                f"Workspace Path: {workspace_path}",
                f"Report Path: {report_path}",
                "",
                "Constraints:",
                "- Do not merge, cherry-pick, or push.",
                "- Do not edit the main checkout.",
                "- Work only in the assigned workspace path.",
                "- Write the final worker report to the report path above.",
                "",
            ]
        ),
        encoding="utf-8",
    )


def write_task_json(path, args, loop_id, repo_path, worktree_path, report_path, task_file, acceptance_file, task_statement, acceptance_criteria):
    write_json(
        path,
        {
            "schema_version": 1,
            "loop_id": loop_id,
            "iteration": 1,
            "provider": args.provider,
            "role": args.role,
            "repo_path": str(repo_path),
            "workspace_path": str(worktree_path),
            "report_path": str(report_path),
            "task_statement": task_statement,
            "acceptance_criteria": acceptance_criteria,
            "task_source": {
                "task_file": str(task_file),
                "acceptance_file": str(acceptance_file),
            },
            "constraints": {
                "allow_merge": False,
                "allow_cherry_pick": False,
                "allow_push": False,
                "main_checkout_edits": False,
            },
            "report_requirements": {
                "path": str(report_path),
                "format": "json",
            },
        },
    )


def provider_result_needs_synthetic_report(provider_result_path, report_path):
    try:
        provider_result = json.loads(provider_result_path.read_text(encoding="utf-8"))
        worker_report = json.loads(report_path.read_text(encoding="utf-8"))
    except Exception:
        return True
    if provider_result.get("timed_out") or provider_result.get("signal") is not None:
        return True
    return provider_result.get("exit_code") not in (None, 0) and worker_report.get("status") == "completed"


def repair_report_if_needed(iteration_dir):
    report_path = iteration_dir / "report.json"
    provider_result_path = iteration_dir / "provider-result.json"
    stdout_path = iteration_dir / "stdout.log"
    stderr_path = iteration_dir / "stderr.log"
    raw_report_path = iteration_dir / "report.raw"

    if not provider_result_path.exists():
        write_json(
            provider_result_path,
            {
                "provider": None,
                "exit_code": None,
                "signal": None,
                "timed_out": False,
                "started_at": None,
                "finished_at": utc_now(),
            },
        )
    for log_path in (stdout_path, stderr_path):
        log_path.touch(exist_ok=True)

    if not report_path.exists():
        report.synthesize_failure(report_path, provider_result_path, stdout_path, stderr_path, None)
        return

    try:
        report.validate_report(report_path)
    except Exception:
        report_path.replace(raw_report_path)
        report.synthesize_failure(report_path, provider_result_path, stdout_path, stderr_path, raw_report_path)
        return

    if provider_result_needs_synthetic_report(provider_result_path, report_path):
        report.synthesize_failure(report_path, provider_result_path, stdout_path, stderr_path, None)


def read_report_status(report_path):
    try:
        with report_path.open("r", encoding="utf-8") as handle:
            return json.load(handle).get("status", "failed")
    except Exception:
        return "failed"


def read_changed_files(report_path):
    try:
        with report_path.open("r", encoding="utf-8") as handle:
            value = json.load(handle).get("files_changed", [])
    except Exception:
        return []
    return value if isinstance(value, list) else []


def write_diff_summary(worktree_path, base_rev, iteration_dir):
    diff_result = subprocess.run(
        ["git", "-C", str(worktree_path), "diff", "--stat", base_rev, "--"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    untracked_result = subprocess.run(
        ["git", "-C", str(worktree_path), "ls-files", "--others", "--exclude-standard"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    untracked = "".join(f"?? {line}\n" for line in untracked_result.stdout.splitlines())
    (iteration_dir / "diff_summary").write_text(diff_result.stdout + untracked, encoding="utf-8")


def run_launch(provider, command, worktree_path, iteration_dir):
    return subprocess.run(
        [
            sys.executable,
            str(ROOT_DIR / "lib" / "agent-orch" / "launch.py"),
            "--provider",
            provider,
            "--cwd",
            str(worktree_path),
            "--stdout",
            str(iteration_dir / "stdout.log"),
            "--stderr",
            str(iteration_dir / "stderr.log"),
            "--result",
            str(iteration_dir / "provider-result.json"),
            "--",
            *command,
        ],
        check=False,
    ).returncode


def start_command(args):
    if args.role not in VALID_ROLES:
        fail("invalid_role", "role must be explore or implement")
    if args.auto_fix and args.max_iterations is None:
        fail("missing_arg", "--max-iterations is required when --auto-fix is present")
    if args.max_iterations is not None and args.max_iterations < 1:
        fail("invalid_args", "--max-iterations must be at least 1")

    repo_path = resolve_repo(args.repo)
    task_file, task_statement = read_text_file(args.task_file, "task")
    acceptance_file, acceptance_criteria = read_text_file(args.acceptance_file, "acceptance")

    loop_id = loop_store.new_loop_id()
    loop_dir = repo_path / ".superpowers" / "agent-orch" / "loops" / loop_id
    iteration_dir = loop_dir / "iterations" / "1"
    loop_path = loop_dir / "loop.json"
    now = utc_now()

    write_json(
        loop_path,
        {
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
        },
    )

    try:
        config = provider_config.validate_provider(repo_path, args.provider)
        if args.role not in set(config["supported_roles"]):
            fail("provider_config_invalid", f"provider does not support role: {args.role}")
        readiness = provider_config.run_readiness(config)
    except provider_config.AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir)})
        fail(exc.code, exc.message, details)
    except AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir)})
        fail(exc.code, exc.message, details)

    try:
        update_loop_state(loop_path, "dispatching", {"readiness": readiness})
        worktree_path, base_rev = create_worktree(repo_path, loop_id, iteration_dir)
        report_path = iteration_dir / "report.json"
        prompt_path = iteration_dir / "prompt.md"
        task_json_path = iteration_dir / "task.json"
        write_prompt(prompt_path, args.role, task_statement, acceptance_criteria, worktree_path, report_path)
        write_task_json(
            task_json_path,
            args,
            loop_id,
            repo_path,
            worktree_path,
            report_path,
            task_file,
            acceptance_file,
            task_statement,
            acceptance_criteria,
        )

        command = provider_config.render_command(
            config["command_template"],
            {
                "prompt_file": str(prompt_path),
                "task_dir": str(iteration_dir),
                "task_json": str(task_json_path),
                "workspace_path": str(worktree_path),
                "report_path": str(report_path),
            },
        )
        write_json(
            iteration_dir / "provider-command.json",
            {
                "provider_id": config["provider_id"],
                "provider_kind": config["provider_kind"],
                "command": command,
                "config_path": config["config_path"],
            },
        )

        update_loop_state(loop_path, "worker_running", {"worktree_path": str(worktree_path)})
        run_launch(args.provider, command, worktree_path, iteration_dir)
        repair_report_if_needed(iteration_dir)
        write_diff_summary(worktree_path, base_rev, iteration_dir)

        report_status = read_report_status(report_path)
        changed_files = read_changed_files(report_path)
        update_loop_state(
            loop_path,
            "worker_collected",
            {
                "worktree_path": str(worktree_path),
                "worker_report_status": report_status,
                "report_path": str(report_path),
            },
        )
    except Exception as exc:
        update_loop_state(loop_path, "failed")
        fail(
            "loop_start_failed",
            str(exc),
            {
                "loop_id": loop_id,
                "loop_dir": str(loop_dir),
                "iteration_dir": str(iteration_dir),
            },
        )

    print_json(
        {
            "loop_id": loop_id,
            "state": "worker_collected",
            "status": "worker_collected",
            "current_iteration": 1,
            "loop_dir": str(loop_dir),
            "iteration_dir": str(iteration_dir),
            "worktree_path": str(worktree_path),
            "report_path": str(report_path),
            "report_status": report_status,
            "changed_files": changed_files,
        }
    )
    return 0


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        if message.startswith("the following arguments are required:"):
            fail("missing_arg", message)
        if message.startswith("unrecognized arguments:"):
            fail("unknown_arg", message)
        fail("invalid_args", message)


def build_parser():
    parser = JsonArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--task-file", required=True)
    parser.add_argument("--acceptance-file", required=True)
    parser.add_argument("--auto-fix", action="store_true")
    parser.add_argument("--max-iterations", type=int)
    return parser


def main(argv):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        return start_command(args)
    except AgentOrchError as exc:
        print_error(exc)
        return 1
    except provider_config.AgentOrchError as exc:
        print_error(AgentOrchError(exc.code, exc.message, exc.details))
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
