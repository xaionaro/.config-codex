#!/usr/bin/env python3
"""Exact owned-group containment for generated profiler commands."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SUPERVISOR = ROOT / "hooks/tests/process_supervisor.py"

SPEC = importlib.util.spec_from_file_location("process_supervisor_contract", SUPERVISOR)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("process supervisor module cannot be loaded")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

GRANDCHILD_SOURCE = """
import os
from pathlib import Path
import signal
import time

for watched in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched, signal.SIG_IGN)
Path(os.environ["SUPERVISED_GRANDCHILD_PID"]).write_text(
    str(os.getpid()), encoding="ascii"
)
while True:
    time.sleep(60)
"""

LEADER_SOURCE = """
import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

for watched in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched, signal.SIG_IGN)
Path(os.environ["SUPERVISED_LEADER_PID"]).write_text(
    str(os.getpid()), encoding="ascii"
)
control_fd = int(os.environ["SUPERVISOR_CONTROL_FD_NUMBER"])
try:
    os.fstat(control_fd)
except OSError as error:
    if error.errno != errno.EBADF:
        raise
    inherited = False
else:
    inherited = True
Path(os.environ["SUPERVISED_CONTROL_INHERITED"]).write_text(
    json.dumps(inherited), encoding="ascii"
)
subprocess.Popen(
    [sys.executable, "-c", os.environ["SUPERVISED_GRANDCHILD_SOURCE"]],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
grandchild = Path(os.environ["SUPERVISED_GRANDCHILD_PID"])
while not grandchild.is_file():
    time.sleep(0.01)
while True:
    time.sleep(60)
"""


def group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


def wait_for_path(path: Path, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 3.0
    while not path.is_file() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    if not path.is_file():
        raise AssertionError(f"generated path was not published: {path.name}")


class ProcessSupervisorContractTests(unittest.TestCase):
    def _environment(self, root: Path, control_fd: int) -> dict[str, str]:
        return {
            **os.environ,
            "PYTHONDONTWRITEBYTECODE": "1",
            "SUPERVISED_CONTROL_INHERITED": str(root / "control-inherited.json"),
            "SUPERVISED_GRANDCHILD_PID": str(root / "grandchild.pid"),
            "SUPERVISED_GRANDCHILD_SOURCE": GRANDCHILD_SOURCE,
            "SUPERVISED_LEADER_PID": str(root / "leader.pid"),
            "SUPERVISOR_CONTROL_FD_NUMBER": str(control_fd),
        }

    def _start_guard(
        self,
        root: Path,
        *,
        timeout: float,
        parent_pid: int | None = None,
    ) -> tuple[subprocess.Popen[bytes], int]:
        control_read, control_write = os.pipe2(os.O_CLOEXEC)
        command = [
            sys.executable,
            str(SUPERVISOR),
            "guard",
            "--control-fd",
            str(control_read),
            "--parent-pid",
            str(os.getpid() if parent_pid is None else parent_pid),
            "--timeout",
            str(timeout),
            "--cwd",
            str(root),
            "--",
            sys.executable,
            "-c",
            LEADER_SOURCE,
        ]
        guard = subprocess.Popen(
            command,
            env=self._environment(root, control_read),
            pass_fds=(control_read,),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        os.close(control_read)
        return guard, control_write

    def test_timeout_drains_resistant_leader_and_grandchild_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="process-supervisor-timeout-") as tmp:
            root = Path(tmp)
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            guard, control_write = self._start_guard(root, timeout=0.4)
            leader = 0
            try:
                wait_for_path(root / "leader.pid", guard)
                wait_for_path(root / "grandchild.pid", guard)
                leader = int((root / "leader.pid").read_text(encoding="ascii"))
                _stdout, stderr = guard.communicate(timeout=6.0)
                self.assertEqual(guard.returncode, 124, stderr.decode(errors="replace"))
                self.assertFalse(group_exists(leader))
                self.assertIsNone(unrelated.poll())
                self.assertFalse(
                    json.loads((root / "control-inherited.json").read_text())
                )
            finally:
                os.close(control_write)
                if guard.poll() is None:
                    os.killpg(guard.pid, signal.SIGKILL)
                    guard.wait()
                if leader and group_exists(leader):
                    os.killpg(leader, signal.SIGKILL)
                os.killpg(unrelated.pid, signal.SIGKILL)
                unrelated.wait()

    def test_abrupt_parent_death_wakes_guard_and_drains_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="process-supervisor-parent-") as tmp:
            root = Path(tmp)
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            client_pid = os.fork()
            if client_pid == 0:
                guard, control_write = self._start_guard(
                    root,
                    timeout=30.0,
                    parent_pid=os.getpid(),
                )
                (root / "guard.pid").write_text(str(guard.pid), encoding="ascii")
                (root / "control-write.fd").write_text(
                    str(control_write), encoding="ascii"
                )
                signal.pause()
                os._exit(78)

            leader = 0
            guard_pid = 0
            client_waited = False
            try:
                deadline = time.monotonic() + 3.0
                while not (root / "guard.pid").is_file() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "guard.pid").is_file())
                guard_pid = int((root / "guard.pid").read_text(encoding="ascii"))
                dummy = mock.Mock()
                dummy.poll.return_value = None
                wait_for_path(root / "leader.pid", dummy)
                wait_for_path(root / "grandchild.pid", dummy)
                leader = int((root / "leader.pid").read_text(encoding="ascii"))
                os.kill(client_pid, signal.SIGKILL)
                os.waitpid(client_pid, 0)
                client_waited = True
                deadline = time.monotonic() + 6.0
                while group_exists(leader) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(group_exists(leader))
                self.assertIsNone(unrelated.poll())
            finally:
                if not client_waited:
                    try:
                        os.kill(client_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.waitpid(client_pid, 0)
                if guard_pid:
                    try:
                        os.killpg(guard_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if leader and group_exists(leader):
                    os.killpg(leader, signal.SIGKILL)
                os.killpg(unrelated.pid, signal.SIGKILL)
                unrelated.wait()

    def test_owned_group_signals_only_before_reap_and_exactly_once(self) -> None:
        with tempfile.TemporaryDirectory(prefix="process-supervisor-order-") as tmp:
            root = Path(tmp)
            ready = root / "ready"
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import pathlib,signal,time,sys; "
                    "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                    "pathlib.Path(sys.argv[1]).write_text('ready'); "
                    "time.sleep(60)",
                    str(ready),
                ],
                start_new_session=True,
            )
            wait_for_path(ready, process)
            events: list[tuple[str, int | None]] = []
            real_killpg = os.killpg

            def recorded_killpg(group_id: int, signal_number: int) -> None:
                events.append((f"signal:{signal_number}", process.returncode))
                real_killpg(group_id, signal_number)

            owned = MODULE.OwnedProcessGroup.from_process(process)
            with mock.patch.object(MODULE.os, "killpg", side_effect=recorded_killpg):
                owned.drain()
                owned.drain()

            self.assertIsNotNone(process.returncode)
            self.assertTrue(events)
            self.assertTrue(all(returncode is None for _name, returncode in events))
            self.assertFalse(group_exists(process.pid))

    def test_guard_rejects_wrong_parent_and_missing_pidfd_support(self) -> None:
        with tempfile.TemporaryDirectory(prefix="process-supervisor-failclosed-") as tmp:
            root = Path(tmp)
            guard, control_write = self._start_guard(
                root,
                timeout=1.0,
                parent_pid=os.getpid() + 1,
            )
            try:
                _stdout, _stderr = guard.communicate(timeout=2.0)
                self.assertEqual(guard.returncode, 125)
                self.assertFalse((root / "leader.pid").exists())
            finally:
                os.close(control_write)
            with mock.patch.object(MODULE.os, "pidfd_open", None):
                self.assertFalse(MODULE.linux_containment_supported())


if __name__ == "__main__":
    unittest.main()
