#!/usr/bin/env python3
"""External exact-source evidence for the Python pre-reviewer controller."""

from __future__ import annotations

from array import array
import argparse
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Final


PIPE_SIZE: Final = 4096
OUTPUT_CAP: Final = 4_096
WATCHDOG_SECONDS: Final = 8.0
SCENARIOS: Final = (
    "success",
    "failure",
    "nul-prefix",
    "nul-embedded",
    "nul-stream",
    "nul-open",
    "exact-cap",
    "over-cap-valid",
    "oversize-open",
    "partial-cancel",
    "real-timeout",
)


class EvidenceError(RuntimeError):
    """External observations contradict the exact-child contract."""


@dataclass(frozen=True)
class Fixture:
    root: Path
    wrapper: Path
    controller: Path
    worker: Path


@dataclass(frozen=True)
class TraceResult:
    label: str
    status: int
    output: bytes
    trace: str
    controller_pid: int
    events: tuple[str, ...]
    shell_tuple: str
    lean_tuple: str


@dataclass(frozen=True)
class SyscallCompletion:
    arguments: str
    result: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--lean", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--scenario", choices=SCENARIOS, action="append")
    parser.add_argument("--abrupt-death", action="store_true")
    parser.add_argument("--publication-evidence", action="store_true")
    parser.add_argument("--skip-lean", action="store_true")
    return parser.parse_args()


def _worker_source() -> str:
    return r'''#!/usr/bin/env bash
set -uo pipefail
input="$(cat)"
mode="$(printf '%s' "$input" | jq -r '.tool_input.command // "failure"')"
payload='{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
payload+='"permissionDecision":"deny","permissionDecisionReason":"generated"}}'
case "$mode" in
  success) printf '%s' "$payload" ;;
  publish-valid)
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
    printf '%s' '"permissionDecision":"deny","permissionDecisionReason":"'
    printf '%*s' 2900 ''
    printf '"}}'
    ;;
  failure) printf '%s' '{"hookSpecificOutput":'; exit 9 ;;
  nul-prefix) printf '\0%s' "$payload" ;;
  nul-embedded) printf '%s\0%s' "${payload:0:20}" "${payload:20}" ;;
  nul-stream)
    printf '%s' "${payload:0:20}"
    printf '\0'
    printf '%s' "${payload:20}"
    ;;
  nul-open)
    printf '\0'
    exec sleep 90
    ;;
  exact-cap)
    printf '%s' "$payload"
    printf '%*s' "$((4096 - ${#payload}))" ''
    ;;
  over-cap-valid)
    printf '%s' "$payload"
    printf '%*s' "$((4097 - ${#payload}))" ''
    ;;
  oversize-open)
    trap '' TERM
    while :; do printf '%4096s' ''; done
    ;;
  partial-cancel|real-timeout)
    printf '%s' '{"hookSpecificOutput":'
    exec sleep 90
    ;;
  descendant-no-pdeath)
    sleep 90 &
    wait
    ;;
  *) exit 97 ;;
esac
'''


def make_fixture(source_root: Path, destination: Path) -> Fixture:
    hooks = destination / "hooks"
    library = hooks / "lib"
    library.mkdir(parents=True)
    wrapper_source = source_root / "hooks" / "edit-bash-pre-reviewer.sh"
    controller_source = (
        source_root / "hooks" / "lib" / "edit_bash_pre_reviewer_controller.py"
    )
    wrapper = hooks / wrapper_source.name
    controller = library / controller_source.name
    wrapper.symlink_to(wrapper_source)
    controller.symlink_to(controller_source)
    worker = library / "edit-bash-pre-reviewer-worker.sh"
    worker.write_text(_worker_source(), encoding="utf-8")
    worker.chmod(0o755)
    if (
        not wrapper.samefile(wrapper_source)
        or not controller.samefile(controller_source)
    ):
        raise EvidenceError("fixture does not use exact controller sources")
    return Fixture(destination, wrapper, controller, worker)


def generated_input(mode: str) -> bytes:
    return json.dumps(
        {
            "session_id": "generated",
            "turn_id": f"generated-{mode}",
            "tool_name": "Bash",
            "tool_input": {"command": mode},
        },
        separators=(",", ":"),
    ).encode()


def wait_exact(process: subprocess.Popen[bytes], pidfd: int, timeout: float) -> int:
    ready, _, _ = select.select([pidfd], [], [], timeout)
    if not ready:
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
    status = process.wait()
    os.close(pidfd)
    return status


def _controller_pid(trace: str, controller: Path) -> int:
    del controller
    pattern = re.compile(
        r"^(?P<pid>\d+)\s+fcntl\(0, F_DUPFD_CLOEXEC, 300\)\s+= \d+$",
        re.MULTILINE,
    )
    match = pattern.search(trace)
    if match is None:
        raise EvidenceError("controller identity is absent from owned ancestry")
    return int(match.group("pid"))


def _wait_for_controller(trace_path: Path, controller: Path) -> int:
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        trace = trace_path.read_text(encoding="utf-8") if trace_path.exists() else ""
        try:
            return _controller_pid(trace, controller)
        except EvidenceError:
            time.sleep(0.002)
    raise EvidenceError("controller did not appear in owned trace")


def _children(trace: str, parent: int) -> list[int]:
    marker = re.search(
        rf"^{parent}\s+fcntl\(0, F_DUPFD_CLOEXEC, 300\)",
        trace,
        re.MULTILINE,
    )
    scoped = trace[marker.start() :] if marker is not None else trace
    return [
        int(match.group("child"))
        for match in re.finditer(
            rf"^{parent}\s+(?:clone|clone3)\([^\n]+\)\s+= (?P<child>\d+)$",
            scoped,
            re.MULTILINE,
        )
    ]


def _decode_hex_string(rendered: str) -> str | None:
    parts = re.findall(r"\\x([0-9a-fA-F]{2})", rendered)
    if not parts or "".join(f"\\x{part}" for part in parts) != rendered:
        return None
    try:
        return bytes.fromhex("".join(parts)).decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None


def _exec_pid(trace: str, executable_name: str, argument: str) -> int | None:
    pattern = re.compile(
        r'^(?P<pid>\d+)\s+execve\("(?P<path>[^"]*)",\s*'
        r'\[(?P<arguments>[^\]]*)\]',
        re.MULTILINE,
    )
    for match in pattern.finditer(trace):
        path = _decode_hex_string(match.group("path"))
        arguments = tuple(
            decoded
            for rendered in re.findall(r'"([^"]*)"', match.group("arguments"))
            if (decoded := _decode_hex_string(rendered)) is not None
        )
        if (
            path is not None
            and Path(path).name == executable_name
            and argument in arguments
        ):
            return int(match.group("pid"))
    return None


def _gate_consumed(trace: str, parent: int, child: int) -> bool:
    forks = tuple(
        re.finditer(
            rf"^{parent}\s+(?:clone|clone3)\([^\n]+\)\s+= (?P<child>\d+)$",
            trace,
            re.MULTILINE,
        )
    )
    selected = next(
        (
            index
            for index, match in enumerate(forks)
            if int(match.group("child")) == child
        ),
        None,
    )
    if selected is None:
        return False
    fork = forks[selected]
    gates = tuple(
        re.finditer(
            rf"^{parent}\s+pipe2\(\[(?P<read>\d+), (?P<write>\d+)\], "
            rf"(?=[^\n]*O_CLOEXEC)(?=[^\n]*O_NONBLOCK)[^\n]+\)\s+= 0$",
            trace[: fork.start()],
            re.MULTILINE,
        )
    )
    if not gates:
        return False
    gate_read = gates[-1].group("read")
    region = trace[fork.end() :]
    return any(
        completion.arguments.split(",", 1)[0].strip() == gate_read
        and "\\x00" in completion.arguments.lower()
        and completion.result.strip() == "1"
        for completion in _syscall_completions(region, child, "read")
    )


def _pidfd_for_child(trace: str, parent: int, child: int) -> int | None:
    match = re.search(
        rf"^{parent}\s+pidfd_open\({child}, 0\)\s+= (?P<fd>\d+)$",
        trace,
        re.MULTILINE,
    )
    return int(match.group("fd")) if match is not None else None


def _pidfd_signal_sent(trace: str, parent: int, pidfd: int | None) -> bool:
    return pidfd is not None and any(
        completion.arguments.split(",", 1)[0].strip() == str(pidfd)
        and completion.result.strip() == "0"
        for completion in _syscall_completions(
            trace, parent, "pidfd_send_signal"
        )
    )


def _controller_signal_delivered(trace: str, parent: int) -> bool:
    return re.search(
        rf"^{parent}\s+--- SIG(?:HUP|INT|TERM) ", trace, re.MULTILINE
    ) is not None


def _selector_timed_out(trace: str, parent: int) -> bool:
    return any(
        completion.result.strip() == "0"
        for syscall in ("epoll_wait", "epoll_pwait", "epoll_pwait2")
        for completion in _syscall_completions(trace, parent, syscall)
    )


def _capture_read_facts(
    trace: str,
    parent: int,
    read_fd: int | None,
) -> tuple[int, bool]:
    if read_fd is None:
        return 0, False
    count = 0
    nul_observed = False
    for completion in _syscall_completions(trace, parent, "read"):
        if completion.arguments.split(",", 1)[0].strip() != str(read_fd):
            continue
        result = completion.result.strip()
        if result.isdigit():
            count += int(result)
        nul_observed = nul_observed or "\\x00" in completion.arguments.lower()
    return count, nul_observed


def _fcntl_duplicate(trace: str, pid: int, source: int, minimum: int) -> int | None:
    match = re.search(
        rf"^{pid}\s+fcntl\({source}, F_DUPFD_CLOEXEC, {minimum}\)\s+= (?P<fd>\d+)$",
        trace,
        re.MULTILINE,
    )
    return int(match.group("fd")) if match is not None else None


def _syscall_completions(
    trace: str,
    pid: int,
    syscall: str,
) -> tuple[SyscallCompletion, ...]:
    complete = re.compile(
        rf"^{pid}\s+{re.escape(syscall)}\((?P<args>.*)\)\s+= (?P<result>.+)$"
    )
    unfinished = re.compile(
        rf"^{pid}\s+{re.escape(syscall)}\((?P<prefix>.*) <unfinished \.\.\.>$"
    )
    resumed = re.compile(
        rf"^{pid}\s+<\.\.\. {re.escape(syscall)} resumed>"
        rf"(?P<suffix>.*)\s+= (?P<result>.+)$"
    )
    pending: list[str] = []
    observed: list[SyscallCompletion] = []
    for line in trace.splitlines():
        if match := complete.fullmatch(line):
            observed.append(
                SyscallCompletion(match.group("args"), match.group("result"))
            )
        elif match := unfinished.fullmatch(line):
            pending.append(match.group("prefix"))
        elif match := resumed.fullmatch(line):
            if not pending:
                continue
            suffix = match.group("suffix").rstrip()
            arguments = pending.pop(0) + suffix
            if arguments.endswith(")"):
                arguments = arguments[:-1]
            observed.append(SyscallCompletion(arguments, match.group("result")))
    return tuple(observed)


def _closed(trace: str, pid: int, fd: int | None) -> bool:
    return fd is not None and any(
        completion.arguments.strip() == str(fd)
        and completion.result.strip() == "0"
        for completion in _syscall_completions(trace, pid, "close")
    )


def _waited(trace: str, pid: int, child: int) -> tuple[bool, bool]:
    for completion in _syscall_completions(trace, pid, "wait4"):
        first_argument = completion.arguments.split(",", 1)[0].strip()
        if first_argument != str(child) or completion.result.strip() != str(child):
            continue
        if "WIFEXITED(s)" in completion.arguments:
            status = re.search(
                r"WEXITSTATUS\(s\) == (?P<status>\d+)", completion.arguments
            )
            return True, status is not None and status.group("status") == "0"
        if "WIFSIGNALED(s)" in completion.arguments:
            return True, False
    return False, False


def _read_eof(trace: str, pid: int, fd: int | None) -> bool:
    return fd is not None and any(
        completion.arguments.split(",", 1)[0].strip() == str(fd)
        and completion.result.strip() == "0"
        for completion in _syscall_completions(trace, pid, "read")
    )


def external_events(
    trace: str,
    controller_pid: int,
    output: bytes,
    expected_output: bytes,
    label: str,
) -> tuple[str, ...]:
    del label
    events: list[str] = []
    input_fd = _fcntl_duplicate(trace, controller_pid, 0, 300)
    if input_fd is not None:
        events.append("preflight-passed")
        events.append("input-opened")
    children = _children(trace, controller_pid)
    if not children:
        return tuple(events)
    reviewer = children[0]
    reviewer_pidfd = _pidfd_for_child(trace, controller_pid, reviewer)
    if reviewer_pidfd is None:
        return tuple(events)
    events.append("reviewer-owned")
    if _gate_consumed(trace, controller_pid, reviewer):
        events.append("reviewer-started")
    pipe_match = re.search(
        rf"^{controller_pid}\s+pipe2\(\[(?P<read>\d+), "
        rf"(?P<write>\d+)\], O_CLOEXEC\)\s+= 0$",
        trace,
        re.MULTILINE,
    )
    read_fd = write_fd = None
    if pipe_match is not None:
        read_fd = _fcntl_duplicate(
            trace, controller_pid, int(pipe_match.group("read")), 301
        )
        write_fd = _fcntl_duplicate(
            trace, controller_pid, int(pipe_match.group("write")), 302
        )
    if _closed(trace, controller_pid, write_fd):
        events.append("reviewer-write-closed")
    if _closed(trace, controller_pid, input_fd):
        events.append("input-closed")
    reviewer_waited, reviewer_success = _waited(trace, controller_pid, reviewer)
    captured_count, captured_nul = _capture_read_facts(
        trace, controller_pid, read_fd
    )
    child_signalled = _pidfd_signal_sent(
        trace, controller_pid, reviewer_pidfd
    )
    cancelled = (
        child_signalled
        and reviewer_waited
        and not reviewer_success
        and (
            _controller_signal_delivered(trace, controller_pid)
            or _selector_timed_out(trace, controller_pid)
        )
    )
    rejected = (
        captured_nul
        or captured_count > OUTPUT_CAP
        or (reviewer_waited and not reviewer_success)
    )
    if rejected:
        events.append("capture-rejected")
    elif _read_eof(trace, controller_pid, read_fd):
        events.append("capture-complete")
    if _closed(trace, controller_pid, read_fd):
        events.append("reviewer-read-closed")
    if reviewer_waited:
        events.append(
            "reviewer-reaped:success" if reviewer_success else "reviewer-reaped:failure"
        )
    if (
        not rejected
        and "capture-complete" in events
        and output == expected_output
        and expected_output != b""
    ):
        events.append("bytes-valid")
    if cancelled:
        events.append("cancellation-observed")
    if len(children) >= 2:
        publisher = children[-1]
        publisher_pidfd = _pidfd_for_child(trace, controller_pid, publisher)
        if publisher_pidfd is None:
            return tuple(events)
        events.append("publisher-owned")
        if _gate_consumed(trace, controller_pid, publisher):
            events.append("publisher-started")
        if output:
            events.append("output-escaped")
        publisher_waited, publisher_success = _waited(trace, controller_pid, publisher)
        if publisher_waited:
            events.append(
                "publisher-reaped:success"
                if publisher_success
                else "publisher-reaped:failure"
            )
        if publisher_success and output == expected_output:
            events.append("publication-confirmed")
    return tuple(events)


def _tuple_from_events(events: tuple[str, ...]) -> str:
    started = "publisher-started" in events
    escaped = "output-escaped" in events
    confirmed = "publication-confirmed" in events
    reviewer_reaped = any(event.startswith("reviewer-reaped:") for event in events)
    descriptors = all(
        event in events
        for event in (
            "input-closed",
            "reviewer-read-closed",
            "reviewer-write-closed",
        )
    )
    cancelled = "cancellation-observed" in events
    return " ".join(
        "1" if value else "0"
        for value in (
            started,
            escaped,
            confirmed,
            reviewer_reaped,
            descriptors,
            cancelled,
        )
    )


def expected_output(label: str) -> bytes:
    payload = (
        b'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
        b'"permissionDecision":"deny","permissionDecisionReason":"generated"}}'
    )
    if label == "success":
        return payload
    if label == "exact-cap":
        return payload + b" " * (OUTPUT_CAP - len(payload))
    return b""


def publication_payload() -> bytes:
    return (
        b'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
        b'"permissionDecision":"deny","permissionDecisionReason":"'
        + b" " * 2900
        + b'"}}'
    )


def run_scenario(
    fixture: Fixture,
    lean: Path,
    artifact: Path,
    label: str,
    *,
    skip_lean: bool = False,
) -> TraceResult:
    artifact.mkdir(parents=True)
    trace_path = artifact / "strace"
    survivor = subprocess.Popen([shutil.which("sleep") or "sleep", "90"])
    survivor_pidfd = os.pidfd_open(survivor.pid)
    process = subprocess.Popen(
        [
            shutil.which("strace") or "strace",
            "-f",
            "-qq",
            "-xx",
            "-s",
            "65536",
            "-e",
            "trace=process,desc,signal",
            "-o",
            str(trace_path),
            shutil.which("bash") or "/bin/bash",
            str(fixture.wrapper),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "CODEX_PRE_REVIEWER_TRACE_FD": "1",
            "CODEX_PRE_REVIEWER_WAIT_NOTIFY_FD": "2",
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    )
    assert process.stdin is not None
    process.stdin.write(generated_input(label))
    process.stdin.close()
    wrapper_pidfd = os.pidfd_open(process.pid)
    controller_pidfd: int | None = None
    try:
        if label == "partial-cancel":
            controller_pid = _wait_for_controller(trace_path, fixture.controller)
            controller_pidfd = os.pidfd_open(controller_pid)
            time.sleep(0.05)
            signal.pidfd_send_signal(controller_pidfd, signal.SIGTERM)
        watchdog = 75.0 if label == "real-timeout" else WATCHDOG_SECONDS
        status = wait_exact(process, wrapper_pidfd, watchdog)
        survivor_ready, _, _ = select.select([survivor_pidfd], [], [], 0)
        if survivor_ready:
            raise EvidenceError("unrelated exact survivor was disturbed")
    finally:
        if controller_pidfd is not None:
            os.close(controller_pidfd)
        signal.pidfd_send_signal(survivor_pidfd, signal.SIGKILL)
        survivor.wait()
        os.close(survivor_pidfd)
    assert process.stdout is not None and process.stderr is not None
    output = process.stdout.read()
    errors = process.stderr.read()
    (artifact / "stdout").write_bytes(output)
    (artifact / "stderr").write_bytes(errors)
    trace = trace_path.read_text(encoding="utf-8")
    controller_pid = _controller_pid(trace, fixture.controller)
    expected = expected_output(label)
    if status != 0 or output != expected:
        raise EvidenceError(
            f"{label}: status/output mismatch {status}/{len(output)}"
        )
    events = external_events(trace, controller_pid, output, expected, label)
    shell_tuple = _tuple_from_events(events)
    expected_tuples = {
        "success": "1 1 1 1 1 0",
        "exact-cap": "1 1 1 1 1 0",
        "partial-cancel": "0 0 0 1 1 1",
        "real-timeout": "0 0 0 1 1 1",
    }
    expected_tuple = expected_tuples.get(label, "0 0 0 1 1 0")
    if not label.startswith(("failure", "nul", "over", "oversize", "partial", "real")):
        if "capture-complete" not in events:
            raise EvidenceError(f"{label}: exact reviewer EOF was not observed")
    if shell_tuple != expected_tuple:
        raise EvidenceError(
            f"{label}: external tuple {shell_tuple!r} != {expected_tuple!r}"
        )
    lean_tuple = "not-run"
    if not skip_lean:
        lean_run = subprocess.run(
            [str(lean), *events],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        lean_tuple = lean_run.stdout.decode().strip()
        if lean_tuple != shell_tuple:
            raise EvidenceError(
                f"{label}: shell {shell_tuple!r} != Lean {lean_tuple!r}"
            )
    return TraceResult(
        label,
        status,
        output,
        trace,
        controller_pid,
        events,
        shell_tuple,
        lean_tuple,
    )


def _pipe_bytes_available(fd: int) -> int:
    count = array("i", [0])
    fcntl.ioctl(fd, 0x541B, count, True)
    return count[0]


def _start_backpressured(
    fixture: Fixture,
    artifact: Path,
    filler: bytes,
) -> tuple[subprocess.Popen[bytes], int, int, int, Path, subprocess.Popen[bytes], int]:
    artifact.mkdir(parents=True)
    survivor = subprocess.Popen([shutil.which("sleep") or "sleep", "90"])
    survivor_pidfd = os.pidfd_open(survivor.pid)
    output_read, output_write = os.pipe()
    fcntl.fcntl(output_read, fcntl.F_SETPIPE_SZ, PIPE_SIZE)
    if filler:
        os.write(output_write, filler)
    trace_path = artifact / "strace"
    process = subprocess.Popen(
        [
            shutil.which("strace") or "strace",
            "-f",
            "-qq",
            "-xx",
            "-s",
            "65536",
            "-e",
            "trace=process,desc,signal",
            "-o",
            str(trace_path),
            shutil.which("bash") or "/bin/bash",
            str(fixture.wrapper),
        ],
        stdin=subprocess.PIPE,
        stdout=output_write,
        stderr=subprocess.DEVNULL,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    os.close(output_write)
    assert process.stdin is not None
    process.stdin.write(generated_input("publish-valid"))
    process.stdin.close()
    wrapper_pidfd = os.pidfd_open(process.pid)
    controller_pid = _wait_for_controller(trace_path, fixture.controller)
    controller_pidfd = os.pidfd_open(controller_pid)
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        trace = trace_path.read_text(encoding="utf-8")
        if len(_children(trace, controller_pid)) >= 2:
            return (
                process,
                wrapper_pidfd,
                controller_pidfd,
                output_read,
                trace_path,
                survivor,
                survivor_pidfd,
            )
        time.sleep(0.002)
    signal.pidfd_send_signal(controller_pidfd, signal.SIGKILL)
    wait_exact(process, wrapper_pidfd, 3.0)
    os.close(controller_pidfd)
    os.close(output_read)
    signal.pidfd_send_signal(survivor_pidfd, signal.SIGKILL)
    survivor.wait()
    os.close(survivor_pidfd)
    raise EvidenceError("publisher is absent from owned ancestry")


def _finish_backpressured(
    process: subprocess.Popen[bytes],
    wrapper_pidfd: int,
    controller_pidfd: int,
    output_read: int,
    survivor: subprocess.Popen[bytes],
    survivor_pidfd: int,
) -> tuple[int, bytes]:
    status = wait_exact(process, wrapper_pidfd, 4.0)
    os.close(controller_pidfd)
    blocks: list[bytes] = []
    while block := os.read(output_read, 65_536):
        blocks.append(block)
    os.close(output_read)
    survivor_ready, _, _ = select.select([survivor_pidfd], [], [], 0)
    if survivor_ready:
        raise EvidenceError("unrelated exact survivor was disturbed")
    signal.pidfd_send_signal(survivor_pidfd, signal.SIGKILL)
    survivor.wait()
    os.close(survivor_pidfd)
    return status, b"".join(blocks)


def publication_evidence(
    fixture: Fixture,
    lean: Path,
    artifact: Path,
    *,
    skip_lean: bool = False,
) -> dict[str, tuple[bool, bool, bool]]:
    filler = b"f" * PIPE_SIZE
    payload = publication_payload()
    states: dict[str, tuple[bool, bool, bool]] = {}

    started = _start_backpressured(
        fixture, artifact / "started-no-escape", filler
    )
    process, wrapper, controller, output_read, _trace, survivor, survivor_fd = started
    signal.pidfd_send_signal(controller, signal.SIGTERM)
    status, output = _finish_backpressured(
        process, wrapper, controller, output_read, survivor, survivor_fd
    )
    if status != 0 or output != filler:
        raise EvidenceError(
            "started/no-escape publication observation failed: "
            f"status={status} bytes={len(output)}"
        )
    states["started-no-escape"] = (True, False, False)

    atomic = _start_backpressured(
        fixture, artifact / "atomic-backpressure-no-escape", filler
    )
    process, wrapper, controller, output_read, _trace, survivor, survivor_fd = atomic
    time.sleep(0.05)
    if _pipe_bytes_available(output_read) != PIPE_SIZE:
        raise EvidenceError("atomic publisher escaped into a partially available pipe")
    signal.pidfd_send_signal(controller, signal.SIGTERM)
    status, output = _finish_backpressured(
        process, wrapper, controller, output_read, survivor, survivor_fd
    )
    if status != 0 or output != filler:
        raise EvidenceError("atomic backpressure allowed partial publication")
    states["atomic-backpressure-no-escape"] = (True, False, False)

    complete = _start_backpressured(
        fixture, artifact / "complete-before-confirm", filler
    )
    process, wrapper, controller, output_read, _trace, survivor, survivor_fd = complete
    signal.pidfd_send_signal(controller, signal.SIGSTOP)
    collected = bytearray(os.read(output_read, PIPE_SIZE))
    deadline = time.monotonic() + 3.0
    while len(collected) < len(filler) + len(payload):
        if time.monotonic() >= deadline:
            raise EvidenceError(
                "atomic publication did not complete while controller stopped"
            )
        collected.extend(os.read(output_read, 65_536))
    signal.pidfd_send_signal(controller, signal.SIGTERM)
    signal.pidfd_send_signal(controller, signal.SIGCONT)
    status, remainder = _finish_backpressured(
        process, wrapper, controller, output_read, survivor, survivor_fd
    )
    if status != 0 or bytes(collected) + remainder != filler + payload:
        raise EvidenceError("complete-before-confirm publication observation failed")
    states["complete-before-confirm"] = (True, True, False)

    confirmed = run_scenario(
        fixture,
        lean,
        artifact / "confirmed",
        "success",
        skip_lean=skip_lean,
    )
    if confirmed.output != expected_output("success"):
        raise EvidenceError("confirmed publication output mismatch")
    states["confirmed"] = (True, True, True)

    mutants = (
        {
            key: (escaped, escaped, confirmed)
            for key, (_started, escaped, confirmed) in states.items()
        },
        {
            key: (started, confirmed, confirmed)
            for key, (started, _escaped, confirmed) in states.items()
        },
        {
            key: (started, escaped, started)
            for key, (started, escaped, _confirmed) in states.items()
        },
    )
    if any(mutant == states for mutant in mutants):
        raise EvidenceError("publication-state conflation mutation survived")
    return states


def abrupt_controller_death(fixture: Fixture, artifact: Path) -> None:
    artifact.mkdir(parents=True)
    trace_path = artifact / "strace"
    survivor = subprocess.Popen([shutil.which("sleep") or "sleep", "90"])
    survivor_pidfd = os.pidfd_open(survivor.pid)
    process = subprocess.Popen(
        [
            shutil.which("strace") or "strace",
            "-f",
            "-qq",
            "-xx",
            "-s",
            "65536",
            "-e",
            "trace=process,desc,signal",
            "-o",
            str(trace_path),
            shutil.which("bash") or "/bin/bash",
            str(fixture.wrapper),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    wrapper_pidfd = os.pidfd_open(process.pid)
    owned_pidfds: list[int] = []
    try:
        assert process.stdin is not None
        process.stdin.write(generated_input("descendant-no-pdeath"))
        process.stdin.close()
        controller_pid = _wait_for_controller(trace_path, fixture.controller)
        controller_pidfd = os.pidfd_open(controller_pid)
        owned_pidfds.append(controller_pidfd)
        deadline = time.monotonic() + 3.0
        reviewer_pid = descendant_pid = None
        while time.monotonic() < deadline:
            trace = trace_path.read_text(encoding="utf-8")
            children = _children(trace, controller_pid)
            sleep_pid = _exec_pid(trace, "sleep", "90")
            if children and sleep_pid is not None:
                reviewer_pid = children[0]
                descendant_pid = sleep_pid
                break
            time.sleep(0.002)
        if reviewer_pid is None or descendant_pid is None:
            raise EvidenceError("owned reviewer descendant ancestry is incomplete")
        reviewer_pidfd = os.pidfd_open(reviewer_pid)
        descendant_pidfd = os.pidfd_open(descendant_pid)
        owned_pidfds.extend((reviewer_pidfd, descendant_pidfd))
        signal.pidfd_send_signal(controller_pidfd, signal.SIGKILL)
        wait_exact(process, wrapper_pidfd, 4.0)
        wrapper_pidfd = -1
        for pidfd in (reviewer_pidfd, descendant_pidfd):
            ready, _, _ = select.select([pidfd], [], [], 2.0)
            if not ready:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
                raise EvidenceError("controller death left an owned descendant alive")
        survivor_ready, _, _ = select.select([survivor_pidfd], [], [], 0)
        if survivor_ready:
            raise EvidenceError("unrelated exact survivor was disturbed")
    finally:
        if wrapper_pidfd >= 0:
            try:
                signal.pidfd_send_signal(wrapper_pidfd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            os.close(wrapper_pidfd)
        for pidfd in owned_pidfds:
            os.close(pidfd)
        signal.pidfd_send_signal(survivor_pidfd, signal.SIGKILL)
        survivor.wait()
        os.close(survivor_pidfd)


def main() -> int:
    args = parse_args()
    if shutil.which("strace") is None:
        raise EvidenceError("strace is required")
    cleanup = args.artifact_root is None
    artifact_root = args.artifact_root or Path(
        tempfile.mkdtemp(prefix="pre-reviewer-exact-evidence-")
    )
    artifact_root.mkdir(parents=True, exist_ok=True)
    fixture = make_fixture(args.root, artifact_root / "fixture")
    try:
        labels = tuple(args.scenario) if args.scenario else SCENARIOS[:-1]
        for label in labels:
            result = run_scenario(
                fixture,
                args.lean,
                artifact_root / label,
                label,
                skip_lean=args.skip_lean,
            )
            print(
                f"{label}\t{result.shell_tuple}\t{' '.join(result.events)}"
            )
        if args.abrupt_death:
            abrupt_controller_death(fixture, artifact_root / "abrupt-death")
            print("abrupt-death\texact descendants gone; unrelated survivor alive")
        if args.publication_evidence:
            states = publication_evidence(
                fixture,
                args.lean,
                artifact_root / "publication",
                skip_lean=args.skip_lean,
            )
            print(f"publication-states\t{states}")
    finally:
        if cleanup:
            shutil.rmtree(artifact_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
