#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(realpath -m -- "$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-aggregate-recovery.XXXXXX")")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

session_id=aggregate-recovery-session
proof_root="$TMP_ROOT/proof"
outer_cwd="$TMP_ROOT/aggregate-root"
plan_source="$TMP_ROOT/eci-aggregate-plan.json.source"
mkdir -p -- "$proof_root" "$outer_cwd"

init_repo() {
  local repo="$1"

  mkdir -p -- "$repo/hooks"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'ECI aggregate test'
  git -C "$repo" config user.email 'eci-aggregate-test@example.invalid'
  printf '%s\n' baseline >"$repo/hooks/target.txt"
  printf '%s\n' baseline >"$repo/deleted.txt"
  printf '%s\n' baseline >"$repo/unrelated.txt"
  git -C "$repo" add -- hooks/target.txt deleted.txt unrelated.txt
  git -C "$repo" commit -qm 'fixture baseline'
}

repo_a="$outer_cwd/repo-a"
repo_b="$outer_cwd/repo-b"
init_repo "$repo_a"
init_repo "$repo_b"

run_active_for_session() {
  local caller_session="$1"
  shift

  (
    cd -- "$outer_cwd"
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$caller_session" \
      CODEX_ROLE=main TMPDIR="$TMP_ROOT" "$ROOT/bin/eci-active" "$@"
  )
}

run_active() {
  run_active_for_session "$session_id" "$@"
}

run_active_from() {
  local caller_cwd="$1"
  shift

  (
    cd -- "$caller_cwd"
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
      CODEX_ROLE=main TMPDIR="$TMP_ROOT" "$ROOT/bin/eci-active" "$@"
  )
}

jq -cn \
  --arg repo_a "$repo_a" \
  --arg repo_b "$repo_b" \
  '{schema:"eci-aggregate-plan-source/v1",repositories:[{id:"repo-a",repo_root:$repo_a},{id:"repo-b",repo_root:$repo_b}]}' \
  >"$plan_source"

# Aggregate migration is only an explicit parent-to-child bridge. An otherwise
# valid Git root outside that parent must not become a selectable member.
outside_repo="$TMP_ROOT/outside-repo"
outside_plan_source="$TMP_ROOT/outside-eci-aggregate-plan.json.source"
strict_session_id=aggregate-strict-membership-session
init_repo "$outside_repo"
jq -cn --arg repo "$outside_repo" \
  '{schema:"eci-aggregate-plan-source/v1",repositories:[{id:"outside",repo_root:$repo}]}' \
  >"$outside_plan_source"
run_active_for_session "$strict_session_id" on 'aggregate strict-membership fixture' >/dev/null
if run_active_for_session "$strict_session_id" aggregate-migrate "$outside_plan_source"; then
  printf '%s\n' 'aggregate-migrate unexpectedly accepted a repository outside the parent cwd' >&2
  exit 1
fi
[ ! -e "$proof_root/$strict_session_id/eci-aggregate-plan.json" ]

strict_marker="$proof_root/$strict_session_id/eci_active"
strict_report="$proof_root/$strict_session_id/user-closed.md"
[ -f "$strict_marker" ]
{
  printf 'schema: eci-user-closed/v1\n'
  printf 'owner: coordinator\n'
  printf 'session_id: %s\n' "$strict_session_id"
  printf 'cwd: %s\n' "$outer_cwd"
  printf 'report_path: %s\n' "$strict_report"
  printf 'reason: strict-membership negative control completed; incomplete test-only ECI session closed\n'
  printf 'state: incomplete\n'
  printf 'user-closed: true\n'
} >"$strict_report"
run_active_for_session "$strict_session_id" off "$strict_report" >/dev/null
[ ! -e "$strict_marker" ]
[ ! -e "$proof_root/$strict_session_id/eci-aggregate-plan.json" ]

run_active on 'aggregate recovery fixture' >/dev/null

# Aggregate migration must never recover a session by choosing the newest
# directory.  The caller must name the live parent session explicitly, so a
# concurrent/sibling session cannot be converted by accident.
missing_session_output="$TMP_ROOT/aggregate-migrate-missing-session.out"
if (
  cd -- "$outer_cwd"
  env -u CODEX_SESSION_ID -u CODEX_THREAD_ID \
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_ROLE=main TMPDIR="$TMP_ROOT" \
    "$ROOT/bin/eci-active" aggregate-migrate "$plan_source"
) >"$missing_session_output" 2>&1; then
  printf '%s\n' 'aggregate-migrate unexpectedly selected a fallback session' >&2
  exit 1
fi
grep -Fq 'explicit current CODEX_SESSION_ID or CODEX_THREAD_ID' "$missing_session_output"

# A legacy parent marker at a non-Git cwd can gain a bound plan without
# changing that marker's cwd only after the identity-bound negative check.
run_active aggregate-migrate "$plan_source"

marker="$proof_root/$session_id/eci_active"
plan="$proof_root/$session_id/eci-aggregate-plan.json"
[ -f "$marker" ]
[ -f "$plan" ]
grep -Fqx "cwd: $outer_cwd" "$marker"
jq -e \
  --arg session_id "$session_id" \
  --arg outer_cwd "$outer_cwd" \
  --arg repo_a "$repo_a" \
  --arg repo_b "$repo_b" '
    (has("schema") | not) and
    .session_id == $session_id and
    .outer_cwd == $outer_cwd and
    [.repositories[].id] == ["repo-a", "repo-b"] and
    .repositories[0].repo_root == $repo_a and
    .repositories[1].repo_root == $repo_b
  ' "$plan" >/dev/null

# Revalidation must enforce the same strict descendant relationship. This
# tampered plan remains canonical and points at a real Git root, so a failure
# later in the review gate would not prove the plan-consumption invariant.
plan_backup="$TMP_ROOT/eci-aggregate-plan.original"
plan_tampered="$TMP_ROOT/eci-aggregate-plan.tampered"
plan_tamper_output="$TMP_ROOT/eci-aggregate-plan-tampered.out"
cp -- "$plan" "$plan_backup"
jq -c --arg repo "$outside_repo" --arg git_dir "$outside_repo/.git" --arg git_common "$outside_repo/.git" '
  .repositories[0].repo_root = $repo |
  .repositories[0].git_dir = $git_dir |
  .repositories[0].git_common_dir = $git_common
' "$plan" >"$plan_tampered"
mv -- "$plan_tampered" "$plan"
if run_active aggregate-review final repo-a >"$plan_tamper_output" 2>&1; then
  printf '%s\n' 'aggregate-review unexpectedly consumed a plan with an external repository root' >&2
  exit 1
fi
grep -Fq 'requires a validated active aggregate session and selected target' "$plan_tamper_output"
mv -- "$plan_backup" "$plan"

# Aggregate staging is a parent-CWD bridge. It selects the worktree by plan ID
# and stages one complete literal batch only after every operand has passed
# the same ownership checks.
stage_modified='hooks/target.txt'
stage_deleted='deleted.txt'
stage_regular='new-staged-file.txt'
stage_spaced='new staged file.txt'
stage_leading_dash='-new-staged-file.txt'
stage_colon=':new-staged-file.txt'
printf '%s\n' 'reviewed aggregate staging change' >>"$repo_a/$stage_modified"
rm -- "$repo_a/$stage_deleted"
printf '%s\n' 'regular aggregate file' >"$repo_a/$stage_regular"
printf '%s\n' 'new aggregate file' >"$repo_a/$stage_spaced"
printf '%s\n' 'leading dash aggregate file' >"$repo_a/$stage_leading_dash"
printf '%s\n' 'colon aggregate file' >"$repo_a/$stage_colon"
run_active aggregate-stage repo-a -- "$stage_modified" "$stage_deleted" "$stage_regular" "$stage_spaced" "$stage_leading_dash" "$stage_colon"
stage_expected="$TMP_ROOT/aggregate-stage.expected"
stage_actual="$TMP_ROOT/aggregate-stage.actual"
printf '%s\n' "$stage_colon" "$stage_leading_dash" "$stage_deleted" "$stage_modified" "$stage_regular" "$stage_spaced" | LC_ALL=C sort >"$stage_expected"
git -C "$repo_a" diff --cached --name-only >"$stage_actual"
LC_ALL=C sort -o "$stage_actual" "$stage_actual"
cmp -s "$stage_expected" "$stage_actual"
git -C "$repo_b" diff --cached --quiet

# A selected child worktree resolves to the same concrete plan member as the
# parent caller. It may stage that member but cannot choose another one.
run_active_from "$repo_a" aggregate-stage repo-a -- "$stage_modified"
git -C "$repo_a" diff --cached --name-only | grep -Fqx "$stage_modified"

git -C "$repo_a" --literal-pathspecs restore --staged -- "$stage_modified" "$stage_deleted" "$stage_regular" "$stage_spaced" "$stage_leading_dash" "$stage_colon"
git -C "$repo_a" restore -- "$stage_modified" "$stage_deleted"
rm -- "$repo_a/$stage_regular" "$repo_a/$stage_spaced" "$repo_a/$stage_leading_dash" "$repo_a/$stage_colon"

# A selected batch has no arbitrary upper operand limit. Every item must
# still pass the selected-root validation before the one Git index update.
stage_many=()
for stage_index in $(seq 1 65); do
  stage_path="many-$stage_index.txt"
  printf '%s\n' "many aggregate path $stage_index" >"$repo_a/$stage_path"
  stage_many+=("$stage_path")
done
run_active aggregate-stage repo-a -- "${stage_many[@]}"
git -C "$repo_a" diff --cached --name-only | LC_ALL=C sort >"$TMP_ROOT/aggregate-stage-many.actual"
printf '%s\n' "${stage_many[@]}" | LC_ALL=C sort >"$TMP_ROOT/aggregate-stage-many.expected"
cmp -s -- "$TMP_ROOT/aggregate-stage-many.expected" "$TMP_ROOT/aggregate-stage-many.actual"
git -C "$repo_a" restore --staged -- "${stage_many[@]}"
rm -- "${stage_many[@]/#/$repo_a/}"

empty_index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
if run_active aggregate-stage repo-a -- >"$TMP_ROOT/aggregate-stage-empty.out" 2>&1; then
  printf '%s\n' 'aggregate-stage unexpectedly accepted an empty selected batch' >&2
  exit 1
fi
[ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$empty_index_before" ] || {
  printf '%s\n' 'aggregate-stage changed the index for an empty selected batch' >&2
  exit 1
}

outside_index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
if run_active aggregate-stage repo-a -- ../outside.txt >"$TMP_ROOT/aggregate-stage-outside-root.out" 2>&1; then
  printf '%s\n' 'aggregate-stage unexpectedly accepted an outside-root path' >&2
  exit 1
fi
[ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$outside_index_before" ] || {
  printf '%s\n' 'aggregate-stage changed the index for an outside-root path' >&2
  exit 1
}

for invalid_stage_id in undeclared ../repo-a; do
  invalid_id_output="$TMP_ROOT/aggregate-stage-invalid-id-${invalid_stage_id//\//_}.out"
  invalid_id_index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
  if run_active aggregate-stage "$invalid_stage_id" -- "$stage_modified" >"$invalid_id_output" 2>&1; then
    printf 'aggregate-stage unexpectedly accepted invalid repository ID=%q\n' "$invalid_stage_id" >&2
    exit 1
  fi
  [ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$invalid_id_index_before" ]
done

assert_stage_rejected_preserves_index() {
  local label="$1" invalid_path="$2" output before after

  output="$TMP_ROOT/aggregate-stage-$label.out"
  before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
  if run_active aggregate-stage repo-a -- "$stage_modified" "$invalid_path" >"$output" 2>&1; then
    printf 'aggregate-stage unexpectedly accepted invalid path label=%s path=%q\n' "$label" "$invalid_path" >&2
    exit 1
  fi
  after="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
  [ "$after" = "$before" ] || {
    printf 'aggregate-stage changed the index for rejected mixed batch label=%s path=%q\n' "$label" "$invalid_path" >&2
    exit 1
  }
}

printf '%s\n' 'candidate change for rejected mixed batches' >>"$repo_a/$stage_modified"
printf '%s\n' 'ignored aggregate stage candidate' >"$repo_a/ignored-stage.txt"
printf '%s\n' 'ignored-stage.txt' >>"$repo_a/.git/info/exclude"
printf '%s\n' 'ignored by repository .gitignore' >"$repo_a/ignored-stage-gitignore.txt"
printf '%s\n' 'ignored-stage-gitignore.txt' >>"$repo_a/.gitignore"
printf '%s\n' 'control candidate' >"$repo_a/eci_active"
printf '%s\n' 'approval candidate' >"$repo_a/.git-commit-approved-once"
ln -s -- "$outside_repo" "$repo_a/escape-dir"
ln -s -- hooks "$repo_a/in-root-link"

for invalid_stage_path in \
  /etc/passwd \
  ../outside \
  hooks//target.txt \
  hooks/./target.txt \
  'hooks/*.txt' \
  'hooks/[t]arget.txt' \
  ':(top)hooks/target.txt' \
  ':/short-magic-only.txt' \
  ':!short-magic-only.txt' \
  ':^short-magic-only.txt' \
  hooks \
  missing-stage.txt \
  ignored-stage.txt \
  ignored-stage-gitignore.txt \
  escape-dir/tracked.txt \
  in-root-link/target.txt \
  .git/config \
  eci_active \
  .git-reset-approved-once \
  .git-worktree-approved-once \
  .git-commit-approved-once \
  .git-future-approved-once \
  --; do
  assert_stage_rejected_preserves_index "${invalid_stage_path//\//_}" "$invalid_stage_path"
done
no_path_output="$TMP_ROOT/aggregate-stage-no-path.out"
no_path_index_before="$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')"
if run_active aggregate-stage repo-a -- >"$no_path_output" 2>&1; then
  printf '%s\n' 'aggregate-stage unexpectedly accepted no file operands' >&2
  exit 1
fi
[ "$(sha256sum -- "$repo_a/.git/index" | awk '{print $1}')" = "$no_path_index_before" ]
# The lifecycle CLI retains its established direct-operand spelling. The
# validator may defer that ordinary syntax to the selected repository route;
# the same selected-root and literal-path checks still govern the mutation.
run_active aggregate-stage repo-a "$stage_modified" >"$TMP_ROOT/aggregate-stage-direct.out"
git -C "$repo_a" diff --cached --name-only | grep -Fqx "$stage_modified"
git -C "$repo_a" restore --staged -- "$stage_modified"
git -C "$repo_a" restore -- "$stage_modified"

rm -- "$repo_a/ignored-stage.txt" "$repo_a/ignored-stage-gitignore.txt" "$repo_a/.gitignore" "$repo_a/eci_active" "$repo_a/.git-commit-approved-once" "$repo_a/escape-dir" "$repo_a/in-root-link"
git -C "$repo_a" restore -- "$stage_modified"

# A migrated parent may not start the singleton nested lifecycle. The plan
# has no nested counterpart, so accepting this normal command would create a
# mixed-state artifact which makes aggregate teardown fail later.
nested_output="$TMP_ROOT/aggregate-normal-nested.out"
if run_active nested-enter 1 1 "$session_id" >"$nested_output" 2>&1; then
  printf '%s\n' 'singleton nested-enter unexpectedly accepted an aggregate plan' >&2
  exit 1
fi
grep -Fq 'aggregate session' "$nested_output"
[ ! -e "$proof_root/$session_id/ate_nested_eci_active" ]

# A valid singleton wait report must not be able to create wait state under a
# plan either. Remove the synthetic source report after the negative check so
# the aggregate fixture remains free of singleton evidence.
wait_report="$proof_root/$session_id/eci_user_owned_wait.md"
printf '%s\n' \
  '# ECI User-Owned Wait' \
  'state: user-owned-wait' \
  'blocker_id: aggregate-test' \
  'state_fingerprint: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'owner: user' \
  'brp_result: exhausted-no-feasible-internal-path' \
  'user_owned_input: unobtainable' \
  'unblock_kind: decision' \
  'unblock: await user decision' \
  >"$wait_report"
wait_output="$TMP_ROOT/aggregate-normal-wait.out"
if run_active wait "$wait_report" >"$wait_output" 2>&1; then
  printf '%s\n' 'singleton wait unexpectedly accepted an aggregate plan' >&2
  exit 1
fi
grep -Fq 'aggregate session' "$wait_output"
[ ! -e "$proof_root/$session_id/eci_wait" ]
rm -f -- "$wait_report"

# The review gate is also callable without the CLI wrapper. It must refuse a
# normal invocation before looking for singleton evidence under a live plan.
normal_gate_output="$TMP_ROOT/aggregate-normal-gate.out"
if (
  cd -- "$outer_cwd"
  CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
    "$ROOT/hooks/eci-review-gate.sh" final "$session_id"
) >"$normal_gate_output" 2>&1; then
  printf '%s\n' 'singleton review gate unexpectedly accepted an aggregate plan' >&2
  exit 1
fi
grep -Fq 'singleton lifecycle invocation for an aggregate session' "$normal_gate_output"

# SessionStart may arrive from one declared sibling while the parent marker is
# active. It must retain aggregate ownership rather than creating singleton
# baseline files beside the aggregate plan.
snapshot_transcript="$TMP_ROOT/aggregate-session-snapshot.jsonl"
snapshot_output="$TMP_ROOT/aggregate-session-snapshot.json"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aggregate-recovery-session"}}' >"$snapshot_transcript"
(
  cd -- "$repo_a"
  jq -cn --arg session_id "$session_id" --arg cwd "$repo_a" --arg transcript "$snapshot_transcript" \
    '{session_id:$session_id,cwd:$cwd,transcript_path:$transcript}' |
    CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
      bash "$ROOT/hooks/session-snapshot.sh" >"$snapshot_output"
)
jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$snapshot_output" >/dev/null
[ ! -e "$proof_root/$session_id/baseline_head" ]
[ ! -e "$proof_root/$session_id/baseline_head.binding" ]

emit_manifest_source() {
  local repo="$1" repo_id="$2" source_root="$3" source_path="$4" kind="${5:-root}" version="${6:-1}"
  local e2e_required="${7:-true}"
  local stage_target="${8:-true}" target_path="${9:-$repo/hooks/target.txt}"
  local source_session="$source_root/$session_id" evidence_dir evidence

  case "$stage_target" in
  true)
    printf '%s\n' 'aggregate fixture change' >>"$repo/hooks/target.txt"
    git -C "$repo" add -- hooks/target.txt
    ;;
  false) ;;
  *)
    printf 'unsupported aggregate manifest stage_target=%q\n' "$stage_target" >&2
    return 1
    ;;
  esac
  ECI_EMIT_CURRENT_MANIFEST=1 ECI_EMIT_PROOF_ROOT="$source_root" \
    ECI_EMIT_SESSION_ID="$session_id" ECI_EMIT_KIND="$kind" ECI_TEST_REPO="$repo" \
    ECI_TEST_TARGET="$target_path" ECI_TEST_CWD="$repo" ECI_EMIT_E2E_REQUIRED="$e2e_required" \
    "$ROOT/hooks/tests/test-eci-review-gate.sh" >/dev/null
  evidence_dir="$proof_root/$session_id/eci-aggregate.$repo_id.evidence"
  mkdir -p -- "$evidence_dir"
  for evidence in "$source_session"/*; do
    [ "${evidence##*/}" = eci-required-critics.json ] && continue
    cp -- "$evidence" "$evidence_dir/${evidence##*/}"
  done
  jq -c --arg source "$source_session/" --arg destination "$evidence_dir/" --arg version "$version" '
    walk(if type == "string" and startswith($source)
      then $destination + ltrimstr($source)
      else .
      end) |
    .acceptance_version = $version |
    .rows |= map(.acceptance_version = $version)
  ' "$source_session/eci-required-critics.json" >"$source_path"
}

rewrite_aggregate_evidence_root() {
  local source_manifest="$1" source_evidence_root="$2" destination_root="$3" destination_manifest="$4"

  mkdir -p -- "$destination_root"
  cp -- "$source_evidence_root"/* "$destination_root/"
  jq -c --arg source "$source_evidence_root/" --arg destination "$destination_root/" '
    walk(if type == "string" and startswith($source)
      then $destination + ltrimstr($source)
      else .
      end)
  ' "$source_manifest" >"$destination_manifest"
  jq -e --arg destination "$destination_root/" '
    [
      .current_diff_artifact,
      (.targets[] | .diff_artifact),
      (.rows[] | .diff_artifact),
      (.rows[] | .spawn_request_artifact),
      (.rows[] | .report_artifact),
      (.rows[] | .adjudication_artifact),
      (.rows[] | .intention_artifact),
      (.rows[] | .e2e_artifact)
    ] | map(select(. != null)) as $artifacts |
    ($artifacts | length > 0) and all($artifacts[]; startswith($destination))
  ' "$destination_manifest" >/dev/null
}

assert_aggregate_evidence_root_is_advisory() {
  local label="$1" manifest_source="$2" output

  # Artifact-path provenance is historical review context. It cannot redirect
  # the fixed session leaf, selected repository, or Git CAS target, so normal
  # aggregate manifest publication and review remain available.
  output="$TMP_ROOT/aggregate-evidence-$label.out"
  if ! run_active aggregate-manifest-write repo-a "$manifest_source" >"$output" 2>&1; then
    cat -- "$output" >&2
    printf 'aggregate-manifest-write unexpectedly rejected advisory %s evidence paths\n' "$label" >&2
    exit 1
  fi
  if ! run_active aggregate-review final repo-a >"$output" 2>&1; then
    cat -- "$output" >&2
    printf 'aggregate review unexpectedly rejected advisory %s evidence paths\n' "$label" >&2
    exit 1
  fi
}

assert_aggregate_review_is_advisory() {
  local label="$1" repo_id="$2" output

  # Snapshot classification and historic review evidence route fresh review;
  # they are not a permission ceremony.  The command must still reach the
  # selected member through the live parent/plan boundary, but a mixed index
  # and worktree is ordinary user work rather than an aggregate-review denial.
  output="$TMP_ROOT/aggregate-review-$label.out"
  if ! run_active aggregate-review final "$repo_id" >"$output" 2>&1; then
    cat -- "$output" >&2
    printf 'aggregate review unexpectedly rejected advisory mixed snapshot=%s\n' "$label" >&2
    exit 1
  fi
}

# Mixed staged/worktree snapshots remain ordinary user work. The selected
# parent/member boundary is checked by the wrapper; the review gate reports a
# fresh-review need instead of turning the snapshot shape into a denial.
overlap_manifest_source="$TMP_ROOT/repo-b-overlap/eci-required-critics.json.source"
mkdir -p -- "${overlap_manifest_source%/*}"
printf '%s\n' 'staged target overlap fixture change' >>"$repo_b/hooks/target.txt"
git -C "$repo_b" add -- hooks/target.txt
printf '%s\n' 'unstaged target overlap fixture change' >>"$repo_b/hooks/target.txt"
emit_manifest_source "$repo_b" repo-b "$TMP_ROOT/source-b-overlap" "$overlap_manifest_source" root 1 true false "$repo_b/hooks/target.txt"
run_active aggregate-manifest-write repo-b "$overlap_manifest_source"
assert_aggregate_review_is_advisory target-overlap repo-b
git -C "$repo_b" restore --staged -- hooks/target.txt
git -C "$repo_b" restore -- hooks/target.txt

# A separate tracked worktree change must not become governed merely because
# porcelain status augments the general changed-path inventory.
unstaged_target_manifest_source="$TMP_ROOT/repo-b-unstaged-target/eci-required-critics.json.source"
mkdir -p -- "${unstaged_target_manifest_source%/*}"
printf '%s\n' 'staged target membership fixture change' >>"$repo_b/hooks/target.txt"
git -C "$repo_b" add -- hooks/target.txt
printf '%s\n' 'tracked unrelated membership fixture change' >>"$repo_b/unrelated.txt"
emit_manifest_source "$repo_b" repo-b "$TMP_ROOT/source-b-unstaged-target" "$unstaged_target_manifest_source" root 1 true false "$repo_b/unrelated.txt"
run_active aggregate-manifest-write repo-b "$unstaged_target_manifest_source"
assert_aggregate_review_is_advisory unstaged-target repo-b
git -C "$repo_b" restore --staged -- hooks/target.txt
git -C "$repo_b" restore -- hooks/target.txt unrelated.txt

manifest_source_a="$TMP_ROOT/repo-a/eci-required-critics.json.source"
manifest_source_b="$TMP_ROOT/repo-b/eci-required-critics.json.source"
mkdir -p -- "${manifest_source_a%/*}" "${manifest_source_b%/*}"
printf '%s\n' 'tracked aggregate user work' >>"$repo_a/unrelated.txt"
emit_manifest_source "$repo_a" repo-a "$TMP_ROOT/source-a" "$manifest_source_a"
emit_manifest_source "$repo_b" repo-b "$TMP_ROOT/source-b" "$manifest_source_b"

# Artifact namespaces are review context rather than an authorization rule.
# These paths must not change the fixed session leaf or selected Git target.
repo_a_evidence="$proof_root/$session_id/eci-aggregate.repo-a.evidence"
repo_b_evidence="$proof_root/$session_id/eci-aggregate.repo-b.evidence"
unscoped_evidence="$proof_root/$session_id/unscoped-evidence"
cross_member_evidence="$repo_b_evidence/copied-repo-a-evidence"
unscoped_manifest_source="$TMP_ROOT/repo-a-unscoped/eci-required-critics.json.source"
cross_member_manifest_source="$TMP_ROOT/repo-a-cross-member/eci-required-critics.json.source"
mkdir -p -- "${unscoped_manifest_source%/*}" "${cross_member_manifest_source%/*}"
rewrite_aggregate_evidence_root "$manifest_source_a" "$repo_a_evidence" "$unscoped_evidence" "$unscoped_manifest_source"
rewrite_aggregate_evidence_root "$manifest_source_a" "$repo_a_evidence" "$cross_member_evidence" "$cross_member_manifest_source"
assert_aggregate_evidence_root_is_advisory unscoped "$unscoped_manifest_source"
assert_aggregate_evidence_root_is_advisory cross-member "$cross_member_manifest_source"

# Each sibling receives a normal v2 subcontract in a namespaced parent
# session path. The aggregate command selects its root only by plan ID.
if run_active manifest-write "$manifest_source_a" >/dev/null 2>&1; then
  printf '%s\n' 'singleton manifest-write unexpectedly accepted an aggregate plan' >&2
  exit 1
fi
if run_active aggregate-review final ../repo-a >/dev/null 2>&1; then
  printf '%s\n' 'path-shaped aggregate repository ID unexpectedly passed selection' >&2
  exit 1
fi
run_active aggregate-manifest-write repo-a "$manifest_source_a"
run_active aggregate-manifest-write repo-b "$manifest_source_b"

# A singleton review record is historical workflow residue. The aggregate
# wrapper still owns the live plan/selected-member boundary, while the gate
# treats this record as a fresh-review reminder rather than a denial.
singleton_manifest="$proof_root/$session_id/eci-required-critics.json"
printf '%s\n' '{}' >"$singleton_manifest"
if ! (
  cd -- "$outer_cwd"
  ECI_AGGREGATE_REPO_ID=repo-a ECI_AGGREGATE_PARENT_CWD="$outer_cwd" \
    ECI_REVIEW_CWD="$outer_cwd" CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_SESSION_ID="$session_id" "$ROOT/hooks/eci-review-gate.sh" final "$session_id"
); then
  rm -f -- "$singleton_manifest"
  printf '%s\n' 'aggregate review gate unexpectedly rejected advisory singleton review residue' >&2
  exit 1
fi
rm -f -- "$singleton_manifest"

# The disjoint mixed snapshot is eligible for final review. A fresh v2 target
# then proves aggregate commit captures only the staged tree, leaving tracked
# user work in the worktree.
commit_message="$TMP_ROOT/eci-aggregate-commit-message.source"
printf '%s\n' 'aggregate bridge commit' >"$commit_message"

final_a_output="$TMP_ROOT/aggregate-final-repo-a.out"
if ! run_active aggregate-review final repo-a >"$final_a_output" 2>&1; then
  cat -- "$final_a_output" >&2
  printf '%s\n' 'aggregate final unexpectedly rejected disjoint tracked worktree changes' >&2
  exit 1
fi

# A selected child invokes the same review gate against the marker-validated
# aggregate parent. A different selected child must not redirect that review.
if ! run_active_from "$repo_a" aggregate-review final repo-a >"$TMP_ROOT/aggregate-final-repo-a-child.out" 2>&1; then
  cat -- "$TMP_ROOT/aggregate-final-repo-a-child.out" >&2
  printf '%s\n' 'aggregate final from its selected child did not use the aggregate parent cwd' >&2
  exit 1
fi
if run_active_from "$repo_b" aggregate-review final repo-a >"$TMP_ROOT/aggregate-final-wrong-child.out" 2>&1; then
  printf '%s\n' 'aggregate review accepted repo-a from the separately selected repo-b child' >&2
  exit 1
fi

# Aggregate commit publishes the selected current index tree with an explicit
# parent/ref CAS. Historic review anchors and enumeration injection modes are
# not normal-work authority; the concrete invariant is that this selected
# staged tree, and no tracked worktree-only file, reaches the branch.
head_a_before="$(git -C "$repo_a" rev-parse HEAD)"
run_active aggregate-commit repo-a "$commit_message"
head_a_after="$(git -C "$repo_a" rev-parse HEAD)"
[ "$head_a_before" != "$head_a_after" ]
accepted_tree="$(git -C "$repo_a" rev-parse "$head_a_after^{tree}")"
accepted_parent="$head_a_before"
[ "$(git -C "$repo_a" rev-parse "$head_a_after^")" = "$accepted_parent" ]
commit_paths="$TMP_ROOT/aggregate-repo-a-commit-paths"
git -C "$repo_a" show --format= --name-only "$head_a_after" >"$commit_paths"
[ "$(wc -l <"$commit_paths")" -eq 1 ]
grep -Fqx hooks/target.txt "$commit_paths"
git -C "$repo_a" diff --cached --quiet
[ "$(git -C "$repo_a" diff --name-only --no-renames)" = unrelated.txt ]

# A committed member has a new live snapshot. Refresh only that member with a
# distinct post-commit subcontract for the terminal off gate; its commit
# admission is already the postwrite acceptance boundary. Repo-b remains on
# its original independent final/off subcontract.
aggregate_post_commit_acceptance_version=3
emit_manifest_source "$repo_a" repo-a "$TMP_ROOT/source-a-after-commit" "$manifest_source_a" \
  candidate-fix "$aggregate_post_commit_acceptance_version"
run_active aggregate-manifest-write repo-a "$manifest_source_a"
run_active aggregate-review final repo-b

report="$proof_root/$session_id/disengage.md"
printf '%s\n' \
  '## ECI completion certificate' \
  'clean-pass:' \
  '## Stop checklist walkthrough' \
  'validated' \
  '## Incomplete compliance' \
  'none' \
  >"$report"
run_active aggregate-off "$report"

[ ! -e "$marker" ]
[ ! -e "$proof_root/$session_id/eci-aggregate-teardown-complete" ] && \
  [ ! -L "$proof_root/$session_id/eci-aggregate-teardown-complete" ]

# Stop uses the removed current marker as the lifecycle boundary. It must not
# require a historic all-members receipt or a singleton manifest after the
# aggregate parent has been closed.
stop_output="$TMP_ROOT/aggregate-stop.json"
jq -cn --arg session_id "$session_id" --arg cwd "$outer_cwd" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:""}' |
  CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/stop-gate.sh" >"$stop_output"
jq -e '.continue == true' "$stop_output" >/dev/null

printf '%s\n' 'ECI aggregate recovery tests: PASS'
