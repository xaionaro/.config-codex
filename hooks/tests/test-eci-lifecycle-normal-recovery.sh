#!/usr/bin/env bash

# R11 normal lifecycle recovery: current resolved targets, not historical
# marker/source/receipt ceremony, decide whether ordinary work can proceed.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(realpath -e -- "$(mktemp -d "$TMP_PARENT/eci-normal-recovery.XXXXXX")")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

proof_root="$TMP_ROOT/proof"
cwd="$TMP_ROOT/work"
outer="$TMP_ROOT/outer"
repo="$outer/member"
mkdir -p -- "$proof_root" "$cwd" "$repo"

git -C "$repo" init -q
git -C "$repo" config user.name 'ECI normal recovery test'
git -C "$repo" config user.email 'eci-normal-recovery@example.invalid'
printf '%s\n' baseline >"$repo/tracked.txt"
git -C "$repo" add -- tracked.txt
git -C "$repo" commit -qm baseline

run_active() {
  local sid="$1" workdir="$2"
  shift 2

  (
    cd -- "$workdir"
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$sid" \
      TMPDIR="$TMP_ROOT" "$ROOT/bin/eci-active" "$@"
  )
}

arm_hardlinked_marker() {
  local sid="$1" workdir="$2" foreign="$3" extra_links="${4:-0}"
  local marker="$proof_root/$sid/eci_active" oversized link_index

  run_active "$sid" "$workdir" on 'ordinary hard-linked marker fixture' >/dev/null
  hardlink_current_marker "$sid" "$foreign" "$extra_links"
}

hardlink_current_marker() {
  local sid="$1" foreign="$2" extra_links="${3:-0}"
  local marker="$proof_root/$sid/eci_active" oversized link_index

  oversized="$(head -c 5120 </dev/zero | tr '\000' x)"
  cp -- "$marker" "$foreign"
  printf 'legacy_note: %s\n' "$oversized" >>"$foreign"
  cp -- "$foreign" "$foreign.before"
  rm -f -- "$marker"
  ln -- "$foreign" "$marker"
  for ((link_index = 1; link_index <= extra_links; link_index++)); do
    ln -- "$foreign" "$foreign.extra.$link_index"
  done
  [ "$(stat -c '%i' -- "$foreign")" = "$(stat -c '%i' -- "$marker")" ]
  [ "$(wc -c <"$marker")" -gt 4096 ]
}

assert_foreign_marker_preserved_and_rehomed() {
  local sid="$1" foreign="$2"
  local marker="$proof_root/$sid/eci_active"

  cmp -s -- "$foreign.before" "$foreign"
  [ "$(stat -c '%i' -- "$foreign")" != "$(stat -c '%i' -- "$marker")" ]
  [ "$(stat -c '%h' -- "$marker")" -eq 1 ]
}

# A large harmless historical marker record is still a regular direct marker
# for this session/CWD. Status must retain compact visibility, while the first
# ordinary mutation safely rehomes the session directory entry before copying
# an arbitrary readable singleton manifest.
singleton_sid=normal-recovery-singleton
singleton_dir="$proof_root/$singleton_sid"
singleton_foreign="$TMP_ROOT/foreign-singleton-marker"
singleton_source="$TMP_ROOT/ordinary singleton manifest.txt"
printf '%s\n%s\n' 'arbitrary readable manifest bytes' 'not a canonical JSON receipt' >"$singleton_source"
arm_hardlinked_marker "$singleton_sid" "$cwd" "$singleton_foreign"
run_active "$singleton_sid" "$cwd" status >"$TMP_ROOT/singleton-status.out"
grep -Fqx "session_id: $singleton_sid" "$TMP_ROOT/singleton-status.out"
[ "$(wc -c <"$TMP_ROOT/singleton-status.out")" -lt 1024 ]
run_active "$singleton_sid" "$cwd" manifest-write "$singleton_source"
cmp -s -- "$singleton_source" "$singleton_dir/eci-required-critics.json"
assert_foreign_marker_preserved_and_rehomed "$singleton_sid" "$singleton_foreign"

# Rehoming must not accidentally turn a larger valid hard-link count into a
# normal-work denial. The source inode and all foreign aliases remain intact;
# only the current session directory entry is replaced.
many_links_sid=normal-recovery-many-links
many_links_dir="$proof_root/$many_links_sid"
many_links_foreign="$TMP_ROOT/foreign-many-links-marker"
arm_hardlinked_marker "$many_links_sid" "$cwd" "$many_links_foreign" 9
[ "$(stat -c '%h' -- "$many_links_foreign")" -eq 11 ]
run_active "$many_links_sid" "$cwd" manifest-write "$singleton_source"
cmp -s -- "$many_links_foreign.before" "$many_links_foreign"
[ "$(stat -c '%h' -- "$many_links_foreign")" -eq 10 ]
[ "$(stat -c '%h' -- "$many_links_dir/eci_active")" -eq 1 ]

# The same semantic direct marker must allow local nested lifecycle recovery;
# stale regular local nested records are history, not a reason to reject the
# next active state, while the foreign hard-linked marker inode remains intact.
nested_sid=normal-recovery-nested
nested_dir="$proof_root/$nested_sid"
nested_foreign="$TMP_ROOT/foreign-nested-marker"
arm_hardlinked_marker "$nested_sid" "$cwd" "$nested_foreign"
printf '%s\n' 'stale nested active record' >"$nested_dir/ate_nested_eci_active"
printf '%s\n' 'stale nested completion record' >"$nested_dir/ate_nested_eci_completion"
run_active "$nested_sid" "$cwd" nested-enter 1 1
[ -f "$nested_dir/ate_nested_eci_active" ] && [ ! -L "$nested_dir/ate_nested_eci_active" ]
run_active "$nested_sid" "$cwd" nested-accept
[ -f "$nested_dir/ate_nested_eci_completion" ] && [ ! -L "$nested_dir/ate_nested_eci_completion" ]
printf '%s\n' 'stale nested completion after acceptance' >"$nested_dir/ate_nested_eci_completion"
run_active "$nested_sid" "$cwd" nested-exit
[ ! -e "$nested_dir/ate_nested_eci_active" ] && [ ! -L "$nested_dir/ate_nested_eci_active" ]
assert_foreign_marker_preserved_and_rehomed "$nested_sid" "$nested_foreign"

# Completion records are historical residue. A symlink or nonregular entry is
# never followed or replaced, but it also cannot strand a safe active marker.
nested_link_sid=normal-recovery-nested-link
nested_link_dir="$proof_root/$nested_link_sid"
nested_link_target="$TMP_ROOT/foreign-nested-completion"
printf '%s\n' 'foreign nested completion' >"$nested_link_target"
run_active "$nested_link_sid" "$cwd" on 'nested completion link fixture' >/dev/null
ln -s -- "$nested_link_target" "$nested_link_dir/ate_nested_eci_completion"
run_active "$nested_link_sid" "$cwd" nested-enter 1 1 \
  >"$TMP_ROOT/nested-link.out" 2>"$TMP_ROOT/nested-link.err"
[ -f "$nested_link_dir/ate_nested_eci_active" ] && [ ! -L "$nested_link_dir/ate_nested_eci_active" ]
[ -L "$nested_link_dir/ate_nested_eci_completion" ]
grep -Fqx 'foreign nested completion' "$nested_link_target"
grep -Fq 'ECI advisory: preserved unusual nested completion history' "$TMP_ROOT/nested-link.err"

nested_node_sid=normal-recovery-nested-node
nested_node_dir="$proof_root/$nested_node_sid"
run_active "$nested_node_sid" "$cwd" on 'nested completion node fixture' >/dev/null
mkdir -- "$nested_node_dir/ate_nested_eci_completion"
run_active "$nested_node_sid" "$cwd" nested-enter 1 1 \
  >"$TMP_ROOT/nested-node.out" 2>"$TMP_ROOT/nested-node.err"
[ -f "$nested_node_dir/ate_nested_eci_active" ] && [ ! -L "$nested_node_dir/ate_nested_eci_active" ]
[ -d "$nested_node_dir/ate_nested_eci_completion" ] && [ ! -L "$nested_node_dir/ate_nested_eci_completion" ]
grep -Fq 'ECI advisory: preserved unusual nested completion history' "$TMP_ROOT/nested-node.err"

# Aggregate migration must likewise rehome the parent marker and accept an
# ordinary plan larger than the obsolete 16 KiB source cap. The selected live
# repository remains the actual publication target for an arbitrary manifest.
aggregate_sid=normal-recovery-aggregate
aggregate_dir="$proof_root/$aggregate_sid"
aggregate_foreign="$TMP_ROOT/foreign-aggregate-marker"
aggregate_plan="$TMP_ROOT/ordinary large aggregate plan.json"
aggregate_manifest="$TMP_ROOT/ordinary aggregate manifest.txt"
aggregate_filler_file="$TMP_ROOT/ordinary-large-aggregate-filler"
head -c 1049600 </dev/zero | tr '\000' x >"$aggregate_filler_file"
jq -n --arg repo "$repo" --rawfile filler "$aggregate_filler_file" \
  '{historic_note:$filler,repositories:[{id:"member",repo_root:$repo}]}' >"$aggregate_plan"
[ "$(wc -c <"$aggregate_plan")" -gt 1048576 ]
printf '%s\n%s\n' 'aggregate arbitrary manifest bytes' 'not a canonical review schema' >"$aggregate_manifest"
arm_hardlinked_marker "$aggregate_sid" "$outer" "$aggregate_foreign"
run_active "$aggregate_sid" "$outer" aggregate-migrate "$aggregate_plan"
assert_foreign_marker_preserved_and_rehomed "$aggregate_sid" "$aggregate_foreign"
run_active "$aggregate_sid" "$repo" aggregate-manifest-write member "$aggregate_manifest"
cmp -s -- "$aggregate_manifest" "$aggregate_dir/eci-aggregate.member.required-critics.json"

# Aggregate Git publication also rehomes a newly hard-linked parent marker,
# then revalidates its selected child repository before using Git.
aggregate_commit_foreign="$TMP_ROOT/foreign-aggregate-commit-marker"
aggregate_message="$TMP_ROOT/ordinary aggregate commit message.txt"
printf '%s\n' 'aggregate staged content' >>"$repo/tracked.txt"
run_active "$aggregate_sid" "$repo" aggregate-stage member -- tracked.txt
printf '%s\n' 'ordinary aggregate commit text' >"$aggregate_message"
hardlink_current_marker "$aggregate_sid" "$aggregate_commit_foreign"
run_active "$aggregate_sid" "$repo" aggregate-commit member "$aggregate_message"
assert_foreign_marker_preserved_and_rehomed "$aggregate_sid" "$aggregate_commit_foreign"

# Wait imports a readable regular user report into its fixed session location
# rather than treating the input pathname or historical report grammar as a
# target selector. Resume and ledger append accept ordinary multiline context.
text_sid=normal-recovery-text
text_dir="$proof_root/$text_sid"
wait_source="$TMP_ROOT/ordinary external wait report.md"
long_scope="$(head -c 5200 </dev/zero | tr '\000' x)"$'\nsecond scope line'
multiline_entry=$'first historical line\nsecond historical line'
multiline_resume=$'resumed after a local change\nwith ordinary detail'
printf '%s\n%s\n' 'arbitrary external wait report' 'with historical free-form notes' >"$wait_source"
run_active "$text_sid" "$cwd" on "$long_scope"
run_active "$text_sid" "$cwd" ledger-append "$multiline_entry"
grep -Fq 'first historical line' "$text_dir/high_level_log.md"
grep -Fq 'second historical line' "$text_dir/high_level_log.md"
run_active "$text_sid" "$cwd" wait "$wait_source"
cmp -s -- "$wait_source" "$text_dir/eci_user_owned_wait.md"
[ -f "$text_dir/eci_wait" ] && [ ! -L "$text_dir/eci_wait" ]
run_active "$text_sid" "$cwd" resume "$multiline_resume"
[ ! -e "$text_dir/eci_wait" ] && [ ! -L "$text_dir/eci_wait" ]

# Ordinary session lifecycle visibility must use the semantic marker reader
# too. A benign historical note cannot make permissive current-session state
# disappear after it was created.
permissive_sid=normal-recovery-permissive
permissive_dir="$proof_root/$permissive_sid"
permissive_marker="$permissive_dir/eci_active"
permissive_note="$(head -c 5120 </dev/zero | tr '\000' x)"
run_active "$permissive_sid" "$cwd" on 'permissive marker fixture' >/dev/null
printf 'legacy_note: %s\n' "$permissive_note" >>"$permissive_marker"
run_active "$permissive_sid" "$cwd" permissive-on session lifecycle ordinary-work 'ordinary local visibility' 60
grep -Fqx 'ECI permissive mode active' \
  < <(run_active "$permissive_sid" "$cwd" permissive-status session lifecycle ordinary-work 'ordinary local visibility')

# Read-only source aliases are ordinary input, while fixed destinations remain
# no-follow boundaries that cannot be followed or replaced by the importer.
unsafe_wait_sid=normal-recovery-wait-unsafe
unsafe_wait_dir="$proof_root/$unsafe_wait_sid"
unsafe_source_target="$TMP_ROOT/foreign-wait-source"
unsafe_source_link="$TMP_ROOT/unsafe-wait-source-link"
printf '%s\n' 'foreign wait source bytes' >"$unsafe_source_target"
ln -s -- "$unsafe_source_target" "$unsafe_source_link"
run_active "$unsafe_wait_sid" "$cwd" on 'unsafe wait source fixture' >/dev/null
run_active "$unsafe_wait_sid" "$cwd" wait "$unsafe_source_link"
cmp -s -- "$unsafe_source_target" "$unsafe_wait_dir/eci_user_owned_wait.md"
[ -f "$unsafe_wait_dir/eci_wait" ] && [ ! -L "$unsafe_wait_dir/eci_wait" ]
grep -Fqx 'foreign wait source bytes' "$unsafe_source_target"

unsafe_dest_sid=normal-recovery-destination-unsafe
unsafe_dest_dir="$proof_root/$unsafe_dest_sid"
unsafe_dest_target="$TMP_ROOT/foreign-fixed-destination"
printf '%s\n' 'foreign destination bytes' >"$unsafe_dest_target"
run_active "$unsafe_dest_sid" "$cwd" on 'unsafe destination fixture' >/dev/null
ln -s -- "$unsafe_dest_target" "$unsafe_dest_dir/eci_user_owned_wait.md"
if run_active "$unsafe_dest_sid" "$cwd" wait "$wait_source"; then
  printf '%s\n' 'wait replaced a symlinked fixed destination' >&2
  exit 1
fi
[ -L "$unsafe_dest_dir/eci_user_owned_wait.md" ]
grep -Fqx 'foreign destination bytes' "$unsafe_dest_target"

unsafe_manifest_sid=normal-recovery-manifest-unsafe
unsafe_manifest_dir="$proof_root/$unsafe_manifest_sid"
unsafe_manifest_target="$TMP_ROOT/foreign-manifest-destination"
printf '%s\n' 'foreign manifest destination bytes' >"$unsafe_manifest_target"
run_active "$unsafe_manifest_sid" "$cwd" on 'unsafe manifest destination fixture' >/dev/null
ln -s -- "$unsafe_manifest_target" "$unsafe_manifest_dir/eci-required-critics.json"
if run_active "$unsafe_manifest_sid" "$cwd" manifest-write "$singleton_source"; then
  printf '%s\n' 'manifest-write replaced a symlinked fixed destination' >&2
  exit 1
fi
[ -L "$unsafe_manifest_dir/eci-required-critics.json" ]
grep -Fqx 'foreign manifest destination bytes' "$unsafe_manifest_target"

# Off must clear the validated direct marker even when stale regular
# user-closed history and a nonregular prewrite residue remain advisory.
off_sid=normal-recovery-off
off_dir="$proof_root/$off_sid"
off_report="$TMP_ROOT/ordinary disengage report.md"
printf '%s\n' 'ordinary report; historical receipt wording is advisory' >"$off_report"
run_active "$off_sid" "$cwd" on 'off reconciliation fixture' >/dev/null
printf '%s\n' 'stale regular user-closed history' >"$off_dir/eci-user-closed.ledger"
mkdir "$off_dir/eci-prewrite-admitted.stale"
run_active "$off_sid" "$cwd" off "$off_report"
[ ! -e "$off_dir/eci_active" ] && [ ! -L "$off_dir/eci_active" ]
[ -d "$off_dir/eci-prewrite-admitted.stale" ]

# Direct marker semantic conflicts and unsafe final objects are still concrete
# target failures; their foreign or unusual targets must be preserved.
conflict_sid=normal-recovery-marker-conflict
conflict_dir="$proof_root/$conflict_sid"
run_active "$conflict_sid" "$cwd" on 'conflicting marker fixture' >/dev/null
mkdir -p "$TMP_ROOT/other-cwd"
printf 'cwd: %s\n' "$TMP_ROOT/other-cwd" >>"$conflict_dir/eci_active"
if run_active "$conflict_sid" "$cwd" manifest-write "$singleton_source"; then
  printf '%s\n' 'manifest-write accepted conflicting current marker cwd mappings' >&2
  exit 1
fi

marker_link_sid=normal-recovery-marker-link
marker_link_dir="$proof_root/$marker_link_sid"
marker_link_target="$TMP_ROOT/foreign-direct-marker"
printf '%s\n' 'foreign marker bytes' >"$marker_link_target"
run_active "$marker_link_sid" "$cwd" on 'symlink direct marker fixture' >/dev/null
rm -f -- "$marker_link_dir/eci_active"
ln -s -- "$marker_link_target" "$marker_link_dir/eci_active"
if run_active "$marker_link_sid" "$cwd" manifest-write "$singleton_source"; then
  printf '%s\n' 'manifest-write followed a symlinked direct marker' >&2
  exit 1
fi
[ -L "$marker_link_dir/eci_active" ]
grep -Fqx 'foreign marker bytes' "$marker_link_target"

marker_node_sid=normal-recovery-marker-node
marker_node_dir="$proof_root/$marker_node_sid"
run_active "$marker_node_sid" "$cwd" on 'nonregular direct marker fixture' >/dev/null
rm -f -- "$marker_node_dir/eci_active"
mkdir "$marker_node_dir/eci_active"
if run_active "$marker_node_sid" "$cwd" manifest-write "$singleton_source"; then
  printf '%s\n' 'manifest-write accepted a nonregular direct marker' >&2
  exit 1
fi
[ -d "$marker_node_dir/eci_active" ]

printf '%s\n' 'ECI normal lifecycle recovery: PASS'
