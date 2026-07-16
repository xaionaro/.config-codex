#!/usr/bin/env python3
"""Deterministic ownership and cancellation races for publication gates."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "hooks" / "lib" / "edit_bash_pre_reviewer_controller.py"
PAYLOAD = (
    b'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
    b'"permissionDecision":"deny","permissionDecisionReason":"generated"}}'
)


def run_helper(body: str) -> subprocess.CompletedProcess[bytes]:
    source = f"""
import errno
import importlib.util
import os
from pathlib import Path
import signal
import sys
import time

spec = importlib.util.spec_from_file_location(
    "generated_controller", {str(CONTROLLER)!r}
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
payload = {PAYLOAD!r}
{textwrap.dedent(body)}
"""
    return subprocess.run(
        [sys.executable, "-c", source],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5.0,
        check=False,
        env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"},
    )


class OwnershipGateTests(unittest.TestCase):
    def assert_silent_success(self, result: subprocess.CompletedProcess[bytes]) -> None:
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")

    def test_publisher_pidfd_failure_cannot_escape_output(self) -> None:
        result = run_helper(
            """
            def fail_pidfd(_pid):
                time.sleep(0.1)
                raise OSError(errno.EMFILE, "generated pidfd failure")
            module.os.pidfd_open = fail_pidfd
            try:
                module._start_publisher(payload)
            except (module.ControllerError, OSError):
                pass
            """
        )
        self.assert_silent_success(result)

    def test_reviewer_pidfd_failure_precedes_exec_and_output(self) -> None:
        result = run_helper(
            """
            def fail_pidfd(_pid):
                time.sleep(0.1)
                raise OSError(errno.EMFILE, "generated pidfd failure")
            module.os.pidfd_open = fail_pidfd
            try:
                module._start_reviewer(
                    Path("/bin/echo"),
                    Path("/bin/true"),
                    Path("/generated-sentinel"),
                    0,
                    1,
                )
            except (module.ControllerError, OSError):
                pass
            """
        )
        self.assert_silent_success(result)

    def test_stopped_publisher_pidfd_failure_is_bounded_and_reaped(self) -> None:
        result = run_helper(
            """
            observed = []
            def stop_before_gate(*_args):
                signal.raise_signal(signal.SIGSTOP)
                os._exit(98)
            def fail_after_stop(pid):
                observed.append(pid)
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WUNTRACED | os.WNOHANG)
                    if waited == pid and os.WIFSTOPPED(status):
                        raise OSError(errno.EMFILE, "generated stopped pidfd failure")
                    time.sleep(0.005)
                raise AssertionError("generated publisher did not stop")
            module._publisher_child = stop_before_gate
            module.os.pidfd_open = fail_after_stop
            started = time.monotonic()
            try:
                module._start_publisher(payload, started + 0.25)
            except module.ControllerError:
                pass
            assert time.monotonic() - started < 1.0
            assert len(observed) == 1
            try:
                os.waitpid(observed[0], os.WNOHANG)
            except ChildProcessError:
                pass
            else:
                raise AssertionError("publisher was not reaped")
            """
        )
        self.assert_silent_success(result)

    def test_stopped_reviewer_pidfd_failure_is_bounded_and_reaped(self) -> None:
        result = run_helper(
            """
            observed = []
            def stop_before_gate(*_args):
                signal.raise_signal(signal.SIGSTOP)
                os._exit(98)
            def fail_after_stop(pid):
                observed.append(pid)
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WUNTRACED | os.WNOHANG)
                    if waited == pid and os.WIFSTOPPED(status):
                        raise OSError(errno.EMFILE, "generated stopped pidfd failure")
                    time.sleep(0.005)
                raise AssertionError("generated reviewer did not stop")
            module._reviewer_child = stop_before_gate
            module.os.pidfd_open = fail_after_stop
            started = time.monotonic()
            try:
                module._start_reviewer(
                    Path("/bin/true"),
                    Path("/bin/true"),
                    Path("/generated-sentinel"),
                    0,
                    1,
                    started + 0.25,
                )
            except module.ControllerError:
                pass
            assert time.monotonic() - started < 1.0
            assert len(observed) == 1
            try:
                os.waitpid(observed[0], os.WNOHANG)
            except ChildProcessError:
                pass
            else:
                raise AssertionError("reviewer was not reaped")
            """
        )
        self.assert_silent_success(result)

    def test_pending_cancellation_before_publisher_fork_blocks_output(self) -> None:
        result = run_helper(
            """
            module.preflight = lambda *_args: None
            module.capture_reviewer = lambda *_args: module.CaptureResult(
                payload, True, False, 0, len(payload)
            )
            original_validate = module.validate_hook_output
            def cancel_then_validate(raw):
                signal.raise_signal(signal.SIGTERM)
                return original_validate(raw)
            module.validate_hook_output = cancel_then_validate
            module.run_controller(
                Path("/bin/true"), Path("/bin/true"), Path("/bin/true")
            )
            """
        )
        self.assert_silent_success(result)

    def test_cancellation_during_publisher_ownership_blocks_output(self) -> None:
        result = run_helper(
            """
            module.preflight = lambda *_args: None
            module.capture_reviewer = lambda *_args: module.CaptureResult(
                payload, True, False, 0, len(payload)
            )
            real_pidfd_open = os.pidfd_open
            def cancel_during_ownership(pid):
                pidfd = real_pidfd_open(pid)
                signal.raise_signal(signal.SIGTERM)
                return pidfd
            module.os.pidfd_open = cancel_during_ownership
            module.run_controller(
                Path("/bin/true"), Path("/bin/true"), Path("/bin/true")
            )
            """
        )
        self.assert_silent_success(result)

    def test_cancellation_after_gate_release_may_follow_escaped_output(self) -> None:
        result = run_helper(
            """
            if not hasattr(module, "_write_payload"):
                raise SystemExit(90)
            module.preflight = lambda *_args: None
            module.capture_reviewer = lambda *_args: module.CaptureResult(
                payload, True, False, 0, len(payload)
            )
            def write_then_cancel(_payload):
                os.write(1, b"escaped-after-release")
                pidfd = os.pidfd_open(os.getppid())
                try:
                    signal.pidfd_send_signal(pidfd, signal.SIGTERM)
                finally:
                    os.close(pidfd)
            module._write_payload = write_then_cancel
            module.run_controller(
                Path("/bin/true"), Path("/bin/true"), Path("/bin/true")
            )
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"escaped-after-release")

    def test_post_nul_cancellation_is_transferred_to_main_wake_pipe(self) -> None:
        result = run_helper(
            """
            monitor = module.CancellationMonitor()
            wake_read, wake_write = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
            gate_read, gate_write = module._open_gate()
            previous_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK, module.CANCELLATION_SIGNALS
            )
            previous_handler = signal.signal(signal.SIGTERM, monitor.observe)
            child = module.ExactPublisher(
                os.getpid(), -1, gate_write, previous_mask
            )
            real_write = module.os.write
            def cancel_after_nul(fd, data):
                written = real_write(fd, data)
                if fd == gate_write and data == b"\\0":
                    signal.raise_signal(signal.SIGTERM)
                return written
            module.os.write = cancel_after_nul
            try:
                released = module._release_gate(child, monitor, wake_write)
                try:
                    wake = os.read(wake_read, 1)
                except BlockingIOError:
                    wake = b""
                if not released or not monitor.cancelled or wake == b"":
                    raise SystemExit(91)
            finally:
                module.os.write = real_write
                signal.signal(signal.SIGTERM, previous_handler)
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                module._close(gate_read)
                module._close(wake_read)
                module._close(wake_write)
            """
        )
        self.assert_silent_success(result)

    def test_cancelled_monitor_prevents_selector_wait(self) -> None:
        result = run_helper(
            """
            class NeverSelect:
                def select(self, _timeout):
                    raise SystemExit(92)
            monitor = module.CancellationMonitor(cancelled=True)
            if module._select_unless_cancelled(NeverSelect(), monitor, 70.0) != []:
                raise SystemExit(93)
            """
        )
        self.assert_silent_success(result)

    def test_owned_publisher_is_reaped_after_each_injected_failure(self) -> None:
        injections = {
            "wake-fd": """
                real = module.signal.set_wakeup_fd
                calls = 0
                def fail_once(fd):
                    global calls
                    calls += 1
                    if calls == 1:
                        raise OSError(errno.EIO, "generated wake failure")
                    return real(fd)
                module.signal.set_wakeup_fd = fail_once
            """,
            "mask": """
                real = module._restore_mask
                calls = 0
                def fail_once(mask):
                    global calls
                    calls += 1
                    if calls == 1:
                        raise OSError(errno.EIO, "generated mask failure")
                    return real(mask)
                module._restore_mask = fail_once
            """,
            "selector-create": """
                def fail_selector_after_release():
                    time.sleep(0.1)
                    raise OSError(errno.EMFILE, "generated selector failure")
                module.selectors.DefaultSelector = fail_selector_after_release
            """,
            "selector-register": """
                real_selector = module.selectors.DefaultSelector
                class FailRegister:
                    def __init__(self):
                        self.delegate = real_selector()
                    def register(self, *_args, **_kwargs):
                        raise OSError(errno.EMFILE, "generated register failure")
                    def close(self):
                        self.delegate.close()
                module.selectors.DefaultSelector = FailRegister
            """,
            "pidfd-signal": """
                module._write_payload = lambda _payload: time.sleep(90)
                module.selectors.DefaultSelector = lambda: (_ for _ in ()).throw(
                    OSError(errno.EMFILE, "generated selector failure")
                )
                module.signal.pidfd_send_signal = lambda *_args: (_ for _ in ()).throw(
                    OSError(errno.EIO, "generated pidfd signal failure")
                )
            """,
        }
        for name, injection in injections.items():
            with self.subTest(name=name):
                body = textwrap.dedent(
                    """
                    observed = []
                    real_pidfd_open = module.os.pidfd_open
                    def record_pidfd(pid):
                        fd = real_pidfd_open(pid)
                        observed.append((pid, os.dup(fd)))
                        return fd
                    module.os.pidfd_open = record_pidfd
                    """
                )
                body += textwrap.dedent(injection)
                body += textwrap.dedent(
                    """
                    wake_read, wake_write = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
                    monitor = module.CancellationMonitor()
                    try:
                        module.publish_exact(payload, wake_read, wake_write, monitor)
                    except OSError:
                        pass
                    finally:
                        module._close(wake_read)
                        module._close(wake_write)
                    if len(observed) != 1:
                        raise SystemExit(94)
                    pid, duplicate_pidfd = observed[0]
                    try:
                        ready, _, _ = __import__('select').select(
                            [duplicate_pidfd], [], [], 0
                        )
                        if not ready:
                            raise SystemExit(95)
                        try:
                            os.waitpid(pid, os.WNOHANG)
                        except ChildProcessError:
                            pass
                        else:
                            raise SystemExit(96)
                    finally:
                        os.close(duplicate_pidfd)
                    """
                )
                result = run_helper(body)
                self.assert_silent_success(result)

    def test_dual_signal_failure_uses_fatal_parent_death_path(self) -> None:
        survivor = subprocess.Popen(["/bin/sleep", "5"])
        survivor_pidfd = __import__("os").pidfd_open(survivor.pid)
        try:
            result = run_helper(
                """
                module.PUBLISHER_TIMEOUT_SECONDS = 0.05
                module._write_payload = lambda _payload: time.sleep(90)
                real_start = module._start_publisher
                def record_start(value, deadline=None):
                    child = real_start(value, deadline)
                    print(f"owned-pid={child.pid}", file=sys.stderr, flush=True)
                    return child
                module._start_publisher = record_start
                def fail_signal(*_args):
                    raise module.ExactSignalUnavailable("generated dual failure")
                module.signal_exact_process = fail_signal
                wake_read, wake_write = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
                try:
                    module.publish_exact(
                        payload,
                        wake_read,
                        wake_write,
                        module.CancellationMonitor(),
                    )
                finally:
                    module._close(wake_read)
                    module._close(wake_write)
                """
            )
            self.assertEqual(
                result.returncode,
                125,
                result.stderr.decode(errors="replace"),
            )
            match = re.search(rb"owned-pid=(\d+)", result.stderr)
            self.assertIsNotNone(match, result.stderr.decode(errors="replace"))
            assert match is not None
            owned_pid = int(match.group(1))
            deadline = __import__("time").monotonic() + 1.0
            while (
                Path(f"/proc/{owned_pid}").exists()
                and __import__("time").monotonic() < deadline
            ):
                __import__("time").sleep(0.01)
            self.assertFalse(Path(f"/proc/{owned_pid}").exists())
            ready, _, _ = __import__("select").select([survivor_pidfd], [], [], 0)
            self.assertEqual(ready, [])
        finally:
            __import__("signal").pidfd_send_signal(
                survivor_pidfd,
                __import__("signal").SIGKILL,
            )
            survivor.wait()
            __import__("os").close(survivor_pidfd)

    def test_python_and_libc_signal_failure_is_irrecoverable(self) -> None:
        result = run_helper(
            """
            import ctypes
            def fail_python(*_args):
                raise OSError(errno.EIO, "generated Python failure")
            class FailedLibc:
                @staticmethod
                def pidfd_send_signal(*_args):
                    ctypes.set_errno(errno.EIO)
                    return -1
            module.signal.pidfd_send_signal = fail_python
            module._libc = lambda: FailedLibc()
            child = module.OwnedChild(1, 9, -1, set())
            try:
                module.signal_exact_process(child, signal.SIGKILL)
            except module.ExactSignalUnavailable:
                pass
            else:
                raise SystemExit(98)
            """
        )
        self.assert_silent_success(result)


if __name__ == "__main__":
    unittest.main()
