# Emergency Unblock

Coordinator loads this module to assess a potential case. The assigned emergency implementer loads it only after coordinator qualification. It is exceptional; ordinary ECI workers do not load it.

It is a recovery aid, not an authorization or evidence ceremony.

## Emergency policy

> **Emergency Unblock** is a one-shot provisional path before normal ECI.
>
> Eligible only when already available direct evidence shows that the user is blocked now; the exact bug cause and repair, or the exact missing-capability change and repair, are already known; one smallest bounded reversible repair is obvious; no material competing diagnosis or approach exists; and the action is within the requested scope. Qualification performs no new diagnosis, reproduction, exploration, comparison, or hypothesis testing.
>
> Preserve secret-handling, destructive-action, external-mutation, dirty-work, role-ownership, and bounded-target reread safeguards. These prevent concrete accidental harm; they are not waived.
>
> Before the one provisional action, defer normal ECI Step 1/2, style review, TDD, tests, and critic review.
>
> For a non-configuration change, E2E may also be waived. E2E required by the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) may not be waived.

## Provisional action

> Route one implementer to make only the smallest repair. Report it exactly as **“provisional Emergency Unblock — unchecked”**; never call it fixed, accepted, complete, reviewed, proven, or ready to commit.
>
> Immediately after that action, start normal ECI Step 1 against the changed state. If the repair fails, uncertainty appears, diagnosis is hard, or another unchecked change seems necessary, make no second emergency repair: load `debugging-discipline` and enter the normal debugging route.
