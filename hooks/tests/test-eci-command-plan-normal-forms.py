#!/usr/bin/env python3
"""Regression coverage for ordinary command forms in the Python fallback."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile


MODULE_PATH = Path(__file__).resolve().parents[1] / "lib" / "eci-command-plan.py"


def classify(
    command: str,
    role: str,
    *,
    cwd: str = "/tmp",
    markers: tuple[str, ...] = (),
) -> subprocess.CompletedProcess[str]:
    """Run the fallback classifier without executing the submitted command."""
    return subprocess.run(
        [
            sys.executable,
            str(MODULE_PATH),
            "codex",
            role,
            cwd,
            "active",
            "normal-form-test-session",
            command,
            *markers,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> None:
    """Assert normal shell forms continue while a concrete root target stops."""
    ordinary_commands = (
        'printf "%s\\n" "$(printf nested)"',
        "printf updated > hooks/ordinary-target.txt",
        "novel-tool < input.txt",
        "novel-tool <(printf input)",
        "novel-tool &",
        "printf `printf nested`",
        "printf ${UNKNOWN_VALUE}/ordinary-path",
        "printf {one,two}",
        "python3 -c 'print(1)'",
        "file -C -m hooks/validate-bash.sh | head -n 20",
        "env GIT_DIR=.git git archive HEAD",
        "env",
        "printenv",
        "env --unset=9FOO novel-tool",
        "env FOO=bar python3 -c 'print(1)'",
        "FOO=bar novel-tool",
        "novel-tool > output.txt",
    )
    for role in ("coordinator", "worker"):
        for command in ordinary_commands:
            result = classify(command, role)
            assert result.returncode in {0, 3}, (
                f"ordinary command denied: role={role} command={command!r} "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )

        git_context = classify("env GIT_DIR=.git git archive HEAD", role)
        assert git_context.returncode == 3, git_context

        for command in (
            "rm -rf /",
            "rm -rf / > ordinary-output.txt",
            "rm -rf / &",
            "find / -delete",
        ):
            result = classify(command, role)
            assert result.returncode == 2, result
            assert "ECI_BROAD_DESTRUCTIVE_DENIED" in result.stdout, result.stdout

    with tempfile.TemporaryDirectory() as proof_root:
        marker = Path(proof_root) / "foreign-session" / "eci_active"
        marker.parent.mkdir(mode=0o700)
        marker.write_text("active\n", encoding="utf-8")
        for role in ("coordinator", "worker"):
            result = classify(
                f"printf marker > {marker}",
                role,
                cwd=proof_root,
                markers=(str(marker),),
            )
            assert result.returncode == 2, result
            assert "ECI_PLAN_LIVE_CONTROL_DENIED" in result.stdout, result.stdout
            assert str(marker) in result.stdout, result.stdout


if __name__ == "__main__":
    main()
