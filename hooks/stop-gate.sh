#!/usr/bin/env bash
# Stop hook: require a checklist pass before ending.

set -euo pipefail

# This name is an internal per-process optimization only.  Never trust an
# inherited value: the canonical root is computed below before it is exported
# for the helper functions used by this callback.
unset CODEX_STOP_GATE_ROOT

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [ -z "$HOOK_DIR" ]; then
  # This callback has no usable local source directory from which to load its
  # helpers. Source spelling/provenance is diagnostic metadata, not an active
  # work target, so let the client continue rather than manufacturing a Stop
  # loop around it.
  printf '%s\n' '{"continue":true}'
  exit 0
fi
CODEX_PROVIDER_HOME="${HOME:?HOME must be set}/.codex"
CANONICAL_HOOK_DIR="$(cd "$CODEX_PROVIDER_HOME/hooks" 2>/dev/null && pwd -P || true)"

# Hook configuration and lifecycle authority are HOME-bound.  If an already
# running client invokes a stale copied hook, transfer to the one canonical
# source before loading helpers or examining ECI state.  CODEX_HOME must not
# select this source.
if [ -n "$CANONICAL_HOOK_DIR" ] && [ "$HOOK_DIR" != "$CANONICAL_HOOK_DIR" ]; then
  canonical_stop_gate="$CODEX_PROVIDER_HOME/hooks/stop-gate.sh"
  if [ -f "$canonical_stop_gate" ] && [ ! -L "$canonical_stop_gate" ] &&
    [ -x "$canonical_stop_gate" ] &&
    [ "$(realpath -e -- "$canonical_stop_gate" 2>/dev/null || true)" = "$CANONICAL_HOOK_DIR/stop-gate.sh" ]; then
    exec "$canonical_stop_gate"
  fi
fi
# A missing/mismatched canonical location is only deployment provenance. The
# callback already has a concrete runnable source, so retain it as the helper
# root and let ordinary Stop work continue. A valid canonical copy still wins
# above through `exec`, so a failed transfer must leave the current source
# selected rather than trying to load helpers from a stale incomplete copy.
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
codex_install_fail_open_trap stop-gate

input="$(< /dev/stdin)"
stop_callback_max_input_bytes=65536
session_id=""
cwd=""
transcript_path=""
stop_active=false
stop_recursive_callback_candidate=false
# Retained as a compatibility default for the dirty-worktree fast path. No
# ordinary callback sets it: recursive metadata without a valid direct marker
# is advisory and therefore continues.
stop_recursive_callback_unvalidated=false
stop_identity_malformed=false
stop_identity_decode_status=""
stop_identity_session_status=""
stop_identity_cwd_status=""
stop_identity_transcript_status=""
stop_identity_active_status=""

# Decode ownership/control identity once from the top-level JSON object.  The
# record has a fixed NUL-delimited shape so Bash never selects a nested field
# or reads a partial regex match from malformed callback bytes.
stop_identity_decode() {
  local -a record=()

  mapfile -d '' -t record < <(
    python3 - "$stop_callback_max_input_bytes" "$input" <<'PY'
import json
import sys

limit = int(sys.argv[1])
raw = sys.argv[2]
keys = ("session_id", "cwd", "transcript_path", "stop_hook_active")

class JSONObject(list):
    pass

def reject_constant(_value):
    raise ValueError("non-JSON numeric constant")

def field_status(value, expected_type):
    if value is _MISSING:
        return "absent", ""
    if type(value) is expected_type:
        if expected_type is bool:
            return "boolean", "true" if value else "false"
        return "string", value
    return "wrong_type", ""

def emit(values):
    if len(values) != 9:
        raise ValueError("unexpected decoder record shape")
    output = sys.stdout.buffer
    for value in values:
        output.write(value.encode("utf-8"))
        output.write(b"\0")

_MISSING = object()
try:
    if len(raw.encode("utf-8", "surrogateescape")) > limit:
        raise ValueError("callback exceeds bounded decoder input")
    value = json.loads(
        raw,
        object_pairs_hook=JSONObject,
        parse_constant=reject_constant,
    )
    if not isinstance(value, JSONObject):
        raise ValueError("top-level callback is not an object")
    fields = {}
    for key, candidate in value:
        if key not in keys:
            continue
        if key in fields:
            raise ValueError("duplicate top-level ownership/control key")
        fields[key] = candidate
    session_status, session_value = field_status(fields.get("session_id", _MISSING), str)
    cwd_status, cwd_value = field_status(fields.get("cwd", _MISSING), str)
    transcript_status, transcript_value = field_status(
        fields.get("transcript_path", _MISSING), str
    )
    active_status, active_value = field_status(
        fields.get("stop_hook_active", _MISSING), bool
    )
    emit((
        "ok",
        session_status,
        session_value,
        cwd_status,
        cwd_value,
        transcript_status,
        transcript_value,
        active_status,
        active_value,
    ))
except (TypeError, ValueError, UnicodeError, json.JSONDecodeError):
    emit(("error", "", "", "", "", "", "", "", ""))
PY
  )

  [ "${#record[@]}" -eq 9 ] || return 1
  [ "${record[0]}" = ok ] || return 1
  stop_identity_decode_status="${record[0]}"
  stop_identity_session_status="${record[1]}"
  session_id="${record[2]}"
  stop_identity_cwd_status="${record[3]}"
  cwd="${record[4]}"
  stop_identity_transcript_status="${record[5]}"
  transcript_path="${record[6]}"
  stop_identity_active_status="${record[7]}"
  stop_active="${record[8]}"
}

if ! stop_identity_decode; then
  stop_identity_malformed=true
else
  [ "$stop_identity_session_status" = string ] || stop_identity_malformed=true
  [ "$stop_identity_cwd_status" = string ] || stop_identity_malformed=true
  case "$stop_identity_transcript_status" in
    absent|string) ;;
    *) stop_identity_malformed=true ;;
  esac
  case "$stop_identity_active_status" in
    absent) stop_active=false ;;
    boolean) ;;
    *) stop_identity_malformed=true ;;
  esac
  if [ "$stop_identity_malformed" = false ]; then
    if [ -z "$session_id" ] || ! [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] ||
      [ -z "$cwd" ] || [[ "$cwd" != /* ]] || [[ "$cwd" == *[![:print:]]* ]]; then
      stop_identity_malformed=true
    fi
  fi
fi

if [ "$stop_identity_malformed" = true ]; then
  # Do not use a malformed field to identify a proof directory or marker.
  session_id=""
  cwd="$PWD"
  transcript_path=""
  stop_active=false
  canonical_stop_cwd="$(pwd -P)"
else
  if [ "$cwd" = "$PWD" ]; then
    canonical_stop_cwd="$(pwd -P)"
  else
    canonical_stop_cwd="$(codex_canonical_cwd "$cwd")"
  fi
  [ -n "$canonical_stop_cwd" ] || {
    stop_identity_malformed=true
    session_id=""
    cwd="$PWD"
    transcript_path=""
    stop_active=false
    canonical_stop_cwd="$(pwd -P)"
  }
fi
stop_recursive_callback_candidate="$stop_active"
root="$(codex_proof_root)"
export CODEX_STOP_GATE_ROOT="$root"
proof_dir=""
if [ "$stop_identity_malformed" = false ] && codex_valid_session_id "$session_id"; then
  proof_dir="$root/$session_id"
fi

# Active-stop discovery is intentionally bounded before any state parsing.  A
# valid typed session gets a direct lookup; ambiguity checks inspect only the
# root's immediate session directories.  Do not recurse through arbitrary
# child trees: those trees are unrelated proof state and are not part of the
# Stop marker namespace.
eci_stop_max_markers=64
eci_stop_max_namespace_entries=4096
eci_stop_max_marker_bytes="$codex_eci_marker_max_bytes"
# The fallback ownership scan is deliberately finite. It first bounds every
# immediate proof-root entry, then emits only eci_active candidates. This
# keeps no-direct ordinary callbacks finite even when unrelated directories
# contain no marker at all.

stop_direct_marker_path() {
  local candidate
  codex_valid_session_id "$session_id" || return 1
  candidate="$root/$session_id/eci_active"
  [ -e "$candidate" ] || [ -L "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

stop_marker_scan() {
  local entry marker namespace_count=0 marker_count=0

  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  # Every immediate proof-root entry counts toward the discovery ceiling, not
  # just entries that happen to contain eci_active. This is the bounded marker
  # namespace used before a no-direct ordinary callback may continue.
  while IFS= read -r -d '' entry; do
    namespace_count=$((namespace_count + 1))
    if [ "$namespace_count" -gt "$eci_stop_max_namespace_entries" ]; then
      printf '%s\0' '__ECI_STOP_MARKER_NAMESPACE_OVERFLOW__'
      return 0
    fi
    if [ -L "$entry" ]; then
      printf '%s\0' '__ECI_STOP_MARKER_NAMESPACE_UNSAFE__'
      return 0
    fi
    if [ -d "$entry" ] && [ ! -x "$entry" ]; then
      printf '%s\0' '__ECI_STOP_MARKER_NAMESPACE_UNSAFE__'
      return 0
    fi
    marker="$entry/eci_active"
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    marker_count=$((marker_count + 1))
    if [ "$marker_count" -gt "$eci_stop_max_markers" ]; then
      printf '%s\0' '__ECI_STOP_MARKER_OVERFLOW__'
      return 0
    fi
    printf '%s\0' "$marker"
  done < <(
    if ! find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null; then
      printf '%s\0' '__ECI_STOP_MARKER_NAMESPACE_UNSAFE__'
    fi
  )
}

# `find` does not follow a session-directory symlink while collecting
# eci_active files. Before trusting a direct-marker fast path, reject any
# immediate proof-root symlink rather than allowing a hidden peer or a
# symlinked direct session to evade the bounded marker scan. `-quit` keeps
# output bounded to one path and stops at the first unsafe child.
# R11: This sibling-symlink block is an adversarial evasion assumption; it does not itself prevent a concrete
# accidental deviation. Correct behavior is warning/self-repair of the unrelated sibling and continuation with the validated direct marker.
stop_root_has_unsafe_child_symlink() {
  local child

  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  child="$(find "$root" -mindepth 1 -maxdepth 1 -type l -print -quit 2>/dev/null)" || return 0
  [ -n "$child" ]
}

stop_marker_cache=()
stop_marker_cache_loaded=false
stop_marker_cache_status=0
stop_invalid_marker=""
# Set only when the direct typed-session marker passed the in-process fast
# validator. json_block_fast can reuse that result instead of running the
# full diagnostic classifier a second time.
stop_direct_marker_valid_fast=false
# `active_eci_marker_for_stop` runs in the caller shell so that the selected
# marker and its fully validated same-cwd peer count remain available to the
# common JSON blocker without a second partial ownership decision.
stop_selected_marker=""
stop_same_cwd_valid_peer_count=0
# Sibling records are maintenance observations, not alternate owners for a
# callback that has already validated its direct marker.  This is deliberately
# advisory: bots are not adversaries, and a stale/malformed sibling must not
# turn current-session work into a Stop loop.
stop_sibling_state_advisory=false
# Keep the malformed-identity preflight nounset-safe.  The full legacy marker
# lookup is intentionally deferred until after the authoritative fast path.
legacy_eci_active=""
stop_root_ambiguity_scan_cached=""

stop_root_requires_ambiguity_scan() {
  local link_count reserved_count=0 name marker
  [ "$stop_root_ambiguity_scan_cached" = true ] && return 0
  [ "$stop_root_ambiguity_scan_cached" = false ] && return 1
  if ! [ -d "$root" ] || [ -L "$root" ]; then
    stop_root_ambiguity_scan_cached=false
    return 1
  fi
  # On the Linux proof-root filesystem, a directory's link count is 2 plus
  # its immediate subdirectory count.  This cheap probe avoids spawning a
  # full bounded find for the normal one-session direct-marker case; any
  # additional session directory still routes through the existing strict
  # duplicate/overflow scan.
  link_count="$(stat -c '%h' -- "$root" 2>/dev/null || true)"
  case "$link_count" in
    ''|*[!0-9]*) stop_root_ambiguity_scan_cached=true; return 0 ;;
  esac
  if [ "$link_count" -le 3 ]; then
    stop_root_ambiguity_scan_cached=false
    return 1
  fi
  # Reserved proof namespaces are not sibling session owners.  Count those
  # fixed directories with shell builtins before deciding whether a bounded
  # scan is needed; the common direct-marker + activity layout therefore
  # avoids spawning find while duplicate normal-session detection remains
  # enabled whenever an unreserved sibling may exist.
  for name in activity audit eci history pre-reviewer reviewer reviewer-dumps \
    side-stop skip-stop skills; do
    if [ -e "$root/$name" ] || [ -L "$root/$name" ]; then
      if [ -d "$root/$name" ] && [ ! -L "$root/$name" ]; then
        reserved_count=$((reserved_count + 1))
        # A reserved namespace may itself carry an authoritative legacy
        # marker.  Probe those fixed paths directly; only such a marker (or
        # an unreserved sibling below) needs the bounded duplicate scan.
        marker="$root/$name/eci_active"
        if [ -e "$marker" ] || [ -L "$marker" ]; then
          stop_root_ambiguity_scan_cached=true
          return 0
        fi
      else
        stop_root_ambiguity_scan_cached=true
        return 0
      fi
    fi
  done
  # link_count is 2 + immediate subdirectory count on the supported proof
  # filesystems.  With only the direct session and known reserved dirs there
  # is no possible second session marker to discover.
  if [ "$link_count" -le $((3 + reserved_count)) ]; then
    stop_root_ambiguity_scan_cached=false
    return 1
  fi
  if [ "$link_count" -gt 3 ]; then
    stop_root_ambiguity_scan_cached=true
    return 0
  fi
  stop_root_ambiguity_scan_cached=false
  return 1
}

stop_marker_scan_required() {
  [ "$stop_recursive_callback_candidate" = true ] && return 0
  if stop_direct_marker_path >/dev/null 2>&1; then
    stop_root_requires_ambiguity_scan && return 0
    return 1
  fi
  # A callback without a direct marker must inspect the bounded immediate
  # namespace before ordinary Stop can continue: a fully valid same-cwd peer
  # marker remains authoritative even though it is owned by another session.
  return 0
}

stop_marker_cache_load() {
  local marker

  [ "$stop_marker_cache_loaded" = true ] && return "$stop_marker_cache_status"
  stop_marker_cache_loaded=true
  stop_marker_cache=()
  stop_marker_scan_required || return 0
  if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
    stop_marker_cache_status=2
    return 2
  fi
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' marker; do
    case "$marker" in
      __ECI_STOP_MARKER_OVERFLOW__|__ECI_STOP_MARKER_NAMESPACE_OVERFLOW__|__ECI_STOP_MARKER_NAMESPACE_UNSAFE__)
        stop_marker_cache_status=2
        return 2
        ;;
      *) stop_marker_cache+=("$marker") ;;
    esac
  done < <(stop_marker_scan || true)
  return 0
}

stop_marker_cache_has_unsafe_structural_sibling() {
  local direct_marker="$1" candidate

  # The startup bounded preflight owns file-type and size checks. This helper
  # distinguishes an unsafe type/owner from an unrelated record whose
  # embedded metadata is merely invalid. Hardlinks retain marker identity.
  [ "$stop_marker_cache_loaded" = true ] || return 1
  [ "${stop_marker_cache_status:-0}" -eq 0 ] || return 0
  for candidate in "${stop_marker_cache[@]}"; do
    [ "$candidate" = "$direct_marker" ] && continue
    codex_state_file_owner_is_valid "$candidate" false || return 0
  done
  return 1
}

stop_note_direct_marker_siblings() {
  local direct_marker="$1" candidate

  stop_same_cwd_valid_peer_count=0
  stop_sibling_state_advisory=false

  # The common one-session path does no discovery.  When sibling paths exist,
  # inspect them only to make an advisory available to the current owner.
  # Discovery/validation trouble is intentionally non-blocking here: the
  # direct marker has already established the concrete current-session work.
  stop_root_requires_ambiguity_scan || return 0
  while IFS= read -r -d '' candidate; do
    case "$candidate" in
      __ECI_STOP_MARKER_OVERFLOW__|__ECI_STOP_MARKER_NAMESPACE_OVERFLOW__|__ECI_STOP_MARKER_NAMESPACE_UNSAFE__)
        stop_sibling_state_advisory=true
        return 0
        ;;
    esac
    [ "$candidate" = "$direct_marker" ] && continue
    stop_sibling_state_advisory=true
    if codex_eci_marker_is_valid_for_cwd \
      "$candidate" "${canonical_stop_cwd:-$cwd}"; then
      stop_same_cwd_valid_peer_count=$((stop_same_cwd_valid_peer_count + 1))
    fi
  done < <(stop_marker_scan || true)
}

stop_marker_has_any() {
  if stop_direct_marker_path >/dev/null 2>&1; then
    return 0
  fi
  stop_marker_cache_load || [ "$stop_marker_cache_status" -eq 2 ] || return 1
  [ "${#stop_marker_cache[@]}" -gt 0 ]
}

json_continue() {
  # Fixed output keeps the inactive/no-marker callback free of a jq process.
  printf '%s\n' '{"continue":true}'
}

stop_diagnostic() {
  local reason="${1:-unspecified stop-gate denial}"
  local marker_context="${2:-${marker:-<none>}}"
  local instruction_context="${3:-${instructions:-<none>}}"
  local code remediation
  local subject="session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}"),marker=$(eci_diagnostic_value "$marker_context"),instructions=$(eci_diagnostic_value "$instruction_context")"
  case "$reason" in
    \[ECI_*\]*)
      code="${reason%%\]*}"
      code="${code#\[}"
      ;;
    *) code="$(eci_diagnostic_code_for_reason "$reason")" ;;
  esac
  remediation="continue the task and follow the identified marker or instructions; retry Stop only after the reported condition is resolved"
  case "$code" in
    ECI_STOP_ACTIVE_ECI)
      remediation="the marker remains authoritative; resume actual active ECI work or complete valid normal teardown; do not retry unchanged Stop"
      ;;
    ECI_STOP_MARKER_AMBIGUOUS)
      remediation="preserve both marker records; resolve duplicate ownership through the owning coordinator using scoped review admission or explicit teardown; retry Stop only after one validated owner remains"
      ;;
    ECI_STOP_MARKER_SCAN_UNSAFE)
      remediation="resolve the proof-root or marker-scan integrity condition through the coordinator route; do not retry Stop until the marker set is bounded and validated"
      ;;
    ECI_STOP_MARKER_UNSAFE)
      remediation="repair the marker ownership and cwd/session binding at the reported path through the coordinator route; retry Stop only after the marker is a regular validated file"
      ;;
    ECI_MARKER_MISSING_CURRENT)
      remediation="recreate the expected marker through the coordinator lifecycle route or complete teardown; retry Stop only after marker validation passes"
      ;;
    ECI_MARKER_UNSAFE_PATH)
      remediation="repair or remove the unsafe marker path through the coordinator route; retry Stop only after the path is a regular in-scope marker"
      ;;
    ECI_MARKER_MALFORMED)
      remediation="rewrite the marker through the coordinator lifecycle route with the required bounded schema; retry Stop only after marker validation passes"
      ;;
    ECI_MARKER_OWNERSHIP_INVALID)
      remediation="repair the marker owner/session binding through the coordinator lifecycle route; retry Stop only after ownership validation passes"
      ;;
    ECI_MARKER_SCOPE_MISMATCH)
      remediation="use the session/cwd bound to the marker or complete coordinator teardown; retry Stop only after scope validation passes"
      ;;
    ECI_STOP_SESSION_DIR_UNSAFE)
      remediation="repair the coordinator-owned session directory binding at the reported proof-root/session path; retry Stop only after the session directory is regular and in scope"
      ;;
    ECI_STOP_LOOP_STATE_UNSAFE)
      remediation="repair or remove the coordinator-owned stop-loop state through the coordinator route; retry Stop only after the state is a regular, bounded record"
      ;;
  esac
  eci_diagnostic_reason "$code" "Stop" "stop-admission" "$subject" "$reason" "$remediation"
}

# When a bounded marker scan finds unsafe state, diagnostics must still bind
# to the callback's owner. A stale marker from another session/cwd is not a
# candidate for a current-session scope error. Prefer the direct marker first;
# otherwise admit only the current session (or a reserved marker whose
# embedded owner and cwd match) to diagnostic selection.
stop_marker_candidate_matches_current() {
  local marker="$1" marker_dir marker_name marker_owner marker_cwd

  [ -n "$session_id" ] || return 1
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 1 ;;
  esac
  marker_dir="${marker%/*}"
  marker_name="${marker_dir##*/}"
  if codex_eci_marker_path_session_matches "$marker" "$session_id"; then
    return 0
  fi
  codex_reserved_proof_dir "$marker_name" || return 1
  marker_owner="$(codex_state_value "$marker" session_id false 2>/dev/null || true)"
  [ "$marker_owner" = "$session_id" ] || return 1
  marker_cwd="$(codex_state_value "$marker" cwd false 2>/dev/null || true)"
  [ -n "$marker_cwd" ] || return 1
  [ "$(codex_canonical_cwd "$marker_cwd")" = "${canonical_stop_cwd:-$cwd}" ]
}

active_eci_stop_reason() {
  local marker="$1" peer_count="${stop_same_cwd_valid_peer_count:-0}"
  local sibling_note=""

  case "$peer_count" in
    ''|*[!0-9]*) peer_count=0 ;;
  esac
  if [ "${stop_sibling_state_advisory:-false}" = true ]; then
    sibling_note=' sibling marker state is advisory and a separate maintenance/self-repair candidate; it does not change this callback owner.'
  fi
  if [ "$peer_count" -gt 0 ]; then
    printf '%s' "[ECI_STOP_ACTIVE_ECI] Stop is denied because the resolved ECI marker is valid and bound to this session/cwd: $marker; same_cwd_valid_peer_count=$peer_count; the direct marker remains authoritative.$sibling_note No marker repair is indicated. Resume actual active ECI work or complete valid normal teardown before retrying Stop. Do not retry unchanged Stop."
    return 0
  fi
  printf '%s' "[ECI_STOP_ACTIVE_ECI] Stop is denied because the resolved ECI marker is valid and bound to this session/cwd: $marker;$sibling_note no marker repair is indicated. The marker remains authoritative. Resume actual active ECI work or complete valid normal teardown before retrying Stop. Do not retry unchanged Stop."
}

stop_emit_selected_marker() {
  stop_selected_marker="$1"
  printf '%s\n' "$1"
}

foreign_same_cwd_eci_marker_is_valid() {
  local marker="$1" direct_marker marker_dir marker_session

  [ -n "$marker" ] || return 1
  direct_marker="$(stop_direct_marker_path 2>/dev/null || true)"
  [ -z "$direct_marker" ] || return 1
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 1 ;;
  esac
  marker_dir="${marker%/*}"
  [ -d "$marker_dir" ] && [ ! -L "$marker_dir" ] || return 1
  marker_session="${marker_dir##*/}"
  codex_valid_session_id "$marker_session" || return 1
  [ "$marker_session" != "$session_id" ] || return 1
  codex_eci_marker_is_valid_for_cwd "$marker" "${canonical_stop_cwd:-$cwd}"
}

foreign_same_cwd_eci_stop_reason() {
  local marker="$1" marker_dir marker_session

  marker_dir="${marker%/*}"
  marker_session="${marker_dir##*/}"
  printf '%s' "[ECI_STOP_ACTIVE_ECI] Stop is denied because callback session $session_id has no direct active ECI marker; the fully validated active ECI marker at $marker is owned by different session $marker_session and bound to the same canonical cwd. The marker remains authoritative. Resume actual active ECI work or complete valid normal teardown before retrying Stop. Do not retry unchanged Stop."
}

# Active ECI is a main/orchestrator concern. Keep the ordinary authoritative
# fast path to marker probes; active-marker denial never reads wait/report
# state to admit Stop and never mutates those lifecycle artifacts.
json_block_fast() {
  local marker="$1" reason marker_code direct_marker=""
  [ -n "$marker" ] || marker="$stop_invalid_marker"

  # A queued callback or older selector can supply a marker path that is no
  # longer authoritative. A non-transcript callback with a direct current
  # marker must diagnose that current owner, while an unsafe/overflowed scan
  # remains the higher-priority fail-closed condition.
  if [ -z "${transcript_path:-}" ] &&
    codex_valid_session_id "${session_id:-}" &&
    [ "${stop_marker_cache_status:-0}" -ne 2 ] &&
    codex_proof_root_is_safe &&
    direct_marker="$(stop_direct_marker_path 2>/dev/null || true)" &&
    [ -n "$direct_marker" ] && [ "$marker" != "$direct_marker" ]; then
    marker="$direct_marker"
    if codex_eci_marker_is_valid_for_cwd "$marker" "${canonical_stop_cwd:-$cwd}"; then
      stop_direct_marker_valid_fast=true
    fi
  fi

  if [ -z "$marker" ] &&
    [ "${stop_marker_cache_status:-0}" -ne 2 ] &&
    [ "${#stop_marker_cache[@]}" -gt 0 ]; then
    local candidate candidate_code
    for candidate in "${stop_marker_cache[@]}"; do
      # A nonempty malformed session cannot equal any path owner, but its
      # active marker still needs a concrete scope diagnostic. Empty and
      # syntactically valid sessions keep the current-owner filter.
      if [ -z "$session_id" ] || codex_valid_session_id "$session_id"; then
        stop_marker_candidate_matches_current "$candidate" || continue
      fi
      candidate_code="$(codex_eci_marker_failure_code "$candidate" "${canonical_stop_cwd:-$cwd}" "${session_id:-}" 2>/dev/null || true)"
      if [ -n "$candidate_code" ] && [ "$candidate_code" != ECI_MARKER_VALID ]; then
        marker="$candidate"
        break
      fi
    done
  fi
  if [ -z "$marker" ]; then
    reason="[ECI_STOP_MARKER_SCAN_UNSAFE] ECI stop state is unsafe or unavailable: marker scan overflowed or found an invalid marker without a concrete path for session=${session_id:-<missing>} cwd=${canonical_stop_cwd:-<missing>}. Do not stop; continue the ECI task and resolve the marker or proof-root integrity issue first."
    json_block_with_loop_state "$reason"
    return 0
  fi
  # The same-cwd discovery path selected this marker only after validating its
  # own path, ownership, schema, and canonical cwd. Keep that truthful peer
  # diagnostic out of the callback-session failure classifier below.
  if foreign_same_cwd_eci_marker_is_valid "$marker"; then
    reason="$(foreign_same_cwd_eci_stop_reason "$marker")"
    json_block_with_loop_state "$reason"
    return 0
  fi
  # The direct fast validator assumes the startup bounded-marker preflight
  # accepted the record. A rejected preflight must use the bounded diagnostic
  # path instead of rereading the untrusted marker.
  if [ "${stop_direct_marker_valid_fast:-false}" = true ] ||
    { [ "${marker_bound_status:-0}" -ne 2 ] &&
      [ -n "$marker" ] && [ -z "$transcript_path" ] &&
      [ "$marker" = "$root/$session_id/eci_active" ] &&
      stop_direct_marker_is_valid_fast "$marker" "${canonical_stop_cwd:-$cwd}"; }; then
    marker_code="ECI_MARKER_VALID"
  else
    marker_code="$(codex_eci_marker_failure_code "$marker" "${canonical_stop_cwd:-$cwd}" "${session_id:-}" 2>/dev/null || true)"
  fi
  [ -n "$marker_code" ] || marker_code="ECI_MARKER_VALIDATION_FAILED"
  case "$marker_code" in
    ECI_MARKER_VALID)
      marker_code="ECI_STOP_ACTIVE_ECI"
      reason="$(active_eci_stop_reason "$marker")"
      ;;
    ECI_MARKER_MISSING_CURRENT)
      reason="[$marker_code] Stop is denied because the expected ECI marker is missing at $marker for session=${session_id:-<missing>}. Recreate it through the coordinator lifecycle route or complete teardown before retrying."
      ;;
    ECI_MARKER_UNSAFE_PATH)
      reason="[$marker_code] Stop is denied because the ECI marker path is unsafe (symlink, non-regular path, or outside the proof-root/session layout): $marker. Remove the unsafe path through the coordinator route before retrying."
      ;;
    ECI_MARKER_MALFORMED)
      reason="[$marker_code] Stop is denied because the ECI marker has malformed bounded schema, size, newline, or control-byte content: $marker. Rewrite it through the coordinator lifecycle route before retrying."
      ;;
    ECI_MARKER_OWNERSHIP_INVALID)
      reason="[$marker_code] Stop is denied because the ECI marker path owner does not match its embedded session identity: $marker. Repair ownership through the coordinator lifecycle route before retrying."
      ;;
    ECI_MARKER_SCOPE_MISMATCH)
      reason="[$marker_code] Stop is denied because the ECI marker session/cwd binding does not match session=${session_id:-<missing>} cwd=${canonical_stop_cwd:-<missing>}: $marker. Use the bound session or complete coordinator teardown before retrying."
      ;;
    *)
      reason="[$marker_code] Stop is denied because ECI marker validation failed for session=${session_id:-<missing>} cwd=${canonical_stop_cwd:-<missing>}: $marker. Inspect the reported marker condition through the coordinator route before retrying."
      ;;
  esac
  json_block_with_loop_state "$reason"
}

# Keep active-marker discovery bounded before any ownership/cwd validation.
# These are fixed resource limits, not waits or retries; an overflow is unsafe
# control state and blocks read-only without creating recovery artifacts.
eci_stop_marker_set_is_bounded() {
  local marker count=0 bytes
  [ -d "$root" ] || {
    [ -e "$root" ] || [ -L "$root" ] || return 0
    return 2
  }
  [ ! -L "$root" ] || return 2
  # A valid direct current-session marker establishes the concrete owner for
  # this callback.  Sibling records may still be noted below as maintenance
  # observations, but they do not make the direct marker's bounded file probe
  # fail or turn normal work into a peer-state loop.
  if marker="$(stop_direct_marker_path 2>/dev/null || true)" &&
    [ -n "$marker" ]; then
    codex_eci_marker_file_is_bounded "$marker" || return 2
    return 0
  fi
  stop_marker_cache_load || return "$stop_marker_cache_status"
  for marker in "${stop_marker_cache[@]}"; do
    count=$((count + 1))
    [ "$count" -le "$eci_stop_max_markers" ] || return 2
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
    bytes="$(stat -c '%s' -- "$marker" 2>/dev/null || true)"
    case "$bytes" in
      ''|*[!0-9]*) return 2 ;;
    esac
    [ "$bytes" -le "$eci_stop_max_marker_bytes" ] || return 2
  done
  return 0
}

# Bind loop state to the current marker publication. Session IDs and
# canonical cwd can be reused after a clean teardown, so a persisted terminal
# counter must not suppress a fresh denial for a newly published marker. The
# marker is already bounded before active-stop admission reaches this helper;
# include both its inode metadata and bytes so recreation with identical
# content still starts a new generation.
codex_stop_loop_marker_generation() {
  local marker_path="${1:-}" metadata content_hash
  if [ -z "$marker_path" ]; then
    printf '%s' 'no-active-marker'
    return 0
  fi
  if [ -f "$marker_path" ] && [ ! -L "$marker_path" ]; then
    # GNU stat exposes nanosecond mtime/ctime through %y/%z. Marker ctime
    # changes on every lifecycle publication, including rapid remove/recreate
    # with identical bytes, while unrelated stop-loop state writes do not
    # mutate the marker itself.
    metadata="$(stat -Lc '%d:%i:%s:%y:%z' -- "$marker_path" 2>/dev/null || true)"
    if [ -n "$metadata" ] &&
      [[ "$metadata" != *$'\n'* ]] && [[ "$metadata" != *$'\r'* ]]; then
      # Nanosecond mtime/ctime and inode identity already distinguish every
      # supported marker publication. Avoid hashing the marker on the normal
      # GNU-stat path; reserve the content hash for the portable fallback.
      printf '%s' "$metadata"
      return 0
    fi
    # Deterministic fallback for stat implementations without nanosecond
    # fields. Inode, second-resolution timestamps, and marker bytes still
    # distinguish the normal lifecycle publication path.
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$marker_path" 2>/dev/null || true)"
    content_hash="$(sha256sum -- "$marker_path" 2>/dev/null || true)"
    content_hash="${content_hash%% *}"
    if [[ "$metadata" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] &&
      [[ "$content_hash" =~ ^[0-9a-f]{64}$ ]]; then
      printf '%s|%s' "$metadata" "$content_hash"
      return 0
    fi
  fi
  printf '%s' 'unavailable-marker'
}

json_block_with_loop_state() {
  local reason="$1"
  local loop_state loop_tmp loop_code loop_cwd loop_fingerprint loop_count loop_emitted
  local loop_marker_generation
  local loop_line loop_key loop_version loop_state_code loop_state_session loop_state_cwd loop_state_fingerprint
  local loop_state_count loop_state_emitted loop_line_count loop_state_valid
  local loop_publish_failed loop_state_owned loop_state_reset

  # Keep the normalized loop-state fields initialized even when this is the
  # first denial for a session.  `set -u` must not turn an absent state file
  # into an opaque hook failure.
  loop_state_code=""
  loop_state_session=""
  loop_state_cwd=""
  loop_state_fingerprint=""
  loop_version=""
  loop_state_count=0
  loop_state_emitted=false
  loop_line_count=0
  loop_state_valid=true
  loop_publish_failed=false
  loop_state_owned=true
  loop_state_reset=false

  # Loop bookkeeping is an optional convergence aid, never Stop admission.
  # If this callback cannot safely name a local state file, continuation is
  # preferable to a repeated denial caused by the bookkeeping itself.
  if [ -z "${proof_dir:-}" ] || ! codex_valid_session_id "${session_id:-}"; then
    json_continue
    return 0
  fi

  if ! codex_session_dir_is_safe "${root:-}" "${session_id:-}"; then
    json_continue
    return 0
  fi
  if ! mkdir -p -- "$proof_dir"; then
    json_continue
    return 0
  fi
  loop_state="$proof_dir/stop_loop_state"
  loop_code="$(eci_diagnostic_code_for_reason "$reason")"
  loop_cwd="${canonical_stop_cwd:-$(codex_canonical_cwd "${cwd:-$PWD}")}"
  loop_marker_generation="$(codex_stop_loop_marker_generation "${marker:-}")"
  # This record is not an authorization boundary.  It only ensures that a
  # host retry sees one useful reminder and then a bounded continuation.
  loop_fingerprint="$(codex_hash_string "${loop_code}|${reason}|${loop_marker_generation}" 2>/dev/null || true)"
  if ! [[ "$loop_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
    loop_fingerprint="$(printf '%s' "${loop_code}|${reason}|${loop_marker_generation}" | sha256sum || true)"
    loop_fingerprint="${loop_fingerprint%% *}"
  fi
  loop_count=0
  loop_emitted=false
  loop_state_valid=true
  if [ -e "$loop_state" ] || [ -L "$loop_state" ]; then
    if ! codex_state_file_owner_is_valid "$loop_state"; then
      loop_state_owned=false
      loop_state_valid=false
    elif [ ! -r "$loop_state" ]; then
      loop_state_valid=false
    else
      loop_state_code=""
      loop_state_session=""
      loop_state_cwd=""
      loop_state_fingerprint=""
      loop_state_count=""
      loop_state_emitted=""
      loop_version=""
      loop_line_count=0
      while IFS= read -r loop_line || [ -n "$loop_line" ]; do
        loop_line_count=$((loop_line_count + 1))
        case "$loop_line" in
          'version: 1') [ -z "$loop_version" ] || loop_state_valid=false; loop_version=1 ;;
          'version: 2') [ -z "$loop_version" ] || loop_state_valid=false; loop_version=2 ;;
          'code: '*) [ -z "$loop_state_code" ] || loop_state_valid=false; loop_state_code="${loop_line#code: }" ;;
          'session_id: '*) [ -z "$loop_state_session" ] || loop_state_valid=false; loop_state_session="${loop_line#session_id: }" ;;
          'cwd: '*) [ -z "$loop_state_cwd" ] || loop_state_valid=false; loop_state_cwd="${loop_line#cwd: }" ;;
          'fingerprint: '*) [ -z "$loop_state_fingerprint" ] || loop_state_valid=false; loop_state_fingerprint="${loop_line#fingerprint: }" ;;
          'count: '*) [ -z "$loop_state_count" ] || loop_state_valid=false; loop_state_count="${loop_line#count: }" ;;
          'loop_emitted: true') [ -z "$loop_state_emitted" ] || loop_state_valid=false; loop_state_emitted=true ;;
          'loop_emitted: false') [ -z "$loop_state_emitted" ] || loop_state_valid=false; loop_state_emitted=false ;;
          *) loop_state_valid=false ;;
        esac
        [ "$loop_line_count" -le 7 ] || loop_state_valid=false
      done <"$loop_state" || loop_state_valid=false
      [[ "$loop_version" = 1 || "$loop_version" = 2 ]] || loop_state_valid=false
      if [ "$loop_version" = 1 ]; then
        # Version-1 state predates callback fingerprints. Its persisted
        # count is stale by definition; reset it on this callback.
        [ "$loop_line_count" -eq 6 ] || loop_state_valid=false
      else
        [ "$loop_line_count" -eq 7 ] || loop_state_valid=false
        [[ "$loop_state_fingerprint" =~ ^[0-9a-f]{64}$ ]] || loop_state_valid=false
      fi
      [[ "$loop_state_code" =~ ^[A-Z0-9_]{1,128}$ ]] || loop_state_valid=false
      codex_valid_session_id "$loop_state_session" || loop_state_valid=false
      [[ "$loop_state_count" =~ ^[1-9][0-9]{0,5}$ ]] || loop_state_valid=false
      [ -n "$loop_state_cwd" ] || loop_state_valid=false
    fi
    if [ "$loop_state_valid" != true ]; then
      # A well-scoped ordinary file can be reset in place. An unsafe or
      # unwritable record is left untouched; it simply cannot generate an
      # additional Stop denial.
      if [ "$loop_state_owned" = true ] && [ -f "$loop_state" ] && [ ! -L "$loop_state" ]; then
        loop_state_reset=true
        loop_state_code=""
        loop_state_session=""
        loop_state_cwd=""
        loop_state_fingerprint=""
        loop_state_count=0
        loop_state_emitted=false
        loop_version=""
      else
        json_continue
        return 0
      fi
    fi
  fi
  if [ "$loop_version" = 1 ]; then
    loop_state_fingerprint=""
  fi
  if [ "$loop_state_reset" != true ] &&
    [ "$loop_state_fingerprint" = "$loop_fingerprint" ] &&
    [ "$loop_state_code" = "$loop_code" ] &&
    [ "$loop_state_session" = "${session_id:-}" ] &&
    [ "$loop_state_cwd" = "$loop_cwd" ]; then
    if [ "${loop_state_emitted:-false}" = true ]; then
      json_continue
      return 0
    fi
  fi
  # First occurrence (and legacy pre-R11 records) gets the one useful
  # reminder. Do not increment a counter: all identical later callbacks take
  # the continuation branch above.
  loop_count=1
  loop_emitted=true
  loop_tmp="$loop_state.tmp.$$"
  if [ -e "$loop_tmp" ] || [ -L "$loop_tmp" ]; then
    json_continue
    return 0
  fi
  if {
    printf 'version: 2\nfingerprint: %s\ncode: %s\nsession_id: %s\ncwd: %s\ncount: %s\nloop_emitted: %s\n' \
      "$loop_fingerprint" "$loop_code" "${session_id:-}" "$loop_cwd" "$loop_count" "$loop_emitted"
  } 2>/dev/null >"$loop_tmp"; then
    if ! mv -- "$loop_tmp" "$loop_state" 2>/dev/null; then
      loop_publish_failed=true
    fi
  else
    loop_publish_failed=true
  fi

  if [ "$loop_publish_failed" = true ]; then
    # Cleanup only the exact regular temp record we created. Failure to clean
    # it is also advisory: the marker decision above remains untouched.
    if [ -f "$loop_tmp" ] && [ ! -L "$loop_tmp" ] &&
      codex_state_file_owner_is_valid "$loop_tmp"; then
      rm -f -- "$loop_tmp" || true
    fi
    json_continue
    return 0
  fi

  reason="$(stop_diagnostic "$reason" "${marker:-<none>}" "${instructions:-<none>}")"
  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# Keep the public denial helper stable while sharing its bounded convergence
# state with the active-marker fast path.
json_block() {
  json_block_with_loop_state "$1"
}

# Unsafe marker-discovery state has no trusted owner for loop bookkeeping.
# Render its diagnostic without creating or updating any stop-loop record.
json_block_stateless() {
  local reason

  reason="$(stop_diagnostic "$1" "${marker:-<none>}" "${instructions:-<none>}")"
  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# A failed top-level identity decode is allowed to preserve the ordinary
# inactive/no-marker continuation path, but it must not inspect a direct wait
# or write loop state when an active ECI marker may be relevant.
if [ "$stop_identity_malformed" = true ]; then
  # Without a usable current-session identity there is no concrete marker
  # target to own this callback. Do not turn a sibling scan or raw callback
  # grammar into a repeated Stop denial; the client can continue and the next
  # well-formed callback will evaluate its direct marker normally.
  json_continue
  exit 0
fi

marker_bound_status=0
eci_stop_marker_set_is_bounded || marker_bound_status=$?
if [ "$marker_bound_status" -eq 2 ]; then
  # A direct path is concrete current-session control state and still receives
  # its focused marker reminder below. A failed peer/namespace scan with no
  # direct marker is only auxiliary discovery metadata, so it must not invent
  # an active owner or a Stop loop.
  if stop_direct_marker_path >/dev/null 2>&1; then
    json_block_fast ""
    exit 0
  fi
  marker_bound_status=0
fi

# Validate an ECI marker without following the final session/marker symlinks.
# Return 0 for a regular marker, 1 for an absent marker, and 2 for an unsafe
# existing path.  Ancestor cache symlinks are allowed when they resolve to the
# stable directories checked by eci_root_is_safe_for_stop.
eci_marker_is_safe_regular() {
  local marker="$1"
  local parent

  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 2 ;;
  esac

  eci_root_is_safe_for_stop || return 2

  parent="${marker%/*}"
  [ ! -L "$parent" ] || return 2
  if [ ! -d "$parent" ]; then
    [ ! -e "$parent" ] && return 1
    return 2
  fi

  [ ! -L "$marker" ] || return 2
  [ -e "$marker" ] || return 1
  [ -f "$marker" ] || return 2
  # Do not let a path-shaped marker become authoritative when its embedded
  # session/cwd record is malformed or belongs to another working directory.
  # This is still a bounded marker read; it does not enter transcript or
  # recovery-state handling.
  codex_eci_marker_is_valid_for_cwd "$marker" "$canonical_stop_cwd" || return 2
}

eci_root_is_safe_for_stop() {
  local parent

  codex_proof_root_is_safe || return 2
  case "$root" in
    /*) ;;
    *) return 2 ;;
  esac
  parent="${root%/*}"
  [ -n "$parent" ] || parent="/"

  # A missing default root is normal.  Existing root/parent paths must still
  # be directories; this catches a directory-to-file swap without writing to
  # the replaced path.  Symlink roots are unsafe, while an existing symlink
  # parent is allowed when it still resolves to a directory (the default
  # deployment may use a symlinked cache parent).
  [ ! -L "$root" ] || return 2
  if [ -e "$root" ]; then
    [ -d "$root" ] || return 2
  fi
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] || return 2
  fi
  return 0
}

stop_direct_marker_is_valid_fast() {
  local marker="$1" expected_cwd="$2"
  local marker_dir marker_name marker_cwd
  local -a lines=()

  case "$marker" in
    "$root/$session_id/eci_active") ;;
    *) return 1 ;;
  esac
  marker_dir="${marker%/*}"
  [ -d "$marker_dir" ] && [ ! -L "$marker_dir" ] || return 1
  codex_state_file_owner_is_valid "$marker" false || return 1
  # eci_stop_marker_set_is_bounded already performed the shared finite-size
  # probe before this validator runs.  Avoid reading the same marker twice on
  # every active callback; the remaining mapfile is the schema/ownership read.
  mapfile -t lines <"$marker" || return 1
  case "${#lines[@]}" in 3|4) ;; *) return 1 ;; esac
  for line in "${lines[@]}"; do
    [[ "$line" != *[[:cntrl:]]* ]] || return 1
  done
  case "${lines[0]}" in "scope: "*) ;; *) return 1 ;; esac
  case "${lines[1]}" in "cwd: "*) ;; *) return 1 ;; esac
  case "${lines[2]}" in "session_id: $session_id") ;; *) return 1 ;; esac
  if [ "${#lines[@]}" -eq 4 ]; then
    case "${lines[3]}" in "created_utc: "*) ;; *) return 1 ;; esac
  fi
  marker_cwd="${lines[1]#cwd: }"
  [ -n "${lines[0]#scope: }" ] || return 1
  [ -n "$marker_cwd" ] || return 1
  case "$marker_cwd" in /*) ;; *) return 1 ;; esac
  [ "$(codex_canonical_cwd "$marker_cwd")" = "$expected_cwd" ] || return 1
  marker_name="${marker_dir##*/}"
  [ "$marker_name" = "$session_id" ]
}

active_eci_marker_for_stop() {
  local marker side_stop parent_session_id is_subagent_context=false marker_status
  local transcript_owner="" subagent_metadata="" direct_marker=""

  stop_direct_marker_valid_fast=false
  stop_selected_marker=""
  stop_same_cwd_valid_peer_count=0

  # A malformed typed hook identity cannot silently enter generic stop logic
  # while any regular ECI marker exists.  This scan is only a bounded proof-root
  # glob; it does not parse transcripts, ledgers, or recovery state.
  if [ "$stop_identity_malformed" = true ]; then
    stop_marker_has_any && return 2
    return 1
  fi

  # A validated direct current-session marker is the callback owner regardless
  # of sibling marker debris.  Siblings are advisory maintenance candidates:
  # they are not alternate owners, and a malformed/duplicate/unrelated record
  # must not block this ordinary callback before the current owner can make
  # progress.  This is a coordination guard, not adversarial containment.
  direct_marker="$(stop_direct_marker_path 2>/dev/null || true)"
  if [ -n "$direct_marker" ]; then
    if stop_direct_marker_is_valid_fast "$direct_marker" "$canonical_stop_cwd"; then
      stop_direct_marker_valid_fast=true
      stop_note_direct_marker_siblings "$direct_marker"
      stop_emit_selected_marker "$direct_marker"
      return 0
    fi
    return 2
  fi

  # There is no direct current-session marker. Peer marker records, malformed
  # scan entries, and discovery ambiguity are auxiliary maintenance metadata;
  # they cannot select an owner for this callback or hold ordinary Stop. The
  # explicit parent-side-stop path below is still a direct relationship, not
  # a scan-derived peer inference.

  # A normal transcript path carries its session UUID.  This lets the direct
  # marker decision avoid opening/parsing transcript data on the hot path.
  if [ -n "$transcript_path" ]; then
    transcript_owner="$(codex_path_owner_session_id "$transcript_path" 2>/dev/null || true)"
  fi

  if codex_valid_session_id "$session_id"; then
    marker="$root/$session_id/eci_active"

    # A missing transcript or a path owned by this session is authoritative:
    # do not run the Python transcript scanner or enumerate legacy state.
    if [ -z "$transcript_path" ] || [ "$transcript_owner" = "$session_id" ]; then
      if [ -n "$direct_marker" ] && [ "$marker" = "$direct_marker" ]; then
        stop_direct_marker_is_valid_fast "$marker" "$canonical_stop_cwd" || return 2
        stop_emit_selected_marker "$marker"
        return 0
      fi
      marker_status=0
      if eci_marker_is_safe_regular "$marker"; then
        stop_emit_selected_marker "$marker"
        return 0
      else
        marker_status=$?
        [ "$marker_status" -eq 2 ] && return 2
      fi
    fi

    # Unknown/synthetic transcript paths retain the historical parent/subagent
    # precedence check.  It is off the direct-marker fast path and bounded by
    # the existing helper's input budget.
    if [ -n "$transcript_path" ]; then
      # Read the bounded metadata prefix once.  The helper emits a closed
      # object, so a shell match avoids a second jq/Python process.
      subagent_metadata="$(codex_hook_thread_spawn_metadata "$input" 2>/dev/null || true)"
      case "$subagent_metadata" in
        *'"parent_thread_id":'*)
          is_subagent_context=true
          if [[ "$subagent_metadata" =~ \"parent_thread_id\":\"([^\"]*)\" ]]; then
            parent_session_id="${BASH_REMATCH[1]}"
          else
            parent_session_id=""
          fi
          ;;
      esac
    fi

    if [ "$is_subagent_context" = true ]; then
      if [ "$session_id" = "$parent_session_id" ]; then
        # A transcript's parent-thread label does not deactivate the current
        # session's validated marker. Return it to the common active-marker
        # blocker before any subagent continuation path can run.
        marker_status=0
        if eci_marker_is_safe_regular "$marker"; then
          stop_emit_selected_marker "$marker"
          return 0
        else
          marker_status=$?
          [ "$marker_status" -eq 2 ] && return 2
          return 1
        fi
      fi
    fi

    marker_status=0
    if eci_marker_is_safe_regular "$marker"; then
      stop_emit_selected_marker "$marker"
      return 0
    else
      marker_status=$?
      [ "$marker_status" -eq 2 ] && return 2
    fi

    [ "$is_subagent_context" = true ] && return 1

    side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)
    parent_session_id="$(codex_state_value "$side_stop" parent_session_id || true)"
    if codex_valid_session_id "$parent_session_id"; then
      marker="$root/$parent_session_id/eci_active"
      marker_status=0
      if eci_marker_is_safe_regular "$marker"; then
        stop_emit_selected_marker "$marker"
        return 0
      else
        marker_status=$?
        [ "$marker_status" -eq 2 ] && return 2
      fi
    fi

    # A valid typed session with no own marker has no active ECI ownership.
    # Return before legacy/root discovery; side-stop and parent ownership were
    # checked above using only their bounded direct paths.
    if ! stop_direct_marker_path; then
      return 1
    fi
  fi

  [ "$is_subagent_context" = true ] && return 1

  marker="$(codex_legacy_eci_markers_for_cwd "$cwd" "$session_id" 2>/dev/null | head -n1 || true)"
  [ -n "$marker" ] || return 1
  marker_status=0
  if eci_marker_is_safe_regular "$marker"; then
    stop_emit_selected_marker "$marker"
    return 0
  fi
  marker_status=$?
  [ "$marker_status" -eq 2 ] && return 2
  return 1
}

block_if_eci_active_for_stop() {
  local marker marker_status=0 direct_marker=""

  if active_eci_marker_for_stop >/dev/null; then
    marker="$stop_selected_marker"
    [ -n "$marker" ] || return 1
    if [ "$stop_recursive_callback_candidate" = true ]; then
      direct_marker="$(stop_direct_marker_path 2>/dev/null || true)"
      # A recursive callback has no active-work boundary unless the selected
      # marker is its own valid direct marker. Peer records, parent metadata,
      # and callback form are advisory rather than prerequisites for ordinary
      # work, so leave this callback to the normal continuation path.
      [ "$marker" = "$direct_marker" ] || return 1
    fi
    json_block_fast "$marker"
    return 0
  else
    marker_status=$?
    # Only a malformed direct path is concrete current-session control state.
    # Sibling scan status (including overflow, links, and duplicate metadata)
    # is advisory and must not replace that focused result or invent an owner.
    if [ "$marker_status" -eq 2 ]; then
      direct_marker="$(stop_direct_marker_path 2>/dev/null || true)"
      if [ -n "$direct_marker" ]; then
        stop_invalid_marker="$direct_marker"
        json_block_fast ""
        return 0
      fi
    fi
    # No valid direct marker means recursive callback fields and peer scans
    # cannot manufacture an owner or turn ordinary work into a Stop denial.
    return 1
  fi
}

proof=""
instructions=""
stop_historical_evidence_advisory=false
if [ -n "$proof_dir" ]; then
  proof="$proof_dir/proof.md"
  instructions="$proof_dir/instructions.md"
fi

proof_recovery_text() {
  printf ' Legacy proof files are optional. Update or remove %s using %s; if that file is missing, read %s.' \
    "$proof" "$instructions" "$CODEX_PROVIDER_HOME/hooks/stop-checklist.md"
}

block_proof_validation() {
  # Proof receipts, headings, audit notes, and reviewer artifacts describe
  # historical review state. They can be revisited during normal current-diff
  # work, but do not own this Stop callback once the direct marker path has
  # declined it.
  stop_historical_evidence_advisory=true
  return 0
}

root_status=0
eci_root_is_safe_for_stop || root_status=$?
if [ "$root_status" -eq 2 ]; then
  json_block_fast ""
  exit 0
fi

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*)
    # An invalid typed identity cannot silently bypass an active ECI marker.
    # Keep the inactive/missing-marker case lightweight and unchanged.  Scan
    # only the proof-root marker entries; no transcript or ledger work occurs.
    if stop_marker_has_any; then
      json_block_fast "$legacy_eci_active"
    elif [ "$stop_recursive_callback_candidate" = true ]; then
      json_block_fast ""
    else
      json_continue
    fi
    exit 0
    ;;
esac

if block_if_eci_active_for_stop; then
  exit 0
fi

teardown_complete=false
teardown_receipt="$proof_dir/eci-teardown-complete"
aggregate_plan="$proof_dir/eci-aggregate-plan.json"
aggregate_teardown_receipt="$proof_dir/eci-aggregate-teardown-complete"
if [ -e "$aggregate_plan" ] || [ -L "$aggregate_plan" ] ||
  [ -e "$aggregate_teardown_receipt" ] || [ -L "$aggregate_teardown_receipt" ]; then
  if [ -e "$teardown_receipt" ] || [ -L "$teardown_receipt" ]; then
    stop_historical_evidence_advisory=true
  fi
  if codex_eci_aggregate_teardown_receipt_is_valid "$aggregate_teardown_receipt" "$session_id"; then
    teardown_complete=true
  else
    stop_historical_evidence_advisory=true
  fi
elif [ -e "$teardown_receipt" ] || [ -L "$teardown_receipt" ]; then
  if codex_eci_teardown_receipt_is_valid "$teardown_receipt" "$session_id" "$proof_dir/eci-required-critics.json"; then
    teardown_complete=true
  else
    stop_historical_evidence_advisory=true
  fi
fi

if [ -z "$transcript_path" ] && [ "$stop_recursive_callback_candidate" != true ]; then
  json_continue
  exit 0
fi

# The active-ECI path above is intentionally read-only.  Initialize scratch
# storage only after that authoritative fast path has declined the callback.
codex_init_tmp || true

git_change_summary() {
  local repo="$1"
  local baseline="$2"
  local base status changed=false

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
      if ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
        printf 'commits changed since baseline %s..HEAD\n' "$base"
        changed=true
      fi
    fi
  fi

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    changed=true
  fi

  [ "$changed" = "true" ]
}

git_dirty_summary() {
  local repo="$1"
  local status

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    return 0
  fi

  return 1
}

git_head_summary() {
  local repo="$1"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$repo" log -1 --oneline 2>/dev/null || true
}

indent_text() {
  sed 's/^/  /'
}

touched_repo_change_summary() {
  local marker="$1"
  local repo base_status_sha status status_sha repo_wide path path_status found=false

  repo="$(codex_state_value "$marker" repo || true)"
  [ -n "$repo" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)"
  [ -n "$status" ] || return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path_status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal -- "$path" 2>/dev/null || true)"
    [ -n "$path_status" ] || continue
    if [ "$found" = false ]; then
      printf '%s\n' "$repo"
      found=true
    fi
    printf '%s\n' "$path_status" | indent_text
  done < <(awk 'index($0, "path: ") == 1 { print substr($0, 7) }' "$marker" 2>/dev/null)
  [ "$found" = true ] && return 0

  repo_wide="$(codex_state_value "$marker" repo_wide || true)"
  [ "$repo_wide" = true ] || return 1

  base_status_sha="$(codex_state_value "$marker" status_sha || true)"
  status_sha="$(codex_hash_string "$status")"

  if [ -n "$status" ] && [ -n "$base_status_sha" ] && [ "$status_sha" != "$base_status_sha" ]; then
    printf '%s\n' "$repo"
    printf '%s\n' "$status" | indent_text
    return 0
  fi

  return 1
}

touched_repos_change_summary() {
  local session_id="$1"
  local dir marker found=false summary

  dir="$(codex_session_state_dir touched-repos "$session_id" 2>/dev/null || true)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  for marker in "$dir"/*; do
    [ -f "$marker" ] || continue
    summary="$(touched_repo_change_summary "$marker" || true)"
    [ -n "$summary" ] || continue
    printf '%s\n' "$summary"
    found=true
  done

  [ "$found" = "true" ]
}

publish_worker_dirty_handoff() {
  local coordinator_session_id="$1" change_summary="$2"
  local handoff handoff_tmp canonical_cwd

  # This is a status handoff, not a permission record.  The worker has already
  # done the useful thing by identifying its own dirty paths; the coordinator
  # needs that fact, not a forced commit or a ceremony before normal return.
  [ -n "${proof_dir:-}" ] || return 1
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  mkdir -p -- "$proof_dir" || return 1
  [ -d "$proof_dir" ] && [ ! -L "$proof_dir" ] || return 1

  handoff="$proof_dir/latest-status-report.md"
  [ ! -L "$handoff" ] || return 1
  [ ! -e "$handoff" ] || [ -f "$handoff" ] || return 1
  handoff_tmp="$proof_dir/.latest-status-report.md.worker-handoff.$$.tmp"
  [ ! -e "$handoff_tmp" ] && [ ! -L "$handoff_tmp" ] || return 1
  canonical_cwd="$(codex_canonical_cwd "$cwd")"
  [ -n "$canonical_cwd" ] || return 1

  if ! {
    printf '%s\n' '# Worker dirty-worktree handoff'
    printf '%s\n' 'state: dirty-worktree-handoff'
    printf 'worker_session_id: %s\n' "$session_id"
    printf 'coordinator_session_id: %s\n' "$coordinator_session_id"
    printf 'cwd: %s\n' "$canonical_cwd"
    printf '%s\n' 'route: normal-worker-return'
    printf '%s\n' ''
    printf '%s\n' '## Changed owned paths'
    printf '%s\n' "$change_summary" | indent_text
  } >"$handoff_tmp"; then
    rm -f -- "$handoff_tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -- "$handoff_tmp" "$handoff"; then
    rm -f -- "$handoff_tmp" 2>/dev/null || true
    return 1
  fi
}

format_gitleaks_findings() {
  local report="$1"

  # The scanner runs with --redact. Keep the optional handoff equally small:
  # a candidate location and rule are useful for an accidental inclusion, but
  # neither matched text nor arbitrary scanner descriptions belong in it.
  jq -r '
    .[] |
    "\(.File // "<unknown>"):\((.StartLine // "?") | tostring) \(.RuleID // "unknown")"
  ' "$report" 2>/dev/null
}

run_gitleaks_command() {
  local report="$1"
  shift
  local out rc

  out=$("$@" 2>&1)
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      printf '%s\n' "$out" >"${report}.err"
      return 2
      ;;
  esac
}

run_secret_scan() {
  local repo="$1"
  local baseline="$2"
  local proof_dir="$3"
  local report="$proof_dir/gitleaks-report.json"
  local findings="$proof_dir/gitleaks-findings.txt"
  local worktree_report="$proof_dir/gitleaks-worktree-report.json"
  local commit_report="$proof_dir/gitleaks-commit-report.json"
  local tmp_index base findings_count worktree_dirty commit_changed scan_rc errors=""
  local -a reports

  rm -f "$report" "$findings" "$worktree_report" "$commit_report" \
    "${worktree_report}.err" "${commit_report}.err"

  if ! command -v gitleaks >/dev/null 2>&1; then
    printf '%s\n' "gitleaks not found on PATH" >"$findings"
    return 2
  fi

  worktree_dirty=false
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
    worktree_dirty=true
  fi

  commit_changed=false
  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null &&
      ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
      commit_changed=true
    fi
  fi

  if [ "$worktree_dirty" = "true" ]; then
    tmp_index=$(mktemp "$proof_dir/gitleaks-index.XXXXXX")
    rm -f "$tmp_index"
    if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" read-tree HEAD >/dev/null 2>&1
    else
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" read-tree --empty >/dev/null 2>&1
    fi
    if [ "$?" -eq 0 ]; then
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" add -N -- . >/dev/null 2>&1 || true
      scan_rc=0
      GIT_INDEX_FILE="$tmp_index" run_gitleaks_command "$worktree_report" \
        gitleaks protect --source "$repo" --redact --no-banner --log-level error \
          --report-format json --report-path "$worktree_report" || scan_rc=$?
      case "$scan_rc" in
        0|1)
          [ -f "$worktree_report" ] || errors="$errors worktree"
          ;;
        *) errors="$errors worktree" ;;
      esac
    else
      printf '%s\n' "could not prepare temporary git index for worktree scan" >"${worktree_report}.err"
      errors="$errors worktree"
    fi
    rm -f "$tmp_index"
  fi

  if [ "$commit_changed" = "true" ]; then
    scan_rc=0
    run_gitleaks_command "$commit_report" \
      gitleaks detect --source "$repo" --log-opts "$base..HEAD" --redact --no-banner \
        --log-level error --report-format json --report-path "$commit_report" || scan_rc=$?
    case "$scan_rc" in
      0|1)
        [ -f "$commit_report" ] || errors="$errors commits"
        ;;
      *) errors="$errors commits" ;;
    esac
  fi

  reports=()
  [ -f "$worktree_report" ] && reports+=("$worktree_report")
  [ -f "$commit_report" ] && reports+=("$commit_report")
  if [ "${#reports[@]}" -gt 0 ]; then
    jq -s 'add' "${reports[@]}" >"$report" 2>/dev/null || cp "${reports[0]}" "$report"
  else
    printf '[]\n' >"$report"
  fi

  if [ -n "$errors" ]; then
    # A scanner failure is an optional diagnostic, not an admission failure.
    # Do not copy arbitrary scanner stderr into the proof handoff.
    printf '%s\n' "gitleaks could not complete for:$errors" >"$findings"
    rm -f "${worktree_report}.err" "${commit_report}.err"
    return 2
  fi

  findings_count=$(jq 'length' "$report" 2>/dev/null || printf '0')
  if [ "${findings_count:-0}" -gt 0 ]; then
    format_gitleaks_findings "$report" >"$findings"
    return 1
  fi

  rm -f "$findings" "$worktree_report" "$commit_report"
  return 0
}

canonical_existing_path() {
  local path="$1"
  local dir base canonical_dir

  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    canonical_dir="$( (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir" )"
    printf '%s/%s\n' "$canonical_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

git_common_dir() {
  local repo="$1"
  local common top

  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    canonical_existing_path "$common"
    return
  fi

  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  case "$common" in
    /*) canonical_existing_path "$common" ;;
    *) canonical_existing_path "${top:-$repo}/$common" ;;
  esac
}

repo_identity() {
  local repo="$1"
  local top common

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$repo")"
    top="$(canonical_existing_path "$top")"
    common="$(git_common_dir "$repo")"
    printf 'git:%s:%s\n' "$top" "$common"
  else
    printf 'nogit:%s\n' "$(codex_canonical_cwd "$repo")"
  fi
}

activity_marker_summary() {
  local session_id="$1"
  local cwd="$2"
  local marker name found=""

  for name in shell edit subagent; do
    marker=$(codex_existing_state_file activity "$name" "$session_id" "$cwd" 2>/dev/null || true)
    [ -n "$marker" ] && found="$found $name"
  done

  printf '%s\n' "$found"
}

transcript_has_activity_since_last_user() {
  local transcript="$1"

  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  jq -e -s '
    def response_item_type($e):
      $e.payload.type // $e.payload.item.type // "";
    def content_of($e):
      $e.message.content // $e.payload.message.content // $e.payload.item.content // $e.payload.content // "";
    def event_role($e):
      if $e.type == "user" then "user"
      elif $e.type == "assistant" then "assistant"
      elif $e.type == "response_item" then
        if response_item_type($e) == "function_call" then "assistant"
        elif response_item_type($e) == "function_call_output" then "tool_result"
        else ($e.payload.role // $e.payload.item.role // "") end
      elif $e.type == "message" then ($e.role // "")
      else "" end;
    def is_real_user($e):
      event_role($e) == "user"
      and ((content_of($e) | type) == "string")
      and ((content_of($e) | test("^[[:space:]]*<(hook_prompt|subagent_notification|turn_aborted)"; "i")) | not)
      and (($e.isMeta // $e.message.isMeta // false) | not);
    def call_records($e):
      if $e.type == "response_item" and response_item_type($e) == "function_call" then
        [{
          name: ($e.payload.name // $e.payload.item.name // ""),
          arguments: (($e.payload.arguments // $e.payload.item.arguments // "") | tostring)
        }]
      else
        (content_of($e) as $c
        | if ($c | type) == "array" then
          [$c[] | select(.type == "tool_use" or .type == "function_call")
            | {name: (.name // ""), arguments: ((.input // .arguments // "") | tostring)}]
        else [] end)
      end;
    def active_call($c):
      (($c.name // "") | test("(^|\\.)(apply_patch|Edit|Write|MultiEdit|spawn_agent|send_input|wait_agent|close_agent|resume_agent)$"))
      or
      (($c.name // "") == "multi_tool_use.parallel"
        and (($c.arguments // "") | test("functions\\.(apply_patch|spawn_agent|send_input|wait_agent|close_agent|resume_agent)")));
    . as $all
    | ([ $all | to_entries[] | select(is_real_user(.value)) | .key ] | last // -1) as $last_user
    | $last_user >= 0 and
      ([ $all | to_entries[]
        | select(.key > $last_user and event_role(.value) == "assistant")
        | call_records(.value)[]
        | select(active_call(.)) ] | length) > 0
  ' "$transcript" >/dev/null 2>&1
}

if codex_hook_is_subagent_context "$input"; then
  subagent_change_summary="$(touched_repos_change_summary "$session_id" || true)"
  if [ -n "$subagent_change_summary" ]; then
    coordinator_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
    if ! codex_valid_session_id "$coordinator_session_id"; then
      coordinator_session_id=unavailable
    fi
    # The return route is the provider's normal worker completion channel. The
    # hook cannot force client presentation, but it can make the handoff ready
    # for the coordinator instead of trapping the worker in a repeated Stop.
    publish_worker_dirty_handoff "$coordinator_session_id" "$subagent_change_summary" || true
  fi
  json_continue
  exit 0
fi

repo="${cwd:-$PWD}"
side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)

if codex_side_stop_is_active_for_session "$side_stop" "$session_id"; then
  json_continue
  exit 0
fi

baseline="$proof_dir/baseline_head"
skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
eci_active="$root/$session_id/eci_active"
legacy_eci_active="$(codex_legacy_eci_markers_for_cwd "$cwd" "$session_id" 2>/dev/null | head -n1 || true)"
ate_active=$(codex_existing_state_file ate ate_active "$session_id" "$cwd" 2>/dev/null || true)
task_active=$(codex_existing_state_file active-task task_active "$session_id" "$cwd" 2>/dev/null || true)
activity_summary="$(activity_marker_summary "$session_id" "$cwd")"
change_summary="$(git_change_summary "$repo" "$baseline" || true)"
changed=false
[ -n "$change_summary" ] && changed=true
transcript_activity=false
if transcript_has_activity_since_last_user "$transcript_path"; then
  transcript_activity=true
fi
repo_is_git=false
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_is_git=true
fi

mkdir -p "$proof_dir"

if [ -n "$eci_active" ]; then
  marker_status=0
  if eci_marker_is_safe_regular "$eci_active"; then
    json_block_fast "$eci_active"
    exit 0
  else
    marker_status=$?
    if [ "$marker_status" -eq 2 ]; then
      json_block_fast ""
      exit 0
    fi
  fi
fi

if [ -n "$legacy_eci_active" ]; then
  marker_status=0
  if eci_marker_is_safe_regular "$legacy_eci_active"; then
    json_block_fast "$legacy_eci_active"
    exit 0
  else
    marker_status=$?
    if [ "$marker_status" -eq 2 ]; then
      json_block_fast ""
      exit 0
    fi
  fi
fi

if [ -n "$skip" ] && [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ -n "$ate_active" ] && [ -f "$ate_active" ]; then
  # An ATE phase is workflow ceremony, not a concrete current-session scope,
  # cross-session, or destructive target. It can guide normal work elsewhere,
  # but it must not hold this ordinary Stop callback or require an artifact,
  # role, delegation, or ledger action before it may return.
  json_continue
  exit 0
fi

# An inactive, marker-free session is outside ECI's dirty-worktree admission
# boundary. Active ECI and ATE paths have already returned above.
if [ "$changed" = "true" ] && [ "$stop_recursive_callback_unvalidated" != true ]; then
  json_continue
  exit 0
fi

# Early exit: if this session did no mutation work since the last user
# message and no persisted indicators exist, skip the stop gate regardless of
# pre-existing dirt from prior sessions.
if [ "$transcript_activity" != "true" ] &&
  [ ! -f "$proof" ] &&
  [ "$changed" != "true" ] &&
  [ -z "$task_active" ] &&
  [ -z "$activity_summary" ]; then
  json_continue
  exit 0
fi

reviewer_out=""
if reviewer_out=$(printf '%s' "$input" | "$HOOK_DIR/system-prompt-reviewer.sh"); then
  if [ -n "$reviewer_out" ] &&
    printf '%s' "$reviewer_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    # Reviewer output can inform the next current-diff review, but a stored
    # reviewer artifact is not an active marker and cannot own Stop.
    stop_historical_evidence_advisory=true
  fi
fi

if [ -f "$proof" ]; then
  if codex_markdown_section_has_body "$proof" "ECI completion certificate"; then
    if ! codex_markdown_section_has_body "$proof" "Stop checklist walkthrough" || ! codex_markdown_section_has_body "$proof" "Incomplete compliance"; then
      block_proof_validation "ECI completion proof must include non-empty Stop checklist walkthrough and Incomplete compliance sections."
    fi

    marker_error="$(codex_eci_terminal_verdict_error "ECI completion proof" "$proof")"
    if [ -n "$marker_error" ]; then
      block_proof_validation "$marker_error"
    fi
  elif ! grep -qiE 'fast.exit|fast exit' "$proof"; then
    missing=""
    grep -qi '^##[[:space:]]*Summary' "$proof" || missing="$missing Summary"
    grep -qi '^##[[:space:]]*Verification' "$proof" || missing="$missing Verification"
    grep -qi '^##[[:space:]]*Requirements' "$proof" || missing="$missing Requirements"
    grep -qi '^##[[:space:]]*Root Cause' "$proof" || missing="$missing Root-Cause"
    grep -qi '^##[[:space:]]*Claim Inventory' "$proof" || missing="$missing Claim-Inventory"
    grep -qi '^##[[:space:]]*Pre-Mortem' "$proof" || missing="$missing Pre-Mortem"
    grep -qi '^##[[:space:]]*Adversarial Critique' "$proof" || missing="$missing Adversarial-Critique"
    grep -qi '^##[[:space:]]*Rule-Compliance Self-Audit' "$proof" || missing="$missing Rule-Compliance-Self-Audit"
    grep -qi '^##[[:space:]]*Gaps' "$proof" || missing="$missing Gaps"

    if [ -n "$missing" ]; then
      block_proof_validation "Proof file is missing required sections:$missing."
    fi

    audit_section=$(awk '
      /^##[[:space:]]*Rule-Compliance Self-Audit/ { in_audit=1; next }
      in_audit && /^##[[:space:]]/ { in_audit=0 }
      in_audit { print }
    ' "$proof")
    audit_hashes=$(mktemp "$TMPDIR/codex-audit-hashes.XXXXXX")
    audit_errs=$(printf '%s\n' "$audit_section" | awk -v hashfile="$audit_hashes" '
      function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      function check_sources(raw, label,   body, n, i, item, nonempty, has_codex) {
        body = raw
        sub(/^[^:]*:[[:space:]]*/, "", body)
        n = split(body, parts, ",")
        nonempty = 0
        has_codex = 0
        for (i = 1; i <= n; i++) {
          item = trim(parts[i])
          if (item == "") {
            print label ": empty audit source"
          } else {
            nonempty++
          }
          if (item ~ /CODEX\.md/) has_codex = 1
        }
        if (nonempty < 3) print label ": need at least three non-empty sources"
        if (!has_codex) print label ": must include CODEX.md among the sources"
      }
      function finish_violation() {
        if (violation_count == 0) return
        if (!has_corr) print "violation #" violation_count ": no correction marker"
        if (blocker_seen && !blocker_input) print "violation #" violation_count ": blocker missing non-empty input"
        if (blocker_seen && !blocker_command) print "violation #" violation_count ": blocker missing non-empty command"
      }

      /^[[:space:]]*[Cc][Ll][Ee][Aa][Nn]-[Ss][Cc][Aa][Nn]:[[:space:]]*/ {
        clean_count++
        check_sources($0, "clean-scan")
        next
      }

      /^[[:space:]]*[-*]*[[:space:]]*[Vv]iolation:/ {
        finish_violation()
        violation_count++
        has_corr = 0
        blocker_seen = 0
        blocker_input = 0
        blocker_command = 0
        next
      }

      violation_count > 0 && /^[[:space:]]*commit:[[:space:]]*[0-9a-fA-F]{7,40}/ {
        has_corr = 1
        match($0, /[0-9a-fA-F]{7,40}/)
        print substr($0, RSTART, RLENGTH) > hashfile
        next
      }

      violation_count > 0 && /^[[:space:]]*```(edit|grep|restate)/ {
        has_corr = 1
        next
      }

      violation_count > 0 && /^[[:space:]]*blocker:[[:space:]]*$/ {
        has_corr = 1
        blocker_seen = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*input:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*input:[[:space:]]*/, "", value)
        if (trim(value) != "") blocker_input = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*command:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*command:[[:space:]]*/, "", value)
        value = trim(value)
        lower = tolower(value)
        if (value == "") {
          blocker_command = 0
        } else if (lower ~ /^(tbd|todo|later|fix later|figure out|placeholder|none|n\/a|\.\.\.|<.*>)$/) {
          print "violation #" violation_count ": blocker command is a placeholder"
        } else {
          blocker_command = 1
        }
        next
      }

      END {
        finish_violation()
        if (clean_count == 0 && violation_count == 0) print "empty audit: provide clean-scan: or Violation:"
        if (clean_count > 0 && violation_count > 0) print "mutual-exclusion: use clean-scan or Violation:, not both"
      }
    ')

    if [ -n "$audit_errs" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit grammar failure: $audit_errs"
    fi

    bad_commits=""
    if [ -s "$audit_hashes" ]; then
      while IFS= read -r audit_hash; do
        if [ "$repo_is_git" != "true" ] ||
          ! git -C "$repo" cat-file -e "${audit_hash}^{commit}" 2>/dev/null ||
          ! git -C "$repo" merge-base --is-ancestor "$audit_hash" HEAD 2>/dev/null; then
          bad_commits="$bad_commits $audit_hash"
        fi
      done <"$audit_hashes"
    fi
    if [ -n "$bad_commits" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit has unreachable audit commit(s):$bad_commits."
    fi

    audit_sha=$(printf '%s' "$audit_section" | sha256sum | awk '{print $1}')
    cur_head=""
    workdir_dirty=0
    if [ "$repo_is_git" = "true" ]; then
      cur_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
      if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
        workdir_dirty=1
      fi
    fi

    history_identity="$(repo_identity "$repo")"
    history_key="$(codex_hash_string "$history_identity")"
    history_dir="$root/history/$history_key"
    history_file="$history_dir/$session_id.log"
    mkdir -p "$history_dir"
    printf '%s\n' "$history_identity" >"$history_dir/repo_identity"
    if [ -f "$history_file" ]; then
      last_line=$(tail -n1 "$history_file")
      prev_sha=$(printf '%s' "$last_line" | cut -d'|' -f1)
      prev_head=$(printf '%s' "$last_line" | cut -d'|' -f2)

      if [ "$audit_sha" = "$prev_sha" ]; then
        if [ "$workdir_dirty" = "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: identical audit plus dirty tree."
        fi
        if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: HEAD advance from $prev_head to $cur_head with a byte-identical audit."
        fi

        rescan_ok=$(printf '%s\n' "$audit_section" | awk '
          function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
          }
          /^[[:space:]]*[Rr]escanned:[[:space:]]*/ {
            body = $0
            sub(/^[^:]*:[[:space:]]*/, "", body)
            n = split(body, parts, ",")
            nonempty = 0
            has_codex = 0
            empty = 0
            for (i = 1; i <= n; i++) {
              item = trim(parts[i])
              if (item == "") empty = 1
              else nonempty++
              if (item ~ /CODEX\.md/) has_codex = 1
            }
            if (nonempty >= 3 && has_codex && !empty) ok = 1
          }
          END { print ok ? 1 : 0 }
        ')
        if [ "$rescan_ok" != "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: missing/invalid rescanned: for byte-identical audit on unchanged repo."
        fi
      fi

      if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ] && [ -s "$audit_hashes" ]; then
        range_ok=0
        while IFS= read -r audit_hash; do
          if [ "$audit_hash" != "$prev_head" ] &&
            git -C "$repo" merge-base --is-ancestor "$prev_head" "$audit_hash" 2>/dev/null &&
            git -C "$repo" merge-base --is-ancestor "$audit_hash" "$cur_head" 2>/dev/null; then
            range_ok=1
            break
          fi
        done <"$audit_hashes"
        if [ "$range_ok" = "0" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: old-only commit range after HEAD movement."
        fi
      fi
    fi

    printf '%s|%s|%s\n' "$audit_sha" "$cur_head" "$(date -u +%s)" >"$history_file"
    rm -f "$audit_hashes"
  fi

  if [ "$teardown_complete" != true ] && { { [ -f "$proof_dir/eci_active" ] && [ ! -L "$proof_dir/eci_active" ]; } ||
    [ -e "$proof_dir/eci-required-critics.json" ] ||
    codex_markdown_section_has_body "$proof" "ECI completion certificate"; }; then
    review_gate_error=""
    if ! review_gate_error="$("$HOOK_DIR/eci-review-gate.sh" final "$session_id" 2>&1)"; then
      block_proof_validation "Required ECI critic manifest rejected at final-proof acceptance: $review_gate_error"
    fi
  fi

  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  rm -f "$proof" "$instructions" "$baseline"
  dirty_summary="$(git_dirty_summary "$repo" || true)"
  if [ -n "$dirty_summary" ]; then
    git_status_at_accept="$proof_dir/git-status-at-accept.txt"
    printf '%s\n' "$dirty_summary" >"$git_status_at_accept"
  fi
  # Historical proof acceptance is not a live completion boundary. Preserve
  # any local status note above, then let normal work or teardown continue.
  json_continue
  exit 0
fi

if [ "$stop_active" = "true" ]; then
  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  rm -f "$instructions" "$baseline"
  json_continue
  exit 0
fi

if [ "$changed" != "true" ]; then
  # A clean callback with post-user activity has no concrete accidental target
  # to protect. Checklists and workflow records remain optional guidance, not
  # a Stop admission requirement.
  json_continue
  exit 0
fi

head_summary="$(git_head_summary "$repo")"
[ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
dirty_summary="$(git_dirty_summary "$repo" || true)"
[ -n "$dirty_summary" ] || dirty_summary="clean"
secret_scan_rc=0
run_secret_scan "$repo" "$baseline" "$proof_dir" || secret_scan_rc=$?
case "$secret_scan_rc" in
  0) secret_scan_status="passed (gitleaks)" ;;
  1) secret_scan_status="advisory: redacted candidate reported by gitleaks" ;;
  *) secret_scan_status="advisory: gitleaks unavailable or incomplete" ;;
esac
{
  cat <<EOF
# Automated Stop Checks

Automated checks already run by stop-gate:
- Git changes since the session baseline: present.
- Dirty worktree: $dirty_summary
- HEAD: $head_summary
- Secret scan: $secret_scan_status
- Change summary:
EOF
  printf '%s\n' "$change_summary" | indent_text
  cat <<'EOF'

Do not rerun automated git checks unless investigating a reported failure.

EOF
  cat "$CODEX_PROVIDER_HOME/hooks/stop-verification.md"
} >"$instructions"

json_block "Automated stop checks found changed git state while ECI is inactive and no active marker is bound. This is dirty-worktree stop admission, not marker repair. If changes are task-owned, re-enter or keep ECI active, commit only scoped completed changes, then run env CODEX_SESSION_ID=$session_id \"\$HOME/.codex/bin/eci-active\" off <disengage-report.md> against final HEAD before retrying Stop. If changes are intentionally preserved, read the generated Stop checklist at $instructions and use it as the handoff; do not retry unchanged. skip-stop is only an intentional dirty handoff; it does not close ECI or make the worktree clean. Follow $instructions for remaining verification; invoke Stop only after the checklist is satisfied or the state changes."
