#!/usr/bin/env python3
"""Fail-closed contracts for the single-build pre-reviewer profiler."""

from __future__ import annotations

from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import shlex
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PROFILER = ROOT / "hooks/tests/profile_pre_reviewer_ab.py"
SPEC = importlib.util.spec_from_file_location("pre_reviewer_profile_contract", PROFILER)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def make_executable(path: Path, body: bytes = b"#!/bin/sh\nexit 0\n") -> Path:
    path.write_bytes(body)
    path.chmod(0o700)
    return path.resolve()


def trace_line(path: Path, *arguments: str, status: int = 0) -> str:
    argv = ", ".join(json.dumps(value) for value in (str(path), *arguments))
    return f'1 execve({json.dumps(str(path))}, [{argv}], 0x0) = {status}\n'


class SummaryContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.commit = "a" * 40
        self.summary = {
            "candidate_commit": self.commit,
            "controller_build_count": 1,
            "fresh_trace_execve_successes": 3,
            "report_schema_version": 1,
            "reuse_trace_execve_successes": 2,
        }

    def test_accepts_only_exact_summary_schema(self) -> None:
        self.assertEqual(
            MODULE.validate_profile_summary(self.summary, self.commit),
            self.summary,
        )

    def test_rejects_extra_missing_bool_bad_commit_and_bad_counts(self) -> None:
        mutations = []
        extra = dict(self.summary, extra=True)
        missing = dict(self.summary)
        del missing["candidate_commit"]
        boolean = dict(self.summary, controller_build_count=True)
        bad_commit = dict(self.summary, candidate_commit="HEAD")
        no_build = dict(self.summary, controller_build_count=0)
        too_many_builds = dict(self.summary, controller_build_count=2)
        no_fresh = dict(self.summary, fresh_trace_execve_successes=0)
        no_reuse = dict(self.summary, reuse_trace_execve_successes=0)
        mutations.extend(
            (extra, missing, boolean, bad_commit, no_build, too_many_builds,
             no_fresh, no_reuse)
        )
        for value in mutations:
            with self.subTest(value=value), self.assertRaises(MODULE.ProfileError):
                MODULE.validate_profile_summary(value, self.commit)

    def test_rejects_report_substitution_and_head_mismatch(self) -> None:
        report = b"generated report\n"
        digest = hashlib.sha256(report).hexdigest()
        MODULE.validate_report_binding(
            report,
            digest,
            self.summary,
            expected_commit=self.commit,
        )
        with self.assertRaises(MODULE.ProfileError):
            MODULE.validate_report_binding(
                report + b"substitution",
                digest,
                self.summary,
                expected_commit=self.commit,
            )
        with self.assertRaises(MODULE.ProfileError):
            MODULE.validate_report_binding(
                report,
                digest,
                self.summary,
                expected_commit="b" * 40,
            )


class TracePublicationContractTests(unittest.TestCase):
    def _formal_oracle(
        self,
        output: Path,
        body: bytes | None = None,
    ) -> tuple[Path, Path]:
        invocation = output / "logs/formal-profile-evidence.args"
        invocation.parent.mkdir(parents=True, exist_ok=True)
        executable = output / "artifacts/pre-reviewer/preReviewerControllerDiff"
        executable.parent.mkdir(parents=True, exist_ok=True)
        if body is None:
            body = (
                b"#!/usr/bin/env bash\n"
                + f"printf '%s\\n' \"$@\" >{shlex.quote(str(invocation))}\n".encode()
                + b"printf '%s\\n' profile-evidence-ok\n"
            )
        executable = make_executable(executable, body)
        stamp = executable.with_suffix(".stamp")
        stamp.write_text("generated verified stamp\n", encoding="utf-8")
        stamp.chmod(0o600)
        return executable, invocation

    def _bound_output(self, base: Path) -> tuple[Path, dict[str, object], Path]:
        output = base / "output"
        trace_root = output / "evidence/traces"
        trace_root.mkdir(parents=True, mode=0o700)
        output.chmod(0o700)
        lean = make_executable(base / "lean")
        bash = make_executable(base / "bash")
        fresh = trace_root / "fresh.strace"
        reuse = trace_root / "reuse.strace"
        fresh.write_text(
            trace_line(lean, "PreReviewerController.lean"),
            encoding="utf-8",
        )
        reuse.write_text(trace_line(bash), encoding="utf-8")
        fresh.chmod(0o600)
        reuse.chmod(0o600)
        binding = {
            "fresh_path": "evidence/traces/fresh.strace",
            "fresh_sha256": hashlib.sha256(fresh.read_bytes()).hexdigest(),
            "reuse_path": "evidence/traces/reuse.strace",
            "reuse_sha256": hashlib.sha256(reuse.read_bytes()).hexdigest(),
            "trace_binding_schema_version": 1,
        }
        report = output / "evidence/pre-reviewer-profile.out"
        report.write_text(
            "profile-trace-binding "
            + json.dumps(binding, sort_keys=True, separators=(",", ":"))
            + "\nprofile-summary "
            + json.dumps(
                {
                    "candidate_commit": "a" * 40,
                    "controller_build_count": 1,
                    "fresh_trace_execve_successes": 1,
                    "report_schema_version": 1,
                    "reuse_trace_execve_successes": 1,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        report.chmod(0o600)
        self._formal_oracle(output)
        return output, binding, report

    def test_publishes_real_traces_to_fixed_private_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            source.mkdir(mode=0o700)
            fresh_source = source / "fresh.strace"
            reuse_source = source / "reuse.strace"
            fresh_source.write_bytes(b"fresh-real-trace\n")
            reuse_source.write_bytes(b"reuse-real-trace\n")
            output = base / "output"
            (output / "evidence").mkdir(parents=True, mode=0o700)
            output.chmod(0o700)

            with mock.patch.object(
                MODULE.os,
                "fsync",
                wraps=os.fsync,
            ) as fsync:
                binding = MODULE.publish_phase_traces(
                    fresh_source,
                    reuse_source,
                    output,
                )

            self.assertEqual(set(binding), MODULE.PROFILE_TRACE_BINDING_KEYS)
            self.assertGreaterEqual(fsync.call_count, 5)
            MODULE.validate_profile_trace_binding(binding, output)
            self.assertEqual(
                (output / binding["fresh_path"]).read_bytes(),
                fresh_source.read_bytes(),
            )
            self.assertEqual(
                (output / binding["reuse_path"]).read_bytes(),
                reuse_source.read_bytes(),
            )
            self.assertEqual(
                (output / binding["fresh_path"]).stat().st_mode & 0o777,
                0o600,
            )

    def test_rejects_trace_substitution_swap_alias_and_delete(self) -> None:
        mutations = ("substitution", "swap", "symlink", "hardlink", "delete")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                output, binding, _report = self._bound_output(Path(tmp))
                fresh = output / "evidence/traces/fresh.strace"
                reuse = output / "evidence/traces/reuse.strace"
                if mutation == "substitution":
                    fresh.write_bytes(b"substituted\n")
                elif mutation == "swap":
                    fresh_bytes = fresh.read_bytes()
                    fresh.write_bytes(reuse.read_bytes())
                    reuse.write_bytes(fresh_bytes)
                elif mutation == "symlink":
                    reuse.unlink()
                    reuse.symlink_to(fresh)
                elif mutation == "hardlink":
                    reuse.unlink()
                    os.link(fresh, reuse)
                else:
                    reuse.unlink()
                with self.assertRaises(MODULE.ProfileError):
                    MODULE.validate_profile_trace_binding(binding, output)

    def test_persisted_report_binds_trace_record_and_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output, _binding, report = self._bound_output(Path(temporary))
            invocation = output / "logs/formal-profile-evidence.args"
            digest = MODULE.validate_persisted_profile(
                report,
                output,
                "a" * 40,
            )
            self.assertEqual(digest, hashlib.sha256(report.read_bytes()).hexdigest())
            self.assertEqual(
                invocation.read_text(encoding="utf-8").splitlines(),
                ["check-profile-evidence", "1", "1", "1", "1", "0"],
            )
            MODULE.validate_persisted_profile(
                report,
                output,
                "a" * 40,
                expected_sha256=digest,
            )
            (output / "evidence/traces/reuse.strace").write_bytes(b"changed\n")
            invocation.unlink()
            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_persisted_profile(
                    report,
                    output,
                    "a" * 40,
                    expected_sha256=digest,
                )
            self.assertFalse(invocation.exists())

    def test_formal_profile_oracle_rejects_nonzero_and_malformed_results(self) -> None:
        variants = (
            b"#!/usr/bin/env bash\nexit 7\n",
            b"#!/usr/bin/env bash\nprintf '%s\\n' wrong-result\n",
            (
                b"#!/usr/bin/env bash\n"
                b"printf '%s\\n' profile-evidence-ok\n"
                b"printf '%s\\n' unexpected-stderr >&2\n"
            ),
        )
        for body in variants:
            with self.subTest(body=body), tempfile.TemporaryDirectory() as temporary:
                output, _binding, report = self._bound_output(Path(temporary))
                self._formal_oracle(output, body)

                with self.assertRaises(MODULE.ProfileError):
                    MODULE.validate_persisted_profile(report, output, "a" * 40)

    def test_formal_profile_oracle_timeout_drains_only_its_owned_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output, _binding, report = self._bound_output(Path(temporary))
            leader_pid = output / "logs/formal-profile-evidence.pid"
            descendant_pid = output / "logs/formal-profile-evidence-child.pid"
            descendant_source = (
                "import os, signal, time\n"
                "from pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                f"Path({str(descendant_pid)!r}).write_text(str(os.getpid()))\n"
                "time.sleep(60)\n"
            )
            self._formal_oracle(
                output,
                (
                    "#!/usr/bin/env python3\n"
                    "import os\n"
                    "from pathlib import Path\n"
                    "import signal\n"
                    "import subprocess\n"
                    "import sys\n"
                    "import time\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    f"Path({str(leader_pid)!r}).write_text(str(os.getpid()))\n"
                    f"subprocess.Popen([sys.executable, '-c', {descendant_source!r}])\n"
                    f"while not Path({str(descendant_pid)!r}).is_file(): time.sleep(0.01)\n"
                    "time.sleep(60)\n"
                ).encode(),
            )
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            try:
                with mock.patch.object(
                    MODULE,
                    "FORMAL_PROFILE_EVIDENCE_TIMEOUT_SECONDS",
                    1.0,
                ), self.assertRaisesRegex(MODULE.ProfileError, "timed out"):
                    MODULE.validate_persisted_profile(report, output, "a" * 40)
                self.assertTrue(leader_pid.is_file())
                self.assertTrue(descendant_pid.is_file())
                with self.assertRaises(ProcessLookupError):
                    os.killpg(int(leader_pid.read_text(encoding="ascii")), 0)
                self.assertIsNone(unrelated.poll())
            finally:
                if unrelated.poll() is None:
                    os.killpg(unrelated.pid, signal.SIGKILL)
                    unrelated.wait()

    def test_formal_invocation_is_bound_to_original_published_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            output, binding, report = self._bound_output(base)
            invocation = output / "logs/formal-profile-evidence.args"
            phase_evidence = MODULE.validate_phase_traces(
                output / MODULE.FRESH_TRACE_RELATIVE_PATH,
                output / MODULE.REUSE_TRACE_RELATIVE_PATH,
            )
            published = MODULE.PublishedPhaseTraceEvidence(
                fresh_sha256=str(binding["fresh_sha256"]),
                reuse_sha256=str(binding["reuse_sha256"]),
                phase_evidence=phase_evidence,
            )
            MODULE.validate_persisted_profile(
                report,
                output,
                "a" * 40,
                expected_published=published,
            )
            self.assertTrue(invocation.is_file())
            invocation.unlink()

            fresh = output / MODULE.FRESH_TRACE_RELATIVE_PATH
            fresh.write_text(
                fresh.read_text(encoding="utf-8")
                + trace_line(make_executable(base / "additional-fresh")),
                encoding="utf-8",
            )
            rebound = MODULE.profile_trace_binding(output)
            summary = MODULE._single_report_record(
                report.read_text(encoding="utf-8"),
                "profile-summary ",
            )
            summary["fresh_trace_execve_successes"] = 2
            report.write_text(
                "profile-trace-binding "
                + json.dumps(rebound, sort_keys=True, separators=(",", ":"))
                + "\nprofile-summary "
                + json.dumps(summary, sort_keys=True, separators=(",", ":"))
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.ProfileError,
                "original published evidence",
            ):
                MODULE.validate_persisted_profile(
                    report,
                    output,
                    "a" * 40,
                    expected_published=published,
                )
            self.assertFalse(invocation.exists())

    def test_persisted_report_rejects_rebound_semantic_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output, _binding, report = self._bound_output(Path(temporary))
            invocation = output / "logs/formal-profile-evidence.args"
            fresh = output / MODULE.FRESH_TRACE_RELATIVE_PATH
            fresh.write_text(
                trace_line(make_executable(Path(temporary) / "substituted")),
                encoding="utf-8",
            )
            rebound = MODULE.profile_trace_binding(output)
            report.write_text(
                "profile-trace-binding "
                + json.dumps(rebound, sort_keys=True, separators=(",", ":"))
                + "\nprofile-summary "
                + json.dumps(
                    {
                        "candidate_commit": "a" * 40,
                        "controller_build_count": 1,
                        "fresh_trace_execve_successes": 1,
                        "report_schema_version": 1,
                        "reuse_trace_execve_successes": 1,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_persisted_profile(report, output, "a" * 40)
            self.assertFalse(invocation.exists())

    def test_persisted_report_counts_come_from_published_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output, _binding, report = self._bound_output(Path(temporary))
            invocation = output / "logs/formal-profile-evidence.args"
            text = report.read_text(encoding="utf-8")
            summary = MODULE._single_report_record(text, "profile-summary ")
            summary["fresh_trace_execve_successes"] = 99
            report.write_text(
                "profile-trace-binding "
                + json.dumps(
                    MODULE._single_report_record(text, "profile-trace-binding "),
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\nprofile-summary "
                + json.dumps(summary, sort_keys=True, separators=(",", ":"))
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_persisted_profile(report, output, "a" * 40)
            self.assertFalse(invocation.exists())

    def test_original_publication_binding_is_retained_until_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            source.mkdir()
            fresh = source / "fresh.strace"
            reuse = source / "reuse.strace"
            lean = make_executable(base / "lean")
            bash = make_executable(base / "bash")
            fresh.write_text(
                trace_line(lean, "PreReviewerController.lean"),
                encoding="utf-8",
            )
            reuse.write_text(trace_line(bash), encoding="utf-8")
            output = base / "output"
            (output / "evidence").mkdir(parents=True)
            output.chmod(0o700)

            published = MODULE.publish_phase_trace_evidence(fresh, reuse, output)
            MODULE.validate_published_phase_trace_evidence(published, output)
            (output / MODULE.FRESH_TRACE_RELATIVE_PATH).write_text(
                trace_line(bash),
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_published_phase_trace_evidence(published, output)

    def test_report_publication_rejects_mutation_after_summary_validation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repository = base / "repository"
            formal = base / "formal"
            output = base / "output"
            repository.mkdir()
            formal.mkdir(mode=0o700)
            output.mkdir(mode=0o700)
            persisted_fresh: Path | None = None
            bash: Path | None = None

            def publish(*_args: object, **_kwargs: object) -> object:
                nonlocal persisted_fresh, bash
                sources = formal / "sources"
                sources.mkdir()
                fresh = sources / "fresh.strace"
                reuse = sources / "reuse.strace"
                lean = make_executable(base / "lean")
                bash = make_executable(base / "bash")
                fresh.write_text(
                    trace_line(lean, "PreReviewerController.lean"),
                    encoding="utf-8",
                )
                reuse.write_text(trace_line(bash), encoding="utf-8")
                published = MODULE.publish_phase_trace_evidence(
                    fresh,
                    reuse,
                    output,
                )
                persisted_fresh = output / MODULE.FRESH_TRACE_RELATIVE_PATH
                return published

            def mutate_after_summary_observation(_path: Path) -> int:
                assert persisted_fresh is not None and bash is not None
                persisted_fresh.write_text(trace_line(bash), encoding="utf-8")
                return 1

            with mock.patch.object(
                MODULE,
                "validate_profile_roots",
            ), mock.patch.object(
                MODULE,
                "validate_profile_destinations",
            ), mock.patch.object(
                MODULE,
                "export_candidate",
                return_value=SimpleNamespace(commit="a" * 40),
            ), mock.patch.object(
                MODULE,
                "_run_profile",
                side_effect=publish,
            ), mock.patch.object(
                MODULE,
                "controller_build_count",
                side_effect=mutate_after_summary_observation,
            ):
                with redirect_stderr(io.StringIO()), self.assertRaises(
                    MODULE.ProfileError
                ):
                    MODULE._main(
                        [
                            "profile",
                            str(repository),
                            "--formal-tmp-root",
                            str(formal),
                            "--output-root",
                            str(output),
                        ]
                    )

            self.assertFalse(
                (output / "evidence/pre-reviewer-profile.out").exists()
            )

    def test_publication_rejects_preexisting_or_linked_destination(self) -> None:
        for linked in (False, True):
            with self.subTest(linked=linked), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                source = base / "source"
                source.mkdir()
                fresh = source / "fresh"
                reuse = source / "reuse"
                fresh.write_bytes(b"fresh")
                reuse.write_bytes(b"reuse")
                output = base / "output"
                evidence = output / "evidence"
                evidence.mkdir(parents=True)
                output.chmod(0o700)
                if linked:
                    outside = base / "outside"
                    outside.mkdir()
                    (evidence / "traces").symlink_to(outside, target_is_directory=True)
                else:
                    (evidence / "traces").mkdir()
                with self.assertRaises(MODULE.ProfileError):
                    MODULE.publish_phase_traces(fresh, reuse, output)

    def test_publication_failure_preserves_completed_trace_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            source.mkdir()
            fresh = source / "fresh"
            fresh.write_bytes(b"fresh-preserved")
            reuse_target = source / "reuse-target"
            reuse_target.write_bytes(b"reuse")
            reuse = source / "reuse"
            reuse.symlink_to(reuse_target)
            output = base / "output"
            (output / "evidence").mkdir(parents=True)
            output.chmod(0o700)

            with self.assertRaises(MODULE.ProfileError):
                MODULE.publish_phase_traces(fresh, reuse, output)

            self.assertEqual(
                (output / "evidence/traces/fresh.strace").read_bytes(),
                b"fresh-preserved",
            )


class RootContractTests(unittest.TestCase):
    def test_roots_must_be_distinct_absolute_private_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first = base / "first"
            second = base / "second"
            first.mkdir(mode=0o700)
            second.mkdir(mode=0o700)
            with mock.patch.object(
                MODULE, "_filesystem_type", side_effect=("tmpfs", "ext4")
            ):
                MODULE.validate_profile_roots(first, second)
            for roots in (
                (Path("relative"), second),
                (first, Path("relative")),
                (first, first),
            ):
                with self.subTest(roots=roots), self.assertRaises(MODULE.ProfileError):
                    MODULE.validate_profile_roots(*roots)
            second.chmod(0o755)
            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_profile_roots(first, second)

    def test_roots_require_tmpfs_formal_and_persistent_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first = base / "first"
            second = base / "second"
            first.mkdir(mode=0o700)
            second.mkdir(mode=0o700)
            for filesystems in (("ext4", "ext4"), ("tmpfs", "tmpfs")):
                with self.subTest(filesystems=filesystems), mock.patch.object(
                    MODULE, "_filesystem_type", side_effect=filesystems
                ), self.assertRaises(MODULE.ProfileError):
                    MODULE.validate_profile_roots(first, second)

    def test_roots_reject_symlinks_and_preexisting_destinations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first = base / "first"
            second = base / "second"
            first.mkdir(mode=0o700)
            second.mkdir(mode=0o700)
            alias = base / "alias"
            alias.symlink_to(first, target_is_directory=True)
            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_profile_roots(alias, second)
            destination = second / "evidence/pre-reviewer-profile.out"
            destination.parent.mkdir()
            destination.write_text("preexisting", encoding="utf-8")
            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_profile_destinations(second)
            destination.unlink()
            destination.parent.rmdir()
            outside = base / "outside"
            outside.mkdir()
            (second / "evidence").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(MODULE.ProfileError):
                MODULE.validate_profile_destinations(second)


class TraceContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.lean = make_executable(self.root / "lean")
        self.leanc = make_executable(self.root / "leanc")
        self.bash = make_executable(self.root / "bash")
        self.jq = make_executable(self.root / "jq")
        self.fresh = self.root / "fresh.strace"
        self.reuse = self.root / "reuse.strace"
        self.fresh.write_text(
            trace_line(self.bash)
            + trace_line(self.lean, "-o", "Proofs/PreReviewerController.olean",
                         "Proofs/PreReviewerController.lean")
            + trace_line(self.leanc, "-o", "preReviewerControllerDiff"),
            encoding="utf-8",
        )
        self.reuse.write_text(
            trace_line(self.bash) + trace_line(self.jq), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_fixed_distinct_traces_prove_fresh_compile_and_reuse_no_compile(self) -> None:
        evidence = MODULE.validate_phase_traces(self.fresh, self.reuse)
        self.assertEqual(evidence.fresh_execve_successes, 3)
        self.assertEqual(evidence.reuse_execve_successes, 2)
        self.assertTrue(evidence.fresh_controller_compilation)
        self.assertFalse(evidence.reuse_controller_compilation)
        self.assertIn(self.lean, evidence.fresh_paths)
        self.assertNotIn(self.lean, evidence.reuse_paths)

    def test_missing_swapped_and_aliased_traces_fail(self) -> None:
        missing = self.root / "missing.strace"
        alias = self.root / "alias.strace"
        alias.symlink_to(self.fresh)
        for fresh, reuse in (
            (missing, self.reuse),
            (self.reuse, self.fresh),
            (self.fresh, alias),
        ):
            with self.subTest(fresh=fresh, reuse=reuse), self.assertRaises(
                MODULE.ProfileError
            ):
                MODULE.validate_phase_traces(fresh, reuse)

    def test_only_successful_execve_records_count(self) -> None:
        self.reuse.write_text(
            trace_line(self.bash, status=-1) + trace_line(self.jq), encoding="utf-8"
        )
        self.assertEqual(MODULE.successful_execve_paths(self.reuse), (self.jq,))

    def test_distinct_injected_executables_reach_closure_validator(self) -> None:
        generated_fresh = make_executable(self.root / "generated-fresh")
        generated_reuse = make_executable(self.root / "generated-reuse")
        self.fresh.write_text(
            self.fresh.read_text() + trace_line(generated_fresh), encoding="utf-8"
        )
        self.reuse.write_text(
            self.reuse.read_text() + trace_line(generated_reuse), encoding="utf-8"
        )
        evidence = MODULE.validate_phase_traces(self.fresh, self.reuse)
        definition = {
            "product_tools": [],
            "harness_tools": ["bash", "lean", "leanc", "jq"],
            "optional_harness_tools": [],
        }
        with self.assertRaisesRegex(MODULE.ProfileError, "generated-fresh"):
            MODULE.verify_tool_manifest_closure(
                definition,
                observed_product=set(),
                observed_harness={path.name for path in evidence.all_paths},
            )

    def test_product_trace_excludes_sources_under_canonical_code_root(self) -> None:
        code_root = self.root / "code"
        code_root.mkdir()
        configured = make_executable(code_root / "configured-hook.sh")
        alias = self.root / "code-alias"
        alias.symlink_to(code_root, target_is_directory=True)
        trace_root = self.root / "product-traces"
        trace_root.mkdir()
        (trace_root / "configured.strace").write_text(
            trace_line(configured), encoding="utf-8"
        )
        self.assertEqual(
            MODULE.discover_observed_runtime_tools(trace_root, alias), set()
        )


class ToolIdentityContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bash = make_executable(self.root / "bash")
        self.elan = make_executable(self.root / "elan")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_direct_toolchain_does_not_require_unobserved_elan(self) -> None:
        with mock.patch.object(MODULE.shutil, "which") as which:
            which.side_effect = lambda name: str(self.bash) if name == "bash" else None
            entries = MODULE.tool_entries(
                ["bash"], ["elan"], {"bash": self.bash}
            )
        self.assertEqual([entry["name"] for entry in entries], ["bash"])

    def test_unrelated_elan_is_omitted_when_trace_did_not_observe_it(self) -> None:
        with mock.patch.object(MODULE.shutil, "which") as which:
            which.side_effect = lambda name: str(
                self.elan if name == "elan" else self.bash
            )
            entries = MODULE.tool_entries(
                ["bash"], ["elan"], {"bash": self.bash}
            )
        self.assertEqual([entry["name"] for entry in entries], ["bash"])

    def test_observed_elan_binds_exact_trace_path(self) -> None:
        with mock.patch.object(MODULE.shutil, "which") as which:
            which.side_effect = lambda name: str(
                self.elan if name == "elan" else self.bash
            )
            entries = MODULE.tool_entries(
                ["bash"], ["elan"], {"bash": self.bash, "elan": self.elan}
            )
        elan_entry = next(entry for entry in entries if entry["name"] == "elan")
        self.assertEqual(elan_entry["path"], str(self.elan))

    def test_declared_command_binds_unique_canonical_trace_alias(self) -> None:
        canonical = make_executable(self.root / "gawk")
        shim = self.root / "awk"
        shim.symlink_to(canonical)
        with mock.patch.object(MODULE.shutil, "which") as which:
            which.side_effect = lambda name: str(shim) if name == "awk" else None
            entries = MODULE.tool_entries(
                ["awk"], [], {"gawk": canonical}
            )
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["name"], "awk")
        self.assertEqual(entries[0]["path"], str(canonical))

    def test_four_toolchain_roles_accept_exact_elan_candidates(self) -> None:
        roles = ("clang", "ld.lld", "lean", "leanc")
        direct = {
            role: make_executable(self.root / f"direct-{role}") for role in roles
        }
        toolchain = {
            role: make_executable(self.root / f"toolchain-{role}")
            for role in roles
        }

        def which(name: str) -> str | None:
            if name == "elan":
                return str(self.elan)
            return str(direct[name]) if name in direct else None

        def run(arguments: list[str], **_kwargs: object) -> object:
            if arguments[:2] == [str(self.elan), "which"]:
                return SimpleNamespace(
                    returncode=0,
                    stdout=f"{toolchain[arguments[2]]}\n",
                )
            return SimpleNamespace(returncode=0, stdout=b"lean version\n")

        with mock.patch.object(MODULE.shutil, "which", side_effect=which), mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=run,
        ):
            entries = MODULE.tool_entries(
                list(roles),
                [],
                toolchain,
            )

        self.assertEqual(
            {entry["name"]: entry["path"] for entry in entries},
            {role: str(toolchain[role]) for role in roles},
        )

    def test_declared_basename_cannot_bypass_independent_role_resolution(self) -> None:
        resolved_root = self.root / "resolved"
        resolved_root.mkdir()
        independently_resolved = make_executable(resolved_root / "bash")
        with mock.patch.object(
            MODULE.shutil,
            "which",
            return_value=str(independently_resolved),
        ), self.assertRaises(MODULE.ProfileError):
            MODULE.tool_entries(["bash"], [], {"bash": self.bash})

    def test_trace_path_must_resolve_to_one_declared_role(self) -> None:
        canonical = make_executable(self.root / "gawk")
        with mock.patch.object(MODULE.shutil, "which", return_value=str(canonical)):
            with self.assertRaises(MODULE.ProfileError):
                MODULE.tool_entries(
                    ["awk", "gawk"],
                    [],
                    {"gawk": canonical},
                )

    def test_declared_role_resolution_drift_after_trace_fails(self) -> None:
        resolved_root = self.root / "resolved"
        resolved_root.mkdir()
        drifted = make_executable(resolved_root / "bash")
        with mock.patch.object(MODULE.shutil, "which", return_value=str(self.bash)):
            entries = MODULE.tool_entries(["bash"], [], {"bash": self.bash})
        with mock.patch.object(MODULE.shutil, "which", return_value=str(drifted)):
            with self.assertRaises(MODULE.ProfileError):
                MODULE.verify_tool_entries(entries)

    def test_observed_tool_missing_or_drift_after_trace_fails(self) -> None:
        with mock.patch.object(MODULE.shutil, "which") as which:
            which.side_effect = lambda name: str(
                self.elan if name == "elan" else self.bash
            )
            entries = MODULE.tool_entries(
                ["bash"], ["elan"], {"bash": self.bash, "elan": self.elan}
            )
            self.elan.unlink()
            with self.assertRaises(MODULE.ProfileError):
                MODULE.verify_tool_entries(entries)
            make_executable(self.elan, b"#!/bin/sh\nexit 7\n")
            with self.assertRaises(MODULE.ProfileError):
                MODULE.verify_tool_entries(entries)

    def test_optional_identity_cannot_introduce_unobserved_tool(self) -> None:
        with self.assertRaises(MODULE.ProfileError):
            MODULE.tool_entries(
                ["bash"], ["elan"], {"bash": self.bash}, include_optional={"elan"}
            )


class BuildAuditContractTests(unittest.TestCase):
    def test_build_audit_appends_once_and_reuse_appends_zero(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            audit = root / "controller-build.audit"
            MODULE.append_controller_build_audit(audit, root)
            self.assertEqual(MODULE.controller_build_count(audit), 1)
            MODULE.record_reuse_phase(audit, root)
            self.assertEqual(MODULE.controller_build_count(audit), 1)

    def test_audit_rejects_outside_path_and_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            outside = root.parent / "outside-audit"
            with self.assertRaises(MODULE.ProfileError):
                MODULE.append_controller_build_audit(outside, root)
            target = root / "target"
            target.write_text("", encoding="utf-8")
            alias = root / "audit"
            alias.symlink_to(target)
            with self.assertRaises(MODULE.ProfileError):
                MODULE.append_controller_build_audit(alias, root)


class OwnedProcessContractTests(unittest.TestCase):
    def test_direct_profiler_signals_return_modeled_status(self) -> None:
        for signal_value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signal_value), tempfile.TemporaryDirectory(
                prefix="direct-profiler-signal-"
            ) as temporary:
                ready = Path(temporary) / "ready"
                profiler_pid = os.fork()
                if profiler_pid == 0:
                    def hold() -> int:
                        ready.write_text("ready", encoding="ascii")
                        signal.pause()
                        return 78

                    try:
                        status = MODULE._run_with_profile_signal_protocol(hold)
                    except BaseException:
                        os._exit(1)
                    os._exit(status)

                waited = False
                try:
                    deadline = time.monotonic() + 2.0
                    while not ready.is_file() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.is_file())
                    os.kill(profiler_pid, signal_value)
                    waited_pid, wait_status = os.waitpid(profiler_pid, 0)
                    waited = waited_pid == profiler_pid
                    self.assertEqual(
                        os.waitstatus_to_exitcode(wait_status),
                        128 + signal_value.value,
                    )
                finally:
                    if not waited:
                        try:
                            os.kill(profiler_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        os.waitpid(profiler_pid, 0)

    def test_timeout_reaps_only_the_owned_generated_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pid_path = root / "descendant.pid"
            script = root / "hung.sh"
            script.write_text(
                "#!/bin/sh\n"
                "sleep 60 &\n"
                f"printf '%s\\n' \"$!\" >{pid_path!s}\n"
                "wait\n",
                encoding="utf-8",
            )
            script.chmod(0o700)
            with self.assertRaises(subprocess.TimeoutExpired):
                MODULE.run_owned_command(
                    [str(script)],
                    cwd=root,
                    environment=os.environ.copy(),
                    log_path=root / "owned.log",
                    timeout=0.2,
                )
            descendant = int(pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                try:
                    os.kill(descendant, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                self.fail("owned generated descendant survived process-group cleanup")

    def test_run_hook_timeout_reaps_resistant_descendant_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descendant_pid_path = root / "descendant.pid"
            script = root / "hung-hook.sh"
            script.write_text(
                "#!/bin/sh\n"
                f"{sys.executable} -c 'import os, signal, time; "
                "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "open(os.environ[\"PROFILE_DESCENDANT_PID\"], \"w\").write("
                "str(os.getpid())); time.sleep(60)' "
                "</dev/null >/dev/null 2>&1 &\n"
                "wait\n",
                encoding="utf-8",
            )
            script.chmod(0o700)
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            descendant = 0
            descendant_alive = False
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    MODULE.run_hook(
                        str(script),
                        b"generated",
                        {
                            **os.environ,
                            "PROFILE_DESCENDANT_PID": str(descendant_pid_path),
                        },
                        root,
                        timeout=0.3,
                    )
                descendant = int(descendant_pid_path.read_text(encoding="ascii"))
                descendant_alive = True
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    try:
                        os.kill(descendant, 0)
                    except ProcessLookupError:
                        descendant_alive = False
                        break
                    time.sleep(0.02)
                else:
                    self.fail("run_hook descendant survived owned-group cleanup")
                self.assertIsNone(unrelated.poll())
            finally:
                if descendant_alive:
                    try:
                        os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                MODULE._stop_owned_process_group(unrelated)

    def test_run_hook_normal_exit_drains_resistant_descendant_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descendant_pid_path = root / "descendant.pid"
            script = root / "completed-hook.sh"
            script.write_text(
                "#!/bin/sh\n"
                f"{sys.executable} -c 'import os, signal, time; "
                "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "open(os.environ[\"PROFILE_DESCENDANT_PID\"], \"w\").write("
                "str(os.getpid())); time.sleep(60)' "
                "</dev/null >/dev/null 2>&1 &\n"
                "while [ ! -s \"$PROFILE_DESCENDANT_PID\" ]; do :; done\n"
                "exit 0\n",
                encoding="utf-8",
            )
            script.chmod(0o700)
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            descendant = 0
            descendant_alive = False
            try:
                result = MODULE.run_hook(
                    str(script),
                    b"generated",
                    {
                        **os.environ,
                        "PROFILE_DESCENDANT_PID": str(descendant_pid_path),
                    },
                    root,
                    timeout=1.0,
                )
                self.assertEqual(result.returncode, 0)
                descendant = int(descendant_pid_path.read_text(encoding="ascii"))
                descendant_alive = True
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    try:
                        os.kill(descendant, 0)
                    except ProcessLookupError:
                        descendant_alive = False
                        break
                    time.sleep(0.02)
                else:
                    self.fail("completed run_hook left its owned descendant alive")
                self.assertIsNone(unrelated.poll())
            finally:
                if descendant_alive:
                    try:
                        os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                MODULE._stop_owned_process_group(unrelated)

    def test_profiler_signal_reaps_active_owned_group_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            formal = root / "formal"
            output = root / "output"
            formal.mkdir(mode=0o700)
            output.mkdir(mode=0o700)
            group_pid_path = root / "group.pid"
            descendant_pid_path = root / "descendant.pid"
            signal_log = root / "descendant-signals"
            child_source = (
                "import os, signal, time\n"
                "def observed(signum, _frame):\n"
                "    with open(os.environ['PROFILE_SIGNAL_LOG'], 'a', "
                "encoding='ascii') as stream:\n"
                "        stream.write(str(signum) + '\\n')\n"
                "for value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):\n"
                "    signal.signal(value, observed)\n"
                "open(os.environ['PROFILE_DESCENDANT_PID'], 'w').write("
                "str(os.getpid()))\n"
                "while True:\n"
                "    time.sleep(60)\n"
            )
            script = root / "active-owned-group.sh"
            script.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$$\" >{group_pid_path!s}\n"
                f"{shlex.quote(sys.executable)} -c {shlex.quote(child_source)} "
                "</dev/null >/dev/null 2>&1 &\n"
                "wait\n",
                encoding="utf-8",
            )
            script.chmod(0o700)
            environment = {
                **os.environ,
                "PROFILE_DESCENDANT_PID": str(descendant_pid_path),
                "PROFILE_SIGNAL_LOG": str(signal_log),
            }
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            profiler_pid = os.fork()
            if profiler_pid == 0:
                os.setsid()
                devnull_fd = os.open(os.devnull, os.O_WRONLY)
                os.dup2(devnull_fd, 1)
                os.dup2(devnull_fd, 2)
                os.close(devnull_fd)

                def run_active_group(*_args: object, **_kwargs: object) -> object:
                    MODULE.run_owned_command(
                        [str(script)],
                        cwd=root,
                        environment=environment,
                        log_path=output / "active.log",
                        timeout=60.0,
                    )
                    raise AssertionError("active group unexpectedly completed")

                with mock.patch.object(MODULE, "validate_profile_roots"), mock.patch.object(
                    MODULE,
                    "validate_profile_destinations",
                ), mock.patch.object(
                    MODULE,
                    "export_candidate",
                    return_value=SimpleNamespace(commit="a" * 40),
                ), mock.patch.object(MODULE, "_run_profile", side_effect=run_active_group):
                    try:
                        MODULE.main(
                            [
                                str(MODULE.PROFILER) if hasattr(MODULE, "PROFILER") else "profile",
                                str(root),
                                "--formal-tmp-root",
                                str(formal),
                                "--output-root",
                                str(output),
                            ]
                        )
                    except BaseException:
                        os._exit(77)
                os._exit(78)

            group_pid = 0
            group_alive = False
            descendant = 0
            profiler_waited = False
            try:
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    if group_pid_path.is_file() and descendant_pid_path.is_file():
                        break
                    waited, _status = os.waitpid(profiler_pid, os.WNOHANG)
                    if waited == profiler_pid:
                        profiler_waited = True
                        break
                    time.sleep(0.02)
                self.assertTrue(group_pid_path.is_file())
                self.assertTrue(descendant_pid_path.is_file())
                group_pid = int(group_pid_path.read_text(encoding="ascii"))
                group_alive = True
                descendant = int(descendant_pid_path.read_text(encoding="ascii"))
                os.kill(profiler_pid, signal.SIGTERM)
                deadline = time.monotonic() + 5.0
                while not profiler_waited and time.monotonic() < deadline:
                    waited, _status = os.waitpid(profiler_pid, os.WNOHANG)
                    if waited == profiler_pid:
                        profiler_waited = True
                        break
                    time.sleep(0.02)
                self.assertTrue(profiler_waited)
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    try:
                        os.kill(descendant, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.02)
                else:
                    self.fail("profiler signal left active owned descendant alive")
                try:
                    os.killpg(group_pid, 0)
                except ProcessLookupError:
                    group_alive = False
                else:
                    self.fail("profiler signal left active owned group alive")
                self.assertIsNone(unrelated.poll())
                self.assertEqual(
                    signal_log.read_text(encoding="ascii").splitlines(),
                    [str(signal.SIGTERM.value)],
                )
            finally:
                if not profiler_waited:
                    try:
                        os.killpg(profiler_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.waitpid(profiler_pid, 0)
                if group_alive:
                    try:
                        os.killpg(group_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                MODULE._stop_owned_process_group(unrelated)


class WrapperContractTests(unittest.TestCase):
    def _stub_wrapper_tree(self, base: Path) -> Path:
        wrapper = base / "hooks/tests/profile-pre-reviewer.sh"
        library = base / "hooks/tests/lib/formal-tmpfs.sh"
        profiler = base / "hooks/tests/profile_pre_reviewer_ab.py"
        library.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "hooks/tests/profile-pre-reviewer.sh", wrapper)
        shutil.copy2(ROOT / "hooks/tests/lib/formal-tmpfs.sh", library)
        profiler.write_text(
            "import json, os, pathlib, sys\n"
            "formal = pathlib.Path(sys.argv[3])\n"
            "output = pathlib.Path(sys.argv[5])\n"
            "pathlib.Path(os.environ['PROFILE_STUB_LOG']).write_text("
            "json.dumps({'argv': sys.argv[1:], 'formal': str(formal), "
            "'output': str(output)}))\n"
            "(output / 'evidence').mkdir(parents=True, exist_ok=True)\n"
            "(output / 'logs').mkdir(parents=True, exist_ok=True)\n"
            "(output / 'evidence/pre-reviewer-profile.out').write_text("
            "'stub-report\\n')\n"
            "(output / 'logs/pre-reviewer-profile.log').write_text("
            "'stub-log\\n')\n"
            "raise SystemExit(int(os.environ.get('PROFILE_STUB_STATUS', '0')))\n",
            encoding="utf-8",
        )
        return wrapper

    def _resistant_stub_wrapper_tree(self, base: Path) -> Path:
        wrapper = self._stub_wrapper_tree(base)
        profiler = base / "hooks/tests/profile_pre_reviewer_ab.py"
        child_source = (
            "import os, signal, time\n"
            "def observed(signum, _frame):\n"
            "    with open(os.environ['PROFILE_SIGNAL_LOG'], 'a', "
            "encoding='ascii') as stream:\n"
            "        stream.write(str(signum) + '\\n')\n"
            "for value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):\n"
            "    signal.signal(value, observed)\n"
            "open(os.environ['PROFILE_CHILD_READY'], 'w').write('ready\\n')\n"
            "while True:\n"
            "    time.sleep(60)\n"
        )
        profiler.write_text(
            "import json, os, pathlib, signal, subprocess, sys, time\n"
            "formal = pathlib.Path(sys.argv[3])\n"
            "output = pathlib.Path(sys.argv[5])\n"
            "pathlib.Path(os.environ['PROFILE_STUB_LOG']).write_text("
            "json.dumps({'formal': str(formal), 'output': str(output)}))\n"
            "(output / 'evidence').mkdir(parents=True, exist_ok=True)\n"
            "(output / 'logs').mkdir(parents=True, exist_ok=True)\n"
            "(output / 'evidence/partial').write_text('preserve\\n')\n"
            "(output / 'logs/pre-reviewer-profile.log').write_text("
            "'interrupted\\n')\n"
            f"child_source = {child_source!r}\n"
            "child = subprocess.Popen([sys.executable, '-c', child_source], "
            "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
            "stderr=subprocess.DEVNULL)\n"
            "pathlib.Path(os.environ['PROFILE_DESCENDANT_PID']).write_text("
            "str(child.pid))\n"
            "while not pathlib.Path(os.environ['PROFILE_CHILD_READY']).is_file():\n"
            "    time.sleep(0.01)\n"
            "pathlib.Path(os.environ['PROFILE_READY']).write_text('ready\\n')\n"
            "signal.pause()\n",
            encoding="utf-8",
        )
        return wrapper

    def _assert_interrupt_teardown(self, signal_value: signal.Signals, mode: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            wrapper = self._resistant_stub_wrapper_tree(base)
            invocation = base / "invocation.json"
            ready = base / "ready"
            child_ready = base / "child-ready"
            descendant_pid_path = base / "descendant.pid"
            signal_log = base / "descendant-signals"
            unrelated = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
            )
            environment = {
                **os.environ,
                "PROFILE_STUB_LOG": str(invocation),
                "PROFILE_READY": str(ready),
                "PROFILE_CHILD_READY": str(child_ready),
                "PROFILE_DESCENDANT_PID": str(descendant_pid_path),
                "PROFILE_SIGNAL_LOG": str(signal_log),
            }
            if mode == "explicit":
                formal = base / "formal"
                output = base / "output"
                formal.mkdir(mode=0o700)
                output.mkdir(mode=0o700)
                arguments = [
                    str(wrapper),
                    "--formal-tmp-root",
                    str(formal),
                    "--output-root",
                    str(output),
                ]
            else:
                environment.update(
                    {
                        "CODEX_TEST_FORMAL_TMPFS_BASE": "/tmp",
                        "CODEX_TEST_FORMAL_PERSISTENT_BASE": str(
                            base / "persistent"
                        ),
                    }
                )
                arguments = [str(wrapper)]
                formal = Path()
                output = Path()
            process = subprocess.Popen(
                arguments,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                start_new_session=True,
            )
            descendant = 0
            descendant_alive = False
            timed_out = False
            try:
                deadline = time.monotonic() + 3.0
                while not ready.is_file() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    time.sleep(0.02)
                self.assertTrue(ready.is_file(), "stub profiler did not become ready")
                observed = json.loads(invocation.read_text(encoding="utf-8"))
                formal = Path(observed["formal"])
                output = Path(observed["output"])
                descendant = int(descendant_pid_path.read_text(encoding="ascii"))
                descendant_alive = True
                os.kill(process.pid, signal_value)
                try:
                    stdout, stderr = process.communicate(timeout=5.0)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    MODULE._stop_owned_process_group(process)
                    stdout, stderr = process.communicate(timeout=1.0)
                self.assertFalse(timed_out, stderr.decode(errors="replace"))
                self.assertEqual(process.returncode, 128 + signal_value.value)
                self.assertEqual(stdout, b"")
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    try:
                        os.kill(descendant, 0)
                    except ProcessLookupError:
                        descendant_alive = False
                        break
                    time.sleep(0.02)
                else:
                    self.fail("interrupted wrapper left resistant descendant alive")
                self.assertIsNone(unrelated.poll())
                self.assertEqual(
                    signal_log.read_text(encoding="ascii").splitlines(),
                    [str(signal_value.value)],
                )
                self.assertTrue((output / "evidence/partial").is_file())
                self.assertTrue(
                    (output / "logs/pre-reviewer-profile.log").is_file()
                )
                if mode == "explicit":
                    self.assertTrue(formal.is_dir())
                    self.assertTrue(output.is_dir())
                else:
                    self.assertFalse(formal.exists())
                    self.assertTrue(output.is_dir())
            finally:
                MODULE._stop_owned_process_group(process)
                if descendant_alive:
                    try:
                        os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                MODULE._stop_owned_process_group(unrelated)

    def test_explicit_mode_interrupts_owned_profiler_group(self) -> None:
        for signal_value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signal_value):
                self._assert_interrupt_teardown(signal_value, "explicit")

    def test_no_arg_mode_interrupts_owned_profiler_group(self) -> None:
        for signal_value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signal_value):
                self._assert_interrupt_teardown(signal_value, "no-arg")

    def test_wrapper_rejects_partial_modes_and_internal_reexec_state(self) -> None:
        wrapper = ROOT / "hooks/tests/profile-pre-reviewer.sh"
        for arguments in (
            ["--formal-tmp-root", "/tmp/generated"],
            ["--output-root", "/tmp/generated"],
            ["--formal-tmp-root", "/tmp/a", "--output-root"],
        ):
            result = subprocess.run(
                [str(wrapper), *arguments],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
        result = subprocess.run(
            [str(wrapper)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "CODEX_PROFILE_INTERNAL_REEXEC": "1"},
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"internal profiler reexec", result.stderr)

    def test_wrapper_source_invokes_external_python_once_without_recursion(self) -> None:
        source = (ROOT / "hooks/tests/profile-pre-reviewer.sh").read_text(
            encoding="utf-8"
        )
        self.assertEqual(source.count("profile_pre_reviewer_ab.py"), 1)
        self.assertNotIn("CODEX_PROFILE_EXPORTED", source)
        self.assertNotIn("exec python3", source)

    def test_no_arg_wrapper_invokes_external_mode_once_and_cleans_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            wrapper = self._stub_wrapper_tree(base)
            invocation = base / "invocation.json"
            persistent_base = base / "persistent"
            result = subprocess.run(
                [str(wrapper)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "CODEX_TEST_FORMAL_TMPFS_BASE": "/tmp",
                    "CODEX_TEST_FORMAL_PERSISTENT_BASE": str(persistent_base),
                    "PROFILE_STUB_LOG": str(invocation),
                },
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout, b"stub-report\n")
            observed = json.loads(invocation.read_text(encoding="utf-8"))
            self.assertEqual(observed["argv"][1], "--formal-tmp-root")
            self.assertEqual(observed["argv"][3], "--output-root")
            self.assertTrue(Path(observed["formal"]).is_absolute())
            self.assertTrue(Path(observed["output"]).is_absolute())
            self.assertNotEqual(observed["formal"], observed["output"])
            self.assertFalse(Path(observed["formal"]).exists())
            self.assertFalse(Path(observed["output"]).exists())

    def test_no_arg_wrapper_preserves_persistent_failure_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            wrapper = self._stub_wrapper_tree(base)
            invocation = base / "invocation.json"
            result = subprocess.run(
                [str(wrapper)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "CODEX_TEST_FORMAL_TMPFS_BASE": "/tmp",
                    "CODEX_TEST_FORMAL_PERSISTENT_BASE": str(base / "persistent"),
                    "PROFILE_STUB_LOG": str(invocation),
                    "PROFILE_STUB_STATUS": "7",
                },
                check=False,
            )
            self.assertEqual(result.returncode, 7)
            observed = json.loads(invocation.read_text(encoding="utf-8"))
            output = Path(observed["output"])
            self.assertTrue((output / "logs/pre-reviewer-profile.log").is_file())
            self.assertIn(str(output).encode(), result.stderr)
            self.assertFalse(Path(observed["formal"]).exists())

    def test_explicit_mode_allocates_and_deletes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            wrapper = self._stub_wrapper_tree(base)
            invocation = base / "invocation.json"
            formal = base / "formal"
            output = base / "output"
            formal.mkdir(mode=0o700)
            output.mkdir(mode=0o700)
            result = subprocess.run(
                [
                    str(wrapper),
                    "--formal-tmp-root",
                    str(formal),
                    "--output-root",
                    str(output),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={**os.environ, "PROFILE_STUB_LOG": str(invocation)},
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertTrue(formal.is_dir())
            self.assertTrue(output.is_dir())


class RunnerReuseContractTests(unittest.TestCase):
    def test_runner_invokes_profiler_once_then_reuses_bound_report(self) -> None:
        source = (ROOT / "hooks/tests/run.sh").read_text(encoding="utf-8")
        self.assertEqual(
            source.count('"$ROOT/hooks/tests/profile-pre-reviewer.sh"'), 1
        )
        self.assertEqual(source.count("module.validate_persisted_profile("), 2)
        self.assertIn("expected_sha256=expected_sha256", source)
        self.assertIn("profile final build audit remains exactly one", source)

    def test_runner_verifies_formal_identity_before_profile_oracle(self) -> None:
        source = (ROOT / "hooks/tests/run.sh").read_text(encoding="utf-8")
        verification = source.index(
            'if ! "$controller_verifier" --verify-artifact'
        )
        validation = source.index(
            "print(module.validate_persisted_profile("
        )
        self.assertLess(verification, validation)


if __name__ == "__main__":
    unittest.main()
