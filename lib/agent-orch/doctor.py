#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


ARTIFACTS = (
    "status.json",
    "metadata.json",
    "task.json",
    "report.json",
    "report.raw",
    "provider-result.json",
    "stdout.log",
    "stderr.log",
    "git.diffstat",
    "diff_summary",
)


def read_json(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def is_git_repo(path):
    if not path:
        return False
    try:
        subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        return True
    except Exception:
        return False


def tail_progress(task_dir):
    progress_path = task_dir / "attempts" / "1" / "progress.log"
    if not progress_path.exists():
        return []
    lines = [line.strip() for line in progress_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    return lines[-4:]


def artifact_booleans(task_dir):
    return {
        "stdout": (task_dir / "stdout.log").exists(),
        "stderr": (task_dir / "stderr.log").exists(),
        "report": (task_dir / "report.json").exists(),
        "report_raw": (task_dir / "report.raw").exists(),
        "diffstat": (task_dir / "git.diffstat").exists(),
        "attempts": (task_dir / "attempts").is_dir(),
    }


def provider_dir_from_status(status):
    command = status.get("provider_command")
    if not command:
        return None
    return str(Path(command).parent)


def readiness(task_dir, status, metadata):
    provider_dir = provider_dir_from_status(status)
    manifest_path = status.get("manifest_path")
    provider_command = status.get("provider_command")
    repo_path = metadata.get("repo_path")
    worktree_path = metadata.get("worktree_path")
    return {
        "provider_dir": {"exists": bool(provider_dir and Path(provider_dir).is_dir())},
        "provider_manifest": {"valid": bool(manifest_path and Path(manifest_path).is_file())},
        "provider_command": {"executable": bool(provider_command and Path(provider_command).is_file() and Path(provider_command).stat().st_mode & 0o111)},
        "repo": {"valid_git_repo": is_git_repo(repo_path)},
        "worktree": {"exists": bool(worktree_path and Path(worktree_path).is_dir())},
    }


def build_summary(task_dir):
    status = read_json(task_dir / "status.json") or {}
    metadata = read_json(task_dir / "metadata.json") or {}
    report = read_json(task_dir / "report.json") or {}
    provider_result = read_json(task_dir / "provider-result.json") or {}

    return {
        "task_id": status.get("task_id"),
        "status": status.get("status"),
        "phase": status.get("phase"),
        "worker": status.get("worker"),
        "provider_id": status.get("provider_id") or metadata.get("provider_id"),
        "provider_kind": status.get("provider_kind") or metadata.get("provider_kind"),
        "mode": status.get("mode"),
        "repo_path": metadata.get("repo_path") or status.get("repo_path"),
        "worktree_path": metadata.get("worktree_path") or status.get("worktree_path"),
        "runtime_ref": status.get("runtime_ref"),
        "session_ref": status.get("session_ref"),
        "workspace_path": status.get("workspace_path"),
        "binding_status": status.get("binding_status"),
        "progress_preview": tail_progress(task_dir),
        "report": {
            "status": report.get("status"),
            "path": str(task_dir / "report.json"),
        },
        "provider_result": {
            "exit_code": provider_result.get("exit_code"),
            "signal": provider_result.get("signal"),
            "timed_out": provider_result.get("timed_out"),
        },
        "artifacts": artifact_booleans(task_dir),
        "readiness": readiness(task_dir, status, metadata),
    }


def copy_if_exists(src, dst):
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def write_bundle(task_dir, bundle_path):
    bundle_path.mkdir(parents=True, exist_ok=True)
    for artifact in ARTIFACTS:
        copy_if_exists(task_dir / artifact, bundle_path / artifact)

    attempts_dir = task_dir / "attempts"
    if attempts_dir.is_dir():
        for src in attempts_dir.rglob("*"):
            if src.is_file():
                copy_if_exists(src, bundle_path / "attempts" / src.relative_to(attempts_dir))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-dir", required=True)
    parser.add_argument("--bundle")
    args = parser.parse_args(argv)

    task_dir = Path(args.task_dir).expanduser().resolve(strict=False)
    payload = build_summary(task_dir)
    if args.bundle:
        bundle_path = Path(args.bundle).expanduser().resolve(strict=False)
        write_bundle(task_dir, bundle_path)
        payload["bundle_path"] = str(bundle_path)

    print(json.dumps(payload, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
