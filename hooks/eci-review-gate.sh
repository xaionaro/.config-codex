#!/usr/bin/env bash
# Acceptance boundary for the required-critic ledger.
#
# This script is intentionally absent from Stop's active-marker fast path.  It
# may inspect bounded repository/artifact state and acquire the mutation lock;
# Stop callbacks must remain marker-only and read-only.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

usage() {
  local subject="phase=$(eci_diagnostic_value "${1:-<missing>}"),session=$(eci_diagnostic_value "${2:-<missing>}"),cwd=$(eci_diagnostic_value "${ECI_REVIEW_CWD:-$PWD}")"
  local detail="Usage: eci-review-gate.sh <commit|final|off|prewrite> <session-id>"
  printf '%s\n' "$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$detail")" "Stop" "review-gate-cli" "$subject" "$detail" "invoke the review gate with one supported phase and a valid session id")" >&2
}

fail_gate() {
  local detail="${1:-unspecified review-gate failure}"
  local subject="session=${session_id:-<missing>},cwd=$(eci_diagnostic_value "${ECI_REVIEW_CWD:-$PWD}"),manifest=$(eci_diagnostic_value "${manifest:-${root:-<unresolved>}/${session_id:-<missing>}/eci-required-critics.json}")"
  printf '%s\n' "$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$detail")" "${phase:-startup}" "${phase:-unknown-operation}" "$subject" "$detail" "correct the reported gate input or evidence for the identified session/cwd/manifest, then retry the ${phase:-requested} acceptance operation")" >&2
  exit 1
}

# Review evidence is bounded before hashing or line-oriented parsing.  The
# gate is an acceptance boundary, so a large artifact is a denial rather than
# an invitation to spend unbounded time or memory.
eci_review_artifact_max_bytes=10485760
eci_review_anchor_max_bytes=16384
eci_review_ledger_max_bytes=1048576

phase="${1:-}"
session_id="${2:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
case "$phase" in
  commit|final|off|prewrite) ;;
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
  off_cwd="${ECI_REVIEW_CWD:-$PWD}"
  off_cwd="$(codex_canonical_cwd "$off_cwd")"
  codex_eci_marker_path_owner_is_valid "$marker" ||
    fail_gate 'ECI required-critic review gate rejected teardown: the direct marker path/owner binding is malformed; marker retained.'
  codex_eci_marker_is_valid_for_cwd "$marker" "$off_cwd" ||
    fail_gate 'ECI required-critic review gate rejected teardown: the direct marker cwd binding is malformed or belongs to another cwd; marker retained.'
fi

lock_path="$(codex_eci_lock_path || true)"
[ -n "$lock_path" ] || fail_gate 'ECI required-critic review gate could not resolve the mutation lock.'
[ ! -L "$lock_path" ] && { [ ! -e "$lock_path" ] || [ -f "$lock_path" ]; } ||
  fail_gate "ECI required-critic review gate lock is unsafe: $lock_path"

gate_lock_fd=""
gate_lock_owned=false
if [ -n "${ECI_REVIEW_GATE_FD:-}" ]; then
  case "$ECI_REVIEW_GATE_FD" in
    ''|*[!0-9]*) fail_gate 'ECI required-critic review gate received an invalid inherited lock descriptor.' ;;
  esac
  [ -e "/proc/$$/fd/$ECI_REVIEW_GATE_FD" ] ||
    fail_gate 'ECI required-critic review gate received a missing inherited lock descriptor.'
  fd_target="$(readlink -f -- "/proc/$$/fd/$ECI_REVIEW_GATE_FD" 2>/dev/null || true)"
  lock_real="$(realpath -m -- "$lock_path" 2>/dev/null || true)"
  [ "$fd_target" = "$lock_real" ] ||
    fail_gate 'ECI required-critic review gate rejected an inherited descriptor not bound to the canonical mutation lock.'
  flock -n "$ECI_REVIEW_GATE_FD" 2>/dev/null ||
    fail_gate 'ECI required-critic review gate inherited lock is not held.'
  gate_lock_fd="$ECI_REVIEW_GATE_FD"
else
  # Never trust the old caller-controlled boolean receipts.  Standalone calls
  # acquire the canonical lock themselves, non-blocking.
  if [ "${ECI_REVIEW_GATE_LOCK_HELD:-}" = true ] || [ "${ECI_MUTATION_LOCK_HELD:-}" = true ]; then
    fail_gate 'ECI required-critic review gate rejects caller-controlled lock receipts; pass inherited fd 9 or let the gate acquire the lock.'
  fi
  if ! exec {gate_lock_fd}>>"$lock_path"; then
    fail_gate 'ECI required-critic review gate could not open the mutation lock.'
  fi
  flock -n "$gate_lock_fd" || fail_gate 'ECI required-critic review gate mutation lock is busy.'
  gate_lock_owned=true
fi
if [ -n "$gate_lock_fd" ]; then
  trap 'if [ "$gate_lock_owned" = true ]; then flock -u "$gate_lock_fd" 2>/dev/null || true; eval "exec ${gate_lock_fd}>&-"; fi' EXIT
fi

# A nested ECI never owns the outer marker.  Check this only after acquiring
# the canonical lock, then re-read it while the lock is held so enter/exit
# cannot race the acceptance boundary.
nested="$session_dir/ate_nested_eci_active"
if [ -f "$nested" ] && [ ! -L "$nested" ]; then
  fail_gate "ECI required-critic review gate denied $phase while a nested ECI target is active; exit the nested target first."
elif [ -L "$nested" ]; then
  fail_gate "ECI required-critic review gate found an unsafe nested ECI marker: $nested"
fi

manifest="$session_dir/eci-required-critics.json"
[ -f "$manifest" ] && [ ! -L "$manifest" ] ||
  fail_gate "ECI required-critic review gate denied $phase: missing canonical manifest $manifest"

manifest_bytes="$(wc -c <"$manifest" 2>/dev/null || true)"
case "$manifest_bytes" in ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed manifest size.' ;; esac
[ "$manifest_bytes" -le 65536 ] || fail_gate 'ECI required-critic review gate denied an oversized manifest (limit 65536 bytes).'
[ "$(tail -c 1 -- "$manifest" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
  fail_gate 'ECI required-critic review gate denied a manifest without exactly one final LF.'
[ "$(awk 'END { print NR + 0 }' "$manifest" 2>/dev/null || printf '0')" -eq 1 ] ||
  fail_gate 'ECI required-critic review gate requires one compact JSON line plus its final LF.'
LC_ALL=C grep -q $'\r' "$manifest" && fail_gate 'ECI required-critic review gate denied carriage returns in the manifest.' || true
jq -e . "$manifest" >/dev/null 2>&1 || fail_gate 'ECI required-critic review gate denied invalid UTF-8 or malformed JSON.'
jq -c . "$manifest" | cmp -s - "$manifest" ||
  fail_gate 'ECI required-critic review gate requires compact canonical JSON with the fixed member order.'

top_keys='["schema","current_target_id","current_target_kind","current_diff_artifact","current_diff_sha256","current_target_path","repo_root","git_dir","git_common_dir","base_oid","head_oid","staged_diff_sha256","worktree_diff_sha256","status_sha256","target_file_hashes","acceptance_version","targets","rows"]'
row_keys='["target_id","target_kind","diff_artifact","diff_sha256","critic_role","gate_phase","child_identity","critic_provider","critic_semantic_role","critic_provenance","spawn_request_artifact","spawn_request_sha256","report_artifact","report_sha256","adjudication_artifact","adjudication_sha256","verdict","e2e_required","e2e_artifact","e2e_sha256","repo_root","git_dir","git_common_dir","base_oid","head_oid","staged_diff_sha256","worktree_diff_sha256","status_sha256","target_path","target_version","intention_artifact","intention_sha256","acceptance_version"]'
target_keys='["target_id","target_kind","diff_artifact","diff_sha256","e2e_required","target_path","target_version"]'
if ! jq -e --argjson expected "$top_keys" --argjson rows_expected "$row_keys" --argjson targets_expected "$target_keys" '
  (keys_unsorted == $expected) and
  (.schema == "eci-required-critics/v2") and
  (.current_target_id | type == "string") and (.current_target_kind | type == "string") and
  (.current_diff_artifact | type == "string") and (.current_diff_sha256 | test("^[0-9a-f]{64}$")) and
  (.current_target_path | type == "string") and (.repo_root | type == "string") and
  (.git_dir | type == "string") and (.git_common_dir | type == "string") and
  (.base_oid | test("^[0-9a-f]{40,64}$")) and (.head_oid | test("^[0-9a-f]{40,64}$")) and
  (.staged_diff_sha256 | test("^[0-9a-f]{64}$")) and (.worktree_diff_sha256 | test("^[0-9a-f]{64}$")) and
  (.status_sha256 | test("^[0-9a-f]{64}$")) and (.target_file_hashes | type == "object") and
  (.acceptance_version | test("^[1-9][0-9]*$")) and (.targets | type == "array" and length > 0) and
  (.rows | type == "array" and length > 0) and
  all(.targets[]; keys_unsorted == $targets_expected and (.target_id | type == "string") and
    (.target_kind | . == "root" or . == "subtask" or . == "candidate-fix") and
    (.diff_artifact | type == "string") and (.diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.e2e_required | type == "boolean") and (.target_path | type == "string") and
    (.target_version | test("^[0-9a-f]{64}$"))) and
  all(.rows[]; keys_unsorted == $rows_expected and (.target_id | type == "string") and
    (.target_kind | . == "root" or . == "subtask" or . == "candidate-fix") and
    (.diff_artifact | type == "string") and (.diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.critic_role | . == "A" or . == "B" or . == "C") and
    (.gate_phase | . == "prewrite" or . == "postwrite") and
    (.child_identity | type == "string" and length > 0) and
    (.critic_provider | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")) and
    (.critic_semantic_role == ("ECI Critic " + .critic_role)) and
    (.critic_provenance | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.:/=-]{0,255}$")) and
    (.spawn_request_artifact | type == "string") and (.spawn_request_sha256 | test("^[0-9a-f]{64}$")) and
    (.report_artifact | type == "string") and (.report_sha256 | test("^[0-9a-f]{64}$")) and
    (.adjudication_artifact | type == "string") and (.adjudication_sha256 | test("^[0-9a-f]{64}$")) and
    (.verdict == "PASS") and (.e2e_required | type == "boolean") and
    (((.e2e_required and (.e2e_artifact | type == "string") and (.e2e_sha256 | test("^[0-9a-f]{64}$"))) or
      ((.e2e_required | not) and .e2e_artifact == null and .e2e_sha256 == null))) and
    (.repo_root | type == "string") and (.git_dir | type == "string") and (.git_common_dir | type == "string") and
    (.base_oid | test("^[0-9a-f]{40,64}$")) and (.head_oid | test("^[0-9a-f]{40,64}$")) and
    (.staged_diff_sha256 | test("^[0-9a-f]{64}$")) and (.worktree_diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.status_sha256 | test("^[0-9a-f]{64}$")) and (.target_path | type == "string") and
    (.target_version | test("^[0-9a-f]{64}$")) and (.intention_artifact == null or (.intention_artifact | type == "string")) and
    (.intention_sha256 == null or (.intention_sha256 | test("^[0-9a-f]{64}$"))) and
    (.acceptance_version | test("^[1-9][0-9]*$")))
' "$manifest" >/dev/null 2>&1; then
  fail_gate 'ECI required-critic review gate denied manifest v2 schema, ordering, binding, or verdict fields.'
fi

acceptance_version="$(jq -r '.acceptance_version' "$manifest")"
[[ "$acceptance_version" =~ ^[1-9][0-9]*$ ]] ||
  fail_gate "ECI required-critic review gate denied noncanonical acceptance_version: $acceptance_version"

ledger="$session_dir/eci-required-critics.$phase.$acceptance_version.ledger"

current_target_id="$(jq -r '.current_target_id' "$manifest")"
current_target_kind="$(jq -r '.current_target_kind' "$manifest")"
current_diff_artifact="$(jq -r '.current_diff_artifact' "$manifest")"
current_diff_sha256="$(jq -r '.current_diff_sha256' "$manifest")"
current_target_path="$(jq -r '.current_target_path' "$manifest")"
if [ -n "${ECI_REVIEW_TARGET_ID:-}" ] && [ "$current_target_id" != "$ECI_REVIEW_TARGET_ID" ]; then
  fail_gate "ECI required-critic review gate target mismatch: expected $ECI_REVIEW_TARGET_ID, got $current_target_id"
fi
if [ -n "${ECI_REVIEW_DIFF_SHA256:-}" ] && [ "$current_diff_sha256" != "$ECI_REVIEW_DIFF_SHA256" ]; then
  fail_gate "ECI required-critic review gate diff mismatch for target $current_target_id"
fi
jq -e --arg id "$current_target_id" --arg kind "$current_target_kind" --arg diff "$current_diff_artifact" --arg sha "$current_diff_sha256" --arg path "$current_target_path" '
  any(.targets[]; .target_id == $id and .target_kind == $kind and
    .diff_artifact == $diff and .diff_sha256 == $sha and .target_path == $path)
' "$manifest" >/dev/null 2>&1 ||
  fail_gate "ECI required-critic review gate current target is not bound to a governed target: $current_target_id"

canonical_artifact() {
  local path="$1" base="$session_dir" canonical base_real parent part rest rest_lexical
  case "$path" in *[![:print:]]*) return 1 ;; esac
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  canonical="$(realpath -m -- "$path" 2>/dev/null || true)"
  base_real="$(realpath -m -- "$base" 2>/dev/null || true)"
  [ -n "$canonical" ] && [ -n "$base_real" ] || return 1
  [ "$canonical" = "$path" ] || return 1
  case "$canonical" in "$base_real"/*) ;; *) return 1 ;; esac
  rest="${canonical#"$base_real"/}"; parent="$base_real"
  rest_lexical="${path#"$base"/}"; parent="$base"
  while [ -n "$rest_lexical" ]; do
    part="${rest_lexical%%/*}"; parent="$parent/$part"
    [ ! -L "$parent" ] || return 1
    [ "$rest_lexical" = "$part" ] && rest_lexical="" || rest_lexical="${rest_lexical#*/}"
  done
  [ -f "$path" ] && [ ! -L "$path" ]
}

repo_path_safe() {
  local path="$1" repo="$2" canonical rest part parent
  case "$path" in *[![:print:]]*) return 1 ;; esac
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  canonical="$(realpath -m -- "$path" 2>/dev/null || true)"
  [ "$canonical" = "$path" ] || return 1
  case "$canonical" in "$repo"/*) ;; *) return 1 ;; esac
  rest="${canonical#"$repo"/}"; parent="$repo"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"; parent="$parent/$part"; [ ! -L "$parent" ] || return 1
    [ "$rest" = "$part" ] && rest="" || rest="${rest#*/}"
  done
  [ -f "$path" ] || return 1
}

verify_artifact() {
  local label="$1" path="$2" expected="$3" actual bytes
  canonical_artifact "$path" || fail_gate "ECI required-critic review gate denied $label artifact for target $current_target_id: $path"
  bytes="$(wc -c <"$path" 2>/dev/null || true)"
  case "$bytes" in
    ''|*[!0-9]*) fail_gate "ECI required-critic review gate denied malformed $label artifact size for target $current_target_id: $path" ;;
  esac
  [ "$bytes" -le "$eci_review_artifact_max_bytes" ] ||
    fail_gate "ECI required-critic review gate denied oversized $label artifact for target $current_target_id (limit $eci_review_artifact_max_bytes bytes): $path"
  actual="$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail_gate "ECI required-critic review gate denied stale $label hash for target $current_target_id: $path"
}

# A spawn request is an evidence-bearing record, not merely an opaque file
# whose digest happened to be copied into the manifest.  Bind the provider,
# semantic role, child identity, and provenance to the exact canonical bytes
# so a forged row cannot substitute a different critic behind the same role.
verify_spawn_request_artifact() {
  local path="$1" expected_sha="$2" role_expected="$3" child_expected="$4"
  local provider_expected="$5" semantic_role_expected="$6" provenance_expected="$7"
  local parent_session_expected="$8" target_id_expected="$9" gate_phase_expected="${10}"
  local authority_expected="${11}" model_class_expected="${12}"
  local line_count lines
  verify_artifact 'spawn request' "$path" "$expected_sha"
  verify_bounded_text_file 'spawn request' "$path" "$eci_review_artifact_max_bytes"
  mapfile -t lines <"$path" ||
    fail_gate "ECI required-critic review gate could not read spawn request for target $current_target_id: $path"
  [ "${#lines[@]}" -eq 11 ] ||
    fail_gate "ECI required-critic review gate denied spawn request field count for target $current_target_id: $path"
  [ "${lines[0]}" = 'schema: eci-critic-spawn/v2' ] ||
    fail_gate "ECI required-critic review gate denied spawn request schema for target $current_target_id: $path"
  [ "${lines[1]}" = "provider: $provider_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn provider binding for target $current_target_id: $path"
  [ "${lines[2]}" = "semantic_role: $semantic_role_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn semantic-role binding for target $current_target_id: $path"
  [ "${lines[3]}" = "authority: $authority_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn authority binding for target $current_target_id: $path"
  [ "${lines[4]}" = "required_model_class: $model_class_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn model-class binding for target $current_target_id: $path"
  [ "${lines[5]}" = "parent_session: $parent_session_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn parent-session binding for target $current_target_id: $path"
  [ "${lines[6]}" = "target_id: $target_id_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn target binding for target $current_target_id: $path"
  [ "${lines[7]}" = "critic_role: $role_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn critic-role binding for target $current_target_id: $path"
  [ "${lines[8]}" = "gate_phase: $gate_phase_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn gate-phase binding for target $current_target_id: $path"
  [ "${lines[9]}" = "child_identity: $child_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn child binding for target $current_target_id: $path"
  [ "${lines[10]}" = "provenance: $provenance_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn provenance binding for target $current_target_id: $path"
  [[ "$provider_expected" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]] ||
    fail_gate "ECI required-critic review gate denied malformed spawn provider for target $current_target_id: $path"
  [ "$semantic_role_expected" = "ECI Critic $role_expected" ] ||
    fail_gate "ECI required-critic review gate denied spawn semantic role for target $current_target_id: $path"
  [ "$parent_session_expected" = "$session_id" ] ||
    fail_gate "ECI required-critic review gate denied spawn parent session for target $current_target_id: $path"
  case "$authority_expected:$model_class_expected:$role_expected" in
    authoritative:special:C|non-authoritative:ordinary:A|non-authoritative:ordinary:B) ;;
    *) fail_gate "ECI required-critic review gate denied critic authority/model class for target $current_target_id: $path" ;;
  esac
  [[ "$provenance_expected" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/=-]{0,255}$ ]] ||
    fail_gate "ECI required-critic review gate denied malformed spawn provenance for target $current_target_id: $path"
}

verify_report_identity() {
  local path="$1" target_id_expected="$2" role_expected="$3" gate_phase_expected="$4"
  local child_expected="$5" provider_expected="$6" semantic_role_expected="$7" provenance_expected="$8"
  local identity
  identity="eci_critic_identity: session_id=$session_id;target_id=$target_id_expected;critic_role=$role_expected;gate_phase=$gate_phase_expected;child_identity=$child_expected;critic_provider=$provider_expected;critic_semantic_role=$semantic_role_expected;critic_provenance=$provenance_expected"
  [ "$(grep -c '^eci_critic_identity: ' "$path" 2>/dev/null || true)" -eq 1 ] ||
    fail_gate "ECI required-critic review gate denied report identity marker count for target $target_id_expected: $path"
  grep -Fqx -- "$identity" "$path" ||
    fail_gate "ECI required-critic review gate denied report identity binding for target $target_id_expected: $path"
}

verify_report_text() {
  local path="$1"
  if ! python3 - "$path" <<'PY'
from pathlib import Path
import re
import sys

try:
    raw = Path(sys.argv[1]).read_bytes()
    text = raw.decode("utf-8")
except (OSError, UnicodeDecodeError):
    raise SystemExit(1)

# Reports are bounded text records. Allow only tab and LF among control bytes;
# reject CR, C0 controls, DEL, malformed UTF-8, and a missing final LF.
if not raw or not raw.endswith(b"\n"):
    raise SystemExit(1)
if any((byte < 0x20 and byte != 0x09 and byte != 0x0A) or byte == 0x7F for byte in raw):
    raise SystemExit(1)
lines = text.splitlines(keepends=True)
marker_re = re.compile(r"^eci_critic_verdict: (APPROVED|CONDITIONAL|REJECTED)\n$")
markers = [index for index, line in enumerate(lines) if marker_re.fullmatch(line)]
if len(markers) != 1 or markers[0] != len(lines) - 1:
    raise SystemExit(1)
if not any(line.strip() for line in lines[:-1]):
    raise SystemExit(1)
PY
  then
    fail_gate "ECI required-critic review gate denied report artifact text contract: $path"
  fi
}

verify_report_verdict() {
  local path="$1" expected="$2" marker marker_count
  marker="$(tail -n 1 -- "$path" 2>/dev/null || true)"
  marker_count="$(grep -c '^eci_critic_verdict: \(APPROVED\|CONDITIONAL\|REJECTED\)$' "$path" 2>/dev/null || true)"
  [ "$marker_count" -eq 1 ] && [ "$marker" = "eci_critic_verdict: $expected" ] ||
    fail_gate "ECI required-critic review gate denied a report whose canonical verdict marker does not match its adjudication: $path"
}

verify_bounded_text_file() {
  local label="$1" path="$2" limit="$3" bytes
  [ -f "$path" ] && [ ! -L "$path" ] ||
    fail_gate "ECI required-critic review gate found an unsafe $label: $path"
  bytes="$(wc -c <"$path" 2>/dev/null || true)"
  case "$bytes" in
    ''|*[!0-9]*) fail_gate "ECI required-critic review gate denied malformed $label size: $path" ;;
  esac
  [ "$bytes" -le "$limit" ] ||
    fail_gate "ECI required-critic review gate denied oversized $label (limit $limit bytes): $path"
  [ "$bytes" -eq 0 ] ||
    [ "$(tail -c 1 -- "$path" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate "ECI required-critic review gate denied a $label without a final LF: $path"
}

# A manifest PASS is a coordinator admission result, not permission to erase
# an independent critic's CONDITIONAL/REJECTED report.  Every row therefore
# carries a compact, closed adjudication record bound to the exact report and
# row tuple.  APPROVED may be accepted directly; a non-APPROVED source verdict
# requires an explicit bounded downgrade decision and reason.
verify_adjudication_artifact() {
  local path="$1" expected_sha="$2" target_id_expected="$3" role_expected="$4" phase_expected="$5" child_expected="$6"
  local provider_expected="$7" semantic_role_expected="$8" provenance_expected="$9" report_sha_expected="${10}"
  verify_artifact adjudication "$path" "$expected_sha"
  [ "$(awk 'END { print NR + 0 }' "$path" 2>/dev/null || printf '0')" -eq 1 ] ||
    fail_gate "ECI required-critic review gate denied a multi-line adjudication artifact: $path"
  [ "$(tail -c 1 -- "$path" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate "ECI required-critic review gate denied an adjudication artifact without a final LF: $path"
  jq -c . "$path" | cmp -s - "$path" ||
    fail_gate "ECI required-critic review gate denied noncanonical adjudication JSON: $path"
  jq -e \
    --arg target "$target_id_expected" --arg role "$role_expected" --arg phase "$phase_expected" \
    --arg child "$child_expected" --arg provider "$provider_expected" --arg semantic_role "$semantic_role_expected" \
    --arg provenance "$provenance_expected" --arg report "$report_sha_expected" \
    'keys_unsorted == ["schema","target_id","critic_role","gate_phase","child_identity","critic_provider","critic_semantic_role","critic_provenance","report_sha256","source_verdict","decision","reason"] and
     .schema == "eci-critic-adjudication/v1" and .target_id == $target and .critic_role == $role and
     .gate_phase == $phase and .child_identity == $child and .critic_provider == $provider and
     .critic_semantic_role == $semantic_role and .critic_provenance == $provenance and .report_sha256 == $report and
     (.source_verdict == "APPROVED" or .source_verdict == "CONDITIONAL" or .source_verdict == "REJECTED") and
     (.reason | type == "string" and length > 0 and length <= 512) and
     ((.source_verdict == "APPROVED" and .decision == "accepted") or
      ((.source_verdict == "CONDITIONAL" or .source_verdict == "REJECTED") and .decision == "downgraded"))' \
    "$path" >/dev/null 2>&1 ||
    fail_gate "ECI required-critic review gate denied an unbound or silent critic adjudication: $path"
  adjudication_source_verdict="$(jq -r '.source_verdict' "$path")"
}

review_cwd="${ECI_REVIEW_CWD:-$PWD}"
review_cwd="$(realpath -m -- "$review_cwd" 2>/dev/null || true)"
[ -n "$review_cwd" ] && [ -d "$review_cwd" ] && [ ! -L "$review_cwd" ] ||
  fail_gate 'ECI required-critic review gate rejected an unsafe review cwd.'
canonical_git_path() {
  local raw="$1"
  case "$raw" in
    /*) realpath -m -- "$raw" 2>/dev/null || true ;;
    *) realpath -m -- "$review_cwd/$raw" 2>/dev/null || true ;;
  esac
}
repo_root_raw="$(codex_git_safe -C "$review_cwd" rev-parse --show-toplevel 2>/dev/null || true)"
repo_root_actual="$(canonical_git_path "$repo_root_raw")"
[ -n "$repo_root_actual" ] || fail_gate 'ECI required-critic review gate could not resolve the governed repository.'
git_dir_raw="$(codex_git_safe -C "$review_cwd" rev-parse --git-dir 2>/dev/null || true)"
git_common_raw="$(codex_git_safe -C "$review_cwd" rev-parse --git-common-dir 2>/dev/null || true)"
git_dir_actual="$(canonical_git_path "$git_dir_raw")"
git_common_actual="$(canonical_git_path "$git_common_raw")"
[ -n "$git_dir_actual" ] && [ -n "$git_common_actual" ] || fail_gate 'ECI required-critic review gate could not resolve canonical git paths.'
case "$repo_root_actual$git_dir_actual$git_common_actual" in
  *[![:print:]]*) fail_gate 'ECI required-critic review gate rejected non-printable repository binding paths.' ;;
esac
head_actual="$(codex_git_safe -C "$repo_root_actual" rev-parse HEAD 2>/dev/null || true)"
base_actual="$head_actual"
if [ -e "$session_dir/baseline_head.binding" ] || [ -L "$session_dir/baseline_head.binding" ]; then
  [ -e "$session_dir/baseline_head" ] && [ ! -L "$session_dir/baseline_head" ] ||
    fail_gate 'ECI required-critic review gate found a baseline binding without its immutable baseline_head.'
fi
if [ -e "$session_dir/baseline_head" ] || [ -L "$session_dir/baseline_head" ]; then
  verify_bounded_text_file 'baseline_head' "$session_dir/baseline_head" 4096
  mapfile -t baseline_lines <"$session_dir/baseline_head" ||
    fail_gate 'ECI required-critic review gate could not read baseline_head.'
  [ "${#baseline_lines[@]}" -eq 1 ] ||
    fail_gate 'ECI required-critic review gate rejected a multi-line baseline_head.'
  base_actual="${baseline_lines[0]}"
fi
[[ "$base_actual" =~ ^[0-9a-f]{40,64}$ ]] ||
  fail_gate 'ECI required-critic review gate rejected a malformed baseline base_oid.'
codex_git_safe -C "$repo_root_actual" cat-file -e "$base_actual^{commit}" >/dev/null 2>&1 ||
  fail_gate 'ECI required-critic review gate rejected a baseline base_oid that does not resolve in the governed repository.'
if [ -e "$session_dir/baseline_head" ] || [ -L "$session_dir/baseline_head" ]; then
  baseline_binding="$session_dir/baseline_head.binding"
  verify_bounded_text_file 'baseline binding' "$baseline_binding" 4096
  mapfile -t baseline_binding_lines <"$baseline_binding" ||
    fail_gate 'ECI required-critic review gate could not read the baseline binding.'
  [ "${#baseline_binding_lines[@]}" -eq 7 ] ||
    fail_gate 'ECI required-critic review gate rejected an incomplete baseline binding.'
  [ "${baseline_binding_lines[0]}" = 'schema: eci-baseline-binding/v1' ] ||
    fail_gate 'ECI required-critic review gate rejected an unsupported baseline binding schema.'
  [ "${baseline_binding_lines[1]}" = "session_id: $session_id" ] ||
    fail_gate 'ECI required-critic review gate rejected a baseline binding session mismatch.'
  [ "${baseline_binding_lines[2]}" = "cwd: $review_cwd" ] ||
    fail_gate 'ECI required-critic review gate rejected a baseline binding cwd mismatch.'
  [ "${baseline_binding_lines[3]}" = "repo_root: $repo_root_actual" ] ||
    fail_gate 'ECI required-critic review gate rejected a baseline binding repository mismatch.'
  [ "${baseline_binding_lines[4]}" = "git_dir: $git_dir_actual" ] ||
    fail_gate 'ECI required-critic review gate rejected a baseline binding git-dir mismatch.'
  [ "${baseline_binding_lines[5]}" = "git_common_dir: $git_common_actual" ] ||
    fail_gate 'ECI required-critic review gate rejected a baseline binding common-dir mismatch.'
  [ "${baseline_binding_lines[6]}" = "base_oid: $base_actual" ] ||
    fail_gate 'ECI required-critic review gate rejected a substituted baseline binding.'
fi
staged_actual="$(codex_git_safe -C "$repo_root_actual" diff --cached --binary | sha256sum | awk '{print $1}')"
worktree_actual="$(codex_git_safe -C "$repo_root_actual" diff --binary | sha256sum | awk '{print $1}')"
status_actual="$(codex_git_safe -C "$repo_root_actual" status --porcelain=v1 --untracked-files=all | sha256sum | awk '{print $1}')"
repo_binding_sha256="$(printf 'repo_root=%s\ngit_dir=%s\ngit_common_dir=%s\nbase_oid=%s\nhead_oid=%s\nstaged_diff_sha256=%s\nworktree_diff_sha256=%s\nstatus_sha256=%s\n' \
  "$repo_root_actual" "$git_dir_actual" "$git_common_actual" "$base_actual" "$head_actual" \
  "$staged_actual" "$worktree_actual" "$status_actual" | sha256sum | awk '{print $1}')"
[[ "$repo_binding_sha256" =~ ^[0-9a-f]{64}$ ]] || fail_gate 'ECI required-critic review gate could not derive the live repository binding.'
jq -e --arg root "$repo_root_actual" --arg gd "$git_dir_actual" --arg gc "$git_common_actual" --arg base "$base_actual" --arg head "$head_actual" --arg staged "$staged_actual" --arg work "$worktree_actual" --arg status "$status_actual" '
  .repo_root == $root and .git_dir == $gd and .git_common_dir == $gc and .base_oid == $base and .head_oid == $head and
  .staged_diff_sha256 == $staged and .worktree_diff_sha256 == $work and .status_sha256 == $status
' "$manifest" >/dev/null 2>&1 || fail_gate 'ECI required-critic review gate denied stale, alternate, or drifted repository binding.'

staged_dirty=false
if codex_git_safe -C "$repo_root_actual" diff --cached --quiet --binary; then
  :
else
  diff_status=$?
  [ "$diff_status" -eq 1 ] || fail_gate 'ECI required-critic review gate could not inspect the staged diff.'
  staged_dirty=true
fi
worktree_dirty=false
if codex_git_safe -C "$repo_root_actual" diff --quiet --binary; then
  :
else
  diff_status=$?
  [ "$diff_status" -eq 1 ] || fail_gate 'ECI required-critic review gate could not inspect the worktree diff.'
  worktree_dirty=true
fi
[ "$staged_dirty" = false ] || [ "$worktree_dirty" = false ] ||
  fail_gate 'ECI required-critic review gate denied a mixed staged and worktree diff; represent one snapshot explicitly before acceptance.'
if [ "$staged_dirty" = true ]; then
  trusted_diff_sha256="$(codex_git_safe -C "$repo_root_actual" diff --cached --binary | sha256sum | awk '{print $1}')"
elif [ "$worktree_dirty" = true ]; then
  trusted_diff_sha256="$(codex_git_safe -C "$repo_root_actual" diff --binary | sha256sum | awk '{print $1}')"
else
  trusted_diff_sha256="$(codex_git_safe -C "$repo_root_actual" diff --binary "$base_actual" "$head_actual" | sha256sum | awk '{print $1}')"
fi
[ "$current_diff_sha256" = "$trusted_diff_sha256" ] ||
  fail_gate 'ECI required-critic review gate denied a diff artifact that does not match the trusted canonical repository diff.'
jq -e --arg trusted "$trusted_diff_sha256" 'all(.targets[]; .diff_sha256 == $trusted)' "$manifest" >/dev/null 2>&1 ||
  fail_gate 'ECI required-critic review gate denied a governed target with a noncanonical diff binding.'

declare -A trusted_changed_paths=()
declare -A untracked_changed_paths=()
add_trusted_changed_path() {
  local relative="$1" absolute
  [ -n "$relative" ] || return 0
  case "$relative" in
    /*|*[^[:print:]]*) fail_gate 'ECI required-critic review gate denied a noncanonical changed path.' ;;
  esac
  absolute="$(realpath -m -- "$repo_root_actual/$relative" 2>/dev/null || true)"
  [ "$absolute" = "$repo_root_actual/$relative" ] ||
    fail_gate 'ECI required-critic review gate denied a changed path with traversal or symlinked components.'
  case "$absolute" in
    "$repo_root_actual"/*) trusted_changed_paths["$absolute"]=1 ;;
    *) fail_gate 'ECI required-critic review gate denied a changed path outside the repository.' ;;
  esac
}

if [ "$staged_dirty" = true ]; then
  while IFS= read -r -d '' changed; do
    add_trusted_changed_path "$changed"
  done < <(codex_git_safe -C "$repo_root_actual" diff --cached --name-only -z --no-renames)
elif [ "$worktree_dirty" = true ]; then
  while IFS= read -r -d '' changed; do
    add_trusted_changed_path "$changed"
  done < <(codex_git_safe -C "$repo_root_actual" diff --name-only -z --no-renames)
else
  while IFS= read -r -d '' changed; do
    add_trusted_changed_path "$changed"
  done < <(codex_git_safe -C "$repo_root_actual" diff --name-only -z --no-renames "$base_actual" "$head_actual")
fi

# Git diff omits untracked files. Include their paths in the trusted changed
# set; target_file_hashes remains the content binding for those targets.
while IFS= read -r -d '' status_record; do
  status_code="${status_record:0:2}"
  status_path="${status_record:3}"
  add_trusted_changed_path "$status_path"
  if [ "$status_code" = '??' ]; then
    status_absolute="$(realpath -m -- "$repo_root_actual/$status_path" 2>/dev/null || true)"
    [ "$status_absolute" = "$repo_root_actual/$status_path" ] ||
      fail_gate 'ECI required-critic review gate denied a noncanonical untracked path.'
    untracked_changed_paths["$status_absolute"]=1
  fi
  case "$status_code" in
    R*|C*)
      IFS= read -r -d '' status_path || true
      add_trusted_changed_path "$status_path"
      ;;
  esac
done < <(codex_git_safe -C "$repo_root_actual" status --porcelain=v1 --untracked-files=all -z)

target_path="$current_target_path"
[ -e "$target_path" ] ||
  fail_gate "ECI required-critic review gate does not support deletion-only governed targets; represent the deleted path in a dedicated review artifact: $target_path"
repo_path_safe "$target_path" "$repo_root_actual" || fail_gate "ECI required-critic review gate denied target outside the canonical repository: $target_path"
[ -n "${trusted_changed_paths[$target_path]+x}" ] ||
  fail_gate "ECI required-critic review gate denied target not present in the trusted changed-path set: $target_path"
[ -n "${untracked_changed_paths[$target_path]+x}" ] &&
  fail_gate "ECI required-critic review gate denied an untracked-only governed target; include its bytes in a canonical diff artifact before admission: $target_path"
target_version_actual="$(sha256sum -- "$target_path" 2>/dev/null | awk '{print $1}')"
jq -e --arg path "$target_path" --arg sha "$target_version_actual" '.target_file_hashes[$path] == $sha' "$manifest" >/dev/null 2>&1 ||
  fail_gate "ECI required-critic review gate denied a stale target file binding: $target_path"
jq -e '([.targets[].target_path] | unique | sort) == ([.target_file_hashes | keys[]] | sort)' "$manifest" >/dev/null 2>&1 ||
  fail_gate 'ECI required-critic review gate denied target_file_hashes that do not exactly cover the governed target paths.'

verify_target_path() {
  local obj="$1" path version
  path="$(jq -r '.target_path' <<<"$obj")"; version="$(jq -r '.target_version' <<<"$obj")"
  [ -e "$path" ] || fail_gate "ECI required-critic review gate does not support deletion-only governed targets; represent the deleted path in a dedicated review artifact: $path"
  repo_path_safe "$path" "$repo_root_actual" || fail_gate "ECI required-critic review gate denied target path: $path"
  [ -n "${trusted_changed_paths[$path]+x}" ] || fail_gate "ECI required-critic review gate denied target not present in the trusted changed-path set: $path"
  [ -z "${untracked_changed_paths[$path]+x}" ] || fail_gate "ECI required-critic review gate denied an untracked-only governed target; include its bytes in a canonical diff artifact before admission: $path"
  jq -e --arg path "$path" --arg version "$version" '.target_file_hashes[$path] == $version' "$manifest" >/dev/null 2>&1 ||
    fail_gate "ECI required-critic review gate denied missing target file binding: $path"
  [ "$(sha256sum -- "$path" | awk '{print $1}')" = "$version" ] || fail_gate "ECI required-critic review gate denied stale target version: $path"
}

target_count="$(jq '.targets | length' "$manifest")"
row_count="$(jq '.rows | length' "$manifest")"
declare -A seen_children=() seen_targets=() seen_tuples=()
optional_prewrite_count=0
if [ "$phase" = prewrite ]; then
  required_specs=('C:prewrite')
  expected_rows_per_target=1
else
  required_specs=('A:postwrite' 'B:postwrite' 'C:postwrite')
  expected_rows_per_target=3
fi
while IFS= read -r target; do
  target_id="$(jq -r '.target_id' <<<"$target")"; target_kind="$(jq -r '.target_kind' <<<"$target")"
  diff_artifact="$(jq -r '.diff_artifact' <<<"$target")"; diff_sha256="$(jq -r '.diff_sha256' <<<"$target")"
  target_e2e_required="$(jq -r '.e2e_required' <<<"$target")"
  target_key="$target_id|$target_kind"
  [ -z "${seen_targets[$target_key]+x}" ] || fail_gate "ECI required-critic review gate found a duplicate governed target: $target_id ($target_kind)"
  seen_targets[$target_key]=1; verify_artifact diff "$diff_artifact" "$diff_sha256"; verify_target_path "$target"
  if [ "$phase" != prewrite ]; then
    prewrite_matching="$(jq --arg id "$target_id" --arg kind "$target_kind" '[.rows[] | select(.target_id == $id and .target_kind == $kind and .critic_role == "C" and .gate_phase == "prewrite")] | length' "$manifest")"
    [ "$prewrite_matching" -le 1 ] || fail_gate "ECI required-critic review gate found contradictory Critic C prewrite evidence for $target_id ($target_kind)"
    [ "$prewrite_matching" -eq 0 ] || optional_prewrite_count=$((optional_prewrite_count + 1))
  fi
  for required in "${required_specs[@]}"; do
    role="${required%%:*}"; gate_phase="${required#*:}"
    matching="$(jq --arg id "$target_id" --arg kind "$target_kind" --arg role "$role" --arg phase "$gate_phase" '[.rows[] | select(.target_id == $id and .target_kind == $kind and .critic_role == $role and .gate_phase == $phase)] | length' "$manifest")"
    [ "$matching" -eq 1 ] || fail_gate "ECI required-critic review gate denied target $target_id ($target_kind): missing or contradictory Critic $role $gate_phase evidence. Spawn one fresh blind Critic $role identity; do not reuse the prior child."
  done
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(jq -r '.target_id' <<<"$row")" = "$target_id" ] && [ "$(jq -r '.target_kind' <<<"$row")" = "$target_kind" ] || continue
    [ "$(jq -r '.diff_artifact' <<<"$row")" = "$diff_artifact" ] && [ "$(jq -r '.diff_sha256' <<<"$row")" = "$diff_sha256" ] || fail_gate "ECI required-critic review gate found a stale diff binding for target $target_id"
    child="$(jq -r '.child_identity' <<<"$row")"; [ -z "${seen_children[$child]+x}" ] || fail_gate "ECI required-critic review gate found a reused child identity: $child"; seen_children[$child]=1
    critic_role="$(jq -r '.critic_role' <<<"$row")"
    critic_provider="$(jq -r '.critic_provider' <<<"$row")"
    critic_semantic_role="$(jq -r '.critic_semantic_role' <<<"$row")"
    critic_provenance="$(jq -r '.critic_provenance' <<<"$row")"
    [ "$critic_semantic_role" = "ECI Critic $critic_role" ] ||
      fail_gate "ECI required-critic review gate denied semantic critic-role binding for target $target_id"
    row_acceptance_version="$(jq -r '.acceptance_version' <<<"$row")"
    [ "$row_acceptance_version" = "$acceptance_version" ] ||
      fail_gate "ECI required-critic review gate found a changed acceptance_version for target $target_id"
    tuple="$target_id|$target_kind|$child|$critic_role|$(jq -r '.gate_phase' <<<"$row")|$critic_provider|$critic_provenance"; [ -z "${seen_tuples[$tuple]+x}" ] || fail_gate "ECI required-critic review gate found a duplicate admission tuple: $tuple"; seen_tuples[$tuple]=1
    jq -e --arg root "$repo_root_actual" --arg gd "$git_dir_actual" --arg gc "$git_common_actual" --arg base "$base_actual" --arg head "$head_actual" --arg staged "$staged_actual" --arg work "$worktree_actual" --arg status "$status_actual" --arg path "$(jq -r '.target_path' <<<"$target")" --arg ver "$(jq -r '.target_version' <<<"$target")" '.repo_root==$root and .git_dir==$gd and .git_common_dir==$gc and .base_oid==$base and .head_oid==$head and .staged_diff_sha256==$staged and .worktree_diff_sha256==$work and .status_sha256==$status and .target_path==$path and .target_version==$ver' <<<"$row" >/dev/null || fail_gate "ECI required-critic review gate denied repository/target binding for $target_id"
    verify_spawn_request_artifact \
      "$(jq -r '.spawn_request_artifact' <<<"$row")" "$(jq -r '.spawn_request_sha256' <<<"$row")" \
      "$critic_role" "$child" "$critic_provider" "$critic_semantic_role" "$critic_provenance" \
      "$session_id" "$target_id" "$(jq -r '.gate_phase' <<<"$row")" \
      "$([ "$critic_role" = C ] && printf authoritative || printf non-authoritative)" \
      "$([ "$critic_role" = C ] && printf special || printf ordinary)"
    report_artifact_path="$(jq -r '.report_artifact' <<<"$row")"
    verify_artifact report "$report_artifact_path" "$(jq -r '.report_sha256' <<<"$row")"
    verify_report_text "$report_artifact_path"
    verify_report_identity \
      "$report_artifact_path" "$target_id" "$critic_role" "$(jq -r '.gate_phase' <<<"$row")" \
      "$child" "$critic_provider" "$critic_semantic_role" "$critic_provenance"
    verify_adjudication_artifact \
      "$(jq -r '.adjudication_artifact' <<<"$row")" "$(jq -r '.adjudication_sha256' <<<"$row")" \
      "$target_id" "$critic_role" "$(jq -r '.gate_phase' <<<"$row")" \
      "$child" "$critic_provider" "$critic_semantic_role" "$critic_provenance" "$(jq -r '.report_sha256' <<<"$row")"
    verify_report_verdict "$report_artifact_path" "$adjudication_source_verdict"
    if [ "$(jq -r '.critic_role' <<<"$row")" = C ] && [ "$(jq -r '.gate_phase' <<<"$row")" = prewrite ]; then
      intention="$(jq -r '.intention_artifact // empty' <<<"$row")"; [ -n "$intention" ] || fail_gate "ECI prewrite admission requires Critic C intention evidence for $target_id"
      verify_artifact intention "$intention" "$(jq -r '.intention_sha256' <<<"$row")"
    fi
    row_e2e_required="$(jq -r '.e2e_required' <<<"$row")"
    [ "$row_e2e_required" = "$target_e2e_required" ] ||
      fail_gate "ECI required-critic review gate found an inconsistent E2E requirement for target $target_id"
    if [ "$target_e2e_required" = true ]; then
      verify_artifact E2E "$(jq -r '.e2e_artifact' <<<"$row")" "$(jq -r '.e2e_sha256' <<<"$row")"
    fi
  done < <(jq -c --arg id "$target_id" --arg kind "$target_kind" '.rows[] | select(.target_id == $id and .target_kind == $kind)' "$manifest")
done < <(jq -c '.targets[]' "$manifest")
if [ "$phase" = prewrite ]; then
  [ "$row_count" -eq $((target_count * expected_rows_per_target)) ] || fail_gate 'ECI required-critic review gate denied an incomplete or over-populated prewrite critic row set.'
else
  [ "$((row_count - optional_prewrite_count))" -eq $((target_count * expected_rows_per_target)) ] || fail_gate 'ECI required-critic review gate denied an incomplete or over-populated postwrite critic row set.'
fi

manifest_sha256="$(sha256sum -- "$manifest" | awk '{print $1}')"
target_set_sha256="$(jq -c '[.targets[] | {target_id,target_kind,target_path,target_version}] | sort_by([.target_id,.target_kind,.target_path,.target_version])' "$manifest" | sha256sum | awk '{print $1}')"
row_identity_sha256="$(jq -c '[.rows[] | {target_id,target_kind,critic_role,gate_phase,child_identity,critic_provider,critic_semantic_role,critic_provenance,spawn_request_artifact,spawn_request_sha256,report_artifact,report_sha256,adjudication_artifact,adjudication_sha256,e2e_artifact,e2e_sha256}] | sort_by([.target_id,.target_kind,.critic_role,.gate_phase,.child_identity,.critic_provider,.critic_provenance])' "$manifest" | sha256sum | awk '{print $1}')"
identity_ledger="$session_dir/eci-critic-identities.ledger"
mapfile -t current_identity_hashes < <(
  jq -c '.rows[] | {target_id,target_kind,critic_role,gate_phase,child_identity,critic_provider,critic_semantic_role,critic_provenance,spawn_request_artifact,spawn_request_sha256,report_artifact,report_sha256,adjudication_artifact,adjudication_sha256,e2e_artifact,e2e_sha256}' "$manifest" |
    while IFS= read -r identity_row; do
      printf '%s' "$identity_row" | sha256sum | awk '{print $1}'
    done
)
[ "${#current_identity_hashes[@]}" -eq "$row_count" ] ||
  fail_gate 'ECI required-critic review gate could not derive the bounded critic identity set.'
mapfile -t current_scope_hashes < <(
  jq -c '.rows[] | {target_id,target_kind,critic_role,gate_phase,critic_provider,critic_semantic_role,critic_provenance}' "$manifest" |
    while IFS= read -r scope_row; do
      printf '%s' "$scope_row" | sha256sum | awk '{print $1}'
    done
)
mapfile -t current_child_hashes < <(
  jq -c '.rows[] | {critic_role,gate_phase,child_identity,critic_provider,critic_semantic_role,critic_provenance}' "$manifest" |
    while IFS= read -r child_row; do
      printf '%s' "$child_row" | sha256sum | awk '{print $1}'
    done
)
mapfile -t current_artifact_hashes < <(
  jq -c '.rows[] | {critic_role,gate_phase,child_identity,critic_provider,critic_semantic_role,critic_provenance,spawn_request_artifact,spawn_request_sha256,report_artifact,report_sha256,adjudication_artifact,adjudication_sha256,e2e_artifact,e2e_sha256}' "$manifest" |
    while IFS= read -r artifact_row; do
      printf '%s' "$artifact_row" | sha256sum | awk '{print $1}'
    done
)
[ "${#current_scope_hashes[@]}" -eq "$row_count" ] &&
  [ "${#current_child_hashes[@]}" -eq "$row_count" ] &&
  [ "${#current_artifact_hashes[@]}" -eq "$row_count" ] ||
  fail_gate 'ECI required-critic review gate could not derive critic identity bindings.'
# Teardown consumes the immediately preceding final admission.  Before the
# off rows are published, the only valid identity prefix is therefore final;
# using an empty off prefix would make every legitimate final->off transition
# look like missing history.  The off prefix is still published below and is
# bound into the terminal off anchor after publication.
identity_prefix="$phase:$acceptance_version:$manifest_sha256:"
identity_admission_lookup_phase="$phase"
if [ "$phase" = off ] && [ -f "$identity_ledger" ] && [ ! -L "$identity_ledger" ]; then
  # A direct off admission may be retried after receipt publication fails;
  # consume its own published identity prefix when present.  Otherwise off
  # consumes the immediately preceding final prefix.
  grep -Eq "^off:${acceptance_version}:${manifest_sha256}:" "$identity_ledger" ||
    identity_admission_lookup_phase=final
elif [ "$phase" = off ]; then
  identity_admission_lookup_phase=final
fi
identity_admission_prefix="$identity_admission_lookup_phase:$acceptance_version:$manifest_sha256:"
current_identity_admission_sha256="$(
  if [ -f "$identity_ledger" ] && [ ! -L "$identity_ledger" ]; then
    awk -F: -v prefix="$identity_admission_prefix" 'index($0,prefix)==1 {print}' "$identity_ledger"
  fi | sha256sum | awk '{print $1}'
)"
[[ "$current_identity_admission_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  fail_gate 'ECI required-critic review gate could not derive the historical identity admission hash.'
current_ledger_sha256="$(
  jq -c '.rows[]' "$manifest" |
    while IFS= read -r row; do
      printf '%s\n' "$row" | sha256sum | awk '{print $1}'
    done |
    sha256sum | awk '{print $1}'
)"
[[ "$current_ledger_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  fail_gate 'ECI required-critic review gate could not derive the immutable critic ledger hash.'
if [ -e "$identity_ledger" ] || [ -L "$identity_ledger" ]; then
  [ -f "$identity_ledger" ] && [ ! -L "$identity_ledger" ] ||
    fail_gate "ECI required-critic review gate found an unsafe critic identity ledger: $identity_ledger"
  identity_bytes="$(wc -c <"$identity_ledger" 2>/dev/null || true)"
  case "$identity_bytes" in ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed critic identity ledger size.' ;; esac
  [ "$identity_bytes" -le 1048576 ] || fail_gate 'ECI required-critic review gate denied an oversized critic identity ledger.'
  [ "$(tail -c 1 -- "$identity_ledger" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate 'ECI required-critic review gate denied a critic identity ledger without a final LF.'
  while IFS= read -r identity_line; do
    [[ "$identity_line" =~ ^(commit|final|off|prewrite):[1-9][0-9]*:[0-9a-f]{64}:[0-9a-f]{64}:[0-9a-f]{64}:[0-9a-f]{64}:[0-9a-f]{64}$ ]] ||
      fail_gate 'ECI required-critic review gate found a malformed critic identity ledger row.'
  done <"$identity_ledger"
else
  identity_bytes=0
fi
for ((identity_index=0; identity_index<row_count; identity_index++)); do
  identity_hash="${current_identity_hashes[$identity_index]}"
  scope_hash="${current_scope_hashes[$identity_index]}"
  child_hash="${current_child_hashes[$identity_index]}"
  artifact_hash="${current_artifact_hashes[$identity_index]}"
  [[ "$identity_hash" =~ ^[0-9a-f]{64}$ && "$scope_hash" =~ ^[0-9a-f]{64}$ && "$child_hash" =~ ^[0-9a-f]{64}$ && "$artifact_hash" =~ ^[0-9a-f]{64}$ ]] ||
    fail_gate 'ECI required-critic review gate derived malformed critic identity bindings.'
  if [ "$identity_bytes" -gt 0 ]; then
    while IFS=: read -r old_phase old_version old_manifest old_row_hash old_scope_hash old_child_hash old_artifact_hash; do
      if [ "$old_child_hash" = "$child_hash" ] || [ "$old_artifact_hash" = "$artifact_hash" ]; then
        # A terminal off boundary consumes the identities admitted by the
        # immediately preceding final boundary for the exact same manifest.
        # This is not a fresh review: a different manifest/snapshot still
        # rejects the reuse below.
        if [ "$phase" = off ] && [ "$old_phase" = final ] &&
          [ "$old_manifest" = "$manifest_sha256" ]; then
          :
        else
          [ "$old_phase:$old_version" = "$phase:$acceptance_version" ] ||
            fail_gate 'ECI required-critic review gate denied a reused critic identity or artifact across historical admissions (unchanged snapshot/lineage reset).'
        fi
        [ "$old_scope_hash" = "$scope_hash" ] ||
          fail_gate 'ECI required-critic review gate denied a critic child or artifact reused for another governed target.'
      fi
    done <"$identity_ledger"
  fi
done
anchor="$session_dir/eci-acceptance-anchor"
anchor_append=false
anchor_exists=false
anchor_has_exact=false
transaction="$session_dir/eci-acceptance-transaction"
transaction_valid=false
transaction_state=""
transaction_tuple="$phase:$acceptance_version:$manifest_sha256:$trusted_diff_sha256:$target_set_sha256:$repo_binding_sha256:$row_identity_sha256"

transaction_file_sha256() {
  local path="$1"
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    sha256sum -- "$path" | awk '{print $1}'
  else
    printf '' | sha256sum | awk '{print $1}'
  fi
}

write_transaction_state() {
  local state="$1" tmp ledger_prefix_sha256 identity_prefix_sha256
  case "$state" in prepared|ledger-published|identity-published|anchor-published) ;; *) return 1 ;; esac
  [ -e "$transaction" ] || [ -L "$transaction" ] || {
    :
  }
  [ ! -L "$transaction" ] || return 1
  if [ -e "$transaction" ] && [ ! -f "$transaction" ]; then
    return 1
  fi
  tmp="$transaction.tmp.$$"
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  ledger_prefix_sha256="$(transaction_file_sha256 "$ledger")"
  identity_prefix_sha256="$(transaction_file_sha256 "$identity_ledger")"
  if ! (set -C; {
    printf 'schema: eci-acceptance-transaction/v2\n'
    printf 'session_id: %s\n' "$session_id"
    printf 'tuple: %s\n' "$transaction_tuple"
    printf 'ledger_sha256: %s\n' "$ledger_prefix_sha256"
    printf 'identity_sha256: %s\n' "$identity_prefix_sha256"
    printf 'state: %s\n' "$state"
  } >"$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  [ ! -L "$transaction" ] || {
    rm -f -- "$tmp"
    return 1
  }
  if ! mv -- "$tmp" "$transaction"; then
    rm -f -- "$tmp"
    return 1
  fi
  transaction_valid=true
  transaction_state="$state"
}

if [ -e "$transaction" ] || [ -L "$transaction" ]; then
  [ -f "$transaction" ] && [ ! -L "$transaction" ] ||
    fail_gate "ECI required-critic review gate found an unsafe acceptance transaction: $transaction"
  transaction_bytes="$(wc -c <"$transaction" 2>/dev/null || true)"
  case "$transaction_bytes" in ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed acceptance transaction size.' ;; esac
  [ "$transaction_bytes" -le 4096 ] || fail_gate 'ECI required-critic review gate denied an oversized acceptance transaction.'
  [ "$(tail -c 1 -- "$transaction" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate 'ECI required-critic review gate denied an acceptance transaction without a final LF.'
  mapfile -t transaction_lines <"$transaction" || fail_gate 'ECI required-critic review gate could not read its acceptance transaction.'
  [ "${#transaction_lines[@]}" -eq 6 ] || fail_gate 'ECI required-critic review gate denied an incomplete acceptance transaction.'
  [ "${transaction_lines[0]}" = 'schema: eci-acceptance-transaction/v2' ] ||
    fail_gate 'ECI required-critic review gate denied an unsupported acceptance transaction schema.'
  [ "${transaction_lines[1]}" = "session_id: $session_id" ] ||
    fail_gate 'ECI required-critic review gate denied an acceptance transaction session mismatch.'
  [ "${transaction_lines[2]}" = "tuple: $transaction_tuple" ] ||
    fail_gate 'ECI required-critic review gate denied a stale or substituted acceptance transaction.'
  transaction_ledger_sha256="${transaction_lines[3]#ledger_sha256: }"
  transaction_identity_sha256="${transaction_lines[4]#identity_sha256: }"
  [[ "${transaction_lines[3]}" == ledger_sha256:\ * && "$transaction_ledger_sha256" =~ ^[0-9a-f]{64}$ ]] ||
    fail_gate 'ECI required-critic review gate denied a malformed acceptance transaction ledger prefix.'
  [[ "${transaction_lines[4]}" == identity_sha256:\ * && "$transaction_identity_sha256" =~ ^[0-9a-f]{64}$ ]] ||
    fail_gate 'ECI required-critic review gate denied a malformed acceptance transaction identity prefix.'
  [ "$(transaction_file_sha256 "$ledger")" = "$transaction_ledger_sha256" ] ||
    fail_gate 'ECI required-critic review gate rejected a recovery transaction with a changed transaction ledger prefix.'
  [ "$(transaction_file_sha256 "$identity_ledger")" = "$transaction_identity_sha256" ] ||
    fail_gate 'ECI required-critic review gate rejected a recovery transaction with a changed transaction identity prefix.'
  transaction_state="${transaction_lines[5]#state: }"
  [[ "${transaction_lines[5]}" == state:\ * ]] || fail_gate 'ECI required-critic review gate denied a malformed acceptance transaction state.'
  case "$transaction_state" in prepared|ledger-published|identity-published|anchor-published) ;; *) fail_gate 'ECI required-critic review gate denied an unknown acceptance transaction state.' ;; esac
  transaction_valid=true
fi

decimal_greater() {
  local left="$1" right="$2"
  if [ "${#left}" -ne "${#right}" ]; then
    [ "${#left}" -gt "${#right}" ]
  else
    [[ "$left" > "$right" ]]
  fi
}

if [ -e "$anchor" ] || [ -L "$anchor" ]; then
  anchor_exists=true
  [ -f "$anchor" ] && [ ! -L "$anchor" ] || fail_gate "ECI required-critic review gate found an unsafe acceptance anchor: $anchor"
  anchor_bytes="$(wc -c <"$anchor" 2>/dev/null || true)"
  case "$anchor_bytes" in ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed acceptance-anchor size.' ;; esac
  [ "$anchor_bytes" -le 16384 ] || fail_gate 'ECI required-critic review gate denied an oversized acceptance anchor.'
  [ "$(tail -c 1 -- "$anchor" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate 'ECI required-critic review gate denied an acceptance anchor without a final LF.'
  mapfile -t anchor_lines <"$anchor" || fail_gate 'ECI required-critic review gate could not read the acceptance anchor.'
  [ "${#anchor_lines[@]}" -ge 7 ] || fail_gate 'ECI required-critic review gate denied an incomplete acceptance anchor.'
  [ "${anchor_lines[0]}" = 'schema: eci-acceptance-anchor/v1' ] || fail_gate 'ECI required-critic review gate denied an unsupported acceptance-anchor schema.'
  [ "${anchor_lines[1]}" = "session_id: $session_id" ] || fail_gate 'ECI required-critic review gate denied an acceptance-anchor session mismatch.'
  [ "${anchor_lines[2]}" = "repo_root: $repo_root_actual" ] || fail_gate 'ECI required-critic review gate denied an acceptance-anchor repository mismatch.'
  [ "${anchor_lines[3]}" = "git_dir: $git_dir_actual" ] || fail_gate 'ECI required-critic review gate denied an acceptance-anchor git-dir mismatch.'
  [ "${anchor_lines[4]}" = "git_common_dir: $git_common_actual" ] || fail_gate 'ECI required-critic review gate denied an acceptance-anchor common-dir mismatch.'
  [[ "${anchor_lines[5]}" == base_oid:\ * ]] || fail_gate 'ECI required-critic review gate denied a malformed acceptance-anchor base.'
  anchor_base_oid="${anchor_lines[5]#base_oid: }"
  [[ "$anchor_base_oid" =~ ^[0-9a-f]{40,64}$ ]] || fail_gate 'ECI required-critic review gate denied a malformed acceptance-anchor base.'
  anchor_max_version=0
  anchor_has_exact=false
  anchor_seen_same_snapshot=false
  anchor_seen_nonoff_phase=""
  anchor_has_commit_admission=false
  anchor_commit_max_version=0
  for ((anchor_index=6; anchor_index<${#anchor_lines[@]}; anchor_index++)); do
    anchor_line="${anchor_lines[$anchor_index]}"
    IFS=: read -r anchor_prefix anchor_phase anchor_version anchor_manifest anchor_diff anchor_targets anchor_binding anchor_identity anchor_ledger anchor_identity_admission anchor_extra <<<"$anchor_line"
    [ -z "${anchor_extra:-}" ] && [ "$anchor_prefix" = admission ] ||
      fail_gate 'ECI required-critic review gate denied a malformed acceptance-anchor admission.'
    case "$anchor_phase" in commit|final|off|prewrite) ;; *) fail_gate 'ECI required-critic review gate denied an unknown acceptance-anchor phase.' ;; esac
    [[ "$anchor_version" =~ ^[1-9][0-9]*$ ]] || fail_gate 'ECI required-critic review gate denied a noncanonical acceptance-anchor version.'
    [[ "$anchor_manifest" =~ ^[0-9a-f]{64}$ && "$anchor_diff" =~ ^[0-9a-f]{64}$ && "$anchor_targets" =~ ^[0-9a-f]{64}$ && "$anchor_binding" =~ ^[0-9a-f]{64}$ ]] ||
      fail_gate 'ECI required-critic review gate denied malformed acceptance-anchor hashes.'
    [[ "$anchor_identity" =~ ^[0-9a-f]{64}$ && "$anchor_ledger" =~ ^[0-9a-f]{64}$ && "$anchor_identity_admission" =~ ^[0-9a-f]{64}$ ]] ||
      fail_gate 'ECI required-critic review gate denied an acceptance-anchor identity hash.'
    admission_ledger="$session_dir/eci-required-critics.$anchor_phase.$anchor_version.ledger"
    [ -f "$admission_ledger" ] && [ ! -L "$admission_ledger" ] ||
      fail_gate "ECI required-critic review gate found a missing ledger for prior admission (shortened or deleted ledger): $admission_ledger"
    [ "${identity_bytes:-0}" -gt 0 ] ||
      fail_gate 'ECI required-critic review gate found a historical admission without its immutable critic identity ledger.'
    historical_ledger_sha256="$(sha256sum -- "$admission_ledger" 2>/dev/null | awk '{print $1}')"
    [ "$historical_ledger_sha256" = "$anchor_ledger" ] ||
      fail_gate 'ECI required-critic review gate found a mutated historical critic ledger (anchor hash mismatch).'
    identity_admission_prefix="${anchor_phase}:${anchor_version}:${anchor_manifest}:"
    historical_identity_admission_sha256="$(awk -F: -v prefix="$identity_admission_prefix" 'index($0,prefix)==1 {print}' "$identity_ledger" | sha256sum | awk '{print $1}')"
    [ "$historical_identity_admission_sha256" = "$anchor_identity_admission" ] ||
      fail_gate 'ECI required-critic review gate found a reordered or mutated historical critic identity admission.'
    admission_line_count="$(wc -l <"$admission_ledger" 2>/dev/null || true)"
    identity_admission_count="$(awk -F: -v prefix="$identity_admission_prefix" 'index($0,prefix)==1 {n++} END {print n+0}' "$identity_ledger" 2>/dev/null || printf '0')"
    [ "$admission_line_count" = "$identity_admission_count" ] ||
      fail_gate 'ECI required-critic review gate found a truncated or replaced critic identity ledger for a historical admission.'
    decimal_greater "$anchor_version" "$anchor_max_version" && anchor_max_version="$anchor_version"
    if [ "$anchor_phase" = commit ]; then
      anchor_has_commit_admission=true
      decimal_greater "$anchor_version" "$anchor_commit_max_version" && anchor_commit_max_version="$anchor_version"
    fi
    [ "$anchor_diff:$anchor_targets:$anchor_binding" = "$trusted_diff_sha256:$target_set_sha256:$repo_binding_sha256" ] && anchor_seen_same_snapshot=true
    if [ "$anchor_version" = "$acceptance_version" ]; then
      if [ "$anchor_phase" = "$phase" ]; then
          [ "$anchor_manifest" = "$manifest_sha256" ] &&
          [ "$anchor_diff" = "$trusted_diff_sha256" ] &&
          [ "$anchor_targets" = "$target_set_sha256" ] &&
          [ "$anchor_binding" = "$repo_binding_sha256" ] &&
          [ "$anchor_identity" = "$row_identity_sha256" ] &&
          [ "$anchor_ledger" = "$current_ledger_sha256" ] &&
          [ "$anchor_identity_admission" = "$current_identity_admission_sha256" ] ||
          fail_gate 'ECI required-critic review gate denied a changed manifest for an already-admitted phase/version (changed manifest after admission).'
        anchor_has_exact=true
      elif [ "$anchor_identity" = "$row_identity_sha256" ]; then
        # The terminal off boundary consumes the exact identities admitted by
        # final for the same manifest/live snapshot.  A different phase,
        # manifest, or repository tuple remains a historical reuse attempt.
        if [ "$phase" = off ] && [ "$anchor_phase" = final ] &&
          [ "$anchor_manifest" = "$manifest_sha256" ] &&
          [ "$anchor_diff" = "$trusted_diff_sha256" ] &&
          [ "$anchor_targets" = "$target_set_sha256" ] &&
          [ "$anchor_binding" = "$repo_binding_sha256" ] &&
          [ "$anchor_ledger" = "$current_ledger_sha256" ] &&
          [ "$anchor_identity_admission" = "$current_identity_admission_sha256" ]; then
          :
        else
          fail_gate 'ECI required-critic review gate denied reused critic identities or artifacts across phase admissions.'
        fi
      fi
      if [ "$anchor_phase" != off ] && [ "$phase" != off ]; then
        [ -n "$anchor_seen_nonoff_phase" ] || anchor_seen_nonoff_phase="$anchor_phase"
        [ "$anchor_seen_nonoff_phase" = "$phase" ] ||
          fail_gate 'ECI required-critic review gate denied a commit/final/prewrite phase substitution at one acceptance version.'
      fi
    fi
  done
  if decimal_greater "$acceptance_version" "$anchor_max_version" && [ "$anchor_seen_same_snapshot" = true ]; then
    fail_gate 'ECI required-critic review gate denied an acceptance_version reset/substitution for an unchanged snapshot.'
  fi
  if decimal_greater "$anchor_max_version" "$acceptance_version"; then
    fail_gate 'ECI required-critic review gate denied an acceptance_version regression.'
  fi
  if [ "$anchor_base_oid" != "$base_actual" ]; then
    # A normal direct commit advances HEAD after the commit-phase admission.
    # The historical anchor header remains immutable; only the terminal off
    # transition may move to a strictly newer snapshot, and it must carry a
    # fresh acceptance version after the committed admission.
    [ "$phase" = off ] && [ "$anchor_has_commit_admission" = true ] &&
      decimal_greater "$acceptance_version" "$anchor_commit_max_version" ||
      fail_gate 'ECI required-critic review gate denied an acceptance-anchor base mismatch.'
  fi
  [ "$anchor_has_exact" = true ] || anchor_append=true
else
  anchor_append=true
fi

# A ledger without its immutable session anchor cannot establish lineage and
# must not be treated as a fresh admission.  Likewise, every phase/version
# ledger beside an existing anchor must have an explicit anchor row.
if [ "$anchor_exists" = true ]; then
  shopt -s nullglob
  for admission_ledger in "$session_dir"/eci-required-critics.*.*.ledger; do
    [ -f "$admission_ledger" ] && [ ! -L "$admission_ledger" ] ||
      fail_gate "ECI required-critic review gate found an unsafe historical ledger: $admission_ledger"
    admission_name="${admission_ledger##*/}"
    admission_key="${admission_name#eci-required-critics.}"
    admission_key="${admission_key%.ledger}"
    [[ "$admission_key" =~ ^(commit|final|off|prewrite)\.[1-9][0-9]*$ ]] ||
      fail_gate "ECI required-critic review gate found a malformed historical ledger name: $admission_name"
    admission_phase="${admission_key%%.*}"
    admission_version="${admission_key#*.}"
    grep -Fq "admission:$admission_phase:$admission_version:" "$anchor" ||
      fail_gate "ECI required-critic review gate found a ledger without an anchor admission: $admission_name"
  done
  shopt -u nullglob
else
  shopt -s nullglob
  orphan_ledgers=("$session_dir"/eci-required-critics.*.*.ledger)
  if [ "${#orphan_ledgers[@]}" -gt 0 ]; then
    [ "$transaction_valid" = true ] ||
      fail_gate 'ECI required-critic review gate found historical critic evidence without its acceptance anchor or recoverable transaction.'
  fi
  shopt -u nullglob
fi
if [ "$anchor_exists" = true ]; then
  [ "$identity_bytes" -gt 0 ] ||
    fail_gate 'ECI required-critic review gate found historical admissions without the critic identity ledger.'
else
  if [ "$identity_bytes" -gt 0 ]; then
    [ "$transaction_valid" = true ] ||
      fail_gate 'ECI required-critic review gate found a critic identity ledger without its acceptance anchor or recoverable transaction.'
  fi
fi
if [ "${identity_bytes:-0}" -gt 0 ]; then
  while IFS=: read -r identity_phase identity_version identity_manifest identity_row identity_scope identity_child identity_artifact identity_extra; do
    [ -z "${identity_extra:-}" ] ||
      fail_gate 'ECI required-critic review gate found an identity row with an unexpected suffix.'
    known_identity=false
    if [ "$identity_phase:$identity_version:$identity_manifest" = "$phase:$acceptance_version:$manifest_sha256" ]; then
      known_identity=true
    fi
    if [ "$anchor_exists" = true ] && grep -Fq "admission:$identity_phase:$identity_version:$identity_manifest:" "$anchor"; then
      known_identity=true
    fi
    [ "$known_identity" = true ] ||
      fail_gate 'ECI required-critic review gate rejected an unanchored critic identity row.'
  done <"$identity_ledger"
fi
ledger_tmp=""
sentinel=""
sentinel_created=false

if [ "$phase" = prewrite ]; then
  # A prewrite admission is ordered only against the same repository snapshot.
  # Historical postwrite ledgers from an older acceptance version are evidence,
  # not a reason to reject a new snapshot.
  for post_phase in commit final off; do
    prior_ledger="$session_dir/eci-required-critics.$post_phase.$acceptance_version.ledger"
    if [ -L "$prior_ledger" ]; then
      fail_gate "ECI prewrite admission found an unsafe prior ledger: $prior_ledger"
    fi
    [ ! -e "$prior_ledger" ] ||
      fail_gate 'ECI prewrite admission must precede postwrite admission for this acceptance version.'
  done

  prewrite_writer="${ECI_PREWRITE_WRITER_SESSION:-}"
  codex_valid_session_id "$prewrite_writer" ||
    fail_gate 'ECI prewrite admission denied: ECI_PREWRITE_WRITER_SESSION must be a valid session id.'
  [ "$prewrite_writer" = "$session_id" ] ||
    fail_gate 'ECI prewrite admission denied: writer session must equal the canonical gate session.'
  pre_target="${ECI_PREWRITE_TARGET:-}"
  [ -n "$pre_target" ] || fail_gate 'ECI prewrite admission denied: exact canonical target is required.'
  [ "$pre_target" = "$current_target_path" ] || fail_gate 'ECI prewrite admission denied: target binding does not match the current manifest.'
  sentinel="$session_dir/eci-prewrite-admitted.$acceptance_version"
  if [ -e "$sentinel" ] || [ -L "$sentinel" ]; then
    [ -f "$sentinel" ] && [ ! -L "$sentinel" ] || fail_gate 'ECI prewrite admission sentinel is unsafe.'
    [ "$(awk 'END { print NR + 0 }' "$sentinel")" -eq 7 ] || fail_gate 'ECI prewrite admission sentinel has an invalid schema.'
    grep -Fxq "session_id: $session_id" "$sentinel" || fail_gate 'ECI prewrite admission sentinel has a mismatched writer session.'
    grep -Fxq "target_path: $pre_target" "$sentinel" || fail_gate 'ECI prewrite admission sentinel is bound to another target.'
    grep -Fxq "target_version: $target_version_actual" "$sentinel" || fail_gate 'ECI prewrite admission sentinel has a stale target binding.'
    grep -Fxq "repo_root: $repo_root_actual" "$sentinel" || fail_gate 'ECI prewrite admission sentinel has a stale repository binding.'
    grep -Fxq "diff_sha256: $current_diff_sha256" "$sentinel" || fail_gate 'ECI prewrite admission sentinel has a stale diff binding.'
    grep -Fxq "acceptance_version: $acceptance_version" "$sentinel" || fail_gate 'ECI prewrite admission sentinel has a stale acceptance version.'
  fi
fi

if [ -e "$ledger" ] || [ -L "$ledger" ]; then
  [ -f "$ledger" ] && [ ! -L "$ledger" ] ||
    fail_gate "ECI required-critic review gate found an unsafe append-only ledger: $ledger"
  ledger_bytes="$(wc -c <"$ledger" 2>/dev/null || true)"
  old_lines="$(wc -l <"$ledger")"
else
  ledger_bytes=0
  old_lines=0
fi
case "$ledger_bytes" in ''|*[!0-9]*) fail_gate 'ECI required-critic review gate denied malformed ledger size.' ;; esac
[ "$ledger_bytes" -le 1048576 ] || fail_gate 'ECI required-critic review gate denied an oversized append-only ledger.'
if [ "$ledger_bytes" -gt 0 ]; then
  [ "$(tail -c 1 -- "$ledger" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
    fail_gate 'ECI required-critic review gate denied an append-only ledger without a final LF.'
fi
if [ "$phase" = prewrite ] && [ "$old_lines" -ne 0 ]; then
  fail_gate 'ECI prewrite admission must precede every postwrite ledger admission and cannot be repeated later.'
fi
[ "$anchor_has_exact" = true ] && [ "$old_lines" -eq "$row_count" ] ||
  if [ "$anchor_has_exact" = true ]; then
    fail_gate 'ECI required-critic review gate found a shortened or deleted ledger for an existing phase/version admission.'
  fi
[ "$old_lines" -le "$row_count" ] ||
  fail_gate 'ECI required-critic review gate denied ledger truncation or row loss.'
i=0
if [ -f "$ledger" ]; then
  while IFS= read -r old; do
    i=$((i + 1))
    [[ "$old" =~ ^[0-9a-f]{64}$ ]] ||
      fail_gate "ECI required-critic review gate found a malformed ledger row: $i"
    expected="$(jq -c '.rows['"$((i - 1))"']' "$manifest" | sha256sum | awk '{print $1}')"
    [ "$old" = "$expected" ] ||
      fail_gate "ECI required-critic review gate denied changed manifest after admission: row $i (unchanged snapshot/lineage reset)."
  done <"$ledger"
fi

# Prepare the complete next prefix before publishing either side of a
# prewrite transaction.  The old ledger remains untouched if this fails.
if [ "$old_lines" -lt "$row_count" ]; then
  ledger_tmp="$ledger.tmp.$$"
  [ ! -e "$ledger_tmp" ] && [ ! -L "$ledger_tmp" ] ||
    fail_gate "ECI required-critic review gate found an unsafe ledger transaction path: $ledger_tmp"
  if [ "$old_lines" -gt 0 ]; then
    cat -- "$ledger" >"$ledger_tmp" || { rm -f -- "$ledger_tmp"; fail_gate 'ECI required-critic review gate could not stage the ledger prefix.'; }
  else
    : >"$ledger_tmp" || fail_gate 'ECI required-critic review gate could not stage the ledger.'
  fi
if ! jq -c ".rows[$old_lines:][]" "$manifest" |
      while IFS= read -r row; do
        printf '%s\n' "$row" | sha256sum | awk '{print $1}' >>"$ledger_tmp"
      done; then
    rm -f -- "$ledger_tmp"
    fail_gate 'ECI required-critic review gate could not stage the complete ledger prefix.'
  fi
  verify_bounded_text_file 'staged append-only ledger' "$ledger_tmp" "$eci_review_ledger_max_bytes"
fi

# Publish a small, tuple-bound recovery record before the first state mutation.
# If the process dies after the ledger or identity boundary, the next locked
# invocation can distinguish that recoverable prefix from an unexplained
# orphan and complete the same admission without resetting its lineage.
if [ "$transaction_valid" != true ]; then
  write_transaction_state prepared ||
    fail_gate 'ECI required-critic review gate could not publish its bounded recovery transaction.'
fi

if [ "$phase" = prewrite ] && [ ! -e "$sentinel" ]; then
  sentinel_tmp="$sentinel.tmp.$$"
  [ ! -e "$sentinel_tmp" ] && [ ! -L "$sentinel_tmp" ] || {
    [ -n "$ledger_tmp" ] && rm -f -- "$ledger_tmp"
    fail_gate 'ECI prewrite admission found an unsafe sentinel transaction path.'
  }
  if ! (set -C; {
    printf 'session_id: %s\n' "$session_id"
    printf 'target_path: %s\n' "$pre_target"
    printf 'target_version: %s\n' "$target_version_actual"
    printf 'repo_root: %s\n' "$repo_root_actual"
    printf 'diff_sha256: %s\n' "$current_diff_sha256"
    printf 'acceptance_version: %s\n' "$acceptance_version"
    printf 'state: admitted\n'
  } >"$sentinel_tmp"); then
    rm -f -- "$sentinel_tmp" "$ledger_tmp"
    fail_gate 'ECI prewrite admission could not stage its atomic sentinel.'
  fi
  if ! (set -C; ln -- "$sentinel_tmp" "$sentinel") 2>/dev/null; then
    rm -f -- "$sentinel_tmp" "$ledger_tmp"
    fail_gate 'ECI prewrite admission could not publish its atomic sentinel.'
  fi
  rm -f -- "$sentinel_tmp"
  sentinel_created=true
fi

if [ -n "$ledger_tmp" ]; then
  if ! mv -- "$ledger_tmp" "$ledger"; then
    rm -f -- "$ledger_tmp"
    if [ "$sentinel_created" = true ]; then
      rm -f -- "$sentinel"
    fi
    fail_gate 'ECI required-critic review gate could not publish the prefix-preserving ledger transaction.'
  fi
fi
write_transaction_state ledger-published ||
  fail_gate 'ECI required-critic review gate could not record the ledger publication boundary.'
if [ "${ECI_REVIEW_GATE_TEST_FAIL_AFTER:-}" = ledger ]; then
  exit 75
fi

identity_tmp=""
if [ "$anchor_has_exact" = true ]; then
  for ((identity_index=0; identity_index<row_count; identity_index++)); do
    identity_hash="${current_identity_hashes[$identity_index]}"
    scope_hash="${current_scope_hashes[$identity_index]}"
    child_hash="${current_child_hashes[$identity_index]}"
    artifact_hash="${current_artifact_hashes[$identity_index]}"
    grep -E "^${phase}:${acceptance_version}:[0-9a-f]{64}:${identity_hash}:${scope_hash}:${child_hash}:${artifact_hash}$" "$identity_ledger" >/dev/null 2>&1 ||
      fail_gate 'ECI required-critic review gate found a missing historical critic identity row for an existing phase/version admission.'
  done
fi
for ((identity_index=0; identity_index<row_count; identity_index++)); do
  identity_hash="${current_identity_hashes[$identity_index]}"
  scope_hash="${current_scope_hashes[$identity_index]}"
  child_hash="${current_child_hashes[$identity_index]}"
  artifact_hash="${current_artifact_hashes[$identity_index]}"
  if [ "$identity_bytes" -eq 0 ] || ! grep -E "^${phase}:${acceptance_version}:[0-9a-f]{64}:${identity_hash}:${scope_hash}:${child_hash}:${artifact_hash}$" "$identity_ledger" >/dev/null 2>&1; then
    identity_tmp="$identity_ledger.tmp.$$"
    break
  fi
done
if [ -n "$identity_tmp" ]; then
  [ ! -e "$identity_tmp" ] && [ ! -L "$identity_tmp" ] ||
    fail_gate 'ECI required-critic review gate found an unsafe critic identity transaction path.'
  if [ "$identity_bytes" -gt 0 ]; then
    cat -- "$identity_ledger" >"$identity_tmp" || {
      rm -f -- "$identity_tmp"
      fail_gate 'ECI required-critic review gate could not stage the critic identity prefix.'
    }
  else
    : >"$identity_tmp" || fail_gate 'ECI required-critic review gate could not stage the critic identity ledger.'
  fi
  for ((identity_index=0; identity_index<row_count; identity_index++)); do
    identity_hash="${current_identity_hashes[$identity_index]}"
    scope_hash="${current_scope_hashes[$identity_index]}"
    child_hash="${current_child_hashes[$identity_index]}"
    artifact_hash="${current_artifact_hashes[$identity_index]}"
    grep -E "^${phase}:${acceptance_version}:[0-9a-f]{64}:${identity_hash}:${scope_hash}:${child_hash}:${artifact_hash}$" "$identity_tmp" >/dev/null 2>&1 ||
      printf '%s%s:%s:%s:%s\n' "$identity_prefix" "$identity_hash" "$scope_hash" "$child_hash" "$artifact_hash" >>"$identity_tmp"
  done
  verify_bounded_text_file 'staged critic identity ledger' "$identity_tmp" "$eci_review_ledger_max_bytes"
  mv -- "$identity_tmp" "$identity_ledger" || {
    rm -f -- "$identity_tmp"
    fail_gate 'ECI required-critic review gate could not publish the critic identity ledger.'
  }
fi

write_transaction_state identity-published ||
  fail_gate 'ECI required-critic review gate could not record the critic-identity publication boundary.'
if [ "${ECI_REVIEW_GATE_TEST_FAIL_AFTER:-}" = identity ]; then
  exit 75
fi

# The final anchor is intentionally published last.  A crash before this
# boundary leaves the immutable ledger/identity prefixes plus the tuple-bound
# transaction, which the next locked invocation can replay.
identity_admission_prefix="$phase:$acceptance_version:$manifest_sha256:"
identity_admission_sha256="$(awk -F: -v prefix="$identity_admission_prefix" 'index($0,prefix)==1 {print}' "$identity_ledger" | sha256sum | awk '{print $1}')"
[[ "$identity_admission_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  fail_gate 'ECI required-critic review gate could not derive the published critic identity admission hash.'
anchor_record="admission:$phase:$acceptance_version:$manifest_sha256:$trusted_diff_sha256:$target_set_sha256:$repo_binding_sha256:$row_identity_sha256:$current_ledger_sha256:$identity_admission_sha256"
if [ "$anchor_append" = true ]; then
  anchor_tmp="$anchor.tmp.$$"
  [ ! -e "$anchor_tmp" ] && [ ! -L "$anchor_tmp" ] ||
    fail_gate 'ECI required-critic review gate found an unsafe acceptance-anchor transaction path.'
  if [ -e "$anchor" ]; then
    if ! (set -C; { cat -- "$anchor"; printf '%s\n' "$anchor_record"; } >"$anchor_tmp"); then
      rm -f -- "$anchor_tmp"
      fail_gate 'ECI required-critic review gate could not stage the acceptance-anchor append.'
    fi
  else
    if ! (set -C; {
      printf 'schema: eci-acceptance-anchor/v1\n'
      printf 'session_id: %s\n' "$session_id"
      printf 'repo_root: %s\n' "$repo_root_actual"
      printf 'git_dir: %s\n' "$git_dir_actual"
      printf 'git_common_dir: %s\n' "$git_common_actual"
      printf 'base_oid: %s\n' "$base_actual"
      printf '%s\n' "$anchor_record"
    } >"$anchor_tmp"); then
      rm -f -- "$anchor_tmp"
      fail_gate 'ECI required-critic review gate could not stage the acceptance anchor.'
    fi
  fi
  verify_bounded_text_file 'staged acceptance anchor' "$anchor_tmp" "$eci_review_anchor_max_bytes"
  if ! mv -- "$anchor_tmp" "$anchor"; then
    rm -f -- "$anchor_tmp"
    fail_gate 'ECI required-critic review gate could not publish the acceptance anchor.'
  fi
fi
write_transaction_state anchor-published ||
  fail_gate 'ECI required-critic review gate could not record the acceptance-anchor publication boundary.'
if [ "${ECI_REVIEW_GATE_TEST_FAIL_AFTER:-}" = anchor ]; then
  exit 75
fi
rm -f -- "$transaction"
[ ! -e "$transaction" ] && [ ! -L "$transaction" ] ||
  fail_gate 'ECI required-critic review gate could not clear its completed recovery transaction.'

# A normal direct commit is admitted only after the full coordinator review
# gate has published its append-only evidence and acceptance anchor.  Publish
# a tuple-bound receipt last, atomically, so validate-bash can consume it for
# the one matching direct commit without relying on a hidden user approval.
if [ "$phase" = commit ]; then
  commit_marker="$session_dir/eci_active"
  if [ -e "$commit_marker" ] || [ -L "$commit_marker" ]; then
    [ -f "$commit_marker" ] && [ ! -L "$commit_marker" ] ||
      fail_gate 'ECI commit admission found an unsafe active marker.'
    codex_eci_marker_path_owner_is_valid "$commit_marker" ||
      fail_gate 'ECI commit admission found malformed active-marker ownership.'
    codex_eci_marker_is_valid_for_cwd "$commit_marker" "$review_cwd" ||
      fail_gate 'ECI commit admission found an active marker bound to another cwd.'
    commit_receipt="$session_dir/eci-commit-admitted"
    commit_anchor_sha256="$(sha256sum -- "$anchor" 2>/dev/null | awk '{print $1}')"
    [[ "$commit_anchor_sha256" =~ ^[0-9a-f]{64}$ ]] ||
      fail_gate 'ECI commit admission could not hash its acceptance anchor.'
    if [ -e "$commit_receipt" ] || [ -L "$commit_receipt" ]; then
      [ -f "$commit_receipt" ] && [ ! -L "$commit_receipt" ] ||
        fail_gate 'ECI commit admission found an unsafe existing receipt.'
      codex_eci_commit_admission_receipt_is_valid "$commit_receipt" "$session_id" "$manifest" ||
        fail_gate 'ECI commit admission found a stale or mismatched existing receipt.'
    else
      commit_receipt_tmp="$commit_receipt.tmp.$$"
      [ ! -e "$commit_receipt_tmp" ] && [ ! -L "$commit_receipt_tmp" ] ||
        fail_gate 'ECI commit admission found an unsafe receipt transaction path.'
      if ! (set -C; {
        printf 'schema: eci-commit-admission/v1\n'
        printf 'session_id: %s\n' "$session_id"
        printf 'phase: commit\n'
        printf 'acceptance_version: %s\n' "$acceptance_version"
        printf 'manifest_sha256: %s\n' "$manifest_sha256"
        printf 'repo_binding_sha256: %s\n' "$repo_binding_sha256"
        printf 'anchor_sha256: %s\n' "$commit_anchor_sha256"
        printf 'state: admitted\n'
      } >"$commit_receipt_tmp"); then
        rm -f -- "$commit_receipt_tmp"
        fail_gate 'ECI commit admission could not stage its receipt.'
      fi
      if ! (set -C; ln -- "$commit_receipt_tmp" "$commit_receipt") 2>/dev/null; then
        rm -f -- "$commit_receipt_tmp"
        fail_gate 'ECI commit admission could not publish its atomic receipt.'
      fi
      rm -f -- "$commit_receipt_tmp"
      codex_eci_commit_admission_receipt_is_valid "$commit_receipt" "$session_id" "$manifest" ||
        fail_gate 'ECI commit admission published an invalid receipt.'
    fi
  fi
fi

printf 'ECI required-critic review gate passed: phase=%s target=%s binding=%s\n' "$phase" "$current_target_id" "$manifest_sha256"
