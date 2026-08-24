## Pre-split coverage map

Baseline source SHA-256: `9d9d990b4c65c2175bd10d87949512293fc64704aeb4672a868702aa0bcd6623`.

| Source family | Invariant | Destination | Verification |
| --- | --- | --- | --- |
| `ATE :1-109,177-245,290-397,427-526,542-704,830-1008` | outer lifecycle/roles/lineage | ATE router + orchestration + coordinator-runtime | routing-test |
| `ATE :110-176` | exact pause transaction | pause-all-work | routing-test |
| `ATE :246-289,705-797` | acceptance/review runtime | coordinator-runtime + review-policy + ATE review | routing-test |
| `ATE :398-426` | independent style admission | coding-style-admission | routing-test |
| `ATE :512-526,726-759` | architecture/PoC/design review | ATE design | routing-test |
| `ATE research` | fact discovery | ATE research | routing-test |
| `ATE execution+debug` | owned implementation/RCA | ATE execution + debugging-discipline | routing-test |
| `ATE :798-829` | test design/QA | ATE testing-and-qa | routing-test |
| `ATE :1009-1051` | policy scenarios | policy-pressure-tests | routing-test |
| `ATE :1052-1122` | red flags/cross-skill limits | owners + ATE router | routing-test |
