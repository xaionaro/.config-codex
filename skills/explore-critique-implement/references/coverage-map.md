## Workflow coverage map

This map is an audit index, not an admission inventory. Use it to find the right guidance; never require a source version, hash, record, or route before ordinary bounded work.

| Concern | Destination | Verification |
| --- | --- | --- |
| activation, lineage, and worker routing | ECI router | routing test |
| coordinator lifecycle and teardown | coordinator runtime + ECI coordinator | routing test |
| direct-user pause behavior | pause-all-work | routing test |
| style guidance | coding-style-admission | review + formatter/linter where applicable |
| last-resort escalation | ECI coordinator + blocker-resolution-protocol | routing test |
| exploration and design choice | ECI explore + critique | independent review |
| bounded implementation and proof | ECI implement | target-appropriate checks |
| independent review and acceptance | ECI review + coordinator runtime + review policy | fresh A/B/C and required E2E |
| workflow-policy pressure cases | policy-pressure-tests | routing test |
| cross-skill red flags | owning module + ECI router | focused review |
