#!/usr/bin/env python3
"""Hard admission bounds before shell parsing and transcript classification."""

from __future__ import annotations

from pathlib import Path
import os
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


if __name__ == "__main__":
    unittest.main()
