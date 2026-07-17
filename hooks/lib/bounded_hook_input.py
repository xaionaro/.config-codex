#!/usr/bin/env python3
"""Read hook admission data without ever retaining more than 64 KiB."""

from __future__ import annotations

import errno
import json
import os
from pathlib import Path
import stat
import sys
from collections.abc import Sequence


INPUT_BUDGET = 65_536


def transcript_relative_parts_are_allowed(parts: Sequence[str]) -> bool:
    return bool(parts) and all(part not in ("", ".", "..") for part in parts)


def transcript_raw_character_is_allowed(character: str) -> bool:
    if len(character) != 1:
        return False
    codepoint = ord(character)
    return codepoint >= 32 and (codepoint < 127 or codepoint > 159)


def transcript_raw_absolute_path_is_allowed(raw_path: str) -> bool:
    if not all(map(transcript_raw_character_is_allowed, raw_path)):
        return False
    if not raw_path.startswith("/"):
        return False
    root_marker, *components = raw_path.split("/")
    return root_marker == "" and transcript_relative_parts_are_allowed(components)


def _decode_bounded(data: bytes) -> str | None:
    if len(data) > INPUT_BUDGET:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None


def _emit_bounded(data: bytes) -> int:
    if _decode_bounded(data) is None:
        return 2
    view = memoryview(data)
    while view:
        written = os.write(1, view)
        view = view[written:]
    return 0


def _read_bounded_stdin() -> bytes | None:
    retained = bytearray()
    while len(retained) <= INPUT_BUDGET:
        chunk = os.read(0, min(4096, INPUT_BUDGET + 1 - len(retained)))
        if not chunk:
            return bytes(retained)
        retained.extend(chunk)
    return None


def read_stdin() -> int:
    data = _read_bounded_stdin()
    return 2 if data is None else _emit_bounded(data)


def _read_first_record(fd: int) -> bytes | None:
    try:
        retained = bytearray()
        while len(retained) <= INPUT_BUDGET and b"\n" not in retained:
            chunk = os.read(fd, min(4096, INPUT_BUDGET + 1 - len(retained)))
            if not chunk:
                break
            retained.extend(chunk)
    except OSError as error:
        if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
            return None
        return None
    record, separator, _remainder = bytes(retained).partition(b"\n")
    if not separator and len(retained) > INPUT_BUDGET:
        return None
    return record


def _open_regular_file(path: Path) -> int | None:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    if stat.S_ISREG(os.fstat(fd).st_mode):
        return fd
    os.close(fd)
    return None


def _open_absolute_directory_without_symlinks(path: Path) -> int | None:
    parts = path.parts
    if not path.is_absolute() or not parts or parts[0] != "/":
        return None
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        directory_fd = os.open("/", flags)
        for part in parts[1:]:
            if not transcript_relative_parts_are_allowed((part,)):
                os.close(directory_fd)
                return None
            next_fd = os.open(part, flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
    except OSError:
        try:
            os.close(directory_fd)
        except UnboundLocalError:
            pass
        return None
    return directory_fd


def _open_contained_transcript(sessions_root: Path, path: Path) -> int | None:
    root_parts = sessions_root.parts
    path_parts = path.parts
    if (
        not sessions_root.is_absolute()
        or not path.is_absolute()
        or path_parts[: len(root_parts)] != root_parts
    ):
        return None
    relative_parts = path_parts[len(root_parts) :]
    if (
        not transcript_relative_parts_are_allowed(relative_parts)
        or not relative_parts[-1].endswith(".jsonl")
    ):
        return None

    try:
        trusted_parent = sessions_root.parent.resolve(strict=True)
    except OSError:
        return None
    directory_fd = _open_absolute_directory_without_symlinks(
        trusted_parent / sessions_root.name
    )
    if directory_fd is None:
        return None
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        for part in relative_parts[:-1]:
            next_fd = os.open(part, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(
            relative_parts[-1],
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        os.close(directory_fd)
        return None
    os.close(directory_fd)
    if stat.S_ISREG(os.fstat(file_fd).st_mode):
        return file_fd
    os.close(file_fd)
    return None


def read_first_record(path: Path) -> int:
    fd = _open_regular_file(path)
    if fd is None:
        return 2
    try:
        record = _read_first_record(fd)
    finally:
        os.close(fd)
    return 2 if record is None else _emit_bounded(record)


def read_transcript_first_record(sessions_root: Path, raw_path: str) -> int:
    if not transcript_raw_absolute_path_is_allowed(raw_path):
        return 2
    path = Path(raw_path)
    fd = _open_contained_transcript(sessions_root, path)
    if fd is None:
        return 2
    try:
        record = _read_first_record(fd)
    finally:
        os.close(fd)
    if record is None or (decoded := _decode_bounded(record)) is None:
        return 2
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError:
        return 2
    return _emit_bounded(record) if isinstance(value, dict) else 2


def read_hook_transcript_first_record(sessions_root: Path) -> int:
    data = _read_bounded_stdin()
    if data is None or (decoded := _decode_bounded(data)) is None:
        return 2
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError:
        return 2
    if not isinstance(value, dict):
        return 2
    raw_path = value.get("transcript_path")
    if not isinstance(raw_path, str) or not raw_path:
        return 2
    return read_transcript_first_record(sessions_root, raw_path)


def main(argv: Sequence[str]) -> int:
    if argv == ["stdin"]:
        return read_stdin()
    if len(argv) == 2 and argv[0] == "first-record":
        return read_first_record(Path(argv[1]))
    if len(argv) == 3 and argv[0] == "transcript-first-record":
        return read_transcript_first_record(Path(argv[1]), argv[2])
    if len(argv) == 2 and argv[0] == "hook-transcript-first-record":
        return read_hook_transcript_first_record(Path(argv[1]))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
