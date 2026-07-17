#!/usr/bin/env python3
"""Read hook admission data without ever retaining more than 64 KiB."""

from __future__ import annotations

import errno
import os
from pathlib import Path
import stat
import sys
from collections.abc import Sequence


INPUT_BUDGET = 65_536


def _emit_bounded(data: bytes) -> int:
    if len(data) > INPUT_BUDGET:
        return 2
    if b"\0" in data:
        return 2
    try:
        data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return 2
    view = memoryview(data)
    while view:
        written = os.write(1, view)
        view = view[written:]
    return 0


def read_stdin() -> int:
    retained = bytearray()
    while len(retained) <= INPUT_BUDGET:
        chunk = os.read(0, min(4096, INPUT_BUDGET + 1 - len(retained)))
        if not chunk:
            return _emit_bounded(bytes(retained))
        retained.extend(chunk)
    return 2


def read_first_record(path: Path) -> int:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(path, flags)
    except OSError:
        return 2
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            return 2
        retained = bytearray()
        while len(retained) <= INPUT_BUDGET and b"\n" not in retained:
            chunk = os.read(fd, min(4096, INPUT_BUDGET + 1 - len(retained)))
            if not chunk:
                break
            retained.extend(chunk)
    except OSError as error:
        if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
            return 2
        return 2
    finally:
        os.close(fd)
    record, separator, _remainder = bytes(retained).partition(b"\n")
    if not separator and len(retained) > INPUT_BUDGET:
        return 2
    return _emit_bounded(record)


def main(argv: Sequence[str]) -> int:
    if argv == ["stdin"]:
        return read_stdin()
    if len(argv) == 2 and argv[0] == "first-record":
        return read_first_record(Path(argv[1]))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
