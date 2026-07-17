#!/usr/bin/env python3
"""Canonical transcript admission is shared by all hook classifiers."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / "hooks/lib/codex-proof-state.sh"
HELPERS = (
    "codex_hook_transcript_first_record_is_admissible",
    "codex_hook_is_subagent_context",
    "codex_hook_parent_session_id",
)
SUBAGENT_RECORD = (
    b'{"type":"session_meta","payload":{"source":{"subagent":'
    b'{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}\n'
)


def invoke(
    helper: str,
    transcript: Path | str,
    home: Path,
) -> subprocess.CompletedProcess[bytes]:
    hook_input = json.dumps(
        {"transcript_path": str(transcript)},
        separators=(",", ":"),
    )
    return subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; "$2" "$3"',
            "bash",
            str(STATE),
            helper,
            hook_input,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "HOME": str(home),
            "PYTHONDONTWRITEBYTECODE": "1",
        },
        timeout=3.0,
        check=False,
    )


class TranscriptAdmissionTests(unittest.TestCase):
    def assert_all_reject(
        self,
        transcript: Path | str,
        home: Path,
    ) -> None:
        for helper in HELPERS:
            with self.subTest(helper=helper, transcript=transcript):
                result = invoke(helper, transcript, home)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_valid_canonical_transcript_is_shared_by_all_helpers(self) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            home = Path(temporary) / "home"
            sessions = home / ".codex/sessions"
            sessions.mkdir(parents=True)
            transcript = sessions / "valid.jsonl"
            transcript.write_bytes(SUBAGENT_RECORD + b'{"type":"user"}\n')

            admission = invoke(HELPERS[0], transcript, home)
            subagent = invoke(HELPERS[1], transcript, home)
            parent = invoke(HELPERS[2], transcript, home)

            self.assertEqual((admission.returncode, admission.stdout), (0, b""))
            self.assertEqual((subagent.returncode, subagent.stdout), (0, b""))
            self.assertEqual((parent.returncode, parent.stdout), (0, b"parent-session\n"))

    def test_trusted_codex_home_alias_does_not_weaken_below_root_nofollow(self) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            root = Path(temporary)
            home = root / "home"
            physical_codex = root / "physical-codex"
            sessions = physical_codex / "sessions"
            sessions.mkdir(parents=True)
            home.mkdir()
            (home / ".codex").symlink_to(physical_codex, target_is_directory=True)
            transcript = home / ".codex/sessions/valid.jsonl"
            transcript.write_bytes(SUBAGENT_RECORD)

            admission = invoke(HELPERS[0], transcript, home)
            parent = invoke(HELPERS[2], transcript, home)

            self.assertEqual((admission.returncode, admission.stdout), (0, b""))
            self.assertEqual((parent.returncode, parent.stdout), (0, b"parent-session\n"))

    def test_nonexistent_and_nonregular_transcripts_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            home = Path(temporary) / "home"
            sessions = home / ".codex/sessions"
            sessions.mkdir(parents=True)
            self.assert_all_reject(sessions / "missing.jsonl", home)
            nonregular = sessions / "directory.jsonl"
            nonregular.mkdir()
            self.assert_all_reject(nonregular, home)

    def test_dot_segment_and_symlink_escapes_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            root = Path(temporary)
            home = root / "home"
            sessions = home / ".codex/sessions"
            sessions.mkdir(parents=True)
            outside = home / ".codex/outside.jsonl"
            outside.write_bytes(SUBAGENT_RECORD)

            traversed = sessions / ".." / "outside.jsonl"
            self.assert_all_reject(traversed, home)

            intermediate = sessions / "linked"
            intermediate.symlink_to(outside.parent, target_is_directory=True)
            self.assert_all_reject(intermediate / outside.name, home)

            final = sessions / "final.jsonl"
            final.symlink_to(outside)
            self.assert_all_reject(final, home)

    def test_raw_empty_and_dot_components_are_rejected_before_normalization(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            home = Path(temporary) / "home"
            sessions = home / ".codex/sessions"
            nested = sessions / "nested"
            nested.mkdir(parents=True)
            transcript = nested / "valid.jsonl"
            transcript.write_bytes(SUBAGENT_RECORD)
            raw_spellings = (
                f"{sessions}//nested/valid.jsonl",
                f"{sessions}/./nested/valid.jsonl",
                f"{transcript}/.",
                f"{sessions}/nested//valid.jsonl",
                f"{sessions}/nested/./valid.jsonl",
            )
            for raw_spelling in raw_spellings:
                with self.subTest(raw_spelling=raw_spelling):
                    self.assert_all_reject(raw_spelling, home)

    def test_shell_transformed_and_control_paths_are_rejected_by_all_helpers(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="transcript-admission-") as temporary:
            home = Path(temporary) / "home"
            sessions = home / ".codex/sessions"
            sessions.mkdir(parents=True)
            transcript = sessions / "valid.jsonl"
            transcript.write_bytes(SUBAGENT_RECORD)
            suffixes = ("\0", "\n", "\n\n", "\r", "\t", "\x1f", "\x7f", "\x9f")
            for suffix in suffixes:
                with self.subTest(codepoints=tuple(map(ord, suffix))):
                    self.assert_all_reject(f"{transcript}{suffix}", home)

    def test_malformed_nul_and_invalid_utf8_records_are_rejected(self) -> None:
        records = (
            b'{"type":\n',
            b'{"type":"session_meta","value":"a\x00b"}\n',
            b'{"type":"session_meta","value":"a\xffb"}\n',
        )
        for record in records:
            with self.subTest(record=record), tempfile.TemporaryDirectory(
                prefix="transcript-admission-"
            ) as temporary:
                home = Path(temporary) / "home"
                sessions = home / ".codex/sessions"
                sessions.mkdir(parents=True)
                transcript = sessions / "invalid.jsonl"
                transcript.write_bytes(record)
                self.assert_all_reject(transcript, home)


if __name__ == "__main__":
    unittest.main()
