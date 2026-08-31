# Requirement lineage

Requirement lineage is readable coordination context, not a permission system.
Assume bots are non-malicious. Use it to prevent accidental scope drift, not to
make normal work depend on hashes, receipts, exact schemas, or user-created
authorization artifacts.

## Record useful context

Keep the current `project-understanding.md` ledger readable enough to answer:

| Record | Purpose |
| --- | --- |
| User requirement | What outcome the user asked for, in concise faithful wording. |
| Lane | What bounded work is being done. |
| Reason | Why the lane helps that outcome. |
| Parent or prerequisite | Earlier lane when it materially explains the relationship. |
| Owner and evidence | Who owns it and the useful current proof or finding. |

Use stable IDs or aliases when they make a multi-lane report easier to follow.
Do not create an ID, registry, graph, hash, receipt, or exact record layout
solely to proceed with ordinary exploration, implementation, testing, review,
or status reporting.

## Use lineage while working

- Record known outcome, scope, owner, and verification when they are available.
  Label unknown context and reconcile it in parallel; never delay a safe bounded
  handoff. Link the requirement context when known.
- Missing or stale lineage is recorded as `lineage unavailable—reconcile`; it
  does not stop bounded work, status reporting, or a safe assignment.
- Reconcile missing context in parallel with safe work. For example, assign an
  explorer to recover the connection between an existing user requirement and
  a current implementation lane.
- Ask the user only when the proposed work introduces a genuinely new material
  outcome or a material ambiguity that cannot be resolved from the current
  request and ledger. Do not ask merely because an identifier or record is
  absent.
- Preserve historical decisions in `high_level_log.md` when they change the
  current scope or rationale. The ledger remains the current snapshot.

## Scope boundary

Stop or route only a concrete accidental scope mistake: for example, a worker
is about to modify another active lane's file, or a proposed feature is outside
the user's requested outcome. Name the resolved target or new outcome and use
the narrowest safe route.

Do not stop ordinary work for a missing lineage field, stale alias, unreadable
registry, absent log prefix, parser uncertainty, role label, command spelling,
or receipt mismatch. Those are coordination observations to repair or report.
