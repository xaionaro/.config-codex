#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
sys.path.insert(0, str(LIB_ROOT))

import utf8_prefix_cap


class ShortReader:
    def __init__(self, data: bytes, chunk_size: int) -> None:
        self._data = data
        self._chunk_size = chunk_size
        self._offset = 0
        self.requests: list[int] = []
        self.returned = 0

    def __call__(self, file_descriptor: int, length: int) -> bytes:
        del file_descriptor
        self.requests.append(length)
        if self._offset == len(self._data):
            return b""

        end = min(self._offset + self._chunk_size, self._offset + length, len(self._data))
        chunk = self._data[self._offset:end]
        self._offset = end
        self.returned += len(chunk)
        return chunk


class Utf8PrefixCapTests(unittest.TestCase):
    def test_short_reads_consume_at_most_the_limit(self) -> None:
        reader = ShortReader(b"x" * 5000, chunk_size=137)

        result = utf8_prefix_cap.read_at_most(9, 4000, reader)

        self.assertEqual(result, b"x" * 4000)
        self.assertEqual(reader.returned, 4000)
        self.assertGreater(len(reader.requests), 1)
        remaining = 4000
        for request in reader.requests:
            self.assertEqual(request, remaining)
            remaining = max(0, remaining - 137)

    def test_empty_short_read_stops_without_retrying(self) -> None:
        calls = 0

        def empty_reader(file_descriptor: int, length: int) -> bytes:
            nonlocal calls
            del file_descriptor, length
            calls += 1
            return b""

        self.assertEqual(utf8_prefix_cap.read_at_most(0, 4000, empty_reader), b"")
        self.assertEqual(calls, 1)

    def test_complete_prefix_boundaries_are_exact_and_maximal(self) -> None:
        cases = {
            "empty": (b"", b""),
            "ascii": (b"x" * 4001, b"x" * 4000),
            "two-byte-cut": (b"x" * 3999 + "é".encode(), b"x" * 3999),
            "two-byte-fits": (b"x" * 3998 + "é".encode() + b"z", b"x" * 3998 + "é".encode()),
            "three-byte-cut": (b"x" * 3998 + "€".encode(), b"x" * 3998),
            "three-byte-fits": (b"x" * 3997 + "€".encode() + b"z", b"x" * 3997 + "€".encode()),
            "four-byte-cut": (b"x" * 3997 + "😀".encode(), b"x" * 3997),
            "four-byte-fits": (b"x" * 3996 + "😀".encode() + b"z", b"x" * 3996 + "😀".encode()),
        }
        for name, (source, expected) in cases.items():
            with self.subTest(name=name):
                bounded = source[:4000]
                prefix = utf8_prefix_cap.longest_complete_utf8_prefix(bounded)
                self.assertEqual(prefix, expected)
                self.assertLessEqual(len(prefix), 4000)
                prefix.decode("utf-8", errors="strict")
                self.assertTrue(source.startswith(prefix))
                remaining = source[len(prefix):].decode("utf-8", errors="strict")
                if remaining:
                    available = 4000 - len(prefix)
                    self.assertGreater(len(remaining[0].encode("utf-8")), available)

    def test_interior_malformed_utf8_fails(self) -> None:
        with self.assertRaises(UnicodeDecodeError):
            utf8_prefix_cap.longest_complete_utf8_prefix(b"valid\xf0(\x8c(invalid")

    def test_literal_replacement_character_is_preserved(self) -> None:
        source = b"prefix-" + "�".encode() + b"-suffix"

        self.assertEqual(utf8_prefix_cap.longest_complete_utf8_prefix(source), source)

    def test_cli_reads_only_4000_bytes_from_fd_zero(self) -> None:
        helper = LIB_ROOT / "utf8_prefix_cap.py"
        completed = subprocess.run(
            [sys.executable, str(helper)],
            input=b"x" * 4001,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, b"x" * 4000)
        self.assertEqual(completed.stderr, b"")

    def test_cli_fails_without_output_for_interior_malformed_utf8(self) -> None:
        helper = LIB_ROOT / "utf8_prefix_cap.py"
        completed = subprocess.run(
            [sys.executable, str(helper)],
            input=b"valid\xffinvalid",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, b"")


if __name__ == "__main__":
    unittest.main()
