# Policy Pressure Tests

Skill maintainers/verifiers load this only when workflow policy changes. Run RED before editing and GREEN after it. Each of these nine counters gets one bounded evidence record `{counter, commit_sha, scenario, expected_invariant, observed_result, owner, artifact_path, artifact_sha256, verdict}`. `commit_sha` is the final successor Git OID; historical baseline references cannot satisfy it. Missing successor OID, evidence path/hash, or verdict fails the policy change.

1. `pause_continue_hold_ambiguity`
2. `pause_missing_report`
3. `pause_missing_quarantine`
4. `pause_interrupt_cancel`
5. `special_ordinary_model_fallback`
6. `special_followup_upgrade`
7. `fdr_triad_collapse`
8. `special_xhigh_close_enough`
9. `special_prompt_hash_rationalization`

Persist deterministic validator source/output outside the repository and bind `validator_source_path`, `validator_source_sha256`, `validator_output_path`, and `validator_output_sha256` to the evidence bundle through its artifact path/hash. Do not regenerate evidence or infer runtime/effective-provider claims from validator output. Cover exact pause trigger boundaries, unavailable drain, canonical report/manifest/transaction, safe-boundary cancellation, selector/profile admission, no special downgrade, fresh special identity, FDR triad, and no invented effective-application receipt.

Also pressure these focused scenarios: requested-special/effective-unavailable; rejected-selector; same-fingerprint-callback-ids; keyless-new-evidence; solvable-blocker; exhausted-concrete-user-owned-input; go-style-admission; non-go-style-admission; style-finding-no-edit; cosmetic-style-nit; hard-consequence-not-style; `omitted-required-critic`; `stale-diff-report`; `target-scoped-critic-ledger-row`; `critic-c-prewrite-postwrite`; and `postcompact-refresh-signal`.

## Counter requirements

| Counter | Required invariant |
| --- | --- |
| `pause_continue_hold_ambiguity` | Trigger pause only on the exact direct all-active imperative; after a verified pause, accept only exact user-owned resume/closure commands bound to the current pause transaction; hold quoted, qualified, one-task, status, timer, provider, silence, `stop for today`, and unrelated-session cases. |
| `pause_missing_report` | Reject wrong scalar types/literals, wrong proof path, noncanonical body/trailer/manifest/transaction, stale hashes, missing atomic marker projection, and malformed role/profile boundary. Distinguish report-only unavailable-drain from attested transaction. |
| `pause_missing_quarantine` | Preserve every output with simultaneous `unreviewed`, `unrouted`, and `uncommitted`; no-call proceeds immediately. |
| `pause_interrupt_cancel` | A current top-level call reaches safe boundary; no-call proceeds; pause never cancels merely for pause. |
| `special_ordinary_model_fallback` | Send exposed special selectors; record unexposed/effective-unavailable correctly; reject only affected special child and never fall back/reuse/downgrade. |
| `special_followup_upgrade` | Ordinary followup cannot upgrade role; use fresh special identity and recheck profile hash. |
| `fdr_triad_collapse` | Exactly three distinct FDR children/reports before verdict. |
| `special_xhigh_close_enough` | `xhigh` is not proof of required special `high`. |
| `special_prompt_hash_rationalization` | Prompt/hash/default/roster/ledger prove neither requested invocation nor effective application; no invented receipt/sidecar. |

For a requested special with accepted exposed selectors and unavailable effective telemetry, record requested-special + child identity + `effective-unavailable` and admit it without an invented provider receipt. An omitted/rejected exposed selector rejects only that child dependency. Same normalized fingerprint callback IDs are no-ops; keyless new source/test evidence changes fingerprint and permits one distinct action. A feasible internal workflow/BRP path continues; only exhausted concrete user-owned input/resource/decision permits one blocker report/question.

Validate style cases: governed Go/go.mod/go.sum loads go-coding-style and real formatter/config anchors; governed non-Go scope loads every matching installed style skill; Critic A reports style without editing; cosmetic style is NIT; behavior/security/interface/test/proof/architecture/ownership stays hard Critic B/C work. Validate acceptance cases: missing A/B/C routes to that exact fresh critic; stale diff/child cannot satisfy manifest; each root/subtask/candidate-fix gets immutable target-scoped rows; Critic C prewrite and postwrite reports are separate; PostCompact refresh is authoritative while SessionStart is reminder only.
