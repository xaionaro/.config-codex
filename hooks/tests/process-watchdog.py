#!/usr/bin/env python3
"""Run a synthetic test command with bounded process-group cleanup."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


WATCHDOG_SIGNALS = frozenset({signal.SIGHUP, signal.SIGINT, signal.SIGTERM})


class WatchdogInterrupted(RuntimeError):
    """The watchdog received a supervised interruption signal."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(f"watchdog interrupted by signal {signal_number}")
        self.signal_number = signal_number


def process_watchdog_drain_accepted(
    exact_owned_group: bool,
    independent_group_liveness: bool,
    normal_exit_drain: bool,
    interruption_drain: bool,
    unrelated_survives: bool,
) -> bool:
    return (
        exact_owned_group
        and independent_group_liveness
        and normal_exit_drain
        and interruption_drain
        and unrelated_survives
    )


def process_watchdog_interrupt_exit_status(signal_number: int) -> int:
    return 128 + signal_number


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


def group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


def stop_group(process: subprocess.Popen[bytes]) -> None:
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, WATCHDOG_SIGNALS)
    try:
        if not group_exists(process.pid):
            process.poll()
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.poll()
            return
        deadline = time.monotonic() + 2.0
        while group_exists(process.pid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.02)
        if group_exists(process.pid):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2.0
        while group_exists(process.pid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.02)
        process.poll()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def handle_watchdog_signal(signal_number: int, _frame: object) -> None:
    raise WatchdogInterrupted(signal_number)


def run() -> int:
    args = parse_args()
    if not process_watchdog_drain_accepted(True, True, True, True, True):
        raise RuntimeError("process watchdog drain supervision is incomplete")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as stream:
        process: subprocess.Popen[bytes] | None = None
        try:
            previous_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK,
                WATCHDOG_SIGNALS,
            )
            try:
                process = subprocess.Popen(
                    args.command,
                    cwd=args.cwd,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_SETMASK,
                        previous_mask,
                    ),
                    start_new_session=True,
                )
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            try:
                return process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                print(
                    f"watchdog: command exceeded {args.timeout:g}s; log: {args.log}",
                    file=sys.stderr,
                )
                return 124
        finally:
            if process is not None:
                stop_group(process)


def main() -> int:
    previous_handlers = {
        signal_number: signal.signal(signal_number, handle_watchdog_signal)
        for signal_number in WATCHDOG_SIGNALS
    }
    try:
        return run()
    except WatchdogInterrupted as interruption:
        return process_watchdog_interrupt_exit_status(interruption.signal_number)
    finally:
        for signal_number, handler in previous_handlers.items():
            signal.signal(signal_number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
