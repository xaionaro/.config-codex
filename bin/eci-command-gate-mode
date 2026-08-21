#!/usr/bin/env python3
"""Configure and apply the ECI command-gate enforcement floor."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
from typing import Final


MAX_CONFIG_BYTES: Final = 32
MAX_DENIAL_BYTES: Final = 65_536
MAX_EVENT_BYTES: Final = 4_096
MAX_LOG_BYTES: Final = 1_048_576
MAX_LOG_FILES: Final = 4
SCHEMA: Final = "eci-command-gate-event/v1"
CONFIG_RELATIVE: Final = ("eci", "command-gate-mode")
LOG_RELATIVE: Final = ("eci", "command-gate", "would-deny.jsonl")
CODE_PATTERN: Final = re.compile(r"^\[([A-Z0-9_]+)\]")
OPERATION_PATTERN: Final = re.compile(r"(?:^|,|\()\s*operation=([^,)]+)")
DIRECTORY_OPEN_FLAGS: Final = (
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
)
REGULAR_OPEN_BASE_FLAGS: Final = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
ROTATION_LOCK_NAME: Final = ".rotation.lock"
LOG_NAME: Final = LOG_RELATIVE[-1]
ROTATED_LOG_NAMES: Final = tuple(
    f"{LOG_NAME}.{generation}" for generation in range(1, MAX_LOG_FILES + 1)
)


class Mode(str, Enum):
    PERMISSIVE = "permissive"
    ENFORCING = "enforcing"


class Provider(str, Enum):
    CODEX = "codex"
    KIMI = "kimi"


class Role(str, Enum):
    COORDINATOR = "coordinator"
    WORKER = "worker"


class Marker(str, Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"


class Source(str, Enum):
    PARSER = "parser"
    LEGACY = "legacy"


class ConfigState(str, Enum):
    MISSING = "missing"
    CONFIGURED_PERMISSIVE = "configured-permissive"
    CONFIGURED_ENFORCING = "configured-enforcing"
    INVALID_PATH = "invalid-path"
    INVALID_METADATA = "invalid-metadata"
    READ_ERROR = "read-error"
    OVERSIZE = "oversize"
    INVALID_BYTES = "invalid-bytes"


class TelemetryCode(str, Enum):
    BROAD_DESTRUCTIVE_DENIED = "ECI_BROAD_DESTRUCTIVE_DENIED"
    COMMAND_DYNAMIC_INDIRECTION_DENIED = "ECI_COMMAND_DYNAMIC_INDIRECTION_DENIED"
    COMMAND_NONLITERAL_DENIED = "ECI_COMMAND_NONLITERAL_DENIED"
    COMMAND_NOT_ALLOWLISTED = "ECI_COMMAND_NOT_ALLOWLISTED"
    COMMAND_SYNTAX_DENIED = "ECI_COMMAND_SYNTAX_DENIED"
    COMMAND_WRAPPER_UNSUPPORTED = "ECI_COMMAND_WRAPPER_UNSUPPORTED"
    COMMIT_ADMISSION_REQUIRED = "ECI_COMMIT_ADMISSION_REQUIRED"
    CONTROL_IDENTITY_DENIED = "ECI_CONTROL_IDENTITY_DENIED"
    CONTROL_OWNER_REQUIRED = "ECI_CONTROL_OWNER_REQUIRED"
    COORDINATOR_CLEANUP_PIPELINE_DENIED = "ECI_COORDINATOR_CLEANUP_PIPELINE_DENIED"
    COORDINATOR_CONTROL_PIPELINE_DENIED = "ECI_COORDINATOR_CONTROL_PIPELINE_DENIED"
    COORDINATOR_ROUTE_ARGUMENTS_DENIED = "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED"
    COORDINATOR_SOURCE_WRITE_DENIED = "ECI_COORDINATOR_SOURCE_WRITE_DENIED"
    ENVIRONMENT_CONTEXT_DENIED = "ECI_ENVIRONMENT_CONTEXT_DENIED"
    ENVIRONMENT_ENUMERATION_DENIED = "ECI_ENVIRONMENT_ENUMERATION_DENIED"
    ENVIRONMENT_NAME_DENIED = "ECI_ENVIRONMENT_NAME_DENIED"
    ENVIRONMENT_OPTION_DENIED = "ECI_ENVIRONMENT_OPTION_DENIED"
    GIT_BRANCH_REMOTE_DENIED = "ECI_GIT_BRANCH_REMOTE_DENIED"
    GIT_DYNAMIC_EXECUTION_DENIED = "ECI_GIT_DYNAMIC_EXECUTION_DENIED"
    GIT_EXECUTION_CONTEXT_DENIED = "ECI_GIT_EXECUTION_CONTEXT_DENIED"
    GIT_MUTATION_DENIED = "ECI_GIT_MUTATION_DENIED"
    HOOK_IDENTITY_MALFORMED = "ECI_HOOK_IDENTITY_MALFORMED"
    LIFECYCLE_ARGUMENTS_DENIED = "ECI_LIFECYCLE_ARGUMENTS_DENIED"
    LIFECYCLE_IDENTITY_DENIED = "ECI_LIFECYCLE_IDENTITY_DENIED"
    LIFECYCLE_OWNER_REQUIRED = "ECI_LIFECYCLE_OWNER_REQUIRED"
    MARKER_MALFORMED = "ECI_MARKER_MALFORMED"
    MARKER_MISSING_CURRENT = "ECI_MARKER_MISSING_CURRENT"
    MARKER_OWNERSHIP_AMBIGUOUS = "ECI_MARKER_OWNERSHIP_AMBIGUOUS"
    MARKER_OWNERSHIP_INVALID = "ECI_MARKER_OWNERSHIP_INVALID"
    MARKER_SCOPE_MISMATCH = "ECI_MARKER_SCOPE_MISMATCH"
    MARKER_UNSAFE_PATH = "ECI_MARKER_UNSAFE_PATH"
    PLAN_DYNAMIC_LAUNCH_DENIED = "ECI_PLAN_DYNAMIC_LAUNCH_DENIED"
    PLAN_INTERNAL_DENIED = "ECI_PLAN_INTERNAL_DENIED"
    PLAN_LIFECYCLE_IDENTITY_DENIED = "ECI_PLAN_LIFECYCLE_IDENTITY_DENIED"
    PLAN_LIMIT_DENIED = "ECI_PLAN_LIMIT_DENIED"
    PLAN_LIVE_CONTROL_DENIED = "ECI_PLAN_LIVE_CONTROL_DENIED"
    PLAN_SYNTAX_DENIED = "ECI_PLAN_SYNTAX_DENIED"
    PLAN_WRAPPER_DENIED = "ECI_PLAN_WRAPPER_DENIED"
    PLAN_WRAPPER_DEPTH_DENIED = "ECI_PLAN_WRAPPER_DEPTH_DENIED"
    PROOF_PATH_ESCAPE_DENIED = "ECI_PROOF_PATH_ESCAPE_DENIED"
    REVIEW_GATE_ARGUMENTS_DENIED = "ECI_REVIEW_GATE_ARGUMENTS_DENIED"
    WORKER_ACCEPTANCE_DENIED = "ECI_WORKER_ACCEPTANCE_DENIED"
    WORKER_COMMAND_NOT_ALLOWLISTED = "ECI_WORKER_COMMAND_NOT_ALLOWLISTED"
    WORKER_CONTROL_READ_DENIED = "ECI_WORKER_CONTROL_READ_DENIED"
    WORKER_CONTROL_SCRIPT_DENIED = "ECI_WORKER_CONTROL_SCRIPT_DENIED"
    WORKER_COORDINATOR_ROUTE_DENIED = "ECI_WORKER_COORDINATOR_ROUTE_DENIED"
    WORKER_GIT_OWNERSHIP_DENIED = "ECI_WORKER_GIT_OWNERSHIP_DENIED"
    WORKER_INSTRUCTION_READ_DENIED = "ECI_WORKER_INSTRUCTION_READ_DENIED"
    WORKER_LAUNCHER_DENIED = "ECI_WORKER_LAUNCHER_DENIED"
    WORKER_REVIEW_GATE_DENIED = "ECI_WORKER_REVIEW_GATE_DENIED"
    OTHER = "ECI_OTHER_DENIAL"


class TelemetryOperation(str, Enum):
    ACCEPTANCE_BOUNDARY = "acceptance-boundary"
    BROAD_DESTRUCTIVE = "broad-destructive"
    COMMIT_BOUNDARY = "commit-boundary"
    COORDINATOR_CLEANUP_ROUTE = "coordinator-cleanup-route"
    COORDINATOR_MKTEMP = "coordinator-mktemp"
    COORDINATOR_ROUTE = "coordinator-route"
    COORDINATOR_SOURCE_WRITE = "coordinator-source-write"
    COORDINATOR_STATIC_PIPELINE = "coordinator-static-pipeline"
    DIRECT_ARGV = "direct-argv"
    ECI_CONTROL = "eci-control"
    ECI_LIFECYCLE = "eci-lifecycle"
    ECI_OFF = "eci-off"
    ENVIRONMENT_BOUNDARY = "environment-boundary"
    GIT_BRANCH_REMOTE = "git-branch-remote"
    GIT_EXECUTION_CONTEXT = "git-execution-context"
    HOOK_IDENTITY = "hook-identity"
    PLAN_SEGMENT = "plan-segment"
    PROOF_PATH_OWNERSHIP = "proof-path-ownership"
    REVIEW_GATE = "review-gate"
    WORKER_ACCEPTANCE = "worker-acceptance"
    WORKER_COMMAND = "worker-command"
    WORKER_CONTROL = "worker-control"
    WORKER_CONTROL_READ = "worker-control-read"
    WORKER_CONTROL_SCRIPT = "worker-control-script"
    WORKER_GIT_OWNERSHIP = "worker-git-ownership"
    WORKER_INSTRUCTION_READ = "worker-instruction-read"
    WORKER_LAUNCHER = "worker-launcher"
    WORKER_REVIEW_GATE = "worker-review-gate"
    OTHER = "other"


class FilePurpose(str, Enum):
    CONFIG = "config"
    CONFIG_TEMP = "config-temp"
    ROTATION_LOCK = "rotation-lock"
    LOG_APPEND = "log-append"
    LOG_GENERATION = "log-generation"


class RotationOutcome(str, Enum):
    APPENDED = "appended"
    ROTATED = "rotated"
    LOCK_CONTENDED = "lock-contended"


@dataclass(frozen=True)
class ModeState:
    mode: Mode
    config_state: ConfigState


@dataclass(frozen=True)
class Denial:
    raw: bytes
    code: TelemetryCode
    operation: TelemetryOperation


@dataclass(frozen=True)
class DescriptorIdentity:
    device: int
    inode: int


@dataclass(frozen=True)
class DirectoryHandle:
    descriptor: int
    identity: DescriptorIdentity
    path: Path | None
    parent_descriptor: int | None
    name: str | None


@dataclass(frozen=True)
class RegularFileHandle:
    descriptor: int
    identity: DescriptorIdentity
    parent_descriptor: int
    name: str
    purpose: FilePurpose


@dataclass(frozen=True)
class OpenedStateRoot:
    directory: DirectoryHandle
    logical_path: Path
    canonical_path: Path
    allows_logical_alias: bool


@dataclass(frozen=True)
class OpenedLogDirectory:
    root: OpenedStateRoot
    directory: DirectoryHandle


class CommandGateModeError(RuntimeError):
    """Base class for bounded command-gate mode failures."""


class UnsafePathError(CommandGateModeError):
    """A configured state path failed structural ownership validation."""

    def __init__(
        self,
        message: str,
        *,
        config_state: ConfigState | None = None,
    ) -> None:
        super().__init__(message)
        self.config_state = config_state


class TelemetryReductionError(CommandGateModeError):
    """A denial could not be reduced to the closed telemetry schema."""


def _base_path(variable: str, fallback: tuple[str, ...]) -> Path:
    configured = os.environ.get(variable)
    if configured:
        path = Path(configured)
    else:
        home = os.environ.get("HOME")
        if not home:
            raise UnsafePathError("missing home directory")
        path = Path(home).joinpath(*fallback)
    if not path.is_absolute():
        raise UnsafePathError("state root is not absolute")
    return path


def _descriptor_identity(metadata: os.stat_result) -> DescriptorIdentity:
    return DescriptorIdentity(device=metadata.st_dev, inode=metadata.st_ino)


def _same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _validate_creation_parent(metadata: os.stat_result) -> None:
    mode = stat.S_IMODE(metadata.st_mode)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or mode & 0o300 != 0o300
        or mode & 0o002
        or mode & 0o7000
    ):
        raise UnsafePathError("creation parent metadata rejected")


def _validate_directory_identity(handle: DirectoryHandle) -> os.stat_result:
    descriptor_metadata = os.fstat(handle.descriptor)
    if not stat.S_ISDIR(descriptor_metadata.st_mode):
        raise UnsafePathError("directory descriptor type rejected")
    if _descriptor_identity(descriptor_metadata) != handle.identity:
        raise UnsafePathError("directory descriptor identity changed")
    if handle.parent_descriptor is not None and handle.name is not None:
        try:
            named_metadata = os.stat(
                handle.name,
                dir_fd=handle.parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise UnsafePathError("directory name disappeared") from error
        if not _same_identity(descriptor_metadata, named_metadata):
            raise UnsafePathError("directory name identity changed")
    elif handle.path is not None:
        try:
            named_metadata = os.stat(handle.path, follow_symlinks=False)
        except OSError as error:
            raise UnsafePathError("directory path disappeared") from error
        if not _same_identity(descriptor_metadata, named_metadata):
            raise UnsafePathError("directory path identity changed")
    return descriptor_metadata


def _validate_owned_directory(handle: DirectoryHandle) -> None:
    metadata = _validate_directory_identity(handle)
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise UnsafePathError("owned directory metadata rejected")


@contextmanager
def open_directory_path(path: Path, *, create: bool) -> Iterator[DirectoryHandle]:
    """Open one canonical absolute directory path without following aliases."""
    if not path.is_absolute():
        raise UnsafePathError("directory is not absolute")
    current_fd = os.open("/", DIRECTORY_OPEN_FLAGS)
    try:
        for component in path.parts[1:]:
            try:
                next_fd = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=current_fd)
            except FileNotFoundError:
                if not create:
                    raise
                _validate_creation_parent(os.fstat(current_fd))
                try:
                    os.mkdir(component, mode=0o700, dir_fd=current_fd)
                except FileExistsError:
                    pass
                next_fd = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=current_fd)
            except OSError as error:
                raise UnsafePathError("directory traversal rejected") from error
            os.close(current_fd)
            current_fd = next_fd
        metadata = os.fstat(current_fd)
        handle = DirectoryHandle(
            descriptor=current_fd,
            identity=_descriptor_identity(metadata),
            path=path,
            parent_descriptor=None,
            name=None,
        )
        _validate_directory_identity(handle)
        yield handle
    finally:
        os.close(current_fd)


@contextmanager
def open_owned_directory(
    parent: DirectoryHandle,
    name: str,
    *,
    create: bool,
) -> Iterator[DirectoryHandle]:
    _validate_directory_identity(parent)
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent.descriptor)
        except FileExistsError:
            pass
    try:
        descriptor = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=parent.descriptor)
    except OSError as error:
        if isinstance(error, FileNotFoundError):
            raise
        raise UnsafePathError("owned directory traversal rejected") from error
    try:
        metadata = os.fstat(descriptor)
        handle = DirectoryHandle(
            descriptor=descriptor,
            identity=_descriptor_identity(metadata),
            path=None,
            parent_descriptor=parent.descriptor,
            name=name,
        )
        _validate_owned_directory(handle)
        yield handle
        _validate_owned_directory(handle)
        _validate_directory_identity(parent)
    finally:
        os.close(descriptor)


@contextmanager
def _config_parent(*, create: bool) -> Iterator[DirectoryHandle]:
    base = _base_path("XDG_CONFIG_HOME", (".config",))
    with open_directory_path(base, create=create) as base_handle:
        with open_owned_directory(
            base_handle,
            CONFIG_RELATIVE[0],
            create=create,
        ) as parent:
            yield parent


def _regular_open_flags(purpose: FilePurpose) -> int:
    access_flags = {
        FilePurpose.CONFIG: os.O_RDONLY,
        FilePurpose.CONFIG_TEMP: os.O_WRONLY,
        FilePurpose.ROTATION_LOCK: os.O_RDWR,
        FilePurpose.LOG_APPEND: os.O_WRONLY | os.O_APPEND,
        FilePurpose.LOG_GENERATION: os.O_RDONLY,
    }[purpose]
    return access_flags | REGULAR_OPEN_BASE_FLAGS


def _validate_regular_metadata(
    metadata: os.stat_result,
    *,
    purpose: FilePurpose,
) -> None:
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        config_state = (
            ConfigState.INVALID_METADATA
            if purpose in (FilePurpose.CONFIG, FilePurpose.CONFIG_TEMP)
            else None
        )
        raise UnsafePathError(
            f"{purpose.value} file metadata rejected",
            config_state=config_state,
        )
    if purpose is FilePurpose.ROTATION_LOCK and metadata.st_size != 0:
        raise UnsafePathError("rotation lock must be empty")


def validate_named_identity(
    handle: RegularFileHandle,
    *,
    name: str | None = None,
) -> os.stat_result:
    descriptor_metadata = os.fstat(handle.descriptor)
    _validate_regular_metadata(descriptor_metadata, purpose=handle.purpose)
    if _descriptor_identity(descriptor_metadata) != handle.identity:
        raise UnsafePathError(f"{handle.purpose.value} descriptor identity changed")
    observed_name = handle.name if name is None else name
    try:
        named_metadata = os.stat(
            observed_name,
            dir_fd=handle.parent_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise UnsafePathError(
            f"{handle.purpose.value} file name disappeared"
        ) from error
    _validate_regular_metadata(named_metadata, purpose=handle.purpose)
    if not _same_identity(descriptor_metadata, named_metadata):
        raise UnsafePathError(f"{handle.purpose.value} file identity changed")
    return descriptor_metadata


@contextmanager
def open_regular_file(
    parent: DirectoryHandle,
    name: str,
    *,
    purpose: FilePurpose,
    create: bool,
) -> Iterator[RegularFileHandle]:
    _validate_directory_identity(parent)
    flags = _regular_open_flags(purpose)
    descriptor = -1
    created = False
    try:
        try:
            descriptor = os.open(name, flags, dir_fd=parent.descriptor)
        except FileNotFoundError:
            if not create:
                raise
            try:
                descriptor = os.open(
                    name,
                    flags | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=parent.descriptor,
                )
                created = True
            except FileExistsError:
                if purpose is FilePurpose.CONFIG_TEMP:
                    raise UnsafePathError("configuration temporary name already exists")
                descriptor = os.open(name, flags, dir_fd=parent.descriptor)
        except OSError as error:
            config_state = (
                ConfigState.INVALID_PATH
                if purpose in (FilePurpose.CONFIG, FilePurpose.CONFIG_TEMP)
                else None
            )
            raise UnsafePathError(
                f"{purpose.value} file open rejected",
                config_state=config_state,
            ) from error
        if created:
            os.fchmod(descriptor, 0o600)
        metadata = os.fstat(descriptor)
        handle = RegularFileHandle(
            descriptor=descriptor,
            identity=_descriptor_identity(metadata),
            parent_descriptor=parent.descriptor,
            name=name,
            purpose=purpose,
        )
        validate_named_identity(handle)
        yield handle
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_mode() -> ModeState:
    try:
        with _config_parent(create=False) as parent:
            try:
                with open_regular_file(
                    parent,
                    CONFIG_RELATIVE[1],
                    purpose=FilePurpose.CONFIG,
                    create=False,
                ) as config:
                    metadata = validate_named_identity(config)
                    if metadata.st_size > MAX_CONFIG_BYTES:
                        return ModeState(Mode.ENFORCING, ConfigState.OVERSIZE)
                    try:
                        value = os.read(config.descriptor, MAX_CONFIG_BYTES + 1)
                    except OSError:
                        return ModeState(Mode.ENFORCING, ConfigState.READ_ERROR)
                    validate_named_identity(config)
            except FileNotFoundError:
                return ModeState(Mode.PERMISSIVE, ConfigState.MISSING)
    except FileNotFoundError:
        return ModeState(Mode.PERMISSIVE, ConfigState.MISSING)
    except UnsafePathError as error:
        return ModeState(
            Mode.ENFORCING,
            error.config_state or ConfigState.INVALID_PATH,
        )
    except OSError:
        return ModeState(Mode.ENFORCING, ConfigState.READ_ERROR)
    if value == b"permissive\n":
        return ModeState(Mode.PERMISSIVE, ConfigState.CONFIGURED_PERMISSIVE)
    if value == b"enforcing\n":
        return ModeState(Mode.ENFORCING, ConfigState.CONFIGURED_ENFORCING)
    if len(value) > MAX_CONFIG_BYTES:
        return ModeState(Mode.ENFORCING, ConfigState.OVERSIZE)
    return ModeState(Mode.ENFORCING, ConfigState.INVALID_BYTES)


def set_mode(mode: Mode) -> None:
    temporary_name = f".command-gate-mode.{os.getpid()}.{secrets.token_hex(8)}"
    renamed = False
    with _config_parent(create=True) as parent:
        with open_regular_file(
            parent,
            temporary_name,
            purpose=FilePurpose.CONFIG_TEMP,
            create=True,
        ) as temporary:
            try:
                value = f"{mode.value}\n".encode()
                if os.write(temporary.descriptor, value) != len(value):
                    raise OSError(errno.EIO, "short configuration write")
                validate_named_identity(temporary)
                os.fsync(temporary.descriptor)
                validate_named_identity(temporary)
                os.rename(
                    temporary_name,
                    CONFIG_RELATIVE[1],
                    src_dir_fd=parent.descriptor,
                    dst_dir_fd=parent.descriptor,
                )
                renamed = True
                validate_named_identity(temporary, name=CONFIG_RELATIVE[1])
                os.fsync(parent.descriptor)
                validate_named_identity(temporary, name=CONFIG_RELATIVE[1])
            finally:
                if not renamed:
                    try:
                        validate_named_identity(temporary)
                        os.unlink(temporary_name, dir_fd=parent.descriptor)
                    except FileNotFoundError:
                        pass
    observed = read_mode()
    expected_state = (
        ConfigState.CONFIGURED_PERMISSIVE
        if mode is Mode.PERMISSIVE
        else ConfigState.CONFIGURED_ENFORCING
    )
    if observed.mode is not mode or observed.config_state is not expected_state:
        raise UnsafePathError("configuration reread did not match requested mode")


def parse_denial(raw: bytes) -> Denial:
    if not raw or len(raw) > MAX_DENIAL_BYTES:
        raise TelemetryReductionError("denial size rejected")
    try:
        document = json.loads(raw)
        reason = document["hookSpecificOutput"]["permissionDecisionReason"]
    except (KeyError, TypeError, ValueError, RecursionError) as error:
        raise TelemetryReductionError("denial document rejected") from error
    if (
        document["hookSpecificOutput"]["permissionDecision"] != "deny"
        or not isinstance(reason, str)
    ):
        raise TelemetryReductionError("denial shape rejected")
    code_match = CODE_PATTERN.match(reason)
    operation_match = OPERATION_PATTERN.search(reason)
    if code_match is None or operation_match is None:
        raise TelemetryReductionError("diagnostic identity rejected")
    try:
        code = TelemetryCode(code_match.group(1))
    except ValueError:
        code = TelemetryCode.OTHER
    try:
        operation = TelemetryOperation(operation_match.group(1))
    except ValueError:
        operation = TelemetryOperation.OTHER
    return Denial(
        raw=raw,
        code=code,
        operation=operation,
    )


def _normalized_absolute_path(value: str, *, label: str) -> Path:
    if not value or "\0" in value:
        raise UnsafePathError(f"{label} is missing or malformed")
    path = Path(value)
    if not path.is_absolute() or os.path.normpath(value) != value or str(path) != value:
        raise UnsafePathError(f"{label} is not absolute and lexically normalized")
    return path


def _validate_state_root_metadata(metadata: os.stat_result) -> None:
    mode = stat.S_IMODE(metadata.st_mode)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or mode & 0o700 != 0o700
        or mode & 0o022
        or mode & 0o7000
    ):
        raise UnsafePathError("telemetry state root metadata rejected")


def _validate_default_alias_chain(logical_path: Path) -> None:
    current = Path("/")
    for component in logical_path.parts[1:]:
        current /= component
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return
        except OSError as error:
            raise UnsafePathError("telemetry default alias inspection rejected") from error
        if stat.S_ISLNK(metadata.st_mode):
            try:
                target_metadata = os.stat(current)
            except OSError as error:
                raise UnsafePathError("telemetry default alias is unresolved") from error
            if not stat.S_ISDIR(target_metadata.st_mode):
                raise UnsafePathError("telemetry default alias target is not a directory")
        elif not stat.S_ISDIR(metadata.st_mode):
            raise UnsafePathError("telemetry default path component is not a directory")


def _resolve_default_path_twice(logical_path: Path) -> Path:
    _validate_default_alias_chain(logical_path)
    first = Path(os.path.realpath(logical_path, strict=False))
    _validate_default_alias_chain(logical_path)
    second = Path(os.path.realpath(logical_path, strict=False))
    if first != second or not first.is_absolute():
        raise UnsafePathError("telemetry default alias resolution changed")
    return first


@contextmanager
def _opened_canonical_directory(
    path: Path,
    *,
    create: bool,
) -> Iterator[DirectoryHandle]:
    with open_directory_path(path, create=create) as directory:
        yield directory


def _validate_state_root_identity(root: OpenedStateRoot) -> None:
    descriptor_metadata = _validate_directory_identity(root.directory)
    _validate_state_root_metadata(descriptor_metadata)
    try:
        canonical_metadata = os.stat(root.canonical_path, follow_symlinks=False)
    except OSError as error:
        raise UnsafePathError("telemetry canonical state root disappeared") from error
    if not _same_identity(descriptor_metadata, canonical_metadata):
        raise UnsafePathError("telemetry canonical state root identity changed")
    if root.allows_logical_alias:
        if _resolve_default_path_twice(root.logical_path) != root.canonical_path:
            raise UnsafePathError("telemetry logical state root changed target")
        try:
            logical_metadata = os.stat(root.logical_path)
        except OSError as error:
            raise UnsafePathError("telemetry logical state root disappeared") from error
    else:
        if Path(os.path.realpath(root.logical_path, strict=False)) != root.canonical_path:
            raise UnsafePathError("telemetry explicit state root became noncanonical")
        try:
            logical_metadata = os.stat(root.logical_path, follow_symlinks=False)
        except OSError as error:
            raise UnsafePathError("telemetry explicit state root disappeared") from error
    if not _same_identity(descriptor_metadata, logical_metadata):
        raise UnsafePathError("telemetry logical state root identity changed")


@contextmanager
def _opened_state_root(*, create: bool) -> Iterator[OpenedStateRoot]:
    configured = os.environ.get("XDG_STATE_HOME")
    if configured:
        # Explicit XDG_STATE_HOME is caller-selected, so it must already be canonical.
        logical_path = _normalized_absolute_path(configured, label="XDG_STATE_HOME")
        canonical_path = Path(os.path.realpath(logical_path, strict=False))
        if canonical_path != logical_path:
            raise UnsafePathError("XDG_STATE_HOME must not contain aliases")
        allows_logical_alias = False
    else:
        # The derived HOME default may preserve an existing stable .local alias.
        home_value = os.environ.get("HOME", "")
        home = _normalized_absolute_path(home_value, label="HOME")
        logical_path = home / ".local" / "state"
        canonical_path = _resolve_default_path_twice(logical_path)
        allows_logical_alias = True
    with _opened_canonical_directory(canonical_path, create=create) as directory:
        metadata = _validate_directory_identity(directory)
        _validate_state_root_metadata(metadata)
        root = OpenedStateRoot(
            directory=directory,
            logical_path=logical_path,
            canonical_path=canonical_path,
            allows_logical_alias=allows_logical_alias,
        )
        _validate_state_root_identity(root)
        yield root


@contextmanager
def _opened_log_directory() -> Iterator[OpenedLogDirectory]:
    with _opened_state_root(create=True) as root:
        with open_owned_directory(
            root.directory,
            LOG_RELATIVE[0],
            create=True,
        ) as eci_directory:
            with open_owned_directory(
                eci_directory,
                LOG_RELATIVE[1],
                create=True,
            ) as log_directory:
                yield OpenedLogDirectory(root=root, directory=log_directory)
                _validate_owned_directory(log_directory)
                _validate_state_root_identity(root)


def _validate_telemetry_file(metadata: os.stat_result, *, label: str) -> None:
    del label
    _validate_regular_metadata(metadata, purpose=FilePurpose.LOG_GENERATION)


def _validate_named_descriptor(parent_descriptor: int, name: str, descriptor: int) -> None:
    metadata = os.fstat(descriptor)
    handle = RegularFileHandle(
        descriptor=descriptor,
        identity=_descriptor_identity(metadata),
        parent_descriptor=parent_descriptor,
        name=name,
        purpose=FilePurpose.LOG_GENERATION,
    )
    validate_named_identity(handle)


def _open_existing_regular(
    stack: ExitStack,
    parent: DirectoryHandle,
    name: str,
    purpose: FilePurpose,
) -> RegularFileHandle | None:
    try:
        return stack.enter_context(
            open_regular_file(
                parent,
                name,
                purpose=purpose,
                create=False,
            )
        )
    except FileNotFoundError:
        return None


def _validate_fixed_log_family(parent: DirectoryHandle) -> None:
    with ExitStack() as stack:
        _open_existing_regular(
            stack,
            parent,
            ROTATION_LOCK_NAME,
            FilePurpose.ROTATION_LOCK,
        )
        _open_existing_regular(
            stack,
            parent,
            LOG_NAME,
            FilePurpose.LOG_GENERATION,
        )
        for name in ROTATED_LOG_NAMES:
            _open_existing_regular(
                stack,
                parent,
                name,
                FilePurpose.LOG_GENERATION,
            )


def _name_is_absent(parent: DirectoryHandle, name: str) -> bool:
    try:
        os.stat(name, dir_fd=parent.descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return True
    except OSError as error:
        raise UnsafePathError("telemetry family name inspection failed") from error
    return False


def _unlink_open_file(parent: DirectoryHandle, handle: RegularFileHandle) -> None:
    validate_named_identity(handle)
    os.unlink(handle.name, dir_fd=parent.descriptor)
    if not _name_is_absent(parent, handle.name):
        raise UnsafePathError("telemetry generation unlink did not remove its name")
    metadata = os.fstat(handle.descriptor)
    if _descriptor_identity(metadata) != handle.identity or metadata.st_nlink != 0:
        raise UnsafePathError("telemetry generation unlink identity changed")


def _rename_open_file(
    parent: DirectoryHandle,
    handle: RegularFileHandle,
    destination: str,
) -> None:
    validate_named_identity(handle)
    if not _name_is_absent(parent, destination):
        raise UnsafePathError("telemetry rotation destination is occupied")
    os.rename(
        handle.name,
        destination,
        src_dir_fd=parent.descriptor,
        dst_dir_fd=parent.descriptor,
    )
    if not _name_is_absent(parent, handle.name):
        raise UnsafePathError("telemetry rotation source name persisted")
    validate_named_identity(handle, name=destination)
    _validate_directory_identity(parent)


def _rotate_fixed_family(parent: DirectoryHandle) -> bool:
    with ExitStack() as stack:
        current = _open_existing_regular(
            stack,
            parent,
            LOG_NAME,
            FilePurpose.LOG_GENERATION,
        )
        generations = {
            name: _open_existing_regular(
                stack,
                parent,
                name,
                FilePurpose.LOG_GENERATION,
            )
            for name in ROTATED_LOG_NAMES
        }
        if current is None:
            return False
        current_metadata = validate_named_identity(current)
        if current_metadata.st_size < MAX_LOG_BYTES:
            return False
        oldest = generations[ROTATED_LOG_NAMES[-1]]
        if oldest is not None:
            _unlink_open_file(parent, oldest)
        for generation in range(MAX_LOG_FILES - 1, 0, -1):
            source_name = f"{LOG_NAME}.{generation}"
            source = generations[source_name]
            if source is not None:
                _rename_open_file(parent, source, f"{LOG_NAME}.{generation + 1}")
        _rename_open_file(parent, current, ROTATED_LOG_NAMES[0])
    _validate_fixed_log_family(parent)
    return True


def _validate_handle_in_fixed_family(
    parent: DirectoryHandle,
    handle: RegularFileHandle,
) -> None:
    descriptor_metadata = os.fstat(handle.descriptor)
    _validate_regular_metadata(descriptor_metadata, purpose=handle.purpose)
    matches = 0
    for name in (LOG_NAME, *ROTATED_LOG_NAMES):
        try:
            metadata = os.stat(
                name,
                dir_fd=parent.descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            continue
        _validate_regular_metadata(metadata, purpose=FilePurpose.LOG_GENERATION)
        if _same_identity(descriptor_metadata, metadata):
            matches += 1
    if matches != 1:
        raise UnsafePathError("appended log no longer has exactly one retained name")


def _append_record(parent: DirectoryHandle, record: bytes) -> None:
    with open_regular_file(
        parent,
        LOG_NAME,
        purpose=FilePurpose.LOG_APPEND,
        create=True,
    ) as log:
        validate_named_identity(log)
        if os.write(log.descriptor, record) != len(record):
            raise OSError(errno.EIO, "short telemetry write")
        try:
            validate_named_identity(log)
        except UnsafePathError:
            _validate_handle_in_fixed_family(parent, log)
    _validate_directory_identity(parent)


def try_rotate_log(parent: DirectoryHandle, record: bytes) -> RotationOutcome:
    with open_regular_file(
        parent,
        ROTATION_LOCK_NAME,
        purpose=FilePurpose.ROTATION_LOCK,
        create=True,
    ) as lock:
        validate_named_identity(lock)
        try:
            fcntl.flock(lock.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            _append_record(parent, record)
            return RotationOutcome.LOCK_CONTENDED
        validate_named_identity(lock)
        _validate_fixed_log_family(parent)
        rotated = _rotate_fixed_family(parent)
        _append_record(parent, record)
        _validate_fixed_log_family(parent)
        validate_named_identity(lock)
        return RotationOutcome.ROTATED if rotated else RotationOutcome.APPENDED


def append_event(
    denial: Denial,
    *,
    provider: Provider,
    role: Role,
    marker: Marker,
    source: Source,
    config_state: ConfigState,
) -> None:
    with _opened_log_directory() as location:
        event = {
            "schema": SCHEMA,
            "event": "would-deny",
            "at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
                "+00:00", "Z"
            ),
            "provider": provider.value,
            "role": role.value,
            "marker": marker.value,
            "source": source.value,
            "code": denial.code.value,
            "operation": denial.operation.value,
            "config_state": config_state.value,
        }
        record = json.dumps(event, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"
        if len(record) > MAX_EVENT_BYTES:
            raise TelemetryReductionError("telemetry event exceeds the bounded record size")
        try_rotate_log(location.directory, record)
        _validate_state_root_identity(location.root)


def emit_telemetry_unavailable() -> None:
    try:
        os.write(2, b"eci-command-gate-mode: telemetry unavailable\n")
    except OSError:
        pass


def _stream_enforcing_input() -> int:
    while True:
        chunk = sys.stdin.buffer.read(MAX_DENIAL_BYTES)
        if not chunk:
            return 0
        sys.stdout.buffer.write(chunk)


def _read_permissive_input() -> bytes:
    raw = sys.stdin.buffer.read(MAX_DENIAL_BYTES + 1)
    oversize = len(raw) > MAX_DENIAL_BYTES
    while sys.stdin.buffer.read(MAX_DENIAL_BYTES):
        oversize = True
    if oversize:
        raise TelemetryReductionError("denial size rejected")
    return raw


def finalize(provider: Provider, role: Role, marker: Marker, source: Source) -> int:
    mode_state = read_mode()
    if mode_state.mode is Mode.ENFORCING:
        return _stream_enforcing_input()
    try:
        raw = _read_permissive_input()
        denial = parse_denial(raw)
        append_event(
            denial,
            provider=provider,
            role=role,
            marker=marker,
            source=source,
            config_state=mode_state.config_state,
        )
    except Exception:
        emit_telemetry_unavailable()
    return 0


def _usage() -> int:
    print(
        "usage: eci-command-gate-mode get | set permissive | set enforcing",
        file=sys.stderr,
    )
    return 2


def main(arguments: list[str]) -> int:
    if arguments == ["get"]:
        state = read_mode()
        print(
            json.dumps(
                {"mode": state.mode.value, "config_state": state.config_state.value},
                separators=(",", ":"),
            )
        )
        return 0
    if len(arguments) == 2 and arguments[0] == "set":
        if arguments[1] not in (Mode.PERMISSIVE.value, Mode.ENFORCING.value):
            return _usage()
        try:
            mode = Mode(arguments[1])
            set_mode(mode)
        except (OSError, CommandGateModeError) as error:
            print(f"eci-command-gate-mode: set failed: {error}", file=sys.stderr)
            return 1
        return 0
    if len(arguments) == 5 and arguments[0] == "finalize":
        try:
            provider = Provider(arguments[1])
            role = Role(arguments[2])
            marker = Marker(arguments[3])
            source = Source(arguments[4])
        except ValueError:
            return 2
        return finalize(provider, role, marker, source)
    return _usage()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
