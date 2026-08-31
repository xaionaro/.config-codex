#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-ledger-reconcile.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

proof_root="$TMP_ROOT/proof"
session_id=t00-ledger-reconcile
session_dir="$proof_root/$session_id"
cwd="$TMP_ROOT/repository"
log="$session_dir/high_level_log.md"
anchor="$session_dir/high_level_log.anchor"
mkdir -p -- "$session_dir" "$cwd"

run_current() {
  (
    cd -- "$cwd"
    CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
      "$ROOT/bin/eci-active" "$@"
  )
}

# A regular current-session log and malformed historical anchor are diagnostic
# residue. Starting normal work repairs the anchor rather than requiring a
# user recovery command or a matching hash receipt.
printf '%s\n' 'ordinary prior note' >"$log"
printf '%s\n' 'malformed historical anchor' >"$anchor"
run_current on 'ledger reconciliation fixture' >"$TMP_ROOT/on.out"
[ -f "$session_dir/eci_active" ] && [ ! -L "$session_dir/eci_active" ]
[ -f "$anchor" ] && [ ! -L "$anchor" ]
grep -Fqx 'schema: eci-high-level-log-anchor/v1' "$anchor"
grep -Fqx "session_id: $session_id" "$anchor"

# A regular direct marker that still maps to this session/CWD remains usable
# when harmless historic fields exceed the Stop callback's bounded-parser
# limit and canonical-CWD aliases are retained.
oversized_legacy_note="$(printf '%*s' 5000 '' | tr ' ' x)"
[ "${#oversized_legacy_note}" -gt 4096 ]
printf '%s\n' \
  "legacy_note: $oversized_legacy_note" \
  "session_id: $session_id" \
  "cwd: $cwd/." \
  >>"$session_dir/eci_active"
run_current ledger-append 'ordinary append with stale marker metadata' >"$TMP_ROOT/metadata-append.out"
grep -Fq 'ordinary append with stale marker metadata' "$log"

# The normal append path also repairs stale record formatting: a regular
# historical log without a final LF gains its separator before the ordinary
# entry. Neither old anchor grammar nor old line shape is admission.
printf '%s' 'unterminated historical note' >"$log"
printf '%s\n' 'another malformed anchor' >"$anchor"
run_current ledger-append 'ordinary append after stale anchor' >"$TMP_ROOT/append.out"
grep -Fq 'unterminated historical note' "$log"
grep -Fq 'ordinary append after stale anchor' "$log"
grep -Eq '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T.* ordinary append after stale anchor$' "$log"
grep -Fqx 'schema: eci-high-level-log-anchor/v1' "$anchor"

# An anchor symlink is an unsafe *anchor write* target, not an unsafe current
# log target.  Normal current-session work must leave it and its outside
# target untouched, emit an advisory, and continue with the regular log.
advisory_session=t00-ledger-anchor-advisory
advisory_dir="$proof_root/$advisory_session"
advisory_log="$advisory_dir/high_level_log.md"
advisory_anchor="$advisory_dir/high_level_log.anchor"
foreign="$TMP_ROOT/foreign-anchor"
mkdir -p -- "$advisory_dir"
printf '%s\n' 'ordinary log' >"$advisory_log"
printf '%s\n' sentinel >"$foreign"
ln -s -- "$foreign" "$advisory_anchor"
(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$advisory_session" \
    "$ROOT/bin/eci-active" on 'anchor advisory fixture'
) >"$TMP_ROOT/advisory-on.out" 2>"$TMP_ROOT/advisory-on.err"
[ -f "$advisory_dir/eci_active" ] && [ ! -L "$advisory_dir/eci_active" ]
[ -L "$advisory_anchor" ]
grep -Fqx sentinel "$foreign"
grep -Fq 'ECI advisory: high-level ledger anchor is a symlink; leaving it untouched while normal lifecycle work continues.' \
  "$TMP_ROOT/advisory-on.err"

(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$advisory_session" \
    "$ROOT/bin/eci-active" ledger-append 'ordinary append beside anchor symlink'
) >"$TMP_ROOT/advisory-append.out" 2>"$TMP_ROOT/advisory-append.err"
grep -Fq 'ordinary append beside anchor symlink' "$advisory_log"
[ -L "$advisory_anchor" ]
grep -Fqx sentinel "$foreign"
grep -Fq 'ECI advisory: high-level ledger anchor is a symlink; leaving it untouched while normal lifecycle work continues.' \
  "$TMP_ROOT/advisory-append.err"

# A nonregular anchor is likewise historical diagnostic residue. It must stay
# in place while a regular current-session log and marker remain usable.
directory_session=t00-ledger-anchor-directory
directory_dir="$proof_root/$directory_session"
directory_log="$directory_dir/high_level_log.md"
directory_anchor="$directory_dir/high_level_log.anchor"
mkdir -p -- "$directory_anchor"
printf '%s\n' 'ordinary directory-anchor log' >"$directory_log"
(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$directory_session" \
    "$ROOT/bin/eci-active" on 'directory anchor advisory fixture'
) >"$TMP_ROOT/directory-on.out" 2>"$TMP_ROOT/directory-on.err"
[ -f "$directory_dir/eci_active" ] && [ ! -L "$directory_dir/eci_active" ]
[ -d "$directory_anchor" ] && [ ! -L "$directory_anchor" ]
grep -Fq 'ECI advisory: high-level ledger anchor is not a regular file; leaving it untouched while normal lifecycle work continues.' \
  "$TMP_ROOT/directory-on.err"
(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$directory_session" \
    "$ROOT/bin/eci-active" ledger-append 'ordinary append beside anchor directory'
) >"$TMP_ROOT/directory-append.out" 2>"$TMP_ROOT/directory-append.err"
grep -Fq 'ordinary append beside anchor directory' "$directory_log"
[ -d "$directory_anchor" ] && [ ! -L "$directory_anchor" ]
grep -Fq 'ECI advisory: high-level ledger anchor is not a regular file; leaving it untouched while normal lifecycle work continues.' \
  "$TMP_ROOT/directory-append.err"

# A session-local log hard-linked to an external file must be detached before
# append. The external inode stays byte-for-byte unchanged while ordinary
# current-session logging continues on a new local inode.
hardlink_session=t00-ledger-hardlink
hardlink_dir="$proof_root/$hardlink_session"
hardlink_log="$hardlink_dir/high_level_log.md"
foreign_log="$TMP_ROOT/foreign-hardlinked-log.md"
mkdir -p -- "$hardlink_dir"
printf '%s\n' 'foreign log sentinel' >"$foreign_log"
cp -- "$foreign_log" "$TMP_ROOT/foreign-hardlinked-log.before"
ln -- "$foreign_log" "$hardlink_log"
(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$hardlink_session" \
    "$ROOT/bin/eci-active" on 'hard-link ledger fixture'
) >"$TMP_ROOT/hardlink-on.out"
[ "$(stat -c '%i' -- "$foreign_log")" = "$(stat -c '%i' -- "$hardlink_log")" ]
(
  cd -- "$cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$hardlink_session" \
    "$ROOT/bin/eci-active" ledger-append 'ordinary append after hard-link detachment'
) >"$TMP_ROOT/hardlink-append.out"
cmp -s -- "$TMP_ROOT/foreign-hardlinked-log.before" "$foreign_log"
[ "$(stat -c '%i' -- "$foreign_log")" != "$(stat -c '%i' -- "$hardlink_log")" ]
grep -Fq 'ordinary append after hard-link detachment' "$hardlink_log"

printf '%s\n' 'eci ledger reconciliation assertions: PASS'
