#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${CODEX_TEST_PRUNE_HELPER:-$ROOT/hooks/lib/prune_pre_reviewer_turn_state.py}"

names=(
  capture-turn-key.json claim-turn-key
  .capture-turn-key.redacted.A0 .capture-turn-key.capped.A0
  .capture-turn-key.json.A0 .capture-turn-key.validated.A0
  .capture-turn-key.consumed.A0 .capture-turn-key.prompt.A0
  capture-turn-.json capture-turn-key.json.extra capture-turn-key!.json
  claim-turn- claim-turn-key.json .capture-turn-key.unknown.A0
  .capture-turn-key.capped. .capture-turn-key.capped.A-0
  .capture-turn-key.capped.A0.extra unrelated
)

(cd "$ROOT/proofs" && lake build >/dev/null)
mapfile -t lean_outputs < <("$ROOT/proofs/.lake/build/bin/pruneTurnStateDiff" "${names[@]}")
mapfile -t python_outputs < <(
  python3 - "$HELPER" "${names[@]}" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pruner", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for name in sys.argv[2:]:
    print("1" if module.is_prunable_name(name) else "0")
PY
)

[ "${#lean_outputs[@]}" -eq "${#names[@]}" ]
[ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
printf 'prune namespace differential cases: %s\n' "${#names[@]}"
