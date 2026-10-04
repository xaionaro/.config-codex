#!/usr/bin/env python3
"""Focused checks for the embedded inspection query transport and output merge."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def load_functions() -> dict[str, object]:
    """Load the shipped query and output decision without executing the Bash hook."""
    source = Path(__file__).resolve().parents[1].joinpath("validate-bash.sh").read_text()
    start = source.index("def inspection_argument_roles(")
    end = source.index("\ndef segment_spec(", start)
    namespace = {"os": os, "json": json, "subprocess": subprocess, "re": re}
    exec(source[start:end], namespace)
    start = source.index('        roles = inspection_argument_roles([*git_options, *tokens[index:]])')
    end = source.index('        if (roles is not None and roles["eligible"]', start)
    decision = source[start:end]
    exec("def output_decision(roles, verb, arguments):\n" +
         "    tokens, index, repo_dir = [verb, *arguments], 0, 'repo'\n" +
         "    git_options = []\n" +
         decision.replace('        ', '    ').replace(
             '    roles = inspection_argument_roles([*git_options, *tokens[index:]])\n', '') +
         "    return 'inspection', repo_dir\n", namespace)
    return namespace


def assert_reaped(pid_file: Path) -> None:
    """Assert that the owned query process no longer has a live process identity."""
    pid = int(pid_file.read_text())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError(f"query process {pid} was not reaped")


def main() -> None:
    """Exercise transport failure boundaries and positive output fact merging."""
    namespace = load_functions()
    query = namespace["inspection_argument_roles"]
    decision = namespace["output_decision"]
    valid = json.dumps(dict(query="argument-roles", output=False, complete=True, eligible=True)).encode()
    previous_home = os.environ.get("CODEX_CONFIGURED_HOME")
    try:
        with tempfile.TemporaryDirectory(prefix="inspection-transport-") as root:
            os.environ["CODEX_CONFIGURED_HOME"] = root
            binary = Path(root, "bin/eci-git-inspection")
            binary.parent.mkdir()
            pid_file = Path(root, "pid")

            def install(body: str) -> None:
                """Install one finite owned query behavior and record its process identity."""
                binary.write_text("#!/usr/bin/python3\nimport os,sys,time\n" +
                                  f"open({str(pid_file)!r},'w').write(str(os.getpid()))\n" + body)
                binary.chmod(0o755)

            install("sys.exit(0)\n")
            assert query(["diff", "x" * (4 * 1024 * 1024 + 1)]) is None
            assert not pid_file.exists(), "oversized request launched a process"
            assert query(["diff", "\0" * 1000000]) is None
            assert not pid_file.exists(), "oversized encoded request launched a process"
            print("request cap PASS")

            for name, payload, expected in (
                ("valid", valid, True),
                ("boundary", valid + b" " * (8192 - len(valid)), True),
                ("overflow", b"x" * 8193, False),
                ("invalid encoding", b"\xff", False),
                ("malformed JSON", b"{", False),
            ):
                install(f"sys.stdin.buffer.read()\nos.write(1,{payload!r})\n")
                result = query(["diff"])
                assert (result is not None) is expected, (name, result)
                assert_reaped(pid_file)
                print(name, "PASS")

            for name, body, arguments, timeout in (
                ("stream overflow", 'sys.stdin.buffer.read()\nwhile True:\n os.write(1,b"x"*4096)\n time.sleep(0.01)\n', ["diff"], False),
                ("early stdin close", 'os.close(0)\ntime.sleep(30)\n', ["diff", "x" * 100000], False),
                ("deadline", 'sys.stdin.buffer.read()\nos.close(1)\ntime.sleep(30)\n', ["diff"], True),
                ("nonzero status", f'sys.stdin.buffer.read()\nos.write(1,{valid!r})\nsys.exit(1)\n', ["diff"], False),
            ):
                install(body)
                began = time.monotonic()
                assert query(arguments) is None, name
                elapsed = time.monotonic() - began
                assert 9 <= elapsed <= 12 if timeout else elapsed < 2, (name, elapsed)
                assert_reaped(pid_file)
                print(name, "PASS")

        for roles in (None, dict(output=False, complete=False, eligible=False)):
            assert decision(roles, "log", ["--no-merges", "--output=out"])[0] == "output"
            for arguments in (["--", "--output=literal"], ["-S", "--output=consumed"], ["--unknown", "--output=uncertain"]):
                assert decision(roles, "diff", arguments)[0] == "inspection", arguments
        assert decision(dict(output=True, complete=False, eligible=False), "diff", ["--unknown"])[0] == "output"
        assert decision(dict(output=True, complete=True, eligible=False), "diff", ["--stat-width=80", "--output=out"])[0] == "output"
        assert decision(dict(output=False, complete=True, eligible=False), "diff", ["--output=consumed"])[0] == "inspection"
        print("positive fallback and query preservation PASS")
    finally:
        if previous_home is None:
            os.environ.pop("CODEX_CONFIGURED_HOME", None)
        else:
            os.environ["CODEX_CONFIGURED_HOME"] = previous_home


if __name__ == "__main__":
    main()
