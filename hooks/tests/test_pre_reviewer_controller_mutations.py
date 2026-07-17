#!/usr/bin/env python3
"""Static mutation contract for the Python exact-child controller."""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WRAPPER = Path("hooks/edit-bash-pre-reviewer.sh")
CONTROLLER = Path("hooks/lib/edit_bash_pre_reviewer_controller.py")
HOOKS_JSON = Path("hooks.json")
SPEC = Path("proofs/Spec/PreReviewerController.lean")
PROOFS = Path("proofs/Proofs/PreReviewerController.lean")
LIFECYCLE = Path("hooks/tests/pre_reviewer_lifecycle.py")
PROFILER = Path("hooks/tests/profile_pre_reviewer_ab.py")


REQUIRED: dict[Path, tuple[str, ...]] = {
    WRAPPER: (
        'controller="$HOOK_DIR/lib/edit_bash_pre_reviewer_controller.py"',
        'exec "$python_command" "$controller"',
        "resolve_absolute_executable python3",
        "resolve_absolute_executable unshare",
    ),
    CONTROLLER: (
        "OUTPUT_CAP: Final = 4_096",
        "retain_raw_chunk(",
        'b"\\0" in chunk',
        'raw.decode("utf-8", "strict")',
        "object_pairs_hook=_strict_object",
        "signal.pidfd_send_signal",
        "os.pidfd_open",
        '"--user"',
        '"--map-root-user"',
        '"--pid"',
        '"--fork"',
        '"--kill-child=KILL"',
        "PR_SET_PDEATHSIG",
        "if os.getppid() != expected_parent",
        "_set_parent_death_signal(expected_parent)",
        "wait_exact_process",
        "wait_exact_publisher",
        "os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)",
        "os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)",
        "signal.pthread_sigmask",
        "signal.set_wakeup_fd(child.release_fd)",
        "_release_gate",
        "class OwnedChild:",
        "class OwnedChildGuard:",
        "self.status = _cleanup_owned_child(self.child)",
        "_select_unless_cancelled",
        'os.write(wake_write, b"\\0")',
        "_failed_gated_fork(",
        "os.waitpid(pid, os.WNOHANG)",
        "os.kill(pid, signal.SIGKILL)",
    ),
    HOOKS_JSON: (
        '"statusMessage": "Checking shell command"',
        '"statusMessage": "Checking first tool call"',
        '"timeout": 75',
    ),
    SPEC: (
        "publicationStarted : Bool",
        "outputMayHaveEscaped : Bool",
        "publicationConfirmed : Bool",
        "def publicationConfirmable",
        "def descriptorsClosed",
        "reviewerOwned",
        "publisherOwned",
        "maintenanceHoldsSharedTurnLock",
    ),
    PROOFS: (
        "theorem controllerRun_confirmation_safe",
        "theorem publication_facts_are_monotone",
        "theorem cancelled_fold_cannot_confirm",
        "theorem descriptor_cleanup_idempotent",
        "theorem maintenance_visit_count_bounded",
        "theorem maintenance_never_holds_shared_turn_lock",
    ),
    LIFECYCLE: (
        "def abrupt_controller_death(",
        'generated_input("descendant-no-pdeath")',
        "unrelated exact survivor was disturbed",
        "def publication_evidence(",
        "started-no-escape",
        "atomic-backpressure-no-escape",
        "complete-before-confirm",
        "publication-state conflation mutation survived",
        "def _pidfd_for_child(",
        "def _gate_consumed(",
        "del label",
    ),
    PROFILER: (
        'BASELINE_COMMIT: Final = "72b8b3d62df89975b35ed5bda1a5231a2be4fe4b"',
        '"git", "get-tar-commit-id"',
        "RUNTIME_MANIFEST_RELATIVE_PATH",
        "def discover_runtime_sources(",
        "runtime-manifest-before ",
        "def export_candidate(",
        "def render_identity_record(",
        "candidate source bytes differ from reported commit",
        "def observe_configured_sources(",
        "configured command source mismatch",
        "source-identities ",
        "time.monotonic_ns()",
        "parent_raw_ms=",
        "candidate_raw_ms=",
        "prepared-fake",
        "large-history",
        "retained-state",
        "capture_consumed",
        "call_attempted",
        "call_completed",
        "Two rows per matching Bash invocation are expected; displayed ",
        "rows alone do not prove that all corresponding processes remain ",
    ),
}


FORBIDDEN: dict[Path, tuple[str, ...]] = {
    WRAPPER: ("coproc", "mktemp", "CODEX_PRE_REVIEWER_TRACE_FD"),
    CONTROLLER: (
        "os.killpg(",
        "CODEX_PRE_REVIEWER_TRACE_FD",
        "CODEX_PRE_REVIEWER_WAIT_NOTIFY_FD",
        "NamedTemporaryFile",
        "mkstemp",
    ),
}


MUTATIONS: tuple[tuple[str, Path, str, str], ...] = (
    ("remove-cap", CONTROLLER, "OUTPUT_CAP: Final = 4_096", "4_097"),
    ("remove-nul", CONTROLLER, 'b"\\0" in chunk', "False"),
    (
        "remove-pidfd-signal",
        CONTROLLER,
        "signal.pidfd_send_signal",
        "os.kill",
    ),
    (
        "remove-kill-child",
        CONTROLLER,
        '"--kill-child=KILL"',
        '"--fork"',
    ),
    (
        "remove-pdeath",
        CONTROLLER,
        "_set_parent_death_signal(expected_parent)",
        "pass  # generated mutation",
    ),
    (
        "remove-parent-check",
        CONTROLLER,
        "if os.getppid() != expected_parent",
        "if False",
    ),
    (
        "remove-exact-reviewer-wait",
        CONTROLLER,
        "waited_pid, raw_status = os.waitpid(child.pid, 0)",
        "waited_pid, raw_status = child.pid, 0",
    ),
    (
        "remove-exact-child-guard-cleanup",
        CONTROLLER,
        "self.status = _cleanup_owned_child(self.child)",
        "self.status = 0",
    ),
    (
        "remove-failed-gate-exact-kill",
        CONTROLLER,
        "os.kill(pid, signal.SIGKILL)",
        "pass  # generated mutation",
    ),
    (
        "conflate-started-escaped",
        SPEC,
        "outputMayHaveEscaped : Bool",
        "publicationStartedAgain : Bool",
    ),
    (
        "conflate-escaped-confirmed",
        SPEC,
        "publicationConfirmed : Bool",
        "outputMayHaveEscapedAgain : Bool",
    ),
    (
        "remove-confirmation-proof",
        PROOFS,
        "theorem controllerRun_confirmation_safe",
        "def controllerRun_confirmation_safe",
    ),
    (
        "profile-baseline-revision",
        PROFILER,
        'BASELINE_COMMIT: Final = "72b8b3d62df89975b35ed5bda1a5231a2be4fe4b"',
        'BASELINE_COMMIT: Final = "HEAD"',
    ),
    (
        "remove-profile-source-observation",
        PROFILER,
        "configured command source mismatch",
        "configured command source accepted",
    ),
    (
        "registration-timeout",
        HOOKS_JSON,
        '"timeout": 75',
        '"timeout": 74',
    ),
)


def contract_holds(sources: dict[Path, str]) -> bool:
    return (
        all(
            token in sources[path]
            for path, tokens in REQUIRED.items()
            for token in tokens
        )
        and all(
            token not in sources[path]
            for path, tokens in FORBIDDEN.items()
            for token in tokens
        )
        and all(old in sources[path] for _name, path, old, _new in MUTATIONS)
    )


class ControllerMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        paths = set(REQUIRED) | set(FORBIDDEN)
        self.sources = {
            path: (ROOT / path).read_text(encoding="utf-8") for path in paths
        }

    def test_contract_baseline(self) -> None:
        self.assertTrue(contract_holds(self.sources))

    def test_each_mutation_is_killed(self) -> None:
        for name, path, old, new in MUTATIONS:
            with self.subTest(name=name):
                mutated = dict(self.sources)
                mutated[path] = mutated[path].replace(old, new)
                self.assertFalse(contract_holds(mutated))


if __name__ == "__main__":
    unittest.main()
