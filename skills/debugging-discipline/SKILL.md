---
name: debugging-discipline
description: Use alongside superpowers:systematic-debugging for any problem — adds hypothesis discipline, alternative explanations, and falsification requirements
---

# Debugging Discipline

Supplements `superpowers:systematic-debugging` with additional rigor.

## Reproduce first

Reproduce the issue before investigating. No reproduction = no understanding.

## Hypothesis Discipline

- Label every potential cause as HYPOTHESIS until falsified — saying "root cause identified" prematurely leads to wasted effort on wrong fixes.
- Before testing a hypothesis, state at least one alternative explanation. If you can't, you don't understand the problem yet.
- A hypothesis becomes "confirmed root cause" only when you have tested a prediction that would have DISPROVED it if wrong, and it survived.

## Logging

- When you can't diagnose → add logging + auto-tests to gather info/reproduce.
- When unsure about log level, prefer more logging.
- When logs lack relevant IDs or context, fix them immediately.
