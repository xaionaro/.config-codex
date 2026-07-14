#!/usr/bin/env python3

from __future__ import annotations

import os
import stat
import sys
from collections.abc import Sequence

PRIVATE_MODE = 0o700
_REQUIRED_CALLS = ("open", "fstat", "fchmod", "lstat", "close", "geteuid")
_REQUIRED_FLAGS = ("O_RDONLY", "O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")


def _required_calls_available() -> bool:
    return all(callable(getattr(os, name, None)) for name in _REQUIRED_CALLS)


def _open_flags() -> int | None:
    flags = 0
    for name in _REQUIRED_FLAGS:
        flag = getattr(os, name, None)
        if not isinstance(flag, int):
            return None
        flags |= flag
    return flags


def _is_private_directory(metadata: os.stat_result, effective_uid: int) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == effective_uid
        and stat.S_IMODE(metadata.st_mode) == PRIVATE_MODE
    )


def _same_object(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def migrate(path: os.PathLike[str] | str) -> bool:
    """Privatize one current-user directory without following a pathname link."""
    flags = _open_flags()
    if flags is None or not _required_calls_available():
        return False

    descriptor: int | None = None
    success = False
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        effective_uid = os.geteuid()
        if not stat.S_ISDIR(before.st_mode) or before.st_uid != effective_uid:
            return False
        if stat.S_IMODE(before.st_mode) != PRIVATE_MODE:
            os.fchmod(descriptor, PRIVATE_MODE)

        after = os.fstat(descriptor)
        path_after = os.lstat(path)
        success = (
            _same_object(after, path_after)
            and _is_private_directory(after, effective_uid)
            and _is_private_directory(path_after, effective_uid)
        )
    except OSError:
        success = False
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                success = False
    return success


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        return 1
    try:
        return 0 if migrate(argv[1]) else 1
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
