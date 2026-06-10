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
        "error_code": exc.code,
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


def create_worktree(repo_path, loop_id, iteration, iteration_dir):
    base_rev = subprocess.check_output(["git", "-C", str(repo_path), "rev-parse", "HEAD"], text=True).strip()
    worktree_parent = repo_path.parent / f"{repo_path.name}.worktrees"
    worktree_path = worktree_parent / f"agent-orch-loop-{loop_id}-{iteration}"
    branch_name = f"agent-orch/loop-{loop_id}-{iteration}"

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


def write_task_json(
    path,
    loop_id,
    iteration,
    provider,
    role,
    repo_path,
    worktree_path,
    report_path,
    task_file,
    acceptance_file,
    task_statement,
    acceptance_criteria,
    extra=None,
):
    payload = {
        "schema_version": 1,
        "loop_id": loop_id,
        "iteration": iteration,
        "provider": provider,
        "role": role,
        "repo_path": str(repo_path),
        "workspace_path": str(worktree_path),
        "report_path": str(report_path),
        "task_statement": task_statement,
        "acceptance_criteria": acceptance_criteria,
        "task_source": {
            "task_file": str(task_file) if task_file else None,
            "acceptance_file": str(acceptance_file) if acceptance_file else None,
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
    }
    if extra:
        payload.update(extra)
    write_json(
        path,
        payload,
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


def read_report_error_code(report_path):
    try:
        with report_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return None
    value = payload.get("error_code")
    return value if isinstance(value, str) and value else None


def provider_exited_nonzero(provider_result_path):
    try:
        with provider_result_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return False
    return payload.get("exit_code") not in (None, 0)


def worker_error_code(report_path, provider_result_path):
    error_code = read_report_error_code(report_path)
    if error_code:
        return error_code

    report_status = read_report_status(report_path)
    if not provider_exited_nonzero(provider_result_path):
        return None
    if report_status == "partial":
        return "worker_partial"
    if report_status == "failed":
        return "worker_declared_failure"
    return None


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


def git_status_snapshot(repo_path, ignored_prefixes=None):
    ignored = tuple(prefix.rstrip("/") + "/" for prefix in (ignored_prefixes or []))
    result = subprocess.run(
        ["git", "-C", str(repo_path), "status", "--porcelain=v1", "--untracked-files=all"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    entries = []
    for line in result.stdout.splitlines():
        path = line[3:] if len(line) > 3 else ""
        if any(path == prefix[:-1] or path.startswith(prefix) for prefix in ignored):
            continue
        entries.append(line)
    return entries


def audit_workspace(repo_path, worktree_path, base_rev, loop_id, iteration_dir, coordinator_status_before):
    ignored_prefix = f".superpowers/agent-orch/loops/{loop_id}"
    coordinator_status = git_status_snapshot(repo_path, [ignored_prefix])
    worktree_diff = subprocess.run(
        ["git", "-C", str(worktree_path), "diff", "--name-status", base_rev, "--"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    worktree_untracked = subprocess.run(
        ["git", "-C", str(worktree_path), "ls-files", "--others", "--exclude-standard"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    payload = {
        "status": "passed",
        "error_code": None,
        "coordinator_repo_path": str(repo_path),
        "worktree_path": str(worktree_path),
        "coordinator_status_before": coordinator_status_before,
        "coordinator_status_after": coordinator_status,
        "worktree_diff": worktree_diff.stdout.splitlines(),
        "worktree_untracked": worktree_untracked.stdout.splitlines(),
    }
    if coordinator_status != coordinator_status_before:
        payload["status"] = "failed"
        payload["error_code"] = "workspace_violation"
    write_json(iteration_dir / "workspace-audit.json", payload)
    return payload


def write_workspace_violation_report(iteration_dir, audit_payload):
    report_path = iteration_dir / "report.json"
    provider_result_path = iteration_dir / "provider-result.json"
    stdout_path = iteration_dir / "stdout.log"
    stderr_path = iteration_dir / "stderr.log"
    payload = {
        "status": "failed",
        "error_code": "workspace_violation",
        "summary": "worker modified the coordinator checkout outside the assigned workspace",
        "files_changed": [],
        "tests_run": [],
        "open_questions": [],
        "risks": ["workspace_violation"],
        "notes": ["see workspace-audit.json", "see provider-result.json", "see stdout.log", "see stderr.log"],
        "diagnostics": {
            "report_path": str(report_path),
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "provider_result_path": str(provider_result_path),
            "workspace_audit_path": str(iteration_dir / "workspace-audit.json"),
            "coordinator_status_before": audit_payload.get("coordinator_status_before", []),
            "coordinator_status_after": audit_payload.get("coordinator_status_after", []),
        },
    }
    write_json(report_path, payload)


def iteration_artifact_paths(iteration_dir):
    paths = {
        "iteration_dir": str(iteration_dir),
        "report_path": str(iteration_dir / "report.json"),
        "stdout_path": str(iteration_dir / "stdout.log"),
        "stderr_path": str(iteration_dir / "stderr.log"),
        "provider_result_path": str(iteration_dir / "provider-result.json"),
        "workspace_audit_path": str(iteration_dir / "workspace-audit.json"),
    }
    raw_report_path = iteration_dir / "report.raw"
    if raw_report_path.exists():
        paths["raw_report_path"] = str(raw_report_path)
    return paths


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
    for field in ("loop_id", "repo_path", "provider", "state"):
        if not isinstance(payload.get(field), str) or not payload[field]:
            fail("loop_state_invalid", f"loop state field must be a non-empty string: {field}", {"path": str(loop_path)})
    if payload.get("role") not in VALID_ROLES:
        fail("loop_state_invalid", "loop state role must be explore or implement", {"path": str(loop_path)})
    current_iteration = payload.get("current_iteration")
    if isinstance(current_iteration, bool) or not isinstance(current_iteration, int) or current_iteration < 1:
        fail("loop_state_invalid", "loop current_iteration must be a positive integer", {"path": str(loop_path)})
    if not isinstance(payload.get("auto_fix"), bool):
        fail("loop_state_invalid", "loop auto_fix must be a boolean", {"path": str(loop_path)})
    max_iterations = payload.get("max_iterations")
    if payload["auto_fix"] and (
        isinstance(max_iterations, bool)
        or not isinstance(max_iterations, int)
        or max_iterations < 1
    ):
        fail("loop_state_invalid", "loop max_iterations must be a positive integer when auto_fix is enabled", {"path": str(loop_path)})
    return loop_path, payload


def run_iteration(
    loop_path,
    loop_payload,
    iteration,
    provider,
    role,
    task_statement,
    acceptance_criteria,
    task_file,
    acceptance_file,
    task_extra=None,
    dispatch_state="dispatching",
):
    repo_path = Path(loop_payload["repo_path"])
    loop_dir = loop_path.parent
    loop_id = loop_payload["loop_id"]
    iteration_dir = loop_dir / "iterations" / str(iteration)

    config = provider_config.validate_provider(repo_path, provider)
    if role not in set(config["supported_roles"]):
        fail("provider_config_invalid", f"provider does not support role: {role}")
    readiness = provider_config.run_readiness(config)

    update_loop_state(
        loop_path,
        dispatch_state,
        {
            "current_iteration": iteration,
            "provider": provider,
            "role": role,
            "readiness": readiness,
        },
    )

    worktree_path, base_rev = create_worktree(repo_path, loop_id, iteration, iteration_dir)
    report_path = iteration_dir / "report.json"
    prompt_path = iteration_dir / "prompt.md"
    task_json_path = iteration_dir / "task.json"
    write_prompt(prompt_path, role, task_statement, acceptance_criteria, worktree_path, report_path)
    write_task_json(
        task_json_path,
        loop_id,
        iteration,
        provider,
        role,
        repo_path,
        worktree_path,
        report_path,
        task_file,
        acceptance_file,
        task_statement,
        acceptance_criteria,
        task_extra,
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

    update_loop_state(
        loop_path,
        "worker_running",
        {
            "current_iteration": iteration,
            "worktree_path": str(worktree_path),
        },
    )
    coordinator_status_before = git_status_snapshot(
        repo_path,
        [f".superpowers/agent-orch/loops/{loop_id}"],
    )
    run_launch(provider, command, worktree_path, iteration_dir)
    workspace_audit = audit_workspace(
        repo_path,
        worktree_path,
        base_rev,
        loop_id,
        iteration_dir,
        coordinator_status_before,
    )
    repair_report_if_needed(iteration_dir)
    if workspace_audit.get("error_code") == "workspace_violation":
        write_workspace_violation_report(iteration_dir, workspace_audit)
    write_diff_summary(worktree_path, base_rev, iteration_dir)

    report_status = read_report_status(report_path)
    error_code = worker_error_code(report_path, iteration_dir / "provider-result.json")
    changed_files = read_changed_files(report_path)
    update_loop_state(
        loop_path,
        "worker_collected",
        {
            "current_iteration": iteration,
            "provider": provider,
            "role": role,
            "worktree_path": str(worktree_path),
            "worker_report_status": report_status,
            "error_code": error_code,
            "report_path": str(report_path),
            "workspace_audit_path": str(iteration_dir / "workspace-audit.json"),
        },
    )
    return {
        "iteration_dir": iteration_dir,
        "worktree_path": worktree_path,
        "report_path": report_path,
        "report_status": report_status,
        "error_code": error_code,
        "changed_files": changed_files,
        "artifact_paths": iteration_artifact_paths(iteration_dir),
    }


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
        result = run_iteration(
            loop_path,
            {
                "loop_id": loop_id,
                "repo_path": str(repo_path),
            },
            1,
            args.provider,
            args.role,
            task_statement,
            acceptance_criteria,
            task_file,
            acceptance_file,
            None,
            "dispatching",
        )
    except provider_config.AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        readiness = details.get("readiness")
        if readiness is not None:
            readiness_path = loop_dir / "readiness.json"
            write_json(readiness_path, readiness)
            details["readiness_path"] = str(readiness_path)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir)})
        fail(exc.code, exc.message, details)
    except AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir)})
        fail(exc.code, exc.message, details)
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
            "iteration_dir": str(result["iteration_dir"]),
            "worktree_path": str(result["worktree_path"]),
            "report_path": str(result["report_path"]),
            "report_status": result["report_status"],
            "error_code": result["error_code"] if result["error_code"] else None,
            "changed_files": result["changed_files"],
            **result["artifact_paths"],
        }
    )
    return 0


def continue_command(args):
    loop_path, loop_payload = load_loop(args.loop_dir)
    loop_dir = loop_path.parent
    loop_id = loop_payload["loop_id"]
    current_iteration = loop_payload["current_iteration"]

    if not loop_payload.get("auto_fix"):
        fail(
            "auto_fix_not_enabled",
            "loop continue requires a loop started with --auto-fix",
            {"loop_id": loop_id, "loop_dir": str(loop_dir)},
        )

    max_iterations = loop_payload.get("max_iterations")
    next_iteration = current_iteration + 1
    if not isinstance(max_iterations, int) or next_iteration > max_iterations:
        update_loop_state(loop_path, "failed_max_iterations")
        fail(
            "max_iterations_reached",
            "loop continue would exceed --max-iterations",
            {
                "loop_id": loop_id,
                "loop_dir": str(loop_dir),
                "current_iteration": current_iteration,
                "max_iterations": max_iterations,
            },
        )

    source_iteration_dir = loop_dir / "iterations" / str(current_iteration)
    next_task_path = source_iteration_dir / "next_task.json"
    if not next_task_path.is_file():
        fail(
            "next_task_missing",
            "loop continue requires an existing next_task.json",
            {
                "loop_id": loop_id,
                "loop_dir": str(loop_dir),
                "current_iteration": current_iteration,
                "next_task_path": str(next_task_path),
            },
        )

    decision_path = source_iteration_dir / "decision.json"
    try:
        with decision_path.open("r", encoding="utf-8") as handle:
            decision_payload = json.load(handle)
    except Exception:
        decision_payload = {}
    expected_next_task_path = decision_payload.get("next_task_path") if isinstance(decision_payload, dict) else None
    if (
        loop_payload.get("state") != "worker_collected"
        or not isinstance(decision_payload, dict)
        or decision_payload.get("decision") != "auto_fix_ready"
        or expected_next_task_path != str(next_task_path)
    ):
        fail(
            "next_task_stale",
            "loop continue requires a current auto_fix_ready decision",
            {
                "loop_id": loop_id,
                "loop_dir": str(loop_dir),
                "current_iteration": current_iteration,
                "next_task_path": str(next_task_path),
                "decision_path": str(decision_path),
            },
        )

    try:
        with next_task_path.open("r", encoding="utf-8") as handle:
            next_task = json.load(handle)
    except json.JSONDecodeError as exc:
        fail("next_task_invalid", f"next_task.json is invalid JSON: {exc}", {"next_task_path": str(next_task_path)})
    if not isinstance(next_task, dict):
        fail("next_task_invalid", "next_task.json must be a JSON object", {"next_task_path": str(next_task_path)})

    provider = loop_payload["provider"]
    role = next_task.get("role", loop_payload["role"])
    if role not in VALID_ROLES:
        fail("invalid_role", "next_task role must be explore or implement", {"next_task_path": str(next_task_path)})
    task_statement = next_task.get("task_statement")
    acceptance_criteria = next_task.get("acceptance_criteria") or next_task.get("original_acceptance_criteria")
    if not isinstance(task_statement, str) or not task_statement.strip():
        fail("next_task_invalid", "next_task.json must include task_statement", {"next_task_path": str(next_task_path)})
    if not isinstance(acceptance_criteria, str) or not acceptance_criteria.strip():
        fail("next_task_invalid", "next_task.json must include acceptance_criteria", {"next_task_path": str(next_task_path)})

    consumed_path = source_iteration_dir / "next_task.consumed.json"
    next_task["consumed_at"] = utc_now()
    next_task["consumed_by_iteration"] = next_iteration
    write_json(consumed_path, next_task)
    next_task_path.unlink()

    task_extra = {
        "source_next_task_path": str(consumed_path),
        "source_iteration": current_iteration,
        "auto_fix": True,
        "blocker_summaries": next_task.get("blocker_summaries", []),
        "blocker_signature": next_task.get("blocker_signature"),
        "original_acceptance_criteria": next_task.get("original_acceptance_criteria"),
    }

    try:
        result = run_iteration(
            loop_path,
            loop_payload,
            next_iteration,
            provider,
            role,
            task_statement,
            acceptance_criteria,
            None,
            None,
            task_extra,
            "auto_fix_dispatching",
        )
    except provider_config.AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        readiness = details.get("readiness")
        if readiness is not None:
            readiness_path = loop_dir / f"readiness-{next_iteration}.json"
            write_json(readiness_path, readiness)
            details["readiness_path"] = str(readiness_path)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir), "iteration": next_iteration})
        fail(exc.code, exc.message, details)
    except AgentOrchError as exc:
        update_loop_state(loop_path, "failed")
        details = dict(exc.details)
        details.update({"loop_id": loop_id, "loop_dir": str(loop_dir), "iteration": next_iteration})
        fail(exc.code, exc.message, details)
    except Exception as exc:
        update_loop_state(loop_path, "failed")
        fail(
            "loop_continue_failed",
            str(exc),
            {
                "loop_id": loop_id,
                "loop_dir": str(loop_dir),
                "iteration_dir": str(loop_dir / "iterations" / str(next_iteration)),
            },
        )

    print_json(
        {
            "loop_id": loop_id,
            "state": "worker_collected",
            "status": "worker_collected",
            "current_iteration": next_iteration,
            "loop_dir": str(loop_dir),
            "iteration_dir": str(result["iteration_dir"]),
            "worktree_path": str(result["worktree_path"]),
            "report_path": str(result["report_path"]),
            "report_status": result["report_status"],
            "error_code": result["error_code"] if result["error_code"] else None,
            "changed_files": result["changed_files"],
            "consumed_next_task_path": str(consumed_path),
            **result["artifact_paths"],
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


def build_start_parser():
    parser = JsonArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--task-file", required=True)
    parser.add_argument("--acceptance-file", required=True)
    parser.add_argument("--auto-fix", action="store_true")
    parser.add_argument("--max-iterations", type=int)
    return parser


def build_continue_parser():
    parser = JsonArgumentParser()
    parser.add_argument("--loop-dir", required=True)
    return parser


def main(argv):
    try:
        if argv and argv[0] == "continue":
            parser = build_continue_parser()
            args = parser.parse_args(argv[1:])
            return continue_command(args)
        if argv and argv[0] == "start":
            argv = argv[1:]
        parser = build_start_parser()
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
