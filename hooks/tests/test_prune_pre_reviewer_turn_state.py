#!/usr/bin/env python3

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Iterator
from pathlib import Path
from types import TracebackType
from unittest import mock

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
sys.path.insert(0, str(LIB_ROOT))

import prune_pre_reviewer_turn_state


class FakeEntry:
    def __init__(self, name: str, error: OSError) -> None:
        self.name = name
        self._error = error

    def stat(self, *, follow_symlinks: bool = True) -> os.stat_result:
        if follow_symlinks:
            raise AssertionError("pruning must not follow links")
        raise self._error


class FakeScandir:
    def __init__(self, entries: list[FakeEntry]) -> None:
        self._entries = entries

    def __enter__(self) -> FakeScandir:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        return None

    def __iter__(self) -> Iterator[FakeEntry]:
        return iter(self._entries)


class PrunePreReviewerTurnStateTests(unittest.TestCase):
    def open_directory(self, path: Path) -> int:
        return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)

    def test_exact_age_boundary_is_retained_and_older_entry_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            exact = state_dir / "claim-turn-exact"
            old = state_dir / "claim-turn-old"
            exact.touch()
            old.touch()
            now = 10_000
            os.utime(exact, (now - 3600, now - 3600))
            os.utime(old, (now - 3601, now - 3601))
            fd = self.open_directory(state_dir)
            try:
                self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, now))
                self.assertTrue(exact.exists())
                self.assertFalse(old.exists())
            finally:
                os.close(fd)

    def test_every_namespace_is_selected(self) -> None:
        names = (
            "capture-turn-key_A-9.json",
            "claim-turn-key_A-9",
            ".capture-turn-key_A-9.redacted.A0",
            ".capture-turn-key_A-9.capped.A0",
            ".capture-turn-key_A-9.json.A0",
            ".capture-turn-key_A-9.validated.A0",
            ".capture-turn-key_A-9.consumed.A0",
            ".capture-turn-key_A-9.prompt.A0",
        )
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            now = 10_000
            for name in names:
                path = state_dir / name
                path.touch()
                os.utime(path, (now - 3601, now - 3601))
            fd = self.open_directory(state_dir)
            try:
                self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, now))
                self.assertEqual(list(state_dir.iterdir()), [])
            finally:
                os.close(fd)

    def test_near_matches_and_non_regular_entries_are_retained(self) -> None:
        names = (
            "capture-turn-.json",
            "capture-turn-key.json.extra",
            "capture-turn-key!.json",
            "claim-turn-",
            "claim-turn-key.json",
            ".capture-turn-key.unknown.A0",
            ".capture-turn-key.capped.",
            ".capture-turn-key.capped.A-0",
            ".capture-turn-key.capped.A0.extra",
            "unrelated",
        )
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            now = 10_000
            for name in names:
                path = state_dir / name
                path.touch()
                os.utime(path, (now - 3601, now - 3601))
            directory = state_dir / "claim-turn-directory"
            directory.mkdir()
            fifo = state_dir / "claim-turn-fifo"
            os.mkfifo(fifo)
            target = state_dir / "target"
            target.touch()
            os.utime(target, (now - 3601, now - 3601))
            symlink = state_dir / "claim-turn-symlink"
            symlink.symlink_to(target.name)
            fd = self.open_directory(state_dir)
            try:
                self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, now))
                self.assertEqual({path.name for path in state_dir.iterdir()}, set(names) | {
                    directory.name, fifo.name, target.name, symlink.name
                })
            finally:
                os.close(fd)

    def test_invalid_directory_descriptors_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            state_dir = root / "state"
            state_dir.mkdir(mode=0o700)
            state_dir.chmod(0o700)
            regular = root / "regular"
            regular.touch()
            directory_fd = self.open_directory(state_dir)
            regular_fd = os.open(regular, os.O_RDONLY)
            try:
                state_dir.chmod(0o755)
                self.assertFalse(prune_pre_reviewer_turn_state.prune(directory_fd, 10_000))
                state_dir.chmod(0o700)
                with mock.patch.object(
                    prune_pre_reviewer_turn_state.os,
                    "geteuid",
                    return_value=os.geteuid() + 1,
                ):
                    self.assertFalse(prune_pre_reviewer_turn_state.prune(directory_fd, 10_000))
                self.assertFalse(prune_pre_reviewer_turn_state.prune(regular_fd, 10_000))
            finally:
                os.close(regular_fd)
                os.close(directory_fd)

    def test_entry_disappearance_and_errors_are_tolerated(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            fd = self.open_directory(state_dir)
            entries = [
                FakeEntry("claim-turn-gone", FileNotFoundError()),
                FakeEntry("claim-turn-error", PermissionError()),
            ]
            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state.os,
                    "scandir",
                    return_value=FakeScandir(entries),
                ) as scandir:
                    self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, 10_000))
                scandir.assert_called_once_with(fd)
            finally:
                os.close(fd)

    def test_unlink_errors_are_tolerated_and_descriptor_remains_usable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            old = state_dir / "claim-turn-old"
            old.touch()
            now = 10_000
            os.utime(old, (now - 3601, now - 3601))
            fd = self.open_directory(state_dir)
            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state.os,
                    "unlink",
                    side_effect=FileNotFoundError(),
                ):
                    self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, now))
                self.assertTrue(stat.S_ISDIR(os.fstat(fd).st_mode))
                self.assertTrue(old.exists())
            finally:
                os.close(fd)

    def test_cli_is_silent_and_leaves_parent_descriptor_open(self) -> None:
        helper = LIB_ROOT / "prune_pre_reviewer_turn_state.py"
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            fd = self.open_directory(state_dir)
            try:
                result = subprocess.run(
                    [sys.executable, str(helper), str(fd), "10000"],
                    pass_fds=(fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
                self.assertTrue(stat.S_ISDIR(os.fstat(fd).st_mode))
            finally:
                os.close(fd)


if __name__ == "__main__":
    unittest.main()
