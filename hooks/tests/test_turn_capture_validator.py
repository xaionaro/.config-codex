#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
sys.path.insert(0, str(LIB_ROOT))

import turn_capture_validator


def capture_bytes(turn_id: str, prompt: object) -> bytes:
    return json.dumps(
        {"turn_id": turn_id, "prompt": prompt},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")


class TurnCaptureValidatorTests(unittest.TestCase):
    def test_valid_capture_preserves_literal_replacement_character(self) -> None:
        data = capture_bytes("turn-valid", "before-�-after")

        result = turn_capture_validator.validate_capture_bytes(data, '"turn-valid"')

        self.assertEqual(result, "before-�-after".encode())

    def test_invalid_utf8_and_duplicate_keys_fail(self) -> None:
        cases = (
            b'{"turn_id":"turn-valid","prompt":"bad\xff"}',
            b'{"turn_id":"turn-valid","prompt":"one","prompt":"two"}',
        )
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    turn_capture_validator.validate_capture_bytes(data, '"turn-valid"')

    def test_exact_turn_id_and_string_prompt_are_required(self) -> None:
        cases = (
            capture_bytes("other", "prompt"),
            capture_bytes("turn-valid", {"not": "a string"}),
        )
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    turn_capture_validator.validate_capture_bytes(data, '"turn-valid"')

    def test_nul_and_oversized_prompts_fail(self) -> None:
        cases = (
            capture_bytes("turn-valid", "before\0after"),
            capture_bytes("turn-valid", "x" * 4001),
        )
        for data in cases:
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError):
                    turn_capture_validator.validate_capture_bytes(data, '"turn-valid"')

    def test_capture_and_turn_id_bounds_are_explicit(self) -> None:
        with self.assertRaises(ValueError):
            turn_capture_validator.validate_capture_bytes(
                b" " * (turn_capture_validator.CAPTURE_JSON_LIMIT + 1),
                '"turn-valid"',
            )
        with self.assertRaises(ValueError):
            turn_capture_validator.validate_capture_bytes(
                capture_bytes("x" * 4097, "prompt"),
                json.dumps("x" * 4097),
            )

    def test_turn_id_uses_nonempty_utf8_byte_bound(self) -> None:
        accepted = (
            "x" * 4095,
            "x" * 4096,
            "é" * 2048,
            "😀" * 1024,
            "x" * 4090 + "é😀",
        )
        rejected = ("", "x" * 4097, "é" * 2049, "😀" * 1025)

        for turn_id in accepted:
            with self.subTest(accepted_bytes=len(turn_id.encode())):
                result = turn_capture_validator.validate_capture_bytes(
                    capture_bytes(turn_id, "prompt"),
                    json.dumps(turn_id, ensure_ascii=False),
                )
                self.assertEqual(result, b"prompt")
        for turn_id in rejected:
            with self.subTest(rejected_bytes=len(turn_id.encode())):
                with self.assertRaises(ValueError):
                    turn_capture_validator.validate_capture_bytes(
                        capture_bytes(turn_id, "prompt"),
                        json.dumps(turn_id, ensure_ascii=False),
                    )

        with self.assertRaises(ValueError):
            turn_capture_validator.validate_capture_bytes(
                capture_bytes("turn-valid", "prompt"),
                '"bad\udcff"',
            )

    def test_cli_outputs_prompt_only_on_success(self) -> None:
        helper = LIB_ROOT / "turn_capture_validator.py"
        valid = subprocess.run(
            [sys.executable, str(helper), '"turn-valid"'],
            input=capture_bytes("turn-valid", "prompt"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        invalid = subprocess.run(
            [sys.executable, str(helper), '"turn-valid"'],
            input=b'{"turn_id":"turn-valid","prompt":"bad\xff"}',
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual((valid.returncode, valid.stdout, valid.stderr), (0, b"prompt", b""))
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual((invalid.stdout, invalid.stderr), (b"", b""))


if __name__ == "__main__":
    unittest.main()
