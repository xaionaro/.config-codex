#!/usr/bin/env python3
"""Classify one finite literal shell command plan for the ECI Bash gate."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import sys
from dataclasses import dataclass


MAX_BYTES = 16 * 1024
MAX_SEGMENTS = 8
MAX_ARGV = 128
MAX_ARG_BYTES = 4 * 1024
MAX_WRAPPER_DEPTH = 8
PUBLIC_ENV_NAMES = {
    "CODEX_HOME",
    "CODEX_ROLE",
    "CODEX_SESSION_ID",
    "HOME",
    "KIMI_CODE_HOME",
    "KIMI_ROLE",
    "KIMI_SESSION_ID",
    "PATH",
    "PWD",
    "SESSION_ID",
    "TMPDIR",
}
CONTEXT_ENV_NAMES = {
    "BASH_ENV",
    "ENV",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_DIR",
    "GIT_EXTERNAL_DIFF",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
    "PERL5OPT",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONSTARTUP",
    "RUBYOPT",
}
RESERVED_CONTROLS = {
    "!",
    "[[",
    "]]",
    "case",
    "coproc",
    "do",
    "done",
    "elif",
    "else",
    "esac",
    "fi",
    "for",
    "function",
    "if",
    "in",
    "select",
    "then",
    "time",
    "until",
    "while",
}
TRANSPARENT_WRAPPERS = {
    "chronic",
    "command",
    "doas",
    "env",
    "exec",
    "nice",
    "nohup",
    "prlimit",
    "setsid",
    "sudo",
    "systemd-run",
    "time",
    "timeout",
}
LIFECYCLE_NAMES = {
    "eci-active",
    "eci-active-gate.sh",
    "eci-review-gate",
    "eci-review-gate.sh",
    "eci-stage",
    "stop-gate.sh",
}
BROAD_DESTRUCTIVE_NAMES = {
    "mkfs",
    "mkfs.btrfs",
    "mkfs.ext4",
}
SOURCE_WRITERS = {
    "chmod",
    "chown",
    "cp",
    "dd",
    "install",
    "ln",
    "mv",
    "patch",
    "rm",
    "rsync",
    "rmdir",
    "shred",
    "srm",
    "tee",
    "touch",
    "truncate",
    "unlink",
}
PATH_CAPABILITY_NAMES = SOURCE_WRITERS | {
    "bash",
    "cat",
    "cmp",
    "dash",
    "diff",
    "file",
    "find",
    "git",
    "grep",
    "head",
    "ls",
    "node",
    "perl",
    "php",
    "python",
    "python2",
    "python3",
    "readlink",
    "rg",
    "ruby",
    "sed",
    "sh",
    "sha256sum",
    "stat",
    "tail",
    "wc",
    "zsh",
}
LIVE_EXACT = {
    "baseline_head",
    "eci-acceptance-anchor",
    "eci-acceptance-transaction",
    "eci-baseline-binding",
    "eci-commit-admitted",
    "eci-required-critics.json",
    "eci-critic-identities.ledger",
    "eci-teardown-complete",
    "eci-user-closed.ledger",
    "eci_active",
    "eci_user_owned_wait.md",
    "eci_wait",
    "goal_state",
    "stop_loop_state",
    "stop_timestamps",
}
LIVE_PREFIXES = (
    "eci-acceptance-anchor.",
    "eci-acceptance-transaction.",
    "eci-baseline-binding.",
    "eci-commit-admitted.",
    "eci-critic-identities.",
    "eci-required-critics.",
    "eci-teardown-complete.",
    "stop_loop_state.",
    "stop_timestamps.",
)


@dataclass(frozen=True)
class Token:
    value: str
    offset: int
    protected: tuple[bool, ...]


@dataclass(frozen=True)
class Segment:
    argv: tuple[Token, ...]
    offset: int


@dataclass(frozen=True)
class Plan:
    segments: tuple[Segment, ...]
    operators: tuple[str, ...]


@dataclass(frozen=True)
class EnvironmentAssignment:
    name: str
    value: str
    argv_index: int
    token: Token


@dataclass(frozen=True)
class EnvironmentCommand:
    child: tuple[Token, ...]
    child_argv_index: int
    assignments: tuple[EnvironmentAssignment, ...]


@dataclass(frozen=True)
class GateModeIdentity:
    canonical_paths: tuple[str, str]
    identity: tuple[int, int] | None
    size: int
    digest: bytes
    failure: str


class PlanError(Exception):
    def __init__(
        self,
        code: str,
        reason: str,
        offset: int,
        segment: int,
        argv_index: int,
        token: str,
        remediation: str,
        *,
        predicate: str = "syntax",
        path: str = "n/a",
    ) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason
        self.offset = offset
        self.segment = segment
        self.argv_index = argv_index
        self.token = token
        self.remediation = remediation
        self.predicate = predicate
        self.path = path


def shell_escape(value: str) -> str:
    if not value:
        return "''"
    if re.fullmatch(r"[A-Za-z0-9_./:=+,-]+", value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


def parse(command: str) -> Plan:
    encoded = command.encode("utf-8", "strict")
    byte_offsets = [0]
    for character in command:
        byte_offsets.append(byte_offsets[-1] + len(character.encode("utf-8")))
    if len(encoded) > MAX_BYTES:
        raise PlanError(
            "ECI_PLAN_LIMIT_DENIED",
            f"command is {len(encoded)} bytes; maximum is {MAX_BYTES}",
            MAX_BYTES,
            1,
            0,
            "<command>",
            "split the command into smaller finite literal calls",
            predicate="command-byte-limit",
        )
    if "\x00" in command or "\r" in command:
        bad = "\x00" if "\x00" in command else "\r"
        offset = byte_offsets[command.index(bad)]
        raise PlanError(
            "ECI_PLAN_SYNTAX_DENIED",
            "NUL and carriage-return bytes are not command-plan syntax",
            offset,
            1,
            0,
            repr(bad),
            "remove the reported byte and retry one literal plan",
            predicate="forbidden-byte",
        )

    segments: list[Segment] = []
    operators: list[str] = []
    current: list[Token] = []
    chars: list[str] = []
    provenance: list[bool] = []
    token_offset = 0
    token_started = False
    quote = ""
    escaped = False
    index = 0

    def flush_token() -> None:
        nonlocal chars, provenance, token_started
        if not token_started:
            return
        token = Token("".join(chars), token_offset, tuple(provenance))
        if len(token.value.encode("utf-8")) > MAX_ARG_BYTES:
            raise PlanError(
                "ECI_PLAN_LIMIT_DENIED",
                f"argv element is larger than {MAX_ARG_BYTES} bytes",
                token.offset,
                len(segments) + 1,
                len(current),
                token.value[:80],
                "shorten the reported argv element and retry",
                predicate="argv-byte-limit",
            )
        current.append(token)
        chars = []
        provenance = []
        token_started = False

    def flush_segment(operator: str, offset: int) -> None:
        flush_token()
        if not current:
            raise PlanError(
                "ECI_PLAN_SYNTAX_DENIED",
                "a command-plan operator has an empty adjacent segment",
                offset,
                len(segments) + 1,
                0,
                operator,
                "supply one nonempty literal argv on each side of the operator",
                predicate="empty-segment",
            )
        if len(segments) >= MAX_SEGMENTS:
            raise PlanError(
                "ECI_PLAN_LIMIT_DENIED",
                f"command plan exceeds {MAX_SEGMENTS} segments",
                offset,
                len(segments) + 1,
                0,
                operator,
                "split the plan into separately reviewed calls",
                predicate="segment-limit",
            )
        segments.append(Segment(tuple(current), current[0].offset))
        current.clear()
        operators.append(operator)

    while index < len(command):
        char = command[index]
        if escaped:
            chars.append(char)
            provenance.append(True)
            token_started = True
            escaped = False
            index += 1
            continue
        if quote == "'":
            if char == "'":
                quote = ""
            else:
                chars.append(char)
                provenance.append(True)
            index += 1
            continue
        if char == "\\":
            if not chars:
                token_offset = byte_offsets[index]
            token_started = True
            escaped = True
            index += 1
            continue
        if char == "'":
            if not chars:
                token_offset = byte_offsets[index]
            token_started = True
            quote = "'"
            index += 1
            continue
        if char == '"':
            if not chars:
                token_offset = byte_offsets[index]
            token_started = True
            quote = "" if quote == '"' else '"'
            index += 1
            continue
        in_double = quote == '"'
        if char in " \t" and not in_double:
            flush_token()
            index += 1
            continue
        if not in_double:
            operator = ""
            if command.startswith("&&", index) or command.startswith("||", index):
                operator = command[index:index + 2]
            elif char in ";|\n":
                operator = char
            if operator:
                flush_segment(operator, byte_offsets[index])
                index += len(operator)
                continue
            if char == "&":
                raise PlanError(
                    "ECI_PLAN_SYNTAX_DENIED",
                    "background execution is not a finite command-plan operator",
                    byte_offsets[index],
                    len(segments) + 1,
                    len(current),
                    char,
                    "remove '&' or use a finite supported plan operator",
                    predicate="background-operator",
                )
            if char in "<>":
                predicate = "process-substitution" if index + 1 < len(command) and command[index + 1] == "(" else "redirection"
                raise PlanError(
                    "ECI_PLAN_SYNTAX_DENIED",
                    f"{predicate.replace('-', ' ')} is not literal argv syntax",
                    byte_offsets[index],
                    len(segments) + 1,
                    len(current),
                    command[index:index + 2] if predicate == "process-substitution" else char,
                    "pass paths as literal argv and let the invoked tool perform I/O",
                    predicate=predicate,
                )
            if char in "()":
                raise PlanError(
                    "ECI_PLAN_SYNTAX_DENIED",
                    "shell grouping and process substitution are not literal argv syntax",
                    byte_offsets[index],
                    len(segments) + 1,
                    len(current),
                    char,
                    "invoke a finite direct argv without shell grouping",
                    predicate="grouping",
                )
            if char == "#" and not token_started:
                raise PlanError(
                    "ECI_PLAN_SYNTAX_DENIED",
                    "unquoted shell comments are not part of a literal command plan",
                    byte_offsets[index],
                    len(segments) + 1,
                    len(current),
                    char,
                    "remove the comment or quote the literal hash character",
                    predicate="comment",
                )
            if char in "*?[{}" or (char == "~" and not token_started):
                raise PlanError(
                    "ECI_PLAN_SYNTAX_DENIED",
                    "unquoted expansion syntax makes argv filesystem- or shell-dependent",
                    byte_offsets[index],
                    len(segments) + 1,
                    len(current),
                    char,
                    "quote or escape the literal metacharacter, or pass explicit argv",
                    predicate="shell-expansion",
                )
        if char in "$`" and quote != "'":
            raise PlanError(
                "ECI_PLAN_SYNTAX_DENIED",
                "parameter, command, or arithmetic expansion makes argv dynamic",
                byte_offsets[index],
                len(segments) + 1,
                len(current),
                char,
                "replace expansion with explicit literal argv",
                predicate="dynamic-expansion",
            )
        if not chars:
            token_offset = byte_offsets[index]
        chars.append(char)
        provenance.append(bool(quote))
        token_started = True
        index += 1

    if escaped or quote:
        raise PlanError(
            "ECI_PLAN_SYNTAX_DENIED",
            "shell quoting or escaping is unbalanced",
            len(encoded),
            len(segments) + 1,
            len(current),
            quote or "\\",
            "close the reported quote or remove the trailing escape",
            predicate="unbalanced-quote",
        )
    flush_token()
    if not current:
        token = operators[-1] if operators else "<empty>"
        raise PlanError(
            "ECI_PLAN_SYNTAX_DENIED",
            "command plan has no final literal argv",
            len(encoded),
            len(segments) + 1,
            0,
            token,
            "supply one nonempty literal argv after the operator",
            predicate="empty-segment",
        )
    segments.append(Segment(tuple(current), current[0].offset))
    total_argv = sum(len(segment.argv) for segment in segments)
    if len(segments) > MAX_SEGMENTS or total_argv > MAX_ARGV:
        raise PlanError(
            "ECI_PLAN_LIMIT_DENIED",
            f"command plan contains {len(segments)} segments and {total_argv} argv elements; limits are {MAX_SEGMENTS} and {MAX_ARGV}",
            len(encoded),
            len(segments),
            len(segments[-1].argv) - 1,
            "<plan>",
            "split the plan into smaller separately reviewed calls",
            predicate="plan-limit",
        )
    return Plan(tuple(segments), tuple(operators))


def assignment_name(value: str) -> str | None:
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", value, re.S)
    return match.group(1) if match else None


def shell_assignment_name(token: Token) -> str | None:
    name = assignment_name(token.value)
    if name is None:
        return None
    equals_index = len(name)
    if any(token.protected[:equals_index + 1]):
        return None
    return name


def error_for_token(
    code: str,
    reason: str,
    segment_index: int,
    argv_index: int,
    token: Token,
    remediation: str,
    predicate: str,
    *,
    path: str = "n/a",
) -> PlanError:
    return PlanError(
        code,
        reason,
        token.offset,
        segment_index,
        argv_index,
        token.value,
        remediation,
        predicate=predicate,
        path=path,
    )


def parse_env_command(
    argv: tuple[Token, ...], segment_index: int
) -> EnvironmentCommand:
    index = 1
    while index < len(argv):
        token = argv[index]
        value = token.value
        if value == "--":
            index += 1
            break
        if value in {"-i", "--ignore-environment"}:
            index += 1
            continue
        if value in {"-S", "--split-string"} or value.startswith("--split-string="):
            raise error_for_token(
                "ECI_ENVIRONMENT_OPTION_DENIED",
                "env split-string constructs argv dynamically",
                segment_index,
                index,
                token,
                "remove split-string and pass the child argv literally",
                "environment-split-string",
            )
        if value in {"-u", "--unset", "-C", "--chdir"}:
            if index + 1 >= len(argv):
                raise error_for_token(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    f"env option {value} is missing its required argument",
                    segment_index,
                    index,
                    token,
                    "supply the required literal option argument",
                    "environment-missing-option-argument",
                )
            if value in {"-u", "--unset"} and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", argv[index + 1].value):
                raise error_for_token(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    f"env option {value} argument is not a valid identifier",
                    segment_index,
                    index + 1,
                    argv[index + 1],
                    "supply one literal environment identifier",
                    "environment-invalid-option-argument",
                )
            index += 2
            continue
        if value.startswith("--unset="):
            unset_name = value.split("=", 1)[1]
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", unset_name):
                raise error_for_token(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    f"env option {value} argument is not a valid identifier",
                    segment_index,
                    index,
                    token,
                    "supply --unset=NAME with one literal environment identifier",
                    "environment-invalid-option-argument",
                )
            index += 1
            continue
        if value.startswith("--chdir="):
            index += 1
            continue
        if value.startswith("-"):
            raise error_for_token(
                "ECI_ENVIRONMENT_OPTION_DENIED",
                f"unsupported env option {value}",
                segment_index,
                index,
                token,
                "use -i, -u NAME, -C DIR, assignments, --, and a literal child argv",
                "environment-unsupported-option",
            )
        break

    assignments: list[EnvironmentAssignment] = []
    while index < len(argv):
        token = argv[index]
        name = assignment_name(token.value)
        if name is None:
            break
        if name in CONTEXT_ENV_NAMES or name.startswith("GIT_"):
            kind = "registered repository" if name.startswith("GIT_") else "registered interpreter"
            raise error_for_token(
                "ECI_ENVIRONMENT_CONTEXT_DENIED",
                f"environment assignment name {name} changes {kind} context",
                segment_index,
                index,
                Token(name, token.offset, tuple(False for _ in name)),
                f"remove the {name} context assignment and invoke the literal child directly",
                "environment-context-assignment",
            )
        assignments.append(
            EnvironmentAssignment(
                name,
                token.value.split("=", 1)[1],
                index,
                token,
            )
        )
        index += 1
    if index >= len(argv):
        token = argv[0]
        raise error_for_token(
            "ECI_ENVIRONMENT_ENUMERATION_DENIED",
            "env has no remaining child executable and would enumerate inherited environment state",
            segment_index,
            0,
            token,
            "provide one finite literal child argv after env options and assignments",
            "environment-enumeration",
        )
    return EnvironmentCommand(argv[index:], index, tuple(assignments))


def env_child(argv: tuple[Token, ...], segment_index: int) -> tuple[Token, ...]:
    return parse_env_command(argv, segment_index).child


def canonical_lifecycle_provider(token: Token) -> str | None:
    if not os.path.isabs(token.value) or os.path.normpath(token.value) != token.value:
        return None
    home = os.environ.get("HOME", "")
    roots = {
        "codex": os.environ.get("CODEX_HOME", os.path.join(home, ".codex")),
        "kimi": os.environ.get("KIMI_CODE_HOME", os.path.join(home, ".kimi-code")),
    }
    for provider, root in roots.items():
        if root and token.value == os.path.join(os.path.normpath(root), "bin", "eci-active"):
            return provider
    return None


def _file_digest(path: str, expected: os.stat_result) -> bytes | None:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        observed = os.fstat(descriptor)
        if (
            not stat.S_ISREG(observed.st_mode)
            or (observed.st_dev, observed.st_ino)
            != (expected.st_dev, expected.st_ino)
            or observed.st_size != expected.st_size
        ):
            return None
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                return digest.digest()
            digest.update(chunk)
    finally:
        os.close(descriptor)


def gate_mode_identity() -> GateModeIdentity:
    home = os.environ.get("HOME", "")
    roots = (
        os.environ.get("CODEX_HOME", os.path.join(home, ".codex")),
        os.environ.get("KIMI_CODE_HOME", os.path.join(home, ".kimi-code")),
    )
    paths = tuple(
        os.path.join(os.path.normpath(root), "bin", "eci-command-gate-mode")
        for root in roots
    )
    if any(
        not root
        or not os.path.isabs(root)
        or os.path.normpath(root) != root
        or not os.path.isabs(path)
        for root, path in zip(roots, paths, strict=True)
    ):
        return GateModeIdentity(paths, None, 0, b"", "canonical-path-invalid")
    states: list[os.stat_result] = []
    for path in paths:
        try:
            state = os.lstat(path)
        except OSError:
            return GateModeIdentity(paths, None, 0, b"", "canonical-path-missing")
        if (
            stat.S_ISLNK(state.st_mode)
            or not stat.S_ISREG(state.st_mode)
            or state.st_uid != os.getuid()
            or not state.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        ):
            return GateModeIdentity(paths, None, 0, b"", "canonical-metadata-invalid")
        states.append(state)
    identities = {(state.st_dev, state.st_ino) for state in states}
    if len(identities) != 1:
        return GateModeIdentity(paths, None, 0, b"", "canonical-hardlink-split")
    digest = _file_digest(paths[0], states[0])
    if digest is None:
        return GateModeIdentity(paths, None, 0, b"", "canonical-read-race")
    return GateModeIdentity(
        paths,
        (states[0].st_dev, states[0].st_ino),
        states[0].st_size,
        digest,
        "",
    )


def resolved_executable(token: Token, cwd: str) -> str:
    value = token.value
    if os.path.isabs(value):
        return os.path.normpath(value)
    if os.sep in value:
        return os.path.normpath(os.path.abspath(os.path.join(cwd, value)))
    return shutil.which(value) or ""


def candidate_matches_gate_mode(
    token: Token,
    cwd: str,
    identity: GateModeIdentity,
    *,
    interpreter_script: bool,
) -> tuple[bool, str]:
    candidate = resolved_executable(token, cwd)
    reserved_name = os.path.basename(token.value) == "eci-command-gate-mode"
    names_canonical = candidate in identity.canonical_paths
    if identity.failure:
        if reserved_name or names_canonical:
            return False, identity.failure
        return False, ""
    if not candidate:
        return (False, "candidate-not-resolved") if reserved_name else (False, "")
    try:
        state = os.stat(candidate, follow_symlinks=True)
    except OSError:
        return (False, "candidate-not-readable") if reserved_name else (False, "")
    if not stat.S_ISREG(state.st_mode) or state.st_uid != os.getuid():
        return (False, "candidate-metadata-invalid") if reserved_name else (False, "")
    if not interpreter_script and not state.st_mode & (
        stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    ):
        return (False, "candidate-not-executable") if reserved_name else (False, "")
    if (state.st_dev, state.st_ino) == identity.identity:
        return True, ""
    if state.st_size != identity.size:
        return (False, "reserved-copy-size-mismatch") if reserved_name else (False, "")
    try:
        descriptor = os.open(candidate, os.O_RDONLY)
    except OSError:
        return (False, "candidate-not-readable") if reserved_name else (False, "")
    try:
        observed = os.fstat(descriptor)
        if (
            not stat.S_ISREG(observed.st_mode)
            or (observed.st_dev, observed.st_ino) != (state.st_dev, state.st_ino)
            or observed.st_size != state.st_size
        ):
            return False, "candidate-read-race"
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    if digest.digest() == identity.digest:
        return True, ""
    return (False, "reserved-copy-digest-mismatch") if reserved_name else (False, "")


def gate_mode_mutation_error(
    argv: tuple[Token, ...],
    original_argv: tuple[Token, ...],
    segment_index: int,
    role: str,
    cwd: str,
    identity: GateModeIdentity,
) -> PlanError | None:
    interpreter_script = os.path.basename(argv[0].value) in {"python", "python3"}
    target_index = 1 if interpreter_script else 0
    action_index = target_index + 1
    if action_index >= len(argv) or argv[action_index].value != "set":
        return None
    target = argv[target_index]
    matched, identity_failure = candidate_matches_gate_mode(
        target,
        cwd,
        identity,
        interpreter_script=interpreter_script,
    )
    target_original_index = next(
        index for index, original in enumerate(original_argv) if original is target
    )
    if identity_failure:
        return error_for_token(
            "ECI_CONTROL_IDENTITY_DENIED",
            "command-gate control executable identity validation failed: "
            f"failure={identity_failure}",
            segment_index,
            target_original_index,
            target,
            "restore the canonical owner-executable Codex/Kimi hardlink pair before retrying",
            "gate-mode-identity",
            path=resolved_executable(target, cwd) or "n/a",
        )
    if not matched or role != "worker":
        return None
    action = argv[action_index]
    action_original_index = next(
        index for index, original in enumerate(original_argv) if original is action
    )
    return error_for_token(
        "ECI_CONTROL_OWNER_REQUIRED",
        "worker argv selects coordinator-owned command-gate mode mutation",
        segment_index,
        action_original_index,
        action,
        "route the exact command-gate mode change through the coordinator",
        "gate-mode-mutation",
        path=resolved_executable(target, cwd) or "n/a",
    )


def canonical_lifecycle_name(token: Token, cwd: str) -> str | None:
    name = os.path.basename(token.value)
    if name not in LIFECYCLE_NAMES:
        return None
    candidate = token.value
    if os.sep not in candidate:
        candidate = shutil.which(candidate) or ""
    elif not os.path.isabs(candidate):
        candidate = os.path.abspath(os.path.join(cwd, candidate))
    if not candidate or os.path.normpath(candidate) != candidate:
        return None

    home = os.environ.get("HOME", "")
    roots = {
        os.environ.get("CODEX_HOME", os.path.join(home, ".codex")),
        os.environ.get("KIMI_CODE_HOME", os.path.join(home, ".kimi-code")),
    }
    for root in roots:
        if not root:
            continue
        normalized = os.path.normpath(root)
        expected = {
            os.path.join(normalized, "bin", "eci-active"),
            os.path.join(normalized, "bin", "eci-review-gate"),
            os.path.join(normalized, "bin", "eci-stage"),
            os.path.join(normalized, "hooks", "eci-active-gate.sh"),
            os.path.join(normalized, "hooks", "eci-review-gate.sh"),
            os.path.join(normalized, "hooks", "stop-gate.sh"),
        }
        if candidate in expected:
            return name
    return None


def lifecycle_identity_error(
    argv: tuple[Token, ...], segment_index: int, active_session: str
) -> PlanError | None:
    if os.path.basename(argv[0].value) != "env":
        return None
    command = parse_env_command(argv, segment_index)
    target_provider = canonical_lifecycle_provider(command.child[0])
    if target_provider is None:
        return None

    expected_name = "CODEX_SESSION_ID" if target_provider == "codex" else "KIMI_SESSION_ID"
    wrong_name = "KIMI_SESSION_ID" if target_provider == "codex" else "CODEX_SESSION_ID"
    remediation = "env {}={} {}".format(
        expected_name,
        shell_escape(active_session),
        " ".join(shell_escape(token.value) for token in command.child),
    )
    wrong = next(
        (assignment for assignment in command.assignments if assignment.name == wrong_name),
        None,
    )
    if wrong is not None:
        return error_for_token(
            "ECI_PLAN_LIFECYCLE_IDENTITY_DENIED",
            f"provider session identity mismatch: target_provider={target_provider} expected_name={expected_name} observed_name={wrong_name}",
            segment_index,
            wrong.argv_index,
            wrong.token,
            remediation,
            "lifecycle-provider-identity",
        )

    expected = next(
        (
            assignment
            for assignment in reversed(command.assignments)
            if assignment.name == expected_name
        ),
        None,
    )
    if expected is None:
        return error_for_token(
            "ECI_PLAN_LIFECYCLE_IDENTITY_DENIED",
            f"provider session identity missing: target_provider={target_provider} expected_name={expected_name} observed_name=<none>",
            segment_index,
            command.child_argv_index,
            command.child[0],
            remediation,
            "lifecycle-identity-missing",
        )
    if expected.value != active_session:
        observed = expected.value if expected.value else "<empty>"
        return error_for_token(
            "ECI_PLAN_LIFECYCLE_IDENTITY_DENIED",
            f"active session identity mismatch: target_provider={target_provider} expected_value={active_session} observed_value={observed}",
            segment_index,
            expected.argv_index,
            expected.token,
            remediation,
            "lifecycle-session-identity",
        )
    return None


def unwrap(argv: tuple[Token, ...], segment_index: int) -> tuple[Token, ...]:
    depth = 0
    argv_positions = {id(token): index for index, token in enumerate(argv)}

    def reject_malformed(token: Token, reason: str) -> None:
        raise error_for_token(
            "ECI_PLAN_WRAPPER_DENIED",
            reason,
            segment_index,
            argv_positions[id(token)],
            token,
            "supply the wrapper's required literal option argument and child argv",
            "malformed-transparent-wrapper",
        )

    while argv:
        name = os.path.basename(argv[0].value)
        if name not in TRANSPARENT_WRAPPERS:
            return argv
        if name == "env":
            argv = env_child(argv, segment_index)
        elif name in {"command", "nohup", "setsid"}:
            index = 1
            while index < len(argv) and argv[index].value in {"--", "-p"}:
                index += 1
            if index >= len(argv):
                reject_malformed(argv[-1], f"{name} has no remaining child argv")
            argv = argv[index:]
        elif name == "exec":
            index = 1
            while index < len(argv):
                value = argv[index].value
                if value == "--":
                    index += 1
                    break
                if value == "-a":
                    if index + 1 >= len(argv):
                        reject_malformed(argv[index], "exec -a is missing its literal argv-zero argument")
                    index += 2
                    continue
                if value in {"-c", "-l"}:
                    index += 1
                    continue
                break
            if index >= len(argv):
                reject_malformed(argv[-1], "exec has no remaining child argv")
            argv = argv[index:]
        elif name == "timeout":
            index = 1
            while index < len(argv):
                value = argv[index].value
                if value == "--":
                    index += 1
                    break
                if value in {"-k", "--kill-after", "-s", "--signal"}:
                    if index + 1 >= len(argv):
                        reject_malformed(argv[index], f"timeout option {value} is missing its argument")
                    index += 2
                    continue
                if value.startswith(("--kill-after=", "--signal=")) or value in {"--foreground", "--preserve-status", "--verbose"}:
                    index += 1
                    continue
                if value.startswith("-"):
                    return argv
                break
            if index + 1 >= len(argv):
                reject_malformed(argv[-1], "timeout requires both a duration and a child argv")
            argv = argv[index + 1:]
        elif name == "nice":
            index = 1
            if index < len(argv) and argv[index].value in {"-n", "--adjustment"}:
                if index + 1 >= len(argv):
                    reject_malformed(argv[index], f"nice option {argv[index].value} is missing its adjustment")
                index += 2
            elif index < len(argv) and argv[index].value.startswith("--adjustment="):
                index += 1
            elif index < len(argv) and re.fullmatch(r"-[0-9]+", argv[index].value):
                index += 1
            if index >= len(argv):
                reject_malformed(argv[-1], "nice has no remaining child argv")
            argv = argv[index:]
        elif name == "time":
            index = 1
            while index < len(argv):
                value = argv[index].value
                if value == "--":
                    index += 1
                    break
                if value in {"-f", "--format", "-o", "--output"}:
                    if index + 1 >= len(argv):
                        reject_malformed(argv[index], f"time option {value} is missing its argument")
                    index += 2
                    continue
                if value.startswith(("--format=", "--output=")) or value in {
                    "-a", "--append", "-p", "--portability", "-q", "--quiet",
                    "-v", "--verbose",
                }:
                    index += 1
                    continue
                if value in {"-h", "--help", "-V", "--version"}:
                    return argv
                if value.startswith("-"):
                    return argv
                break
            if index >= len(argv):
                reject_malformed(argv[-1], "time has no remaining child argv")
            argv = argv[index:]
        elif name == "prlimit":
            index = 1
            value_options = {"-p", "--pid", "-o", "--output"}
            resource_options = {
                "-c", "--core", "-d", "--data", "-e", "--nice",
                "-f", "--fsize", "-i", "--sigpending", "-l", "--memlock",
                "-m", "--rss", "-n", "--nofile", "-q", "--msgqueue",
                "-r", "--rtprio", "-s", "--stack", "-t", "--cpu",
                "-u", "--nproc", "-v", "--as", "-x", "--locks",
                "-y", "--rttime",
            }
            while index < len(argv):
                value = argv[index].value
                if value == "--":
                    index += 1
                    break
                if value in value_options:
                    if index + 1 >= len(argv):
                        reject_malformed(argv[index], f"prlimit option {value} is missing its argument")
                    index += 2
                    continue
                if value in resource_options or value.startswith(tuple(option + "=" for option in resource_options)):
                    index += 1
                    continue
                if value in {"--noheadings", "--raw", "--verbose"}:
                    index += 1
                    continue
                if value in {"-h", "--help", "-V", "--version"}:
                    return argv
                if value.startswith("-"):
                    return argv
                break
            if index >= len(argv):
                return argv
            argv = argv[index:]
        elif name == "chronic":
            index = 1
            while index < len(argv):
                value = argv[index].value
                if value == "--":
                    index += 1
                    break
                if value.startswith("-"):
                    index += 1
                    continue
                break
            if index >= len(argv):
                reject_malformed(argv[-1], "chronic has no remaining child argv")
            argv = argv[index:]
        elif name in {"sudo", "doas", "systemd-run"}:
            index = 1
            while index < len(argv) and argv[index].value.startswith("-"):
                if argv[index].value in {"-u", "--user", "--unit", "--property", "--setenv", "-p"}:
                    if index + 1 >= len(argv):
                        reject_malformed(argv[index], f"{name} option {argv[index].value} is missing its argument")
                    index += 2
                else:
                    index += 1
            if index >= len(argv):
                reject_malformed(argv[-1], f"{name} has no remaining child argv")
            argv = argv[index:]
        else:
            return argv
        depth += 1
        if depth > MAX_WRAPPER_DEPTH:
            raise error_for_token(
                "ECI_PLAN_WRAPPER_DEPTH_DENIED",
                f"transparent wrapper nesting exceeds {MAX_WRAPPER_DEPTH}",
                segment_index,
                0,
                argv[0],
                "remove redundant wrappers and invoke the finite child argv directly",
                "wrapper-depth",
            )
    return argv


def is_live_name(name: str) -> bool:
    return name in LIVE_EXACT or any(name.startswith(prefix) for prefix in LIVE_PREFIXES)


def roots_from_environment(provider: str) -> list[str]:
    prefixes = ("CODEX", "KIMI")
    roots: list[str] = []
    for prefix in prefixes:
        for suffix in ("PROOF_ROOT", "PROOF_ROOT_CANONICAL", "PROOF_ROOT_CONFIGURED", "PROOF_ROOT_STABLE_ALIAS"):
            raw = os.environ.get(f"{prefix}_{suffix}", "")
            if raw and os.path.isabs(raw) and os.path.normpath(raw) == raw and raw not in roots:
                roots.append(raw)
    return roots


def candidate_paths(value: str, cwd: str) -> tuple[str, str]:
    expanded = os.path.expanduser(value)
    lexical = expanded if os.path.isabs(expanded) else os.path.abspath(os.path.join(cwd, expanded))
    lexical = os.path.normpath(lexical)
    return lexical, os.path.realpath(lexical)


def live_state(active_markers: list[str], provider: str) -> tuple[set[str], set[tuple[int, int]], list[str]]:
    lexical: set[str] = set()
    identities: set[tuple[int, int]] = set()
    sessions: list[str] = []
    roots = roots_from_environment(provider)
    for marker in active_markers:
        session = os.path.dirname(marker)
        session_name = os.path.basename(session)
        alias_sessions = [session]
        for root in roots:
            alias = os.path.join(root, session_name)
            if alias not in alias_sessions:
                alias_sessions.append(alias)
        for alias_session in alias_sessions:
            if alias_session not in sessions:
                sessions.append(alias_session)
            for name in LIVE_EXACT:
                lexical.add(os.path.normpath(os.path.join(alias_session, name)))
        for path in tuple(lexical):
            try:
                state = os.stat(path, follow_symlinks=True)
            except OSError:
                continue
            if stat.S_ISREG(state.st_mode):
                identities.add((state.st_dev, state.st_ino))
    return lexical, identities, sessions


def path_operands(argv: tuple[Token, ...]) -> list[tuple[int, Token]]:
    if os.path.basename(argv[0].value) not in PATH_CAPABILITY_NAMES:
        return []
    result: list[tuple[int, Token]] = []
    for index, token in enumerate(argv[1:], 1):
        value = token.value
        if value == "--":
            continue
        if value.startswith("-") and "=" not in value:
            continue
        if value.startswith("-") and "=" in value:
            _, value = value.split("=", 1)
            if not value:
                continue
            token = Token(value, token.offset, token.protected[-len(value):])
        result.append((index, token))
    return result


def instruction_path_error(
    argv: tuple[Token, ...], segment_index: int, cwd: str
) -> PlanError | None:
    name = os.path.basename(argv[0].value)
    read_tools = {
        "cat", "cmp", "diff", "file", "git", "grep", "head", "ls", "rg",
        "sed", "sha256sum", "stat", "tail", "wc",
    }
    if name not in read_tools:
        return None
    provider_homes: list[tuple[str, str]] = []
    for raw in (
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        os.environ.get("CODEX_HOME", ""),
        os.environ.get("KIMI_CODE_HOME", ""),
        os.path.join(os.environ.get("HOME", ""), ".codex"),
        os.path.join(os.environ.get("HOME", ""), ".kimi-code"),
    ):
        if not raw or not os.path.isabs(raw):
            continue
        lexical = os.path.normpath(raw)
        pair = (lexical, os.path.realpath(lexical))
        if pair not in provider_homes:
            provider_homes.append(pair)
    skill_roots = [
        (os.path.join(lexical, "skills"), os.path.join(resolved, "skills"))
        for lexical, resolved in provider_homes
    ]
    lexical_cwd = os.path.normpath(os.path.abspath(cwd))
    resolved_cwd = os.path.realpath(lexical_cwd)
    for index, token in path_operands(argv):
        lexical, resolved = candidate_paths(token.value, cwd)
        basename = os.path.basename(lexical)
        matched = next(
            (
                (lexical_root, real_root)
                for lexical_root, real_root in skill_roots
                if lexical == lexical_root or lexical.startswith(lexical_root + os.sep)
            ),
            None,
        )
        looks_instruction = (
            basename in {"SKILL.md", "CODEX.md", "AGENTS.md"}
            or matched is not None
        )
        if not looks_instruction:
            continue
        if basename in {"CODEX.md", "AGENTS.md"}:
            matched = next(
                (
                    (lexical_home, real_home)
                    for lexical_home, real_home in provider_homes
                    if lexical == os.path.join(lexical_home, basename)
                ),
                None,
            )
            lexical_parent = os.path.dirname(lexical)
            if matched is None and (
                lexical_parent == lexical_cwd
                or lexical_parent.startswith(lexical_cwd + os.sep)
            ):
                matched = (lexical_cwd, resolved_cwd)
            if matched is None and lexical_cwd.startswith(lexical_parent + os.sep):
                matched = (lexical_parent, os.path.realpath(lexical_parent))
        failure = ""
        instruction_root = "<none>"
        if matched is None:
            failure = "outside-instruction-root"
        else:
            instruction_root, real_root = matched
            if not os.path.exists(lexical):
                failure = "missing-instruction-source"
            elif resolved != lexical and not (resolved == real_root or resolved.startswith(real_root + os.sep)):
                failure = "symlink-escape"
            elif not (os.path.isfile(lexical) or os.path.isdir(lexical)):
                failure = "not-regular-file"
        if failure:
            return error_for_token(
                "ECI_WORKER_INSTRUCTION_READ_DENIED",
                f"instruction source path validation failed: failure={failure} resolved={resolved} instruction_root={instruction_root}",
                segment_index,
                index,
                token,
                "use an existing canonical regular file or directory contained by an installed instruction root",
                "worker-instruction-read",
                path=resolved,
            )
    return None


def source_write_error(
    argv: tuple[Token, ...], segment_index: int, cwd: str
) -> PlanError | None:
    name = os.path.basename(argv[0].value)
    roots: list[str] = []
    for raw in (
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        os.environ.get("CODEX_HOME", ""),
        os.environ.get("KIMI_CODE_HOME", ""),
    ):
        if raw and os.path.isabs(raw):
            resolved = os.path.realpath(raw)
            if resolved not in roots:
                roots.append(resolved)
    for index, token in enumerate(argv[1:], 1):
        if token.value == "--":
            continue
        if token.value.startswith("-") and "=" not in token.value:
            continue
        if token.value.startswith("-") and "=" in token.value:
            value = token.value.split("=", 1)[1]
            if not value:
                continue
            token = Token(value, token.offset, token.protected[-len(value):])
        elif name == "dd" and token.value.startswith("of="):
            value = token.value.split("=", 1)[1]
            if not value:
                continue
            token = Token(value, token.offset, token.protected[-len(value):])
        _, resolved = candidate_paths(token.value, cwd)
        if any(resolved == root or resolved.startswith(root + os.sep) for root in roots):
            return error_for_token(
                "ECI_COORDINATOR_SOURCE_WRITE_DENIED",
                "coordinator argv names a source-tree path for a visible write operation",
                segment_index,
                index,
                token,
                "delegate the source-tree edit to the assigned implementation worker",
                "coordinator-source-write",
                path=resolved,
            )
    return None


def repository_root(cwd: str) -> str | None:
    current = os.path.realpath(cwd)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def broad_destructive_error(
    argv: tuple[Token, ...], segment_index: int, cwd: str
) -> PlanError | None:
    name = os.path.basename(argv[0].value)
    if name in BROAD_DESTRUCTIVE_NAMES:
        return error_for_token(
            "ECI_BROAD_DESTRUCTIVE_DENIED",
            f"{name} is a recognizable broad destructive operation",
            segment_index,
            0,
            argv[0],
            "replace it with a bounded task-owned file operation",
            "broad-destructive",
        )
    recursive_rm = name == "rm" and any(
        token.value in {"-r", "-R", "-rf", "-fr", "--recursive"}
        for token in argv[1:]
    )
    if not recursive_rm and name not in {"dd", "shred", "srm"}:
        return None

    protected_roots = {os.path.realpath("/"), os.path.realpath(cwd)}
    for raw in (
        os.environ.get("HOME", ""),
        os.environ.get("CODEX_HOME", ""),
        os.environ.get("KIMI_CODE_HOME", ""),
        *roots_from_environment("codex"),
    ):
        if raw and os.path.isabs(raw):
            protected_roots.add(os.path.realpath(raw))
    repo_root = repository_root(cwd)
    if repo_root is not None:
        protected_roots.add(repo_root)

    for index, token in enumerate(argv[1:], 1):
        if token.value == "--" or token.value.startswith("-"):
            continue
        value = token.value
        if name == "dd":
            if not value.startswith("of="):
                continue
            value = value.split("=", 1)[1]
            token = Token(value, token.offset, token.protected[-len(value):])
        lexical, resolved = candidate_paths(value, cwd)
        try:
            target_mode = os.stat(resolved).st_mode
        except OSError:
            target_mode = 0
        if (
            resolved in protected_roots
            or lexical in protected_roots
            or os.path.ismount(resolved)
            or stat.S_ISBLK(target_mode)
        ):
            return error_for_token(
                "ECI_BROAD_DESTRUCTIVE_DENIED",
                "recursive removal targets a filesystem, home, repository, provider, proof, or current-working root",
                segment_index,
                index,
                token,
                "narrow the target to one exact task-owned file or subdirectory",
                "broad-destructive",
                path=resolved,
            )
    return None


def inspect_segment(
    segment: Segment,
    segment_index: int,
    provider: str,
    role: str,
    active: bool,
    cwd: str,
    live_paths: set[str],
    live_ids: set[tuple[int, int]],
    proof_sessions: list[str],
    active_session: str = "",
    mode_identity: GateModeIdentity | None = None,
) -> str:
    argv = segment.argv
    original_argv = argv
    first_assignment = shell_assignment_name(argv[0])
    if first_assignment is not None:
        raise error_for_token(
            "ECI_PLAN_SYNTAX_DENIED",
            "assignments before the executable are shell context, not literal argv",
            segment_index,
            0,
            argv[0],
            "use env with a literal child argv, or remove the leading assignment",
            "leading-assignment",
        )
    if (
        argv[0].value in RESERVED_CONTROLS
        and argv[0].value != "time"
        and not any(argv[0].protected)
    ):
        raise error_for_token(
            "ECI_PLAN_SYNTAX_DENIED",
            "reserved shell control words are not literal executable argv",
            segment_index,
            0,
            argv[0],
            "invoke one direct finite executable argv",
            "reserved-shell-control",
        )
    if active:
        identity_error = lifecycle_identity_error(argv, segment_index, active_session)
        if identity_error is not None:
            raise identity_error

    argv = unwrap(argv, segment_index)
    name = os.path.basename(argv[0].value)
    mode_error = gate_mode_mutation_error(
        argv,
        original_argv,
        segment_index,
        role,
        cwd,
        mode_identity if mode_identity is not None else gate_mode_identity(),
    )
    if mode_error is not None:
        raise mode_error

    def protected_git_result(token_index: int, action: str) -> str:
        if active and role == "worker":
            raise error_for_token(
                "ECI_WORKER_GIT_OWNERSHIP_DENIED",
                f"worker argv selects acceptance-sensitive Git operation {action}",
                segment_index,
                token_index,
                argv[token_index],
                "route this exact Git mutation through the coordinator acceptance path",
                "worker-git-ownership",
            )
        return "DEFER"

    def protected_lifecycle_result(token_index: int) -> str:
        lifecycle_name = os.path.basename(argv[token_index].value)
        if active and role == "worker":
            code = (
                "ECI_WORKER_REVIEW_GATE_DENIED"
                if lifecycle_name in {"eci-review-gate", "eci-review-gate.sh"}
                else "ECI_CONTROL_OWNER_REQUIRED"
            )
            raise error_for_token(
                code,
                f"worker argv invokes coordinator-owned lifecycle target {lifecycle_name}",
                segment_index,
                token_index,
                argv[token_index],
                "route this exact lifecycle operation through the coordinator",
                "worker-lifecycle-control",
            )
        return "DEFER"

    if name == "printenv":
        names = argv[1:]
        if not names:
            raise error_for_token(
                "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                "printenv has no queried names and would enumerate inherited environment state",
                segment_index,
                0,
                argv[0],
                "query one to sixteen registered environment names explicitly",
                "environment-enumeration",
            )
        seen: set[str] = set()
        if len(names) > 16:
            raise error_for_token(
                "ECI_ENVIRONMENT_NAME_DENIED",
                "printenv query exceeds sixteen unique registered names",
                segment_index,
                16,
                names[16],
                "query at most sixteen unique registered names",
                "environment-name-limit",
            )
        for index, token in enumerate(names, 1):
            if token.value.startswith("-"):
                raise error_for_token(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    f"printenv option {token.value} is unsupported",
                    segment_index,
                    index,
                    token,
                    "remove options and query registered names directly",
                    "environment-unsupported-option",
                )
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token.value):
                raise error_for_token(
                    "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                    f"printenv query token {token.value} is not an identifier",
                    segment_index,
                    index,
                    token,
                    "query one literal registered environment identifier",
                    "environment-invalid-name",
                )
            if token.value in seen:
                raise error_for_token(
                    "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                    f"printenv query name {token.value} is duplicated",
                    segment_index,
                    index,
                    token,
                    "query each registered environment name at most once",
                    "environment-duplicate-name",
                )
            if token.value not in PUBLIC_ENV_NAMES:
                raise error_for_token(
                    "ECI_ENVIRONMENT_NAME_DENIED",
                    f"printenv query name at argv index {index} has status=unregistered",
                    segment_index,
                    index,
                    token,
                    "query only unique names from the provider-parity public environment registry",
                    "environment-name-unregistered",
                )
            seen.add(token.value)

    if name in {"bash", "dash", "sh", "zsh", "python", "python2", "python3", "perl", "ruby", "node", "php"}:
        for index, token in enumerate(argv[1:], 1):
            node_eval = name == "node" and (
                token.value in {"-e", "--eval"}
                or token.value.startswith(("-e=", "--eval="))
            )
            if (
                token.value in {"-c", "-s", "-", "--stdin"}
                or (name != "python" and token.value.startswith("-c"))
                or node_eval
            ):
                raise error_for_token(
                    "ECI_PLAN_DYNAMIC_LAUNCH_DENIED",
                    "inline or stdin interpreter code hides the executed argv",
                    segment_index,
                    index,
                    token,
                    "invoke a literal script path or direct executable argv",
                    "dynamic-interpreter-launch",
                )
        if name in {"bash", "dash", "sh", "zsh"}:
            script_index = 1
            while script_index < len(argv):
                value = argv[script_index].value
                if value in {"-O", "+O", "--rcfile"}:
                    if script_index + 1 >= len(argv):
                        raise error_for_token(
                            "ECI_PLAN_WRAPPER_DENIED",
                            f"shell option {value} is missing its required literal argument",
                            segment_index,
                            script_index,
                            argv[script_index],
                            "supply the option argument followed by a literal script path",
                            "malformed-transparent-wrapper",
                        )
                    script_index += 2
                    continue
                if value == "--":
                    script_index += 1
                    break
                if value.startswith("-"):
                    script_index += 1
                    continue
                break
            if (
                script_index < len(argv)
                and canonical_lifecycle_name(argv[script_index], cwd) is not None
            ):
                return protected_lifecycle_result(script_index)
    if name in {"alias", "enable", "eval", "export", "hash", "set", "source", ".", "unset", "xargs"}:
        raise error_for_token(
            "ECI_PLAN_DYNAMIC_LAUNCH_DENIED",
            f"{name} constructs or loads executable argv dynamically",
            segment_index,
            0,
            argv[0],
            "invoke the resulting finite literal argv directly",
            "dynamic-launch",
        )
    if name == "find" and any(token.value in {"-exec", "-execdir", "-ok", "-okdir", "-delete"} for token in argv[1:]):
        token_index = next(index for index, token in enumerate(argv) if token.value in {"-exec", "-execdir", "-ok", "-okdir", "-delete"})
        raise error_for_token(
            "ECI_PLAN_DYNAMIC_LAUNCH_DENIED",
            "find action constructs nested execution or deletes discovered paths",
            segment_index,
            token_index,
            argv[token_index],
            "separate discovery from one finite literal action",
            "dynamic-find-action",
        )

    if name == "git":
        for index, token in enumerate(argv[1:], 1):
            if token.value in {"-c", "--config-env", "--git-dir", "--work-tree", "--exec-path", "--namespace", "--super-prefix", "--textconv", "--ext-diff"} or token.value.startswith(("--config-env=", "--git-dir=", "--work-tree=", "--exec-path=", "--namespace=", "--super-prefix=")):
                raise error_for_token(
                    "ECI_GIT_DYNAMIC_EXECUTION_DENIED",
                    "Git execution or repository context is overridden by a visible option",
                    segment_index,
                    index,
                    token,
                    "remove the reported Git context option and use repository-default inspection",
                    "git-execution-context",
                )
        index = 1
        while index < len(argv):
            value = argv[index].value
            if value == "-C" and index + 1 < len(argv):
                index += 2
                continue
            if value in {"--literal-pathspecs", "--no-optional-locks", "--no-pager"}:
                index += 1
                continue
            if value.startswith("-"):
                index += 1
                continue
            break
        subcommand = argv[index].value if index < len(argv) else ""
        mutators = {
            "add", "am", "apply", "cherry-pick", "commit", "config", "gc",
            "merge", "mv", "push", "rebase", "rename", "replace", "reset", "restore",
            "revert", "rm", "tag", "update-index", "worktree",
        }
        tail = [token.value for token in argv[index + 1:]]
        if subcommand == "submodule" and tail[:1] != ["status"]:
            return protected_git_result(index, subcommand)
        if subcommand == "remote" and tail and tail[0] in {
            "add", "prune", "remove", "rename", "set-head", "set-url", "update",
        }:
            return protected_git_result(index + 1, f"remote {tail[0]}")
        if subcommand == "branch":
            branch_mutators = {
                "-c", "-C", "-d", "-D", "-m", "-M", "--copy", "--delete",
                "--edit-description", "--move", "--set-upstream-to", "--unset-upstream",
            }
            value_options = {
                "--contains", "--format", "--merged", "--no-contains", "--no-merged",
                "--points-at", "--sort",
            }
            skip = False
            for value in tail:
                if skip:
                    skip = False
                    continue
                if value in branch_mutators or any(value.startswith(option + "=") for option in branch_mutators if option.startswith("--")):
                    return protected_git_result(index + 1 + tail.index(value), f"branch {value}")
                if value in value_options:
                    skip = True
                    continue
                if not value.startswith("-"):
                    return protected_git_result(index + 1 + tail.index(value), "branch update")
        if subcommand in mutators:
            return protected_git_result(index, subcommand)

    if active:
        for index, token in path_operands(argv):
            lexical, resolved = candidate_paths(token.value, cwd)
            containing_sessions = [
                proof_session
                for proof_session in proof_sessions
                if lexical == proof_session or lexical.startswith(proof_session + os.sep)
            ]
            resolved_sessions = [os.path.realpath(proof_session) for proof_session in proof_sessions]
            if containing_sessions and not any(
                resolved == proof_session or resolved.startswith(proof_session + os.sep)
                for proof_session in resolved_sessions
            ):
                raise error_for_token(
                    "ECI_PROOF_PATH_ESCAPE_DENIED",
                    f"proof path resolves outside its active session aliases: resolved={resolved} proof_root={containing_sessions[0]}",
                    segment_index,
                    index,
                    token,
                    "replace the escaping symlink with a canonical path contained by the active proof session",
                    "proof-symlink-escape",
                    path=lexical,
                )

    if active and role == "worker":
        instruction_error = instruction_path_error(argv, segment_index, cwd)
        if instruction_error is not None:
            raise instruction_error
        for index, token in path_operands(argv):
            lexical, resolved = candidate_paths(token.value, cwd)
            matched_path = ""
            if lexical in live_paths:
                matched_path = lexical
            elif resolved in live_paths:
                matched_path = resolved
            elif any(
                (lexical.startswith(session + os.sep) or lexical == session)
                and is_live_name(os.path.basename(lexical))
                for session in proof_sessions
            ):
                matched_path = lexical
            elif any(
                (resolved.startswith(session + os.sep) or resolved == session)
                and is_live_name(os.path.basename(resolved))
                for session in proof_sessions
            ):
                matched_path = resolved
            else:
                try:
                    state = os.stat(lexical, follow_symlinks=True)
                except OSError:
                    state = None
                if state is not None and (state.st_dev, state.st_ino) in live_ids:
                    matched_path = resolved
            if matched_path:
                raise error_for_token(
                    "ECI_PLAN_LIVE_CONTROL_DENIED",
                    "worker argv resolves to an exact active-session live-control artifact",
                    segment_index,
                    index,
                    token,
                    "route this exact live-control operation through the coordinator",
                    "worker-live-control",
                    path=matched_path,
                )

    if canonical_lifecycle_name(argv[0], cwd) is not None:
        return protected_lifecycle_result(0)
    destructive_error = broad_destructive_error(argv, segment_index, cwd)
    if destructive_error is not None:
        raise destructive_error
    coordinator_writer = name in SOURCE_WRITERS or (
        name == "sed" and any(
            token.value in {"-i", "--in-place"} or token.value.startswith(("-i", "--in-place="))
            for token in argv[1:]
        )
    )
    if active and role == "coordinator" and coordinator_writer:
        source_error = source_write_error(argv, segment_index, cwd)
        if source_error is not None:
            raise source_error
    return "ADMIT"


def denied_json(
    error: PlanError,
    provider: str,
    role: str,
    active: bool,
    command: str,
    segment: Segment | None = None,
) -> str:
    marker = "active" if active else "inactive"
    if error.code.startswith("ECI_PLAN_"):
        operation = "plan-segment"
    elif error.code.startswith("ECI_ENVIRONMENT_"):
        operation = "environment-boundary"
    elif error.code == "ECI_WORKER_GIT_OWNERSHIP_DENIED":
        operation = "worker-git-ownership"
    elif error.code.startswith("ECI_GIT_"):
        operation = "git-execution-context"
    elif error.code == "ECI_BROAD_DESTRUCTIVE_DENIED":
        operation = "broad-destructive"
    elif error.code == "ECI_CONTROL_OWNER_REQUIRED":
        operation = "worker-control"
    elif error.code == "ECI_CONTROL_IDENTITY_DENIED":
        operation = "worker-control"
    elif error.code == "ECI_WORKER_REVIEW_GATE_DENIED":
        operation = "worker-review-gate"
    elif error.code == "ECI_WORKER_INSTRUCTION_READ_DENIED":
        operation = "worker-instruction-read"
    elif error.code == "ECI_PROOF_PATH_ESCAPE_DENIED":
        operation = "proof-path-ownership"
    elif error.code == "ECI_COORDINATOR_SOURCE_WRITE_DENIED":
        operation = "coordinator-source-write"
    else:
        operation = "plan-segment"
    subject = (
        f"phase=PreToolUse, operation={operation}, provider={provider}, role={role}, "
        f"marker={marker}, segment={error.segment}, argv_index={error.argv_index}, "
        f"byte_offset={error.offset}, token={shell_escape(error.token)}, "
        f"path={shell_escape(error.path)}, predicate={error.predicate}"
    )
    if error.code == "ECI_ENVIRONMENT_CONTEXT_DENIED":
        rejected = "<environment-context command; assignment value omitted>"
    elif segment is None:
        rejected = shell_escape(command)
    else:
        rejected = " ".join(shell_escape(token.value) for token in segment.argv)
    reason = (
        f"[{error.code}] ECI gate denied ({subject}); reason: {error.reason}; "
        f"rejected segment={rejected}; remediation: {error.remediation}."
    )
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        separators=(",", ":"),
    )


def main() -> int:
    if len(sys.argv) < 7:
        return 64
    provider, role, cwd, active_word, active_session, command, *active_markers = sys.argv[1:]
    active = active_word == "active"
    if active and (
        not active_session
        or len(active_session.encode("utf-8", "strict")) > MAX_ARG_BYTES
        or any(ord(character) < 32 or ord(character) == 127 for character in active_session)
    ):
        return 64
    try:
        plan = parse(command)
    except PlanError as error:
        if not active and error.code.startswith("ECI_PLAN_"):
            return 0
        print(denied_json(error, provider, role, active, command))
        return 2
    try:
        live_paths, live_ids, proof_sessions = live_state(active_markers, provider) if active else (set(), set(), [])
        mode_identity = gate_mode_identity()
        outcomes = [
            inspect_segment(
                segment,
                index,
                provider,
                role,
                active,
                cwd,
                live_paths,
                live_ids,
                proof_sessions,
                active_session,
                mode_identity,
            )
            for index, segment in enumerate(plan.segments, 1)
        ]
    except PlanError as error:
        if (
            not active
            and not error.code.startswith(("ECI_ENVIRONMENT_", "ECI_GIT_"))
            and error.predicate not in {"gate-mode-mutation", "gate-mode-identity"}
        ):
            return 0
        segment = (
            plan.segments[error.segment - 1]
            if 1 <= error.segment <= len(plan.segments)
            else None
        )
        print(denied_json(error, provider, role, active, command, segment))
        return 2
    if "DEFER" in outcomes:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
