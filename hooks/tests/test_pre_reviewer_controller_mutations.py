#!/usr/bin/env python3
"""Static mutation checks for the bounded pre-reviewer controller contract."""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = Path("hooks/edit-bash-pre-reviewer.sh")
WORKER = Path("hooks/lib/edit-bash-pre-reviewer-worker.sh")
HOOKS_JSON = Path("hooks.json")
SPEC = Path("proofs/Spec/PreReviewerController.lean")
PROBE = Path("hooks/tests/probe-pre-reviewer-timeout.sh")


REQUIRED: dict[Path, tuple[str, ...]] = {
    CONTROLLER: (
        "readonly CONTROLLER_TIMEOUT=70",
        "readonly CONTROLLER_KILL_AFTER=2",
        "backend_timeout=60",
        '[[ "$backend_timeout" =~ ^([1-9]|[1-5][0-9]|60)$ ]]',
        '[ -f "$BASH" ] && [ -x "$BASH" ]',
        '[ -f "$worker" ] && [ -r "$worker" ]',
        "resolve_controller_command timeout",
        "resolve_controller_command mktemp",
        "resolve_controller_command chmod",
        "resolve_controller_command cat",
        "resolve_controller_command rm",
        'kill -TERM -- "-$controller_leader"',
        'kill -KILL -- "-$controller_leader"',
        'wait "$controller_leader"',
        'exec {controller_stdin_fd}>&-',
        'if [ "$controller_status" -eq 0 ]',
        '"$rm_command" -f -- "$controller_buffer"',
        '"${CONTROLLER_TIMEOUT}s" "$BASH" "$worker"',
    ),
    WORKER: ('HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"',),
    HOOKS_JSON: ('"timeout": 75',),
    SPEC: (
        "if state.leaderReaped && state.status == some .success then",
        '| .closeStdin => { state with stdinLive := false }',
        '| .removeBuffer => { state with bufferLive := false }',
        "leaderOwned := false, leaderReaped := true, status := some result",
    ),
    PROBE: (
        "synthetic_pid_absent()",
        "attempt < 50",
        "sleep 0.02",
        'synthetic_pid_absent "$leader"',
        'synthetic_pid_absent "$worker_pid"',
        'synthetic_pid_absent "$child_pid"',
    ),
}

REQUIRED_COUNTS: dict[tuple[Path, str], int] = {
    (CONTROLLER, 'wait "$controller_leader"'): 2,
    (CONTROLLER, 'exec {controller_stdin_fd}>&-'): 2,
    (HOOKS_JSON, '"timeout": 75'): 4,
}


MUTATIONS: tuple[tuple[str, Path, str, str], ...] = (
    ("timeout-70", CONTROLLER, "CONTROLLER_TIMEOUT=70", "CONTROLLER_TIMEOUT=71"),
    ("kill-after-2", CONTROLLER, "CONTROLLER_KILL_AFTER=2", "CONTROLLER_KILL_AFTER=3"),
    ("backend-default-60", CONTROLLER, "backend_timeout=60", "backend_timeout=61"),
    ("backend-regex", CONTROLLER, "[1-5][0-9]|60", "[1-6][0-9]|60"),
    ("bash-check", CONTROLLER, '[ -f "$BASH" ]', "true"),
    ("worker-check", CONTROLLER, '[ -f "$worker" ]', "true"),
    ("timeout-prerequisite", CONTROLLER, "resolve_controller_command timeout", "printf timeout"),
    ("mktemp-prerequisite", CONTROLLER, "resolve_controller_command mktemp", "printf mktemp"),
    ("chmod-prerequisite", CONTROLLER, "resolve_controller_command chmod", "printf chmod"),
    ("cat-prerequisite", CONTROLLER, "resolve_controller_command cat", "printf cat"),
    ("rm-prerequisite", CONTROLLER, "resolve_controller_command rm", "printf rm"),
    ("pid-only-term", CONTROLLER, '"-$controller_leader"', '"$controller_leader"'),
    ("delete-kill", CONTROLLER, 'kill -KILL -- "-$controller_leader"', ":"),
    ("wrong-wait", CONTROLLER, 'wait "$controller_leader"', "wait"),
    ("ignore-nonzero", CONTROLLER, '"$controller_status" -eq 0', '"$controller_status" -ge 0'),
    ("omit-stdin-release", CONTROLLER, "exec {controller_stdin_fd}>&-", ":"),
    ("omit-buffer-release", CONTROLLER, '"$rm_command" -f -- "$controller_buffer"', ":"),
    ("worker-invocation", CONTROLLER, '"$BASH" "$worker"', 'bash "$0"'),
    ("config-75", HOOKS_JSON, '"timeout": 75', '"timeout": 74'),
    ("lean-premature-publish", SPEC, "if state.leaderReaped &&", "if true &&"),
    ("lean-omit-close", SPEC, "stdinLive := false", "stdinLive := true"),
    ("lean-omit-remove", SPEC, "bufferLive := false", "bufferLive := true"),
    ("lean-wrong-reap", SPEC, "leaderReaped := true", "leaderReaped := false"),
    ("omit-bounded-pid-poll", PROBE, "synthetic_pid_absent()", "pid_absent()"),
    ("unbound-pid-poll", PROBE, "attempt < 50", "true"),
)


def contract_holds(sources: dict[Path, str]) -> bool:
    tokens_present = all(
        token in sources[path] for path, tokens in REQUIRED.items() for token in tokens
    )
    counts_match = all(
        sources[path].count(token) == expected
        for (path, token), expected in REQUIRED_COUNTS.items()
    )
    return tokens_present and counts_match


class ControllerMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = {path: (ROOT / path).read_text(encoding="utf-8") for path in REQUIRED}

    def test_contract_baseline(self) -> None:
        self.assertTrue(contract_holds(self.sources))

    def test_each_mutation_is_killed(self) -> None:
        for name, path, old, new in MUTATIONS:
            with self.subTest(name=name):
                self.assertIn(old, self.sources[path])
                mutated = dict(self.sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertFalse(contract_holds(mutated))


if __name__ == "__main__":
    unittest.main()
