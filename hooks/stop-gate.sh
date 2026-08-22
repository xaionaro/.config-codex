#!/usr/bin/env bash
# Stop hook: require a checklist pass before ending.

set -euo pipefail

# This name is an internal per-process optimization only.  Never trust an
# inherited value: the canonical root is computed below before it is exported
# for the helper functions used by this callback.
unset CODEX_STOP_GATE_ROOT

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
codex_install_fail_open_trap stop-gate

input="$(< /dev/stdin)"
json_string_field() {
  local key="$1"
  local pattern="\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  if [[ "$input" =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Keep the hot-path admission parse in-process and scalar-only.  Session IDs
# are validated below; malformed/non-scalar input fails open without invoking
# a parser process.  Generic inactive-turn logic retains its existing jq use.
session_id="$(json_string_field session_id)"
transcript_path="$(json_string_field transcript_path)"
stop_active="false"
if [[ "$input" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
  stop_active="${BASH_REMATCH[1]}"
fi
cwd="$(json_string_field cwd)"
stop_identity_malformed=false
if [ -z "$session_id" ] || ! [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] ||
  [ -z "$cwd" ] ||
  [[ "$cwd" == *[![:print:]]* ]] ||
  [[ ! "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\" ]] ||
  [[ ! "$input" =~ \"cwd\"[[:space:]]*:[[:space:]]*\" ]]; then
  stop_identity_malformed=true
fi
[ -z "$cwd" ] && cwd="$PWD"
if [ "$cwd" = "$PWD" ]; then
  # Hook payloads normally carry the process cwd.  `pwd -P` is a Bash builtin
  # and avoids spawning the helper's cd/subshell on every active callback;
  # differing payload paths still take the full physical canonicalization.
  canonical_stop_cwd="$(pwd -P)"
else
  canonical_stop_cwd="$(codex_canonical_cwd "$cwd")"
fi
root="$(codex_proof_root)"
export CODEX_STOP_GATE_ROOT="$root"
proof_dir="$root/$session_id"

# Active-stop discovery is intentionally bounded before any state parsing.  A
# valid typed session gets a direct lookup; ambiguity checks inspect only the
# root's immediate session directories.  Do not recurse through arbitrary
# child trees: those trees are unrelated proof state and are not part of the
# Stop marker namespace.
eci_stop_max_markers=64
eci_stop_max_marker_bytes="$codex_eci_marker_max_bytes"
# The fallback ambiguity scan is deliberately finite.  It only inspects
# immediate session marker paths; it never expands an unbounded shell glob or
# walks arbitrary descendants.  A typed direct-session lookup remains the
# normal O(1) marker probe, while this cap preserves duplicate-owner checks
# when ambiguity must be examined.
eci_stop_max_root_entries=64

stop_direct_marker_path() {
  local candidate
  codex_valid_session_id "$session_id" || return 1
  candidate="$root/$session_id/eci_active"
  [ -e "$candidate" ] || [ -L "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

stop_marker_scan() {
  local marker marker_count=0 root_entry_count=0

  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  # Do not use "$root"/* here: pathname expansion happens before the shell
  # can enforce a cap and can allocate an attacker-sized array.  Count
  # immediate proof-root entries before checking marker types; an overflow is
  # unsafe ambiguity state, while a valid typed session with no direct marker
  # skips this fallback entirely.
  while IFS= read -r -d '' marker; do
    root_entry_count=$((root_entry_count + 1))
    if [ "$root_entry_count" -gt "$eci_stop_max_root_entries" ]; then
      printf '%s\0' '__ECI_STOP_ROOT_ENTRY_OVERFLOW__'
      return 0
    fi
    [ -d "$marker" ] && [ ! -L "$marker" ] || continue
    marker="${marker%/}/eci_active"
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    marker_count=$((marker_count + 1))
    if [ "$marker_count" -gt "$eci_stop_max_markers" ]; then
      # A sentinel avoids an unbounded output/status channel in process
      # substitutions while making overflow an unsafe state for every caller.
      printf '%s\0' '__ECI_STOP_MARKER_OVERFLOW__'
      return 0
    fi
    printf '%s\0' "$marker"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
}

stop_marker_cache=()
stop_marker_cache_loaded=false
stop_marker_cache_status=0
stop_invalid_marker=""
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
  if stop_direct_marker_path >/dev/null 2>&1; then
    stop_root_requires_ambiguity_scan && return 0
    return 1
  fi
  [ "$stop_identity_malformed" = true ] && return 0
  codex_valid_session_id "$session_id" || return 0
  return 1
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
      __ECI_STOP_MARKER_OVERFLOW__|__ECI_STOP_ROOT_ENTRY_OVERFLOW__)
        stop_marker_cache_status=2
        return 2
        ;;
      *) stop_marker_cache+=("$marker") ;;
    esac
  done < <(stop_marker_scan || true)
  return 0
}

stop_marker_has_any() {
  if stop_direct_marker_path >/dev/null 2>&1; then
    return 0
  fi
  stop_marker_cache_load || [ "$stop_marker_cache_status" -eq 2 ] || return 1
  [ "${#stop_marker_cache[@]}" -gt 0 ]
}

# Duplicate-key and scalar-type validation is deliberately deferred until an
# active marker is present.  The ordinary inactive Stop path stays a bounded
# in-process parse; an active ECI callback gets one strict JSON check so a
# duplicate identity cannot make the regex parser select a different owner.
stop_identity_has_marker() {
  stop_marker_has_any
}

stop_identity_json_is_strict() {
  python3 - "$input" <<'PY'
import json
import sys

raw = sys.argv[1]

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

try:
    value = json.loads(raw, object_pairs_hook=reject_duplicates)
except (TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)

if type(value) is not dict:
    raise SystemExit(1)
for key in ("session_id", "cwd", "transcript_path"):
    if key in value and type(value[key]) is not str:
        raise SystemExit(1)
if "stop_hook_active" in value and type(value["stop_hook_active"]) is not bool:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

stop_identity_has_duplicate_keys() {
  # Scan JSON strings with Bash builtins only.  A simple key is checked for a
  # duplicate at any nesting depth; unusual escapes/characters return 2 so the
  # strict Python validator handles those rare inputs.  This keeps ordinary
  # active Stop callbacks free of a Python process while retaining a bounded
  # fail-closed fallback for malformed JSON.
  local raw="$input" length="${#input}" i=0 c key next
  local in_string=false escaped=false closed=false token=""
  local -A seen=()
  while [ "$i" -lt "$length" ]; do
    c="${raw:i:1}"
    if [ "$in_string" = true ]; then
      if [ "$escaped" = true ]; then
        case "$c" in
          $'\n'|$'\r') return 2 ;;
        esac
        token+="\\$c"
        escaped=false
      elif [ "$c" = '\\' ]; then
        escaped=true
      elif [ "$c" = '"' ]; then
        in_string=false
        closed=true
      else
        token+="$c"
      fi
    elif [ "$c" = '"' ]; then
      in_string=true
      escaped=false
      closed=false
      token=""
    elif [ "$closed" = true ] && [[ "$c" != [[:space:]] ]]; then
      if [ "$c" = ':' ]; then
        [[ "$token" =~ ^[A-Za-z0-9_./-]+$ ]] || return 2
        if [[ -v "seen[$token]" ]]; then
          return 1
        fi
        seen["$token"]=1
      fi
      closed=false
    fi
    i=$((i + 1))
  done
  [ "$in_string" = false ] && [ "$escaped" = false ] || return 2
  return 0
}

if stop_identity_has_marker; then
  # Reject non-object payloads before invoking the strict fallback.  The
  # replacement is intentionally local and bounded; it is not a JSON parser.
  identity_compact="${input//[$' \t\r\n']/}"
  case "$identity_compact" in
    \{*\}) ;;
    *) stop_identity_malformed=true ;;
  esac
  duplicate_status=0
  stop_identity_has_duplicate_keys || duplicate_status=$?
  case "$duplicate_status" in
    1) stop_identity_malformed=true ;;
    2) if ! stop_identity_json_is_strict; then stop_identity_malformed=true; fi ;;
  esac
  # These fields are part of the hook identity.  If present, they must be
  # scalar strings/bool; the fast regex parser otherwise intentionally ignores
  # their value shape.
  if [[ "$input" =~ \"transcript_path\"[[:space:]]*:[[:space:]]* ]] &&
    [[ ! "$input" =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\" ]]; then
    stop_identity_malformed=true
  fi
  if [[ "$input" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]* ]] &&
    [[ ! "$input" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*(true|false)([[:space:]]*[,}]) ]]; then
    stop_identity_malformed=true
  fi
fi

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
      remediation="do not retry or poll Stop while the marker and normalized control state are unchanged; take one distinct recovery action or complete coordinator teardown, then wait for new external state"
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

# Active ECI is a main/orchestrator concern. Keep the ordinary authoritative
# fast path to marker probes; only a direct-session validated wait state reads
# bounded state/report data, and that exceptional path never mutates it.
json_block_fast() {
  local marker="$1" reason marker_code
  [ -n "$marker" ] || marker="$stop_invalid_marker"
  if [ -z "$marker" ] && [ "${#stop_marker_cache[@]}" -gt 0 ]; then
    local candidate candidate_code
    for candidate in "${stop_marker_cache[@]}"; do
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
  marker_code="$(codex_eci_marker_failure_code "$marker" "${canonical_stop_cwd:-$cwd}" "${session_id:-}" 2>/dev/null || true)"
  [ -n "$marker_code" ] || marker_code="ECI_MARKER_VALIDATION_FAILED"
  case "$marker_code" in
    ECI_MARKER_VALID)
      marker_code="ECI_STOP_ACTIVE_ECI"
      reason="[$marker_code] Stop is denied because the resolved ECI marker is valid and bound to this session/cwd: $marker; no marker repair is indicated. This denial is control metadata, not a new user request: do not emit another final/status/question, do not retry or poll Stop, and do not repeat this report. Continue the current ECI task with one distinct recovery action; retry Stop only after coordinator teardown is complete."
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
  if marker="$(stop_direct_marker_path 2>/dev/null || true)" &&
    [ -n "$marker" ] && ! stop_root_requires_ambiguity_scan; then
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

marker_bound_status=0
eci_stop_marker_set_is_bounded || marker_bound_status=$?
if [ "$marker_bound_status" -eq 2 ]; then
  json_block_fast ""
  exit 0
fi

json_block_with_loop_state() {
  local reason="$1"
  local loop_state loop_tmp loop_code loop_cwd loop_count loop_emitted
  local loop_line loop_key loop_version loop_state_code loop_state_session loop_state_cwd
  local loop_state_count loop_state_emitted loop_line_count loop_state_valid
  local loop_already_emitted

  # Keep the normalized loop-state fields initialized even when this is the
  # first denial for a session.  `set -u` must not turn an absent state file
  # into an opaque hook failure.
  loop_state_code=""
  loop_state_session=""
  loop_state_cwd=""
  loop_state_count=0
  loop_state_emitted=false
  loop_line_count=0
  loop_state_valid=true
  loop_already_emitted=false

  if [ -n "${proof_dir:-}" ]; then
    if ! codex_session_dir_is_safe "${root:-}" "${session_id:-}"; then
      local unsafe_reason
      unsafe_reason="[ECI_STOP_SESSION_DIR_UNSAFE] Stop gate refused to write stop-loop bookkeeping because proof-root/session is unsafe or out of scope: root=${root:-<missing>}, session=${session_id:-<missing>}, path=${proof_dir}. No stop_timestamps file was written."
      unsafe_reason="$(stop_diagnostic "$unsafe_reason" "${marker:-<none>}" "${instructions:-<none>}")"
      jq -n --arg reason "$unsafe_reason" '{decision: "block", reason: $reason}'
      return 0
    fi
    mkdir -p "$proof_dir"
    loop_state="$proof_dir/stop_loop_state"
    loop_code="$(eci_diagnostic_code_for_reason "$reason")"
    loop_cwd="${canonical_stop_cwd:-$(codex_canonical_cwd "${cwd:-$PWD}")}"
    loop_count=0
    loop_emitted=false
    loop_state_valid=true
    if [ -e "$loop_state" ] || [ -L "$loop_state" ]; then
      if ! codex_state_file_owner_is_valid "$loop_state"; then
        loop_state_valid=false
      else
        loop_state_code=""
        loop_state_session=""
        loop_state_cwd=""
        loop_state_count=""
        loop_state_emitted=""
        loop_version=""
        loop_line_count=0
        while IFS= read -r loop_line || [ -n "$loop_line" ]; do
          loop_line_count=$((loop_line_count + 1))
          case "$loop_line" in
            'version: 1') [ -z "$loop_version" ] || loop_state_valid=false; loop_version=1 ;;
            'code: '*) [ -z "$loop_state_code" ] || loop_state_valid=false; loop_state_code="${loop_line#code: }" ;;
            'session_id: '*) [ -z "$loop_state_session" ] || loop_state_valid=false; loop_state_session="${loop_line#session_id: }" ;;
            'cwd: '*) [ -z "$loop_state_cwd" ] || loop_state_valid=false; loop_state_cwd="${loop_line#cwd: }" ;;
            'count: '*) [ -z "$loop_state_count" ] || loop_state_valid=false; loop_state_count="${loop_line#count: }" ;;
            'loop_emitted: true') [ -z "$loop_state_emitted" ] || loop_state_valid=false; loop_state_emitted=true ;;
            'loop_emitted: false') [ -z "$loop_state_emitted" ] || loop_state_valid=false; loop_state_emitted=false ;;
            *) loop_state_valid=false ;;
          esac
          [ "$loop_line_count" -le 6 ] || loop_state_valid=false
        done <"$loop_state"
        [[ "$loop_version" = 1 && "$loop_line_count" -eq 6 ]] || loop_state_valid=false
        [[ "$loop_state_code" =~ ^[A-Z0-9_]{1,128}$ ]] || loop_state_valid=false
        codex_valid_session_id "$loop_state_session" || loop_state_valid=false
        [[ "$loop_state_count" =~ ^[1-9][0-9]{0,5}$ ]] || loop_state_valid=false
        [ -n "$loop_state_cwd" ] || loop_state_valid=false
      fi
      if [ "$loop_state_valid" != true ]; then
        local loop_state_reason
        loop_state_reason="[ECI_STOP_LOOP_STATE_UNSAFE] Stop gate refused to consume malformed or unsafe normalized loop state at $loop_state; expected exactly version/code/session_id/cwd/count/loop_emitted fields with bounded values."
        loop_state_reason="$(stop_diagnostic "$loop_state_reason" "${marker:-<none>}" "${instructions:-<none>}")"
        jq -n --arg reason "$loop_state_reason" '{decision: "block", reason: $reason}'
        return 0
      fi
    fi
    if [ "$loop_state_code" = "$loop_code" ] &&
      [ "$loop_state_session" = "${session_id:-}" ] &&
      [ "$loop_state_cwd" = "$loop_cwd" ]; then
      loop_count=$((loop_state_count + 1))
      loop_emitted="${loop_state_emitted:-false}"
    else
      loop_count=1
      loop_emitted=false
    fi
    loop_already_emitted="$loop_emitted"
    if [ "$loop_count" -ge 5 ] && [ "$loop_emitted" != true ]; then
      loop_emitted=true
    fi
    loop_tmp="$loop_state.tmp.$$"
    [ ! -e "$loop_tmp" ] && [ ! -L "$loop_tmp" ] || {
      local loop_tmp_reason
      loop_tmp_reason="[ECI_STOP_LOOP_STATE_UNSAFE] Stop gate cannot publish normalized loop state because its temporary path already exists: $loop_tmp."
      loop_tmp_reason="$(stop_diagnostic "$loop_tmp_reason" "${marker:-<none>}" "${instructions:-<none>}")"
      jq -n --arg reason "$loop_tmp_reason" '{decision: "block", reason: $reason}'
      return 0
    }
    {
      printf 'version: 1\ncode: %s\nsession_id: %s\ncwd: %s\ncount: %s\nloop_emitted: %s\n' \
        "$loop_code" "${session_id:-}" "$loop_cwd" "$loop_count" "$loop_emitted"
    } >"$loop_tmp" && mv -- "$loop_tmp" "$loop_state"

    if [ "$loop_count" -ge 5 ] && [ "$loop_already_emitted" = true ]; then
      jq -n '{continue: true}'
      return 0
    fi
    if [ "$loop_count" -ge 5 ]; then
      # A prior stop denial may have told the caller to "stop again".  Once
      # the loop diagnostic is emitted, retain the concrete denial detail but
      # remove that stale instruction so this message cannot restart the loop.
      case "$reason" in
        *', then stop again.') reason="${reason%, then stop again.}" ;;
        *'then stop again.') reason="${reason%then stop again.}" ;;
      esac
      reason="$reason LOOP DETECTED (same diagnostic code/session/cwd repeated $loop_count times). Treat this as unchanged control metadata: do not emit another final/status/question, retry, poll, or stop attempt. Execute at most one distinct recovery action or record one concrete user-owned blocker, then wait for new external state."
    fi
  fi

  reason="$(stop_diagnostic "$reason" "${marker:-<none>}" "${instructions:-<none>}")"
  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# Keep the public denial helper stable while sharing its bounded convergence
# state with the active-marker fast path.
json_block() {
  json_block_with_loop_state "$1"
}

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

eci_wait_state_allows() {
  local marker="$1"
  local state="${marker%/*}/eci_wait"
  local report="${marker%/*}/eci_user_owned_wait.md"
  local state_bytes report_bytes report_sha256
  local state_blocker_id state_fingerprint state_unblock_kind state_unblock state_report_sha256
  local report_blocker_id report_fingerprint report_unblock_kind report_unblock
  local -a lines=() report_lines=()

  # The ordinary active path does only this existence/type probe.  A wait
  # state is considered only for the direct session marker, never a parent or
  # subagent marker.  Validated state remains in place; this function never
  # consumes or deletes it.
  [ -e "$state" ] || [ -L "$state" ] || return 1
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  state_bytes="$(wc -c <"$state" 2>/dev/null || true)"
  case "$state_bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$state_bytes" -le 8192 ] || return 1
  [ "$(tail -c 1 -- "$state" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  mapfile -t lines <"$state" || return 1
  local terminated_lines=0
  while IFS= read -r _; do
    terminated_lines=$((terminated_lines + 1))
  done <"$state"
  [ "$terminated_lines" -eq 9 ] || return 1
  [ "${#lines[@]}" -eq 9 ] || return 1
  [ "${lines[0]}" = "state: user-owned-wait" ] || return 1
  [[ "${lines[1]}" == blocker_id:\ * ]] || return 1
  [[ "${lines[2]}" == state_fingerprint:\ * ]] || return 1
  [[ "${lines[3]}" = "owner: user" ]] || return 1
  [[ "${lines[4]}" = "brp_result: exhausted-no-feasible-internal-path" ]] || return 1
  [[ "${lines[5]}" = "user_owned_input: unobtainable" ]] || return 1
  [[ "${lines[6]}" == unblock_kind:\ * ]] || return 1
  [[ "${lines[7]}" == unblock:\ * ]] || return 1
  [[ "${lines[8]}" == report_sha256:\ * ]] || return 1
  state_blocker_id="${lines[1]#blocker_id: }"
  state_fingerprint="${lines[2]#state_fingerprint: }"
  state_unblock_kind="${lines[6]#unblock_kind: }"
  state_unblock="${lines[7]#unblock: }"
  state_report_sha256="${lines[8]#report_sha256: }"
  [[ "$state_blocker_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$state_fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
  case "$state_unblock_kind" in
    input|resource|decision) ;;
    *) return 1 ;;
  esac
  [ -n "$state_unblock" ] || return 1
  [[ "$state_unblock" != *[[:cntrl:]]* ]] || return 1
  [[ "$state_report_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  report_bytes="$(wc -c <"$report" 2>/dev/null || true)"
  case "$report_bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$report_bytes" -le 8192 ] || return 1
  [ "$(tail -c 1 -- "$report" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  mapfile -t report_lines <"$report" || return 1
  [ "${#report_lines[@]}" -eq 9 ] || return 1
  [ "${report_lines[0]}" = "# ECI User-Owned Wait" ] || return 1
  [ "${report_lines[1]}" = "state: user-owned-wait" ] || return 1
  [[ "${report_lines[2]}" == blocker_id:\ * ]] || return 1
  [[ "${report_lines[3]}" == state_fingerprint:\ * ]] || return 1
  [[ "${report_lines[4]}" = "owner: user" ]] || return 1
  [[ "${report_lines[5]}" = "brp_result: exhausted-no-feasible-internal-path" ]] || return 1
  [[ "${report_lines[6]}" = "user_owned_input: unobtainable" ]] || return 1
  [[ "${report_lines[7]}" == unblock_kind:\ * ]] || return 1
  [[ "${report_lines[8]}" == unblock:\ * ]] || return 1
  report_blocker_id="${report_lines[2]#blocker_id: }"
  report_fingerprint="${report_lines[3]#state_fingerprint: }"
  report_unblock_kind="${report_lines[7]#unblock_kind: }"
  report_unblock="${report_lines[8]#unblock: }"
  [[ "$report_blocker_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$report_fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
  case "$report_unblock_kind" in
    input|resource|decision) ;;
    *) return 1 ;;
  esac
  [ -n "$report_unblock" ] || return 1
  [[ "$report_unblock" != *[[:cntrl:]]* ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  report_sha256="$(sha256sum -- "$report" 2>/dev/null | awk '{print $1}')"
  [[ "$report_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$state_blocker_id" = "$report_blocker_id" ] || return 1
  [ "$state_fingerprint" = "$report_fingerprint" ] || return 1
  [ "$state_unblock_kind" = "$report_unblock_kind" ] || return 1
  [ "$state_unblock" = "$report_unblock" ] || return 1
  [ "$state_report_sha256" = "$report_sha256" ] || return 1
  printf '%s\n' '{"continue":true}'
}

stop_direct_marker_is_valid_fast() {
  local marker="$1" expected_cwd="$2"
  local marker_dir marker_name marker_cwd
  local -a lines=()

  case "$marker" in
    "$root/$session_id/eci_active") ;;
    *) return 1 ;;
  esac
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
  [ -n "$marker_cwd" ] && [ "$(codex_canonical_cwd "$marker_cwd")" = "$expected_cwd" ] || return 1
  marker_dir="${marker%/*}"
  marker_name="${marker_dir##*/}"
  [ "$marker_name" = "$session_id" ]
}

active_eci_marker_for_stop() {
  local marker side_stop parent_session_id is_subagent_context=false marker_status
  local transcript_owner="" subagent_metadata="" malformed_marker direct_marker=""
  local -a cwd_markers=()

  # A malformed typed hook identity cannot silently enter generic stop logic
  # while any regular ECI marker exists.  This scan is only a bounded proof-root
  # glob; it does not parse transcripts, ledgers, or recovery state.
  if [ "$stop_identity_malformed" = true ]; then
    stop_marker_has_any && return 2
    return 1
  fi

  # A typed empty-transcript callback with no direct marker is the common
  # inactive case.  Avoid canonical-cwd/hash work and any root enumeration;
  # only inspect the fixed side-stop namespace when it exists so parent/side
  # ownership remains authoritative.  This is a bounded O(1) fast path.
  if codex_valid_session_id "$session_id" && [ -z "$transcript_path" ] &&
    ! stop_direct_marker_path >/dev/null 2>&1; then
    if [ -e "$root/side-stop" ] || [ -L "$root/side-stop" ]; then
      [ -d "$root/side-stop" ] && [ ! -L "$root/side-stop" ] || return 2
      side_stop="$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)"
      parent_session_id="$(codex_state_value "$side_stop" parent_session_id || true)"
      if codex_valid_session_id "$parent_session_id"; then
        marker="$root/$parent_session_id/eci_active"
        marker_status=0
        if eci_marker_is_safe_regular "$marker"; then
          printf '%s\n' "$marker"
          return 0
        else
          marker_status=$?
          [ "$marker_status" -eq 2 ] && return 2
        fi
      fi
    fi
    return 1
  fi

  # Resolve the complete validated marker set before selecting an owner.  A
  # duplicate active owner is unsafe control state; do not let a direct
  # marker return before that ambiguity is observed.  The scan is restricted
  # to immediate session marker paths and is already count/size bounded above.
  # Use the same finite root scan as the marker-only preflight.  The shared
  # discovery helper historically used an unbounded glob; Stop must not call
  # it on an active callback because arbitrary proof-root entries are user
  # controlled.  Preserve its strict malformed-marker behavior locally.
  # Bind every active callback to the physical cwd once.  Conditional
  # canonicalization let an ancestor symlink create a logical/physical
  # mismatch and made duplicate-owner checks depend on the caller's PWD.
  direct_marker="$(stop_direct_marker_path 2>/dev/null || true)"
  stop_marker_cache_load || return 2
  for marker in "${stop_marker_cache[@]}"; do
    if [ -n "$direct_marker" ] && [ "$marker" = "$direct_marker" ]; then
      # Validate the direct marker once with its cwd binding and reuse it.
      codex_eci_marker_is_valid_for_cwd "$marker" "$canonical_stop_cwd" || return 2
      cwd_markers+=("$marker")
    elif codex_eci_marker_path_owner_is_valid "$marker"; then
      if codex_eci_marker_is_valid_for_cwd "$marker" "$canonical_stop_cwd"; then
        cwd_markers+=("$marker")
      fi
    else
      marker_dir="${marker%/*}"
      marker_name="${marker_dir##*/}"
      marker_owner="$(codex_state_value "$marker" session_id || true)"
      if [ -L "$marker" ] || [ ! -f "$marker" ] ||
        [ ! -d "$marker_dir" ] || [ -L "$marker_dir" ] ||
        { [ -n "$marker_owner" ] && [ "$marker_owner" != "$marker_name" ]; }; then
        return 2
      fi
    fi
  done
  [ "${#cwd_markers[@]}" -le 1 ] || return 2

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
        printf '%s\n' "$marker"
        return 0
      fi
      marker_status=0
      if eci_marker_is_safe_regular "$marker"; then
        printf '%s\n' "$marker"
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
        # The parent session owns the stop decision, but an unsafe own marker
        # must still fail closed before the generic branch can write state.
        marker_status=0
        if eci_marker_is_safe_regular "$marker"; then
          return 1
        else
          marker_status=$?
          [ "$marker_status" -eq 2 ] && return 2
          return 1
        fi
      fi
    fi

    marker_status=0
    if eci_marker_is_safe_regular "$marker"; then
      printf '%s\n' "$marker"
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
        printf '%s\n' "$marker"
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

  marker="$(codex_legacy_eci_markers_for_cwd "$cwd" 2>/dev/null | head -n1 || true)"
  [ -n "$marker" ] || return 1
  marker_status=0
  if eci_marker_is_safe_regular "$marker"; then
    printf '%s\n' "$marker"
    return 0
  fi
  marker_status=$?
  [ "$marker_status" -eq 2 ] && return 2
  return 1
}

block_if_eci_active_for_stop() {
  local marker marker_status=0

  if marker="$(active_eci_marker_for_stop)"; then
    [ -n "$marker" ] || return 1
    if [ "$marker" = "$root/$session_id/eci_active" ] &&
      eci_wait_state_allows "$marker"; then
      return 0
    fi
    json_block_fast "$marker"
    return 0
  else
    marker_status=$?
    # An existing symlink/non-regular ECI marker is unsafe control state.
    # Block without exposing or repairing it, and before generic bookkeeping.
    if [ "$marker_status" -eq 2 ]; then
      stop_invalid_marker=""
      for candidate in "${stop_marker_cache[@]}"; do
        candidate_code="$(codex_eci_marker_failure_code "$candidate" "${canonical_stop_cwd:-$cwd}" "${session_id:-}" 2>/dev/null || true)"
        if [ -n "$candidate_code" ] && [ "$candidate_code" != ECI_MARKER_VALID ]; then
          stop_invalid_marker="$candidate"
          break
        fi
      done
      json_block_fast ""
      return 0
    fi
    return 1
  fi
}

proof="$proof_dir/proof.md"
instructions="$proof_dir/instructions.md"

proof_recovery_text() {
  printf ' Legacy proof files are optional. Update or remove %s using %s; if that file is missing, read %s.' \
    "$proof" "$instructions" "$HOME/.codex/hooks/stop-checklist.md"
}

block_proof_validation() {
  json_block "$1$(proof_recovery_text)"
  exit 0
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
if [ -e "$teardown_receipt" ] || [ -L "$teardown_receipt" ]; then
  codex_eci_teardown_receipt_is_valid "$teardown_receipt" "$session_id" "$proof_dir/eci-required-critics.json" ||
    block_proof_validation "ECI teardown receipt is malformed, stale, or unbound; retain the terminal evidence and repair it before stopping."
  teardown_complete=true
fi

if [ -z "$transcript_path" ]; then
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

format_gitleaks_findings() {
  local report="$1"

  jq -r '
    .[] |
    "\(.File // "<unknown>"):\((.StartLine // "?") | tostring) \(.RuleID // "unknown") \(.Description // "possible secret")"
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
    {
      printf '%s\n' "gitleaks failed for:$errors"
      [ -s "${worktree_report}.err" ] && cat "${worktree_report}.err"
      [ -s "${commit_report}.err" ] && cat "${commit_report}.err"
    } >"$findings"
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
  # A worker-supplied role label is not coordinator evidence.  In particular,
  # CODEX_ROLE=lead/coordinator can be forged by a child process and must not
  # bypass the worker dirty-worktree handoff.  The top-level coordinator does
  # not enter this transcript-backed subagent branch; any future exception
  # must carry an independently verified coordinator receipt, not a string
  # from the worker environment.

  reminder="$proof_dir/subagent-commit-reminder.md"
  skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
  if [ -n "$skip" ]; then
    rm -f "$reminder" 2>/dev/null || true
    json_continue
    exit 0
  fi

  subagent_change_summary="$(touched_repos_change_summary "$session_id" || true)"
  if [ -n "$subagent_change_summary" ]; then
    mkdir -p "$proof_dir"
    {
      cat <<EOF
# Subagent Commit Reminder

This subagent has dirty files in repos it modified.
Commit only owned completed dirty paths modified by this subagent. Do not commit unrelated dirty files.
If committing is unsafe, use the blocker-resolution-protocol skill for real blockers before reporting the blocker and affected paths to the orchestrator.

Bypass only when handoff with dirty work is intentional:
  CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on

Changed repos:
EOF
      printf '%s\n' "$subagent_change_summary" | indent_text
    } >"$reminder"
    json_block "This subagent has dirty files it modified. Read $reminder; commit only owned completed dirty paths, report the blocker after blocker-resolution-protocol, or bypass intentional dirty handoff with CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on; return control to the coordinator for one reviewed retry."
    exit 0
  fi
  rm -f "$reminder" 2>/dev/null || true
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
legacy_eci_active="$(codex_legacy_eci_markers_for_cwd "$cwd" 2>/dev/null | head -n1 || true)"
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
  ate_phase=$(codex_state_value "$ate_active" phase || true)
  case "$ate_phase" in
    awaiting_user|closed) ;;
    *)
      codex_note_state_session_id "$ate_active" "$session_id" || true
      json_block "ATE is active for this session. Continue the agent team task, update the session project-understanding ledger, use blocker-resolution-protocol before reporting a real blocker, or close ATE before stopping."
      exit 0
      ;;
  esac
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
    printf '%s\n' "$reviewer_out"
    exit 0
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
    audit_hashes=$(mktemp "${TMPDIR:-/tmp}/codex-audit-hashes.XXXXXX")
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
    json_block "Verification proof accepted (legacy path), but git state is still dirty. Read $git_status_at_accept, relay the relevant result to the user, commit owned completed changes or state unrelated blockers, then stop."
  else
    json_block "Verification proof accepted (legacy path). Relay the relevant result to the user, then stop."
  fi
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
  head_summary="$(git_head_summary "$repo")"
  [ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
  activity_display="${activity_summary# }"
  [ -n "$activity_display" ] || activity_display="none"
  cat >"$instructions" <<EOF
# Stop Checklist Review

Automated checks already run by stop-gate:
- Git state: clean. No changed git state was detected.
- HEAD: $head_summary
- Activity markers: $activity_display

Do not rerun automated git checks unless investigating a reported failure.

Manual checks remaining:
1. Verify the applicable non-automated stop-checklist items.
2. If ECI or ATE was used, verify the session project-understanding ledger was updated.
3. If any item failed, fix it before stopping.
EOF

  json_block "Automated stop checks passed. Follow $instructions for remaining manual checks; invoke Stop only after those checks pass."
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
  1)
    json_block "Automated secret scan found possible secrets. Read $proof_dir/gitleaks-findings.txt, remove or explicitly remediate them before invoking Stop."
    exit 0
    ;;
  *)
    json_block "Automated secret scan could not complete. Read $proof_dir/gitleaks-findings.txt and fix the scanner failure before invoking Stop."
    exit 0
    ;;
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
  cat "$HOME/.codex/hooks/stop-verification.md"
} >"$instructions"

json_block "Automated stop checks found changed git state. Follow $instructions for remaining verification; invoke Stop only after the verification passes."
