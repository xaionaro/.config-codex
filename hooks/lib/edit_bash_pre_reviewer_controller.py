#!/usr/bin/env python3
"""Binary-safe exact-child controller for the first-tool-call reviewer."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import errno
import fcntl
import json
import os
from pathlib import Path
import selectors
import select
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Callable
from typing import Final


OUTPUT_CAP: Final = 4_096
READ_CHUNK: Final = 4_096
CONTROLLER_TIMEOUT_SECONDS: Final = 70.0
CHILD_GRACE_SECONDS: Final = 2.0
PUBLISHER_TIMEOUT_SECONDS: Final = 2.0
CAPTURE_CLEANUP_MARGIN_SECONDS: Final = 4.0
PR_SET_PDEATHSIG: Final = 1
PR_GET_PDEATHSIG: Final = 2
INPUT_FD_MINIMUM: Final = 300
READ_FD_MINIMUM: Final = 301
WRITE_FD_MINIMUM: Final = 302
CANCELLATION_SIGNALS: Final = frozenset(
    (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
)


class ControllerError(RuntimeError):
    """The controller cannot safely complete this hook invocation."""


class ExactSignalUnavailable(ControllerError):
    """The controller lost its only safe way to stop an owned child."""


def _fatal_controller_exit() -> None:
    """Let PDEATHSIG kill owned descendants; never continue fail-open."""
    os._exit(125)


@dataclass
class OwnedChild:
    pid: int
    pidfd: int
    release_fd: int
    previous_mask: set[signal.Signals]
    role: str = "child"
    status: int | None = None
    reaped: bool = False
    released: bool = False


@dataclass(frozen=True)
class CaptureResult:
    raw: bytes
    complete: bool
    cancelled: bool
    status: int
    maximum_retained: int


ExactProcess = OwnedChild
ExactPublisher = OwnedChild


@dataclass
class CancellationMonitor:
    cancelled: bool = False

    def observe(self, _number: int, _frame: object) -> None:
        self.cancelled = True


def _libc() -> ctypes.CDLL:
    return ctypes.CDLL(None, use_errno=True)


def _set_parent_death_signal(expected_parent: int) -> None:
    libc = _libc()
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) != 0:
        os._exit(121)
    if os.getppid() != expected_parent:
        os._exit(122)


def _reject_privileged_executable(path: Path) -> None:
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK):
        raise ControllerError("required executable is unavailable")
    if metadata.st_mode & (stat.S_ISUID | stat.S_ISGID):
        raise ControllerError("parent-death signal may not survive privileged exec")
    try:
        capability = os.getxattr(path, "security.capability")
    except OSError as error:
        if error.errno not in (errno.ENODATA, errno.ENOTSUP, errno.EOPNOTSUPP):
            raise ControllerError("cannot verify executable capabilities") from error
    else:
        if capability:
            raise ControllerError("parent-death signal may not survive capability exec")


def preflight(unshare: Path, bash: Path, worker: Path) -> None:
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise ControllerError("pidfd support is unavailable")
    if not unshare.is_absolute() or not bash.is_absolute() or not worker.is_absolute():
        raise ControllerError("controller paths must be absolute")
    _reject_privileged_executable(unshare.resolve(strict=True))
    _reject_privileged_executable(bash.resolve(strict=True))
    if not worker.is_file() or not os.access(worker, os.R_OK):
        raise ControllerError("reviewer worker is unavailable")
    backend_timeout = os.environ.get("CODEX_EDIT_PRE_REVIEWER_TIMEOUT", "58")
    if not backend_timeout.isascii() or not backend_timeout.isdigit():
        raise ControllerError("reviewer timeout is invalid")
    if not 1 <= int(backend_timeout) <= 58:
        raise ControllerError("reviewer timeout is invalid")
    os.environ["CODEX_EDIT_PRE_REVIEWER_TIMEOUT"] = backend_timeout
    parent_death_signal = ctypes.c_int()
    if _libc().prctl(PR_GET_PDEATHSIG, ctypes.byref(parent_death_signal)) != 0:
        raise ControllerError("parent-death signal support is unavailable")


def _duplicate_cloexec(fd: int, minimum: int) -> int:
    return fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, minimum)


def _close(fd: int) -> None:
    try:
        os.close(fd)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise


def signal_exact_process(
    child: OwnedChild,
    requested_signal: signal.Signals,
) -> None:
    if child.reaped:
        return
    try:
        signal.pidfd_send_signal(child.pidfd, requested_signal)
    except ProcessLookupError:
        pass
    except OSError as error:
        libc = _libc()
        if libc.pidfd_send_signal(child.pidfd, requested_signal, None, 0) != 0:
            fallback_error = ctypes.get_errno()
            if fallback_error != errno.ESRCH:
                raise ExactSignalUnavailable("cannot signal exact child") from error


def wait_exact_process(child: OwnedChild) -> int:
    waited_pid, raw_status = os.waitpid(child.pid, 0)
    if waited_pid != child.pid:
        raise ControllerError(f"wrong {child.role} reaped")
    child.reaped = True
    child.status = os.waitstatus_to_exitcode(raw_status)
    return child.status


def terminate_exact_process(child: OwnedChild) -> int:
    if child.reaped:
        raise ControllerError(f"{child.role} child was already reaped")
    signal_exact_process(child, signal.SIGTERM)
    ready, _, _ = select.select([child.pidfd], [], [], CHILD_GRACE_SECONDS)
    if not ready:
        signal_exact_process(child, signal.SIGKILL)
    return wait_exact_process(child)


def _cleanup_owned_child(child: OwnedChild) -> int:
    """Restore controller state and finish the exact child on every exit path."""
    _close(child.release_fd)
    child.release_fd = -1
    try:
        _restore_mask(child.previous_mask)
    except OSError:
        pass
    status = child.status if child.status is not None else 1
    try:
        if not child.reaped:
            if child.released:
                status = terminate_exact_process(child)
            else:
                ready, _, _ = select.select(
                    [child.pidfd], [], [], CHILD_GRACE_SECONDS
                )
                if not ready:
                    signal_exact_process(child, signal.SIGKILL)
                status = wait_exact_process(child)
        return status
    except ExactSignalUnavailable:
        _fatal_controller_exit()
    finally:
        _close(child.pidfd)
        child.pidfd = -1


class OwnedChildGuard:
    def __init__(self, start: Callable[[], OwnedChild]) -> None:
        self._start = start
        self.child: OwnedChild | None = None
        self.status = 1

    def __enter__(self) -> OwnedChild:
        self.child = self._start()
        return self.child

    def __exit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: object,
    ) -> None:
        assert self.child is not None
        self.status = _cleanup_owned_child(self.child)


def retain_raw_chunk(
    retained: bytearray,
    raw_count: int,
    chunk: bytes,
) -> tuple[int, bool]:
    next_count = raw_count + len(chunk)
    remaining = OUTPUT_CAP + 1 - len(retained)
    if remaining > 0:
        retained.extend(chunk[:remaining])
    assert len(retained) <= OUTPUT_CAP + 1
    return next_count, b"\0" in chunk or next_count > OUTPUT_CAP


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> object:
    raise ValueError(f"unsupported JSON constant: {value}")


def validate_hook_output(raw: bytes) -> bytes | None:
    if raw == b"":
        return b""
    if b"\0" in raw or len(raw) > OUTPUT_CAP:
        return None
    try:
        decoded = raw.decode("utf-8", "strict")
        parsed = json.loads(
            decoded,
            object_pairs_hook=_strict_object,
            parse_constant=_reject_json_constant,
        )
        if not isinstance(parsed, dict):
            return None
        hook = parsed.get("hookSpecificOutput")
        if not isinstance(hook, dict):
            return None
        if hook.get("hookEventName") != "PreToolUse":
            return None
        if hook.get("permissionDecision") not in ("allow", "deny"):
            return None
        if not isinstance(hook.get("permissionDecisionReason"), str):
            return None
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        return None
    return raw


def _wait_exact_pid(pid: int) -> int:
    waited_pid, status = os.waitpid(pid, 0)
    if waited_pid != pid:
        raise ControllerError("wrong child reaped")
    return os.waitstatus_to_exitcode(status)


def _open_gate() -> tuple[int, int]:
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    os.set_blocking(read_fd, True)
    return read_fd, write_fd


def _gate_child(
    read_fd: int,
    previous_mask: set[signal.Signals],
) -> bool:
    try:
        release = os.read(read_fd, 1)
    except OSError:
        return False
    finally:
        _close(read_fd)
    if release != b"\0":
        return False
    for requested in CANCELLATION_SIGNALS:
        signal.signal(requested, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    return True


def _restore_mask(previous_mask: set[signal.Signals]) -> None:
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def _failed_gated_fork(
    pid: int,
    release_fd: int,
    previous_mask: set[signal.Signals],
    deadline: float,
) -> None:
    try:
        _close(release_fd)
        cleanup_deadline = min(
            deadline,
            time.monotonic() + CHILD_GRACE_SECONDS,
        )
        while True:
            waited_pid, _status = os.waitpid(pid, os.WNOHANG)
            if waited_pid == pid:
                return
            remaining = cleanup_deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.01, remaining))
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _wait_exact_pid(pid)
    finally:
        _restore_mask(previous_mask)


def _release_gate(
    child: OwnedChild,
    monitor: CancellationMonitor,
    wake_write: int,
) -> bool:
    previous_wakeup: int | None = None
    try:
        previous_wakeup = signal.set_wakeup_fd(child.release_fd)
        _restore_mask(child.previous_mask)
        if monitor.cancelled or signal.sigpending() & CANCELLATION_SIGNALS:
            return False
        try:
            os.write(child.release_fd, b"\0")
        except OSError:
            return False
        child.released = True
        return True
    finally:
        signal.set_wakeup_fd(
            wake_write
            if previous_wakeup is None or previous_wakeup < 0
            else previous_wakeup
        )
        try:
            _restore_mask(child.previous_mask)
        except OSError:
            pass
        _close(child.release_fd)
        child.release_fd = -1
        if monitor.cancelled or signal.sigpending() & CANCELLATION_SIGNALS:
            try:
                os.write(wake_write, b"\0")
            except BlockingIOError:
                pass


def _select_unless_cancelled(
    selector: selectors.BaseSelector,
    monitor: CancellationMonitor,
    timeout: float,
) -> list[tuple[selectors.SelectorKey, int]]:
    if monitor.cancelled:
        return []
    return selector.select(timeout)


def _reviewer_child(
    unshare: Path,
    bash: Path,
    worker: Path,
    input_fd: int,
    write_fd: int,
    gate_read: int,
    expected_parent: int,
    previous_mask: set[signal.Signals],
) -> None:
    _set_parent_death_signal(expected_parent)
    if not _gate_child(gate_read, previous_mask):
        os._exit(0)
    try:
        os.dup2(input_fd, 0)
        os.dup2(write_fd, 1)
        null_fd = os.open(os.devnull, os.O_WRONLY | os.O_CLOEXEC)
        os.dup2(null_fd, 2)
        _close(null_fd)
        _close(input_fd)
        _close(write_fd)
        os.execv(
            str(unshare),
            [
                str(unshare),
                "--user",
                "--map-root-user",
                "--pid",
                "--fork",
                "--kill-child=KILL",
                str(bash),
                str(worker),
            ],
        )
    except OSError:
        os._exit(123)
    os._exit(124)


def _start_reviewer(
    unshare: Path,
    bash: Path,
    worker: Path,
    input_fd: int,
    write_fd: int,
    deadline: float | None = None,
) -> ExactProcess:
    if deadline is None:
        deadline = time.monotonic() + CONTROLLER_TIMEOUT_SECONDS
    expected_parent = os.getpid()
    gate_read, gate_write = _open_gate()
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
    try:
        pid = os.fork()
    except OSError:
        _close(gate_read)
        _close(gate_write)
        _restore_mask(previous_mask)
        raise
    if pid == 0:
        _close(gate_write)
        _reviewer_child(
            unshare,
            bash,
            worker,
            input_fd,
            write_fd,
            gate_read,
            expected_parent,
            previous_mask,
        )
    _close(gate_read)
    try:
        pidfd = os.pidfd_open(pid)
    except OSError as error:
        _failed_gated_fork(pid, gate_write, previous_mask, deadline)
        raise ControllerError("cannot own reviewer child") from error
    return OwnedChild(pid, pidfd, gate_write, previous_mask, "reviewer")


def capture_reviewer(
    unshare: Path,
    bash: Path,
    worker: Path,
    wake_read: int,
    wake_write: int,
    monitor: CancellationMonitor,
    deadline: float | None = None,
) -> CaptureResult:
    if deadline is None:
        deadline = time.monotonic() + CONTROLLER_TIMEOUT_SECONDS
    input_fd = _duplicate_cloexec(0, INPUT_FD_MINIMUM)
    pipe_read, pipe_write = os.pipe2(os.O_CLOEXEC)
    read_fd = _duplicate_cloexec(pipe_read, READ_FD_MINIMUM)
    write_fd = _duplicate_cloexec(pipe_write, WRITE_FD_MINIMUM)
    _close(pipe_read)
    _close(pipe_write)
    retained = bytearray()
    raw_count = 0
    complete = False
    cancelled = False
    rejected = False
    status = 1
    guard = OwnedChildGuard(
        lambda: _start_reviewer(unshare, bash, worker, input_fd, write_fd, deadline)
    )
    try:
        with guard as child:
            _close(write_fd)
            _close(input_fd)
            os.set_blocking(read_fd, False)
            selector = selectors.DefaultSelector()
            selector.register(read_fd, selectors.EVENT_READ, "output")
            selector.register(child.pidfd, selectors.EVENT_READ, "child")
            selector.register(wake_read, selectors.EVENT_READ, "cancel")
            if not _release_gate(child, monitor, wake_write):
                cancelled = True
                return CaptureResult(b"", False, True, status, 0)
            capture_deadline = deadline - CAPTURE_CLEANUP_MARGIN_SECONDS
            while not (complete and child.reaped):
                events = _select_unless_cancelled(
                    selector,
                    monitor,
                    max(0.0, capture_deadline - time.monotonic()),
                )
                if not events:
                    cancelled = True
                    break
                if any(key.data == "cancel" for key, _mask in events):
                    try:
                        os.read(wake_read, READ_CHUNK)
                    except BlockingIOError:
                        pass
                    cancelled = True
                    break
                for key, _mask in events:
                    if key.data == "child":
                        selector.unregister(child.pidfd)
                        status = wait_exact_process(child)
                        continue
                    try:
                        chunk = os.read(read_fd, READ_CHUNK)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        complete = True
                        selector.unregister(read_fd)
                        continue
                    raw_count, rejected = retain_raw_chunk(retained, raw_count, chunk)
                    if rejected:
                        break
                if rejected:
                    break
    except (ControllerError, OSError, subprocess.SubprocessError):
        return CaptureResult(b"", False, monitor.cancelled, 1, len(retained))
    finally:
        _close(input_fd)
        _close(write_fd)
        if "selector" in locals():
            selector.close()
        _close(read_fd)
    if cancelled or rejected or not complete or status != 0:
        return CaptureResult(b"", complete, cancelled, status, len(retained))
    return CaptureResult(bytes(retained), True, False, status, len(retained))


def signal_exact_publisher(
    publisher: OwnedChild,
    requested_signal: signal.Signals,
) -> None:
    signal_exact_process(publisher, requested_signal)


def wait_exact_publisher(publisher: OwnedChild) -> int:
    return wait_exact_process(publisher)


def terminate_exact_publisher(publisher: OwnedChild) -> int:
    return terminate_exact_process(publisher)


def _write_payload(payload: bytes) -> None:
    _close(0)
    metadata = os.fstat(1)
    if not stat.S_ISFIFO(metadata.st_mode):
        raise OSError(errno.EINVAL, "hook output is not a pipe")
    pipe_buf = os.fpathconf(1, "PC_PIPE_BUF")
    if len(payload) > OUTPUT_CAP or len(payload) > pipe_buf:
        raise OSError(errno.E2BIG, "hook output exceeds atomic pipe bound")
    if os.write(1, payload) != len(payload):
        raise OSError(errno.EIO, "atomic hook output write was incomplete")


def _publisher_child(
    payload: bytes,
    gate_read: int,
    expected_parent: int,
    previous_mask: set[signal.Signals],
) -> None:
    _set_parent_death_signal(expected_parent)
    if not _gate_child(gate_read, previous_mask):
        os._exit(0)
    try:
        _write_payload(payload)
    except OSError:
        os._exit(7)
    os._exit(0)


def _start_publisher(
    payload: bytes,
    deadline: float | None = None,
) -> ExactPublisher:
    if deadline is None:
        deadline = time.monotonic() + PUBLISHER_TIMEOUT_SECONDS
    expected_parent = os.getpid()
    gate_read, gate_write = _open_gate()
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
    try:
        pid = os.fork()
    except OSError:
        _close(gate_read)
        _close(gate_write)
        _restore_mask(previous_mask)
        raise
    if pid == 0:
        _close(gate_write)
        _publisher_child(payload, gate_read, expected_parent, previous_mask)
    _close(gate_read)
    try:
        pidfd = os.pidfd_open(pid)
    except OSError as error:
        _failed_gated_fork(pid, gate_write, previous_mask, deadline)
        raise ControllerError("cannot own publisher child") from error
    return OwnedChild(pid, pidfd, gate_write, previous_mask, "publisher")


def publish_exact(
    payload: bytes,
    wake_read: int,
    wake_write: int,
    monitor: CancellationMonitor,
    deadline: float | None = None,
) -> tuple[bool, bool]:
    if deadline is None:
        deadline = time.monotonic() + PUBLISHER_TIMEOUT_SECONDS
    guard = OwnedChildGuard(lambda: _start_publisher(payload, deadline))
    cancelled = False
    status = 1
    with guard as publisher:
        try:
            selector = selectors.DefaultSelector()
            selector.register(publisher.pidfd, selectors.EVENT_READ, "publisher")
            selector.register(wake_read, selectors.EVENT_READ, "cancel")
            if not _release_gate(publisher, monitor, wake_write):
                cancelled = True
                return cancelled, False
            events = _select_unless_cancelled(
                selector,
                monitor,
                max(
                    0.0,
                    min(PUBLISHER_TIMEOUT_SECONDS, deadline - time.monotonic()),
                ),
            )
            if not events:
                cancelled = True
                signal_exact_publisher(publisher, signal.SIGKILL)
            elif any(key.data == "cancel" for key, _mask in events):
                cancelled = True
                try:
                    os.read(wake_read, READ_CHUNK)
                except BlockingIOError:
                    pass
                status = terminate_exact_publisher(publisher)
            if not publisher.reaped:
                status = wait_exact_publisher(publisher)
        finally:
            if "selector" in locals():
                selector.close()
    if status == 1:
        status = guard.status
    return cancelled, not cancelled and status == 0


def run_controller(unshare: Path, bash: Path, worker: Path) -> int:
    deadline = time.monotonic() + CONTROLLER_TIMEOUT_SECONDS
    preflight(unshare, bash, worker)
    if time.monotonic() >= deadline:
        raise ControllerError("controller deadline expired during preflight")
    wake_read, wake_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    previous_wakeup = signal.set_wakeup_fd(wake_write)
    monitor = CancellationMonitor()
    previous_handlers = {
        requested: signal.signal(requested, monitor.observe)
        for requested in CANCELLATION_SIGNALS
    }
    try:
        capture = capture_reviewer(
            unshare,
            bash,
            worker,
            wake_read,
            wake_write,
            monitor,
            deadline,
        )
        accepted = validate_hook_output(capture.raw) if capture.complete else None
        if (
            accepted is not None
            and accepted != b""
            and not capture.cancelled
            and not monitor.cancelled
            and capture.status == 0
        ):
            if time.monotonic() >= deadline:
                raise ControllerError("controller deadline expired before publication")
            publish_exact(accepted, wake_read, wake_write, monitor, deadline)
    finally:
        signal.set_wakeup_fd(previous_wakeup)
        for requested, handler in previous_handlers.items():
            signal.signal(requested, handler)
        _close(wake_read)
        _close(wake_write)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        return 0
    try:
        return run_controller(Path(argv[1]), Path(argv[2]), Path(argv[3]))
    except (ControllerError, OSError, subprocess.SubprocessError, ValueError):
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
