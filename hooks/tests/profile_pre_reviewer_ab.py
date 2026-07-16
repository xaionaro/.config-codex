#!/usr/bin/env python3
"""Alternating exact parent/candidate profiles on generated absolute state."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
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
    "lock_held_prune_records_max=170 backend_timeout_max_seconds=58 "
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


def load_runtime_manifest(root: Path) -> dict[str, object]:
    path = root / RUNTIME_MANIFEST_RELATIVE_PATH
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 2:
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


def run_hook(
    command: str,
    input_bytes: bytes,
    environment: dict[str, str],
    code_root: Path,
    *,
    timeout: float,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        shlex.split(command),
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        cwd=code_root,
        env=environment,
        timeout=timeout,
    )


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
    result = subprocess.run(
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
        input=input_bytes,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=code_root,
        env=environment,
        timeout=15.0,
    )
    if result.returncode != 0:
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
        observed_harness - declared_harness - resolved_harness
    )
    if missing_product or missing_harness:
        raise ProfileError(
            "runtime tool closure mismatch "
            f"product={missing_product} harness={missing_harness}"
        )


def discover_observed_runtime_tools(trace_root: Path, code_root: Path) -> set[str]:
    observed: set[str] = set()
    for trace in trace_root.glob("*.strace"):
        for executed in re.findall(r'execve\("([^"\\]+)".*\) += 0', trace.read_text()):
            path = Path(executed).resolve()
            if path.is_relative_to(code_root):
                continue
            observed.add(path.name)
    return observed


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
    entries: list[dict[str, str]] = []
    for name in tool_names:
        resolved = shutil.which(name)
        if resolved is None:
            raise ProfileError(f"runtime tool is unavailable: {name}")
        path = Path(resolved).resolve()
        if "/.elan/bin/" in resolved and shutil.which("elan") is not None:
            actual = subprocess.run(
                ["elan", "which", name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                text=True,
            )
            if actual.returncode != 0:
                raise ProfileError(f"cannot resolve toolchain executable: {name}")
            path = Path(actual.stdout.strip()).resolve()
        version = subprocess.run(
            [str(path), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        ).stdout.splitlines()[:1]
        entries.append(
            {
                "name": name,
                "path": str(path),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "version_sha256": hashlib.sha256(b"\n".join(version)).hexdigest(),
            }
        )
    return entries


def runtime_evidence_manifest(
    parent_root: Path,
    candidate_root: Path,
) -> dict[str, object]:
    definition = load_runtime_manifest(candidate_root)
    harness_paths = tuple(Path(value) for value in definition["harness_sources"])
    return {
        "schema_version": 2,
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
        "harness_tools": _tool_entries(list(definition["harness_tools"])),
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
            process = subprocess.Popen(
                [sys.executable, "-c", wrapper, str(barrier_read), *argv],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd=code_root,
                env=environment,
                pass_fds=(barrier_read,),
            )
            assert process.stdin is not None
            process.stdin.write(tool)
            process.stdin.close()
            processes.append(process)
        os.close(barrier_read)
        started = time.monotonic_ns()
        os.write(barrier_write, b"12")
        os.close(barrier_write)
        statuses = [process.wait(timeout=15.0) for process in processes]
    finally:
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
    candidate_commit: str,
) -> None:
    if not Path(__file__).resolve().is_relative_to(candidate_snapshot):
        raise ProfileError("profiler is not executing from the exported snapshot")
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
    evidence_before = runtime_evidence_manifest(parent_root, candidate_snapshot)
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
    verify_tool_manifest_closure(
        definition,
        observed_product=observed_product,
        observed_harness={
            "bash", "git", "python3", "sha256sum", "strace", "tar",
        },
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
    evidence_after = runtime_evidence_manifest(parent_root, candidate_snapshot)
    if evidence_after != evidence_before:
        raise ProfileError("runtime identity changed during measurement")
    print(
        "runtime-manifest-after "
        + json.dumps(evidence_after, sort_keys=True, separators=(",", ":"))
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        raise SystemExit("usage: profile_pre_reviewer_ab.py REPO")
    candidate_root = Path(argv[1]).resolve()
    if os.environ.get("CODEX_PROFILE_EXPORTED") != "1":
        scratch = Path(tempfile.mkdtemp(prefix="pre-reviewer-ab-"))
        candidate_snapshot = scratch / "candidate"
        try:
            identity = export_candidate(candidate_root, candidate_snapshot)
            environment = os.environ.copy()
            environment.update(
                {
                    "CODEX_PROFILE_EXPORTED": "1",
                    "CODEX_PROFILE_REPOSITORY": str(candidate_root),
                    "CODEX_PROFILE_SCRATCH": str(scratch),
                    "CODEX_PROFILE_COMMIT": identity.commit,
                }
            )
            launcher = candidate_snapshot / "hooks/tests/profile-pre-reviewer.sh"
            os.execve(launcher, [str(launcher)], environment)
        except BaseException:
            shutil.rmtree(scratch, ignore_errors=True)
            raise
    scratch = Path(os.environ["CODEX_PROFILE_SCRATCH"])
    repository = Path(os.environ["CODEX_PROFILE_REPOSITORY"])
    try:
        _run_profile(
            repository,
            candidate_root,
            scratch,
            os.environ["CODEX_PROFILE_COMMIT"],
        )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(CAUSAL_SCOPE_RECORD)
    print(
        "Two rows per matching Bash invocation are expected; displayed rows alone "
        "do not prove that all corresponding processes remain active."
    )
    print(
        "Generated A/B timings cover named generated scenarios and historical "
        "anchors only; backend evidence is one bounded generated observation, "
        "not live causation or a universal speedup claim."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
