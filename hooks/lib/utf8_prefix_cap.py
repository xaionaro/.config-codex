#!/usr/bin/env python3

from __future__ import annotations

import codecs
import os
from collections.abc import Callable

BYTE_LIMIT = 4000
ReadFunction = Callable[[int, int], bytes]


def read_at_most(
    file_descriptor: int,
    byte_limit: int,
    reader: ReadFunction = os.read,
) -> bytes:
    chunks: list[bytes] = []
    remaining = byte_limit
    while remaining > 0:
        chunk = reader(file_descriptor, remaining)
        if not chunk:
            break
        if len(chunk) > remaining:
            raise ValueError("reader returned more bytes than requested")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def longest_complete_utf8_prefix(data: bytes) -> bytes:
    decoder_factory = codecs.getincrementaldecoder("utf-8")
    decoder = decoder_factory(errors="strict")
    decoder.decode(data, final=False)
    buffered, _ = decoder.getstate()
    if len(buffered) > 3 or (buffered and not data.endswith(buffered)):
        raise UnicodeError("UTF-8 decoder buffered a non-terminal suffix")
    if not buffered:
        return data
    return data[: -len(buffered)]


def write_all(file_descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(file_descriptor, data[offset:])
        if written == 0:
            raise OSError("output descriptor accepted zero bytes")
        offset += written


def main() -> int:
    bounded_input = read_at_most(0, BYTE_LIMIT)
    try:
        prefix = longest_complete_utf8_prefix(bounded_input)
    except UnicodeDecodeError:
        return 1
    write_all(1, prefix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
