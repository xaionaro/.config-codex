#!/usr/bin/env python3
"""Behaviorally reject exact-child controller lifecycle mutations."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "hooks" / "lib" / "edit_bash_pre_reviewer_controller.py"
WRAPPER = ROOT / "hooks" / "edit-bash-pre-reviewer.sh"
LIFECYCLE = ROOT / "hooks" / "tests" / "pre_reviewer_lifecycle.py"
LEAN = ROOT / "proofs" / ".lake" / "build" / "bin" / "preReviewerControllerDiff"


@dataclass(frozen=True)
class Mutation:
    name: str
    old: str
    new: str
    scenario: str
    abrupt_death: bool = False


MUTATIONS = (
    Mutation(
        "remove-streaming-nul-rejection",
        'b"\\0" in chunk or next_count > OUTPUT_CAP',
        "next_count > OUTPUT_CAP",
        "nul-open",
    ),
    Mutation(
        "remove-cap",
        "OUTPUT_CAP: Final = 4_096",
        "OUTPUT_CAP: Final = 16_385",
        "over-cap-valid",
    ),
    Mutation(
        "continue-retaining",
        "if remaining > 0:\n        retained.extend(chunk[:remaining])",
        "retained.extend(chunk)",
        "oversize-open",
    ),
    Mutation(
        "false-close-read",
        'if "selector" in locals():\n            selector.close()\n        _close(read_fd)',
        'if "selector" in locals():\n            selector.close()\n        pass',
        "success",
    ),
    Mutation(
        "false-reviewer-wait",
        "waited_pid, raw_status = os.waitpid(child.pid, 0)",
        "waited_pid, raw_status = child.pid, 0",
        "success",
    ),
    Mutation(
        "remove-supervisor-pdeath",
        "_set_parent_death_signal(expected_parent)\n    if not _gate_child",
        "if not _gate_child",
        "success",
        abrupt_death=True,
    ),
    Mutation(
        "remove-namespace-containment",
        '"--kill-child=KILL",',
        "",
        "success",
        abrupt_death=True,
    ),
)


def run_contained(
    argv: list[str], *, timeout: float = 15.0
) -> subprocess.CompletedProcess[bytes]:
    unshare = shutil.which("unshare")
    if unshare is None:
        raise RuntimeError("unshare is required")
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(
            [
                unshare,
                "--user",
                "--map-root-user",
                "--pid",
                "--fork",
                "--kill-child=KILL",
                *argv,
            ],
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
        )
        pidfd = os.pidfd_open(process.pid)
        try:
            ready, _, _ = select.select([pidfd], [], [], timeout)
            timed_out = not ready
            if timed_out:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            result = os.waitid(os.P_PIDFD, pidfd, os.WEXITED)
            process.returncode = (
                result.si_status
                if result.si_code == os.CLD_EXITED
                else -result.si_status
            )
        finally:
            os.close(pidfd)
        stdout.seek(0)
        stderr.seek(0)
        return subprocess.CompletedProcess(
            argv,
            process.returncode,
            stdout.read(),
            stderr.read() + (b"outer containment timeout\n" if timed_out else b""),
        )


class BehavioralMutationTests(unittest.TestCase):
    def test_unmutated_external_evidence_passes(self) -> None:
        result = run_contained(
            [
                "python3",
                str(LIFECYCLE),
                "--root",
                str(ROOT),
                "--lean",
                str(LEAN),
                "--scenario",
                "success",
                "--skip-lean",
                "--abrupt-death",
            ]
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr.decode())

    def test_each_mutation_is_rejected_inside_outer_containment(self) -> None:
        source = CONTROLLER.read_text(encoding="utf-8")
        wrapper = WRAPPER.read_text(encoding="utf-8")
        for mutation in MUTATIONS:
            with self.subTest(name=mutation.name), tempfile.TemporaryDirectory(
                prefix="pre-reviewer-python-mutant-"
            ) as temporary:
                self.assertIn(mutation.old, source)
                root = Path(temporary)
                hooks = root / "hooks"
                library = hooks / "lib"
                library.mkdir(parents=True)
                (hooks / WRAPPER.name).write_text(wrapper, encoding="utf-8")
                mutant = library / CONTROLLER.name
                mutant.write_text(
                    source.replace(mutation.old, mutation.new, 1),
                    encoding="utf-8",
                )
                arguments = [
                    "python3",
                    str(LIFECYCLE),
                    "--root",
                    str(root),
                    "--lean",
                    str(LEAN),
                    "--scenario",
                    mutation.scenario,
                    "--skip-lean",
                ]
                if mutation.abrupt_death:
                    arguments.append("--abrupt-death")
                result = run_contained(arguments, timeout=12.0)
                self.assertNotEqual(
                    result.returncode,
                    0,
                    msg=(
                        f"mutation survived: {mutation.name}; "
                        f"stdout={result.stdout!r}; stderr={result.stderr!r}"
                    ),
                )

    def test_missing_exact_eof_is_rejected_before_lean_invocation(self) -> None:
        source = LIFECYCLE.read_text(encoding="utf-8")
        old = "events = external_events(trace, controller_pid, output, expected, label)"
        new = (
            old
            + "\n    events = tuple(event for event in events "
            + "if event != 'capture-complete')"
        )
        self.assertIn(old, source)
        with tempfile.TemporaryDirectory(
            prefix="pre-reviewer-premature-complete-"
        ) as temporary:
            root = Path(temporary)
            mutant = root / "premature_complete.py"
            mutant.write_text(source.replace(old, new, 1), encoding="utf-8")
            invoked = root / "lean-invoked"
            lean = root / "fake-lean.sh"
            lean.write_text(
                "#!/usr/bin/env bash\n"
                f": >{str(invoked)!r}\n"
                "printf '%s\\n' '1 1 1 1 1 0'\n",
                encoding="utf-8",
            )
            lean.chmod(0o755)

            result = run_contained(
                [
                    "python3",
                    str(mutant),
                    "--root",
                    str(ROOT),
                    "--lean",
                    str(lean),
                    "--scenario",
                    "success",
                ],
                timeout=12.0,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(invoked.exists(), "Lean ran before EOF evidence rejection")


if __name__ == "__main__":
    unittest.main()
