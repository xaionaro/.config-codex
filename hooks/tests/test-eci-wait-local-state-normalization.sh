#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="${ECI_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-wait-local-state.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

proof_root="$TMP_ROOT/proof"
repo="$TMP_ROOT/repo"
mkdir -p -- "$proof_root" "$repo"
proof_root="$(realpath -e -- "$proof_root")"
repo="$(realpath -e -- "$repo")"
proof_alias="$TMP_ROOT/proof-alias"
ln -s -- "$proof_root" "$proof_alias"

run_active() {
  local sid="$1"
  shift

  (
    cd -- "$repo"
    CODEX_SESSION_ID="$sid" CODEX_PROOF_ROOT="$proof_root" \
      "$ROOT/bin/eci-active" "$@"
  )
}

wait_report() {
  local path="$1"

  {
    printf '# ECI User-Owned Wait\n'
    printf 'state: user-owned-wait\n'
    printf 'blocker_id: local-state-normalization\n'
    printf 'state_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'owner: user\n'
    printf 'brp_result: exhausted-no-feasible-internal-path\n'
    printf 'user_owned_input: unobtainable\n'
    printf 'unblock_kind: input\n'
    printf 'unblock: local fixture is ready to resume\n'
  } >"$path"
}

stale_wait_files() {
  local sid="$1"
  local session_dir="$proof_root/$sid"

  printf '%s\n' 'legacy wait report whose historical hash/schema is stale' \
    >"$session_dir/eci_user_owned_wait.md"
  printf '%s\n' 'legacy wait state whose historical hash/schema is stale' \
    >"$session_dir/eci_wait"
}

write_legacy_peer_marker() {
  local peer_dir="$proof_root/activity"

  mkdir -p -- "$peer_dir"
  {
    printf '%s\n' 'scope: unrelated legacy peer'
    printf 'cwd: %s\n' "$repo"
    printf '%s\n' 'session_id: activity'
    printf '%s\n' 'created_utc: 2026-08-28T00:00:00Z'
  } >"$peer_dir/eci_active"
}

arm() {
  local sid="$1"

  run_active "$sid" on "local wait state normalization fixture" \
    >"$TMP_ROOT/$sid.on.out" 2>"$TMP_ROOT/$sid.on.err"
}

failures=0

expect_success() {
  local label="$1"
  shift

  if ! "$@" >"$TMP_ROOT/$label.out" 2>"$TMP_ROOT/$label.err"; then
    printf 'expected %s to succeed, but it failed:\n' "$label" >&2
    cat -- "$TMP_ROOT/$label.err" >&2
    failures=$((failures + 1))
  fi
}

# A new activation owns only its new direct marker. Regular local coordination
# residue is historical context, while unsafe residue must be left untouched.
activation_wait_sid=t00-on-stale-regular-wait
mkdir -p -- "$proof_root/$activation_wait_sid"
stale_wait_files "$activation_wait_sid"
expect_success on-stale-regular-wait \
  run_active "$activation_wait_sid" on 'fresh activation after stale local wait state'
[ -f "$proof_root/$activation_wait_sid/eci_active" ] && [ ! -L "$proof_root/$activation_wait_sid/eci_active" ] || {
  printf '%s\n' 'on did not create its direct marker after stale regular wait state' >&2
  failures=$((failures + 1))
}
[ ! -e "$proof_root/$activation_wait_sid/eci_wait" ] && [ ! -L "$proof_root/$activation_wait_sid/eci_wait" ] || {
  printf '%s\n' 'on left stale regular wait state behind' >&2
  failures=$((failures + 1))
}

activation_plan_sid=t00-on-stale-regular-plan
mkdir -p -- "$proof_root/$activation_plan_sid"
printf '%s\n' 'stale singleton/aggregate plan history' >"$proof_root/$activation_plan_sid/eci-aggregate-plan.json"
expect_success on-stale-regular-plan \
  run_active "$activation_plan_sid" on 'fresh activation after stale local aggregate plan'
[ -f "$proof_root/$activation_plan_sid/eci_active" ] && [ ! -L "$proof_root/$activation_plan_sid/eci_active" ] || {
  printf '%s\n' 'on did not create its direct marker after stale regular aggregate plan' >&2
  failures=$((failures + 1))
}
[ ! -e "$proof_root/$activation_plan_sid/eci-aggregate-plan.json" ] && [ ! -L "$proof_root/$activation_plan_sid/eci-aggregate-plan.json" ] || {
  printf '%s\n' 'on left stale regular aggregate plan behind' >&2
  failures=$((failures + 1))
}

activation_link_sid=t00-on-symlink-residue
activation_link_target="$TMP_ROOT/foreign-activation-residue"
mkdir -p -- "$proof_root/$activation_link_sid"
printf '%s\n' 'foreign residue must remain untouched' >"$activation_link_target"
ln -s -- "$activation_link_target" "$proof_root/$activation_link_sid/eci_wait"
expect_success on-symlink-residue \
  run_active "$activation_link_sid" on 'fresh activation beside symlink residue'
[ -L "$proof_root/$activation_link_sid/eci_wait" ] || {
  printf '%s\n' 'on replaced a symlinked local residue' >&2
  failures=$((failures + 1))
}
grep -Fqx 'foreign residue must remain untouched' "$activation_link_target" || {
  printf '%s\n' 'on changed a symlink residue destination' >&2
  failures=$((failures + 1))
}

activation_directory_sid=t00-on-directory-residue
mkdir -p -- "$proof_root/$activation_directory_sid/eci-aggregate-plan.json"
expect_success on-directory-residue \
  run_active "$activation_directory_sid" on 'fresh activation beside nonregular aggregate residue'
[ -d "$proof_root/$activation_directory_sid/eci-aggregate-plan.json" ] || {
  printf '%s\n' 'on changed a nonregular aggregate residue' >&2
  failures=$((failures + 1))
}

# A duplicate activation of the same current direct marker is idempotent. It
# must not rewrite or clear the active session's wait/aggregate state.
duplicate_on_sid=t00-on-current-marker
arm "$duplicate_on_sid"
stale_wait_files "$duplicate_on_sid"
printf '%s\n' 'current aggregate coordination state must remain untouched' \
  >"$proof_root/$duplicate_on_sid/eci-aggregate-plan.json"
expect_success duplicate-on \
  run_active "$duplicate_on_sid" on 'duplicate activation is an idempotent acknowledgement'
[ -f "$proof_root/$duplicate_on_sid/eci_active" ] && [ ! -L "$proof_root/$duplicate_on_sid/eci_active" ] || {
  printf '%s\n' 'duplicate on did not preserve the current direct marker' >&2
  failures=$((failures + 1))
}
[ -f "$proof_root/$duplicate_on_sid/eci_wait" ] && [ ! -L "$proof_root/$duplicate_on_sid/eci_wait" ] || {
  printf '%s\n' 'duplicate on changed an active session wait state' >&2
  failures=$((failures + 1))
}
grep -Fqx 'current aggregate coordination state must remain untouched' \
  "$proof_root/$duplicate_on_sid/eci-aggregate-plan.json" || {
  printf '%s\n' 'duplicate on changed an active session aggregate state' >&2
  failures=$((failures + 1))
}

# A stale but regular current-session state must not require an opaque
# fingerprint before the user can describe why work may resume.
resume_sid=t00-wait-local-resume
arm "$resume_sid"
stale_wait_files "$resume_sid"
expect_success resume \
  run_active "$resume_sid" resume 'the requested local device is reachable now'
[ ! -e "$proof_root/$resume_sid/eci_wait" ] && [ ! -L "$proof_root/$resume_sid/eci_wait" ] || {
  printf '%s\n' 'resume left stale regular wait state behind' >&2
  failures=$((failures + 1))
}

# The session/CWD mapping, rather than historical marker schema/order/extra
# metadata, is the direct lifecycle target. Conflicting mappings still fail.
metadata_sid=t00-semantic-marker-metadata
arm "$metadata_sid"
printf '%s\n' 'legacy_metadata: harmless historical context' >>"$proof_root/$metadata_sid/eci_active"
printf '%s\n' 'legacy report format is advisory' >"$proof_root/$metadata_sid/eci_user_owned_wait.md"
expect_success semantic-marker-wait \
  run_active "$metadata_sid" wait "$proof_root/$metadata_sid/eci_user_owned_wait.md"
expect_success semantic-marker-resume \
  run_active "$metadata_sid" resume 'semantic current marker remains bound here'
metadata_off_report="$proof_root/$metadata_sid/disengage.md"
printf '%s\n' 'semantic marker teardown fixture' >"$metadata_off_report"
expect_success semantic-marker-off run_active "$metadata_sid" off "$metadata_off_report"
[ ! -e "$proof_root/$metadata_sid/eci_active" ] && [ ! -L "$proof_root/$metadata_sid/eci_active" ] || {
  printf '%s\n' 'off retained a semantically current marker because of harmless metadata' >&2
  failures=$((failures + 1))
}

conflict_sid=t00-semantic-marker-conflict
arm "$conflict_sid"
mkdir -p -- "$TMP_ROOT/other-cwd"
printf 'cwd: %s\n' "$TMP_ROOT/other-cwd" >>"$proof_root/$conflict_sid/eci_active"
printf '%s\n' 'legacy report format is advisory' >"$proof_root/$conflict_sid/eci_user_owned_wait.md"
if run_active "$conflict_sid" wait "$proof_root/$conflict_sid/eci_user_owned_wait.md" \
  >"$TMP_ROOT/conflict-wait.out" 2>"$TMP_ROOT/conflict-wait.err"; then
  printf '%s\n' 'wait accepted a marker with conflicting cwd mappings' >&2
  failures=$((failures + 1))
fi
if run_active "$conflict_sid" on 'conflicting cwd marker must not be idempotent' \
  >"$TMP_ROOT/conflict-on.out" 2>"$TMP_ROOT/conflict-on.err"; then
  printf '%s\n' 'on accepted a marker with conflicting cwd mappings' >&2
  failures=$((failures + 1))
fi
[ ! -e "$proof_root/$conflict_sid/eci_wait" ] && [ ! -L "$proof_root/$conflict_sid/eci_wait" ] || {
  printf '%s\n' 'conflicting marker created a wait state' >&2
  failures=$((failures + 1))
}

conflict_session_sid=t00-semantic-marker-session-conflict
arm "$conflict_session_sid"
printf '%s\n' 'session_id: another-current-session' >>"$proof_root/$conflict_session_sid/eci_active"
printf '%s\n' 'legacy report format is advisory' >"$proof_root/$conflict_session_sid/eci_user_owned_wait.md"
if run_active "$conflict_session_sid" wait "$proof_root/$conflict_session_sid/eci_user_owned_wait.md" \
  >"$TMP_ROOT/conflict-session-wait.out" 2>"$TMP_ROOT/conflict-session-wait.err"; then
  printf '%s\n' 'wait accepted a marker with conflicting session mappings' >&2
  failures=$((failures + 1))
fi
if run_active "$conflict_session_sid" on 'conflicting session marker must not be idempotent' \
  >"$TMP_ROOT/conflict-session-on.out" 2>"$TMP_ROOT/conflict-session-on.err"; then
  printf '%s\n' 'on accepted a marker with conflicting session mappings' >&2
  failures=$((failures + 1))
fi
[ ! -e "$proof_root/$conflict_session_sid/eci_wait" ] && [ ! -L "$proof_root/$conflict_session_sid/eci_wait" ] || {
  printf '%s\n' 'conflicting session marker created a wait state' >&2
  failures=$((failures + 1))
}

# No-follow remains a concrete boundary: a symlink or nonregular direct marker
# is never treated as the current session target, even though stale regular
# metadata itself is advisory.
marker_link_sid=t00-semantic-marker-symlink
arm "$marker_link_sid"
marker_link_target="$TMP_ROOT/foreign-direct-marker"
printf '%s\n' 'foreign direct marker must remain untouched' >"$marker_link_target"
rm -f -- "$proof_root/$marker_link_sid/eci_active"
ln -s -- "$marker_link_target" "$proof_root/$marker_link_sid/eci_active"
printf '%s\n' 'legacy report format is advisory' >"$proof_root/$marker_link_sid/eci_user_owned_wait.md"
if run_active "$marker_link_sid" wait "$proof_root/$marker_link_sid/eci_user_owned_wait.md" \
  >"$TMP_ROOT/symlink-marker-wait.out" 2>"$TMP_ROOT/symlink-marker-wait.err"; then
  printf '%s\n' 'wait accepted a symlinked direct marker' >&2
  failures=$((failures + 1))
fi
if run_active "$marker_link_sid" on 'symlinked direct marker must not be idempotent' \
  >"$TMP_ROOT/symlink-marker-on.out" 2>"$TMP_ROOT/symlink-marker-on.err"; then
  printf '%s\n' 'on accepted a symlinked direct marker' >&2
  failures=$((failures + 1))
fi
[ -L "$proof_root/$marker_link_sid/eci_active" ] || {
  printf '%s\n' 'wait replaced a symlinked direct marker' >&2
  failures=$((failures + 1))
}
grep -Fqx 'foreign direct marker must remain untouched' "$marker_link_target" || {
  printf '%s\n' 'wait changed the symlinked direct marker destination' >&2
  failures=$((failures + 1))
}

marker_directory_sid=t00-semantic-marker-directory
arm "$marker_directory_sid"
rm -f -- "$proof_root/$marker_directory_sid/eci_active"
mkdir -- "$proof_root/$marker_directory_sid/eci_active"
printf '%s\n' 'legacy report format is advisory' >"$proof_root/$marker_directory_sid/eci_user_owned_wait.md"
if run_active "$marker_directory_sid" wait "$proof_root/$marker_directory_sid/eci_user_owned_wait.md" \
  >"$TMP_ROOT/directory-marker-wait.out" 2>"$TMP_ROOT/directory-marker-wait.err"; then
  printf '%s\n' 'wait accepted a nonregular direct marker' >&2
  failures=$((failures + 1))
fi
if run_active "$marker_directory_sid" on 'nonregular direct marker must not be idempotent' \
  >"$TMP_ROOT/directory-marker-on.out" 2>"$TMP_ROOT/directory-marker-on.err"; then
  printf '%s\n' 'on accepted a nonregular direct marker' >&2
  failures=$((failures + 1))
fi
[ -d "$proof_root/$marker_directory_sid/eci_active" ] || {
  printf '%s\n' 'wait changed a nonregular direct marker' >&2
  failures=$((failures + 1))
}

# A stale regular state may not make a fresh valid wait report fail merely
# because a historical state file already exists. A parent-directory alias
# resolving to this same current-session report is also not a new target.
wait_sid=t00-wait-local-wait
arm "$wait_sid"
stale_wait_files "$wait_sid"
wait_report "$proof_root/$wait_sid/eci_user_owned_wait.md"
cp -- "$proof_root/$wait_sid/eci_user_owned_wait.md" "$TMP_ROOT/$wait_sid.wait-report.before"
expect_success wait \
  run_active "$wait_sid" wait "$proof_alias/$wait_sid/eci_user_owned_wait.md"
cmp -s -- "$TMP_ROOT/$wait_sid.wait-report.before" "$proof_root/$wait_sid/eci_user_owned_wait.md" || {
  printf '%s\n' 'wait changed the source-alias report that resolves to its fixed destination' >&2
  failures=$((failures + 1))
}
[ -f "$proof_root/$wait_sid/eci_wait" ] && [ ! -L "$proof_root/$wait_sid/eci_wait" ] || {
  printf '%s\n' 'wait did not publish a current regular wait state' >&2
  failures=$((failures + 1))
}

# Repairing a stale local report/state pair must reconcile the residue rather
# than turn historical parser/hash drift into a lifecycle deadlock.
repair_sid=t00-wait-local-repair
arm "$repair_sid"
stale_wait_files "$repair_sid"
expect_success wait-repair \
  run_active "$repair_sid" wait-repair "$proof_root/$repair_sid/eci_user_owned_wait.md"
[ ! -e "$proof_root/$repair_sid/eci_wait" ] && [ ! -L "$proof_root/$repair_sid/eci_wait" ] || {
  printf '%s\n' 'wait-repair left stale regular wait state armed' >&2
  failures=$((failures + 1))
}

# A normal teardown owns the current session and must clear regular stale
# wait residue before it validates its ordinary current disengage report.
off_sid=t00-wait-local-off
arm "$off_sid"
stale_wait_files "$off_sid"
write_legacy_peer_marker
off_report="$proof_root/$off_sid/disengage.md"
printf '%s\n' 'Normal work completed; stale local wait metadata was reconciled.' >"$off_report"
expect_success off run_active "$off_sid" off "$off_report"
[ ! -e "$proof_root/$off_sid/eci_active" ] && [ ! -L "$proof_root/$off_sid/eci_active" ] || {
  printf '%s\n' 'off left the active marker behind after regular stale wait cleanup' >&2
  failures=$((failures + 1))
}
[ ! -e "$proof_root/$off_sid/eci_wait" ] && [ ! -L "$proof_root/$off_sid/eci_wait" ] || {
  printf '%s\n' 'off left stale regular wait state behind' >&2
  failures=$((failures + 1))
}
[ -f "$proof_root/activity/eci_active" ] && [ ! -L "$proof_root/activity/eci_active" ] || {
  printf '%s\n' 'off removed an unrelated same-CWD legacy peer marker' >&2
  failures=$((failures + 1))
}

# A symlink is not historical format drift. The lifecycle must leave both its
# destination and active marker untouched rather than following or replacing it.
unsafe_sid=t00-wait-local-unsafe
arm "$unsafe_sid"
unsafe_target="$TMP_ROOT/outside-wait-state"
printf '%s\n' 'outside state must not be followed' >"$unsafe_target"
ln -s -- "$unsafe_target" "$proof_root/$unsafe_sid/eci_wait"
if run_active "$unsafe_sid" resume 'the requested local device is reachable now' \
  >"$TMP_ROOT/unsafe-resume.out" 2>"$TMP_ROOT/unsafe-resume.err"; then
  printf '%s\n' 'resume followed or accepted a symlinked wait state' >&2
  failures=$((failures + 1))
fi
grep -Fqx 'outside state must not be followed' "$unsafe_target" || {
  printf '%s\n' 'resume changed the symlink destination' >&2
  failures=$((failures + 1))
}
[ -f "$proof_root/$unsafe_sid/eci_active" ] && [ ! -L "$proof_root/$unsafe_sid/eci_active" ] || {
  printf '%s\n' 'unsafe wait state unexpectedly tore down the active marker' >&2
  failures=$((failures + 1))
}

# A nonregular local state is likewise never removed as if it were historical
# text, and an outside report cannot be substituted for this session's report.
directory_sid=t00-wait-local-directory
arm "$directory_sid"
mkdir -- "$proof_root/$directory_sid/eci_wait"
if run_active "$directory_sid" resume 'the requested local device is reachable now' \
  >"$TMP_ROOT/directory-resume.out" 2>"$TMP_ROOT/directory-resume.err"; then
  printf '%s\n' 'resume accepted a nonregular wait state' >&2
  failures=$((failures + 1))
fi
[ -d "$proof_root/$directory_sid/eci_wait" ] || {
  printf '%s\n' 'resume changed the nonregular wait state target' >&2
  failures=$((failures + 1))
}

# An ordinary readable report may live anywhere. Wait imports it into the
# fixed current-session destination instead of treating its source location as
# a target selector.
outside_sid=t00-wait-local-outside
outside_dir="$proof_root/$outside_sid"
arm "$outside_sid"
outside_report="$TMP_ROOT/outside-wait.md"
wait_report "$outside_report"
expect_success outside-wait run_active "$outside_sid" wait "$outside_report"
[ -f "$outside_dir/eci_wait" ] && [ ! -L "$outside_dir/eci_wait" ] || {
  printf '%s\n' 'outside report did not create a local current wait state' >&2
  failures=$((failures + 1))
}
cmp -s -- "$outside_report" "$outside_dir/eci_user_owned_wait.md" || {
  printf '%s\n' 'outside report was not imported byte-for-byte to the local wait destination' >&2
  failures=$((failures + 1))
}

# A final source symlink is ordinary read-only input. It is resolved once and
# copied into the fixed local report destination without changing its target.
unsafe_source_sid=t00-wait-local-source-link
unsafe_source_target="$TMP_ROOT/foreign-wait-report-source"
unsafe_source_link="$TMP_ROOT/foreign-wait-report-source-link"
arm "$unsafe_source_sid"
wait_report "$unsafe_source_target"
ln -s -- "$unsafe_source_target" "$unsafe_source_link"
expect_success symlink-source-wait run_active "$unsafe_source_sid" wait "$unsafe_source_link"
[ -f "$proof_root/$unsafe_source_sid/eci_user_owned_wait.md" ] &&
  [ ! -L "$proof_root/$unsafe_source_sid/eci_user_owned_wait.md" ] || {
  printf '%s\n' 'symlinked source did not create a local report copy' >&2
  failures=$((failures + 1))
}
cmp -s -- "$unsafe_source_target" "$proof_root/$unsafe_source_sid/eci_user_owned_wait.md" || {
  printf '%s\n' 'symlinked source bytes were not copied to the fixed local report destination' >&2
  failures=$((failures + 1))
}
grep -Fqx '# ECI User-Owned Wait' "$unsafe_source_target" || {
  printf '%s\n' 'wait changed the foreign symlink-source target' >&2
  failures=$((failures + 1))
}

unsafe_destination_sid=t00-wait-local-report-destination-link
unsafe_destination_target="$TMP_ROOT/foreign-wait-report-destination"
arm "$unsafe_destination_sid"
printf '%s\n' 'foreign wait report destination' >"$unsafe_destination_target"
ln -s -- "$unsafe_destination_target" \
  "$proof_root/$unsafe_destination_sid/eci_user_owned_wait.md"
if run_active "$unsafe_destination_sid" wait "$outside_report" \
  >"$TMP_ROOT/unsafe-destination-wait.out" 2>"$TMP_ROOT/unsafe-destination-wait.err"; then
  printf '%s\n' 'wait replaced a symlinked local report destination' >&2
  failures=$((failures + 1))
fi
[ -L "$proof_root/$unsafe_destination_sid/eci_user_owned_wait.md" ] || {
  printf '%s\n' 'wait changed the symlinked local report destination' >&2
  failures=$((failures + 1))
}
grep -Fqx 'foreign wait report destination' "$unsafe_destination_target" || {
  printf '%s\n' 'wait changed the foreign report destination bytes' >&2
  failures=$((failures + 1))
}

nonregular_destination_sid=t00-wait-local-report-destination-node
arm "$nonregular_destination_sid"
mkdir "$proof_root/$nonregular_destination_sid/eci_user_owned_wait.md"
if run_active "$nonregular_destination_sid" wait "$outside_report" \
  >"$TMP_ROOT/nonregular-destination-wait.out" 2>"$TMP_ROOT/nonregular-destination-wait.err"; then
  printf '%s\n' 'wait replaced a nonregular local report destination' >&2
  failures=$((failures + 1))
fi
[ -d "$proof_root/$nonregular_destination_sid/eci_user_owned_wait.md" ] || {
  printf '%s\n' 'wait changed the nonregular local report destination' >&2
  failures=$((failures + 1))
}

[ "$failures" -eq 0 ] || exit 1
printf '%s\n' 'eci wait local-state normalization: PASS'
