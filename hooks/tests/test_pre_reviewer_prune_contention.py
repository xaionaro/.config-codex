#!/usr/bin/env python3
"""Prompt publication remains available while maintenance pruning is paused."""

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROMPT_HOOK = ROOT / "hooks/prompt-task-reminder.sh"


class PruneContentionTests(unittest.TestCase):
    def test_paused_maintenance_does_not_block_distinct_turn_publication(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pre-reviewer-prune-contention-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            proof = root / "proof"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            once = root / "once"
            ready_read_fd, ready_write_fd = os.pipe()
            release_read_fd, release_write_fd = os.pipe()
            for descriptor in (
                ready_read_fd,
                ready_write_fd,
                release_read_fd,
                release_write_fd,
            ):
                self.addCleanup(os.close, descriptor)
            real_python = shutil.which("python3") or "/usr/bin/python3"
            wrapper = bin_dir / "python3"
            wrapper.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "if [[ \"${1:-}\" == *prune_pre_reviewer_turn_state.py ]] && "
                "mkdir \"$CODEX_TEST_PRUNE_ONCE\" 2>/dev/null; then\n"
                "  printf 'ready\\n' >&\"$CODEX_TEST_PRUNE_READY_FD\"\n"
                "  IFS= read -r -u \"$CODEX_TEST_PRUNE_RELEASE_FD\" release\n"
                "  [ \"$release\" = release ]\n"
                "fi\n"
                f'exec "{real_python}" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "HOME": str(home),
                "CODEX_HOME": str(ROOT),
                "CODEX_PROOF_ROOT": str(proof),
                "CODEX_TEST_PRUNE_READY_FD": str(ready_write_fd),
                "CODEX_TEST_PRUNE_RELEASE_FD": str(release_read_fd),
                "CODEX_TEST_PRUNE_ONCE": str(once),
                "PYTHONDONTWRITEBYTECODE": "1",
            }

            def payload(turn_id: str) -> bytes:
                return json.dumps(
                    {
                        "session_id": "t00-session",
                        "turn_id": turn_id,
                        "prompt": f"prompt {turn_id}",
                        "cwd": str(ROOT),
                    },
                    separators=(",", ":"),
                ).encode()

            first = subprocess.Popen(
                ["/bin/bash", str(PROMPT_HOOK)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                pass_fds=(ready_write_fd, release_read_fd),
            )
            def cleanup_first() -> None:
                if first.poll() is not None:
                    return
                first.terminate()
                try:
                    first.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    first.kill()
                    first.wait(timeout=1.0)

            self.addCleanup(cleanup_first)
            input_stream = first.stdin
            self.assertIsNotNone(input_stream)
            if input_stream is None:
                raise AssertionError("prompt process stdin is unavailable")
            input_stream.write(payload("turn-a"))
            input_stream.close()
            first.stdin = None
            readable, _, _ = select.select([ready_read_fd], [], [], 3.0)
            self.assertEqual(
                readable,
                [ready_read_fd],
                "first pruner did not reach pause point",
            )
            self.assertEqual(os.read(ready_read_fd, 64), b"ready\n")

            started = time.monotonic()
            second = subprocess.run(
                ["/bin/bash", str(PROMPT_HOOK)],
                input=payload("turn-b"),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2.0,
                env=environment,
                check=False,
            )
            elapsed = time.monotonic() - started
            os.write(release_write_fd, b"release\n")
            first_stdout, first_stderr = first.communicate(timeout=2.0)
            self.assertEqual((first.returncode, first_stdout), (0, b""), first_stderr)
            self.assertEqual((second.returncode, second.stdout), (0, b""), second.stderr)
            self.assertLess(elapsed, 1.0)
            captures = sorted((proof / "pre-reviewer/t00-session").glob("capture-turn-*.json"))
            self.assertEqual(len(captures), 2)
            observed = {json.loads(path.read_text())["turn_id"] for path in captures}
            self.assertEqual(observed, {"turn-a", "turn-b"})


if __name__ == "__main__":
    unittest.main()
