# Emergency Unblock

Emergency Unblock is an ECI-defined pre-normal branch, not a separate workflow or nested normal ECI. It has exactly one direct owner: the emergency fixer. The fixer self-assesses this module’s eligibility and owns one bounded reversible repair. It creates no workflow, lane, assignment, dispatch, roster role, packet, transition record, ledger/status entry, or handoff. No coordinator, critic, reviewer, separate E2E role, parallel fixer, ATE role, or normal lifecycle action participates in that repair; unrelated normal work remains active. Any active ECI/ATE marker stays unchanged but does not authorize this repair.

It is a recovery aid, not an authorization or evidence ceremony.

## Emergency policy

> **Emergency Unblock** is a one-shot, single-owner recovery path before fresh normal ECI.
>
> The emergency fixer may use this route when direct evidence shows that the user is blocked now and it can independently reach one smallest bounded reversible repair within the requested scope.
>
> It may perform only the minimum diagnosis needed to find that repair. A material competing diagnosis or approach, hard uncertainty, non-reversibility, a broader target, or need for another repair ends the emergency route.
>
> Preserve secret-handling, destructive-action, external-mutation, dirty-work, role-ownership, and bounded-target reread safeguards. These prevent concrete accidental harm; they are not waived.
>
> Defer normal ECI Steps 1–4, style review, TDD, tests, and critic/reviewer participation only until the one repair ends. Do not defer the repair E2E required below.
>
> The fixer runs repair E2E as part of every configuration change under the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and every behavior-affecting repair. For a UI, API, device, or CLI path, follow the [Runtime E2E policy](../SKILL.md#runtime-e2e-policy). Only a behavior-neutral, non-configuration repair may defer it. This repair evidence neither triggers nor replaces normal implementer E2E or normal Step 4's independent repeat.

## Provisional action

> The emergency fixer alone performs the permitted diagnosis, the one repair, and any required repair E2E. Do not add a coordinator, critic, reviewer, separate E2E role, parallel fixer, ATE role, normal lifecycle action, or handoff to that repair while Emergency Unblock is active.
>
> Treat the resulting changed state as dirty and untrusted. Required E2E is repair evidence, not acceptance. Do not call the result accepted, complete, reviewed, proven, or ready to commit.
>
> Only after the repair ends and required E2E completes may fresh normal ECI begin at Step 1 from the dirty/untrusted changed state. E2E evidence from this route is context only; it does not substitute for normal implementer E2E or normal ECI Steps 1–4.
>
> End Emergency Unblock without a second repair if the repair fails; minimal diagnosis reveals a material competing diagnosis or approach; uncertainty becomes hard; or another repair seems necessary. Load `debugging-discipline` and enter the normal debugging route.
