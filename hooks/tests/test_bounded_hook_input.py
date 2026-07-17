#!/usr/bin/env python3
"""Hard admission bounds before shell parsing and transcript classification."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "hooks/lib/bounded_hook_input.py"
PROMPT = ROOT / "hooks/prompt-task-reminder.sh"
WORKER = ROOT / "hooks/lib/edit-bash-pre-reviewer-worker.sh"
LIMIT = 65_536


class BoundedHookInputTests(unittest.TestCase):
    def run_helper(
        self,
        mode: str,
        data: bytes = b"",
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, str(HELPER), mode],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=1.0,
            check=False,
        )

    def test_stdin_limit_is_exact_and_oversize_is_silent(self) -> None:
        exact = b"x" * LIMIT
        accepted = self.run_helper("stdin", exact)
        self.assertEqual((accepted.returncode, accepted.stdout), (0, exact))

        started = time.monotonic()
        rejected = self.run_helper("stdin", exact + b"x")
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, b"")

    def test_first_record_is_bounded_before_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="bounded-first-record-") as temporary:
            transcript = Path(temporary) / "transcript.jsonl"
            transcript.write_bytes(b"x" * (LIMIT + 1) + b"\n{}\n")
            rejected = subprocess.run(
                [sys.executable, str(HELPER), "first-record", str(transcript)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=1.0,
                check=False,
            )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, b"")

    def test_stdin_rejects_nul_and_non_strict_utf8_but_preserves_replacement(self) -> None:
        malformed = {
            "nul": b'{"value":"a\x00b"}',
            "invalid": b'{"value":"a\xffb"}',
            "truncated": b'{"value":"a\xe2\x82',
        }
        for name, payload in malformed.items():
            with self.subTest(name=name):
                result = self.run_helper("stdin", payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))

        valid = '{"value":"a�b"}'.encode()
        accepted = self.run_helper("stdin", valid)
        self.assertEqual((accepted.returncode, accepted.stdout), (0, valid))

    def test_first_record_rejects_nul_invalid_and_truncated_utf8(self) -> None:
        malformed = (
            b'{"value":"a\x00b"}\n{}\n',
            b'{"value":"a\xffb"}\n{}\n',
            b'{"value":"a\xe2\x82\n{}\n',
        )
        for payload in malformed:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory(
                prefix="bounded-first-record-malformed-"
            ) as temporary:
                transcript = Path(temporary) / "transcript.jsonl"
                transcript.write_bytes(payload)
                result = subprocess.run(
                    [sys.executable, str(HELPER), "first-record", str(transcript)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=1.0,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_admission_hooks_bound_stdin_before_shell_substitution(self) -> None:
        for path in (PROMPT, WORKER):
            with self.subTest(path=path):
                source = path.read_text(encoding="utf-8")
                self.assertIn("bounded_hook_input.py\" stdin", source)
                self.assertNotIn("input=$(cat)", source)

    def test_oversized_hook_json_fails_open_before_session_state(self) -> None:
        payload = b'{"session_id":"generated","padding":"' + b"x" * LIMIT + b'"}'
        for path in (PROMPT, WORKER):
            with self.subTest(path=path), tempfile.TemporaryDirectory(
                prefix="bounded-hook-integration-"
            ) as temporary:
                root = Path(temporary)
                home = root / "home"
                home.mkdir()
                proof = root / "proof"
                started = time.monotonic()
                result = subprocess.run(
                    ["/bin/bash", str(path)],
                    input=payload,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=1.0,
                    check=False,
                    env={
                        **os.environ,
                        "HOME": str(home),
                        "CODEX_PROOF_ROOT": str(proof),
                        "PYTHONDONTWRITEBYTECODE": "1",
                    },
                )
                self.assertLess(time.monotonic() - started, 1.0)
                self.assertEqual((result.returncode, result.stdout), (0, b""))
                self.assertFalse(proof.exists())

    def test_malformed_hook_bytes_fail_open_before_prompt_or_worker_state(self) -> None:
        payloads = (
            b'{"session_id":"t00-session","turn_id":"bad","prompt":"a\x00b"}',
            b'{"session_id":"t00-session","turn_id":"bad","prompt":"a\xffb"}',
            b'{"session_id":"t00-session","turn_id":"bad","prompt":"a\xe2\x82',
        )
        for path in (PROMPT, WORKER):
            for payload in payloads:
                with self.subTest(path=path, payload=payload), tempfile.TemporaryDirectory(
                    prefix="bounded-hook-malformed-"
                ) as temporary:
                    root = Path(temporary)
                    home = root / "home"
                    home.mkdir()
                    proof = root / "proof"
                    result = subprocess.run(
                        ["/bin/bash", str(path)],
                        input=payload,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=1.0,
                        check=False,
                        env={
                            **os.environ,
                            "HOME": str(home),
                            "CODEX_PROOF_ROOT": str(proof),
                            "PYTHONDONTWRITEBYTECODE": "1",
                        },
                    )
                    self.assertEqual((result.returncode, result.stdout), (0, b""))
                    self.assertFalse(proof.exists())

    def test_valid_replacement_character_is_preserved_in_prompt_state(self) -> None:
        with tempfile.TemporaryDirectory(prefix="bounded-hook-replacement-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            proof = root / "proof"
            payload = json.dumps(
                {
                    "session_id": "t00-session",
                    "turn_id": "replacement",
                    "prompt": "a�b",
                    "cwd": str(ROOT),
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
            result = subprocess.run(
                ["/bin/bash", str(PROMPT)],
                input=payload,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=1.0,
                check=False,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "CODEX_PROOF_ROOT": str(proof),
                    "PYTHONDONTWRITEBYTECODE": "1",
                },
            )
            self.assertEqual((result.returncode, result.stdout), (0, b""))
            captures = list((proof / "pre-reviewer/t00-session").glob("capture-turn-*.json"))
            self.assertEqual(len(captures), 1)
            self.assertEqual(json.loads(captures[0].read_text())["prompt"], "a�b")

    def test_malformed_first_record_prevents_worker_decision_and_state(self) -> None:
        records = (
            b'{"type":"session_meta","value":"a\x00b"}\n',
            b'{"type":"session_meta","value":"a\xffb"}\n',
            b'{"type":"session_meta","value":"a\xe2\x82',
            b'{"type":\n',
        )
        for record in records:
            with self.subTest(record=record), tempfile.TemporaryDirectory(
                prefix="bounded-worker-record-"
            ) as temporary:
                root = Path(temporary)
                home = root / "home"
                sessions = home / ".codex" / "sessions"
                sessions.mkdir(parents=True)
                transcript = sessions / "generated.jsonl"
                transcript.write_bytes(record)
                proof = root / "proof"
                payload = json.dumps(
                    {
                        "session_id": "t00-session",
                        "turn_id": "bad-record",
                        "tool_name": "Bash",
                        "transcript_path": str(transcript),
                        "tool_input": {"command": "true"},
                    },
                    separators=(",", ":"),
                ).encode()
                result = subprocess.run(
                    ["/bin/bash", str(WORKER)],
                    input=payload,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=1.0,
                    check=False,
                    env={
                        **os.environ,
                        "HOME": str(home),
                        "CODEX_PROOF_ROOT": str(proof),
                        "CODEX_EDIT_PRE_REVIEWER": "ollama:http://127.0.0.1:1/generated",
                        "CODEX_PRE_REVIEWER_FAKE_RESULT": '{"verdict":"deny","reason":"bad"}',
                        "PYTHONDONTWRITEBYTECODE": "1",
                    },
                )
                self.assertEqual((result.returncode, result.stdout), (0, b""))
                self.assertFalse(proof.exists())


if __name__ == "__main__":
    unittest.main()
