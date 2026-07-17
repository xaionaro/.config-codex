#!/usr/bin/env python3
"""Cheap request guards precede transcript and reviewer state I/O."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "hooks/lib/edit-bash-pre-reviewer-worker.sh"


class PreReviewerEarlyAdmissionTests(unittest.TestCase):
    def test_unusable_request_fields_skip_transcript_state_and_backend(self) -> None:
        real_python = shutil.which("python3") or "/usr/bin/python3"
        cases: tuple[tuple[str, object, str], ...] = (
            ("invalid-session", "valid-turn", "Read"),
            ("irrelevant-tool", "valid-turn", "Read"),
            ("absent-turn", None, "Bash"),
            ("non-string-turn", {"bad": True}, "Bash"),
            ("oversized-ascii", "x" * 4097, "Bash"),
            ("oversized-multibyte", "é" * 2049, "Bash"),
        )
        for label, turn_id, tool_name in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix="pre-reviewer-early-admission-"
            ) as temporary:
                root = Path(temporary)
                home = root / "home"
                sessions = home / ".codex/sessions"
                sessions.mkdir(parents=True)
                transcript = sessions / "valid.jsonl"
                transcript.write_text(
                    '{"type":"session_meta","payload":{"source":"cli"}}\n',
                    encoding="utf-8",
                )
                proof = root / "proof"
                transcript_access = root / "transcript-access"
                backend_access = root / "backend-access"
                bin_dir = root / "bin"
                bin_dir.mkdir()
                python_wrapper = bin_dir / "python3"
                python_wrapper.write_text(
                    "#!/bin/bash\n"
                    "set -euo pipefail\n"
                    "for argument in \"$@\"; do\n"
                    "  if [ \"$argument\" = \"$CODEX_TEST_TRANSCRIPT\" ]; then\n"
                    "    : >\"$CODEX_TEST_TRANSCRIPT_ACCESS\"\n"
                    "  fi\n"
                    "done\n"
                    f'exec "{real_python}" "$@"\n',
                    encoding="utf-8",
                )
                python_wrapper.chmod(0o755)
                payload: dict[str, object] = {
                    "session_id": "bad" if label == "invalid-session" else "t00-session",
                    "tool_name": tool_name,
                    "transcript_path": str(transcript),
                    "tool_input": {"command": "true"},
                }
                if label != "absent-turn":
                    payload["turn_id"] = turn_id

                result = subprocess.run(
                    ["/bin/bash", str(WORKER)],
                    input=json.dumps(payload, ensure_ascii=False).encode(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env={
                        **os.environ,
                        "PATH": f"{bin_dir}:/usr/bin:/bin",
                        "HOME": str(home),
                        "CODEX_HOME": str(ROOT),
                        "CODEX_PROOF_ROOT": str(proof),
                        "CODEX_EDIT_PRE_REVIEWER": "generated:invalid",
                        "CODEX_PRE_REVIEWER_DEBUG_BODY_PATH": str(backend_access),
                        "CODEX_TEST_TRANSCRIPT": str(transcript),
                        "CODEX_TEST_TRANSCRIPT_ACCESS": str(transcript_access),
                        "PYTHONDONTWRITEBYTECODE": "1",
                    },
                    timeout=3.0,
                    check=False,
                )

                self.assertEqual((result.returncode, result.stdout), (0, b""))
                self.assertFalse(transcript_access.exists())
                self.assertFalse(proof.exists())
                self.assertFalse(backend_access.exists())


if __name__ == "__main__":
    unittest.main()
