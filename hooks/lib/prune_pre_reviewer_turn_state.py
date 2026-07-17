#!/usr/bin/env python3
"""Cursor-backed bounded cleanup for private current-turn state."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import errno
import fcntl
import os
import re
import stat
import struct
import sys
from collections.abc import Sequence

PRIVATE_MODE = 0o700
MAX_RETAINED_AGE_SECONDS = 3600
DIRENT_BUFFER_BYTES = 4_096
MIN_DIRENT_RECORD_BYTES = 24
MAX_VISITED_PER_BATCH = DIRENT_BUFFER_BYTES // MIN_DIRENT_RECORD_BYTES
CURSOR_NAME = ".prune-cursor"
CURSOR_PENDING_NAME = ".prune-cursor.pending"
MAINTENANCE_LOCK_NAME = ".prune-maintenance-lock"
MAX_CURSOR_BYTES = 64
MAX_DIRECTORY_OFFSET = (1 << 63) - 1
_DIRENT_HEADER = struct.Struct("=QqHB")
_PRUNABLE_NAME: re.Pattern[str] = re.compile(
    r"(?:capture-turn-[A-Za-z0-9_-]+\.json|"
    r"claim-turn-[A-Za-z0-9_-]+|"
    r"\.capture-turn-[A-Za-z0-9_-]+\."
    r"(?:redacted|capped|json|validated|consumed|prompt)\."
    r"[A-Za-z0-9]+)"
)


def is_prunable_name(name: str) -> bool:
    return _PRUNABLE_NAME.fullmatch(name) is not None


def _is_private_current_user_directory(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == PRIVATE_MODE
    )


def _is_private_current_user_regular_file(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_nlink == 1
    )


def _open_maintenance_lock(directory_fd: int) -> int | None:
    flags = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    lock_fd: int | None = None
    try:
        lock_fd = os.open(
            MAINTENANCE_LOCK_NAME,
            flags | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=directory_fd,
        )
        os.fchmod(lock_fd, 0o600)
    except FileExistsError:
        try:
            lock_fd = os.open(
                MAINTENANCE_LOCK_NAME,
                flags,
                dir_fd=directory_fd,
            )
        except OSError:
            return None
    except OSError:
        if lock_fd is not None:
            os.close(lock_fd)
        return None

    try:
        descriptor_metadata = os.fstat(lock_fd)
        path_metadata = os.stat(
            MAINTENANCE_LOCK_NAME,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if (
            not _is_private_current_user_regular_file(descriptor_metadata)
            or descriptor_metadata.st_dev != path_metadata.st_dev
            or descriptor_metadata.st_ino != path_metadata.st_ino
        ):
            os.close(lock_fd)
            return None
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(lock_fd)
            return None
        return lock_fd
    except OSError:
        os.close(lock_fd)
        return None


@dataclass(frozen=True)
class PruneResult:
    success: bool
    visited: int = 0
    removed: int = 0
    complete: bool = False

    def __bool__(self) -> bool:
        return self.success


def _discard_cursor(fd: int) -> None:
    try:
        os.unlink(CURSOR_NAME, dir_fd=fd)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _read_cursor(fd: int) -> int:
    try:
        cursor_fd = os.open(
            CURSOR_NAME,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=fd,
        )
    except FileNotFoundError:
        return 0
    except OSError:
        _discard_cursor(fd)
        return 0
    try:
        metadata = os.fstat(cursor_fd)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
        ):
            _discard_cursor(fd)
            return 0
        raw = os.read(cursor_fd, MAX_CURSOR_BYTES + 1)
        if not raw.isascii() or not raw.strip().isdigit():
            _discard_cursor(fd)
            return 0
        cursor = int(raw.strip(), 10)
        if len(raw) > MAX_CURSOR_BYTES or cursor > MAX_DIRECTORY_OFFSET:
            _discard_cursor(fd)
            return 0
        return cursor
    finally:
        os.close(cursor_fd)


def _write_cursor(fd: int, cursor: int) -> bool:
    try:
        os.unlink(CURSOR_PENDING_NAME, dir_fd=fd)
    except FileNotFoundError:
        pass
    except OSError:
        return False
    if cursor == 0:
        try:
            os.unlink(CURSOR_NAME, dir_fd=fd)
        except FileNotFoundError:
            pass
        except OSError:
            return False
        return True
    temporary = CURSOR_PENDING_NAME
    try:
        cursor_fd = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
            dir_fd=fd,
        )
    except OSError:
        return False
    published = False
    try:
        payload = f"{cursor}\n".encode()
        if os.write(cursor_fd, payload) != len(payload):
            return False
        os.fchmod(cursor_fd, 0o600)
        metadata = os.fstat(cursor_fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            return False
        os.rename(
            temporary,
            CURSOR_NAME,
            src_dir_fd=fd,
            dst_dir_fd=fd,
        )
        published = True
    except OSError:
        return False
    finally:
        os.close(cursor_fd)
        if not published:
            try:
                os.unlink(temporary, dir_fd=fd)
            except OSError:
                pass
    return published


def _read_directory_batch(fd: int, cursor: int) -> tuple[list[str], int, bool, int]:
    scan_fd = os.open(
        ".",
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
        dir_fd=fd,
    )
    try:
        os.lseek(scan_fd, cursor, os.SEEK_SET)
        libc = ctypes.CDLL(None, use_errno=True)
        try:
            getdents64 = libc.getdents64
        except AttributeError as error:
            raise OSError(errno.ENOSYS, "getdents64 is unavailable") from error
        getdents64.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t)
        getdents64.restype = ctypes.c_ssize_t
        buffer = ctypes.create_string_buffer(DIRENT_BUFFER_BYTES)
        count = getdents64(scan_fd, buffer, DIRENT_BUFFER_BYTES)
        if count < 0:
            raise OSError(ctypes.get_errno(), "getdents64 failed")
        if count == 0:
            return [], 0, True, 0
        raw = buffer.raw[:count]
        names: list[str] = []
        position = 0
        next_cursor = cursor
        visited = 0
        while position < count:
            record = _DIRENT_HEADER.unpack_from(raw, position)
            _inode, next_cursor, record_length, _entry_type = record
            if (
                record_length < MIN_DIRENT_RECORD_BYTES
                or position + record_length > count
            ):
                raise OSError(errno.EIO, "invalid getdents64 record")
            name_start = position + _DIRENT_HEADER.size
            name_end = raw.find(b"\0", name_start, position + record_length)
            if name_end < 0:
                raise OSError(errno.EIO, "unterminated getdents64 name")
            name = os.fsdecode(raw[name_start:name_end])
            if name not in (".", ".."):
                names.append(name)
            visited += 1
            position += record_length
        return names, next_cursor, False, visited
    finally:
        os.close(scan_fd)


def _entry_metadata(fd: int, name: str) -> os.stat_result:
    return os.stat(name, dir_fd=fd, follow_symlinks=False)


def _delete_after_revalidation(
    lock_acquired: bool,
    _observed_selected: bool,
    current_selected: bool,
) -> bool:
    return lock_acquired and current_selected


def _metadata_is_prunable(name: str, metadata: os.stat_result, now: int) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and is_prunable_name(name)
        and now - int(metadata.st_mtime) > MAX_RETAINED_AGE_SECONDS
    )


def _remove_after_revalidation(
    fd: int,
    name: str,
    now: int,
    observed_selected: bool,
) -> bool:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    try:
        try:
            current_metadata = _entry_metadata(fd, name)
        except OSError:
            return False
        current_selected = _metadata_is_prunable(name, current_metadata, now)
        if not _delete_after_revalidation(
            True,
            observed_selected,
            current_selected,
        ):
            return False
        try:
            os.unlink(name, dir_fd=fd)
        except OSError:
            return False
        return True
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass


def prune(fd: int, now: int) -> PruneResult:
    """Prune expired state relative to one validated directory descriptor."""
    if type(fd) is not int or type(now) is not int:
        return PruneResult(False)
    try:
        directory_metadata = os.fstat(fd)
    except OSError:
        return PruneResult(False)
    if not _is_private_current_user_directory(directory_metadata):
        return PruneResult(False)

    try:
        names, next_cursor, complete, visited = _read_directory_batch(
            fd, _read_cursor(fd)
        )
    except (OSError, OverflowError):
        return PruneResult(False)
    removed = 0
    for name in names:
        if not is_prunable_name(name):
            continue
        try:
            metadata = _entry_metadata(fd, name)
        except OSError:
            continue
        observed_selected = _metadata_is_prunable(name, metadata, now)
        if not observed_selected:
            continue
        if not _remove_after_revalidation(
            fd,
            name,
            now,
            observed_selected,
        ):
            continue
        removed += 1
    # Directory offsets are opaque and may be invalidated when entries in the
    # scanned batch are removed.  Restart the next bounded pass so deletion
    # cannot make a later expired entry permanently unreachable.
    if removed:
        next_cursor = 0
        complete = False
    if not _write_cursor(fd, next_cursor):
        return PruneResult(False, visited, removed, complete)
    return PruneResult(True, visited, removed, complete)


def main(argv: Sequence[str]) -> int:
    if len(argv) != 3:
        return 1
    try:
        fd = int(argv[1], 10)
        now = int(argv[2], 10)
    except ValueError:
        return 1
    maintenance_lock_fd = _open_maintenance_lock(fd)
    if maintenance_lock_fd is None:
        return 0
    try:
        return 0 if prune(fd, now).success else 1
    finally:
        fcntl.flock(maintenance_lock_fd, fcntl.LOCK_UN)
        os.close(maintenance_lock_fd)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
