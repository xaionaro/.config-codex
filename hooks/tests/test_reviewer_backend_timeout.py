#!/usr/bin/env python3
"""Whole-backend deadlines include resistant curl descendants."""

from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "hooks/lib/reviewer-call.sh"


class ReviewerBackendTimeoutTests(unittest.TestCase):
    def test_both_backends_kill_term_resistant_curl_within_outer_bound(self) -> None:
        for backend in ("ollama", "opencode-zen"):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory(
                prefix="reviewer-timeout-"
            ) as temporary:
                root = Path(temporary)
                fake_bin = root / "bin"
                fake_bin.mkdir()
                pid_file = root / "curl.pid"
                curl = fake_bin / "curl"
                curl.write_text(
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' \"$$\" >\"$GENERATED_CURL_PID\"\n"
                    "trap '' TERM\n"
                    "exec sleep 90\n",
                    encoding="utf-8",
                )
                curl.chmod(0o755)
                for name in ("system", "user", "schema"):
                    (root / name).write_text("{}\n", encoding="utf-8")
                body = """
source "$1"
REVIEWER_BACKEND="$2"
REVIEWER_OLLAMA_MODEL=generated
REVIEWER_OLLAMA_HOST=http://127.0.0.1
REVIEWER_OPENCODE_MODEL=generated
REVIEWER_OPENCODE_HOST=http://127.0.0.1
reviewer_call_chat generated "$3" "$4" "$5" 3
"""
                started = time.monotonic()
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        body,
                        "reviewer-timeout",
                        str(LIBRARY),
                        backend,
                        str(root / "system"),
                        str(root / "user"),
                        str(root / "schema"),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                    env={
                        **os.environ,
                        "PATH": f"{fake_bin}:/usr/bin:/bin",
                        "GENERATED_CURL_PID": str(pid_file),
                    },
                )
                elapsed = time.monotonic() - started
                self.assertNotEqual(result.returncode, 0)
                self.assertLess(elapsed, 4.5)
                self.assertTrue(pid_file.is_file())
                curl_pid = int(pid_file.read_text(encoding="ascii"))
                deadline = time.monotonic() + 0.5
                while (
                    Path(f"/proc/{curl_pid}").exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertFalse(Path(f"/proc/{curl_pid}").exists())


if __name__ == "__main__":
    unittest.main()
