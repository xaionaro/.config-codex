#!/usr/bin/env python3
"""Run a synthetic test command with bounded process-group cleanup."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if args.timeout <= 0 or not args.command:
        parser.error("a positive timeout and command are required")
    return args


def stop_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def main() -> int:
    args = parse_args()
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as stream:
        process = subprocess.Popen(
            args.command,
            cwd=args.cwd,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            return process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            stop_group(process)
            print(
                f"watchdog: command exceeded {args.timeout:g}s; log: {args.log}",
                file=sys.stderr,
            )
            return 124
        except BaseException:
            stop_group(process)
            raise


if __name__ == "__main__":
    raise SystemExit(main())
