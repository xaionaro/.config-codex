#!/usr/bin/env bash

set -euo pipefail

CODEX_ROOT="${CODEX_HOME:-${HOME:?}/.codex}"
KIMI_ROOT="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
expected='Treat short status queries and explicit requests for a status or progress report as requests for a current-state report. Load `writing-status-reports`; reconcile the YAML, validate, render, and publish the full rendered result. Include state, progress, decisions, blockers/risks, verification, next focus, and the multi-lane table when applicable. Correct known missing sections in the YAML and rerender; use its incomplete fallback only when structural failure prevents rendering.'

for instructions in "$CODEX_ROOT/CODEX.md" "$KIMI_ROOT/AGENTS.md"; do
  grep -Fqx -- "- $expected" "$instructions"
done

printf '%s\n' 'Status-report trigger guidance tests: PASS'
