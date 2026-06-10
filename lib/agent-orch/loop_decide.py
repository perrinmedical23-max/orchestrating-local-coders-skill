#!/usr/bin/env python3
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


REQUIRED_REVIEWERS = ("correctness", "integration")
VALID_STATUSES = {"passed", "blocked", "needs_human"}
VALID_ACCEPTANCE_MATCHES = {"met", "partial", "not_met", "unclear"}


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


def read_json(path, error_code, label):
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        fail(error_code, f"{label} is invalid JSON: {path}: {exc}", {"path": str(path)})
    except OSError as exc:
        fail(error_code, f"{label} could not be read: {path}: {exc}", {"path": str(path)})
    if not isinstance(payload, dict):
        fail(error_code, f"{label} must be a JSON object: {path}", {"path": str(path)})
    return payload


def load_loop(loop_dir):
    loop_path = Path(loop_dir).expanduser().resolve(strict=False) / "loop.json"
    if not loop_path.is_file():
        fail("loop_not_found", f"loop not found: {loop_path.parent}")
    payload = read_json(loop_path, "loop_state_invalid", "loop state")
    if not isinstance(payload.get("current_iteration"), int):
        fail("loop_state_invalid", "loop current_iteration must be an integer")
    if not isinstance(payload.get("loop_id"), str):
        fail("loop_state_invalid", "loop_id must be a string")
    return loop_path, payload


def load_report(report_path):
    if not report_path.is_file():
        fail("report_missing", f"current iteration report is missing: {report_path}", {"report_path": str(report_path)})
    return read_json(report_path, "report_invalid", "current iteration report")


def require_review_string(payload, field):
    if not isinstance(payload.get(field), str):
        raise ValueError(f"review field must be a string: {field}")


def require_review_array(payload, field):
    if not isinstance(payload.get(field), list):
        raise ValueError(f"review field must be an array: {field}")


def validate_recorded_review(reviewer, payload):
    require_review_string(payload, "status")
    if payload["status"] not in VALID_STATUSES:
        raise ValueError("review status must be passed, blocked, or needs_human")
    require_review_string(payload, "summary")
    require_review_array(payload, "blocking_findings")
    if reviewer == "correctness":
        require_review_array(payload, "tests_required")
        require_review_array(payload, "residual_risks")
        return
    require_review_string(payload, "acceptance_match")
    if payload["acceptance_match"] not in VALID_ACCEPTANCE_MATCHES:
        raise ValueError("acceptance_match must be met, partial, not_met, or unclear")
    require_review_array(payload, "integration_risks")
    if "suggested_next_task" not in payload:
        raise ValueError("review field is required: suggested_next_task")
    if not (payload["suggested_next_task"] is None or isinstance(payload["suggested_next_task"], (str, dict))):
        raise ValueError("suggested_next_task must be null, string, or object")


def normalize_recorded_review(reviewer, review_path):
    if not review_path.is_file():
        return None
    try:
        with review_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (json.JSONDecodeError, OSError) as exc:
        return {
            "status": "needs_human",
            "summary": "Recorded reviewer JSON is unreadable and requires human review.",
            "blocking_findings": [],
            "error_code": "review_state_invalid",
            "diagnostic": str(exc),
        }
    if not isinstance(payload, dict):
        return {
            "status": "needs_human",
            "summary": "Recorded reviewer JSON is not an object and requires human review.",
            "blocking_findings": [],
            "error_code": "review_state_invalid",
            "diagnostic": f"{reviewer} review must be a JSON object",
        }
    try:
        validate_recorded_review(reviewer, payload)
    except ValueError as exc:
        return {
            **payload,
            "status": "needs_human",
            "error_code": payload.get("error_code", "review_state_invalid"),
            "diagnostic": str(exc),
        }
    return payload


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def update_loop_state(loop_path, loop_payload, state):
    updated = dict(loop_payload)
    updated["state"] = state
    updated["updated_at"] = utc_now()
    write_json(loop_path, updated)


def finding_summary(reviewer, review_payload, finding):
    if isinstance(finding, dict):
        return {
            "reviewer": reviewer,
            "review_summary": review_payload.get("summary", ""),
            "severity": finding.get("severity"),
            "file": finding.get("file"),
            "line": finding.get("line"),
            "issue": finding.get("issue"),
            "recommendation": finding.get("recommendation"),
        }
    return {
        "reviewer": reviewer,
        "review_summary": review_payload.get("summary", ""),
        "severity": None,
        "file": None,
        "line": None,
        "issue": str(finding),
        "recommendation": None,
    }


def collect_blocker_summaries(reviews):
    blockers = []
    for reviewer in REQUIRED_REVIEWERS:
        review_payload = reviews[reviewer]["payload"]
        if review_payload["status"] != "blocked":
            continue
        findings = review_payload.get("blocking_findings", [])
        if findings:
            blockers.extend(finding_summary(reviewer, review_payload, finding) for finding in findings)
        else:
            blockers.append(
                {
                    "reviewer": reviewer,
                    "review_summary": review_payload.get("summary", ""),
                    "severity": None,
                    "file": None,
                    "line": None,
                    "issue": review_payload.get("summary", "Reviewer blocked without a finding."),
                    "recommendation": None,
                }
            )
    return blockers


def blocker_signature(blocker_summaries):
    normalized = []
    for blocker in blocker_summaries:
        normalized.append(
            {
                "reviewer": blocker.get("reviewer"),
                "file": blocker.get("file"),
                "line": blocker.get("line"),
                "issue": blocker.get("issue"),
                "recommendation": blocker.get("recommendation"),
            }
        )
    normalized.sort(
        key=lambda item: (
            str(item.get("reviewer")),
            str(item.get("file")),
            str(item.get("line")),
            str(item.get("issue")),
            str(item.get("recommendation")),
        )
    )
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def prior_blocker_signatures(loop_dir, current_iteration):
    signatures = set()
    for iteration_number in range(1, current_iteration):
        iteration_dir = loop_dir / "iterations" / str(iteration_number)
        for name in ("next_task.json", "next_task.consumed.json"):
            path = iteration_dir / name
            if not path.is_file():
                continue
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            signature = payload.get("blocker_signature")
            if isinstance(signature, str) and signature:
                signatures.add(signature)
        decision_path = iteration_dir / "decision.json"
        if decision_path.is_file():
            try:
                payload = json.loads(decision_path.read_text(encoding="utf-8"))
            except Exception:
                continue
            signature = payload.get("blocker_signature")
            if isinstance(signature, str) and signature:
                signatures.add(signature)
    return signatures


def read_text_if_exists(path):
    try:
        return path.read_text(encoding="utf-8") if path.is_file() else ""
    except OSError:
        return ""


def archive_stale_next_task(iteration_dir, decision):
    next_task_path = iteration_dir / "next_task.json"
    if not next_task_path.is_file():
        return None
    stale_path = iteration_dir / "next_task.stale.json"
    try:
        payload = json.loads(next_task_path.read_text(encoding="utf-8"))
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    payload["stale_at"] = utc_now()
    payload["stale_decision"] = decision
    write_json(stale_path, payload)
    next_task_path.unlink()
    return stale_path


def iteration_artifact_paths(iteration_dir):
    paths = {
        "stdout_path": str(iteration_dir / "stdout.log"),
        "stderr_path": str(iteration_dir / "stderr.log"),
        "provider_result_path": str(iteration_dir / "provider-result.json"),
        "workspace_audit_path": str(iteration_dir / "workspace-audit.json"),
    }
    raw_report_path = iteration_dir / "report.raw"
    if raw_report_path.is_file():
        paths["raw_report_path"] = str(raw_report_path)
    return paths


def build_next_task(loop_payload, loop_dir, iteration, iteration_dir, reviews, report_payload):
    first_task = read_json(loop_dir / "iterations" / "1" / "task.json", "task_invalid", "initial task")
    current_task = read_json(iteration_dir / "task.json", "task_invalid", "current task")
    blocker_summaries = collect_blocker_summaries(reviews)
    signature = blocker_signature(blocker_summaries)
    acceptance_criteria = first_task.get("acceptance_criteria", current_task.get("acceptance_criteria", ""))
    blocker_lines = []
    for index, blocker in enumerate(blocker_summaries, start=1):
        location_parts = [str(value) for value in (blocker.get("file"), blocker.get("line")) if value not in (None, "")]
        location = ":".join(location_parts) if location_parts else "unspecified location"
        issue = blocker.get("issue") or blocker.get("review_summary") or "Blocking reviewer finding"
        recommendation = blocker.get("recommendation")
        line = f"{index}. [{blocker.get('reviewer')}] {location}: {issue}"
        if recommendation:
            line = f"{line} Recommendation: {recommendation}"
        blocker_lines.append(line)
    task_statement = "\n".join(
        [
            "Fix only the blocking reviewer findings listed below. Keep the change narrower than the original task.",
            "",
            "Blocking findings:",
            *blocker_lines,
            "",
            "Original acceptance criteria still apply.",
        ]
    )
    return {
        "schema_version": 1,
        "loop_id": loop_payload["loop_id"],
        "source_iteration": iteration,
        "target_iteration": iteration + 1,
        "provider": loop_payload["provider"],
        "role": loop_payload["role"],
        "task_statement": task_statement,
        "acceptance_criteria": acceptance_criteria,
        "original_task_statement": first_task.get("task_statement", ""),
        "original_acceptance_criteria": acceptance_criteria,
        "blocker_summaries": blocker_summaries,
        "blocker_signature": signature,
        "current_diff_summary": read_text_if_exists(iteration_dir / "diff_summary"),
        "prior_report_summary": report_payload.get("summary"),
        "generated_at": utc_now(),
    }


def decide_command(args):
    loop_path, loop_payload = load_loop(args.loop_dir)
    loop_dir = loop_path.parent
    iteration = loop_payload["current_iteration"]
    iteration_dir = loop_dir / "iterations" / str(iteration)
    report_path = iteration_dir / "report.json"
    reviews_dir = iteration_dir / "reviews"
    decision_path = iteration_dir / "decision.json"

    report_payload = load_report(report_path)

    reviews = {}
    missing_reviewers = []
    for reviewer in REQUIRED_REVIEWERS:
        review_path = reviews_dir / f"{reviewer}.json"
        review_payload = normalize_recorded_review(reviewer, review_path)
        if review_payload is None:
            missing_reviewers.append(reviewer)
        else:
            raw_review_path = reviews_dir / f"{reviewer}.raw"
            reviews[reviewer] = {
                "path": str(review_path),
                "raw_path": str(raw_review_path) if raw_review_path.is_file() else None,
                "payload": review_payload,
                "status": review_payload["status"],
            }

    if missing_reviewers:
        fail(
            "review_missing",
            "required reviewer output is missing",
            {
                "loop_id": loop_payload["loop_id"],
                "current_iteration": iteration,
                "missing_reviewers": missing_reviewers,
            },
        )

    reviewer_statuses = {reviewer: reviews[reviewer]["status"] for reviewer in REQUIRED_REVIEWERS}
    blocking_reviewers = [
        reviewer
        for reviewer in REQUIRED_REVIEWERS
        if reviewer_statuses[reviewer] in {"blocked", "needs_human"}
    ]
    needs_human_reviewers = [
        reviewer
        for reviewer in REQUIRED_REVIEWERS
        if reviewer_statuses[reviewer] == "needs_human"
    ]
    blocked_reviewers = [
        reviewer
        for reviewer in REQUIRED_REVIEWERS
        if reviewer_statuses[reviewer] == "blocked"
    ]
    workspace_violation = report_payload.get("error_code") == "workspace_violation" or any(
        reviews[reviewer]["payload"].get("error_code") == "workspace_violation"
        for reviewer in REQUIRED_REVIEWERS
    )
    next_task_path = None
    blocker_summaries = []
    signature = None
    if workspace_violation:
        state = "manual_gate"
        decision = "workspace_violation"
    elif all(status == "passed" for status in reviewer_statuses.values()):
        state = "completed"
        decision = "completed"
    elif needs_human_reviewers:
        state = "manual_gate"
        decision = "manual_gate"
    elif blocked_reviewers and loop_payload.get("auto_fix"):
        max_iterations = loop_payload.get("max_iterations")
        blocker_summaries = collect_blocker_summaries(reviews)
        signature = blocker_signature(blocker_summaries)
        if signature in prior_blocker_signatures(loop_dir, iteration):
            state = "stopped"
            decision = "repeated_blocker"
        elif not isinstance(max_iterations, int) or iteration >= max_iterations:
            state = "failed_max_iterations"
            decision = "max_iterations_reached"
        else:
            state = "worker_collected"
            decision = "auto_fix_ready"
            next_task = build_next_task(loop_payload, loop_dir, iteration, iteration_dir, reviews, report_payload)
            next_task_path = iteration_dir / "next_task.json"
            write_json(next_task_path, next_task)
            signature = next_task["blocker_signature"]
    else:
        state = "manual_gate"
        decision = "manual_gate"

    stale_next_task_path = None
    if decision != "auto_fix_ready":
        stale_next_task_path = archive_stale_next_task(iteration_dir, decision)

    decided_at = utc_now()
    error_code = None
    if decision == "workspace_violation":
        error_code = "workspace_violation"
    elif decision == "manual_gate" and needs_human_reviewers:
        error_code = next(
            (
                reviews[reviewer]["payload"].get("error_code")
                for reviewer in needs_human_reviewers
                if reviews[reviewer]["payload"].get("error_code")
            ),
            "needs_human",
        )
    elif decision == "manual_gate":
        error_code = "review_blocked"
    elif decision in {"repeated_blocker", "max_iterations_reached"}:
        error_code = decision
    payload = {
        "loop_id": loop_payload["loop_id"],
        "state": state,
        "current_iteration": iteration,
        "decision": decision,
        "error_code": error_code,
        "loop_dir": str(loop_dir),
        "iteration_dir": str(iteration_dir),
        "blocking_reviewers": blocking_reviewers,
        "next_task_path": str(next_task_path) if next_task_path else None,
        "decided_at": decided_at,
        "report_path": str(report_path),
        **iteration_artifact_paths(iteration_dir),
        "report_status": report_payload.get("status"),
        "review_paths": {reviewer: reviews[reviewer]["path"] for reviewer in REQUIRED_REVIEWERS},
        "raw_review_paths": {
            reviewer: reviews[reviewer]["raw_path"]
            for reviewer in REQUIRED_REVIEWERS
            if reviews[reviewer]["raw_path"]
        },
        "reviewer_statuses": reviewer_statuses,
        "decision_path": str(decision_path),
        "blocker_summaries": blocker_summaries,
        "blocker_signature": signature,
        "stale_next_task_path": str(stale_next_task_path) if stale_next_task_path else None,
    }

    write_json(decision_path, payload)
    update_loop_state(loop_path, loop_payload, state)
    if decision == "repeated_blocker":
        fail(
            "repeated_blocker",
            "auto-fix stopped because reviewer blockers repeated",
            {
                "loop_id": loop_payload["loop_id"],
                "current_iteration": iteration,
                "decision_path": str(decision_path),
            },
        )
    print_json(payload)
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
    parser.add_argument("--loop-dir", required=True)
    return parser


def main(argv):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        return decide_command(args)
    except AgentOrchError as exc:
        print_error(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
