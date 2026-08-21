#!/usr/bin/env python3
"""Focused regression tests for the configurable ECI command-gate floor."""

from __future__ import annotations

import errno
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock


CODEX_ROOT = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
KIMI_ROOT = Path(os.environ.get("KIMI_CODE_HOME", Path.home() / ".kimi-code"))
MODE_BIN = CODEX_ROOT / "bin" / "eci-command-gate-mode"


class CommandGateModeTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory(
            prefix="eci-command-gate-mode.",
            dir=os.environ.get("CODEX_TMPDIR", str(Path.home() / "tmp")),
        )
        self.root = Path(self._temporary.name).resolve()
        self.config_home = self.root / "config"
        self.state_home = self.root / "state"
        self.kimi_worker_home: Path | None = None

    def tearDown(self) -> None:
        if self.kimi_worker_home is not None:
            shutil.rmtree(self.kimi_worker_home)
        self._temporary.cleanup()

    def _environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "XDG_CONFIG_HOME": str(self.config_home),
                "XDG_STATE_HOME": str(self.state_home),
            }
        )
        return environment

    def _default_state_environment(self) -> tuple[dict[str, str], Path]:
        logical_home = self.root / "logical-home"
        canonical_home = self.root / "canonical-home"
        logical_home.mkdir(mode=0o700)
        canonical_local = canonical_home / ".local"
        canonical_local.mkdir(parents=True, mode=0o700)
        (logical_home / ".local").symlink_to(canonical_local, target_is_directory=True)
        environment = self._environment()
        environment.pop("XDG_STATE_HOME")
        environment["HOME"] = str(logical_home)
        return environment, canonical_local / "state"

    def _set_mode(self, mode: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(MODE_BIN), "set", mode],
            text=True,
            capture_output=True,
            check=False,
            env=self._environment(),
        )

    def _run_hook(
        self,
        provider: str,
        command: str,
        *,
        role: str = "coordinator",
        active: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        provider_root = CODEX_ROOT if provider == "codex" else KIMI_ROOT
        session_id = (
            "codex-command-gate-mode"
            if provider == "codex"
            else "session_22222222-2222-4222-8222-222222222222"
        )
        proof_root = self.root / f"{provider}-proof"
        marker_dir = proof_root / session_id
        proof_root.mkdir(parents=True, exist_ok=True)
        if active:
            marker_dir.mkdir(parents=True, exist_ok=True)
            (marker_dir / "eci_active").write_text(
                "scope: command-gate mode regression\n"
                f"cwd: {CODEX_ROOT}\n"
                f"session_id: {session_id}\n"
                "created_utc: 2026-08-21T00:00:00Z\n",
                encoding="utf-8",
            )
        payload = json.dumps(
            {
                "session_id": session_id,
                "cwd": str(CODEX_ROOT),
                "tool_input": {"command": command},
            }
        )
        environment = self._environment()
        environment.update(
            {
                "CODEX_HOME": str(CODEX_ROOT),
                "KIMI_CODE_HOME": str(KIMI_ROOT),
                "CODEX_PROOF_ROOT": str(proof_root),
                "KIMI_PROOF_ROOT": str(proof_root),
                "CODEX_HOOK_IS_SUBAGENT": "true" if role == "worker" else "false",
            }
        )
        if provider == "kimi" and role == "worker":
            if self.kimi_worker_home is None:
                self.kimi_worker_home = Path(
                    tempfile.mkdtemp(prefix=".eci-mode-kimi-worker.", dir=CODEX_ROOT)
                )
            kimi_home = self.kimi_worker_home
            mode_alias = kimi_home / "bin" / "eci-command-gate-mode"
            mode_alias.parent.mkdir(parents=True, exist_ok=True)
            if not mode_alias.exists():
                os.link(MODE_BIN, mode_alias)
            wire = (
                kimi_home
                / "sessions"
                / "2026-08-21"
                / session_id
                / "agents"
                / "main"
                / "wire.jsonl"
            )
            wire.parent.mkdir(parents=True, exist_ok=True)
            now_ms = time.time_ns() // 1_000_000
            wire.write_text(
                '{"protocol_version":"1.5"}\n'
                f'{{"event":{{"type":"tool.call","name":"Agent",'
                f'"toolCallId":"agent-call","time":{now_ms - 5_000}}}}}\n',
                encoding="utf-8",
            )
            environment["KIMI_CODE_HOME"] = str(kimi_home)
        return subprocess.run(
            ["bash", str(provider_root / "hooks" / "validate-bash.sh")],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def _events(self) -> list[dict[str, object]]:
        log_path = self.state_home / "eci" / "command-gate" / "would-deny.jsonl"
        self.assertTrue(log_path.is_file(), f"missing telemetry log: {log_path}")
        return [json.loads(line) for line in log_path.read_text().splitlines()]

    def _event_count(self) -> int:
        log_path = self.state_home / "eci" / "command-gate" / "would-deny.jsonl"
        if not log_path.exists():
            return 0
        return len(log_path.read_text().splitlines())

    def _prepare_log_directory(self) -> Path:
        self.state_home.mkdir(mode=0o700, exist_ok=True)
        eci_directory = self.state_home / "eci"
        eci_directory.mkdir(mode=0o700, exist_ok=True)
        log_directory = eci_directory / "command-gate"
        log_directory.mkdir(mode=0o700, exist_ok=True)
        return log_directory

    def _load_mode_module(self) -> object:
        module_name = f"eci_command_gate_mode_{time.time_ns()}"
        loader = importlib.machinery.SourceFileLoader(module_name, str(MODE_BIN))
        specification = importlib.util.spec_from_loader(module_name, loader)
        self.assertIsNotNone(specification)
        module = importlib.util.module_from_spec(specification)
        sys.modules[module_name] = module
        self.addCleanup(sys.modules.pop, module_name, None)
        loader.exec_module(module)
        return module

    def _finalize(
        self,
        denial: bytes,
        *,
        provider: str = "codex",
        role: str = "coordinator",
        marker: str = "active",
        source: str = "parser",
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [str(MODE_BIN), "finalize", provider, role, marker, source],
            input=denial,
            capture_output=True,
            check=False,
            env=environment if environment is not None else self._environment(),
            timeout=5,
        )

    def _module_finalize(
        self,
        mode_module: object,
        denial: bytes,
        *,
        append_failure: BaseException | None = None,
    ) -> tuple[int, bytes, list[bytes]]:
        stdin = SimpleNamespace(buffer=io.BytesIO(denial))
        stdout_buffer = io.BytesIO()
        stdout = SimpleNamespace(buffer=stdout_buffer)
        warnings: list[bytes] = []
        original_write = mode_module.os.write

        def capture_write(descriptor: int, value: bytes) -> int:
            if descriptor == 2:
                warnings.append(value)
                return len(value)
            return original_write(descriptor, value)

        append_patch = (
            mock.patch.object(mode_module, "append_event", side_effect=append_failure)
            if append_failure is not None
            else mock.patch.object(mode_module, "append_event", wraps=mode_module.append_event)
        )
        with mock.patch.dict(mode_module.os.environ, self._environment(), clear=False):
            with mock.patch.object(mode_module.sys, "stdin", stdin):
                with mock.patch.object(mode_module.sys, "stdout", stdout):
                    with mock.patch.object(mode_module.os, "write", side_effect=capture_write):
                        with append_patch:
                            status = mode_module.finalize(
                                mode_module.Provider.CODEX,
                                mode_module.Role.WORKER,
                                mode_module.Marker.ACTIVE,
                                mode_module.Source.PARSER,
                            )
        return status, stdout_buffer.getvalue(), warnings

    def _make_special_file(
        self,
        path: Path,
        kind: str,
    ) -> tuple[Path | None, socket.socket | None]:
        outside: Path | None = None
        bound_socket: socket.socket | None = None
        if kind == "symlink":
            outside = self.root / f"outside-{path.name}"
            outside.write_bytes(b"unchanged\n")
            path.symlink_to(outside)
        elif kind == "hardlink":
            outside = self.root / f"outside-{path.name}"
            outside.write_bytes(b"unchanged\n")
            outside.chmod(0o600)
            os.link(outside, path)
        elif kind == "directory":
            path.mkdir(mode=0o700)
        elif kind == "fifo":
            os.mkfifo(path, mode=0o600)
        elif kind == "socket":
            bound_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            bound_socket.bind(str(path))
        elif kind == "wrong-mode":
            path.write_bytes(b"")
            path.chmod(0o640)
        else:
            self.fail(f"unknown fixture kind: {kind}")
        return outside, bound_socket

    @staticmethod
    def _sample_denial(secret: str = "not-recorded") -> bytes:
        reason = (
            "[ECI_SAMPLE_DENIED] ECI gate denied "
            "(phase=PreToolUse, operation=sample-boundary, token="
            f"{secret}); reason: sample; remediation: retry"
        )
        return (
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": reason,
                    }
                },
                separators=(",", ":"),
            ).encode()
            + b"\n"
        )

    def test_missing_config_allows_parser_denial_and_logs_once(self) -> None:
        for provider in ("codex", "kimi"):
            with self.subTest(provider=provider):
                result = self._run_hook(provider, "env")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
        events = self._events()
        self.assertEqual(len(events), 2)
        self.assertEqual([event["provider"] for event in events], ["codex", "kimi"])
        self.assertTrue(
            all(event["code"] == "ECI_ENVIRONMENT_ENUMERATION_DENIED" for event in events)
        )

    def test_missing_config_allows_legacy_denial_and_logs_once(self) -> None:
        commands = {
            "codex": f"{CODEX_ROOT}/bin/eci-active unknown-verb",
            "kimi": f"{KIMI_ROOT}/bin/eci-active unknown-verb",
        }
        for provider, command in commands.items():
            with self.subTest(provider=provider):
                result = self._run_hook(provider, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
        events = self._events()
        self.assertEqual(len(events), 2)
        self.assertEqual([event["source"] for event in events], ["legacy", "legacy"])
        self.assertTrue(
            all(event["code"] == "ECI_LIFECYCLE_ARGUMENTS_DENIED" for event in events)
        )

    def test_cli_is_present_and_missing_config_reports_permissive(self) -> None:
        self.assertTrue(MODE_BIN.is_file(), f"missing command-gate mode CLI: {MODE_BIN}")
        result = subprocess.run(
            [str(MODE_BIN), "get"],
            text=True,
            capture_output=True,
            check=False,
            env=self._environment(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"mode": "permissive", "config_state": "missing"},
        )

    def test_cli_set_is_atomic_and_exact(self) -> None:
        for mode in ("permissive", "enforcing"):
            with self.subTest(mode=mode):
                result = self._set_mode(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                config = self.config_home / "eci" / "command-gate-mode"
                self.assertEqual(config.read_bytes(), f"{mode}\n".encode())
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                observed = subprocess.run(
                    [str(MODE_BIN), "get"],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=self._environment(),
                )
                self.assertEqual(observed.returncode, 0, observed.stderr)
                self.assertEqual(
                    json.loads(observed.stdout),
                    {"mode": mode, "config_state": f"configured-{mode}"},
                )
        self.assertEqual(self._set_mode("invalid").returncode, 2)

    def test_invalid_config_states_fail_to_enforcing(self) -> None:
        config_dir = self.config_home / "eci"
        config_dir.mkdir(parents=True, mode=0o700)
        config = config_dir / "command-gate-mode"
        for label, value in (
            ("empty", b""),
            ("crlf", b"permissive\r\n"),
            ("trailing", b"permissive\nextra"),
            ("unknown", b"observe\n"),
            ("oversize", b"x" * 64),
        ):
            with self.subTest(label=label):
                config.unlink(missing_ok=True)
                config.write_bytes(value)
                config.chmod(0o600)
                result = subprocess.run(
                    [str(MODE_BIN), "get"],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=self._environment(),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["mode"], "enforcing")
        config.unlink()
        config.mkdir()
        result = subprocess.run(
            [str(MODE_BIN), "get"],
            text=True,
            capture_output=True,
            check=False,
            env=self._environment(),
        )
        self.assertEqual(json.loads(result.stdout)["config_state"], "invalid-metadata")
        config.rmdir()
        outside = self.root / "outside-mode"
        outside.write_text("permissive\n", encoding="utf-8")
        config.symlink_to(outside)
        result = subprocess.run(
            [str(MODE_BIN), "get"],
            text=True,
            capture_output=True,
            check=False,
            env=self._environment(),
        )
        self.assertEqual(json.loads(result.stdout)["config_state"], "invalid-path")

    def test_finalize_enforces_byte_exact_and_permissive_redacts(self) -> None:
        secret = "OPENAI_API_KEY=do-not-record"
        denial = self._sample_denial(secret)
        self.assertEqual(self._set_mode("enforcing").returncode, 0)
        enforcing = self._finalize(denial)
        self.assertEqual(enforcing.returncode, 0, enforcing.stderr)
        self.assertEqual(enforcing.stdout, denial)
        self.assertFalse((self.state_home / "eci" / "command-gate" / "would-deny.jsonl").exists())

        self.assertEqual(self._set_mode("permissive").returncode, 0)
        permissive = self._finalize(denial)
        self.assertEqual(permissive.returncode, 0, permissive.stderr)
        self.assertEqual(permissive.stdout, b"")
        event = self._events()[0]
        self.assertEqual(
            set(event),
            {
                "schema",
                "event",
                "at_utc",
                "provider",
                "role",
                "marker",
                "source",
                "code",
                "operation",
                "config_state",
            },
        )
        self.assertEqual(event["schema"], "eci-command-gate-event/v1")
        self.assertEqual(event["code"], "ECI_OTHER_DENIAL")
        self.assertEqual(event["operation"], "other")
        self.assertNotIn(secret, json.dumps(event))

    def test_default_home_local_alias_records_event_and_creates_suffix(self) -> None:
        environment, canonical_state = self._default_state_environment()
        result = self._finalize(self._sample_denial(), environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        log = canonical_state / "eci" / "command-gate" / "would-deny.jsonl"
        self.assertTrue(log.is_file(), f"missing canonical telemetry log: {log}")
        self.assertEqual(len(log.read_text(encoding="utf-8").splitlines()), 1)
        self.assertEqual(canonical_state.stat().st_mode & 0o777, 0o700)

    def test_explicit_state_alias_is_rejected_without_writing_target(self) -> None:
        target = self.root / "explicit-target"
        target.mkdir(mode=0o700)
        alias = self.root / "explicit-alias"
        alias.symlink_to(target, target_is_directory=True)
        environment = self._environment()
        environment["XDG_STATE_HOME"] = str(alias)
        result = self._finalize(self._sample_denial(), environment=environment)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertFalse((target / "eci").exists())

    def test_invalid_explicit_state_roots_do_not_create_telemetry(self) -> None:
        loop_one = self.root / "loop-one"
        loop_two = self.root / "loop-two"
        loop_one.symlink_to(loop_two)
        loop_two.symlink_to(loop_one)
        dangling = self.root / "dangling"
        dangling.symlink_to(self.root / "missing-target")
        special = self.root / "state-file"
        special.write_text("not a directory\n", encoding="utf-8")
        cases = (
            "relative/state",
            f"{self.root}/./state",
            str(loop_one),
            str(dangling),
            str(special),
        )
        for value in cases:
            with self.subTest(value=value):
                environment = self._environment()
                environment["XDG_STATE_HOME"] = value
                result = self._finalize(self._sample_denial(), environment=environment)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
        self.assertFalse((self.state_home / "eci").exists())

    def test_default_home_dangling_alias_does_not_create_target(self) -> None:
        logical_home = self.root / "dangling-home"
        logical_home.mkdir(mode=0o700)
        missing_target = self.root / "missing-local"
        (logical_home / ".local").symlink_to(missing_target, target_is_directory=True)
        environment = self._environment()
        environment.pop("XDG_STATE_HOME")
        environment["HOME"] = str(logical_home)
        result = self._finalize(self._sample_denial(), environment=environment)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertFalse(missing_target.exists())

    def test_state_root_metadata_is_validated_before_descendant_creation(self) -> None:
        for mode in (0o777, 0o1700):
            with self.subTest(mode=oct(mode)):
                shutil.rmtree(self.state_home, ignore_errors=True)
                self.state_home.mkdir(mode=0o700)
                self.state_home.chmod(mode)
                result = self._finalize(self._sample_denial())
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertFalse((self.state_home / "eci").exists())

    def test_metadata_predicates_reject_wrong_owner(self) -> None:
        mode_module = self._load_mode_module()
        directory_metadata = SimpleNamespace(
            st_mode=stat.S_IFDIR | 0o700,
            st_uid=os.getuid() + 1,
        )
        file_metadata = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600,
            st_uid=os.getuid() + 1,
            st_nlink=1,
        )
        with self.assertRaises(mode_module.UnsafePathError):
            mode_module._validate_state_root_metadata(directory_metadata)
        with self.assertRaises(mode_module.UnsafePathError):
            mode_module._validate_telemetry_file(file_metadata, label="test")

    def test_telemetry_reduction_uses_closed_fallbacks(self) -> None:
        secret = "raw-token=/tmp/private-command"
        denial = self._sample_denial(secret).replace(
            b"ECI_SAMPLE_DENIED",
            b"ECI_UNREGISTERED_SECRET_DENIAL",
        ).replace(
            b"operation=sample-boundary",
            b"operation=unregistered-secret-operation",
        )
        result = self._finalize(denial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        event_text = json.dumps(self._events()[0], separators=(",", ":"))
        self.assertEqual(self._events()[0]["code"], "ECI_OTHER_DENIAL")
        self.assertEqual(self._events()[0]["operation"], "other")
        self.assertNotIn(secret, event_text)
        self.assertNotIn(hashlib.sha256(secret.encode()).hexdigest(), event_text)

    def test_malformed_reduction_obeys_mode_and_enforcing_preserves_bytes(self) -> None:
        for denial in (b"", b"{}\n", b"not-json\n", b"x" * 65_537):
            with self.subTest(size=len(denial)):
                permissive = self._finalize(denial)
                self.assertEqual(permissive.returncode, 0, permissive.stderr)
                self.assertEqual(permissive.stdout, b"")
                self.assertEqual(self._set_mode("enforcing").returncode, 0)
                enforcing = self._finalize(denial)
                self.assertEqual(enforcing.returncode, 0, enforcing.stderr)
                self.assertEqual(enforcing.stdout, denial)
                self.assertEqual(self._set_mode("permissive").returncode, 0)

    def test_deep_malformed_json_is_total_in_permissive_mode(self) -> None:
        denial = b"[" * 2_000 + b"0" + b"]" * 2_000
        result = self._finalize(denial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"eci-command-gate-mode: telemetry unavailable\n",
        )

    def test_legacy_tmp_fault_latch_is_never_touched(self) -> None:
        mode_module = self._load_mode_module()
        fake_uid = 900_000 + os.getuid()
        latch = Path(f"/tmp/.eci-command-gate-fault-{fake_uid}")
        outside_descriptor, outside_name = tempfile.mkstemp(
            prefix="eci-command-gate-legacy-latch.",
            dir="/tmp",
        )
        os.close(outside_descriptor)
        outside = Path(outside_name)
        outside.write_bytes(b"must remain unchanged\n")
        self.addCleanup(outside.unlink, missing_ok=True)
        latch.unlink(missing_ok=True)
        os.link(outside, latch)
        self.addCleanup(latch.unlink, missing_ok=True)
        warnings: list[bytes] = []

        def capture_warning(descriptor: int, value: bytes) -> int:
            self.assertEqual(descriptor, 2)
            warnings.append(value)
            return len(value)

        with mock.patch.object(mode_module.os, "getuid", return_value=fake_uid):
            with mock.patch.object(mode_module.os, "write", side_effect=capture_warning):
                mode_module.emit_telemetry_unavailable()
        self.assertEqual(warnings, [b"eci-command-gate-mode: telemetry unavailable\n"])
        self.assertEqual(outside.read_bytes(), b"must remain unchanged\n")
        self.assertEqual(latch.stat().st_nlink, 2)

    def test_config_hardlink_is_invalid_metadata(self) -> None:
        config_dir = self.config_home / "eci"
        config_dir.mkdir(parents=True, mode=0o700)
        outside = self.root / "outside-config"
        outside.write_bytes(b"permissive\n")
        outside.chmod(0o600)
        os.link(outside, config_dir / "command-gate-mode")
        observed = subprocess.run(
            [str(MODE_BIN), "get"],
            text=True,
            capture_output=True,
            check=False,
            env=self._environment(),
        )
        self.assertEqual(observed.returncode, 0, observed.stderr)
        self.assertEqual(
            json.loads(observed.stdout),
            {"mode": "enforcing", "config_state": "invalid-metadata"},
        )
        self.assertEqual(outside.read_bytes(), b"permissive\n")

    def test_fifo_log_failure_is_bounded_and_permissive(self) -> None:
        log_dir = self._prepare_log_directory()
        os.mkfifo(log_dir / "would-deny.jsonl", mode=0o600)
        started = time.monotonic()
        result = self._finalize(self._sample_denial())
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertLess(elapsed, 1.0)

    def test_only_fixed_rotation_generation_names_are_probed(self) -> None:
        log_dir = self._prepare_log_directory()
        sentinel = log_dir / "would-deny.jsonl.5"
        sentinel.write_bytes(b"unrelated sentinel\n")
        sentinel.chmod(0o600)
        result = self._finalize(self._sample_denial())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(sentinel.read_bytes(), b"unrelated sentinel\n")
        self.assertEqual(self._event_count(), 1)

    def test_permissive_storage_does_not_enumerate_directory(self) -> None:
        mode_module = self._load_mode_module()
        denial = mode_module.parse_denial(self._sample_denial())
        environment = self._environment()
        with mock.patch.dict(mode_module.os.environ, environment, clear=False):
            with mock.patch.object(
                mode_module.os,
                "listdir",
                side_effect=AssertionError("directory enumeration is forbidden"),
            ):
                mode_module.append_event(
                    denial,
                    provider=mode_module.Provider.CODEX,
                    role=mode_module.Role.WORKER,
                    marker=mode_module.Marker.ACTIVE,
                    source=mode_module.Source.PARSER,
                    config_state=mode_module.ConfigState.MISSING,
                )
        self.assertEqual(self._event_count(), 1)

    def test_public_wrong_owner_state_root_fails_permissively(self) -> None:
        foreign_root = Path("/var/tmp")
        metadata = foreign_root.stat()
        self.assertNotEqual(metadata.st_uid, os.getuid())
        environment = self._environment()
        environment["XDG_STATE_HOME"] = str(foreign_root)
        result = self._finalize(self._sample_denial(), environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"eci-command-gate-mode: telemetry unavailable\n",
        )

    def test_public_foreign_config_ancestor_fails_enforcing(self) -> None:
        foreign_config = Path("/root/.config")
        self.assertNotEqual(Path("/root").stat().st_uid, os.getuid())
        environment = self._environment()
        environment["XDG_CONFIG_HOME"] = str(foreign_config)
        observed = subprocess.run(
            [str(MODE_BIN), "get"],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
            timeout=2,
        )
        self.assertEqual(observed.returncode, 0, observed.stderr)
        self.assertEqual(json.loads(observed.stdout)["mode"], "enforcing")

    def test_config_nonregular_and_wrong_mode_files_fail_enforcing(self) -> None:
        for kind in ("symlink", "hardlink", "directory", "fifo", "socket", "wrong-mode"):
            with self.subTest(kind=kind):
                shutil.rmtree(self.config_home, ignore_errors=True)
                config_dir = self.config_home / "eci"
                config_dir.mkdir(parents=True, mode=0o700)
                config = config_dir / "command-gate-mode"
                outside, bound_socket = self._make_special_file(config, kind)
                try:
                    observed = subprocess.run(
                        [str(MODE_BIN), "get"],
                        text=True,
                        capture_output=True,
                        check=False,
                        env=self._environment(),
                        timeout=2,
                    )
                finally:
                    if bound_socket is not None:
                        bound_socket.close()
                self.assertEqual(observed.returncode, 0, observed.stderr)
                state = json.loads(observed.stdout)
                self.assertEqual(state["mode"], "enforcing")
                self.assertIn(state["config_state"], ("invalid-path", "invalid-metadata"))
                if outside is not None:
                    self.assertEqual(outside.read_bytes(), b"unchanged\n")

    def test_every_fixed_telemetry_name_rejects_special_files_boundedly(self) -> None:
        names = (
            ".rotation.lock",
            "would-deny.jsonl",
            "would-deny.jsonl.1",
            "would-deny.jsonl.2",
            "would-deny.jsonl.3",
            "would-deny.jsonl.4",
        )
        kinds = ("symlink", "hardlink", "directory", "fifo", "socket", "wrong-mode")
        for name in names:
            for kind in kinds:
                with self.subTest(name=name, kind=kind):
                    shutil.rmtree(self.state_home, ignore_errors=True)
                    log_dir = self._prepare_log_directory()
                    outside, bound_socket = self._make_special_file(log_dir / name, kind)
                    started = time.monotonic()
                    try:
                        result = self._finalize(self._sample_denial())
                    finally:
                        if bound_socket is not None:
                            bound_socket.close()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(
                        result.stderr,
                        b"eci-command-gate-mode: telemetry unavailable\n",
                    )
                    self.assertLess(time.monotonic() - started, 1.0)
                    if outside is not None:
                        self.assertEqual(outside.read_bytes(), b"unchanged\n")

    def test_device_metadata_is_rejected_by_regular_file_predicate(self) -> None:
        mode_module = self._load_mode_module()
        metadata = os.stat("/dev/null")
        self.assertTrue(stat.S_ISCHR(metadata.st_mode))
        with self.assertRaises(mode_module.UnsafePathError):
            mode_module._validate_regular_metadata(
                metadata,
                purpose=mode_module.FilePurpose.LOG_GENERATION,
            )

    def test_named_file_replacement_is_detected_for_every_purpose(self) -> None:
        mode_module = self._load_mode_module()
        log_dir = self._prepare_log_directory()
        cases = (
            ("would-deny.jsonl", mode_module.FilePurpose.LOG_APPEND),
            ("would-deny.jsonl.1", mode_module.FilePurpose.LOG_GENERATION),
            (".rotation.lock", mode_module.FilePurpose.ROTATION_LOCK),
            ("config-fixture", mode_module.FilePurpose.CONFIG),
            (".config-temp", mode_module.FilePurpose.CONFIG_TEMP),
        )
        with mode_module.open_directory_path(log_dir, create=False) as parent:
            for name, purpose in cases:
                with self.subTest(name=name):
                    artifact = log_dir / name
                    artifact.write_bytes(b"")
                    artifact.chmod(0o600)
                    moved = log_dir / f"moved-{name}"
                    with mode_module.open_regular_file(
                        parent,
                        name,
                        purpose=purpose,
                        create=False,
                    ) as opened:
                        artifact.rename(moved)
                        artifact.write_bytes(b"")
                        artifact.chmod(0o600)
                        with self.assertRaises(mode_module.UnsafePathError):
                            mode_module.validate_named_identity(opened)
                    artifact.unlink()
                    moved.unlink()

    def test_descriptor_contexts_close_directory_and_regular_fds(self) -> None:
        mode_module = self._load_mode_module()
        log_dir = self._prepare_log_directory()
        artifact = log_dir / "would-deny.jsonl"
        artifact.write_bytes(b"")
        artifact.chmod(0o600)
        with mode_module.open_directory_path(log_dir, create=False) as parent:
            directory_fd = parent.descriptor
            with mode_module.open_regular_file(
                parent,
                artifact.name,
                purpose=mode_module.FilePurpose.LOG_APPEND,
                create=False,
            ) as opened:
                file_fd = opened.descriptor
                os.fstat(file_fd)
            with self.assertRaises(OSError):
                os.fstat(file_fd)
        with self.assertRaises(OSError):
            os.fstat(directory_fd)

    def test_contended_rotation_lock_never_waits(self) -> None:
        log_dir = self._prepare_log_directory()
        lock_path = log_dir / ".rotation.lock"
        lock_path.write_bytes(b"")
        lock_path.chmod(0o600)
        lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_NONBLOCK)
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            result = self._finalize(self._sample_denial())
            elapsed = time.monotonic() - started
        finally:
            os.close(lock_descriptor)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertLess(elapsed, 1.0)
        self.assertEqual(self._event_count(), 1)

    def test_permissive_finalize_catches_expected_and_unexpected_exceptions(self) -> None:
        mode_module = self._load_mode_module()
        failures = (
            RuntimeError("injected runtime failure"),
            OSError(errno.EIO, "injected IO failure"),
            mode_module.UnsafePathError("injected path failure"),
        )
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                status, stdout, warnings = self._module_finalize(
                    mode_module,
                    self._sample_denial(),
                    append_failure=failure,
                )
                self.assertEqual(status, 0)
                self.assertEqual(stdout, b"")
                self.assertEqual(
                    warnings,
                    [b"eci-command-gate-mode: telemetry unavailable\n"],
                )

    def test_permissive_finalize_does_not_catch_base_exception(self) -> None:
        mode_module = self._load_mode_module()
        with self.assertRaises(KeyboardInterrupt):
            self._module_finalize(
                mode_module,
                self._sample_denial(),
                append_failure=KeyboardInterrupt(),
            )

    def test_log_symlink_failure_allows_without_stdout(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        log_dir = self._prepare_log_directory()
        outside = self.root / "outside-log"
        outside.write_text("unchanged\n", encoding="utf-8")
        (log_dir / "would-deny.jsonl").symlink_to(outside)
        result = self._finalize(self._sample_denial())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(outside.read_text(), "unchanged\n")
        self.assertEqual(
            result.stderr,
            b"eci-command-gate-mode: telemetry unavailable\n",
        )
        repeated = self._finalize(self._sample_denial())
        self.assertEqual(repeated.returncode, 0)
        self.assertEqual(repeated.stdout, b"")
        self.assertEqual(
            repeated.stderr,
            b"eci-command-gate-mode: telemetry unavailable\n",
        )

    def test_log_hardlink_failure_does_not_modify_link_target(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        log_dir = self._prepare_log_directory()
        outside = self.root / "outside-hardlink"
        outside.write_text("unchanged\n", encoding="utf-8")
        outside.chmod(0o600)
        os.link(outside, log_dir / "would-deny.jsonl")
        result = self._finalize(self._sample_denial())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(outside.read_text(encoding="utf-8"), "unchanged\n")

    def test_lock_and_rotated_family_reject_aliases(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        for name in (".rotation.lock", "would-deny.jsonl.1"):
            with self.subTest(name=name):
                shutil.rmtree(self.state_home, ignore_errors=True)
                log_dir = self._prepare_log_directory()
                outside = self.root / f"outside-{name.replace('.', '-')}"
                outside.write_text("unchanged\n", encoding="utf-8")
                outside.chmod(0o600)
                os.link(outside, log_dir / name)
                result = self._finalize(self._sample_denial())
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertFalse((log_dir / "would-deny.jsonl").exists())
                self.assertEqual(outside.read_text(encoding="utf-8"), "unchanged\n")

    def test_rotated_family_rejects_symlink_directory_and_fifo(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        for name, kind in (
            ("would-deny.jsonl.2", "symlink"),
            ("would-deny.jsonl.3", "directory"),
            ("would-deny.jsonl.4", "fifo"),
        ):
            with self.subTest(name=name, kind=kind):
                shutil.rmtree(self.state_home, ignore_errors=True)
                log_dir = self._prepare_log_directory()
                artifact = log_dir / name
                if kind == "symlink":
                    artifact.symlink_to(self.root / "outside-generation")
                elif kind == "directory":
                    artifact.mkdir(mode=0o700)
                else:
                    os.mkfifo(artifact, mode=0o600)
                result = self._finalize(self._sample_denial())
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertFalse((log_dir / "would-deny.jsonl").exists())

    def test_state_root_replacement_is_detected_after_append(self) -> None:
        mode_module = self._load_mode_module()
        denial = mode_module.parse_denial(self._sample_denial())
        original_write = mode_module.os.write
        moved_state = self.root / "moved-state"
        swapped = False

        def swap_root_after_write(file_descriptor: int, value: bytes) -> int:
            nonlocal swapped
            written = original_write(file_descriptor, value)
            if not swapped and value.startswith(b'{"schema"'):
                self.state_home.rename(moved_state)
                self.state_home.mkdir(mode=0o700)
                swapped = True
            return written

        environment = self._environment()
        with mock.patch.dict(mode_module.os.environ, environment, clear=False):
            with mock.patch.object(mode_module.os, "write", side_effect=swap_root_after_write):
                with self.assertRaises(mode_module.UnsafePathError):
                    mode_module.append_event(
                        denial,
                        provider=mode_module.Provider.CODEX,
                        role=mode_module.Role.WORKER,
                        marker=mode_module.Marker.ACTIVE,
                        source=mode_module.Source.PARSER,
                        config_state=mode_module.ConfigState.MISSING,
                    )
        self.assertTrue(swapped)
        self.assertFalse(
            (self.state_home / "eci" / "command-gate" / "would-deny.jsonl").exists()
        )

    def test_default_alias_resolution_must_be_stable(self) -> None:
        mode_module = self._load_mode_module()
        logical_path = self.root / "unresolved-state"
        resolutions = (
            str(self.root / "first-state"),
            str(self.root / "second-state"),
        )
        with mock.patch.object(mode_module.os.path, "realpath", side_effect=resolutions):
            with self.assertRaises(mode_module.UnsafePathError):
                mode_module._resolve_default_path_twice(logical_path)

    def test_canonical_component_swap_is_rejected_during_traversal(self) -> None:
        mode_module = self._load_mode_module()
        traversal_parent = self.root / "traversal-parent"
        traversal_parent.mkdir(mode=0o700)
        state_root = traversal_parent / "state"
        state_root.mkdir(mode=0o700)
        moved_root = traversal_parent / "moved-state"
        parent_identity = traversal_parent.stat()
        original_open = mode_module.os.open
        swapped = False

        def swap_component_before_open(
            path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ) -> int:
            nonlocal swapped
            if path == "state" and dir_fd is not None:
                metadata = os.fstat(dir_fd)
                if (
                    metadata.st_dev == parent_identity.st_dev
                    and metadata.st_ino == parent_identity.st_ino
                    and not swapped
                ):
                    state_root.rename(moved_root)
                    state_root.symlink_to(moved_root, target_is_directory=True)
                    swapped = True
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(mode_module.os, "open", side_effect=swap_component_before_open):
            with self.assertRaises(mode_module.UnsafePathError):
                with mode_module._opened_canonical_directory(state_root, create=False):
                    self.fail("swapped canonical root was opened")
        self.assertTrue(swapped)

    def test_log_rotation_and_concurrent_append(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        seed = self._finalize(self._sample_denial())
        self.assertEqual(seed.returncode, 0, seed.stderr)
        log_dir = self.state_home / "eci" / "command-gate"
        log = log_dir / "would-deny.jsonl"
        seed_record = log.read_bytes()
        seed_count = 1_048_576 // len(seed_record) + 1
        log.write_bytes(seed_record * seed_count)
        log.chmod(0o600)
        sentinel = log_dir / "unrelated-sentinel"
        sentinel.write_bytes(b"unchanged\n")
        invocations = [
            (provider, role, marker, source)
            for provider in ("codex", "kimi")
            for role in ("coordinator", "worker")
            for marker in ("active", "inactive")
            for source in ("parser", "legacy")
        ]
        barrier = threading.Barrier(len(invocations) + 1)
        results: list[subprocess.CompletedProcess[bytes] | None] = [
            None for _ in invocations
        ]

        def invoke(index: int, arguments: tuple[str, str, str, str]) -> None:
            barrier.wait(timeout=5)
            results[index] = subprocess.run(
                [str(MODE_BIN), "finalize", *arguments],
                input=self._sample_denial(),
                capture_output=True,
                check=False,
                env=self._environment(),
                timeout=10,
            )

        threads = [
            threading.Thread(target=invoke, args=(index, arguments), daemon=True)
            for index, arguments in enumerate(invocations)
        ]
        for thread in threads:
            thread.start()
        barrier.wait(timeout=5)
        for thread in threads:
            thread.join(timeout=12)
            self.assertFalse(thread.is_alive(), "concurrent finalizer exceeded bound")
        for result in results:
            self.assertIsNotNone(result)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"")
        family = [
            path
            for path in (log, *(log_dir / f"would-deny.jsonl.{index}" for index in range(1, 5)))
            if path.exists()
        ]
        records = [line for path in family for line in path.read_bytes().splitlines()]
        self.assertEqual(len(records), seed_count + len(invocations))
        for record in records:
            json.loads(record)
        for path in family:
            metadata = path.stat()
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
            self.assertEqual(metadata.st_nlink, 1)
        self.assertLessEqual(len(family), 5)
        self.assertFalse((log_dir / "would-deny.jsonl.5").exists())
        self.assertEqual(sentinel.read_bytes(), b"unchanged\n")

    def test_provider_enforcing_and_permissive_parser_parity(self) -> None:
        for mode in ("enforcing", "permissive"):
            self.assertEqual(self._set_mode(mode).returncode, 0)
            for provider in ("codex", "kimi"):
                for role in ("coordinator", "worker"):
                    for active in (False, True):
                        with self.subTest(
                            mode=mode, provider=provider, role=role, active=active
                        ):
                            before = self._event_count()
                            result = self._run_hook(
                                provider, "env", role=role, active=active
                            )
                            self.assertEqual(result.returncode, 0, result.stderr)
                            if mode == "enforcing":
                                self.assertIn("ECI_ENVIRONMENT_ENUMERATION_DENIED", result.stdout)
                            else:
                                self.assertEqual(result.stdout, "")
                                self.assertEqual(len(self._events()), before + 1)

    def test_permissive_syntax_and_protected_corpus_logs_first_denial(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        cases = (
            "FOO=bar novel-tool",
            "printf '%s\\n' *",
            "printf hi > /tmp/eci-mode-output | sed -n '1p'",
            "true && env",
            "cat AGENTS.md 2>/dev/null",
            "env | rm -rf /",
        )
        for provider in ("codex", "kimi"):
            for command in cases:
                with self.subTest(provider=provider, command=command):
                    before = self._event_count()
                    result = self._run_hook(provider, command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(len(self._events()), before + 1)
        self.assertTrue(all("command" not in event for event in self._events()))

    def test_allowed_command_has_no_telemetry(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        for provider in ("codex", "kimi"):
            result = self._run_hook(provider, "adb devices -l", role="worker")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
        self.assertFalse((self.state_home / "eci" / "command-gate" / "would-deny.jsonl").exists())

    def test_invalid_config_enforces_without_reducing_denial(self) -> None:
        config_dir = self.config_home / "eci"
        config_dir.mkdir(parents=True, mode=0o700)
        config = config_dir / "command-gate-mode"
        config.write_text("permissive\r\n", encoding="utf-8")
        config.chmod(0o600)
        denial = self._sample_denial("raw-value-must-not-appear")
        result = self._finalize(denial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, denial)
        self.assertFalse(
            (self.state_home / "eci" / "command-gate" / "would-deny.jsonl").exists()
        )

    def test_permissive_protected_corpus_allows_and_logs(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        for provider in ("codex", "kimi"):
            lifecycle = (
                CODEX_ROOT / "bin" / "eci-active"
                if provider == "codex"
                else KIMI_ROOT / "bin" / "eci-active"
            )
            session_id = (
                "codex-command-gate-mode"
                if provider == "codex"
                else "session_22222222-2222-4222-8222-222222222222"
            )
            marker = self.root / f"{provider}-proof" / session_id / "eci_active"
            cases = (
                ("worker", "git commit -m sample"),
                ("worker", "git reset --hard"),
                ("worker", "git worktree add /tmp/eci-mode-worktree"),
                ("worker", f"cat {marker}"),
                ("coordinator", "chmod +x hooks/validate-bash.sh"),
                ("coordinator", f"{lifecycle} unknown-verb"),
            )
            for role, command in cases:
                with self.subTest(provider=provider, role=role, command=command):
                    before = self._event_count()
                    result = self._run_hook(provider, command, role=role)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(self._event_count(), before + 1)

    def test_wrappers_have_one_finalizer_for_parser_and_legacy_denials(self) -> None:
        for root in (CODEX_ROOT, KIMI_ROOT):
            source = (root / "hooks" / "validate-bash.sh").read_text(encoding="utf-8")
            self.assertIn("finalize_command_gate_denial parser \"$plan_output\"", source)
            self.assertIn("finalize_command_gate_denial legacy \"$denial\"", source)
            self.assertNotIn("printf '%s\\n' \"$plan_output\"\n    exit 0", source)

    def test_enforcing_worker_mode_set_is_owned_by_coordinator(self) -> None:
        self.assertEqual(self._set_mode("enforcing").returncode, 0)
        for provider in ("codex", "kimi"):
            for active in (False, True):
                for target in (CODEX_ROOT, KIMI_ROOT):
                    command = f"{target}/bin/eci-command-gate-mode set permissive"
                    with self.subTest(provider=provider, active=active, target=target):
                        result = self._run_hook(
                            provider,
                            command,
                            role="worker",
                            active=active,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("[ECI_CONTROL_OWNER_REQUIRED]", result.stdout)
                        self.assertIn("operation=worker-control", result.stdout)
                        self.assertIn("predicate=gate-mode-mutation", result.stdout)
                        observed = subprocess.run(
                            [str(MODE_BIN), "get"],
                            text=True,
                            capture_output=True,
                            check=False,
                            env=self._environment(),
                        )
                        self.assertEqual(json.loads(observed.stdout)["mode"], "enforcing")

    def test_permissive_worker_mode_set_logs_then_executes(self) -> None:
        for provider in ("codex", "kimi"):
            for active in (False, True):
                for target in (CODEX_ROOT, KIMI_ROOT):
                    self.assertEqual(self._set_mode("permissive").returncode, 0)
                    command = f"{target}/bin/eci-command-gate-mode set enforcing"
                    with self.subTest(provider=provider, active=active, target=target):
                        before = self._event_count()
                        disposition = self._run_hook(
                            provider,
                            command,
                            role="worker",
                            active=active,
                        )
                        self.assertEqual(disposition.returncode, 0, disposition.stderr)
                        self.assertEqual(disposition.stdout, "")
                        self.assertEqual(self._event_count(), before + 1)
                        event = self._events()[-1]
                        self.assertEqual(event["code"], "ECI_CONTROL_OWNER_REQUIRED")
                        execution = subprocess.run(
                            [str(target / "bin" / "eci-command-gate-mode"), "set", "enforcing"],
                            text=True,
                            capture_output=True,
                            check=False,
                            env=self._environment(),
                        )
                        self.assertEqual(execution.returncode, 0, execution.stderr)
                        observed = subprocess.run(
                            [str(MODE_BIN), "get"],
                            text=True,
                            capture_output=True,
                            check=False,
                            env=self._environment(),
                        )
                        self.assertEqual(json.loads(observed.stdout)["mode"], "enforcing")

    def test_coordinator_mode_set_and_worker_get_are_admitted(self) -> None:
        self.assertEqual(self._set_mode("permissive").returncode, 0)
        for provider in ("codex", "kimi"):
            for active in (False, True):
                for target in (CODEX_ROOT, KIMI_ROOT):
                    with self.subTest(provider=provider, active=active, target=target):
                        get_result = self._run_hook(
                            provider,
                            f"{target}/bin/eci-command-gate-mode get",
                            role="worker",
                            active=active,
                        )
                        self.assertEqual(get_result.returncode, 0, get_result.stderr)
                        self.assertEqual(get_result.stdout, "")
                        set_result = self._run_hook(
                            provider,
                            f"{target}/bin/eci-command-gate-mode set permissive",
                            role="coordinator",
                            active=active,
                        )
                        self.assertEqual(set_result.returncode, 0, set_result.stderr)
                        self.assertEqual(set_result.stdout, "")
        self.assertFalse(
            (self.state_home / "eci" / "command-gate" / "would-deny.jsonl").exists()
        )

    def test_mode_set_wrappers_path_and_first_denial(self) -> None:
        self.assertEqual(self._set_mode("enforcing").returncode, 0)
        target = CODEX_ROOT / "bin" / "eci-command-gate-mode"
        commands = (
            "eci-command-gate-mode set",
            f"env FOO=bar {target} set invalid extra",
            f"env -- FOO=bar {target} set enforcing",
            f"timeout 1 {target} set permissive",
            f"python3 {target} set enforcing",
            f"printf before && {target} set enforcing && env",
        )
        for provider in ("codex", "kimi"):
            for command in commands:
                with self.subTest(provider=provider, command=command):
                    result = self._run_hook(provider, command, role="worker")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("[ECI_CONTROL_OWNER_REQUIRED]", result.stdout)
                    self.assertIn("predicate=gate-mode-mutation", result.stdout)
                    self.assertNotIn("ECI_ENVIRONMENT_ENUMERATION_DENIED", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
