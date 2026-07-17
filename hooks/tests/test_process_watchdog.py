#!/usr/bin/env python3
"""Owned-process-group lifecycle tests for the synthetic process watchdog."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
WATCHDOG = ROOT / "hooks/tests/process-watchdog.py"

DESCENDANT_SOURCE = """
import os
from pathlib import Path
import signal
import time

def observed(signal_number, _frame):
    with Path(os.environ["WATCHDOG_SIGNAL_LOG"]).open("a", encoding="ascii") as stream:
        stream.write(f"{signal_number}\\n")

for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched_signal, observed)
Path(os.environ["WATCHDOG_DESCENDANT_PID"]).write_text(
    str(os.getpid()), encoding="ascii"
)
while True:
    time.sleep(60)
"""

LEADER_SOURCE = """
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

Path(os.environ["WATCHDOG_LEADER_PID"]).write_text(
    str(os.getpid()), encoding="ascii"
)
subprocess.Popen(
    [sys.executable, "-c", os.environ["WATCHDOG_DESCENDANT_SOURCE"]],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
descendant = Path(os.environ["WATCHDOG_DESCENDANT_PID"])
while not descendant.is_file():
    time.sleep(0.01)
if sys.argv[1] == "running":
    while True:
        signal.pause()
"""


def group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


class ProcessWatchdogOwnershipTests(unittest.TestCase):
    def _run_case(self, mode: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            leader_pid_path = root / "leader.pid"
            descendant_pid_path = root / "descendant.pid"
            signal_log = root / "descendant-signals"
            environment = {
                **os.environ,
                "WATCHDOG_DESCENDANT_PID": str(descendant_pid_path),
                "WATCHDOG_DESCENDANT_SOURCE": DESCENDANT_SOURCE,
                "WATCHDOG_LEADER_PID": str(leader_pid_path),
                "WATCHDOG_SIGNAL_LOG": str(signal_log),
            }
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            watchdog = subprocess.Popen(
                [
                    sys.executable,
                    str(WATCHDOG),
                    "--timeout",
                    "30",
                    "--log",
                    str(root / "watchdog.log"),
                    "--cwd",
                    str(root),
                    "--",
                    sys.executable,
                    "-c",
                    LEADER_SOURCE,
                    mode,
                ],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            leader_pid = 0
            owned_group_alive = False
            try:
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    if leader_pid_path.is_file() and descendant_pid_path.is_file():
                        break
                    if watchdog.poll() is not None:
                        break
                    time.sleep(0.02)
                self.assertTrue(leader_pid_path.is_file())
                self.assertTrue(descendant_pid_path.is_file())
                leader_pid = int(leader_pid_path.read_text(encoding="ascii"))
                owned_group_alive = True

                if mode == "running":
                    os.kill(watchdog.pid, signal.SIGTERM)
                _stdout, stderr = watchdog.communicate(timeout=6.0)
                expected_status = 143 if mode == "running" else 0
                self.assertEqual(
                    watchdog.returncode,
                    expected_status,
                    stderr.decode(errors="replace"),
                )

                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    if not group_exists(leader_pid):
                        owned_group_alive = False
                        break
                    time.sleep(0.02)
                self.assertFalse(
                    owned_group_alive,
                    "watchdog left its exact owned process group alive",
                )
                self.assertIsNone(unrelated.poll())
                self.assertEqual(
                    signal_log.read_text(encoding="ascii").splitlines(),
                    [str(signal.SIGTERM.value)],
                )
            finally:
                if watchdog.poll() is None:
                    os.kill(watchdog.pid, signal.SIGKILL)
                    watchdog.wait()
                if owned_group_alive and leader_pid:
                    try:
                        os.killpg(leader_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(unrelated.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                unrelated.wait()

    def test_normal_leader_exit_drains_owned_descendant_only(self) -> None:
        self._run_case("exit")

    def test_watchdog_interruption_drains_owned_descendant_only(self) -> None:
        self._run_case("running")


if __name__ == "__main__":
    unittest.main()
