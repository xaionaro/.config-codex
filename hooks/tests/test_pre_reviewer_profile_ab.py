#!/usr/bin/env python3
"""Regression tests for exact parent/candidate profiling identity."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROFILER = ROOT / "hooks" / "tests" / "profile_pre_reviewer_ab.py"
CONTROLLER = Path("hooks/edit-bash-pre-reviewer.sh")
PYTHON_CONTROLLER = Path("hooks/lib/edit_bash_pre_reviewer_controller.py")
BASELINE_COMMIT = "72b8b3d62df89975b35ed5bda1a5231a2be4fe4b"
SPEC = importlib.util.spec_from_file_location("pre_reviewer_profile_ab", PROFILER)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def git_output(*arguments: str) -> bytes:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout


class ProfileIdentityTests(unittest.TestCase):
    def test_runtime_manifest_covers_configuration_and_transitive_sources(self) -> None:
        definition = MODULE.load_runtime_manifest(ROOT)
        expected = {Path(value) for value in definition["product_sources"]}
        self.assertEqual(set(MODULE.CANDIDATE_RUNTIME_SOURCE_PATHS), expected)
        self.assertEqual(set(MODULE.discover_runtime_sources(ROOT)), expected)
        MODULE.verify_manifest_closure(ROOT)
        with tempfile.TemporaryDirectory(prefix="profile-harness-trace-") as temporary:
            observed_harness = MODULE.observe_harness_runtime_tools(
                ROOT / "hooks/tests/differential/pre-reviewer-controller.sh",
                ROOT,
                Path(temporary) / "harness.strace",
            )
        self.assertIn("findmnt", observed_harness)
        MODULE.verify_tool_manifest_closure(
            definition,
            observed_product=set(),
            observed_harness=observed_harness,
        )

    def test_runtime_tool_manifest_rejects_undeclared_observed_tool(self) -> None:
        definition = MODULE.load_runtime_manifest(ROOT)
        with self.assertRaisesRegex(MODULE.ProfileError, "generated-undeclared"):
            MODULE.verify_tool_manifest_closure(
                definition,
                observed_product={"generated-undeclared"},
                observed_harness=set(),
            )

    def test_harness_execution_trace_rejects_added_undeclared_executable(self) -> None:
        definition = MODULE.load_runtime_manifest(ROOT)
        with tempfile.TemporaryDirectory(prefix="profile-harness-mutation-") as temporary:
            scratch = Path(temporary)
            generated = scratch / "generated-undeclared"
            generated.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            generated.chmod(0o755)
            wrapper = scratch / "harness.sh"
            wrapper.write_text(
                "#!/bin/bash\n"
                f'"{generated}"\n'
                f'exec "{ROOT / "hooks/tests/differential/pre-reviewer-controller.sh"}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            observed = MODULE.observe_harness_runtime_tools(
                wrapper,
                ROOT,
                scratch / "mutated.strace",
            )
        self.assertIn("generated-undeclared", observed)
        with self.assertRaisesRegex(MODULE.ProfileError, "generated-undeclared"):
            MODULE.verify_tool_manifest_closure(
                definition,
                observed_product=set(),
                observed_harness=observed,
            )

    def test_causal_scenarios_name_historical_work(self) -> None:
        self.assertEqual(MODULE.LARGE_HISTORY.history_records, 4_096)
        self.assertEqual(MODULE.RETAINED_STATE.retained_entries, 2_000)
        self.assertTrue(MODULE.RETAINED_STATE.measure_prompt)
        self.assertEqual(
            MODULE.HISTORY_SCAN_COMMIT,
            "dbb4a8b9a46f76fb9d0b644942d56fa45d3fce29",
        )
        self.assertEqual(
            MODULE.profile_commands(ROOT),
            tuple(
                str((ROOT / relative).resolve())
                for relative in MODULE.CONFIGURED_HOOK_PATHS
            ),
        )

    def test_export_parent_uses_preserved_parent_revision(self) -> None:
        expected_commit = BASELINE_COMMIT
        expected_controller = git_output("show", f"{BASELINE_COMMIT}:{CONTROLLER}")
        candidate_controller = (ROOT / CONTROLLER).read_bytes()
        self.assertNotEqual(expected_controller, candidate_controller)

        with tempfile.TemporaryDirectory(prefix="profile-parent-test-") as temporary:
            destination = Path(temporary) / "parent"
            exported = MODULE.export_parent(ROOT, destination)

            self.assertEqual(getattr(exported, "commit", None), expected_commit)
            self.assertEqual(
                getattr(exported, "wrapper_sha256", None),
                hashlib.sha256(expected_controller).hexdigest(),
            )
            self.assertEqual(
                (destination / CONTROLLER).read_bytes(), expected_controller
            )

    def test_export_parent_is_immutable_across_successor_history(self) -> None:
        with tempfile.TemporaryDirectory(prefix="profile-successor-test-") as temporary:
            clone = Path(temporary) / "clone"
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(ROOT), str(clone)],
                check=True,
            )
            subprocess.run(
                ["git", "-c", "user.name=Generated", "-c", "user.email=g@example.invalid",
                 "commit", "--quiet", "--allow-empty", "-m", "generated successor"],
                cwd=clone,
                check=True,
            )
            destination = Path(temporary) / "parent"
            exported = MODULE.export_parent(clone, destination)

            self.assertEqual(exported.commit, BASELINE_COMMIT)
            self.assertEqual(
                (destination / CONTROLLER).read_bytes(),
                subprocess.run(
                    ["git", "show", f"{BASELINE_COMMIT}:{CONTROLLER}"],
                    cwd=clone,
                    stdout=subprocess.PIPE,
                    check=True,
                ).stdout,
            )

    def test_candidate_identity_rejects_every_dirty_configured_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="profile-dirty-source-test-") as temporary:
            clone = Path(temporary) / "clone"
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(ROOT), str(clone)],
                check=True,
            )
            for relative in MODULE.CANDIDATE_VERIFIED_SOURCE_PATHS:
                with self.subTest(relative=relative):
                    path = clone / relative
                    original = path.read_bytes()
                    path.write_bytes(original + b"\n# generated dirty candidate\n")
                    with self.assertRaisesRegex(
                        MODULE.ProfileError,
                        rf"candidate source bytes differ from reported commit: {relative}",
                    ):
                        MODULE.candidate_revision_identity(clone)
                    path.write_bytes(original)

    def test_configured_commands_execute_their_own_root(self) -> None:
        observer = getattr(MODULE, "observe_configured_sources", None)
        self.assertTrue(callable(observer), "configured-source observer is missing")
        evidence_builder = getattr(MODULE, "source_identity_evidence", None)
        self.assertTrue(callable(evidence_builder), "source evidence is missing")

        with tempfile.TemporaryDirectory(prefix="profile-source-test-") as temporary:
            scratch = Path(temporary)
            candidate_root = scratch / "candidate"
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(ROOT), str(candidate_root)],
                check=True,
            )
            parent_root = scratch / "parent"
            parent_identity = MODULE.export_parent(candidate_root, parent_root)
            expected_parent = tuple(
                str((parent_root / relative).resolve())
                for relative in MODULE.CONFIGURED_HOOK_PATHS
            )
            expected_candidate = tuple(
                str((candidate_root / relative).resolve())
                for relative in MODULE.CONFIGURED_HOOK_PATHS
            )
            evidence = evidence_builder(
                parent_root,
                candidate_root,
                scratch / "source-evidence",
                parent_identity,
            )
            parent_sources = evidence.parent_sources
            candidate_sources = evidence.candidate_sources

            self.assertEqual(parent_sources, expected_parent)
            self.assertEqual(candidate_sources, expected_candidate)
            self.assertTrue(set(parent_sources).isdisjoint(candidate_sources))
            self.assertEqual(evidence.parent.commit, parent_identity.commit)
            self.assertEqual(
                evidence.candidate.commit,
                subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=candidate_root,
                    stdout=subprocess.PIPE,
                    check=True,
                    text=True,
                ).stdout.strip(),
            )
            self.assertNotEqual(
                evidence.parent.wrapper_sha256,
                evidence.candidate.wrapper_sha256,
            )

            hooks_path = parent_root / "hooks.json"
            configuration = json.loads(hooks_path.read_text())
            serialized = json.dumps(configuration).replace(
                "${CODEX_HOME:-$HOME/.codex}", str(candidate_root.resolve())
            )
            hooks_path.write_text(serialized, encoding="utf-8")
            with self.assertRaises(MODULE.ProfileError):
                observer(parent_root, scratch / "collapsed-source-state")

    def test_identity_record_has_one_immutable_schema(self) -> None:
        identity = MODULE.RevisionIdentity(
            commit="a" * 40,
            wrapper_sha256="b" * 64,
            python_controller_sha256="c" * 64,
            manifest_sha256="d" * 64,
        )
        rendered = MODULE.render_identity_record(identity, identity)
        self.assertEqual(
            rendered,
            "source-identities "
            f"baseline_commit={BASELINE_COMMIT} parent_commit={'a' * 40} "
            f"candidate_commit={'a' * 40} parent_wrapper_sha256={'b' * 64} "
            f"candidate_wrapper_sha256={'b' * 64} "
            f"parent_python_controller_sha256={'c' * 64} "
            f"candidate_python_controller_sha256={'c' * 64} "
            f"parent_manifest_sha256={'d' * 64} "
            f"candidate_manifest_sha256={'d' * 64} "
            "parent_executed=true candidate_executed=true",
        )

    def test_causal_scope_record_names_bounded_mechanisms(self) -> None:
        self.assertEqual(
            MODULE.CAUSAL_SCOPE_RECORD,
            "causal-scope transcript_history_scans=0 "
            "shared_turn_lock_prune_records_max=0 maintenance_prune_records_max=170 "
            "backend_timeout_max_seconds=58 "
            "controller_timeout_seconds=70 hook_timeout_seconds=75",
        )

    def test_runtime_evidence_is_versioned_and_per_entry(self) -> None:
        evidence = MODULE.runtime_evidence_manifest(ROOT, ROOT)
        self.assertEqual(evidence["schema_version"], 2)
        self.assertTrue(evidence["product"]["candidate"])
        self.assertTrue(evidence["harness"])
        self.assertTrue(evidence["product_tools"])
        self.assertTrue(evidence["harness_tools"])
        for section in (
            evidence["product"]["candidate"],
            evidence["harness"],
            evidence["product_tools"],
            evidence["harness_tools"],
        ):
            for entry in section:
                self.assertIn("sha256", entry)
        self.assertIn("not a bit-for-bit", evidence["claim"])
        self.assertIn("not a complete execution universe", evidence["claim"])

    def test_exported_candidate_remains_immutable_after_worktree_change(self) -> None:
        with tempfile.TemporaryDirectory(prefix="profile-candidate-export-") as temporary:
            clone = Path(temporary) / "clone"
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(ROOT), str(clone)],
                check=True,
            )
            destination = Path(temporary) / "candidate"
            identity = MODULE.export_candidate(clone, destination)
            exported_worker = destination / "hooks/lib/edit-bash-pre-reviewer-worker.sh"
            before = exported_worker.read_bytes()
            (clone / "hooks/lib/edit-bash-pre-reviewer-worker.sh").write_bytes(
                before + b"\n# generated drift\n"
            )
            self.assertEqual(exported_worker.read_bytes(), before)
            self.assertEqual(identity.commit, git_output("rev-parse", "HEAD").decode().strip())


if __name__ == "__main__":
    unittest.main()
