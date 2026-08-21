#!/usr/bin/env bash

set -euo pipefail

CODEX_ROOT="${CODEX_HOME:-${HOME:?}/.codex}"
KIMI_ROOT="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
expected='Treat short status queries—exact `status`, `sitrep`, `progress`, `checkpoint`, and equivalents—as requests for a current-state report. Load `writing-status-reports` and include state, progress, decisions, blockers/risks, verification, and next focus; use its multi-lane table when applicable. Never answer only “no new action” or a terse acknowledgment.'

for instructions in "$CODEX_ROOT/CODEX.md" "$KIMI_ROOT/AGENTS.md"; do
  grep -Fqx -- "- $expected" "$instructions"
done

printf '%s\n' 'Status-report trigger guidance tests: PASS'
