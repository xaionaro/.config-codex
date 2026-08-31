#!/usr/bin/env python3
"""Focused unit tests for the finite ECI command-plan parser."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import ModuleType


MODULE_PATH = Path(__file__).resolve().parents[1] / "lib" / "eci-command-plan.py"


def load_module() -> ModuleType:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("eci_command_plan", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    module = load_module()

    plan = module.parse('printf ""')
    assert tuple(token.value for token in plan.segments[0].argv) == ("printf", "")

    unicode_plan = module.parse("printf café && env")
    assert unicode_plan.segments[1].argv[0].offset == len("printf café && ".encode())

    for command in ("'time' --version", r"FOO\=bar", "printf foo#bar", "printf ''~"):
        outcome = module.inspect_segment(
            module.parse(command).segments[0],
            1,
            "codex",
            "worker",
            True,
            "/tmp",
            set(),
            set(),
            [],
        )
        assert outcome == "ADMIT"

    inactive_git_outcome = module.inspect_segment(
        module.parse("git commit -m inactive").segments[0],
        1,
        "codex",
        "worker",
        False,
        "/tmp",
        set(),
        set(),
        [],
    )
    assert inactive_git_outcome == "DEFER"

    worker_archive_outcome = module.inspect_segment(
        module.parse("git archive HEAD").segments[0],
        1,
        "codex",
        "worker",
        True,
        "/tmp",
        set(),
        set(),
        [],
    )
    assert worker_archive_outcome == "DEFER"

    for git_mutation in (
        "git commit -m nope",
        "git reset --hard HEAD",
        "git worktree add /tmp/eci-worker-tree HEAD",
        "git branch feature",
        "git remote set-url origin https://example.invalid/repo.git",
    ):
        try:
            module.inspect_segment(
                module.parse(git_mutation).segments[0],
                1,
                "codex",
                "worker",
                True,
                "/tmp",
                set(),
                set(),
                [],
            )
        except module.PlanError as error:
            assert error.code == "ECI_WORKER_GIT_OWNERSHIP_DENIED"
        else:
            raise AssertionError(f"worker Git mutation was admitted: {git_mutation}")

    middle_plan = module.parse("printf before && env && printf after")
    middle_outcome = module.inspect_segment(
        middle_plan.segments[1],
        2,
        "codex",
        "worker",
        True,
        "/tmp",
        set(),
        set(),
        [],
    )
    assert middle_outcome == "ADMIT"

    for wrapper in (
        "chronic",
        "nice",
        "prlimit --cpu=1",
        "time",
        "timeout 5",
    ):
        ordinary_outcome = module.inspect_segment(
            module.parse(f"{wrapper} /tmp/eci-escape.sh").segments[0],
            1,
            "codex",
            "worker",
            True,
            "/tmp",
            set(),
            set(),
            [],
        )
        assert ordinary_outcome == "ADMIT"
        try:
            module.inspect_segment(
                module.parse(f"{wrapper} git commit -m nope").segments[0],
                1,
                "codex",
                "worker",
                True,
                "/tmp",
                set(),
                set(),
                [],
            )
        except module.PlanError as error:
            assert error.code == "ECI_WORKER_GIT_OWNERSHIP_DENIED"
        else:
            raise AssertionError(f"wrapped worker Git mutation was admitted: {wrapper}")

    for command, code in (
        ("git commit -m nope", "ECI_WORKER_GIT_OWNERSHIP_DENIED"),
        ("rm -rf /", "ECI_BROAD_DESTRUCTIVE_DENIED"),
    ):
        try:
            module.inspect_segment(
                module.parse(command).segments[0],
                1,
                "codex",
                "worker",
                True,
                "/tmp",
                set(),
                set(),
                [],
            )
        except module.PlanError as error:
            assert error.code == code
        else:
            raise AssertionError(f"protected worker capability was admitted: {command}")

    brace_outcome = module.inspect_segment(
        module.parse("printf }").segments[0],
        1,
        "codex",
        "worker",
        True,
        "/tmp",
        set(),
        set(),
        [],
    )
    assert brace_outcome == "ADMIT"

    for command in (
        "bash -O",
        "bash --rcfile",
        "command",
        "exec -a",
        "nice -n 5",
        "sudo -u",
        "timeout 1s",
    ):
        outcome = module.inspect_segment(
            module.parse(command).segments[0],
            1,
            "codex",
            "worker",
            True,
            "/tmp",
            set(),
            set(),
            [],
        )
        assert outcome == "ADMIT", command

    with tempfile.TemporaryDirectory() as temporary_root:
        root = Path(temporary_root)
        codex_home = root / "codex"
        kimi_home = root / "kimi"
        codex_mode = codex_home / "bin" / "eci-command-gate-mode"
        kimi_mode = kimi_home / "bin" / "eci-command-gate-mode"
        codex_mode.parent.mkdir(parents=True)
        kimi_mode.parent.mkdir(parents=True)
        codex_mode.write_text("#!/usr/bin/env python3\nprint('mode')\n", encoding="utf-8")
        codex_mode.chmod(0o755)
        os.link(codex_mode, kimi_mode)
        aliases = root / "aliases"
        aliases.mkdir()
        hardlink_alias = aliases / "mode-hardlink"
        os.link(codex_mode, hardlink_alias)
        symlink_alias = aliases / "mode-symlink"
        symlink_alias.symlink_to(codex_mode)
        byte_copy = aliases / "mode-copy"
        shutil.copyfile(codex_mode, byte_copy)
        byte_copy.chmod(0o755)
        altered_copy = aliases / "eci-command-gate-mode"
        altered_copy.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        altered_copy.chmod(0o755)
        previous = {
            name: module.os.environ.get(name)
            for name in ("CODEX_HOME", "KIMI_CODE_HOME", "PATH")
        }
        module.os.environ.update(
            {
                "CODEX_HOME": str(codex_home),
                "KIMI_CODE_HOME": str(kimi_home),
                "PATH": f"{codex_mode.parent}:{previous['PATH'] or ''}",
            }
        )
        try:
            mutation_commands = (
                f"{codex_mode} set",
                f"{kimi_mode} set permissive",
                "eci-command-gate-mode set enforcing",
                f"env FOO=bar {codex_mode} set invalid extra",
                f"env -- FOO=bar {kimi_mode} set",
                f"timeout 1 {codex_mode} set enforcing",
                f"python3 {codex_mode} set permissive",
                f"{hardlink_alias} set enforcing",
                f"{symlink_alias} set enforcing",
                f"{byte_copy} set enforcing",
                f"python {byte_copy} set enforcing",
            )
            for active in (False, True):
                for command in mutation_commands:
                    try:
                        module.inspect_segment(
                            module.parse(command).segments[0],
                            1,
                            "codex",
                            "worker",
                            active,
                            temporary_root,
                            set(),
                            set(),
                            [],
                        )
                    except module.PlanError as error:
                        assert error.code == "ECI_CONTROL_OWNER_REQUIRED"
                        assert error.predicate == "gate-mode-mutation"
                        diagnostic = module.denied_json(
                            error,
                            "codex",
                            "worker",
                            active,
                            command,
                            module.parse(command).segments[0],
                        )
                        assert "operation=worker-control" in diagnostic
                        assert (
                            "worker argv selects coordinator-owned command-gate mode mutation"
                            in diagnostic
                        )
                    else:
                        raise AssertionError(
                            f"worker mode mutation was admitted: active={active} command={command}"
                        )

            for active in (False, True):
                for command in (
                    f"{codex_mode} get",
                    f"{kimi_mode} get",
                    f"{codex_mode} finalize codex worker active parser",
                    f"{codex_mode} invalid",
                ):
                    outcome = module.inspect_segment(
                        module.parse(command).segments[0],
                        1,
                        "codex",
                        "worker",
                        active,
                        temporary_root,
                        set(),
                        set(),
                        [],
                    )
                    assert outcome == "ADMIT"
                coordinator_outcome = module.inspect_segment(
                    module.parse(f"{codex_mode} set enforcing").segments[0],
                    1,
                    "codex",
                    "coordinator",
                    active,
                    temporary_root,
                    set(),
                    set(),
                    [],
                )
                assert coordinator_outcome == "ADMIT"

            try:
                module.inspect_segment(
                    module.parse(f"{altered_copy} set enforcing").segments[0],
                    1,
                    "codex",
                    "worker",
                    True,
                    temporary_root,
                    set(),
                    set(),
                    [],
                )
            except module.PlanError as error:
                assert error.code == "ECI_CONTROL_IDENTITY_DENIED"
                assert error.predicate == "gate-mode-identity"
            else:
                raise AssertionError("altered reserved control copy was admitted")

            kimi_mode.unlink()
            shutil.copyfile(codex_mode, kimi_mode)
            kimi_mode.chmod(0o755)
            try:
                module.inspect_segment(
                    module.parse(f"{codex_mode} set enforcing").segments[0],
                    1,
                    "codex",
                    "worker",
                    True,
                    temporary_root,
                    set(),
                    set(),
                    [],
                )
            except module.PlanError as error:
                assert error.code == "ECI_CONTROL_IDENTITY_DENIED"
                assert error.predicate == "gate-mode-identity"
            else:
                raise AssertionError("split canonical control links were admitted")
        finally:
            for name, value in previous.items():
                if value is None:
                    module.os.environ.pop(name, None)
                else:
                    module.os.environ[name] = value

    with tempfile.TemporaryDirectory() as temporary_root:
        project_root = Path(temporary_root) / "project"
        project_root.mkdir()
        outside_agents = Path(temporary_root) / "outside" / "AGENTS.md"
        outside_agents.parent.mkdir()
        outside_agents.write_text("outside\n", encoding="utf-8")
        try:
            module.inspect_segment(
                module.parse(f"cat {outside_agents}").segments[0],
                1,
                "codex",
                "worker",
                True,
                str(project_root),
                set(),
                set(),
                [],
            )
        except module.PlanError as error:
            assert error.code == "ECI_WORKER_INSTRUCTION_READ_DENIED"
            assert error.predicate == "worker-instruction-read"
        else:
            raise AssertionError("outside AGENTS.md was admitted as an instruction source")

        provider_home = Path(temporary_root) / "provider"
        skill_root = provider_home / "skills" / "example"
        skill_root.mkdir(parents=True)
        skill_target = skill_root / "reference.md"
        skill_target.write_text("reference\n", encoding="utf-8")
        skill_alias = skill_root / "alias.md"
        skill_alias.symlink_to(skill_target)
        previous_codex_home = module.os.environ.get("CODEX_HOME")
        module.os.environ["CODEX_HOME"] = str(provider_home)
        try:
            outcome = module.inspect_segment(
                module.parse(f"cat {skill_alias}").segments[0],
                1,
                "codex",
                "worker",
                True,
                str(project_root),
                set(),
                set(),
                [],
            )
        finally:
            if previous_codex_home is None:
                del module.os.environ["CODEX_HOME"]
            else:
                module.os.environ["CODEX_HOME"] = previous_codex_home
        assert outcome == "ADMIT"

        session = Path(temporary_root) / "session"
        session.mkdir()
        marker = session / "eci_active"
        marker.write_text("active\n", encoding="utf-8")
        goal_state = session / "goal_state"
        goal_state.write_text("pending\n", encoding="utf-8")
        live_hardlink = Path(temporary_root) / "live-hardlink"
        os.link(goal_state, live_hardlink)
        evidence = session / "result.md"
        evidence.write_text("result\n", encoding="utf-8")
        evidence_hardlink = Path(temporary_root) / "evidence-hardlink"
        os.link(evidence, evidence_hardlink)
        prefixed_control = session / "eci-acceptance-transaction.test"
        prefixed_control.write_text("pending\n", encoding="utf-8")
        original_scandir = module.os.scandir

        def fail_scandir(path: os.PathLike[str] | str):
            raise AssertionError(f"live-state discovery enumerated {path}")

        module.os.scandir = fail_scandir
        try:
            live_paths, live_ids, sessions = module.live_state(
                [os.path.realpath(marker)], "codex"
            )
        finally:
            module.os.scandir = original_scandir

        assert os.path.realpath(goal_state) in live_paths
        assert (goal_state.stat().st_dev, goal_state.stat().st_ino) in live_ids
        assert (evidence.stat().st_dev, evidence.stat().st_ino) not in live_ids

        for command in (
            "cat live-hardlink",
            f"cat {live_hardlink}",
            f"cat {prefixed_control}",
        ):
            try:
                module.inspect_segment(
                    module.parse(command).segments[0],
                    1,
                    "codex",
                    "worker",
                    True,
                    temporary_root,
                    live_paths,
                    live_ids,
                    sessions,
                )
            except module.PlanError as error:
                assert error.code == "ECI_PLAN_LIVE_CONTROL_DENIED"
                diagnostic = module.denied_json(
                    error,
                    "codex",
                    "worker",
                    True,
                    command,
                    module.parse(command).segments[0],
                )
                assert "operation=plan-segment" in diagnostic
            else:
                raise AssertionError(f"live-control alias was admitted: {command}")

        outcome = module.inspect_segment(
            module.parse(f"cat {evidence_hardlink}").segments[0],
            1,
            "codex",
            "worker",
            True,
            temporary_root,
            live_paths,
            live_ids,
            sessions,
        )
        assert outcome == "ADMIT"

        naming_outcome = module.inspect_segment(
            module.parse(f"printf {goal_state}").segments[0],
            1,
            "codex",
            "worker",
            True,
            temporary_root,
            live_paths,
            live_ids,
            sessions,
        )
        assert naming_outcome == "ADMIT"

        canonical_proof_root = Path(temporary_root) / "canonical-proof"
        canonical_session = canonical_proof_root / "alias-session"
        canonical_session.mkdir(parents=True)
        alias_proof_root = Path(temporary_root) / "proof-alias"
        alias_proof_root.symlink_to(canonical_proof_root, target_is_directory=True)
        alias_session = alias_proof_root / canonical_session.name
        alias_marker = alias_session / "eci_active"
        alias_marker.write_text("active\n", encoding="utf-8")
        alias_goal_state = alias_session / "goal_state"
        alias_goal_state.write_text("pending\n", encoding="utf-8")
        alias_escape = alias_session / "goal_state-escape"
        alias_escape.symlink_to(evidence)
        alias_live_paths, alias_live_ids, alias_sessions = module.live_state(
            [str(alias_marker)], "codex"
        )
        try:
            module.inspect_segment(
                module.parse(f"cat {alias_goal_state}").segments[0],
                1,
                "codex",
                "worker",
                True,
                temporary_root,
                alias_live_paths,
                alias_live_ids,
                alias_sessions,
            )
        except module.PlanError as error:
            assert error.code == "ECI_PLAN_LIVE_CONTROL_DENIED"
        else:
            raise AssertionError("live control through a canonical proof-root alias was admitted")
        escape_read = module.inspect_segment(
            module.parse(f"cat {alias_escape}").segments[0],
            1,
            "codex",
            "worker",
            True,
            temporary_root,
            alias_live_paths,
            alias_live_ids,
            alias_sessions,
        )
        assert escape_read == "ADMIT"
        try:
            module.inspect_segment(
                module.parse(f"touch {alias_escape}").segments[0],
                1,
                "codex",
                "worker",
                True,
                temporary_root,
                alias_live_paths,
                alias_live_ids,
                alias_sessions,
            )
        except module.PlanError as error:
            assert error.code == "ECI_PROOF_PATH_ESCAPE_DENIED"
        else:
            raise AssertionError("escaping proof write was admitted")

    print("ECI command-plan parser tests passed")


if __name__ == "__main__":
    main()
