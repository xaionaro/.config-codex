#!/usr/bin/env bash

# R11 aggregate lifecycle regressions: selected concrete repository targets
# matter; caller role, duplicate identical marker metadata, plan retry
# residue, and ordinary child-CWD spelling do not.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(realpath -e -- "$(mktemp -d "$TMP_PARENT/eci-aggregate-selected-target.XXXXXX")")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

proof_root="$TMP_ROOT/proof"
outer_cwd="$TMP_ROOT/outer"
repo_a="$outer_cwd/repo-a"
repo_b="$outer_cwd/repo-b"
plan_a="$TMP_ROOT/friendly-plan-a.json"
plan_b="$TMP_ROOT/friendly-plan-b.json"
plan_main="$TMP_ROOT/friendly-plan-main.json"
message="$TMP_ROOT/ordinary-message.txt"
report="$TMP_ROOT/ordinary-close.md"

mkdir -p -- "$proof_root" "$repo_a" "$repo_b"
for repo in "$repo_a" "$repo_b"; do
  git -C "$repo" init -q
  git -C "$repo" config user.name 'ECI aggregate selected-target test'
  git -C "$repo" config user.email 'eci-aggregate-selected-target@example.invalid'
  printf '%s\n' baseline >"$repo/tracked.txt"
  git -C "$repo" add -- tracked.txt
  git -C "$repo" commit -qm baseline
done

jq -n --arg repo "$repo_a" \
  '{purpose:"ordinary aggregate retry",repositories:[{id:"repo-a",repo_root:$repo}]}' >"$plan_a"
jq -n --arg repo "$repo_b" \
  '{purpose:"conflicting selected target",repositories:[{id:"repo-b",repo_root:$repo}]}' >"$plan_b"
jq -n --arg repo_a "$repo_a" --arg repo_b "$repo_b" \
  '{purpose:"selected child target fixture",repositories:[{id:"repo-a",repo_root:$repo_a},{id:"repo-b",repo_root:$repo_b}]}' >"$plan_main"
printf '%s' 'selected child aggregate commit' >"$message"
printf '%s\n' '# ordinary aggregate close' >"$report"

run_active_as() {
  local session_id="$1" cwd="$2" role="$3"
  shift 3

  (
    cd -- "$cwd"
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
      CODEX_ROLE="$role" TMPDIR="$TMP_ROOT" "$ROOT/bin/eci-active" "$@"
  )
}

main_session='aggregate-selected-target-main'
main_dir="$proof_root/$main_session"
run_active_as "$main_session" "$outer_cwd" coordinator on 'aggregate selected target fixture' >/dev/null
run_active_as "$main_session" "$outer_cwd" worker aggregate-migrate "$plan_main" >/dev/null

# A stale but semantically identical regular plan is current-session history.
# A retry must normalize it rather than requiring manual deletion.
plan_path="$main_dir/eci-aggregate-plan.json"
# Aggregate migration and selected-target paths must use the semantic
# session/CWD mapping even when a harmless historic marker field exceeds the
# Stop callback parser bound.
oversized_legacy_note="$(printf '%*s' 5000 '' | tr ' ' x)"
[ "${#oversized_legacy_note}" -gt 4096 ]
printf 'legacy_note: %s\n' "$oversized_legacy_note" >>"$main_dir/eci_active"
jq '.legacy_retry_note = "regular stale plan metadata"' "$plan_path" >"$plan_path.tmp"
mv -- "$plan_path.tmp" "$plan_path"
run_active_as "$main_session" "$outer_cwd" worker aggregate-migrate "$plan_main"
jq -e 'has("legacy_retry_note") | not' "$plan_path" >/dev/null

# A malformed regular current-session plan is stale coordination residue. A
# retry must reconcile just this session path from the validated request.
printf '%s\n' 'malformed stale aggregate plan' >"$plan_path"
run_active_as "$main_session" "$outer_cwd" worker aggregate-migrate "$plan_main"
jq -e --arg repo_a "$repo_a" --arg repo_b "$repo_b" '
  [.repositories[].repo_root] == [$repo_a, $repo_b]
' "$plan_path" >/dev/null

# Identical duplicate identity fields and canonical-CWD aliases are benign
# historic metadata; they must not invalidate the semantic selected target.
printf 'session_id: %s\ncwd: %s/.\n' "$main_session" "$outer_cwd" >>"$main_dir/eci_active"
if ! (
  export CODEX_PROOF_ROOT="$proof_root"
  source "$ROOT/hooks/lib/codex-proof-state.sh"
  [ "$(codex_eci_aggregate_marker_cwd "$main_dir/eci_active" "$main_session")" = "$outer_cwd" ]
); then
  printf '%s\n' 'aggregate marker reader rejected equivalent duplicate cwd metadata' >&2
  exit 1
fi

# Role routing is not a selected-target boundary. A readable manifest is
# copied to the fixed selected-session destination even when its historical
# bytes are not a review schema; the later review probe requests fresh review
# rather than rejecting ordinary work.
manifest_probe="$TMP_ROOT/ordinary-manifest.json"
printf '%s\n' '{}' >"$manifest_probe"
run_active_as "$main_session" "$repo_a" worker aggregate-manifest-write repo-a "$manifest_probe" >"$TMP_ROOT/manifest-probe.out"
cmp -s -- "$manifest_probe" "$main_dir/eci-aggregate.repo-a.required-critics.json"
run_active_as "$main_session" "$repo_a" worker aggregate-review final repo-a >"$TMP_ROOT/review-probe.out" 2>&1
grep -Fq 'fresh named least-restriction critic' "$TMP_ROOT/review-probe.out"
if grep -Fq 'Only the main/orchestrator may publish or clear ECI lifecycle state.' "$TMP_ROOT/review-probe.out"; then
  cat -- "$TMP_ROOT/review-probe.out" >&2
  printf '%s\n' 'aggregate-review still has a role-only rejection' >&2
  exit 1
fi

printf '%s\n' selected-change >>"$repo_a/tracked.txt"
run_active_as "$main_session" "$repo_a" worker aggregate-stage repo-a tracked.txt
git -C "$repo_a" diff --cached --name-only | grep -Fqx tracked.txt

wrong_target_index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
if run_active_as "$main_session" "$repo_b" worker aggregate-stage repo-a tracked.txt; then
  printf '%s\n' 'aggregate-stage accepted repo-a from the separately selected repo-b child' >&2
  exit 1
fi
[ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$wrong_target_index_before" ] || {
  printf '%s\n' 'wrong selected child changed the repo-a index' >&2
  exit 1
}

index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
if run_active_as "$main_session" "$repo_a" worker aggregate-stage repo-a ../outside.txt; then
  printf '%s\n' 'aggregate-stage accepted an outside selected-repository path from child cwd' >&2
  exit 1
fi
[ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$index_before" ] || {
  printf '%s\n' 'outside child path changed the selected repository index' >&2
  exit 1
}

head_before="$(git -C "$repo_a" rev-parse HEAD)"
run_active_as "$main_session" "$repo_a" worker aggregate-commit repo-a "$message"
head_after="$(git -C "$repo_a" rev-parse HEAD)"
[ "$head_after" != "$head_before" ] || {
  printf '%s\n' 'aggregate-commit from selected child cwd did not publish' >&2
  exit 1
}

printf '%s\n' stale >"$main_dir/eci-aggregate-teardown-complete"
run_active_as "$main_session" "$repo_a" worker aggregate-off "$report"
[ ! -e "$main_dir/eci_active" ] && [ ! -L "$main_dir/eci_active" ] || {
  printf '%s\n' 'aggregate-off from selected child cwd retained the active marker' >&2
  exit 1
}

# Generic aggregate manifest import resolves ordinary source aliases while
# keeping the validated selected repo ID as its only fixed destination selector.
unsafe_manifest_session='aggregate-selected-target-manifest-unsafe'
unsafe_manifest_dir="$proof_root/$unsafe_manifest_session"
unsafe_manifest_source_target="$TMP_ROOT/foreign-aggregate-manifest-source"
unsafe_manifest_source_link="$TMP_ROOT/foreign-aggregate-manifest-source-link"
unsafe_manifest_destination_target="$TMP_ROOT/foreign-aggregate-manifest-destination"
printf '%s\n' 'foreign aggregate manifest source' >"$unsafe_manifest_source_target"
ln -s -- "$unsafe_manifest_source_target" "$unsafe_manifest_source_link"
run_active_as "$unsafe_manifest_session" "$outer_cwd" coordinator on 'aggregate unsafe manifest source fixture' >/dev/null
run_active_as "$unsafe_manifest_session" "$outer_cwd" worker aggregate-migrate "$plan_a" >/dev/null
run_active_as "$unsafe_manifest_session" "$repo_a" worker \
  aggregate-manifest-write repo-a "$unsafe_manifest_source_link"
cmp -s -- "$unsafe_manifest_source_target" \
  "$unsafe_manifest_dir/eci-aggregate.repo-a.required-critics.json"
grep -Fqx 'foreign aggregate manifest source' "$unsafe_manifest_source_target"

printf '%s\n' 'foreign aggregate manifest destination' >"$unsafe_manifest_destination_target"
rm -f -- "$unsafe_manifest_dir/eci-aggregate.repo-a.required-critics.json"
ln -s -- "$unsafe_manifest_destination_target" \
  "$unsafe_manifest_dir/eci-aggregate.repo-a.required-critics.json"
if run_active_as "$unsafe_manifest_session" "$repo_a" worker \
  aggregate-manifest-write repo-a "$manifest_probe"; then
  printf '%s\n' 'aggregate-manifest-write replaced a symlinked fixed destination' >&2
  exit 1
fi
[ -L "$unsafe_manifest_dir/eci-aggregate.repo-a.required-critics.json" ]
grep -Fqx 'foreign aggregate manifest destination' "$unsafe_manifest_destination_target"

unsafe_manifest_node_session='aggregate-selected-target-manifest-node'
unsafe_manifest_node_dir="$proof_root/$unsafe_manifest_node_session"
run_active_as "$unsafe_manifest_node_session" "$outer_cwd" coordinator on 'aggregate nonregular manifest destination fixture' >/dev/null
run_active_as "$unsafe_manifest_node_session" "$outer_cwd" worker aggregate-migrate "$plan_a" >/dev/null
mkdir "$unsafe_manifest_node_dir/eci-aggregate.repo-a.required-critics.json"
if run_active_as "$unsafe_manifest_node_session" "$repo_a" worker \
  aggregate-manifest-write repo-a "$manifest_probe"; then
  printf '%s\n' 'aggregate-manifest-write replaced a nonregular fixed destination' >&2
  exit 1
fi
[ -d "$unsafe_manifest_node_dir/eci-aggregate.repo-a.required-critics.json" ] &&
  [ ! -L "$unsafe_manifest_node_dir/eci-aggregate.repo-a.required-critics.json" ]

# A different semantic target must not overwrite an existing normal plan.
conflict_session='aggregate-selected-target-conflict'
conflict_dir="$proof_root/$conflict_session"
run_active_as "$conflict_session" "$outer_cwd" coordinator on 'aggregate conflict fixture' >/dev/null
run_active_as "$conflict_session" "$outer_cwd" worker aggregate-migrate "$plan_b" >/dev/null
cp -- "$conflict_dir/eci-aggregate-plan.json" "$TMP_ROOT/conflict-plan.before"
if run_active_as "$conflict_session" "$outer_cwd" worker aggregate-migrate "$plan_a" >"$TMP_ROOT/conflict.out" 2>&1; then
  printf '%s\n' 'aggregate-migrate overwrote a conflicting selected-repository mapping' >&2
  exit 1
fi
cmp -s -- "$TMP_ROOT/conflict-plan.before" "$conflict_dir/eci-aggregate-plan.json" || {
  printf '%s\n' 'aggregate-migrate changed a conflicting selected-repository plan' >&2
  exit 1
}

# A linked plan is not a current-session regular object. It must remain
# untouched rather than being followed or replaced during retry.
link_session='aggregate-selected-target-link'
link_dir="$proof_root/$link_session"
foreign_plan="$TMP_ROOT/foreign-plan.json"
printf '%s\n' '{"foreign":"plan"}' >"$foreign_plan"
run_active_as "$link_session" "$outer_cwd" coordinator on 'aggregate linked-plan fixture' >/dev/null
ln -s -- "$foreign_plan" "$link_dir/eci-aggregate-plan.json"
if run_active_as "$link_session" "$outer_cwd" worker aggregate-migrate "$plan_a" >"$TMP_ROOT/link.out" 2>&1; then
  printf '%s\n' 'aggregate-migrate followed or replaced a linked current-session plan' >&2
  exit 1
fi
[ -L "$link_dir/eci-aggregate-plan.json" ]
grep -Fqx '{"foreign":"plan"}' "$foreign_plan"

# Replacing the session entry for a hard-linked stale plan is safe: the
# external inode is not written or followed, and the new plan is local.
hardlink_session='aggregate-selected-target-hardlink'
hardlink_dir="$proof_root/$hardlink_session"
foreign_hardlink_plan="$TMP_ROOT/foreign-hardlinked-plan.json"
printf '%s\n' '{"foreign":"hardlinked-plan"}' >"$foreign_hardlink_plan"
cp -- "$foreign_hardlink_plan" "$TMP_ROOT/foreign-hardlinked-plan.before"
run_active_as "$hardlink_session" "$outer_cwd" coordinator on 'aggregate hard-linked-plan fixture' >/dev/null
ln -- "$foreign_hardlink_plan" "$hardlink_dir/eci-aggregate-plan.json"
[ "$(stat -c '%i' -- "$foreign_hardlink_plan")" = "$(stat -c '%i' -- "$hardlink_dir/eci-aggregate-plan.json")" ]
run_active_as "$hardlink_session" "$outer_cwd" worker aggregate-migrate "$plan_a"
cmp -s -- "$TMP_ROOT/foreign-hardlinked-plan.before" "$foreign_hardlink_plan"
[ "$(stat -c '%i' -- "$foreign_hardlink_plan")" != "$(stat -c '%i' -- "$hardlink_dir/eci-aggregate-plan.json")" ]
jq -e --arg repo "$repo_a" '.repositories[0].repo_root == $repo' \
  "$hardlink_dir/eci-aggregate-plan.json" >/dev/null

# A nonregular current plan also cannot be normalized or replaced.
node_session='aggregate-selected-target-node'
node_dir="$proof_root/$node_session"
run_active_as "$node_session" "$outer_cwd" coordinator on 'aggregate nonregular-plan fixture' >/dev/null
mkdir "$node_dir/eci-aggregate-plan.json"
if run_active_as "$node_session" "$outer_cwd" worker aggregate-migrate "$plan_a" >"$TMP_ROOT/node.out" 2>&1; then
  printf '%s\n' 'aggregate-migrate replaced a nonregular current-session plan' >&2
  exit 1
fi
[ -d "$node_dir/eci-aggregate-plan.json" ] && [ ! -L "$node_dir/eci-aggregate-plan.json" ]

# Repeated fields must agree. Identical repetitions above are harmless;
# conflicting mapping fields still cannot select a target.
printf 'cwd: %s/other-cwd\n' "$TMP_ROOT" >>"$link_dir/eci_active"
mkdir -p "$TMP_ROOT/other-cwd"
if (
  export CODEX_PROOF_ROOT="$proof_root"
  source "$ROOT/hooks/lib/codex-proof-state.sh"
  codex_eci_aggregate_marker_cwd "$link_dir/eci_active" "$link_session" >/dev/null
); then
  printf '%s\n' 'aggregate marker reader accepted conflicting duplicate cwd metadata' >&2
  exit 1
fi

printf '%s\n' 'ECI aggregate selected-target normalization: PASS'
