---
name: debugging-discipline
description: Use when debugging and needing falsifiable hypotheses, alternative explanations, or stronger root-cause discipline
---

# Debugging Discipline

Supplements `systematic-debugging` with additional rigor.

Mitigation is not a fix: lowering failure probability is containment until the cause chain is repaired.
Require explicit causality: trigger -> mechanism -> failure -> repaired link. Any missing link means keep investigating.

## Required Procedure

Follow this loop:

```text
loop(loop(RCA, critic), repro), loop(fix, review)
```

Core rule: keep the failure check cheap and rerun it constantly. After each probe, logging change, or fix, immediately answer: is the original failure still present?

- **Repro loop:** Keep a minimal, fast repro command/path ready. Reproduce the current failure before each RCA pass and rerun the repro after each small probe, logging change, or fix. If reproduction is slow or inconsistent, first shrink/stabilize it with evidence, logging, or tests until the failure mode is observable.
- **RCA/critic loop:** Gather evidence first: inspect the failing path, relevant code, logs, tests, recent changes, and adjacent systems. State an informed RCA hypothesis from that evidence, not a guess. The critic must identify alternative explanations, missing evidence, and predictions that could falsify the hypothesis. Repeat until the critic has no unresolved objections.
- **RCA instrumentation:** RCA may add any scoped diagnostic code needed to gather strong evidence for or against a root-cause hypothesis: logs, traces, counters, assertions, probes, tests, scripts, data captures, or temporary instrumentation. Keep probes targeted and reversible; final review decides what to keep, remove, or convert into regression coverage.
- **Bisect during RCA:** If the required behavior worked at a known commit, release, config, dependency version, or data state, bisect from known-good to current-bad before broad speculation. Run the fast repro at every step. If only a rough timeframe exists, first establish known-good and known-bad anchors.
- **Fix/review loop:** Implement one root-cause fix with rationale: cause chain, evidence, and why the diff repairs the mechanism. Review the rationale against the repro, RCA evidence, tests, and regression risk. Unknown "why" or symptom-only change = failed review unless containment was explicitly requested. Repeat until review finds no blocking issue.

When subagents are explicitly authorized, use one persistent `repro/RCA/fix` subagent for all three phases so reproduction and RCA context carry into the fix. Use separate subagents for `critic` and `review`. Prefer fresh `critic` and `review` subagents each iteration; close or replace them after each pass so prior conclusions do not anchor the next critique. Pass only a compact evidence packet: problem statement, repro steps, relevant logs, current RCA or diff, constraints, and open questions.

Root-cause reporting to the coordinator is mandatory at each transition: suggested RCA, critic-approved RCA, fix proposal, and confirmed fix. Include cause chain, evidence, falsifying prediction tested or still needed, repaired link, and unresolved alternatives. The coordinator owns the current root-cause state and passes it into the next critic/review packet.

## Reproduce first

Reproduce the issue before investigating. No reproduction = no understanding. Slow repros block learning; shrink or automate them before expanding scope.

## Hypothesis Discipline

- Label every potential cause as HYPOTHESIS until falsified — saying "root cause identified" prematurely leads to wasted effort on wrong fixes.
- An RCA hypothesis without cited evidence and explored code/log/test context is a guess. Gather more evidence before testing fixes.
- Before testing a hypothesis, state at least one alternative explanation. If you can't, you don't understand the problem yet.
- A hypothesis becomes "confirmed root cause" only when you have tested a prediction that would have DISPROVED it if wrong, and it survived.

## Logging

- When you can't diagnose → add logging + auto-tests to gather info/reproduce.
- When unsure about log level, prefer more logging.
- When logs lack relevant IDs or context, fix them immediately.
