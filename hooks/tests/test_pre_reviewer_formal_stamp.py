#!/usr/bin/env python3
"""Content-addressed formal executable reuse tests."""

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "hooks/tests/differential/pre-reviewer-controller.sh"
TIMEOUT_PROBE = ROOT / "hooks/tests/probe-pre-reviewer-timeout.sh"
FORMAL_SOURCES = (
    Path("proofs/Spec/PreReviewerController.lean"),
    Path("proofs/Proofs/PreReviewerController.lean"),
    Path("proofs/DiffTest/PreReviewerControllerMain.lean"),
)
DIFFERENTIAL_SOURCES = (
    Path("hooks/edit-bash-pre-reviewer.sh"),
    Path("hooks/lib/edit_bash_pre_reviewer_controller.py"),
    Path("hooks/lib/bounded_hook_input.py"),
    Path("hooks/lib/prune_pre_reviewer_turn_state.py"),
    Path("hooks/lib/reviewer-call.sh"),
    Path("hooks.json"),
    Path("hooks/tests/pre_reviewer_lifecycle.py"),
    Path("hooks/tests/differential/pre-reviewer-controller.sh"),
)


class FormalStampTests(unittest.TestCase):
    def fixture(self, temporary: str) -> tuple[Path, Path, Path, dict[str, str]]:
        root = Path(temporary) / "root"
        script = root / "hooks/tests/differential/pre-reviewer-controller.sh"
        script.parent.mkdir(parents=True)
        shutil.copyfile(VERIFIER, script)
        script.chmod(0o755)
        for relative in FORMAL_SOURCES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        for relative in DIFFERENTIAL_SOURCES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if target != script:
                shutil.copyfile(ROOT / relative, target)
        executable = root / "formal-executable"
        executable.write_bytes(b"generated executable v1\n")
        executable.chmod(0o755)
        stamp = root / "formal-executable.stamp"
        tools = root / "tools"
        tools.mkdir()
        for name in ("lean", "leanc", "unshare"):
            tool = tools / name
            tool.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' 'generated toolchain 1'\n",
                encoding="utf-8",
            )
            tool.chmod(0o755)
        environment = {
            **os.environ,
            "PATH": f"{tools}:/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        return script, executable, stamp, environment

    def timeout_probe_fixture(
        self,
        temporary: str,
    ) -> tuple[Path, Path, Path, Path, Path, dict[str, str]]:
        script, executable, stamp, environment = self.fixture(temporary)
        root = script.parents[3]
        probe = root / "hooks/tests/probe-pre-reviewer-timeout.sh"
        shutil.copyfile(TIMEOUT_PROBE, probe)
        probe.chmod(0o755)

        tools = Path(environment["PATH"].split(":", 1)[0])
        lake_trace = root / "lake.trace"
        lifecycle_trace = root / "lifecycle.trace"
        lake = tools / "lake"
        lake.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >>\"$CODEX_TEST_LAKE_TRACE\"\n"
            "exit 97\n",
            encoding="utf-8",
        )
        lake.chmod(0o755)
        python = tools / "python3"
        python.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "case \"${1:-}\" in\n"
            "  */pre_reviewer_lifecycle.py)\n"
            "    printf '%s\\n' invoked >\"$CODEX_TEST_LIFECYCLE_TRACE\"\n"
            "    artifact_root=\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      if [ \"$1\" = --artifact-root ]; then artifact_root=\"$2\"; break; fi\n"
            "      shift\n"
            "    done\n"
            "    mkdir -p \"$artifact_root/real-timeout\"\n"
            "    printf '%s\\n' '101 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300' >\"$artifact_root/real-timeout/strace\"\n"
            "    printf '%s\\n' '102 pidfd_send_signal(5, SIGTERM, NULL, 0) = 0' >>\"$artifact_root/real-timeout/strace\"\n"
            "    printf '%s\\n' 'real-timeout 0 0 0 1 1 1'\n"
            "    ;;\n"
            "  *) exec /usr/bin/python3 \"$@\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        python.chmod(0o755)
        environment.update(
            {
                "CODEX_PRE_REVIEWER_FORMAL_EXE": str(executable),
                "CODEX_PRE_REVIEWER_FORMAL_STAMP": str(stamp),
                "CODEX_TEST_LAKE_TRACE": str(lake_trace),
                "CODEX_TEST_LIFECYCLE_TRACE": str(lifecycle_trace),
            }
        )
        return probe, script, executable, stamp, lake_trace, environment

    def run_verifier(
        self,
        script: Path,
        environment: dict[str, str],
        *arguments: str,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [str(script), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )

    def test_wrong_executable_and_changed_source_reject_reuse(self) -> None:
        with tempfile.TemporaryDirectory(prefix="formal-stamp-") as temporary:
            script, executable, stamp, environment = self.fixture(temporary)
            written = self.run_verifier(
                script,
                environment,
                "--write-stamp",
                str(executable),
                str(stamp),
            )
            self.assertEqual(written.returncode, 0, written.stderr.decode())
            accepted = self.run_verifier(
                script,
                environment,
                "--verify-artifact",
                str(executable),
                str(stamp),
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr.decode())

            executable.write_bytes(b"generated executable v2\n")
            rejected_executable = self.run_verifier(
                script,
                environment,
                "--verify-artifact",
                str(executable),
                str(stamp),
            )
            self.assertNotEqual(rejected_executable.returncode, 0)

            executable.write_bytes(b"generated executable v1\n")
            (script.parents[3] / FORMAL_SOURCES[0]).write_text(
                "-- generated changed source\n", encoding="utf-8"
            )
            rejected_source = self.run_verifier(
                script,
                environment,
                "--verify-artifact",
                str(executable),
                str(stamp),
            )
            self.assertNotEqual(rejected_source.returncode, 0)

    def test_timeout_probe_reuses_verified_artifact_without_lake(self) -> None:
        with tempfile.TemporaryDirectory(prefix="formal-timeout-probe-") as temporary:
            probe, script, executable, stamp, lake_trace, environment = (
                self.timeout_probe_fixture(temporary)
            )
            lifecycle_trace = Path(environment["CODEX_TEST_LIFECYCLE_TRACE"])
            written = self.run_verifier(
                script, environment, "--write-stamp", str(executable), str(stamp)
            )
            self.assertEqual(written.returncode, 0, written.stderr.decode())

            result = subprocess.run(
                [str(probe)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertTrue(lifecycle_trace.is_file())
            self.assertFalse(lake_trace.exists())

    def test_timeout_probe_rejects_invalid_artifacts_before_lake_or_lifecycle(
        self,
    ) -> None:
        for mutation in ("absent", "wrong-executable", "stale-source"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                prefix="formal-timeout-probe-"
            ) as temporary:
                probe, script, executable, stamp, lake_trace, environment = (
                    self.timeout_probe_fixture(temporary)
                )
                lifecycle_trace = Path(environment["CODEX_TEST_LIFECYCLE_TRACE"])
                written = self.run_verifier(
                    script,
                    environment,
                    "--write-stamp",
                    str(executable),
                    str(stamp),
                )
                self.assertEqual(written.returncode, 0, written.stderr.decode())
                if mutation == "absent":
                    executable.unlink()
                elif mutation == "wrong-executable":
                    executable.write_bytes(b"generated executable v2\n")
                else:
                    source = script.parents[3] / FORMAL_SOURCES[0]
                    source.write_bytes(source.read_bytes() + b"\n-- stale mutation\n")

                result = subprocess.run(
                    [str(probe)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=environment,
                    check=False,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"formal artifact identity", result.stderr)
                self.assertFalse(lifecycle_trace.exists())
                self.assertFalse(lake_trace.exists())

    def test_differential_identity_rejects_controller_and_parser_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="formal-stamp-") as temporary:
            script, executable, _stamp, environment = self.fixture(temporary)
            differential_stamp = executable.with_suffix(".differential")
            written = self.run_verifier(
                script,
                environment,
                "--write-differential-stamp",
                str(executable),
                str(differential_stamp),
            )
            self.assertEqual(written.returncode, 0, written.stderr.decode())
            for relative in DIFFERENTIAL_SOURCES:
                with self.subTest(relative=relative):
                    target = script.parents[3] / relative
                    original = target.read_bytes()
                    target.write_bytes(original + b"\n# generated mutation\n")
                    rejected = self.run_verifier(
                        script,
                        environment,
                        "--verify-differential-stamp",
                        str(executable),
                        str(differential_stamp),
                    )
                    self.assertNotEqual(rejected.returncode, 0)
                    target.write_bytes(original)
            unshare = Path(environment["PATH"].split(":", 1)[0]) / "unshare"
            original_unshare = unshare.read_bytes()
            unshare.write_bytes(original_unshare + b"\n# generated tool mutation\n")
            rejected_tool = self.run_verifier(
                script,
                environment,
                "--verify-differential-stamp",
                str(executable),
                str(differential_stamp),
            )
            self.assertNotEqual(rejected_tool.returncode, 0)

    def test_private_copy_is_verified_before_mutable_source_can_change(self) -> None:
        with tempfile.TemporaryDirectory(prefix="formal-stamp-") as temporary:
            script, executable, stamp, environment = self.fixture(temporary)
            private = executable.with_name("private-executable")
            written = self.run_verifier(
                script, environment, "--write-stamp", str(executable), str(stamp)
            )
            self.assertEqual(written.returncode, 0, written.stderr.decode())
            prepared = self.run_verifier(
                script,
                environment,
                "--prepare-private",
                str(executable),
                str(stamp),
                str(private),
            )
            self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
            executable.write_bytes(b"generated executable v2\n")
            self.assertEqual(private.read_bytes(), b"generated executable v1\n")

    def test_stamp_can_be_bound_to_exact_private_source_copies(self) -> None:
        with tempfile.TemporaryDirectory(prefix="formal-private-sources-") as temporary:
            script, executable, stamp, environment = self.fixture(temporary)
            private_root = Path(temporary) / "private"
            private_sources = []
            for relative in FORMAL_SOURCES:
                target = private_root / relative.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(script.parents[3] / relative, target)
                private_sources.append(target)
            written = self.run_verifier(
                script,
                environment,
                "--write-stamp-with-sources",
                str(executable),
                str(stamp),
                *(str(path) for path in private_sources),
            )
            self.assertEqual(written.returncode, 0, written.stderr.decode())
            (script.parents[3] / FORMAL_SOURCES[0]).write_text(
                "-- generated live-source race\n", encoding="utf-8"
            )
            private_accepted = self.run_verifier(
                script,
                environment,
                "--verify-artifact-with-sources",
                str(executable),
                str(stamp),
                *(str(path) for path in private_sources),
            )
            self.assertEqual(
                private_accepted.returncode,
                0,
                private_accepted.stderr.decode(),
            )
            live_rejected = self.run_verifier(
                script,
                environment,
                "--verify-artifact",
                str(executable),
                str(stamp),
            )
            self.assertNotEqual(live_rejected.returncode, 0)

    def test_production_bound_mutations_are_rejected(self) -> None:
        replacements = (
            (
                Path("hooks/lib/edit_bash_pre_reviewer_controller.py"),
                "OUTPUT_CAP: Final = 4_096",
                "OUTPUT_CAP: Final = 4_095",
            ),
            (
                Path("hooks/lib/bounded_hook_input.py"),
                "INPUT_BUDGET = 65_536",
                "INPUT_BUDGET = 65_535",
            ),
            (
                Path("hooks/lib/prune_pre_reviewer_turn_state.py"),
                "MIN_DIRENT_RECORD_BYTES = 24",
                "MIN_DIRENT_RECORD_BYTES = 25",
            ),
            (
                Path("hooks/lib/reviewer-call.sh"),
                "CODEX_EDIT_PRE_REVIEWER_TIMEOUT:=58",
                "CODEX_EDIT_PRE_REVIEWER_TIMEOUT:=57",
            ),
            (
                Path("hooks/lib/edit_bash_pre_reviewer_controller.py"),
                "CONTROLLER_TIMEOUT_SECONDS: Final = 70.0",
                "CONTROLLER_TIMEOUT_SECONDS: Final = 69.0",
            ),
            (Path("hooks.json"), '"timeout": 75', '"timeout": 74'),
        )
        with tempfile.TemporaryDirectory(prefix="formal-bound-mutations-") as temporary:
            script, _executable, _stamp, environment = self.fixture(temporary)
            checker = Path(temporary) / "bounds-checker"
            checker.write_text(
                "#!/usr/bin/env bash\n"
                "[ \"${1:-}\" = check-bounds ] || exit 2\n"
                "shift\n"
                "[ \"$*\" = \"4096 65536 170 58 70 75\" ] || exit 3\n"
                "printf '%s\\n' bounds-ok\n",
                encoding="utf-8",
            )
            checker.chmod(0o755)
            accepted = self.run_verifier(
                script, environment, "--check-production-bounds", str(checker)
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr.decode())
            for relative, old, new in replacements:
                with self.subTest(relative=relative, old=old):
                    target = script.parents[3] / relative
                    original = target.read_text(encoding="utf-8")
                    self.assertIn(old, original)
                    target.write_text(original.replace(old, new), encoding="utf-8")
                    rejected = self.run_verifier(
                        script,
                        environment,
                        "--check-production-bounds",
                        str(checker),
                    )
                    self.assertNotEqual(rejected.returncode, 0)
                    target.write_text(original, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
