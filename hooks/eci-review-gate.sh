#!/usr/bin/env bash
# Validate the coordinator's bounded required-critic manifest at acceptance
# boundaries. This is never called by the active Stop fast path.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

usage() {
  printf 'Usage: eci-review-gate.sh <commit|final|off> <session-id>\n' >&2
}

fail_gate() {
  printf '%s\n' "$1" >&2
  exit 1
}

phase="${1:-}"
session_id="${2:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
case "$phase" in
  commit|final|off) ;;
  *) usage; exit 2 ;;
esac
codex_valid_session_id "$session_id" || fail_gate 'ECI required-critic review gate needs a valid session id.'

root="$(codex_proof_root)"
codex_proof_root_is_safe || fail_gate "ECI required-critic review gate rejected an unsafe proof root: $root"
session_dir="$root/$session_id"
codex_session_dir_is_safe "$root" "$session_id" ||
  fail_gate "ECI required-critic review gate rejected an unsafe session directory: $session_dir"
[ -d "$session_dir" ] && [ ! -L "$session_dir" ] ||
  fail_gate "ECI required-critic review gate needs the canonical session directory: $session_dir"

if [ "$phase" = off ]; then
  marker="$session_dir/eci_active"
  [ -f "$marker" ] && [ ! -L "$marker" ] ||
    fail_gate "ECI required-critic review gate cannot validate teardown without the regular active marker: $marker"
fi

# Acceptance validation and immutable admission are one locked transaction.
# The active Stop path never calls this script, so this coordination lock is
# deliberately outside the sub-second callback path.
if [ "${ECI_REVIEW_GATE_LOCK_HELD:-false}" != true ]; then
  lock_path="$(codex_eci_lock_path 2>/dev/null || true)"
  [ -n "$lock_path" ] || fail_gate 'ECI required-critic review gate could not resolve the mutation lock.'
  [ ! -L "$lock_path" ] && { [ ! -e "$lock_path" ] || [ -f "$lock_path" ]; } ||
    fail_gate "ECI required-critic review gate lock is unsafe: $lock_path"
  exec {gate_lock_fd}>>"$lock_path" || fail_gate 'ECI required-critic review gate could not open the mutation lock.'
  flock -n "$gate_lock_fd" || fail_gate 'ECI required-critic review gate mutation lock is busy.'
  ECI_REVIEW_GATE_LOCK_HELD=true
  trap 'flock -u "$gate_lock_fd" 2>/dev/null || true; eval "exec ${gate_lock_fd}>&-"' EXIT
fi

manifest="$session_dir/eci-required-critics.json"
admitted="$session_dir/eci-required-critics.admitted.sha256"
[ -f "$manifest" ] && [ ! -L "$manifest" ] ||
  fail_gate "ECI required-critic review gate denied $phase: missing canonical manifest $manifest"

manifest_bytes="$(wc -c <"$manifest" 2>/dev/null || true)"
case "$manifest_bytes" in
  ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed manifest size.' ;;
esac
[ "$manifest_bytes" -le 65536 ] || fail_gate 'ECI required-critic review gate denied an oversized manifest (limit 65536 bytes).'
[ "$(tail -c 1 -- "$manifest" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
  fail_gate 'ECI required-critic review gate denied a manifest without exactly one final LF.'
[ "$(awk 'END { print NR + 0 }' "$manifest" 2>/dev/null || printf '0')" -eq 1 ] ||
  fail_gate 'ECI required-critic review gate requires one compact JSON line plus its final LF.'
if LC_ALL=C grep -q $'\r' "$manifest"; then
  fail_gate 'ECI required-critic review gate denied carriage returns in the manifest.'
fi
if ! jq -e . "$manifest" >/dev/null 2>&1; then
  fail_gate 'ECI required-critic review gate denied invalid UTF-8 or malformed JSON.'
fi
if ! jq -c . "$manifest" | cmp -s - "$manifest"; then
  fail_gate 'ECI required-critic review gate requires compact canonical JSON with the fixed member order.'
fi

top_keys='["schema","current_target_id","current_target_kind","current_diff_artifact","current_diff_sha256","targets","rows"]'
jq -e --argjson expected "$top_keys" '
  (keys_unsorted == $expected) and
  (.schema == "eci-required-critics/v1") and
  (.current_target_id | type == "string") and
  (.current_target_kind | type == "string") and
  (.current_diff_artifact | type == "string") and
  (.current_diff_sha256 | test("^[0-9a-f]{64}$")) and
  (.targets | type == "array" and length > 0) and
  (.rows | type == "array" and length > 0)
' "$manifest" >/dev/null 2>&1 || fail_gate 'ECI required-critic review gate denied the manifest header/schema.'

target_keys='["target_id","target_kind","diff_artifact","diff_sha256","e2e_required"]'
row_keys='["target_id","target_kind","diff_artifact","diff_sha256","critic_role","gate_phase","child_identity","spawn_request_artifact","spawn_request_sha256","report_artifact","report_sha256","verdict","e2e_required","e2e_artifact","e2e_sha256"]'
jq -e --argjson expected "$target_keys" --argjson rows_expected "$row_keys" '
  all(.targets[];
    (keys_unsorted == $expected) and
    (.target_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.target_kind | . == "root" or . == "subtask" or . == "candidate-fix") and
    (.diff_artifact | type == "string") and
    (.diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.e2e_required | type == "boolean")
  ) and
  all(.rows[];
    (keys_unsorted == $rows_expected) and
    (.target_id | type == "string") and
    (.target_kind | . == "root" or . == "subtask" or . == "candidate-fix") and
    (.diff_artifact | type == "string") and
    (.diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.critic_role | . == "A" or . == "B" or . == "C") and
    (.gate_phase | . == "prewrite" or . == "postwrite") and
    (.child_identity | type == "string" and length > 0 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$")) and
    (.spawn_request_artifact | type == "string") and
    (.spawn_request_sha256 | test("^[0-9a-f]{64}$")) and
    (.report_artifact | type == "string") and
    (.report_sha256 | test("^[0-9a-f]{64}$")) and
    (.verdict == "PASS") and
    (.e2e_required | type == "boolean") and
    ((.e2e_required and (.e2e_artifact | type == "string") and (.e2e_sha256 | test("^[0-9a-f]{64}$"))) or
      ((.e2e_required | not) and .e2e_artifact == null and .e2e_sha256 == null))
  )
' "$manifest" >/dev/null 2>&1 || fail_gate 'ECI required-critic review gate denied target/row schema, ordering, or verdict fields.'

current_target_id="$(jq -r '.current_target_id' "$manifest")"
current_target_kind="$(jq -r '.current_target_kind' "$manifest")"
current_diff_artifact="$(jq -r '.current_diff_artifact' "$manifest")"
current_diff_sha256="$(jq -r '.current_diff_sha256' "$manifest")"
if [ -n "${ECI_REVIEW_TARGET_ID:-}" ] && [ "$current_target_id" != "$ECI_REVIEW_TARGET_ID" ]; then
  fail_gate "ECI required-critic review gate target mismatch: expected $ECI_REVIEW_TARGET_ID, got $current_target_id"
fi
if [ -n "${ECI_REVIEW_DIFF_SHA256:-}" ] && [ "$current_diff_sha256" != "$ECI_REVIEW_DIFF_SHA256" ]; then
  fail_gate "ECI required-critic review gate diff mismatch for target $current_target_id"
fi

canonical_artifact() {
  local path="$1"
  local canonical canonical_session

  case "$path" in
    *[![:print:]]*) return 1 ;;
  esac
  canonical_session="$(realpath -m -- "$session_dir" 2>/dev/null || true)"
  canonical="$(realpath -m -- "$path" 2>/dev/null || true)"
  [ -n "$canonical_session" ] && [ -n "$canonical" ] || return 1
  case "$canonical" in
    "$canonical_session"/*) ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  printf '%s\n' "$path"
}

verify_artifact() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local actual

  canonical_artifact "$path" >/dev/null ||
    fail_gate "ECI required-critic review gate denied $label artifact for target $current_target_id: $path"
  actual="$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$expected" ] ||
    fail_gate "ECI required-critic review gate denied stale $label hash for target $current_target_id: $path"
}

target_count="$(jq '.targets | length' "$manifest")"
row_count="$(jq '.rows | length' "$manifest")"

declare -A seen_children=()
declare -A seen_targets=()
target_index=0
while IFS= read -r target; do
  target_id="$(jq -r '.target_id' <<<"$target")"
  target_kind="$(jq -r '.target_kind' <<<"$target")"
  diff_artifact="$(jq -r '.diff_artifact' <<<"$target")"
  diff_sha256="$(jq -r '.diff_sha256' <<<"$target")"
  e2e_required="$(jq -r '.e2e_required' <<<"$target")"
  target_key="$target_id|$target_kind"
  if [ "${seen_targets[$target_key]+set}" = set ]; then
    fail_gate "ECI required-critic review gate found a duplicate governed target: $target_id ($target_kind)"
  fi
  seen_targets[$target_key]=1
  verify_artifact "diff" "$diff_artifact" "$diff_sha256"

  if [ "$target_id" = "$current_target_id" ] && [ "$target_kind" = "$current_target_kind" ]; then
    [ "$diff_artifact" = "$current_diff_artifact" ] && [ "$diff_sha256" = "$current_diff_sha256" ] ||
      fail_gate "ECI required-critic review gate current target/diff binding is inconsistent: $target_id"
  fi

  for required in 'A:postwrite' 'B:postwrite' 'C:prewrite' 'C:postwrite'; do
    role="${required%%:*}"
    gate_phase="${required#*:}"
    matching="$(jq --arg id "$target_id" --arg kind "$target_kind" --arg role "$role" --arg phase "$gate_phase" '[.rows[] | select(.target_id == $id and .target_kind == $kind and .critic_role == $role and .gate_phase == $phase)] | length' "$manifest")"
    [ "$matching" -eq 1 ] ||
      fail_gate "ECI required-critic review gate denied target $target_id ($target_kind): missing or contradictory Critic $role $gate_phase evidence. Spawn one fresh blind Critic $role identity; do not reuse the prior child."
  done

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    row_target_id="$(jq -r '.target_id' <<<"$row")"
    row_target_kind="$(jq -r '.target_kind' <<<"$row")"
    [ "$row_target_id" = "$target_id" ] && [ "$row_target_kind" = "$target_kind" ] || continue
    [ "$(jq -r '.diff_artifact' <<<"$row")" = "$diff_artifact" ] &&
      [ "$(jq -r '.diff_sha256' <<<"$row")" = "$diff_sha256" ] ||
      fail_gate "ECI required-critic review gate found a stale diff binding for target $target_id"
    child="$(jq -r '.child_identity' <<<"$row")"
    if [ "${seen_children[$child]+set}" = set ]; then
      fail_gate "ECI required-critic review gate found a reused child identity: $child"
    fi
    seen_children[$child]=1
    verify_artifact "spawn request" "$(jq -r '.spawn_request_artifact' <<<"$row")" "$(jq -r '.spawn_request_sha256' <<<"$row")"
    verify_artifact "report" "$(jq -r '.report_artifact' <<<"$row")" "$(jq -r '.report_sha256' <<<"$row")"
    row_e2e_required="$(jq -r '.e2e_required' <<<"$row")"
    if [ "$e2e_required" = true ]; then
      [ "$row_e2e_required" = true ] || fail_gate "ECI required-critic review gate denied missing E2E requirement binding for target $target_id"
      verify_artifact "E2E" "$(jq -r '.e2e_artifact' <<<"$row")" "$(jq -r '.e2e_sha256' <<<"$row")"
    else
      [ "$row_e2e_required" = false ] || fail_gate "ECI required-critic review gate denied inconsistent E2E requirement for target $target_id"
    fi
  done < <(jq -c --arg id "$target_id" --arg kind "$target_kind" '.rows[] | select(.target_id == $id and .target_kind == $kind)' "$manifest")
  target_rows="$(jq --arg id "$target_id" --arg kind "$target_kind" '[.rows[] | select(.target_id == $id and .target_kind == $kind)] | length' "$manifest")"
  [ "$target_rows" -eq 4 ] ||
    fail_gate "ECI required-critic review gate denied an incomplete or over-populated critic row set for target $target_id ($target_kind)."
  target_index=$((target_index + 1))
done < <(jq -c '.targets[]' "$manifest")

[ "$row_count" -eq $((target_count * 4)) ] ||
  fail_gate 'ECI required-critic review gate denied an incomplete or over-populated critic row set.'

jq -e --arg current_id "$current_target_id" --arg current_kind "$current_target_kind" --arg current_diff "$current_diff_artifact" --arg current_sha "$current_diff_sha256" '
  any(.targets[]; .target_id == $current_id and .target_kind == $current_kind and .diff_artifact == $current_diff and .diff_sha256 == $current_sha)
' "$manifest" >/dev/null 2>&1 || fail_gate "ECI required-critic review gate current target is not bound to a governed target: $current_target_id"

manifest_sha256="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail_gate 'ECI required-critic review gate could not hash the canonical manifest.'

if [ -e "$admitted" ] || [ -L "$admitted" ]; then
  [ -f "$admitted" ] && [ ! -L "$admitted" ] || fail_gate "ECI required-critic review gate admission record is unsafe: $admitted"
  printf '%s\n' "$manifest_sha256" | cmp -s - "$admitted" ||
    fail_gate "ECI required-critic review gate denied a changed manifest after admission: $manifest"
else
  tmp_admitted="$admitted.tmp.$$"
  [ ! -e "$tmp_admitted" ] && [ ! -L "$tmp_admitted" ] || fail_gate "ECI required-critic review gate temporary admission path is unsafe: $tmp_admitted"
  if ! (set -C; printf '%s\n' "$manifest_sha256" >"$tmp_admitted") ||
    ! ln -- "$tmp_admitted" "$admitted" 2>/dev/null; then
    rm -f -- "$tmp_admitted"
    fail_gate "ECI required-critic review gate could not record immutable admission: $admitted"
  fi
  rm -f -- "$tmp_admitted"
fi

printf 'ECI required-critic review gate passed: phase=%s target=%s\n' "$phase" "$current_target_id"
