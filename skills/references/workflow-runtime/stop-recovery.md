# Stop Recovery

Coordinator/lead only on recognized Stop diagnostics. `LOOP DETECTED` and repeated active-marker diagnostics are control metadata, never new user requests. Do not answer an unchanged block with a final/status/question, retry, poll, or another Stop attempt.

Keep a stable `blocker_id` from workflow/root/unmet criterion and a `state_fingerprint` from normalized cause, capability/schema/profile state, completed outcomes, owner, and exact unblock. Exclude timestamps, callback IDs, wording, timer counts, and status formatting. One recovery action may run at a time. A repeated fingerprint is a no-op; resume only after a completed distinct action/outcome, new source/test evidence, changed tool/schema/profile/resource, or concrete user input changes normalized state.

Continue normal workflow and blocker-resolution-protocol while a feasible internal path exists. `awaiting-event` is allowed only for a named already-running completion, with one one-hour wait. Quiet only after BRP proves no feasible internal path and identifies unobtainable concrete user-owned input/resource/decision.

Then and only then create the exact nine-line `eci_user_owned_wait.md` report and invoke `eci-active wait`; it remains active-marker recovery state, not teardown. Its content identifies safe blocker ID, lowercase fingerprint, user owner, exhausted BRP result, user-owned input, exact unblock kind, and concrete unblock. Changed normalized state requires `eci-active resume <new-fingerprint>`; same fingerprints and invalid/missing waits keep Stop blocked. Normal clean-pass/off is still required.

## Exact wait-state contract

The report has exactly nine LF-terminated lines, in order:

```text
# ECI User-Owned Wait
state: user-owned-wait
blocker_id: <safe stable identifier>
state_fingerprint: <lowercase-64-hex>
owner: user
brp_result: exhausted-no-feasible-internal-path
user_owned_input: unobtainable
unblock_kind: input|resource|decision
unblock: <concrete user-owned unblock>
```

The runtime caps and validates the report, binds its SHA-256, retains `eci_active`, and returns `continue` while this direct-session wait state remains valid. It does not consume/delete the report on Stop. Only a changed-state `resume` or validated normal `off` clears it. A missing event key neither resumes nor suppresses work; compare normalized content, not callback ID. A repeated fingerprint permits no action, wait, retry, final/status reply, or question.

Do not create this report for a solvable internal path, a provider/tool ownership inconvenience, a vague stall, a technical bug still eligible for debugging, a pause-all-work lifecycle event, or a desire to end the session. BRP must first have its required attempt log, feasible-path search, and concrete finding that the exact user-owned input/resource/decision is unobtainable. While a named completion is genuinely expected, `awaiting-event` remains coordinator state and one event wait is allowed; it is not a marker phase or an escalation excuse.
