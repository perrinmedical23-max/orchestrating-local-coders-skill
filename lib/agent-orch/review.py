#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


VALID_REVIEWERS = {"correctness", "integration"}
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
        "message": exc.message,
    }
    if exc.details:
        payload.update(exc.details)
    print(json.dumps(payload, separators=(",", ":")), file=sys.stderr)


def print_json(payload):
    print(json.dumps(payload, separators=(",", ":")))


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
    if not isinstance(payload.get("current_iteration"), int):
        fail("loop_state_invalid", "loop current_iteration must be an integer")
    return loop_path, payload


def read_review_file(path):
    review_path = Path(path).expanduser().resolve(strict=False)
    if not review_path.is_file():
        fail("missing_file", f"review file does not exist: {review_path}")
    return review_path, review_path.read_text(encoding="utf-8")


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def require_object(payload):
    if not isinstance(payload, dict):
        fail("review_invalid", "review must be a JSON object")


def require_string(payload, field):
    if not isinstance(payload.get(field), str):
        fail("review_invalid", f"review field must be a string: {field}")


def require_array(payload, field):
    if not isinstance(payload.get(field), list):
        fail("review_invalid", f"review field must be an array: {field}")


def validate_common(payload):
    require_object(payload)
    require_string(payload, "status")
    if payload["status"] not in VALID_STATUSES:
        fail("review_invalid", f"review status must be one of: {', '.join(sorted(VALID_STATUSES))}")
    require_string(payload, "summary")
    require_array(payload, "blocking_findings")


def validate_correctness(payload):
    validate_common(payload)
    require_array(payload, "tests_required")
    require_array(payload, "residual_risks")


def validate_integration(payload):
    validate_common(payload)
    require_string(payload, "acceptance_match")
    if payload["acceptance_match"] not in VALID_ACCEPTANCE_MATCHES:
        fail("review_invalid", "acceptance_match must be met, partial, not_met, or unclear")
    require_array(payload, "integration_risks")
    if "suggested_next_task" not in payload:
        fail("review_invalid", "review field is required: suggested_next_task")
    if not (
        payload["suggested_next_task"] is None
        or isinstance(payload["suggested_next_task"], (str, dict))
    ):
        fail("review_invalid", "suggested_next_task must be null, string, or object")


def validate_review(reviewer, payload):
    if reviewer == "correctness":
        validate_correctness(payload)
    elif reviewer == "integration":
        validate_integration(payload)
    else:
        fail("invalid_reviewer", "reviewer must be correctness or integration")


def normalized_review(reviewer, summary, error_code, diagnostic):
    payload = {
        "status": "needs_human",
        "summary": summary,
        "blocking_findings": [],
        "error_code": error_code,
        "diagnostic": diagnostic,
    }
    if reviewer == "correctness":
        payload["tests_required"] = []
        payload["residual_risks"] = []
    else:
        payload["acceptance_match"] = "unclear"
        payload["integration_risks"] = []
        payload["suggested_next_task"] = None
    return payload


def record_command(args):
    if args.reviewer not in VALID_REVIEWERS:
        fail("invalid_reviewer", "reviewer must be correctness or integration")

    loop_path, loop_payload = load_loop(args.loop_dir)
    review_file, raw_text = read_review_file(args.review_file)
    iteration = loop_payload["current_iteration"]
    reviews_dir = loop_path.parent / "iterations" / str(iteration) / "reviews"
    review_path = reviews_dir / f"{args.reviewer}.json"
    raw_path = reviews_dir / f"{args.reviewer}.raw"

    try:
        payload = json.loads(raw_text)
        validate_review(args.reviewer, payload)
        write_json(review_path, payload)
        status = payload["status"]
    except json.JSONDecodeError as exc:
        reviews_dir.mkdir(parents=True, exist_ok=True)
        raw_path.write_text(raw_text, encoding="utf-8")
        payload = normalized_review(
            args.reviewer,
            "Reviewer output was not valid JSON and requires human review.",
            "review_json_invalid",
            str(exc),
        )
        write_json(review_path, payload)
        status = payload["status"]
    except AgentOrchError as exc:
        reviews_dir.mkdir(parents=True, exist_ok=True)
        raw_path.write_text(raw_text, encoding="utf-8")
        payload = normalized_review(
            args.reviewer,
            "Reviewer output did not match the required schema and requires human review.",
            exc.code,
            exc.message,
        )
        write_json(review_path, payload)
        status = payload["status"]

    print_json(
        {
            "loop_id": loop_payload["loop_id"],
            "reviewer": args.reviewer,
            "review_path": str(review_path),
            "status": status,
            "current_iteration": iteration,
            "loop_dir": str(loop_path.parent),
            "source_review_file": str(review_file),
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
    parser.add_argument("--loop-dir", required=True)
    parser.add_argument("--reviewer", required=True)
    parser.add_argument("--review-file", required=True)
    return parser


def main(argv):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        return record_command(args)
    except AgentOrchError as exc:
        print_error(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
