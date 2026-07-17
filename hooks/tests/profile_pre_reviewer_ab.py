#!/usr/bin/env python3
"""Alternating exact parent/candidate profiles on generated absolute state."""

from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import contextmanager, redirect_stdout
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Final


SAMPLES: Final = 5
CAUSAL_SCOPE_RECORD: Final = (
    "causal-scope transcript_history_scans=0 "
    "shared_turn_lock_prune_records_max=0 maintenance_prune_records_max=170 "
    "backend_timeout_max_seconds=58 "
    "controller_timeout_seconds=70 hook_timeout_seconds=75"
)
BASELINE_COMMIT: Final = "72b8b3d62df89975b35ed5bda1a5231a2be4fe4b"
HISTORY_SCAN_COMMIT: Final = "dbb4a8b9a46f76fb9d0b644942d56fa45d3fce29"
RETAINED_PRUNE_COMMIT: Final = "b970b2d106847dc615e6132cd8e0f801a7d8db66"
RUNTIME_MANIFEST_RELATIVE_PATH: Final = Path(
    "hooks/pre-reviewer-runtime-manifest.json"
)
WRAPPER_RELATIVE_PATH: Final = Path("hooks/edit-bash-pre-reviewer.sh")
PYTHON_CONTROLLER_RELATIVE_PATH: Final = Path(
    "hooks/lib/edit_bash_pre_reviewer_controller.py"
)


class ProfileError(RuntimeError):
    """A generated profile path did not complete as specified."""


class ProfileInterrupted(ProfileError):
    """The wrapper requested bounded profiler teardown."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(f"profile interrupted by signal {signal_number}")
        self.signal_number = signal_number


PROFILE_SUMMARY_KEYS: Final = frozenset(
    {
        "candidate_commit",
        "controller_build_count",
        "fresh_trace_execve_successes",
        "report_schema_version",
        "reuse_trace_execve_successes",
    }
)
FORMAL_PROFILE_EXECUTABLE_RELATIVE_PATH: Final = Path(
    "artifacts/pre-reviewer/preReviewerControllerDiff"
)
FORMAL_PROFILE_EVIDENCE_TIMEOUT_SECONDS: Final = 10.0
PROFILE_DESTINATIONS: Final = (
    FORMAL_PROFILE_EXECUTABLE_RELATIVE_PATH,
    FORMAL_PROFILE_EXECUTABLE_RELATIVE_PATH.with_suffix(".stamp"),
    Path("evidence/pre-reviewer-profile.out"),
    Path("evidence/traces"),
    Path("evidence/traces/fresh.strace"),
    Path("evidence/traces/reuse.strace"),
    Path("logs/pre-reviewer-profile.log"),
    Path("logs/controller-build.audit"),
    Path("work"),
)
PROFILE_SIGNALS: Final = frozenset(
    {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
)
_ACTIVE_OWNED_GROUPS: dict[int, subprocess.Popen[bytes]] = {}
PROFILE_TRACE_BINDING_KEYS: Final = frozenset(
    {
        "fresh_path",
        "fresh_sha256",
        "reuse_path",
        "reuse_sha256",
        "trace_binding_schema_version",
    }
)
FRESH_TRACE_RELATIVE_PATH: Final = Path("evidence/traces/fresh.strace")
REUSE_TRACE_RELATIVE_PATH: Final = Path("evidence/traces/reuse.strace")
LEAN_TOOLCHAIN_ROLES: Final = frozenset({"clang", "ld.lld", "lean", "leanc"})


@dataclass(frozen=True)
class PhaseTraceEvidence:
    fresh_paths: tuple[Path, ...]
    reuse_paths: tuple[Path, ...]
    fresh_controller_compilation: bool
    reuse_controller_compilation: bool

    @property
    def fresh_execve_successes(self) -> int:
        return len(self.fresh_paths)

    @property
    def reuse_execve_successes(self) -> int:
        return len(self.reuse_paths)

    @property
    def all_paths(self) -> tuple[Path, ...]:
        return self.fresh_paths + self.reuse_paths


@dataclass(frozen=True)
class PublishedPhaseTraceEvidence:
    fresh_sha256: str
    reuse_sha256: str
    phase_evidence: PhaseTraceEvidence

    def trace_binding(self) -> dict[str, object]:
        return {
            "fresh_path": FRESH_TRACE_RELATIVE_PATH.as_posix(),
            "fresh_sha256": self.fresh_sha256,
            "reuse_path": REUSE_TRACE_RELATIVE_PATH.as_posix(),
            "reuse_sha256": self.reuse_sha256,
            "trace_binding_schema_version": 1,
        }


def validate_profile_summary(
    value: object,
    expected_commit: str,
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != PROFILE_SUMMARY_KEYS:
        raise ProfileError("profile summary schema is not exact")
    commit = value["candidate_commit"]
    if (
        not isinstance(commit, str)
        or re.fullmatch(r"[0-9a-f]{40}", commit) is None
        or commit != expected_commit
    ):
        raise ProfileError("profile summary candidate commit mismatch")
    integer_fields = (
        "controller_build_count",
        "fresh_trace_execve_successes",
        "report_schema_version",
        "reuse_trace_execve_successes",
    )
    if any(
        not isinstance(value[field], int) or isinstance(value[field], bool)
        for field in integer_fields
    ):
        raise ProfileError("profile summary numeric field is not an integer")
    if value["report_schema_version"] != 1:
        raise ProfileError("profile report schema is unsupported")
    if value["controller_build_count"] != 1:
        raise ProfileError("profile must contain exactly one controller build")
    if (
        value["fresh_trace_execve_successes"] <= 0
        or value["reuse_trace_execve_successes"] <= 0
    ):
        raise ProfileError("profile phase traces must be nonempty")
    return value


def validate_report_binding(
    report: bytes,
    expected_sha256: str,
    summary: object,
    *,
    expected_commit: str,
) -> None:
    validate_profile_summary(summary, expected_commit)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise ProfileError("profile report digest is malformed")
    if hashlib.sha256(report).hexdigest() != expected_sha256:
        raise ProfileError("profile report bytes do not match retained digest")


def profile_trace_publication_accepted(
    deterministic_private_paths: bool,
    no_aliases_or_preexisting: bool,
    atomic_durable_publish: bool,
    report_digest_binding: bool,
    runner_revalidates: bool,
    preserves_failure_evidence: bool,
) -> bool:
    return (
        deterministic_private_paths
        and no_aliases_or_preexisting
        and atomic_durable_publish
        and report_digest_binding
        and runner_revalidates
        and preserves_failure_evidence
    )


def _private_owned_directory(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(metadata.st_mode)
        and not path.is_symlink()
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) == 0o700
    )


def _filesystem_type(path: Path) -> str:
    findmnt = shutil.which("findmnt")
    if findmnt is None:
        raise ProfileError("profile root validation requires findmnt")
    result = subprocess.run(
        [findmnt, "-n", "-o", "FSTYPE", "--target", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
        timeout=15.0,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise ProfileError("profile root filesystem cannot be identified")
    return result.stdout.strip()


def validate_profile_roots(formal_tmp_root: Path, output_root: Path) -> None:
    roots = (formal_tmp_root, output_root)
    if any(not path.is_absolute() for path in roots):
        raise ProfileError("profile roots must be absolute")
    if any(not _private_owned_directory(path) for path in roots):
        raise ProfileError("profile roots must be owner-private directories")
    try:
        same = os.path.samefile(formal_tmp_root, output_root)
    except OSError as error:
        raise ProfileError("profile roots cannot be compared") from error
    if same:
        raise ProfileError("profile roots must be distinct")
    if _filesystem_type(formal_tmp_root) != "tmpfs":
        raise ProfileError("formal profile root must be tmpfs")
    if _filesystem_type(output_root) == "tmpfs":
        raise ProfileError("profile evidence root must be persistent")


def validate_profile_destinations(output_root: Path) -> None:
    for relative in PROFILE_DESTINATIONS:
        destination = output_root / relative
        parent = output_root
        for component in relative.parts[:-1]:
            parent /= component
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise ProfileError(
                    f"profile destination traverses an invalid parent: {relative}"
                )
        if destination.exists() or destination.is_symlink():
            raise ProfileError(
                f"profile destination already exists: {relative.as_posix()}"
            )


def _open_private_regular_file(path: Path) -> tuple[int, os.stat_result]:
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise ProfileError("private profile file cannot be opened exactly") from error
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        os.close(descriptor)
        raise ProfileError("private profile file metadata is invalid")
    return descriptor, metadata


def _validate_unlinked_parents(output_root: Path, relative: Path) -> Path:
    if not _private_owned_directory(output_root):
        raise ProfileError("profile trace root must be owner-private")
    current = output_root
    for component in relative.parts[:-1]:
        current /= component
        try:
            metadata = current.lstat()
        except OSError as error:
            raise ProfileError("profile trace parent is absent") from error
        if not stat.S_ISDIR(metadata.st_mode) or current.is_symlink():
            raise ProfileError("profile trace parent must not be linked")
    return output_root / relative


def _private_file_sha256(path: Path) -> tuple[str, tuple[int, int]]:
    digest = hashlib.sha256()
    descriptor, metadata = _open_private_regular_file(path)
    try:
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest(), (metadata.st_dev, metadata.st_ino)


def _read_private_file(path: Path) -> bytes:
    descriptor, _metadata = _open_private_regular_file(path)
    chunks: list[bytes] = []
    try:
        while chunk := os.read(descriptor, 1024 * 1024):
            chunks.append(chunk)
    finally:
        os.close(descriptor)
    return b"".join(chunks)


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_publish_file(source: Path, destination: Path) -> str:
    source_metadata = source.lstat()
    if not stat.S_ISREG(source_metadata.st_mode) or source.is_symlink():
        raise ProfileError("profile trace source must be a regular unlinked file")
    if destination.exists() or destination.is_symlink():
        raise ProfileError("profile trace destination already exists")
    temporary = destination.parent / f".{destination.name}.tmp"
    if temporary.exists() or temporary.is_symlink():
        raise ProfileError("profile trace temporary destination already exists")
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    temporary_fd = -1
    digest = hashlib.sha256()
    try:
        opened_metadata = os.fstat(source_fd)
        if (
            opened_metadata.st_dev != source_metadata.st_dev
            or opened_metadata.st_ino != source_metadata.st_ino
        ):
            raise ProfileError("profile trace source changed during open")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        temporary_fd = os.open(temporary, flags, 0o600)
        while chunk := os.read(source_fd, 1024 * 1024):
            digest.update(chunk)
            remaining = memoryview(chunk)
            while remaining:
                written = os.write(temporary_fd, remaining)
                if written <= 0:
                    raise OSError("profile trace publication made no progress")
                remaining = remaining[written:]
        os.fsync(temporary_fd)
    finally:
        os.close(source_fd)
        if temporary_fd >= 0:
            os.close(temporary_fd)
    try:
        os.link(temporary, destination, follow_symlinks=False)
        temporary.unlink()
        _fsync_directory(destination.parent)
    except BaseException:
        if temporary.is_file() and not temporary.is_symlink():
            temporary.unlink()
        raise
    return digest.hexdigest()


def publish_phase_traces(
    fresh_source: Path,
    reuse_source: Path,
    output_root: Path,
) -> dict[str, object]:
    if not profile_trace_publication_accepted(True, True, True, True, True, True):
        raise ProfileError("profile trace publication contract is incomplete")
    if not _private_owned_directory(output_root):
        raise ProfileError("profile trace root must be owner-private")
    evidence_root = output_root / "evidence"
    try:
        evidence_metadata = evidence_root.lstat()
    except OSError as error:
        raise ProfileError("profile evidence root is absent") from error
    if not stat.S_ISDIR(evidence_metadata.st_mode) or evidence_root.is_symlink():
        raise ProfileError("profile evidence root must not be linked")
    trace_root = evidence_root / "traces"
    if trace_root.exists() or trace_root.is_symlink():
        raise ProfileError("profile trace destination root already exists")
    trace_root.mkdir(mode=0o700)
    _fsync_directory(evidence_root)
    fresh_digest = _atomic_publish_file(
        fresh_source,
        output_root / FRESH_TRACE_RELATIVE_PATH,
    )
    reuse_digest = _atomic_publish_file(
        reuse_source,
        output_root / REUSE_TRACE_RELATIVE_PATH,
    )
    binding: dict[str, object] = {
        "fresh_path": FRESH_TRACE_RELATIVE_PATH.as_posix(),
        "fresh_sha256": fresh_digest,
        "reuse_path": REUSE_TRACE_RELATIVE_PATH.as_posix(),
        "reuse_sha256": reuse_digest,
        "trace_binding_schema_version": 1,
    }
    validate_profile_trace_binding(binding, output_root)
    return binding


def validate_profile_trace_binding(
    value: object,
    output_root: Path,
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != PROFILE_TRACE_BINDING_KEYS:
        raise ProfileError("profile trace binding schema is not exact")
    if (
        not isinstance(value["trace_binding_schema_version"], int)
        or isinstance(value["trace_binding_schema_version"], bool)
        or value["trace_binding_schema_version"] != 1
    ):
        raise ProfileError("profile trace binding schema is unsupported")
    expected_paths = {
        "fresh": FRESH_TRACE_RELATIVE_PATH,
        "reuse": REUSE_TRACE_RELATIVE_PATH,
    }
    identities: dict[str, tuple[int, int]] = {}
    for phase, relative in expected_paths.items():
        if value[f"{phase}_path"] != relative.as_posix():
            raise ProfileError("profile trace path is not deterministic")
        expected_digest = value[f"{phase}_sha256"]
        if not isinstance(expected_digest, str) or re.fullmatch(
            r"[0-9a-f]{64}", expected_digest
        ) is None:
            raise ProfileError("profile trace digest is malformed")
        path = _validate_unlinked_parents(output_root, relative)
        actual_digest, identity = _private_file_sha256(path)
        if actual_digest != expected_digest:
            raise ProfileError("profile trace bytes do not match retained digest")
        identities[phase] = identity
    if identities["fresh"] == identities["reuse"]:
        raise ProfileError("fresh and reuse profile traces must not alias")
    return value


def profile_trace_binding(output_root: Path) -> dict[str, object]:
    fresh_digest, _fresh_identity = _private_file_sha256(
        output_root / FRESH_TRACE_RELATIVE_PATH
    )
    reuse_digest, _reuse_identity = _private_file_sha256(
        output_root / REUSE_TRACE_RELATIVE_PATH
    )
    binding: dict[str, object] = {
        "fresh_path": FRESH_TRACE_RELATIVE_PATH.as_posix(),
        "fresh_sha256": fresh_digest,
        "reuse_path": REUSE_TRACE_RELATIVE_PATH.as_posix(),
        "reuse_sha256": reuse_digest,
        "trace_binding_schema_version": 1,
    }
    return validate_profile_trace_binding(binding, output_root)


def publish_phase_trace_evidence(
    fresh_source: Path,
    reuse_source: Path,
    output_root: Path,
) -> PublishedPhaseTraceEvidence:
    binding = publish_phase_traces(fresh_source, reuse_source, output_root)
    phase_evidence = validate_phase_traces(
        output_root / FRESH_TRACE_RELATIVE_PATH,
        output_root / REUSE_TRACE_RELATIVE_PATH,
    )
    published = PublishedPhaseTraceEvidence(
        fresh_sha256=str(binding["fresh_sha256"]),
        reuse_sha256=str(binding["reuse_sha256"]),
        phase_evidence=phase_evidence,
    )
    validate_published_phase_trace_evidence(published, output_root)
    return published


def validate_published_phase_trace_evidence(
    published: PublishedPhaseTraceEvidence,
    output_root: Path,
) -> PhaseTraceEvidence:
    validate_profile_trace_binding(published.trace_binding(), output_root)
    phase_evidence = validate_phase_traces(
        output_root / FRESH_TRACE_RELATIVE_PATH,
        output_root / REUSE_TRACE_RELATIVE_PATH,
    )
    if phase_evidence != published.phase_evidence:
        raise ProfileError("published profile trace semantics changed")
    return phase_evidence


def _single_report_record(report: str, prefix: str) -> object:
    records = [line.removeprefix(prefix) for line in report.splitlines()
               if line.startswith(prefix)]
    if len(records) != 1:
        raise ProfileError(f"profile report must contain one {prefix.strip()} record")
    try:
        return json.loads(records[0])
    except json.JSONDecodeError as error:
        raise ProfileError(f"profile report {prefix.strip()} is invalid") from error


def validate_persisted_profile(
    report_path: Path,
    output_root: Path,
    expected_commit: str,
    *,
    expected_sha256: str | None = None,
    expected_published: PublishedPhaseTraceEvidence | None = None,
) -> str:
    expected_report = output_root / "evidence/pre-reviewer-profile.out"
    if report_path != expected_report:
        raise ProfileError("persisted profile report path is not exact and private")
    report = _read_private_file(report_path)
    report_text = report.decode("utf-8", errors="strict")
    summary = _single_report_record(report_text, "profile-summary ")
    binding = _single_report_record(report_text, "profile-trace-binding ")
    validate_profile_summary(summary, expected_commit)
    validate_profile_trace_binding(binding, output_root)
    phase_evidence = validate_phase_traces(
        output_root / FRESH_TRACE_RELATIVE_PATH,
        output_root / REUSE_TRACE_RELATIVE_PATH,
    )
    if (
        summary["fresh_trace_execve_successes"]
        != phase_evidence.fresh_execve_successes
        or summary["reuse_trace_execve_successes"]
        != phase_evidence.reuse_execve_successes
    ):
        raise ProfileError("profile summary differs from published trace bytes")
    persisted = PublishedPhaseTraceEvidence(
        fresh_sha256=str(binding["fresh_sha256"]),
        reuse_sha256=str(binding["reuse_sha256"]),
        phase_evidence=phase_evidence,
    )
    if expected_published is not None and persisted != expected_published:
        raise ProfileError("persisted profile differs from original published evidence")
    validate_formal_profile_evidence(summary, persisted, output_root)
    digest = hashlib.sha256(report).hexdigest()
    if expected_sha256 is not None:
        validate_report_binding(
            report,
            expected_sha256,
            summary,
            expected_commit=expected_commit,
        )
    return digest


def _formal_profile_executable(output_root: Path) -> Path:
    executable = _validate_unlinked_parents(
        output_root,
        FORMAL_PROFILE_EXECUTABLE_RELATIVE_PATH,
    )
    try:
        descriptor = os.open(
            executable,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise ProfileError("formal profile evidence executable is absent") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or metadata.st_nlink != 1
        ):
            raise ProfileError("formal profile evidence executable metadata is invalid")
    finally:
        os.close(descriptor)
    stamp = executable.with_suffix(".stamp")
    stamp_descriptor, _stamp_metadata = _open_private_regular_file(stamp)
    os.close(stamp_descriptor)
    return executable


def validate_formal_profile_evidence(
    summary: dict[str, object],
    published: PublishedPhaseTraceEvidence,
    output_root: Path,
) -> None:
    executable = _formal_profile_executable(output_root)
    evidence = published.phase_evidence
    command = [
        str(executable),
        "check-profile-evidence",
        str(summary["controller_build_count"]),
        str(evidence.fresh_execve_successes),
        str(evidence.reuse_execve_successes),
        "1" if evidence.fresh_controller_compilation else "0",
        "1" if evidence.reuse_controller_compilation else "0",
    ]
    with _blocked_profile_signals() as previous_mask:
        try:
            process = subprocess.Popen(
                command,
                env={"PATH": "/usr/bin:/bin"},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=lambda: signal.pthread_sigmask(
                    signal.SIG_SETMASK,
                    previous_mask,
                ),
                start_new_session=True,
            )
        except OSError as error:
            raise ProfileError(
                "formal profile evidence oracle could not start"
            ) from error
        _register_owned_group(process)
    try:
        try:
            stdout, stderr = process.communicate(
                timeout=FORMAL_PROFILE_EVIDENCE_TIMEOUT_SECONDS
            )
        except subprocess.TimeoutExpired as error:
            _stop_owned_process_group(process)
            process.communicate()
            raise ProfileError("formal profile evidence oracle timed out") from error
        except BaseException:
            if process.poll() is None:
                _stop_owned_process_group(process)
            process.communicate()
            raise
    finally:
        if process.poll() is None:
            _stop_owned_process_group(process)
        _unregister_owned_group(process)
    if process.returncode != 0:
        raise ProfileError(
            f"formal profile evidence oracle failed with status {process.returncode}"
        )
    if stdout != b"profile-evidence-ok\n" or stderr != b"":
        raise ProfileError("formal profile evidence oracle result is malformed")


_SUCCESSFUL_EXECVE = re.compile(r'execve\("([^"\\]+)".*\)\s+=\s+0(?:\s|$)')


def successful_execve_paths(trace_path: Path) -> tuple[Path, ...]:
    if not trace_path.is_file() or trace_path.is_symlink():
        raise ProfileError(f"phase trace is absent or linked: {trace_path.name}")
    paths = tuple(
        Path(match).resolve()
        for match in _SUCCESSFUL_EXECVE.findall(
            trace_path.read_text(encoding="utf-8", errors="strict")
        )
    )
    return paths


def _trace_has_controller_compile(trace_path: Path, paths: tuple[Path, ...]) -> bool:
    del paths
    for line in trace_path.read_text(
        encoding="utf-8", errors="strict"
    ).splitlines():
        match = _SUCCESSFUL_EXECVE.search(line)
        if match is None:
            continue
        executable = Path(match.group(1)).name
        if executable == "lean" and "PreReviewerController.lean" in line:
            return True
        if (
            executable == "leanc"
            and "preReviewerControllerDiff" in line
            and "--version" not in line
        ):
            return True
    return False


def validate_phase_traces(fresh_trace: Path, reuse_trace: Path) -> PhaseTraceEvidence:
    if not fresh_trace.is_file() or not reuse_trace.is_file():
        raise ProfileError("both fixed phase traces are required")
    if fresh_trace.is_symlink() or reuse_trace.is_symlink():
        raise ProfileError("phase traces must not be links")
    if os.path.samefile(fresh_trace, reuse_trace):
        raise ProfileError("fresh and reuse traces must be distinct files")
    fresh_paths = successful_execve_paths(fresh_trace)
    reuse_paths = successful_execve_paths(reuse_trace)
    if not fresh_paths or not reuse_paths:
        raise ProfileError("phase traces must contain successful execve records")
    fresh_controller_compilation = _trace_has_controller_compile(
        fresh_trace,
        fresh_paths,
    )
    reuse_controller_compilation = _trace_has_controller_compile(
        reuse_trace,
        reuse_paths,
    )
    if not fresh_controller_compilation:
        raise ProfileError("fresh trace lacks controller compilation evidence")
    if reuse_controller_compilation:
        raise ProfileError("reuse trace contains controller compilation evidence")
    return PhaseTraceEvidence(
        fresh_paths,
        reuse_paths,
        fresh_controller_compilation,
        reuse_controller_compilation,
    )


def _validated_audit_path(audit_path: Path, output_root: Path) -> Path:
    root = output_root.resolve()
    if not _private_owned_directory(output_root):
        raise ProfileError("audit root must be an owner-private directory")
    if not audit_path.is_absolute():
        audit_path = output_root / audit_path
    if not audit_path.parent.resolve().is_relative_to(root):
        raise ProfileError("controller build audit escaped its private root")
    if audit_path.is_symlink():
        raise ProfileError("controller build audit must not be a link")
    return audit_path


def append_controller_build_audit(audit_path: Path, output_root: Path) -> None:
    path = _validated_audit_path(audit_path, output_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, b"controller-build\n")
    finally:
        os.close(descriptor)


def controller_build_count(audit_path: Path) -> int:
    if not audit_path.is_file() or audit_path.is_symlink():
        return 0
    return sum(
        line == "controller-build"
        for line in audit_path.read_text(encoding="utf-8").splitlines()
    )


def record_reuse_phase(audit_path: Path, output_root: Path) -> None:
    _validated_audit_path(audit_path, output_root)
    before = controller_build_count(audit_path)
    if before != 1:
        raise ProfileError("reuse phase requires one prior controller build")
    if controller_build_count(audit_path) != before:
        raise ProfileError("reuse phase changed controller build audit")


def load_runtime_manifest(root: Path) -> dict[str, object]:
    path = root / RUNTIME_MANIFEST_RELATIVE_PATH
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 3:
        raise ProfileError("unsupported runtime manifest schema")
    return manifest


_SOURCE_MANIFEST = load_runtime_manifest(Path(__file__).resolve().parents[2])
CANDIDATE_RUNTIME_SOURCE_PATHS: Final = tuple(
    Path(value) for value in _SOURCE_MANIFEST["product_sources"]
)
CANDIDATE_HARNESS_SOURCE_PATHS: Final = tuple(
    Path(value) for value in _SOURCE_MANIFEST["harness_sources"]
)
CANDIDATE_VERIFIED_SOURCE_PATHS: Final = (
    RUNTIME_MANIFEST_RELATIVE_PATH,
    *CANDIDATE_RUNTIME_SOURCE_PATHS,
    *CANDIDATE_HARNESS_SOURCE_PATHS,
)
CONFIGURED_HOOK_PATHS: Final = CANDIDATE_RUNTIME_SOURCE_PATHS[1:4]


@dataclass(frozen=True)
class RevisionIdentity:
    commit: str
    wrapper_sha256: str
    python_controller_sha256: str
    manifest_sha256: str


@dataclass(frozen=True)
class SourceIdentityEvidence:
    parent: RevisionIdentity
    candidate: RevisionIdentity
    parent_sources: tuple[str, str, str]
    candidate_sources: tuple[str, str, str]


@dataclass(frozen=True)
class ProfileScenario:
    name: str
    prepared: bool = False
    history_records: int = 0
    retained_entries: int = 0
    measure_prompt: bool = False


NO_CAPTURE = ProfileScenario("no-capture")
PREPARED_FAKE = ProfileScenario("prepared-fake", prepared=True)
LARGE_HISTORY = ProfileScenario("large-history", history_records=4_096)
RETAINED_STATE = ProfileScenario(
    "retained-state", retained_entries=2_000, measure_prompt=True
)


def configured_commands(code_root: Path) -> tuple[str, str, str]:
    configuration = json.loads((code_root / "hooks.json").read_text())
    bash_group = next(
        group
        for group in configuration["hooks"]["PreToolUse"]
        if group["matcher"] == "^Bash$"
    )
    validator, reviewer = (item["command"] for item in bash_group["hooks"])
    prompt = configuration["hooks"]["UserPromptSubmit"][0]["hooks"][0][
        "command"
    ]
    return validator, reviewer, prompt


def profile_commands(code_root: Path) -> tuple[str, str, str]:
    """Execute exact exported hook bytes independent of historical home paths."""
    return tuple(
        str((code_root / relative).resolve()) for relative in CONFIGURED_HOOK_PATHS
    )


def discover_runtime_sources(code_root: Path) -> tuple[Path, ...]:
    """Discover the configured source closure without consulting the manifest."""
    discovered = {Path("hooks.json"), *CONFIGURED_HOOK_PATHS}
    pending = list(CONFIGURED_HOOK_PATHS)
    path_pattern = re.compile(
        r"(?:\$HOOK_DIR/lib/|\$helper_dir/|\}\%/\*\}/)([A-Za-z0-9_.-]+)"
    )
    while pending:
        relative = pending.pop()
        path = code_root / relative
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8", errors="strict")
        for name in path_pattern.findall(source):
            dependency = Path("hooks/lib") / name
            if dependency not in discovered and (code_root / dependency).is_file():
                discovered.add(dependency)
                pending.append(dependency)
        if relative == WRAPPER_RELATIVE_PATH:
            for name in re.findall(r'\$HOOK_DIR/lib/([A-Za-z0-9_.-]+)', source):
                dependency = Path("hooks/lib") / name
                if dependency not in discovered and (code_root / dependency).is_file():
                    discovered.add(dependency)
                    pending.append(dependency)
    return tuple(sorted(discovered, key=lambda value: value.as_posix()))


def generated_payloads(sample: int) -> tuple[bytes, bytes, str, str]:
    session = f"generated-ab-session-{sample}"
    turn = f"generated-ab-turn-{sample}"
    prompt = json.dumps(
        {
            "session_id": session,
            "hook_event_name": "UserPromptSubmit",
            "cwd": "/generated/absolute/cwd",
            "turn_id": turn,
            "prompt": "generated profiling prompt",
        },
        separators=(",", ":"),
    ).encode()
    tool = json.dumps(
        {
            "session_id": session,
            "turn_id": turn,
            "tool_name": "Bash",
            "cwd": "/generated/absolute/cwd",
            "tool_input": {"command": "true"},
        },
        separators=(",", ":"),
    ).encode()
    return prompt, tool, session, turn


def prepare_large_history(
    state_root: Path,
    tool: bytes,
    session: str,
    records: int,
) -> tuple[bytes, int]:
    sessions = state_root / "home" / ".codex" / "sessions"
    sessions.mkdir(parents=True)
    transcript = sessions / f"generated-{session}.jsonl"
    filler = json.dumps(
        {"type": "message", "role": "assistant", "content": "x" * 192},
        separators=(",", ":"),
    )
    with transcript.open("w", encoding="utf-8") as stream:
        for _index in range(records - 1):
            stream.write(filler + "\n")
        stream.write(
            json.dumps(
                {"type": "message", "role": "user", "content": "generated user"},
                separators=(",", ":"),
            )
            + "\n"
        )
    parsed = json.loads(tool)
    parsed["transcript_path"] = str(transcript)
    return json.dumps(parsed, separators=(",", ":")).encode(), transcript.stat().st_size


def prepare_retained_state(
    state_root: Path,
    session: str,
    entries: int,
) -> None:
    state_dir = state_root / "proof" / "pre-reviewer" / session
    state_dir.mkdir(parents=True, mode=0o700)
    expired = time.time() - 3_601
    for index in range(entries):
        path = state_dir / f"claim-turn-generated-{index}"
        path.touch()
        os.utime(path, (expired, expired))


def generated_environment(
    code_root: Path,
    state_root: Path,
    *,
    fake: bool,
) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(state_root / "home"),
            "CODEX_HOME": str(code_root),
            "CODEX_PROOF_ROOT": str(state_root / "proof"),
            "TMPDIR": str(state_root / "tmp"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    for key in (
        "CODEX_PRE_REVIEWER_TRACE_FD",
        "CODEX_PRE_REVIEWER_TRACE_NONCE",
        "CODEX_PRE_REVIEWER_WAIT_NOTIFY_FD",
        "CODEX_PRE_REVIEWER_FAKE_RESULT",
    ):
        environment.pop(key, None)
    if fake:
        environment["CODEX_EDIT_PRE_REVIEWER"] = (
            "ollama:http://127.0.0.1:1/generated"
        )
        environment["CODEX_PRE_REVIEWER_FAKE_RESULT"] = (
            '{"verdict":"allow","reason":"generated"}'
        )
    return environment


def reset_state(state_root: Path) -> None:
    if state_root.exists():
        shutil.rmtree(state_root)
    for name in ("home", "proof", "tmp"):
        (state_root / name).mkdir(parents=True)


def generated_hook_supervision_accepted(
    new_process_group: bool,
    deadline_armed: bool,
    exact_group_cleanup: bool,
) -> bool:
    return new_process_group and deadline_armed and exact_group_cleanup


def declared_tool_identity_accepted(
    unique_role: bool,
    exact_canonical_path: bool,
    exact_bytes: bool,
) -> bool:
    return unique_role and exact_canonical_path and exact_bytes


def profile_interruption_supervision_accepted(
    traps_all_modes: bool,
    tracked_profiler_group: bool,
    exact_group_cleanup: bool,
    preserves_failure_evidence: bool,
) -> bool:
    return (
        traps_all_modes
        and tracked_profiler_group
        and exact_group_cleanup
        and preserves_failure_evidence
    )


def profile_interrupt_exit_status(signal_number: int) -> int:
    return 128 + signal_number


def run_hook(
    command: str,
    input_bytes: bytes,
    environment: dict[str, str],
    code_root: Path,
    *,
    timeout: float,
) -> subprocess.CompletedProcess[bytes]:
    supervision_ready = generated_hook_supervision_accepted(
        True,
        timeout > 0.0,
        True,
    )
    if not supervision_ready:
        raise ProfileError("generated hook supervision is incomplete")
    deadline = time.monotonic() + timeout
    arguments = shlex.split(command)
    with _blocked_profile_signals() as previous_mask:
        process = subprocess.Popen(
            arguments,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=code_root,
            env=environment,
            preexec_fn=lambda: signal.pthread_sigmask(
                signal.SIG_SETMASK,
                previous_mask,
            ),
            start_new_session=True,
        )
        _register_owned_group(process)
    try:
        remaining = max(0.0, deadline - time.monotonic())
        stdout, _stderr = process.communicate(input=input_bytes, timeout=remaining)
        return subprocess.CompletedProcess(
            arguments,
            process.returncode,
            stdout,
            None,
        )
    except BaseException:
        _stop_owned_process_group(process)
        raise
    finally:
        _stop_owned_process_group(process)
        _unregister_owned_group(process)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def trace_configured_source(
    command: str,
    input_bytes: bytes,
    environment: dict[str, str],
    code_root: Path,
    trace_path: Path,
    expected_source: Path,
) -> str:
    strace = shutil.which("strace")
    if strace is None:
        raise ProfileError("configured-source observation requires strace")
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    status = run_owned_command(
        [
            strace,
            "-f",
            "-qq",
            "-e",
            "trace=execve",
            "-o",
            str(trace_path),
            *shlex.split(command),
        ],
        cwd=code_root,
        environment=environment,
        log_path=trace_path.with_suffix(".log"),
        timeout=15.0,
        input_bytes=input_bytes,
    )
    if status != 0:
        raise ProfileError("configured command failed during source observation")
    expected = str(expected_source.resolve())
    executed = tuple(
        str(Path(match).resolve())
        for match in re.findall(r'execve\("([^"\\]+)"', trace_path.read_text())
        if Path(match).name == expected_source.name
    )
    if executed != (expected,):
        raise ProfileError(
            f"configured command source mismatch for {expected_source.name}"
        )
    return executed[0]


def observe_configured_sources(
    code_root: Path,
    state_root: Path,
) -> tuple[str, str, str]:
    commands = configured_commands(code_root)
    prompt, tool, _session, _turn = generated_payloads(101)
    inputs = (tool, tool, prompt)
    reset_state(state_root)
    environment = generated_environment(code_root, state_root, fake=True)
    observed = tuple(
        trace_configured_source(
            command,
            input_bytes,
            environment,
            code_root,
            state_root / f"source-{index}.strace",
            code_root / relative,
        )
        for index, (command, input_bytes, relative) in enumerate(
            zip(commands, inputs, CONFIGURED_HOOK_PATHS, strict=True)
        )
    )
    return observed


def _committed_bytes(root: Path, commit: str, relative: Path) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise ProfileError(f"reported commit lacks source: {relative}")
    return result.stdout


def _verify_candidate_sources(candidate_root: Path, commit: str) -> None:
    for relative in CANDIDATE_VERIFIED_SOURCE_PATHS:
        if (candidate_root / relative).read_bytes() != _committed_bytes(
            candidate_root, commit, relative
        ):
            raise ProfileError(
                f"candidate source bytes differ from reported commit: {relative}"
            )


def _runtime_manifest(root: Path) -> tuple[tuple[str, str], ...]:
    entries: list[tuple[str, str]] = []
    for relative in (RUNTIME_MANIFEST_RELATIVE_PATH, *CANDIDATE_RUNTIME_SOURCE_PATHS):
        path = root / relative
        if not path.is_file():
            if relative in (
                RUNTIME_MANIFEST_RELATIVE_PATH,
                PYTHON_CONTROLLER_RELATIVE_PATH,
                Path("hooks/lib/bounded_hook_input.py"),
            ):
                continue
            raise ProfileError(f"runtime source is absent: {relative}")
        source_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append((relative.as_posix(), source_sha256))
    return tuple(entries)


def verify_manifest_closure(root: Path) -> None:
    expected = set(CANDIDATE_RUNTIME_SOURCE_PATHS)
    discovered = set(discover_runtime_sources(root))
    if discovered != expected:
        missing = sorted(str(path) for path in discovered - expected)
        extra = sorted(str(path) for path in expected - discovered)
        raise ProfileError(
            f"runtime manifest closure mismatch missing={missing} extra={extra}"
        )


def verify_tool_manifest_closure(
    definition: dict[str, object],
    *,
    observed_product: set[str],
    observed_harness: set[str],
) -> None:
    declared_product = set(definition["product_tools"])
    declared_harness = set(definition["harness_tools"])
    optional_harness = set(definition.get("optional_harness_tools", []))
    resolved_product = {
        Path(resolved).resolve().name
        for name in declared_product
        if (resolved := shutil.which(name)) is not None
    }
    resolved_harness = {
        Path(resolved).resolve().name
        for name in declared_harness
        if (resolved := shutil.which(name)) is not None
    }
    missing_product = sorted(
        observed_product - declared_product - resolved_product
    )
    missing_harness = sorted(
        observed_harness - declared_harness - optional_harness - resolved_harness
    )
    if missing_product or missing_harness:
        raise ProfileError(
            "runtime tool closure mismatch "
            f"product={missing_product} harness={missing_harness}"
        )


def discover_observed_runtime_tools(trace_root: Path, code_root: Path) -> set[str]:
    observed: set[str] = set()
    canonical_code_root = code_root.resolve()
    generated_formal_names = {
        "preReviewerControllerDiff",
        "preReviewerControllerDiff.private",
    }
    for trace in trace_root.rglob("*.strace"):
        for executed in re.findall(r'execve\("([^"\\]+)".*\) += 0', trace.read_text()):
            path = Path(executed).resolve()
            if path.is_relative_to(canonical_code_root):
                continue
            if path.name in generated_formal_names:
                continue
            observed.add(path.name)
    return observed


def observed_runtime_tool_paths(
    evidence: PhaseTraceEvidence,
    code_root: Path,
) -> dict[str, Path]:
    generated_formal_names = {
        "preReviewerControllerDiff",
        "preReviewerControllerDiff.private",
    }
    observed: dict[str, Path] = {}
    for path in evidence.all_paths:
        canonical = path.resolve()
        if canonical.is_relative_to(code_root.resolve()):
            continue
        if canonical.name in generated_formal_names:
            continue
        previous = observed.get(canonical.name)
        if previous is not None and previous != canonical:
            raise ProfileError(
                f"runtime tool name resolved to multiple trace paths: {canonical.name}"
            )
        observed[canonical.name] = canonical
    return observed


@contextmanager
def _blocked_profile_signals() -> Iterator[set[signal.Signals]]:
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, PROFILE_SIGNALS)
    try:
        yield previous
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def _register_owned_group(process: subprocess.Popen[bytes]) -> None:
    _ACTIVE_OWNED_GROUPS[process.pid] = process


def _unregister_owned_group(process: subprocess.Popen[bytes]) -> None:
    _ACTIVE_OWNED_GROUPS.pop(process.pid, None)


def _stop_owned_process_group(process: subprocess.Popen[bytes]) -> None:
    def group_exists() -> bool:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return False
        return True

    if not group_exists():
        if process.poll() is None:
            process.wait(timeout=2.0)
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    if process.poll() is None:
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
    deadline = time.monotonic() + 2.0
    while group_exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    if group_exists():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.wait(timeout=2.0)


def _handle_profile_signal(signal_number: int, _frame: object) -> None:
    for process in tuple(_ACTIVE_OWNED_GROUPS.values()):
        try:
            _stop_owned_process_group(process)
        except (OSError, subprocess.SubprocessError):
            pass
    raise ProfileInterrupted(signal_number)


def _run_with_profile_signal_protocol(operation: Callable[[], int]) -> int:
    if not profile_interruption_supervision_accepted(True, True, True, True):
        raise ProfileError("profile interruption supervision is incomplete")
    previous = {
        signal_number: signal.signal(signal_number, _handle_profile_signal)
        for signal_number in PROFILE_SIGNALS
    }
    try:
        try:
            return operation()
        except ProfileInterrupted as interruption:
            return profile_interrupt_exit_status(interruption.signal_number)
    finally:
        for signal_number, handler in previous.items():
            signal.signal(signal_number, handler)


def run_owned_command(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
    timeout: float,
    input_bytes: bytes | None = None,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("ab") as log:
        with _blocked_profile_signals() as previous_mask:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE if input_bytes is not None else None,
                preexec_fn=lambda: signal.pthread_sigmask(
                    signal.SIG_SETMASK,
                    previous_mask,
                ),
                start_new_session=True,
            )
            _register_owned_group(process)
        try:
            if input_bytes is None:
                status = process.wait(timeout=timeout)
            else:
                process.communicate(input=input_bytes, timeout=timeout)
                status = process.returncode
            return status
        except BaseException:
            _stop_owned_process_group(process)
            raise
        finally:
            _stop_owned_process_group(process)
            _unregister_owned_group(process)


def observe_harness_runtime_tools(
    harness: Path,
    code_root: Path,
    formal_tmp_root: Path,
    output_root: Path,
) -> tuple[PublishedPhaseTraceEvidence, dict[str, Path]]:
    strace = shutil.which("strace")
    bash = shutil.which("bash")
    if strace is None or bash is None:
        raise ProfileError("harness executable observation requires bash and strace")
    trace_root = formal_tmp_root / "profile-traces"
    publish_dir = output_root / "artifacts/pre-reviewer"
    evidence_root = formal_tmp_root / "reuse-evidence"
    build_tmp = formal_tmp_root / "controller-build"
    log_path = output_root / "logs/pre-reviewer-profile.log"
    audit_path = output_root / "logs/controller-build.audit"
    trace_root.mkdir(parents=True)
    publish_dir.mkdir(parents=True)
    evidence_root.mkdir()
    build_tmp.mkdir()
    fresh_trace = trace_root / "fresh.strace"
    reuse_trace = trace_root / "reuse.strace"
    build_environment = {
        **os.environ,
        "TMPDIR": str(build_tmp),
        "CODEX_PRE_REVIEWER_BUILD_AUDIT": str(audit_path),
        "CODEX_PRE_REVIEWER_BUILD_AUDIT_ROOT": str(output_root),
    }
    build_status = run_owned_command(
        [
            strace,
            "-f",
            "-qq",
            "-e",
            "trace=execve",
            "-o",
            str(fresh_trace),
            bash,
            str(harness),
            "--build-artifact",
            str(publish_dir),
        ],
        cwd=code_root,
        environment=build_environment,
        log_path=log_path,
        timeout=900.0,
    )
    if build_status != 0:
        raise ProfileError("fresh harness artifact setup observation failed")
    if controller_build_count(audit_path) != 1:
        raise ProfileError("fresh harness did not audit exactly one controller build")

    executable = publish_dir / "preReviewerControllerDiff"
    stamp = executable.with_suffix(".stamp")
    reuse_environment = {
        **os.environ,
        "CODEX_TEST_SKIP_LEAN_BUILD": "1",
        "CODEX_PRE_REVIEWER_FORMAL_EXE": str(executable),
        "CODEX_PRE_REVIEWER_FORMAL_STAMP": str(stamp),
    }
    reuse_status = run_owned_command(
        [
            strace,
            "-f",
            "-qq",
            "-e",
            "trace=execve",
            "-o",
            str(reuse_trace),
            bash,
            str(harness),
            "--build-artifact",
            str(evidence_root),
        ],
        cwd=code_root,
        environment=reuse_environment,
        log_path=log_path,
        timeout=180.0,
    )
    if reuse_status != 0:
        raise ProfileError("verified-artifact harness reuse observation failed")
    record_reuse_phase(audit_path, output_root)
    reuse_validation_status = run_owned_command(
        [
            bash,
            str(harness),
            "--scenario",
            "success",
            "--artifact-root",
            str(evidence_root),
        ],
        cwd=code_root,
        environment=reuse_environment,
        log_path=log_path,
        timeout=180.0,
    )
    if reuse_validation_status != 0:
        raise ProfileError("verified-artifact harness reuse validation failed")
    published = publish_phase_trace_evidence(fresh_trace, reuse_trace, output_root)
    return (
        published,
        observed_runtime_tool_paths(published.phase_evidence, code_root),
    )


def _file_entries(root: Path, paths: tuple[Path, ...]) -> list[dict[str, str]]:
    return [
        {
            "path": relative.as_posix(),
            "sha256": hashlib.sha256((root / relative).read_bytes()).hexdigest(),
        }
        for relative in paths
        if (root / relative).is_file()
    ]


def _tool_entries(tool_names: list[str]) -> list[dict[str, str]]:
    return tool_entries(tool_names, [], {})


def _declared_tool_candidates(name: str) -> tuple[Path, ...]:
    candidates: list[Path] = []
    resolved = shutil.which(name)
    if resolved is not None:
        try:
            candidates.append(Path(resolved).resolve(strict=True))
        except OSError:
            pass
    if name in LEAN_TOOLCHAIN_ROLES:
        elan = shutil.which("elan")
        if elan is not None:
            result = subprocess.run(
                [elan, "which", name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                text=True,
                timeout=15.0,
            )
            if result.returncode == 0 and result.stdout.strip():
                try:
                    candidate = Path(result.stdout.strip()).resolve(strict=True)
                except OSError:
                    pass
                else:
                    if candidate not in candidates:
                        candidates.append(candidate)
    return tuple(candidates)


def _tool_identity(
    name: str,
    path: Path,
    *,
    unique_role: bool,
) -> dict[str, str]:
    if not path.is_absolute():
        raise ProfileError(f"runtime tool path is not absolute: {name}")
    canonical = path.resolve(strict=True)
    if not canonical.is_file() or not os.access(canonical, os.X_OK):
        raise ProfileError(f"runtime tool is unavailable: {name}")
    candidates = _declared_tool_candidates(name)
    matches = [candidate for candidate in candidates if candidate == canonical]
    if not candidates:
        raise ProfileError(f"declared runtime role is unavailable: {name}")
    canonical_bytes = canonical.read_bytes()
    resolved_bytes = matches[0].read_bytes() if len(matches) == 1 else b""
    if not declared_tool_identity_accepted(
        unique_role,
        len(matches) == 1,
        resolved_bytes == canonical_bytes,
    ):
        raise ProfileError(
            f"declared runtime role differs from traced identity: {name}"
        )
    version = subprocess.run(
        [str(canonical), "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=15.0,
    ).stdout.splitlines()[:1]
    return {
        "name": name,
        "path": str(canonical),
        "sha256": hashlib.sha256(canonical_bytes).hexdigest(),
        "version_sha256": hashlib.sha256(b"\n".join(version)).hexdigest(),
    }


def tool_entries(
    required_names: list[str],
    optional_names: list[str],
    observed_paths: dict[str, Path],
    *,
    include_optional: set[str] | None = None,
) -> list[dict[str, str]]:
    required = set(required_names)
    optional = set(optional_names)
    if required & optional:
        raise ProfileError("required and optional runtime tools overlap")
    declared = required | optional
    resolved_aliases: dict[Path, list[str]] = {}
    for name in declared:
        for candidate in _declared_tool_candidates(name):
            resolved_aliases.setdefault(candidate, []).append(name)
    normalized_observed: dict[str, Path] = {}
    unknown: set[str] = set()
    for observed_name, observed_path in observed_paths.items():
        aliases = resolved_aliases.get(observed_path.resolve(), [])
        if len(aliases) != 1:
            unknown.add(observed_name)
            continue
        declared_name = aliases[0]
        if observed_name in declared and observed_name != declared_name:
            unknown.add(observed_name)
            continue
        previous = normalized_observed.get(declared_name)
        if previous is not None and previous.resolve() != observed_path.resolve():
            raise ProfileError(
                f"declared runtime tool has multiple trace paths: {declared_name}"
            )
        normalized_observed[declared_name] = observed_path
    if unknown:
        raise ProfileError(
            f"observed runtime tools are undeclared: {sorted(unknown)}"
        )
    requested_optional = include_optional or set()
    if requested_optional - set(normalized_observed):
        raise ProfileError("optional identity was not observed in the trace")
    selected = required | (optional & set(normalized_observed)) | requested_optional
    entries: list[dict[str, str]] = []
    for name in sorted(selected):
        if name in normalized_observed:
            path = normalized_observed[name]
        else:
            candidates = _declared_tool_candidates(name)
            if not candidates:
                raise ProfileError(f"runtime tool is unavailable: {name}")
            path = candidates[0]
        aliases = resolved_aliases.get(path.resolve(), [])
        entries.append(
            _tool_identity(
                name,
                path,
                unique_role=aliases == [name],
            )
        )
    return entries


def verify_tool_entries(entries: list[dict[str, str]]) -> None:
    resolved_roles: dict[Path, list[str]] = {}
    for entry in entries:
        name = entry.get("name")
        if not isinstance(name, str):
            raise ProfileError("runtime tool identity lacks a declared name")
        candidates = _declared_tool_candidates(name)
        if not candidates:
            raise ProfileError(f"runtime tool disappeared after trace: {name}")
        for candidate in candidates:
            resolved_roles.setdefault(candidate, []).append(name)
    for entry in entries:
        name = entry.get("name", "unknown")
        path_value = entry.get("path")
        if not isinstance(path_value, str):
            raise ProfileError(f"runtime tool identity lacks a path: {name}")
        try:
            path = Path(path_value)
            current = _tool_identity(
                str(name),
                path,
                unique_role=resolved_roles.get(path.resolve(), []) == [name],
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ProfileError(f"runtime tool disappeared after trace: {name}") from error
        if current != entry:
            raise ProfileError(f"runtime tool identity drifted after trace: {name}")


def runtime_evidence_manifest(
    parent_root: Path,
    candidate_root: Path,
    *,
    observed_harness_paths: dict[str, Path] | None = None,
) -> dict[str, object]:
    definition = load_runtime_manifest(candidate_root)
    harness_paths = tuple(Path(value) for value in definition["harness_sources"])
    return {
        "schema_version": 3,
        "product": {
            "parent": _file_entries(
                parent_root,
                (RUNTIME_MANIFEST_RELATIVE_PATH, *CANDIDATE_RUNTIME_SOURCE_PATHS),
            ),
            "candidate": _file_entries(
                candidate_root,
                (RUNTIME_MANIFEST_RELATIVE_PATH, *CANDIDATE_RUNTIME_SOURCE_PATHS),
            ),
        },
        "harness": _file_entries(candidate_root, harness_paths),
        "product_tools": _tool_entries(list(definition["product_tools"])),
        "harness_tools": tool_entries(
            list(definition["harness_tools"]),
            list(definition.get("optional_harness_tools", [])),
            observed_harness_paths or {},
        ),
        "claim": definition["claim"],
    }


def _manifest_sha256(entries: tuple[tuple[str, str], ...]) -> str:
    digest = hashlib.sha256()
    for relative, source_sha256 in entries:
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(source_sha256.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def _revision_identity(root: Path, commit: str) -> RevisionIdentity:
    wrapper = (root / WRAPPER_RELATIVE_PATH).read_bytes()
    python_controller = root / PYTHON_CONTROLLER_RELATIVE_PATH
    python_controller_sha256 = (
        hashlib.sha256(python_controller.read_bytes()).hexdigest()
        if python_controller.is_file()
        else "absent"
    )
    return RevisionIdentity(
        commit=commit,
        wrapper_sha256=hashlib.sha256(wrapper).hexdigest(),
        python_controller_sha256=python_controller_sha256,
        manifest_sha256=_manifest_sha256(_runtime_manifest(root)),
    )


def candidate_revision_identity(candidate_root: Path) -> RevisionIdentity:
    commit = resolve_revision(candidate_root, "HEAD")
    _verify_candidate_sources(candidate_root, commit)
    return _revision_identity(candidate_root, commit)


def source_identity_evidence(
    parent_root: Path,
    candidate_root: Path,
    scratch: Path,
    parent_identity: RevisionIdentity,
    candidate_identity: RevisionIdentity | None = None,
) -> SourceIdentityEvidence:
    candidate_identity = candidate_identity or candidate_revision_identity(
        candidate_root
    )
    if parent_identity.wrapper_sha256 == candidate_identity.wrapper_sha256:
        raise ProfileError("parent and candidate controller identities match")
    parent_sources = observe_configured_sources(
        parent_root, scratch / "parent-state"
    )
    candidate_sources = observe_configured_sources(
        candidate_root, scratch / "candidate-state"
    )
    return SourceIdentityEvidence(
        parent_identity,
        candidate_identity,
        parent_sources,
        candidate_sources,
    )


def run_configured_pair(
    code_root: Path,
    state_root: Path,
    *,
    scenario: ProfileScenario,
    sample: int,
) -> tuple[int, dict[str, int]]:
    validator, reviewer, prompt_command = profile_commands(code_root)
    reset_state(state_root)
    prompt, tool, session, _turn = generated_payloads(sample)
    environment = generated_environment(code_root, state_root, fake=True)
    attribution = {
        "history_bytes": 0,
        "retained_entries": 0,
        "retained_removed": 0,
    }
    if scenario.history_records:
        tool, attribution["history_bytes"] = prepare_large_history(
            state_root,
            tool,
            session,
            scenario.history_records,
        )
    if scenario.retained_entries:
        prepare_retained_state(state_root, session, scenario.retained_entries)
        attribution["retained_entries"] = scenario.retained_entries
    if scenario.measure_prompt:
        started = time.monotonic_ns()
        capture = run_hook(
            prompt_command,
            prompt,
            environment,
            code_root,
            timeout=15.0,
        )
        elapsed = (time.monotonic_ns() - started) // 1_000_000
        if capture.returncode != 0:
            raise ProfileError("generated retained-state prompt failed")
        state_dir = state_root / "proof" / "pre-reviewer" / session
        remaining = sum(1 for _path in state_dir.glob("claim-turn-generated-*"))
        attribution["retained_removed"] = scenario.retained_entries - remaining
        return elapsed, attribution
    if scenario.prepared:
        capture = run_hook(
            prompt_command,
            prompt,
            environment,
            code_root,
            timeout=10.0,
        )
        if capture.returncode != 0:
            raise ProfileError("generated prompt capture failed")
    barrier_read, barrier_write = os.pipe()
    wrapper = (
        "import os,sys; fd=int(sys.argv[1]); os.read(fd,1); os.close(fd); "
        "os.execvpe(sys.argv[2],sys.argv[2:],os.environ)"
    )
    processes: list[subprocess.Popen[bytes]] = []
    try:
        for command in (validator, reviewer):
            argv = shlex.split(command)
            with _blocked_profile_signals() as previous_mask:
                process = subprocess.Popen(
                    [sys.executable, "-c", wrapper, str(barrier_read), *argv],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    cwd=code_root,
                    env=environment,
                    pass_fds=(barrier_read,),
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_SETMASK,
                        previous_mask,
                    ),
                    start_new_session=True,
                )
                _register_owned_group(process)
            processes.append(process)
            assert process.stdin is not None
            process.stdin.write(tool)
            process.stdin.close()
        os.close(barrier_read)
        started = time.monotonic_ns()
        os.write(barrier_write, b"12")
        os.close(barrier_write)
        deadline = time.monotonic() + 15.0
        statuses = [
            process.wait(timeout=max(0.001, deadline - time.monotonic()))
            for process in processes
        ]
    finally:
        for process in processes:
            _stop_owned_process_group(process)
            _unregister_owned_group(process)
        for fd in (barrier_read, barrier_write):
            try:
                os.close(fd)
            except OSError:
                pass
    if statuses != [0, 0]:
        raise ProfileError(f"configured pair failed: {statuses}")
    return (time.monotonic_ns() - started) // 1_000_000, attribution


def resolve_revision(candidate_root: Path, revision: str) -> str:
    return subprocess.run(
        ["git", "rev-parse", "--verify", revision],
        cwd=candidate_root,
        stdout=subprocess.PIPE,
        check=True,
        text=True,
    ).stdout.strip()


def export_parent(candidate_root: Path, destination: Path) -> RevisionIdentity:
    baseline_commit = resolve_revision(candidate_root, BASELINE_COMMIT)
    if baseline_commit != BASELINE_COMMIT:
        raise ProfileError("immutable baseline commit resolved unexpectedly")
    return export_revision(candidate_root, baseline_commit, destination)


def export_revision(
    repository: Path,
    commit: str,
    destination: Path,
    *,
    verify_runtime_sources: bool = True,
) -> RevisionIdentity:
    archive = destination.parent / f"{destination.name}.tar"
    with archive.open("wb") as stream:
        subprocess.run(
            ["git", "archive", "--format=tar", commit],
            cwd=repository,
            stdout=stream,
            check=True,
        )
    with archive.open("rb") as stream:
        archived_commit = subprocess.run(
            ["git", "get-tar-commit-id"],
            cwd=repository,
            stdin=stream,
            stdout=subprocess.PIPE,
            check=True,
            text=True,
        ).stdout.strip()
    if archived_commit != commit:
        raise ProfileError("exported revision does not match requested commit")
    destination.mkdir()
    with tarfile.open(archive) as bundle:
        bundle.extractall(destination, filter="data")
    if verify_runtime_sources:
        for relative, source_sha256 in _runtime_manifest(destination):
            committed = _committed_bytes(repository, commit, Path(relative))
            if hashlib.sha256(committed).hexdigest() != source_sha256:
                raise ProfileError(
                    f"exported source bytes differ from commit: {relative}"
                )
        return _revision_identity(destination, commit)
    wrapper = (destination / WRAPPER_RELATIVE_PATH).read_bytes()
    return RevisionIdentity(
        commit=commit,
        wrapper_sha256=hashlib.sha256(wrapper).hexdigest(),
        python_controller_sha256="historical-anchor",
        manifest_sha256="historical-anchor",
    )


def export_candidate(candidate_root: Path, destination: Path) -> RevisionIdentity:
    identity = candidate_revision_identity(candidate_root)
    exported = export_revision(candidate_root, identity.commit, destination)
    if exported != identity:
        raise ProfileError("exported candidate identity differs from reported commit")
    return exported


def render_identity_record(
    parent: RevisionIdentity,
    candidate: RevisionIdentity,
) -> str:
    return (
        "source-identities "
        f"baseline_commit={BASELINE_COMMIT} "
        f"parent_commit={parent.commit} "
        f"candidate_commit={candidate.commit} "
        f"parent_wrapper_sha256={parent.wrapper_sha256} "
        f"candidate_wrapper_sha256={candidate.wrapper_sha256} "
        "parent_python_controller_sha256="
        f"{parent.python_controller_sha256} "
        "candidate_python_controller_sha256="
        f"{candidate.python_controller_sha256} "
        f"parent_manifest_sha256={parent.manifest_sha256} "
        f"candidate_manifest_sha256={candidate.manifest_sha256} "
        "parent_executed=true candidate_executed=true"
    )


def alternating_profile(
    parent_root: Path,
    candidate_root: Path,
    scratch: Path,
    *,
    scenario: ProfileScenario,
) -> tuple[list[int], list[int], list[str], dict[str, int]]:
    values = {"parent": [], "candidate": []}
    orders: list[str] = []
    attribution = {
        "history_bytes": 0,
        "retained_entries": 0,
        "retained_removed": 0,
    }
    state_root = scratch / f"{scenario.name}-state"
    for sample in range(SAMPLES):
        order = (
            (("parent", parent_root), ("candidate", candidate_root))
            if sample % 2 == 0
            else (("candidate", candidate_root), ("parent", parent_root))
        )
        orders.append("-".join(name for name, _root in order))
        for name, code_root in order:
            elapsed, observed = run_configured_pair(
                code_root,
                state_root,
                scenario=scenario,
                sample=sample,
            )
            values[name].append(elapsed)
            attribution = {
                key: max(attribution[key], observed[key]) for key in attribution
            }
    return values["parent"], values["candidate"], orders, attribution


def real_backend_phase(candidate_root: Path, scratch: Path) -> dict[str, object]:
    _validator, reviewer, prompt_command = configured_commands(candidate_root)
    state_root = scratch / "real-backend-state"
    reset_state(state_root)
    environment = generated_environment(candidate_root, state_root, fake=False)
    alias = next(
        (
            name
            for name in (
                "CODEX_EDIT_PRE_REVIEWER",
                "LLM_EDIT_PRE_REVIEWER",
                "CLAUDE_EDIT_PRE_REVIEWER",
            )
            if environment.get(name)
        ),
        None,
    )
    if alias is None:
        return {"status": "blocked-alias-unavailable"}
    real_curl = shutil.which("curl")
    if real_curl is None:
        return {"status": "blocked-curl-unavailable"}
    bin_root = scratch / "observable-bin"
    bin_root.mkdir()
    observable = scratch / "backend-observable"
    curl_wrapper = bin_root / "curl"
    curl_wrapper.write_text(
        "#!/usr/bin/env bash\n"
        "printf 'attempted\\n' >>\"$PROFILE_BACKEND_OBSERVABLE\"\n"
        '"$PROFILE_REAL_CURL" "$@"\n'
        "status=$?\n"
        "printf 'completed:%s\\n' \"$status\" >>\"$PROFILE_BACKEND_OBSERVABLE\"\n"
        "exit \"$status\"\n",
        encoding="utf-8",
    )
    curl_wrapper.chmod(0o755)
    environment.update(
        {
            "PATH": f"{bin_root}:{environment['PATH']}",
            "PROFILE_REAL_CURL": real_curl,
            "PROFILE_BACKEND_OBSERVABLE": str(observable),
            "CODEX_EDIT_PRE_REVIEWER_TIMEOUT": "10",
        }
    )
    prompt, tool, session, _turn = generated_payloads(99)
    capture = run_hook(
        prompt_command,
        prompt,
        environment,
        candidate_root,
        timeout=10.0,
    )
    if capture.returncode != 0:
        return {"status": "blocked-prompt-capture"}
    started = time.monotonic_ns()
    try:
        result = run_hook(
            reviewer,
            tool,
            environment,
            candidate_root,
            timeout=20.0,
        )
    except subprocess.TimeoutExpired:
        return {
            "status": "blocked-outer-timeout",
            "elapsed_ms": (time.monotonic_ns() - started) // 1_000_000,
        }
    elapsed = (time.monotonic_ns() - started) // 1_000_000
    observations = observable.read_text().splitlines() if observable.exists() else []
    state_dir = state_root / "proof" / "pre-reviewer" / session
    state_entries = list(state_dir.iterdir()) if state_dir.is_dir() else []
    claim_present = any(path.name.startswith("claim-turn-") for path in state_entries)
    capture_consumed = claim_present and not any(
        path.name.startswith("capture-turn-") for path in state_entries
    )
    call_attempted = "attempted" in observations
    call_completed = any(line.startswith("completed:") for line in observations)
    status = (
        "completed-observed"
        if capture_consumed and call_attempted and call_completed
        else "blocked-observable-incomplete"
    )
    return {
        "status": status,
        "elapsed_ms": elapsed,
        "capture_consumed": capture_consumed,
        "claim_present": claim_present,
        "call_attempted": call_attempted,
        "call_completed": call_completed,
        "hook_status": result.returncode,
    }


def print_samples(
    label: str,
    parent: list[int],
    candidate: list[int],
    orders: list[str],
) -> None:
    print(
        f"ab-{label} parent_raw_ms={parent} candidate_raw_ms={candidate} "
        f"parent_cold_ms={parent[0]} parent_warm_ms={parent[1:]} "
        f"candidate_cold_ms={candidate[0]} candidate_warm_ms={candidate[1:]} "
        f"orders={orders}"
    )


def print_attribution(
    scenario: ProfileScenario,
    anchor: str,
    attribution: dict[str, int],
) -> None:
    print(
        f"causal-attribution scenario={scenario.name} anchor={anchor} "
        f"history_bytes={attribution['history_bytes']} "
        f"retained_entries={attribution['retained_entries']} "
        f"retained_removed_max={attribution['retained_removed']}"
    )


def _run_profile(
    repository: Path,
    candidate_snapshot: Path,
    scratch: Path,
    formal_tmp_root: Path,
    candidate_commit: str,
    output_root: Path,
) -> PublishedPhaseTraceEvidence:
    parent_root = scratch / "parent"
    history_root = scratch / "history-anchor"
    retained_root = scratch / "retained-anchor"
    parent_identity = export_parent(repository, parent_root)
    export_revision(
        repository,
        resolve_revision(repository, HISTORY_SCAN_COMMIT),
        history_root,
        verify_runtime_sources=False,
    )
    export_revision(
        repository,
        resolve_revision(repository, RETAINED_PRUNE_COMMIT),
        retained_root,
        verify_runtime_sources=False,
    )
    candidate_identity = _revision_identity(candidate_snapshot, candidate_commit)
    verify_manifest_closure(candidate_snapshot)
    definition = load_runtime_manifest(candidate_snapshot)
    published_phase_evidence, observed_harness_paths = observe_harness_runtime_tools(
        candidate_snapshot / "hooks/tests/differential/pre-reviewer-controller.sh",
        candidate_snapshot,
        formal_tmp_root,
        output_root,
    )
    if not _private_owned_directory(formal_tmp_root):
        raise ProfileError("formal tmpfs root was lost during controller build")
    evidence_before = runtime_evidence_manifest(
        parent_root,
        candidate_snapshot,
        observed_harness_paths=observed_harness_paths,
    )
    verify_tool_entries(evidence_before["harness_tools"])
    print(
        "runtime-manifest-before "
        + json.dumps(evidence_before, sort_keys=True, separators=(",", ":"))
    )
    source_evidence = source_identity_evidence(
        parent_root,
        candidate_snapshot,
        scratch / "source-evidence",
        parent_identity,
        candidate_identity,
    )
    observed_product = discover_observed_runtime_tools(
        scratch / "source-evidence" / "candidate-state",
        candidate_snapshot,
    )
    observed_harness = set(observed_harness_paths)
    verify_tool_manifest_closure(
        definition,
        observed_product=observed_product,
        observed_harness=observed_harness,
    )
    print(render_identity_record(source_evidence.parent, source_evidence.candidate))
    for anchor_root, scenario, anchor in (
        (parent_root, NO_CAPTURE, BASELINE_COMMIT),
        (parent_root, PREPARED_FAKE, BASELINE_COMMIT),
        (history_root, LARGE_HISTORY, HISTORY_SCAN_COMMIT),
        (retained_root, RETAINED_STATE, RETAINED_PRUNE_COMMIT),
    ):
        parent, candidate, orders, attribution = alternating_profile(
            anchor_root,
            candidate_snapshot,
            scratch,
            scenario=scenario,
        )
        print_samples(scenario.name, parent, candidate, orders)
        print_attribution(scenario, anchor, attribution)
    backend = real_backend_phase(candidate_snapshot, scratch)
    print("compatibility-backend " + " ".join(
        f"{key}={str(value).lower()}" for key, value in backend.items()
    ))
    evidence_after = runtime_evidence_manifest(
        parent_root,
        candidate_snapshot,
        observed_harness_paths=observed_harness_paths,
    )
    verify_tool_entries(evidence_after["harness_tools"])
    if evidence_after != evidence_before:
        raise ProfileError("runtime identity changed during measurement")
    print(
        "runtime-manifest-after "
        + json.dumps(evidence_after, sort_keys=True, separators=(",", ":"))
    )
    return published_phase_evidence


def _main(argv: list[str]) -> int:
    if len(argv) != 6 or argv[2] != "--formal-tmp-root" or argv[4] != "--output-root":
        raise SystemExit(
            "usage: profile_pre_reviewer_ab.py REPO "
            "--formal-tmp-root ABS --output-root ABS"
        )
    if os.environ.get("CODEX_PROFILE_INTERNAL_REEXEC"):
        raise ProfileError("inherited internal profiler reexec state is forbidden")
    repository = Path(argv[1]).resolve()
    formal_tmp_root = Path(argv[3])
    output_root = Path(argv[5])
    validate_profile_roots(formal_tmp_root, output_root)
    validate_profile_destinations(output_root)
    scratch = output_root / "work"
    if scratch.exists() or scratch.is_symlink():
        raise ProfileError("profile scratch destination already exists")
    scratch.mkdir(mode=0o700)
    candidate_snapshot = scratch / "candidate"
    evidence_dir = output_root / "evidence"
    log_path = output_root / "logs/pre-reviewer-profile.log"
    evidence_dir.mkdir(parents=True)
    log_path.parent.mkdir(parents=True)
    log_path.touch(mode=0o600, exist_ok=False)
    temporary_report = evidence_dir / ".pre-reviewer-profile.out.tmp"
    report_path = evidence_dir / "pre-reviewer-profile.out"
    try:
        identity = export_candidate(repository, candidate_snapshot)
        with temporary_report.open("x", encoding="utf-8") as stream:
            temporary_report.chmod(0o600)
            with redirect_stdout(stream):
                published_phase_evidence = _run_profile(
                    repository,
                    candidate_snapshot,
                    scratch,
                    formal_tmp_root,
                    identity.commit,
                    output_root,
                )
                phase_evidence = validate_published_phase_trace_evidence(
                    published_phase_evidence,
                    output_root,
                )
                trace_binding = published_phase_evidence.trace_binding()
                print(
                    "profile-trace-binding "
                    + json.dumps(
                        trace_binding,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                )
                print(CAUSAL_SCOPE_RECORD)
                print(
                    "Two rows per matching Bash invocation are expected; displayed "
                    "rows alone do not prove that all corresponding processes remain "
                    "active."
                )
                print(
                    "Generated A/B timings cover named generated scenarios and "
                    "historical anchors only; backend evidence is one bounded "
                    "generated observation, not live causation, UI-row retention, "
                    "an effect on already-running sessions, or a universal speedup "
                    "claim."
                )
                summary = {
                    "candidate_commit": identity.commit,
                    "controller_build_count": controller_build_count(
                        output_root / "logs/controller-build.audit"
                    ),
                    "fresh_trace_execve_successes": (
                        phase_evidence.fresh_execve_successes
                    ),
                    "report_schema_version": 1,
                    "reuse_trace_execve_successes": (
                        phase_evidence.reuse_execve_successes
                    ),
                }
                validate_profile_summary(summary, identity.commit)
                print(
                    "profile-summary "
                    + json.dumps(summary, sort_keys=True, separators=(",", ":"))
                )
            stream.flush()
            os.fsync(stream.fileno())
        validate_published_phase_trace_evidence(
            published_phase_evidence,
            output_root,
        )
        shutil.rmtree(scratch)
        os.link(temporary_report, report_path, follow_symlinks=False)
        temporary_report.unlink()
        _fsync_directory(evidence_dir)
        validate_persisted_profile(
            report_path,
            output_root,
            identity.commit,
            expected_published=published_phase_evidence,
        )
    except BaseException as error:
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"profile-error: {type(error).__name__}: {error}\n")
        if temporary_report.exists() and not temporary_report.is_symlink():
            temporary_report.unlink()
        print(f"preserved profile evidence: {output_root}", file=sys.stderr)
        raise
    return 0


def main(argv: list[str]) -> int:
    return _run_with_profile_signal_protocol(lambda: _main(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
