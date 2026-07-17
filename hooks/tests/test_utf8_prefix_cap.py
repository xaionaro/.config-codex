#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOKS_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = HOOKS_ROOT / "lib"
ROOT = HOOKS_ROOT.parent
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

    def test_worker_preserves_strict_utf8_when_four_byte_codepoint_crosses_cap(self) -> None:
        prompt_hook = HOOKS_ROOT / "prompt-task-reminder.sh"
        worker = LIB_ROOT / "edit-bash-pre-reviewer-worker.sh"
        with tempfile.TemporaryDirectory(prefix="worker-utf8-cap-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            proof = root / "proof"
            environment = {
                **os.environ,
                "HOME": str(home),
                "CODEX_HOME": str(ROOT),
                "CODEX_PROOF_ROOT": str(proof),
                "CODEX_EDIT_PRE_REVIEWER": "ollama:http://127.0.0.1:1/generated",
                "CODEX_PRE_REVIEWER_FAKE_RESULT": '{"verdict":"allow","reason":"generated"}',
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            prompt = json.dumps(
                {
                    "session_id": "t00-session",
                    "turn_id": "utf8-boundary",
                    "prompt": "generated prompt",
                    "cwd": str(ROOT),
                },
                separators=(",", ":"),
            ).encode()
            prompt_result = subprocess.run(
                ["/bin/bash", str(prompt_hook)],
                input=prompt,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual((prompt_result.returncode, prompt_result.stdout), (0, b""))

            tool_input = {"command": "x" * 3986 + "😀" + "tail"}
            compact = json.dumps(
                tool_input,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
            emoji_offset = compact.index("😀".encode())
            self.assertLess(emoji_offset, 4000)
            self.assertGreater(emoji_offset + 4, 4000)
            expected = utf8_prefix_cap.longest_complete_utf8_prefix(compact[:4000])
            body = root / "reviewer-body.bin"
            environment["CODEX_PRE_REVIEWER_DEBUG_BODY_PATH"] = str(body)
            tool = json.dumps(
                {
                    "session_id": "t00-session",
                    "turn_id": "utf8-boundary",
                    "tool_name": "Bash",
                    "cwd": str(ROOT),
                    "tool_input": tool_input,
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
            worker_result = subprocess.run(
                ["/bin/bash", str(worker)],
                input=tool,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(worker_result.returncode, 0, worker_result.stderr.decode())
            body_bytes = body.read_bytes()
            body_text = body_bytes.decode("utf-8", errors="strict")
            transported = body_text.split("TOOL INPUT: ", 1)[1].rstrip("\n").encode()
            self.assertEqual(transported, expected)
            self.assertLessEqual(len(transported), 4000)
            self.assertNotIn("�".encode(), transported)
            self.assertNotIn("head -c 4000", worker.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
