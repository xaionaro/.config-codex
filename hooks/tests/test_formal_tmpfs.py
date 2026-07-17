#!/usr/bin/env python3
"""Focused setup tests for the lifecycle differential's owned tmpfs scratch."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "hooks/tests/lib/formal-tmpfs.sh"
RUNNER = ROOT / "hooks/tests/run.sh"
PROFILER = ROOT / "hooks/tests/profile_pre_reviewer_ab.py"


class FormalTmpfsTests(unittest.TestCase):
    def select(self, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                '. "$1"; codex_select_formal_tmpfs_scratch',
                "bash",
                str(HELPER),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            check=False,
        )

    def test_inherited_non_tmpfs_tmpdir_cannot_change_selected_scratch(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="formal-inherited-ext4-", dir=str(ROOT)
        ) as inherited:
            result = self.select({**os.environ, "TMPDIR": inherited})
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = Path(result.stdout.strip())
        try:
            self.assertTrue(selected.is_dir())
            filesystem = subprocess.run(
                ["/usr/bin/findmnt", "-n", "-o", "FSTYPE", "--target", str(selected)],
                stdout=subprocess.PIPE,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertEqual(filesystem, "tmpfs")
            self.assertTrue(str(selected).startswith("/tmp/"))
        finally:
            subprocess.run(["rm", "-rf", "--", str(selected)], check=False)

    def test_explicit_non_tmpfs_base_fails_as_setup(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="formal-explicit-ext4-", dir=str(ROOT)
        ) as explicit:
            result = self.select(
                {**os.environ, "CODEX_TEST_FORMAL_TMPFS_BASE": explicit}
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_runner_binds_owned_formal_tmpdir_before_case_accounting(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        setup = source.index("codex_select_formal_tmpfs_scratch")
        accounting = source.index("PASS_COUNT=0")
        lifecycle = source.index("test_pre_reviewer_controller_matches_lean_lifecycle")
        self.assertLess(setup, accounting)
        self.assertIn(
            'CODEX_TEST_SKIP_LEAN_BUILD=1 \\\n    "$verifier" --artifact-root "$evidence"',
            source[lifecycle:],
        )

    def test_formal_artifacts_are_setup_before_dependent_cases(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        profiler = PROFILER.read_text(encoding="utf-8")
        first_case = source.index('run_case "')
        controller_setup = source.index(
            '"$ROOT/hooks/tests/profile-pre-reviewer.sh"'
        )
        prune_setup = source.index("prune-build.log")
        self.assertLess(controller_setup, first_case)
        self.assertLess(prune_setup, first_case)
        self.assertIn(
            "CODEX_PRE_REVIEWER_FORMAL_EXE", source[controller_setup:first_case]
        )
        self.assertIn("CODEX_PRUNE_FORMAL_EXE", source[prune_setup:first_case])
        self.assertIn("logs/pre-reviewer-profile.log", profiler)
        self.assertNotIn("ln -s \"$(type -P true)\"", source)

    def test_persistent_formal_storage_rejects_tmpfs(self) -> None:
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                '. "$1"; codex_select_formal_persistent_storage',
                "bash",
                str(HELPER),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "CODEX_TEST_FORMAL_PERSISTENT_BASE": "/tmp"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_inherited_tmpdir_cannot_change_bound_lifecycle_result(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="formal-lifecycle-ext4-", dir=str(ROOT)
        ) as inherited, tempfile.TemporaryDirectory(
            prefix="formal-lifecycle-verifier-"
        ) as temporary:
            verifier = Path(temporary) / "verifier.sh"
            verifier.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                '[ "$(/usr/bin/findmnt -n -o FSTYPE --target "$TMPDIR")" = tmpfs ]\n'
                "printf '%s\\n' lifecycle-ok\n",
                encoding="utf-8",
            )
            verifier.chmod(0o755)
            outputs = []
            for inherited_tmpdir in (inherited, "/tmp"):
                selected_result = self.select(
                    {**os.environ, "TMPDIR": inherited_tmpdir}
                )
                self.assertEqual(selected_result.returncode, 0, selected_result.stderr)
                selected = Path(selected_result.stdout.strip())
                try:
                    result = subprocess.run(
                        [
                            "/bin/bash",
                            "-c",
                            '. "$1"; codex_run_formal_lifecycle_differential "$2" "$3"',
                            "bash",
                            str(HELPER),
                            str(selected),
                            str(verifier),
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env={**os.environ, "TMPDIR": inherited_tmpdir},
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    outputs.append(result.stdout)
                finally:
                    subprocess.run(["rm", "-rf", "--", str(selected)], check=False)
        self.assertEqual(outputs, ["lifecycle-ok\n", "lifecycle-ok\n"])


if __name__ == "__main__":
    unittest.main()
