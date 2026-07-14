#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
sys.path.insert(0, str(LIB_ROOT))

import migrate_pre_reviewer_state_dir


class PreReviewerStateDirectoryMigrationTests(unittest.TestCase):
    def test_owned_directory_is_migrated_to_private_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root) / "state"
            state_dir.mkdir(mode=0o755)
            state_dir.chmod(0o755)

            migrated = migrate_pre_reviewer_state_dir.migrate(state_dir)

            self.assertTrue(migrated)
            self.assertEqual(state_dir.stat().st_mode & 0o777, 0o700)

    def test_already_private_directory_does_not_need_fchmod(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root) / "state"
            state_dir.mkdir(mode=0o700)
            state_dir.chmod(0o700)

            with mock.patch.object(
                migrate_pre_reviewer_state_dir.os,
                "fchmod",
                side_effect=AssertionError("unexpected fchmod"),
            ):
                migrated = migrate_pre_reviewer_state_dir.migrate(state_dir)

            self.assertTrue(migrated)

    def test_symlink_and_non_directory_are_not_mutated(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            target = root / "target"
            target.mkdir(mode=0o755)
            target.chmod(0o755)
            link = root / "link"
            link.symlink_to(target, target_is_directory=True)
            regular_file = root / "file"
            regular_file.write_text("state", encoding="utf-8")
            regular_file.chmod(0o644)

            self.assertFalse(migrate_pre_reviewer_state_dir.migrate(link))
            self.assertFalse(migrate_pre_reviewer_state_dir.migrate(regular_file))
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            self.assertEqual(regular_file.stat().st_mode & 0o777, 0o644)

    def test_wrong_owner_is_not_mutated(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root) / "state"
            state_dir.mkdir(mode=0o755)
            state_dir.chmod(0o755)

            with mock.patch.object(
                migrate_pre_reviewer_state_dir.os,
                "geteuid",
                return_value=os.geteuid() + 1,
            ):
                migrated = migrate_pre_reviewer_state_dir.migrate(state_dir)

            self.assertFalse(migrated)
            self.assertEqual(state_dir.stat().st_mode & 0o777, 0o755)

    def test_missing_required_flag_or_syscall_fails_without_mutation(self) -> None:
        for unavailable_name in ("O_NOFOLLOW", "fchmod"):
            with self.subTest(unavailable_name=unavailable_name):
                with tempfile.TemporaryDirectory() as temp_root:
                    state_dir = Path(temp_root) / "state"
                    state_dir.mkdir(mode=0o755)
                    state_dir.chmod(0o755)

                    with mock.patch.object(
                        migrate_pre_reviewer_state_dir.os,
                        unavailable_name,
                        None,
                    ):
                        migrated = migrate_pre_reviewer_state_dir.migrate(state_dir)

                    self.assertFalse(migrated)
                    self.assertEqual(state_dir.stat().st_mode & 0o777, 0o755)

    def test_path_swap_during_migration_fails_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            state_dir = root / "state"
            moved_dir = root / "moved"
            state_dir.mkdir(mode=0o755)
            state_dir.chmod(0o755)
            real_fchmod = os.fchmod

            def swap_path(fd: int, mode: int) -> None:
                real_fchmod(fd, mode)
                state_dir.rename(moved_dir)
                state_dir.mkdir(mode=0o700)
                state_dir.chmod(0o700)

            with mock.patch.object(
                migrate_pre_reviewer_state_dir.os,
                "fchmod",
                side_effect=swap_path,
            ):
                migrated = migrate_pre_reviewer_state_dir.migrate(state_dir)

            self.assertFalse(migrated)
            self.assertEqual(moved_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual(state_dir.stat().st_mode & 0o777, 0o700)

    def test_cli_is_silent_for_success_and_failure(self) -> None:
        helper = LIB_ROOT / "migrate_pre_reviewer_state_dir.py"
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            state_dir = root / "state"
            state_dir.mkdir(mode=0o755)
            state_dir.chmod(0o755)
            regular_file = root / "file"
            regular_file.write_text("state", encoding="utf-8")

            success = subprocess.run(
                [sys.executable, str(helper), str(state_dir)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            failure = subprocess.run(
                [sys.executable, str(helper), str(regular_file)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual((success.returncode, success.stdout, success.stderr), (0, b"", b""))
            self.assertNotEqual(failure.returncode, 0)
            self.assertEqual((failure.stdout, failure.stderr), (b"", b""))


if __name__ == "__main__":
    unittest.main()
