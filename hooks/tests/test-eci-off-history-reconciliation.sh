#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-off-history.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

proof_root="$TMP_ROOT/proof"
session_id=t00-off-history
session_dir="$proof_root/$session_id"
report="$session_dir/disengage.md"
manifest="$session_dir/eci-required-critics.json"
receipt="$session_dir/eci-teardown-complete"
mkdir -p -- "$session_dir"

run_active() {
  CODEX_SESSION_ID="$session_id" CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" "$@"
}

printf '%s\n' 'Normal work completed; no unresolved current-session wait state remains.' >"$report"

run_active on 'off history reconciliation fixture' >"$TMP_ROOT/on.out"

# A current ordinary report is not a permission artifact: missing historical
# headings or terminal wording cannot hold normal teardown open. The live
# marker/CWD and unresolved-work checks remain the actual boundary.
if ! run_active off "$report" >"$TMP_ROOT/off-plain.out" 2>"$TMP_ROOT/off-plain.err"; then
  cat -- "$TMP_ROOT/off-plain.err" >&2
  exit 1
fi
[ ! -e "$session_dir/eci_active" ] && [ ! -L "$session_dir/eci_active" ]
grep -q '^ECI inactive\. Disengage report read:' "$TMP_ROOT/off-plain.out"

# A current report target must still be a direct regular file. A symlink is a
# real target-boundary mistake, so it is refused without removing the live
# marker or following its destination.
run_active on 'unsafe report target fixture' >"$TMP_ROOT/on-unsafe-report.out"
safe_target="$TMP_ROOT/safe-report-target.md"
printf '%s\n' \
  '## ECI completion certificate' \
  'clean-pass:' \
  '## Stop checklist walkthrough' \
  'validated' \
  '## Incomplete compliance' \
  'none' >"$safe_target"
symlink_report="$session_dir/symlink-report.md"
ln -s -- "$safe_target" "$symlink_report"
if run_active off "$symlink_report" >"$TMP_ROOT/off-symlink.out" 2>"$TMP_ROOT/off-symlink.err"; then
  printf '%s\n' 'normal off followed a symlinked current report target' >&2
  exit 1
fi
[ -f "$session_dir/eci_active" ] && [ ! -L "$session_dir/eci_active" ]
[ -L "$symlink_report" ]
grep -Fqx 'clean-pass:' "$safe_target"
rm -f -- "$symlink_report"

# These are historical metadata, not the current report. Normal off must
# retain its valid current-report requirement while reconciling this residue.
printf '%s\n' 'malformed historical manifest' >"$manifest"
ln -s -- "$session_dir/missing-report" "$receipt"
if ! run_active off "$report" >"$TMP_ROOT/off.out" 2>"$TMP_ROOT/off.err"; then
  cat -- "$TMP_ROOT/off.err" >&2
  exit 1
fi

[ ! -e "$session_dir/eci_active" ] && [ ! -L "$session_dir/eci_active" ]
[ -L "$receipt" ]
grep -q '^ECI inactive\. Disengage report read:' "$TMP_ROOT/off.out"

# The next clean close has no manifest plus a malformed legacy report and
# receipt. They remain historical/advisory while the supplied current report
# still carries the actual clean-pass decision.
rm -f -- "$manifest"
run_active on 'second off history reconciliation fixture' >"$TMP_ROOT/on-second.out"
printf '%s\n' 'malformed historical report' >"$session_dir/old-disengage.md"
printf '%s\n' 'malformed historical receipt' >"$receipt"
run_active off "$report" >"$TMP_ROOT/off-second.out" 2>"$TMP_ROOT/off-second.err"
[ ! -e "$session_dir/eci_active" ] && [ ! -L "$session_dir/eci_active" ]
[ ! -e "$receipt" ] && [ ! -L "$receipt" ]
grep -q '^ECI inactive\. Disengage report read:' "$TMP_ROOT/off-second.out"

printf '%s\n' 'eci normal off historical reconciliation assertions: PASS'
