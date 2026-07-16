#!/usr/bin/env python3
"""Unit checks for externally derived lifecycle evidence."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


MODULE_PATH = Path(__file__).with_name("pre_reviewer_lifecycle.py")
SPEC = importlib.util.spec_from_file_location("pre_reviewer_lifecycle", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ExternalEvidenceTests(unittest.TestCase):
    def test_confirmed_tuple_requires_all_independent_facts(self) -> None:
        events = (
            "input-closed",
            "reviewer-read-closed",
            "reviewer-write-closed",
            "reviewer-reaped:success",
            "publisher-started",
            "output-escaped",
            "publisher-reaped:success",
            "publication-confirmed",
        )
        self.assertEqual(MODULE._tuple_from_events(events), "1 1 1 1 1 0")
        for removed in events:
            if removed == "publisher-reaped:success":
                continue
            with self.subTest(removed=removed):
                mutated = tuple(event for event in events if event != removed)
                self.assertNotEqual(
                    MODULE._tuple_from_events(mutated), "1 1 1 1 1 0"
                )

    def test_controller_children_ignore_wrapper_preexec_clones(self) -> None:
        trace = (
            "4 clone(flags) = 5\n"
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 clone(flags) = 6\n"
            "4 clone(flags) = 7\n"
        )
        self.assertEqual(MODULE._children(trace, 4), [6, 7])

    def test_close_requires_matching_successful_completion(self) -> None:
        cases = (
            ("4 close(9) = 0\n", True),
            ("4 close(9 <unfinished ...>\n", False),
            (
                "4 close(9 <unfinished ...>\n"
                "4 <... close resumed>) = 0\n",
                True,
            ),
            (
                "4 close(9 <unfinished ...>\n"
                "4 <... close resumed>) = -1 EBADF (Bad file descriptor)\n",
                False,
            ),
            (
                "4 close(9 <unfinished ...>\n"
                "5 close(9) = 0\n"
                "4 <... close resumed>) = 0\n",
                True,
            ),
        )
        for trace, expected in cases:
            with self.subTest(trace=trace):
                self.assertEqual(MODULE._closed(trace, 4, 9), expected)

    def test_wait_parser_pairs_pid_instance_and_preserves_status(self) -> None:
        cases = (
            (
                "4 wait4(6, [{WIFEXITED(s) && WEXITSTATUS(s) == 0}], "
                "0, NULL) = 6\n",
                (True, True),
            ),
            ("4 wait4(6, <unfinished ...>\n", (False, False)),
            (
                "4 wait4(6, <unfinished ...>\n"
                "4 <... wait4 resumed>[{WIFEXITED(s) && "
                "WEXITSTATUS(s) == 0}], 0, NULL) = 6\n",
                (True, True),
            ),
            (
                "4 wait4(6, <unfinished ...>\n"
                "4 <... wait4 resumed>[{WIFSIGNALED(s) && "
                "WTERMSIG(s) == SIGTERM}], 0, NULL) = 6\n",
                (True, False),
            ),
            (
                "4 wait4(6, <unfinished ...>\n"
                "4 <... wait4 resumed>[{WIFEXITED(s) && "
                "WEXITSTATUS(s) == 0}], 0, NULL) = 7\n",
                (False, False),
            ),
            (
                "4 wait4(6, <unfinished ...>\n"
                "5 wait4(8, [{WIFEXITED(s) && WEXITSTATUS(s) == 0}], "
                "0, NULL) = 8\n"
                "4 <... wait4 resumed>[{WIFEXITED(s) && "
                "WEXITSTATUS(s) == 0}], 0, NULL) = 6\n",
                (True, True),
            ),
            (
                "4 wait4(6, <unfinished ...>\n"
                "4 <... wait4 resumed>) = -1 ECHILD (No child processes)\n",
                (False, False),
            ),
        )
        for trace, expected in cases:
            with self.subTest(trace=trace):
                self.assertEqual(MODULE._waited(trace, 4, 6), expected)

    def test_capture_completion_requires_exact_read_eof(self) -> None:
        no_eof = (
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 pipe2([10, 11], O_CLOEXEC) = 0\n"
            "4 fcntl(10, F_DUPFD_CLOEXEC, 301) = 301\n"
            "4 fcntl(11, F_DUPFD_CLOEXEC, 302) = 302\n"
            "4 pipe2([12, 13], O_CLOEXEC|O_NONBLOCK) = 0\n"
            "4 clone(flags) = 6\n"
            "4 pidfd_open(6, 0) = 14\n"
            '6 read(12, "\\x00", 1) = 1\n'
        )
        events = MODULE.external_events(no_eof, 4, b"x", b"x", "success")
        self.assertNotIn("capture-complete", events)

        resumed_eof = (
            no_eof
            + "4 read(301,  <unfinished ...>\n"
            + '4 <... read resumed>"", 4096) = 0\n'
        )
        events = MODULE.external_events(resumed_eof, 4, b"x", b"x", "success")
        self.assertIn("capture-complete", events)

    def test_lifecycle_source_has_no_controller_authored_authority(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "CODEX_PRE_REVIEWER_TRACE_NONCE",
            "role=controller event=",
            "validate_records(",
        ):
            self.assertNotIn(forbidden, source)

    def test_labels_and_clone_position_do_not_create_lifecycle_facts(self) -> None:
        trace = (
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 clone(flags) = 6\n"
        )
        events = MODULE.external_events(trace, 4, b"", b"", "real-timeout")
        for unsupported in (
            "reviewer-owned",
            "reviewer-started",
            "capture-rejected",
            "cancellation-observed",
        ):
            with self.subTest(unsupported=unsupported):
                self.assertNotIn(unsupported, events)

    def test_start_requires_child_side_gate_consumption(self) -> None:
        trace = (
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 pipe2([8, 9], O_CLOEXEC|O_NONBLOCK) = 0\n"
            "4 clone(flags) = 6\n"
            "4 pidfd_open(6, 0) = 10\n"
            '4 write(9, "\\x00", 1) = 1\n'
        )
        events = MODULE.external_events(trace, 4, b"", b"", "success")
        self.assertIn("reviewer-owned", events)
        self.assertNotIn("reviewer-started", events)

    def test_rejection_and_cancellation_require_observed_facts(self) -> None:
        trace = (
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 pipe2([8, 9], O_CLOEXEC|O_NONBLOCK) = 0\n"
            "4 clone(flags) = 6\n"
            "4 pidfd_open(6, 0) = 10\n"
            '6 read(8, "\\x00", 1) = 1\n'
        )
        events = MODULE.external_events(trace, 4, b"", b"", "real-timeout")
        self.assertNotIn("capture-rejected", events)
        self.assertNotIn("cancellation-observed", events)

    def test_hex_reads_distinguish_nul_from_literal_backslash_zero(self) -> None:
        actual_nul = '4 read(301, "\\x00", 4096) = 1\n'
        literal = '4 read(301, "\\x5c\\x30", 4096) = 2\n'
        escaped_backslash = '4 read(301, "\\x5c\\x5c\\x30", 4096) = 3\n'

        self.assertEqual(MODULE._capture_read_facts(actual_nul, 4, 301), (1, True))
        self.assertEqual(MODULE._capture_read_facts(literal, 4, 301), (2, False))
        self.assertEqual(
            MODULE._capture_read_facts(escaped_backslash, 4, 301), (3, False)
        )

    def test_resumed_hex_read_preserves_split_actual_nul(self) -> None:
        trace = (
            '4 read(301,  <unfinished ...>\n'
            '5 read(9, "\\x5c\\x30", 2) = 2\n'
            '4 <... read resumed>"\\x61\\x00\\x62", 4096) = 3\n'
        )
        self.assertEqual(MODULE._capture_read_facts(trace, 4, 301), (3, True))

    def test_gate_start_requires_exact_hex_nul(self) -> None:
        prefix = (
            "4 fcntl(0, F_DUPFD_CLOEXEC, 300) = 300\n"
            "4 pipe2([8, 9], O_CLOEXEC|O_NONBLOCK) = 0\n"
            "4 clone(flags) = 6\n"
            "4 pidfd_open(6, 0) = 10\n"
        )
        actual = prefix + '6 read(8, "\\x00", 1) = 1\n'
        literal = prefix + '6 read(8, "\\x5c\\x30", 1) = 1\n'
        self.assertIn(
            "reviewer-started", MODULE.external_events(actual, 4, b"", b"", "success")
        )
        self.assertNotIn(
            "reviewer-started", MODULE.external_events(literal, 4, b"", b"", "success")
        )

    def test_lifecycle_strace_requests_unambiguous_full_hex_strings(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        self.assertIn('"-xx"', source)
        self.assertIn('"-s",\n            "65536"', source)


if __name__ == "__main__":
    unittest.main()
