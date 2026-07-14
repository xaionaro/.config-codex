#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import stat
import sys
from collections.abc import Sequence

PRIVATE_MODE = 0o700
MAX_RETAINED_AGE_SECONDS = 3600
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


def prune(fd: int, now: int) -> bool:
    """Prune expired state relative to one validated directory descriptor."""
    if type(fd) is not int or type(now) is not int:
        return False
    try:
        directory_metadata = os.fstat(fd)
    except OSError:
        return False
    if not _is_private_current_user_directory(directory_metadata):
        return False

    try:
        with os.scandir(fd) as entries:
            for entry in entries:
                if not is_prunable_name(entry.name):
                    continue
                try:
                    metadata = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    continue
                if now - int(metadata.st_mtime) <= MAX_RETAINED_AGE_SECONDS:
                    continue
                try:
                    os.unlink(entry.name, dir_fd=fd)
                except OSError:
                    continue
    except OSError:
        return False
    return True


def main(argv: Sequence[str]) -> int:
    if len(argv) != 3:
        return 1
    try:
        fd = int(argv[1], 10)
        now = int(argv[2], 10)
    except ValueError:
        return 1
    return 0 if prune(fd, now) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
