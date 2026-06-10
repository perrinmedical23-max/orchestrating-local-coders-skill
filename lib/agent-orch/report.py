#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


VALID_STATUSES = {"completed", "partial", "failed"}
REQUIRED_LISTS = ("files_changed", "tests_run", "open_questions", "risks", "notes")


def load_json(path):
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_report(path):
    report = load_json(path)
    if not isinstance(report, dict):
        raise ValueError("report must be a JSON object")
    if report.get("status") not in VALID_STATUSES:
        raise ValueError("report status must be completed, partial, or failed")
    if not isinstance(report.get("summary"), str):
        raise ValueError("report summary is required")
    for key in REQUIRED_LISTS:
        if not isinstance(report.get(key), list):
            raise ValueError(f"report {key} must be a list")


def synthesize_failure(report_path, provider_result_path, stdout_path, stderr_path, raw_report_path):
    provider_result = {}
    try:
        provider_result = load_json(provider_result_path)
    except Exception:
        provider_result = {}

    if provider_result.get("timed_out"):
        error_code = "provider_timeout"
    elif provider_result.get("signal") is not None:
        error_code = "provider_signal"
    elif provider_result.get("exit_code") not in (None, 0):
        error_code = "provider_exit_failure"
    elif raw_report_path:
        error_code = "worker_report_invalid"
    else:
        error_code = "worker_report_missing"

    raw_path = str(Path(raw_report_path)) if raw_report_path else None
    payload = {
        "status": "failed",
        "error_code": error_code,
        "summary": "worker did not produce a valid report",
        "files_changed": [],
        "tests_run": [],
        "open_questions": [],
        "risks": ["worker_exit_failure"],
        "notes": ["see provider-result.json", "see stdout.log", "see stderr.log"],
        "diagnostics": {
            "exit_code": provider_result.get("exit_code"),
            "signal": provider_result.get("signal"),
            "timed_out": bool(provider_result.get("timed_out", False)),
            "provider_result_path": str(Path(provider_result_path)),
            "stdout_path": str(Path(stdout_path)),
            "stderr_path": str(Path(stderr_path)),
            "raw_report_path": raw_path,
        },
    }

    path = Path(report_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def main(argv):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("report_path")

    synthesize_parser = subparsers.add_parser("synthesize-failure")
    synthesize_parser.add_argument("report_path")
    synthesize_parser.add_argument("provider_result_path")
    synthesize_parser.add_argument("stdout_path")
    synthesize_parser.add_argument("stderr_path")
    synthesize_parser.add_argument("raw_report_path", nargs="?")

    args = parser.parse_args(argv)

    if args.command == "validate":
        try:
            validate_report(args.report_path)
        except Exception as exc:
            print(str(exc), file=sys.stderr)
            return 1
        return 0

    synthesize_failure(
        args.report_path,
        args.provider_result_path,
        args.stdout_path,
        args.stderr_path,
        args.raw_report_path,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
