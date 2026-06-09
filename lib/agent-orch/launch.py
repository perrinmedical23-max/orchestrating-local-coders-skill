#!/usr/bin/env python3
import argparse
import json
import os
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def timeout_seconds():
    raw = os.environ.get("AGENT_ORCH_TIMEOUT_SECS", "1800")
    try:
        value = int(raw)
    except ValueError:
        value = 1800
    return max(value, 1)


def write_result(path, payload):
    with Path(path).open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("missing provider command", file=sys.stderr)
        return 2

    started_at = utc_now()
    timed_out = False
    returncode = None

    with Path(args.stdout).open("wb") as stdout, Path(args.stderr).open("wb") as stderr:
        try:
            process = subprocess.Popen(
                command,
                cwd=args.cwd,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
        except OSError as exc:
            returncode = 127
            stderr.write(f"failed to launch provider: {exc}\n".encode("utf-8", errors="replace"))
            stderr.flush()
            process = None

        if process is not None:
            try:
                returncode = process.wait(timeout=timeout_seconds())
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    returncode = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    returncode = process.wait()

    finished_at = utc_now()
    provider_signal = None
    exit_code = returncode
    if timed_out:
        exit_code = None
    elif returncode is not None and returncode < 0:
        provider_signal = -returncode
        exit_code = None

    write_result(
        args.result,
        {
            "provider": args.provider,
            "exit_code": exit_code,
            "signal": provider_signal,
            "timed_out": timed_out,
            "started_at": started_at,
            "finished_at": finished_at,
        },
    )

    if timed_out:
        return 124
    if provider_signal is not None:
        return 128 + provider_signal
    return int(exit_code or 0)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
