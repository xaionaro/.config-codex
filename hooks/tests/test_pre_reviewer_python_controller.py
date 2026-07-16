#!/usr/bin/env python3
"""Unit contract for the binary-safe exact-child pre-reviewer controller."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "hooks" / "lib" / "edit_bash_pre_reviewer_controller.py"
WRAPPER = ROOT / "hooks" / "edit-bash-pre-reviewer.sh"
HOOKS_JSON = ROOT / "hooks.json"
REVIEWER_CALL = ROOT / "hooks/lib/reviewer-call.sh"
BACKEND_TIMEOUT_MAX_SECONDS = 58
CONTROLLER_TIMEOUT_SECONDS = 70
HOOK_TIMEOUT_SECONDS = 75


class PythonControllerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not CONTROLLER.is_file():
            raise AssertionError("absolute Python exact-child controller is missing")
        spec = importlib.util.spec_from_file_location(
            "pre_reviewer_controller", CONTROLLER
        )
        assert spec is not None and spec.loader is not None
        cls.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.module
        spec.loader.exec_module(cls.module)

    def test_valid_output_preserves_exact_bytes(self) -> None:
        raw = json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "generated",
                }
            },
            separators=(",", ":"),
        ).encode()
        self.assertEqual(self.module.validate_hook_output(raw), raw)

    def test_empty_output_is_valid_silence(self) -> None:
        self.assertEqual(self.module.validate_hook_output(b""), b"")

    def test_binary_and_non_strict_json_are_rejected(self) -> None:
        valid = (
            b'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
            b'"permissionDecision":"deny","permissionDecisionReason":"x"}}'
        )
        rejected = (
            b"\0" + valid,
            valid[:10] + b"\0" + valid[10:],
            valid + b"\0",
            b"\xff" + valid,
            b'{"hookSpecificOutput":{},"hookSpecificOutput":{}}',
            b'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
            b'"permissionDecision":"maybe","permissionDecisionReason":"x"}}',
        )
        for raw in rejected:
            with self.subTest(raw=raw[:20]):
                self.assertIsNone(self.module.validate_hook_output(raw))

    def test_bounded_retention_rejects_nul_and_cap_plus_one(self) -> None:
        retained = bytearray()
        count, rejected = self.module.retain_raw_chunk(
            retained, 0, b"a" * self.module.OUTPUT_CAP
        )
        self.assertFalse(rejected)
        self.assertEqual(len(retained), self.module.OUTPUT_CAP)
        count, rejected = self.module.retain_raw_chunk(retained, count, b"b")
        self.assertTrue(rejected)
        self.assertEqual(count, self.module.OUTPUT_CAP + 1)
        self.assertEqual(len(retained), self.module.OUTPUT_CAP + 1)

        nul_retained = bytearray()
        _count, rejected = self.module.retain_raw_chunk(
            nul_retained, 0, b"prefix\0suffix"
        )
        self.assertTrue(rejected)
        self.assertLessEqual(len(nul_retained), self.module.OUTPUT_CAP + 1)

    def test_publication_cap_matches_atomic_pipe_bound(self) -> None:
        self.assertEqual(self.module.OUTPUT_CAP, 4096)
        body = """
import importlib.util
import os
import sys
spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
calls = 0
real_write = os.write
def counted_write(fd, data):
    global calls
    if fd == 1:
        calls += 1
    return real_write(fd, data)
module.os.write = counted_write
payload = b"x" * 3000
module._write_payload(payload)
if calls != 1:
    raise SystemExit(91)
"""
        result = subprocess.run(
            [sys.executable, "-c", body, str(CONTROLLER)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"x" * 3000)

        oversized = subprocess.run(
            [
                sys.executable,
                "-c",
                body.replace(
                    'payload = b"x" * 3000',
                    'payload = b"x" * (os.fpathconf(1, "PC_PIPE_BUF") + 1)',
                ),
                str(CONTROLLER),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(oversized.returncode, 0)
        self.assertEqual(oversized.stdout, b"")

    def test_whole_controller_deadline_starts_before_preflight(self) -> None:
        original_timeout = self.module.CONTROLLER_TIMEOUT_SECONDS
        original_preflight = self.module.preflight
        original_capture = self.module.capture_reviewer
        capture_called = False

        def slow_preflight(*_args: object) -> None:
            time.sleep(0.05)

        def unexpected_capture(*_args: object) -> object:
            nonlocal capture_called
            capture_called = True
            raise AssertionError("capture ran after controller deadline")

        self.module.CONTROLLER_TIMEOUT_SECONDS = 0.01
        self.module.preflight = slow_preflight
        self.module.capture_reviewer = unexpected_capture
        try:
            with self.assertRaises(self.module.ControllerError):
                self.module.run_controller(Path("/bin/true"), Path("/bin/true"), Path("/bin/true"))
        finally:
            self.module.CONTROLLER_TIMEOUT_SECONDS = original_timeout
            self.module.preflight = original_preflight
            self.module.capture_reviewer = original_capture
        self.assertFalse(capture_called)

    def test_wrapper_is_preflight_and_absolute_python_exec_only(self) -> None:
        source = WRAPPER.read_text(encoding="utf-8")
        self.assertIn('exec "$python_command" "$controller"', source)
        self.assertIn(
            'controller="$HOOK_DIR/lib/edit_bash_pre_reviewer_controller.py"',
            source,
        )
        for forbidden in (
            "coproc",
            "mktemp",
            "CODEX_PRE_REVIEWER_TRACE_FD",
            "CODEX_PRE_REVIEWER_WAIT_NOTIFY_FD",
        ):
            self.assertNotIn(forbidden, source)

    def test_controller_numeric_signal_is_limited_to_unreaped_direct_child(self) -> None:
        source = CONTROLLER.read_text(encoding="utf-8")
        for forbidden in ("os.killpg(", "NamedTemporaryFile", "mkstemp"):
            self.assertNotIn(forbidden, source)
        self.assertEqual(source.count("os.kill("), 1)
        self.assertIn("os.kill(pid, signal.SIGKILL)", source)
        self.assertIn("os.waitpid(pid, os.WNOHANG)", source)
        self.assertIn("signal.pidfd_send_signal", source)
        self.assertIn('"--kill-child=KILL"', source)
        self.assertIn("PR_SET_PDEATHSIG", source)

    def test_preflight_rejects_executable_that_can_clear_pdeathsig(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pre-reviewer-preflight-") as temporary:
            root = Path(temporary)
            unshare = root / "unshare"
            shutil.copyfile(shutil.which("true") or "/bin/true", unshare)
            unshare.chmod(0o4755)
            worker = root / "worker.sh"
            worker.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            worker.chmod(0o755)
            bash = Path(shutil.which("bash") or "/bin/bash")
            with self.assertRaises(self.module.ControllerError):
                self.module.preflight(unshare, bash, worker)

    def test_wrapper_fails_open_when_safety_dependency_is_absent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pre-reviewer-path-") as temporary:
            result = subprocess.run(
                [shutil.which("bash") or "/bin/bash", str(WRAPPER)],
                input=b"{}",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"PATH": temporary, "HOME": temporary},
                check=False,
            )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_named_timeout_layers_have_strict_ordering(self) -> None:
        configuration = json.loads(HOOKS_JSON.read_text(encoding="utf-8"))
        configured = [
            hook["timeout"]
            for group in configuration["hooks"]["PreToolUse"]
            for hook in group["hooks"]
            if hook["command"].endswith("/edit-bash-pre-reviewer.sh\"'")
        ]
        reviewer_source = REVIEWER_CALL.read_text(encoding="utf-8")
        self.assertIn(
            f"CODEX_EDIT_PRE_REVIEWER_TIMEOUT:={BACKEND_TIMEOUT_MAX_SECONDS}",
            reviewer_source,
        )
        self.assertEqual(self.module.CONTROLLER_TIMEOUT_SECONDS, CONTROLLER_TIMEOUT_SECONDS)
        self.assertEqual(set(configured), {HOOK_TIMEOUT_SECONDS})
        self.assertLess(BACKEND_TIMEOUT_MAX_SECONDS, CONTROLLER_TIMEOUT_SECONDS)
        self.assertLess(CONTROLLER_TIMEOUT_SECONDS, HOOK_TIMEOUT_SECONDS)


if __name__ == "__main__":
    unittest.main()
