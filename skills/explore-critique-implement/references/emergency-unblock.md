# Emergency Unblock

Emergency Unblock has one owner: the emergency fixer. The fixer self-assesses this module’s eligibility and owns the entire emergency repair. It is exceptional; ordinary ECI workers do not load it. No coordinator, critic, reviewer, or separate E2E role participates, and no handoff occurs, until the emergency repair ends.

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
> Defer normal ECI Steps 1–4, style review, TDD, tests, and critic/reviewer participation only until the one repair ends. Do not defer the E2E required below.
>
> A configuration change always requires E2E under the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract). Otherwise, the emergency fixer performs E2E as part of every behavior-affecting repair. For a UI, API, device, or CLI path, follow the [Runtime E2E policy](../SKILL.md#runtime-e2e-policy). Only a non-configuration, behavior-neutral change may defer E2E.

## Provisional action

> The emergency fixer alone performs the permitted diagnosis, the one repair, and any required E2E. Do not add a coordinator, critic, reviewer, separate E2E role, or handoff while Emergency Unblock is active.
>
> Treat the resulting changed state as dirty and untrusted. Required E2E is repair evidence, not acceptance. Do not call the result accepted, complete, reviewed, proven, or ready to commit.
>
> Immediately after the repair ends, hand the dirty/untrusted changed state into fresh normal ECI Step 1. E2E evidence from this route is context only; it does not substitute for normal ECI Steps 1–4.
>
> End Emergency Unblock without a second repair if the repair fails; minimal diagnosis reveals a material competing diagnosis or approach; uncertainty becomes hard; or another repair seems necessary. Load `debugging-discipline` and enter the normal debugging route.
