#!/usr/bin/env bash

set -euo pipefail

CODEX_ROOT="${CODEX_HOME:-${HOME:?}/.codex}"
KIMI_ROOT="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
codex_expected='Treat short status queries and explicit requests for a status or progress report as requests for a current-state report. Load `writing-status-reports`; reconcile the YAML, validate, render, and publish the full rendered result. Include state, progress, decisions, blockers/risks, verification, next focus, and the multi-lane table when applicable. Correct known missing sections in the YAML and rerender; use its incomplete fallback only when structural failure prevents rendering.'
kimi_expected='Treat short status queries—exact `status`, `sitrep`, `progress`, `checkpoint`, and equivalents—as requests for a current-state report. Load `writing-status-reports` and include state, progress, decisions, blockers/risks, verification, and next focus; use its multi-lane table when applicable. Never answer only “no new action” or a terse acknowledgment.'

grep -Fqx -- "- $codex_expected" "$CODEX_ROOT/CODEX.md"
grep -Fqx -- "- $kimi_expected" "$KIMI_ROOT/AGENTS.md"

printf '%s\n' 'Status-report trigger guidance tests: PASS'
