# First-tool reviewer causal scope

The historical latency mechanism combined two full transcript-history scans on a first tool call, prompt-state cleanup while holding the shared turn lock, and an optional backend request inside wider controller and hook bounds.

The maintained repair contract is:

- `UserPromptSubmit` writes one private, capped current-turn capture. The first-tool worker consumes that capture and does not scan transcript history beyond one byte-limited first-record classification.
- Current prompt/tool hook JSON and the first transcript record are rejected before shell substitution when they exceed 65,536 bytes, contain NUL, or are not strict complete UTF-8. Valid U+FFFD remains ordinary input. This is an admission bound, not a protocol claim about upstream payload sizes.
- Prompt-state publication and claiming release the shared turn lock before maintenance begins. Cleanup opens and revalidates its own state-directory descriptor, uses a distinct nonblocking private maintenance lock, makes one 4,096-byte `getdents64` call, processes at most 170 raw directory records, and persists a validated private cursor for a later invocation. Quiescent directories converge; continuous churn has no starvation guarantee.
- Prompt and tool text caps preserve complete UTF-8 code points. A valid multibyte character crossing a byte cap is omitted as a whole rather than transported as U+FFFD.
- The whole optional backend call is bounded at 58 seconds, the exact-child controller limit is 70 seconds, and the registered hook limit is 75 seconds. Curl receives a smaller inner limit; termination, reaping, and publication consume the margins.
- Accepted reviewer output is at most 4,096 bytes and is published to a verified pipe/FIFO with one checked write no larger than that pipe's `PIPE_BUF`.
- Anonymous bounded capture, exact pidfd ownership, child-side gate consumption, strict output validation, cancellation wakeup, exact reaping, and confirmed publication address safety and lifecycle evidence. They do not make a latency claim by themselves.

For each matching Bash invocation, one validator row and one first-tool reviewer row are expected. Repeated matching invocations therefore produce repeated pairs. Displayed rows alone do not prove that every corresponding process remains active, and already-running invocations are not retrofitted by later source changes.

Generated profiles cover only their named generated paths. They neither establish live-session causation nor a general speedup.
