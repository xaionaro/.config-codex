#!/usr/bin/env python3

from __future__ import annotations

import fcntl
import ctypes
import os
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
sys.path.insert(0, str(LIB_ROOT))

import prune_pre_reviewer_turn_state


class PrunePreReviewerTurnStateTests(unittest.TestCase):
    def open_directory(self, path: Path) -> int:
        return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)

    def assert_valid_cursor_or_absent(self, state_dir: Path) -> None:
        cursor = state_dir / prune_pre_reviewer_turn_state.CURSOR_NAME
        if not cursor.exists():
            return
        metadata = cursor.stat(follow_symlinks=False)
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertEqual(metadata.st_uid, os.geteuid())
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_nlink, 1)
        self.assertTrue(cursor.read_bytes().strip().isdigit())

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
                retained = {path.name for path in state_dir.iterdir()}
                retained.discard(prune_pre_reviewer_turn_state.CURSOR_NAME)
                self.assertEqual(retained, set(names) | {
                    directory.name, fifo.name, target.name, symlink.name
                })
                self.assert_valid_cursor_or_absent(state_dir)
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
            (state_dir / "claim-turn-gone").touch()
            (state_dir / "claim-turn-error").touch()
            fd = self.open_directory(state_dir)
            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state,
                    "_entry_metadata",
                    side_effect=(FileNotFoundError(), PermissionError()),
                ) as metadata:
                    self.assertTrue(prune_pre_reviewer_turn_state.prune(fd, 10_000))
                self.assertEqual(metadata.call_count, 2)
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

    def test_fresh_same_name_replacement_is_not_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            capture = state_dir / "capture-turn-same.json"
            capture.write_bytes(b"old")
            now = 10_000
            os.utime(capture, (now - 3601, now - 3601))
            replacement = state_dir / ".capture-turn-same.json.FRESH"
            fd = self.open_directory(state_dir)
            real_entry_metadata = prune_pre_reviewer_turn_state._entry_metadata
            replaced = False

            def replace_after_observation(directory_fd: int, name: str) -> os.stat_result:
                nonlocal replaced
                metadata = real_entry_metadata(directory_fd, name)
                if name == capture.name and not replaced:
                    replaced = True
                    replacement.write_bytes(b"fresh")
                    os.utime(replacement, (now, now))
                    os.replace(replacement, capture)
                return metadata

            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state,
                    "_entry_metadata",
                    side_effect=replace_after_observation,
                ):
                    result = prune_pre_reviewer_turn_state.prune(fd, now)
            finally:
                os.close(fd)

            self.assertTrue(result.success)
            self.assertTrue(replaced)
            self.assertEqual(result.removed, 0)
            self.assertEqual(capture.read_bytes(), b"fresh")

    def test_busy_publication_lock_skips_expired_entry_without_waiting(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            old = state_dir / "claim-turn-old"
            old.touch()
            now = 10_000
            os.utime(old, (now - 3601, now - 3601))
            publication_fd = self.open_directory(state_dir)
            prune_fd = self.open_directory(state_dir)
            results: list[prune_pre_reviewer_turn_state.PruneResult] = []

            def run_prune() -> None:
                results.append(prune_pre_reviewer_turn_state.prune(prune_fd, now))

            worker = threading.Thread(target=run_prune)
            try:
                fcntl.flock(publication_fd, fcntl.LOCK_EX)
                worker.start()
                worker.join(timeout=0.5)
                returned_without_waiting = not worker.is_alive()
            finally:
                fcntl.flock(publication_fd, fcntl.LOCK_UN)
                worker.join(timeout=1.0)
                os.close(prune_fd)
                os.close(publication_fd)

            self.assertTrue(returned_without_waiting)
            self.assertEqual(len(results), 1)
            result = results[0]
            self.assertTrue(result.success)
            self.assertEqual(result.removed, 0)
            self.assertTrue(old.exists())

    def test_publication_after_final_metadata_check_cannot_be_unlinked(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            capture = state_dir / "capture-turn-same.json"
            capture.write_bytes(b"old")
            now = 10_000
            os.utime(capture, (now - 3601, now - 3601))
            replacement = state_dir / ".capture-turn-same.json.FRESH"
            replacement.write_bytes(b"fresh")
            os.utime(replacement, (now, now))
            fd = self.open_directory(state_dir)
            real_entry_metadata = prune_pre_reviewer_turn_state._entry_metadata
            metadata_calls = 0
            publisher_blocked = threading.Event()
            publisher_bypassed_lock = threading.Event()
            publisher: threading.Thread | None = None

            def publish() -> None:
                publication_fd = self.open_directory(state_dir)
                try:
                    try:
                        fcntl.flock(
                            publication_fd,
                            fcntl.LOCK_EX | fcntl.LOCK_NB,
                        )
                    except BlockingIOError:
                        publisher_blocked.set()
                        fcntl.flock(publication_fd, fcntl.LOCK_EX)
                    else:
                        publisher_bypassed_lock.set()
                    os.replace(replacement, capture)
                finally:
                    fcntl.flock(publication_fd, fcntl.LOCK_UN)
                    os.close(publication_fd)

            def publish_after_metadata(directory_fd: int, name: str) -> os.stat_result:
                nonlocal metadata_calls, publisher
                metadata = real_entry_metadata(directory_fd, name)
                if name == capture.name:
                    metadata_calls += 1
                    if metadata_calls == 2:
                        publisher = threading.Thread(target=publish)
                        publisher.start()
                        self.assertTrue(publisher_blocked.wait(timeout=1.0))
                return metadata

            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state,
                    "_entry_metadata",
                    side_effect=publish_after_metadata,
                ):
                    result = prune_pre_reviewer_turn_state.prune(fd, now)
            finally:
                os.close(fd)
            if publisher is not None:
                publisher.join(timeout=1.0)

            self.assertEqual(metadata_calls, 2)
            self.assertIsNotNone(publisher)
            self.assertFalse(publisher_bypassed_lock.is_set())
            if publisher is not None:
                self.assertFalse(publisher.is_alive())
            self.assertTrue(result.success)
            self.assertEqual(result.removed, 1)
            self.assertEqual(capture.read_bytes(), b"fresh")

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

    def test_cli_maintenance_serialization_is_nonblocking(self) -> None:
        helper = LIB_ROOT / "prune_pre_reviewer_turn_state.py"
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            old = state_dir / "claim-turn-old"
            old.touch()
            os.utime(old, (1, 1))
            lock = state_dir / prune_pre_reviewer_turn_state.MAINTENANCE_LOCK_NAME
            lock.touch(mode=0o600)
            lock.chmod(0o600)
            lock_fd = os.open(lock, os.O_RDWR | os.O_CLOEXEC)
            directory_fd = self.open_directory(state_dir)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
                result = subprocess.run(
                    [sys.executable, str(helper), str(directory_fd), "10000"],
                    pass_fds=(directory_fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=0.5,
                    check=False,
                )
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                os.close(lock_fd)
                os.close(directory_fd)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
            self.assertTrue(old.exists())

    def test_maintenance_lock_is_released_when_holder_is_killed(self) -> None:
        helper = LIB_ROOT / "prune_pre_reviewer_turn_state.py"
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            old = state_dir / "claim-turn-old"
            old.touch()
            os.utime(old, (1, 1))
            directory_fd = self.open_directory(state_dir)
            ready_read_fd, ready_write_fd = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(ready_read_fd)
                lock_fd = prune_pre_reviewer_turn_state._open_maintenance_lock(
                    directory_fd
                )
                if lock_fd is None:
                    os._exit(2)
                os.write(ready_write_fd, b"ready")
                signal.pause()
                os._exit(3)
            os.close(ready_write_fd)
            try:
                self.assertEqual(os.read(ready_read_fd, 5), b"ready")
                os.kill(pid, signal.SIGKILL)
                waited, status = os.waitpid(pid, 0)
                self.assertEqual(waited, pid)
                self.assertTrue(os.WIFSIGNALED(status))
                result = subprocess.run(
                    [sys.executable, str(helper), str(directory_fd), "10000"],
                    pass_fds=(directory_fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=0.5,
                    check=False,
                )
            finally:
                os.close(ready_read_fd)
                os.close(directory_fd)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
            self.assertFalse(old.exists())

    def test_cli_rejects_non_private_maintenance_lock_without_following_it(self) -> None:
        helper = LIB_ROOT / "prune_pre_reviewer_turn_state.py"
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            state_dir = root / "state"
            state_dir.mkdir(mode=0o700)
            victim = root / "victim"
            victim.write_bytes(b"UNCHANGED")
            (state_dir / prune_pre_reviewer_turn_state.MAINTENANCE_LOCK_NAME).symlink_to(
                victim
            )
            old = state_dir / "claim-turn-old"
            old.touch()
            os.utime(old, (1, 1))
            directory_fd = self.open_directory(state_dir)
            try:
                result = subprocess.run(
                    [sys.executable, str(helper), str(directory_fd), "10000"],
                    pass_fds=(directory_fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=0.5,
                    check=False,
                )
            finally:
                os.close(directory_fd)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
            self.assertEqual(victim.read_bytes(), b"UNCHANGED")
            self.assertTrue(old.exists())

    def test_each_incremental_batch_has_a_population_independent_visit_bound(self) -> None:
        for population in (10, 1_000, 4_000):
            with self.subTest(population=population), tempfile.TemporaryDirectory() as temp_root:
                state_dir = Path(temp_root)
                state_dir.chmod(0o700)
                now = 10_000
                for index in range(population):
                    path = state_dir / f"claim-turn-old-{index}"
                    path.touch()
                    os.utime(path, (now - 3601, now - 3601))
                fd = self.open_directory(state_dir)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    result = prune_pre_reviewer_turn_state.prune(fd, now)
                    self.assertTrue(result.success)
                    self.assertLessEqual(
                        result.visited,
                        prune_pre_reviewer_turn_state.MAX_VISITED_PER_BATCH,
                    )
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    os.close(fd)

    def test_incremental_cursor_eventually_visits_all_expired_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            now = 10_000
            population = 1_000
            for index in range(population):
                path = state_dir / f"claim-turn-old-{index}"
                path.touch()
                os.utime(path, (now - 3601, now - 3601))
            fd = self.open_directory(state_dir)
            try:
                for _attempt in range(32):
                    result = prune_pre_reviewer_turn_state.prune(fd, now)
                    self.assertTrue(result.success)
                    if result.complete:
                        break
                self.assertFalse(
                    any(path.name.startswith("claim-turn-old-") for path in state_dir.iterdir())
                )
            finally:
                os.close(fd)

    def test_fifo_cursor_is_repaired_without_blocking(self) -> None:
        helper = LIB_ROOT / "prune_pre_reviewer_turn_state.py"
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            cursor = state_dir / prune_pre_reviewer_turn_state.CURSOR_NAME
            os.mkfifo(cursor, 0o600)
            fd = self.open_directory(state_dir)
            try:
                result = subprocess.run(
                    [sys.executable, str(helper), str(fd), "10000"],
                    pass_fds=(fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=0.5,
                    check=False,
                )
            finally:
                os.close(fd)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assert_valid_cursor_or_absent(state_dir)

    def test_huge_cursor_is_repaired_to_a_valid_state(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            cursor = state_dir / prune_pre_reviewer_turn_state.CURSOR_NAME
            cursor.write_text("9" * 63 + "\n", encoding="ascii")
            cursor.chmod(0o600)
            fd = self.open_directory(state_dir)
            try:
                result = prune_pre_reviewer_turn_state.prune(fd, 10_000)
            finally:
                os.close(fd)
            self.assertTrue(result.success)
            self.assert_valid_cursor_or_absent(state_dir)

    def test_hard_link_cursor_never_truncates_its_other_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            root = Path(temp_root)
            state_dir = root / "state"
            state_dir.mkdir(mode=0o700)
            victim = root / "victim"
            victim.write_bytes(b"DO_NOT_TRUNCATE")
            victim.chmod(0o600)
            for index in range(300):
                (state_dir / f"unrelated-{index}").touch()
            os.link(victim, state_dir / prune_pre_reviewer_turn_state.CURSOR_NAME)
            fd = self.open_directory(state_dir)
            try:
                result = prune_pre_reviewer_turn_state.prune(fd, 10_000)
            finally:
                os.close(fd)
            self.assertTrue(result.success)
            self.assertEqual(victim.read_bytes(), b"DO_NOT_TRUNCATE")
            self.assert_valid_cursor_or_absent(state_dir)

    def test_abrupt_cursor_publication_keeps_pending_artifacts_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            fd = self.open_directory(state_dir)
            try:
                for cursor in (11, 22, 33):
                    pid = os.fork()
                    if pid == 0:
                        real_rename = os.rename

                        def stop_before_rename(*args, **kwargs):
                            del args, kwargs
                            os.kill(os.getpid(), signal.SIGSTOP)
                            real_rename()

                        prune_pre_reviewer_turn_state.os.rename = stop_before_rename
                        prune_pre_reviewer_turn_state._write_cursor(fd, cursor)
                        os._exit(97)
                    waited, status = os.waitpid(pid, os.WUNTRACED)
                    self.assertEqual(waited, pid)
                    self.assertTrue(os.WIFSTOPPED(status))
                    os.kill(pid, signal.SIGKILL)
                    self.assertEqual(os.waitpid(pid, 0)[0], pid)
            finally:
                os.close(fd)

            pending = [
                path.name
                for path in state_dir.iterdir()
                if path.name != prune_pre_reviewer_turn_state.CURSOR_NAME
            ]
            self.assertLessEqual(len(pending), 1)
            self.assertEqual(
                pending,
                [prune_pre_reviewer_turn_state.CURSOR_PENDING_NAME],
            )

    def test_missing_getdents64_symbol_fails_boundedly(self) -> None:
        class MissingGetdents:
            pass

        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            fd = self.open_directory(state_dir)
            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state.ctypes,
                    "CDLL",
                    return_value=MissingGetdents(),
                ):
                    result = prune_pre_reviewer_turn_state.prune(fd, 10_000)
            finally:
                os.close(fd)
            self.assertFalse(result.success)

    def test_one_getdents_call_per_invocation(self) -> None:
        class FakeGetdents:
            def __init__(self) -> None:
                self.calls = 0
                self.argtypes: object = None
                self.restype: object = None

            def __call__(self, _fd: int, buffer: object, _size: int) -> int:
                self.calls += 1
                name = b"x\0"
                record_length = 24
                record = prune_pre_reviewer_turn_state._DIRENT_HEADER.pack(
                    1, 24, record_length, 8
                ) + name
                record += b"\0" * (record_length - len(record))
                ctypes.memmove(buffer, record, record_length)
                return record_length

        fake_getdents = FakeGetdents()
        fake_libc = type("FakeLibc", (), {})()
        fake_libc.getdents64 = fake_getdents
        with tempfile.TemporaryDirectory() as temp_root:
            state_dir = Path(temp_root)
            state_dir.chmod(0o700)
            fd = self.open_directory(state_dir)
            try:
                with mock.patch.object(
                    prune_pre_reviewer_turn_state.ctypes,
                    "CDLL",
                    return_value=fake_libc,
                ):
                    result = prune_pre_reviewer_turn_state.prune(fd, 10_000)
            finally:
                os.close(fd)
        self.assertTrue(result.success)
        self.assertEqual(fake_getdents.calls, 1)


if __name__ == "__main__":
    unittest.main()
