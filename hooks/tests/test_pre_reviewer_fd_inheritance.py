#!/usr/bin/env python3
"""Focused lock-descriptor inheritance predicates for pruner and validator."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROMPT_HOOK = ROOT / "hooks/prompt-task-reminder.sh"
PRETOOL_HOOK = ROOT / "hooks/edit-bash-pre-reviewer.sh"


class LockDescriptorInheritanceTests(unittest.TestCase):
    def test_pruner_inherits_lock_and_validator_closes_child_copy(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pre-reviewer-fd-") as temporary:
            root = Path(temporary)
            home = root / "home"
            proof = root / "proof"
            state_dir = proof / "pre-reviewer/t00-session"
            state_dir.mkdir(parents=True, mode=0o700)
            state_dir.chmod(0o700)
            state_dir = state_dir.resolve()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            trace = root / "fd.trace"
            trace.touch()
            real_python = shutil.which("python3") or "/usr/bin/python3"
            wrapper = bin_dir / "python3"
            wrapper.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"REAL_PYTHON={shlex_quote(real_python)}\n"
                "kind=other\n"
                "case \" $* \" in\n"
                "  *prune_pre_reviewer_turn_state.py*) kind=pruner ;;\n"
                "  *turn_capture_validator.py*) kind=validator ;;\n"
                "esac\n"
                "if [ \"$kind\" != other ]; then\n"
                "  child=closed; parent=missing\n"
                "  parent_pid=\n"
                "  while read -r status_key status_value _status_rest; do\n"
                "    if [ \"$status_key\" = PPid: ]; then parent_pid=\"$status_value\"; break; fi\n"
                "  done </proc/self/status\n"
                "  [ -n \"$parent_pid\" ] || exit 1\n"
                "  for fd in /proc/$$/fd/*; do\n"
                "    [ \"$(readlink \"$fd\" 2>/dev/null || true)\" = \"$CODEX_TEST_STATE_DIR\" ] && child=has\n"
                "  done\n"
                "  for fd in /proc/$parent_pid/fd/*; do\n"
                "    [ \"$(readlink \"$fd\" 2>/dev/null || true)\" = \"$CODEX_TEST_STATE_DIR\" ] && parent=has\n"
                "  done\n"
                "  printf '%s-child-%s\\n%s-parent-%s\\n' \"$kind\" \"$child\" \"$kind\" \"$parent\" >>\"$CODEX_TEST_FD_TRACE\"\n"
                "fi\n"
                "exec \"$REAL_PYTHON\" \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            environment = {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "HOME": str(home),
                "CODEX_HOME": str(ROOT),
                "CODEX_PROOF_ROOT": str(proof),
                "CODEX_TEST_STATE_DIR": str(state_dir),
                "CODEX_TEST_FD_TRACE": str(trace),
                "CODEX_EDIT_PRE_REVIEWER": "ollama:http://127.0.0.1:1/generated",
                "CODEX_PRE_REVIEWER_FAKE_RESULT": '{"verdict":"deny","reason":"FD test."}',
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            prompt = json.dumps(
                {
                    "session_id": "t00-session",
                    "hook_event_name": "UserPromptSubmit",
                    "cwd": str(ROOT),
                    "turn_id": "validator-fd",
                    "prompt": "FD_PROMPT",
                },
                separators=(",", ":"),
            ).encode()
            prompt_result = subprocess.run(
                ["/bin/bash", str(PROMPT_HOOK)],
                input=prompt,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(
                (prompt_result.returncode, prompt_result.stdout), (0, b""),
                prompt_result.stderr.decode(errors="replace"),
            )
            tool = json.dumps(
                {
                    "session_id": "t00-session",
                    "turn_id": "validator-fd",
                    "tool_name": "Bash",
                    "cwd": str(ROOT),
                    "tool_input": {"command": "true"},
                },
                separators=(",", ":"),
            ).encode()
            tool_result = subprocess.run(
                ["/bin/bash", str(PRETOOL_HOOK)],
                input=tool,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(tool_result.returncode, 0, tool_result.stderr.decode())
            observed = set(trace.read_text(encoding="utf-8").splitlines())
            expected = {
                "pruner-child-has",
                "pruner-parent-has",
                "validator-child-closed",
                "validator-parent-has",
            }
            self.assertEqual(
                observed,
                expected,
                f"FD predicates: {sorted(observed)}",
            )


def shlex_quote(value: str) -> str:
    import shlex

    return shlex.quote(value)


if __name__ == "__main__":
    unittest.main()
