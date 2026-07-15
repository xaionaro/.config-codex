#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable
from typing import Any

PROMPT_BYTE_LIMIT = 4000
TURN_ID_BYTE_LIMIT = 4096
# Worst case: both bounded strings consist entirely of one-byte characters that
# JSON escapes as six bytes, plus object syntax and conservative headroom.
CAPTURE_JSON_LIMIT = 65536
ReadFunction = Callable[[int, int], bytes]


class CaptureValidationError(ValueError):
    pass


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
            raise CaptureValidationError("reader returned more bytes than requested")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CaptureValidationError("duplicate JSON object key")
        result[key] = value
    return result


def parse_json(text: str) -> Any:
    return json.loads(text, object_pairs_hook=unique_object)


def validate_capture_bytes(data: bytes, expected_turn_id_json: str) -> bytes:
    if len(data) > CAPTURE_JSON_LIMIT:
        raise CaptureValidationError("capture JSON exceeds byte limit")
    try:
        text = data.decode("utf-8", errors="strict")
        expected_turn_id = parse_json(expected_turn_id_json)
        capture = parse_json(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CaptureValidationError("capture is not strict UTF-8 JSON") from error

    if not isinstance(expected_turn_id, str):
        raise CaptureValidationError("expected turn ID is not a string")
    if not expected_turn_id:
        raise CaptureValidationError("expected turn ID is empty")
    if len(expected_turn_id.encode("utf-8")) > TURN_ID_BYTE_LIMIT:
        raise CaptureValidationError("turn ID exceeds byte limit")
    if not isinstance(capture, dict):
        raise CaptureValidationError("capture is not an object")
    if capture.get("turn_id") != expected_turn_id:
        raise CaptureValidationError("capture turn ID mismatch")
    prompt = capture.get("prompt")
    if not isinstance(prompt, str):
        raise CaptureValidationError("capture prompt is not a string")
    if "\0" in prompt:
        raise CaptureValidationError("capture prompt contains NUL")
    prompt_bytes = prompt.encode("utf-8")
    if len(prompt_bytes) > PROMPT_BYTE_LIMIT:
        raise CaptureValidationError("capture prompt exceeds byte limit")
    return prompt_bytes


def write_all(file_descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(file_descriptor, data[offset:])
        if written == 0:
            raise OSError("output descriptor accepted zero bytes")
        offset += written


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 1
    data = read_at_most(0, CAPTURE_JSON_LIMIT + 1)
    try:
        prompt = validate_capture_bytes(data, argv[1])
    except (CaptureValidationError, UnicodeError):
        return 1
    write_all(1, prompt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
