#!/usr/bin/env bash
# Shared state helpers for Codex proof-adjacent hooks.

codex_configured_proof_root() {
  printf '%s\n' "${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
}

codex_proof_root_cache_configured=""
codex_proof_root_cache_value=""

codex_proof_root() {
  local configured canonical
  # stop-gate exports its already validated canonical root for the lifetime
  # of one callback.  This is deliberately process-local: it avoids repeated
  # cd/pwd command substitutions on the active hot path without creating a
  # persistent cache or trusting caller-provided state (stop-gate clears the
  # variable before computing the root).
  if [ -n "${CODEX_STOP_GATE_ROOT:-}" ]; then
    printf '%s\n' "$CODEX_STOP_GATE_ROOT"
    return 0
  fi
  configured="$(codex_configured_proof_root)"
  if [ "$configured" = "$codex_proof_root_cache_configured" ] &&
    [ -n "$codex_proof_root_cache_value" ]; then
    printf '%s\n' "$codex_proof_root_cache_value"
    return 0
  fi
  if [ -d "$configured" ] && [ ! -L "$configured" ]; then
    # pwd -P follows ancestor symlinks without spawning an external realpath
    # process; the final configured root component is checked separately by
    # codex_proof_root_is_safe before it becomes authoritative.
    canonical="$(cd -- "$configured" 2>/dev/null && pwd -P || true)"
    codex_proof_root_cache_value="${canonical:-$configured}"
  elif command -v realpath >/dev/null 2>&1; then
    codex_proof_root_cache_value="$(realpath -m -- "$configured" 2>/dev/null || printf '%s' "$configured")"
  else
    codex_proof_root_cache_value="$configured"
  fi
  codex_proof_root_cache_configured="$configured"
  printf '%s\n' "$codex_proof_root_cache_value"
}

codex_valid_session_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Session marker directories have historically appeared in both bare and
# session_-prefixed forms.  When a caller supplies an expected session, treat
# those forms as aliases for discovery, but keep an empty expectation as the
# intentionally broad "any owner" query used by legacy callers.
codex_eci_marker_path_session_matches() {
  local marker="$1" expected_session="${2:-}" marker_name expected_name

  [ -n "$expected_session" ] || return 0
  marker_name="${marker%/*}"
  marker_name="${marker_name##*/}"
  expected_name="$expected_session"
  case "$marker_name" in
    session_?*) marker_name="${marker_name#session_}" ;;
  esac
  case "$expected_name" in
    session_?*) expected_name="${expected_name#session_}" ;;
  esac
  [ -n "$marker_name" ] && [ -n "$expected_name" ] &&
    [ "$marker_name" = "$expected_name" ]
}

# Active markers are deliberately tiny control records.  Keep this limit in
# the shared writer/reader helpers so creation and the Stop fast path enforce
# the same finite bound without scanning recovery state.
codex_eci_marker_max_bytes=4096
codex_eci_marker_scan_max_candidates=64
codex_eci_marker_scan_overflow_token="__CODEX_ECI_MARKER_SCAN_OVERFLOW__"
codex_eci_marker_scan_unsafe_token="__CODEX_ECI_MARKER_SCAN_UNSAFE__"

codex_eci_marker_file_is_bounded() {
  local marker="$1" prefix="" old_lc="" had_lc=0 within=false
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  # Read one byte beyond the finite cap with a Bash builtin so the active
  # Stop path does not spawn wc for every callback.  The metadata validator
  # still performs the complete bounded line/schema check afterwards.
  if [ "${LC_ALL+x}" = x ]; then
    had_lc=1
    old_lc="$LC_ALL"
  fi
  export LC_ALL=C
  IFS= read -r -N "$((codex_eci_marker_max_bytes + 1))" prefix <"$marker" || true
  [ "${#prefix}" -le "$codex_eci_marker_max_bytes" ] && within=true
  if [ "$had_lc" -eq 1 ]; then
    export LC_ALL="$old_lc"
  else
    unset LC_ALL
  fi
  [ "$within" = true ]
}

# Enumerate only a finite number of immediate-session eci_active candidates.
# Unrelated proof files/directories do not consume marker capacity. Callers
# treat the overflow token as unsafe control state; malformed or unsafe
# candidates remain in the stream for strict validation rather than being
# silently discarded.
codex_eci_marker_candidates_bounded() {
  local root entry count=0

  root="$(codex_proof_root)"
  if ! codex_proof_root_is_safe; then
    printf '%s\n' "$codex_eci_marker_scan_unsafe_token"
    return 0
  fi
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' entry; do
    count=$((count + 1))
    if [ "$count" -gt "$codex_eci_marker_scan_max_candidates" ]; then
      printf '%s\n' "$codex_eci_marker_scan_overflow_token"
      return 0
    fi
    printf '%s\n' "$entry"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name eci_active -print0 2>/dev/null)
}

# State writers use these no-follow final-component checks before mkdir or
# marker mutation.  Ancestor cache symlinks are allowed when they resolve to
# directories; the configured proof root and session directory themselves may
# not be symlinks or non-directories.
codex_proof_root_is_safe() {
  local configured root parent

  configured="$(codex_configured_proof_root)"
  # A trailing slash changes how `test -L` treats a final symlink on some
  # platforms.  Normalize it before checking the configured final component;
  # keep the filesystem root itself intact.
  while [ "$configured" != "/" ] && [ "${configured%/}" != "$configured" ]; do
    configured="${configured%/}"
  done
  case "$configured" in
    /*) ;;
    *) return 1 ;;
  esac
  # Resolve ancestor symlinks for a stable canonical root.  The configured
  # final proof-root component itself must never be a symlink: accepting it
  # would let a replaced cache entry redirect all session state elsewhere.
  root="$(codex_proof_root)"
  case "$root" in
    ""|*[![:print:]]*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$configured" ] || return 1
  case "$root" in
    */*) parent="${root%/*}"; [ -n "$parent" ] || parent="/" ;;
    *) parent="." ;;
  esac
  [ ! -L "$root" ] || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] || return 1
  fi
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] || return 1
  fi
  return 0
}

codex_equivalent_proof_root_for_path() {
  local path="$1" configured candidate prefix current
  configured="$(codex_configured_proof_root)"
  case "$configured" in
    */.cache/codex-proof) ;;
    *) return 1 ;;
  esac
  case "$path" in
    */.cache/codex-proof/*)
      prefix="${path%%/.cache/codex-proof/*}"
      [ "$prefix" != "$path" ] || return 1
      candidate="$prefix/.cache/codex-proof" ;;
    *) return 1 ;;
  esac
  [ -n "$prefix" ] || return 1
  [ "$(printf '%s\n' "$candidate" | sed 's#^/*##' | sed 's#/.*##')" ] || return 1
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  [ "$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)" = \
    "$(stat -Lc '%d:%i' -- "$configured" 2>/dev/null || true)" ] || return 1
  current="$candidate"
  while [ "$current" != "/" ]; do
    [ ! -L "$current" ] || return 1
    current="${current%/*}"
    [ -n "$current" ] || current="/"
  done
  printf '%s\n' "$candidate"
}

codex_state_path_is_safe() {
  local path="$1"
  local root="$2"
  local rest component current alias_root

  codex_proof_root_is_safe || return 1
  [ "$root" = "$(codex_proof_root)" ] || return 1
  current="$root"
  case "$path" in
    "$root"/*) rest="${path#"$root"/}" ;;
    "$(codex_configured_proof_root)"/*)
      codex_proof_roots_equivalent || return 1
      rest="${path#"$(codex_configured_proof_root)"/}"
      current="$(codex_configured_proof_root)" ;;
    *)
      alias_root="$(codex_equivalent_proof_root_for_path "$path" 2>/dev/null || true)"
      [ -n "$alias_root" ] || return 1
      rest="${path#"$alias_root"/}"
      current="$alias_root" ;;
  esac
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    [ -n "$component" ] || return 1
    current="$current/$component"
    [ ! -L "$current" ] || return 1
    if [ -e "$current" ]; then
      [ -d "$current" ] || [ "$rest" = "$component" ] || return 1
    fi
    if [ "$rest" = "$component" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
  done
}

codex_proof_roots_equivalent() {
  local candidate="${1:-$(codex_configured_proof_root)}"
  local configured="$(codex_configured_proof_root)" canonical="$(codex_proof_root)"
  [ "$candidate" = "$canonical" ] && return 0
  [ -d "$candidate" ] && [ -d "$configured" ] && [ -d "$canonical" ] || return 1
  [ ! -L "$candidate" ] && [ ! -L "$configured" ] && [ ! -L "$canonical" ] || return 1
  [ "$(stat -Lc '%d:%i' -- "$configured" 2>/dev/null || true)" = \
    "$(stat -Lc '%d:%i' -- "$canonical" 2>/dev/null || true)" ] || return 1
  [ "$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)" = \
    "$(stat -Lc '%d:%i' -- "$configured" 2>/dev/null || true)" ]
}

codex_session_dir_is_safe() {
  local root="$1"
  local session_id="$2"
  local dir

  codex_valid_session_id "$session_id" || return 1
  [ "$root" = "$(codex_proof_root)" ] || return 1
  codex_proof_root_is_safe || return 1
  dir="$root/$session_id"
  [ ! -L "$dir" ] || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] || return 1
  fi
  return 0
}

codex_eci_lock_path() {
  codex_proof_root_is_safe || return 1
  printf '%s/.eci-active.lock\n' "$(codex_proof_root)"
}

codex_reserved_proof_dir() {
  case "${1:-}" in
    activity|audit|eci|history|pre-reviewer|reviewer|reviewer-dumps|security-warnings-*|side-stop|skip-stop|skills)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_real_session_dir_name() {
  [[ "${1:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

codex_proof_alias_session_id() {
  local dir="$1"
  local marker session_id

  # Alias directories are state roots, not transparent symlink shortcuts.
  # Validate every component before reading the alias record so an alias
  # cannot redirect ownership through a replaced/symlinked directory.
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  codex_state_path_is_safe "$dir" "$(codex_proof_root)" || return 1
  marker="$dir/.codex-proof-alias"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  session_id="$(awk -F':[[:space:]]*' '$1 == "session_id" { print $2; exit }' "$marker" 2>/dev/null | tr -d '\r')"
  codex_valid_session_id "$session_id" || return 1
  printf '%s\n' "$session_id"
}

codex_canonical_cwd() {
  local cwd="${1:-$PWD}"
  if [ -d "$cwd" ]; then
    (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s\n' "$cwd"
  else
    printf '%s\n' "$cwd"
  fi
}

codex_resolve_hook_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"

  [ -n "$path" ] || return 1
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *) path="$cwd/$path" ;;
  esac

  realpath -m -- "$path" 2>/dev/null || printf '%s\n' "$path"
}

codex_lexical_hook_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"

  [ -n "$path" ] || return 1
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#~/}" ;;
  esac
  # GNU realpath's -s/-m pair performs the same lexical abspath/normpath
  # operation without following symlink ancestors, but avoids starting a
  # Python interpreter on every synchronous edit callback.  Retain the
  # bounded Python fallback for platforms without that realpath capability.
  local lexical_path
  if command -v realpath >/dev/null 2>&1 &&
     lexical_path="$(realpath -ms -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$lexical_path"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$cwd" "$path" <<'PY'
import os
import sys
cwd, path = sys.argv[1:3]
if not os.path.isabs(path):
    path = os.path.join(cwd, path)
print(os.path.normpath(os.path.abspath(path)))
PY
  else
    case "$path" in
      /*) printf '%s\n' "$path" ;;
      *) printf '%s\n' "$cwd/$path" ;;
    esac
  fi
}

codex_path_is_under_proof_root() {
  local path="${1:-}" alias_root
  case "${1:-}" in
    "$(codex_proof_root)"/*) return 0 ;;
    "$(codex_configured_proof_root)"/*) codex_proof_roots_equivalent ;;
    *)
      alias_root="$(codex_equivalent_proof_root_for_path "$path" 2>/dev/null || true)"
      [ -n "$alias_root" ] && codex_proof_roots_equivalent "$alias_root" ;;
  esac
}

codex_session_ledger_basenames() {
  printf '%s\n' \
    "project-understanding.md" \
    "high_level_log.md" \
    "high_level_log.anchor" \
    "latest-status-report.md"
}

codex_session_ledger_basename() {
  case "${1:-}" in
    project-understanding.md|high_level_log.md|high_level_log.anchor|latest-status-report.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Reserved coordinator/ECI state is never an ordinary worker-edit target.
# Keep this predicate name/path based so it also protects files that have not
# been created yet and does not depend on the target existing.  Callers pass
# both lexical and resolved paths when aliases are involved.
codex_eci_control_basename() {
  case "${1:-}" in
    eci-wait-repair-authorize|eci-wait-repair-authorize.*)
      return 0
      ;;
    eci_active|eci_active.*|goal_state|goal_state.*|eci_wait|eci_wait.*|eci_user_owned_wait.md|eci_user_owned_wait.md.*|eci-coordinator-edit|eci-coordinator-edit.*|eci-permissive-mode|eci-permissive-mode.*|eci-permissive-authorize|eci-permissive-authorize.*|.eci-permissive-mode|.eci-permissive-mode.*|.eci-permissive-authorize|.eci-permissive-authorize.*|eci-required-critics.json|eci-required-critics.json.*|eci-required-critics.*|eci-critic-identities.ledger|eci-critic-identities.ledger.*|eci-acceptance-anchor|eci-acceptance-anchor.*|eci-acceptance-transaction|eci-acceptance-transaction.*|eci-teardown-complete|eci-teardown-complete.*|eci-prewrite-admitted.*|eci-baseline-binding|eci-baseline-binding.*|baseline_head|baseline_head.*|eci-commit-admitted|eci-commit-admitted.*|eci-user-closed.ledger|eci-user-closed.ledger.*|eci-aggregate-plan.json|eci-aggregate-plan.json.*|eci-aggregate-teardown-complete|eci-aggregate-teardown-complete.*|eci-aggregate.*|eci-accidental-mistake-override|eci-accidental-mistake-override.*|.eci-accidental-mistake-override|.eci-accidental-mistake-override.*|.eci-accidental-mistake-override.claim|ate_nested_eci_active|ate_nested_eci_active.*|ate_nested_eci_completion|ate_nested_eci_completion.*|eci-blocker-report.md|stop_timestamps|stop_loop_state|stop_loop_state.*|disengage.md|user-closed.md|proof.md|instructions.md|project-understanding.md|project-understanding.md.*|high_level_log.md|high_level_log.md.*|latest-status-report.md|latest-status-report.md.*|high_level_log.anchor|high_level_log.anchor.*|high_level_log.md.tmp.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# A worker may name a hardlink alias outside the proof root.  Compare the
# alias inode against canonical coordinator records before allowing any edit;
# the regular path/name checks above cannot see this attack.  This helper is
# only used on edit/control paths (not the Stop hot path) and is bounded to
# the proof tree plus a finite candidate count.
# This resolves one concrete accidental-target confusion: a worker can name an
# alias of a coordinator record without realizing it.  It is not a malicious-
# actor/evasion control and does not make ordinary aliases suspicious; callers
# act only when the resolved edit target is an actual control record.
codex_path_is_eci_control_alias() {
  local path="${1:-}" root candidate target_stat candidate_stat count=0
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  target_stat="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
  [ -n "$target_stat" ] || return 1
  root="$(codex_proof_root)"
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  while IFS= read -r -d '' candidate; do
    count=$((count + 1))
    [ "$count" -le 2048 ] || return 1
    codex_eci_control_basename "${candidate##*/}" || continue
    candidate_stat="$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)"
    [ "$candidate_stat" = "$target_stat" ] && return 0
  done < <(find -P "$root" -type f -links +1 -print0 2>/dev/null || true)
  return 1
}

codex_path_is_git_approval_file() {
  case "${1##*/}" in
    .git-reset-approved-once|.git-worktree-approved-once|.git-commit-approved-once)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_path_is_eci_control_file() {
  local path="${1:-}"
  local actual_root default_root root rest sid filename global_override

  [ -n "$path" ] || return 1
  filename="${path##*/}"

  actual_root="$(codex_resolve_hook_path "$PWD" "$(codex_proof_root)" 2>/dev/null || codex_proof_root)"
  default_root="$(codex_resolve_hook_path "$PWD" "$HOME/.cache/codex-proof" 2>/dev/null || printf '%s\n' "$HOME/.cache/codex-proof")"
  for root in "$actual_root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        [ "$rest" != "$sid" ] || continue
        case "$rest" in
          */.eci-accidental-mistake-override.claim|*/.eci-accidental-mistake-override.claim/*)
            codex_valid_session_id "$sid" && return 0
            continue
            ;;
          */eci-wait-repair-authorize.claim|*/eci-wait-repair-authorize.claim/*)
            codex_valid_session_id "$sid" && return 0
            continue
            ;;
        esac
        # Legacy proof namespaces are coordinator-owned recursively.  Do
        # this before the one-level session-control check so a worker cannot
        # target a deeper descendant such as pre-reviewer/archive/state.
        codex_reserved_proof_dir "$sid" && return 0
        [ "${rest#*/}" = "$filename" ] || continue
        codex_eci_control_basename "$filename" || continue
        codex_valid_session_id "$sid" || continue
        return 0
        ;;
    esac
  done
  global_override="$(codex_eci_accidental_override_record_path global 2>/dev/null || true)"
  if [ -n "$global_override" ] && [ "$path" = "$global_override" ]; then
    return 0
  fi
  if [ -n "$global_override" ] && [ "$path" = "$global_override.claim" ]; then
    return 0
  fi
  if [ -n "$global_override" ] && [[ "$path" == "$global_override.claim/"* ]]; then
    return 0
  fi
  return 1
}

codex_path_is_session_ledger_file() {
  local path="$1"
  local actual_root default_root root rest sid filename

  [ -n "$path" ] || return 1
  filename="${path##*/}"
  codex_session_ledger_basename "$filename" || return 1

  actual_root="$(codex_resolve_hook_path "$PWD" "$(codex_proof_root)" 2>/dev/null || codex_proof_root)"
  default_root="$(codex_resolve_hook_path "$PWD" "$HOME/.cache/codex-proof" 2>/dev/null || printf '%s\n' "$HOME/.cache/codex-proof")"
  for root in "$actual_root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        [ "$rest" != "$sid" ] || continue
        [ "${rest#*/}" = "$filename" ] || continue
        codex_reserved_proof_dir "$sid" && continue
        codex_valid_session_id "$sid" || continue
        return 0
        ;;
    esac
  done

  return 1
}

codex_path_is_high_level_log_file() {
  local path="${1:-}"
  [ "${path##*/}" = "high_level_log.md" ] || return 1
  codex_path_is_session_ledger_file "$path"
}

codex_hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    local digest
    digest="$(printf '%s' "${1:-}" | sha256sum)" || return 1
    printf '%s\n' "${digest%% *}"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "${1:-}" | python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    return 1
  fi
}

codex_eci_accidental_override_tool_is_valid() {
  case "${1:-}" in
    validate-bash|validate-apply-patch) return 0 ;;
    *) return 1 ;;
  esac
}

codex_eci_accidental_override_scope_is_valid() {
  case "${1:-}" in
    session|global) return 0 ;;
    *) return 1 ;;
  esac
}

codex_home_lexical_root() {
  local home="${HOME:-}" root

  [ -n "$home" ] || return 1
  root="$home/.codex"
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$root" in
    *[![:print:]]*|*//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  printf '%s\n' "$root"
}

codex_eci_accidental_override_global_root() {
  local root canonical

  root="$(codex_home_lexical_root)" || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  canonical="$(realpath -e -- "$root" 2>/dev/null || true)"
  [ -n "$canonical" ] && [ "$canonical" = "$(realpath -m -- "$canonical" 2>/dev/null || true)" ] || return 1
  printf '%s\n' "$canonical"
}

codex_eci_accidental_override_record_path() {
  local scope="$1" session_id="${2:-}" root path

  codex_eci_accidental_override_scope_is_valid "$scope" || return 1
  case "$scope" in
    session)
      codex_valid_session_id "$session_id" || return 1
      root="$(codex_proof_root)"
      codex_session_dir_is_safe "$root" "$session_id" || return 1
      path="$root/$session_id/.eci-accidental-mistake-override"
      codex_state_path_is_safe "$path" "$root" || return 1
      ;;
    global)
      root="$(codex_eci_accidental_override_global_root)" || return 1
      path="$root/.eci-accidental-mistake-override"
      [ "$(realpath -m -- "$path" 2>/dev/null || true)" = "$path" ] || return 1
      [ ! -L "$path" ] || return 1
      ;;
  esac
  printf '%s\n' "$path"
}

# Cleanup accepts only the canonical session-claim spelling below the active
# proof root.  In particular, the global override record is intentionally not
# a target for this narrow recovery route.
codex_eci_accidental_override_claim_path_is_canonical() {
  local claim="${1:-}" root rest session_id

  root="$(codex_proof_root)" || return 1
  codex_proof_root_is_safe || return 1
  case "$claim" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$claim" in
    *[![:print:]]*) return 1 ;;
  esac
  case "$claim" in
    "$root"/*) rest="${claim#"$root"/}" ;;
    *) return 1 ;;
  esac
  [ "$claim" = "$(realpath -m -- "$claim" 2>/dev/null || true)" ] || return 1
  session_id="${rest%%/*}"
  [ "$rest" = "$session_id/.eci-accidental-mistake-override.claim" ] || return 1
  codex_valid_session_id "$session_id" || return 1
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  [ "$claim" = "$root/$session_id/.eci-accidental-mistake-override.claim" ] || return 1
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  [ "$claim" = "$(realpath -e -- "$claim" 2>/dev/null || true)" ] || return 1
}

codex_eci_accidental_override_cleanup_command() {
  local claim="${1:-}" source provider_root codex_root kimi_root

  codex_eci_accidental_override_claim_path_is_canonical "$claim" || return 1
  source="$(realpath -e -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  case "$source" in
    */hooks/lib/codex-proof-state.sh)
      provider_root="${source%/hooks/lib/codex-proof-state.sh}"
      ;;
    *)
      return 1
      ;;
  esac
  codex_root="$(realpath -e -- "${HOME:-}/.codex" 2>/dev/null || true)"
  kimi_root="$(realpath -e -- "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" 2>/dev/null || true)"

  case "$provider_root" in
    "$codex_root")
      [ -n "$codex_root" ] || return 1
      printf '"$HOME/.codex/bin/eci-active" accidental-override-cleanup --authorized-by-user %q\n' "$claim"
      ;;
    "$kimi_root")
      [ -n "$kimi_root" ] || return 1
      printf '"${KIMI_CODE_HOME:-$HOME/.kimi-code}/bin/eci-active" accidental-override-cleanup --authorized-by-user %q\n' "$claim"
      ;;
    *)
      return 1
      ;;
  esac
}

codex_eci_accidental_override_fingerprint() {
  local scope="$1" tool="$2" session_id="${3:-}" cwd="${4:-}" payload="${5-}" canonical_cwd

  codex_eci_accidental_override_scope_is_valid "$scope" || return 1
  codex_eci_accidental_override_tool_is_valid "$tool" || return 1
  codex_valid_session_id "$session_id" || return 1
  [ -d "$cwd" ] && [ ! -L "$cwd" ] || return 1
  canonical_cwd="$(codex_canonical_cwd "$cwd")"
  case "$canonical_cwd" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$scope" in
    session)
      codex_hash_string "eci-accidental-mistake-override/v1
session
$session_id
$canonical_cwd
$tool
$payload"
      ;;
    global)
      codex_hash_string "eci-accidental-mistake-override/v1
global
$tool
$payload"
      ;;
  esac
}

codex_eci_accidental_override_record_is_valid() {
  local scope="$1" tool="$2" session_id="$3" cwd="$4" payload="${5-}" record expected_fingerprint canonical_cwd
  local -a lines=()

  # Legacy structured records are parsed only for status/cleanup compatibility.
  # They never authorize an operation or affect ordinary command routing.

  record="$(codex_eci_accidental_override_record_path "$scope" "$session_id")" || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  codex_state_file_owner_is_valid "$record" || return 1
  [ "$(realpath -m -- "$record" 2>/dev/null || true)" = "$record" ] || return 1
  [ "$(wc -c <"$record" 2>/dev/null || printf 999999)" -le 4096 ] || return 1
  [ "$(tail -c 1 -- "$record" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$record" 2>/dev/null && return 1 || true
  mapfile -t lines <"$record" || return 1
  [ "${#lines[@]}" -eq 7 ] || return 1
  for line in "${lines[@]}"; do
    LC_ALL=C printf '%s' "$line" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
  done
  canonical_cwd="$(codex_canonical_cwd "$cwd")"
  [ "${lines[0]}" = 'schema: eci-accidental-mistake-override/v1' ] || return 1
  [ "${lines[1]}" = "scope: $scope" ] || return 1
  case "$scope" in
    session)
      [ "${lines[2]}" = "session_id: $session_id" ] || return 1
      [ "${lines[4]}" = "cwd: $canonical_cwd" ] || return 1
      ;;
    global)
      [ "${lines[2]}" = 'session_id: *' ] || return 1
      [ "${lines[4]}" = 'cwd: *' ] || return 1
      ;;
  esac
  [ "${lines[3]}" = "tool: $tool" ] || return 1
  expected_fingerprint="$(codex_eci_accidental_override_fingerprint "$scope" "$tool" "$session_id" "$cwd" "$payload")" || return 1
  [ "${lines[5]}" = "fingerprint: $expected_fingerprint" ] || return 1
  [ "${lines[6]}" = 'authorized_by: user' ] || return 1
}

# Legacy override records are retained only for status/cleanup compatibility.
# Command admission never consumes them or treats their provenance as authority.
codex_eci_accidental_override_matches() {
  local scope="$1" tool="$2" session_id="$3" cwd="$4" payload="${5-}"
  codex_eci_accidental_override_record_is_valid "$scope" "$tool" "$session_id" "$cwd" "$payload"
}

codex_eci_accidental_override_consume_reason=""
codex_eci_accidental_override_consume() {
  local scope="$1" tool="$2" session_id="$3" cwd="$4" payload="${5-}"
  local record lock_path claim lock_fd recovery_command

  record="$(codex_eci_accidental_override_record_path "$scope" "$session_id")" || return 1
  claim="$record.claim"
  if { [ ! -f "$record" ] || [ -L "$record" ]; } &&
     [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    return 1
  fi
  lock_path="$(codex_eci_lock_path 2>/dev/null || true)"
  [ -n "$lock_path" ] || return 1
  [ ! -L "$lock_path" ] && { [ ! -e "$lock_path" ] || [ -f "$lock_path" ]; } || return 1
  if ! exec {lock_fd}>>"$lock_path" 2>/dev/null; then
    return 1
  fi
  if ! flock -n "$lock_fd" 2>/dev/null; then
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return 1
  fi

  claim="$record.claim"
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    if ! { [ -d "$claim" ] && [ ! -L "$claim" ] &&
           [ -f "$record" ] && [ ! -L "$record" ] &&
           rmdir -- "$claim" 2>/dev/null; }; then
      recovery_command="$(codex_eci_accidental_override_cleanup_command "$claim" 2>/dev/null || true)"
      if [ -n "$recovery_command" ]; then
        codex_eci_accidental_override_consume_reason="authorization state is already consumed or interrupted (state=$claim); publish a new explicitly authorized record and use the coordinator recovery route: run from the main coordinator: $recovery_command; do not restore the old record"
      else
        codex_eci_accidental_override_consume_reason="authorization state is already consumed or interrupted (state=$claim); publish a new explicitly authorized record and use the coordinator recovery route before retrying; do not restore the old record"
      fi
      flock -u "$lock_fd" 2>/dev/null || true
      eval "exec $lock_fd>&-" 2>/dev/null || true
      return 1
    fi
  fi
  if [ -e "$claim" ] || [ -L "$claim" ] || ! mkdir -- "$claim" 2>/dev/null; then
    flock -u "$lock_fd" 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return 1
  fi
  if ! codex_eci_accidental_override_record_is_valid "$scope" "$tool" "$session_id" "$cwd" "$payload"; then
    rmdir -- "$claim" 2>/dev/null || true
    flock -u "$lock_fd" 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return 1
  fi
  if ! mv -- "$record" "$claim/record" 2>/dev/null; then
    rmdir -- "$claim" 2>/dev/null || true
    flock -u "$lock_fd" 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return 1
  fi
  if ! rm -f -- "$claim/record" 2>/dev/null || ! rmdir -- "$claim" 2>/dev/null; then
    flock -u "$lock_fd" 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return 1
  fi
  flock -u "$lock_fd" 2>/dev/null || true
  eval "exec ${lock_fd}>&-" 2>/dev/null || true
  return 0
}

codex_eci_session_permissive_scope_is_valid() {
  case "${1:-}" in session|global) return 0 ;; *) return 1 ;; esac
}

codex_eci_session_permissive_selector_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

codex_eci_session_permissive_request_is_valid() {
  local request="${1-}"
  # The direct lifecycle request describes the user-selected mode. It is not
  # turned into a hash/authorization artifact before ordinary recovery work.
  [ -n "$request" ] && [ "${#request}" -le 1048576 ]
}

codex_eci_session_permissive_record_path() {
  local scope="$1" session_id="${2:-}" root path
  codex_eci_session_permissive_scope_is_valid "$scope" || return 1
  if [ "$scope" = session ]; then
    codex_valid_session_id "$session_id" || return 1
    root="$(codex_proof_root)"
    codex_session_dir_is_safe "$root" "$session_id" || return 1
    path="$root/$session_id/eci-permissive-mode"
    codex_state_path_is_safe "$path" "$root" || return 1
  else
    root="$(codex_eci_accidental_override_global_root)" || return 1
    path="$root/.eci-permissive-mode"
    [ "$(realpath -m -- "$path" 2>/dev/null || true)" = "$path" ] && [ ! -L "$path" ] || return 1
  fi
  printf '%s\n' "$path"
}

codex_eci_session_permissive_record_is_valid() {
  local scope="$1" session_id="$2" cwd="$3" gate="$4" operation="$5" request="${6-}" reference_epoch="${7-}"
  local record canonical_cwd='*' session_value='*' now issued expires marker marker_cwd
  local -a lines=()
  codex_eci_session_permissive_scope_is_valid "$scope" &&
    codex_eci_session_permissive_selector_is_valid "$gate" &&
    codex_eci_session_permissive_selector_is_valid "$operation" &&
    codex_eci_session_permissive_request_is_valid "$request" || return 1
  record="$(codex_eci_session_permissive_record_path "$scope" "$session_id")" || return 1
  [ -f "$record" ] && [ ! -L "$record" ] && codex_state_file_owner_is_valid "$record" || return 1
  [ "$(stat -Lc '%a' -- "$record" 2>/dev/null || true)" = 600 ] || return 1
  [ "$(wc -c <"$record" 2>/dev/null || printf 999999)" -le 4096 ] || return 1
  [ "$(tail -c 1 -- "$record" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$record" 2>/dev/null && return 1 || true
  mapfile -t lines <"$record" || return 1
  [ "${#lines[@]}" -eq 9 ] || return 1
  if [ "$scope" = session ]; then
    canonical_cwd="$(codex_canonical_cwd "$cwd")"; session_value="$session_id"
    marker="$(codex_proof_root)/$session_id/eci_active"
    marker_cwd="$(codex_eci_direct_marker_cwd "$marker" "$session_id")" || return 1
    [ "$marker_cwd" = "$canonical_cwd" ] || return 1
  fi
  issued="${lines[6]#issued_at_epoch: }"; expires="${lines[7]#expires_at_epoch: }"
  [[ "$issued" =~ ^[0-9]{1,12}$ && "$expires" =~ ^[0-9]{1,12}$ ]] && [ "$expires" -gt "$issued" ] || return 1
  [ "${lines[0]}" = 'schema: eci-permissive-mode/v2' ] && [ "${lines[1]}" = "scope: $scope" ] &&
    [ "${lines[2]}" = "session_id: $session_value" ] && [ "${lines[3]}" = "cwd: $canonical_cwd" ] &&
    [ "${lines[4]}" = "gate: $gate" ] && [ "${lines[5]}" = "operation: $operation" ] &&
    [ "${lines[6]}" = "issued_at_epoch: $issued" ] && [ "${lines[7]}" = "expires_at_epoch: $expires" ] &&
    [ "${lines[8]}" = 'state: active' ] || return 1
  if [ -n "$reference_epoch" ]; then
    now="$reference_epoch"
  else
    now="$(date -u '+%s')"
  fi
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 1
  [ "$now" -lt "$expires" ] || return 2
}

codex_eci_session_permissive_active() {
  local scope="$1" session_id="$2" cwd="$3" gate="$4" operation="$5" request="${6-}" record status=0
  codex_eci_session_permissive_record_is_valid "$scope" "$session_id" "$cwd" "$gate" "$operation" "$request" || status=$?
  [ "$status" -eq 0 ] && return 0
  if [ "$status" -eq 2 ]; then
    record="$(codex_eci_session_permissive_record_path "$scope" "$session_id")" || return 1
    codex_state_file_owner_is_valid "$record" && rm -f -- "$record" 2>/dev/null || true
  fi
  return 1
}

# Coordinator self-edit state is a short-lived routing preference.  It is not
# a command permission, authorization record, or receipt.
codex_eci_coordinator_edit_record_path() {
  local session_id="$1" root path

  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  path="$root/$session_id/eci-coordinator-edit"
  codex_state_path_is_safe "$path" "$root" || return 1
  printf '%s\n' "$path"
}

# Print `active` or `inactive` for an ordinary record. An accidentally wrong
# target is surfaced rather than overwritten through a symlink or non-regular
# object.
codex_eci_coordinator_edit_record_state() {
  local session_id="$1" cwd="$2" record canonical_cwd marker marker_cwd bytes issued expires now
  local -a lines=()

  codex_valid_session_id "$session_id" || return 1
  [ -d "$cwd" ] && [ ! -L "$cwd" ] || {
    printf '%s\n' inactive
    return 0
  }
  canonical_cwd="$(codex_canonical_cwd "$cwd")"
  record="$(codex_eci_coordinator_edit_record_path "$session_id")" || return 1
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    printf '%s\n' inactive
    return 0
  fi
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  bytes="$(wc -c <"$record" 2>/dev/null || true)"
  case "$bytes" in
    ''|*[!0-9]*)
      printf '%s\n' inactive
      return 0
      ;;
  esac
  [ "$bytes" -le 4096 ] || {
    printf '%s\n' inactive
    return 0
  }
  [ "$(tail -c 1 -- "$record" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || {
    printf '%s\n' inactive
    return 0
  }
  LC_ALL=C grep -q $'\r' "$record" 2>/dev/null && {
    printf '%s\n' inactive
    return 0
  }
  mapfile -t lines <"$record" || return 1
  [ "${#lines[@]}" -eq 6 ] || {
    printf '%s\n' inactive
    return 0
  }
  issued="${lines[3]#issued_at_epoch: }"
  expires="${lines[4]#expires_at_epoch: }"
  [[ "$issued" =~ ^[0-9]{1,12}$ && "$expires" =~ ^[0-9]{1,12}$ ]] || {
    printf '%s\n' inactive
    return 0
  }
  [ "${lines[0]}" = 'schema: eci-coordinator-edit/v1' ] &&
    [ "${lines[1]}" = "session_id: $session_id" ] &&
    [ "${lines[2]}" = "cwd: $canonical_cwd" ] &&
    [ "${lines[3]}" = "issued_at_epoch: $issued" ] &&
    [ "${lines[4]}" = "expires_at_epoch: $expires" ] &&
    [ "${lines[5]}" = 'state: active' ] || {
      printf '%s\n' inactive
      return 0
    }
  ((10#$expires == 10#$issued + 600)) || {
    printf '%s\n' inactive
    return 0
  }
  marker="$(codex_proof_root)/$session_id/eci_active"
  marker_cwd="$(codex_eci_aggregate_marker_cwd "$marker" "$session_id")" || {
    printf '%s\n' inactive
    return 0
  }
  [ "$marker_cwd" = "$canonical_cwd" ] || {
    printf '%s\n' inactive
    return 0
  }
  now="$(date -u '+%s')"
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 1
  if ((10#$now >= 10#$issued && 10#$now < 10#$expires)); then
    printf '%s\n' active
  else
    printf '%s\n' inactive
  fi
}

codex_eci_coordinator_edit_is_active() {
  local state

  state="$(codex_eci_coordinator_edit_record_state "$1" "$2")" || return 1
  [ "$state" = active ]
}

# Permissive state is a short-lived UI/status compatibility record.  It is
# never consulted by the command gate: ordinary work proceeds without it, and
# concrete harmful effects are evaluated from their resolved targets instead.

# Repository inspection is acceptance-sensitive.  Resolve Git from fixed
# system locations once; never let a caller-controlled PATH select the
# executable.  The active Stop path never calls this helper.
codex_git_executable=""
for codex_git_candidate in /usr/bin/git /bin/git /usr/local/bin/git; do
  if [ -x "$codex_git_candidate" ]; then
    codex_git_executable="$codex_git_candidate"
    break
  fi
done

# Run Git in a scrubbed environment so caller-provided config, external-diff
# helpers, textconv filters, alternate object stores, or editor/pager hooks
# cannot execute during review/receipt validation.
codex_git_safe() {
  local arg
  local -a safe_args=()
  [ -n "$codex_git_executable" ] || return 1
  for arg in "$@"; do
    safe_args+=("$arg")
    [ "$arg" = diff ] && safe_args+=(--no-ext-diff --no-textconv)
  done
  env -i \
    HOME="${HOME:-/nonexistent}" \
    PATH=/usr/bin:/bin \
    LANG="${LANG:-C}" \
    LC_ALL="${LC_ALL:-C}" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_DIFF_OPTS= \
    GIT_PAGER=cat \
    GIT_EDITOR=: \
    GIT_SEQUENCE_EDITOR=: \
    GIT_ASKPASS=: \
    GIT_TERMINAL_PROMPT=0 \
    "$codex_git_executable" -c core.fsmonitor=false "${safe_args[@]}"
}

# Create and publish one aggregate commit from the tree admitted by the review
# anchor. The ref CAS prevents a concurrent head move, while checks on both
# sides of commit-tree prevent unreviewed index bytes from entering the ref.
aggregate_commit_accepted_tree_cas() {
  local repo_root="$1" tree_oid="$2" parent_oid="$3" ref_name="$4" message="$5"
  local current_tree current_parent current_ref current_ref_oid new_commit post_tree

  aggregate_commit_tree_cas_failure=""
  [[ "$tree_oid" =~ ^[0-9a-f]{40,64}$ && "$parent_oid" =~ ^[0-9a-f]{40,64}$ ]] || {
    aggregate_commit_tree_cas_failure='accepted tree or parent is malformed'
    return 1
  }
  case "$ref_name" in refs/heads/*) ;; *)
    aggregate_commit_tree_cas_failure='accepted branch reference is malformed'
    return 1
    ;;
  esac
  codex_git_safe -C "$repo_root" check-ref-format "$ref_name" >/dev/null 2>&1 || {
    aggregate_commit_tree_cas_failure='accepted branch reference is invalid'
    return 1
  }
  current_tree="$(codex_git_safe -C "$repo_root" write-tree 2>/dev/null || true)"
  [ "$current_tree" = "$tree_oid" ] || {
    aggregate_commit_tree_cas_failure='index tree changed after acceptance'
    return 1
  }
  current_parent="$(codex_git_safe -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  current_ref="$(codex_git_safe -C "$repo_root" symbolic-ref -q HEAD 2>/dev/null || true)"
  current_ref_oid="$(codex_git_safe -C "$repo_root" rev-parse --verify "$ref_name^{commit}" 2>/dev/null || true)"
  [ "$current_parent" = "$parent_oid" ] && [ "$current_ref" = "$ref_name" ] && [ "$current_ref_oid" = "$parent_oid" ] || {
    aggregate_commit_tree_cas_failure='accepted parent or branch changed before commit publication'
    return 1
  }
  new_commit="$(codex_git_safe -C "$repo_root" commit-tree "$tree_oid" -p "$parent_oid" -F "$message" 2>/dev/null || true)"
  [[ "$new_commit" =~ ^[0-9a-f]{40,64}$ ]] || {
    aggregate_commit_tree_cas_failure='could not create an explicit-tree commit object'
    return 1
  }
  post_tree="$(codex_git_safe -C "$repo_root" write-tree 2>/dev/null || true)"
  [ "$post_tree" = "$tree_oid" ] || {
    aggregate_commit_tree_cas_failure='index tree changed after acceptance'
    return 1
  }
  codex_git_safe -C "$repo_root" update-ref -m 'ECI aggregate commit' "$ref_name" "$new_commit" "$parent_oid" || {
    aggregate_commit_tree_cas_failure='accepted parent changed before CAS ref publication'
    return 1
  }
}

# Recompute the bounded repository tuple used by eci-review-gate.  Terminal
# receipt validation is deliberately the only caller on the Stop path; the
# active-marker fast path never reaches this helper.
codex_eci_live_repo_binding_sha256() {
  local manifest="$1"
  local repo_root git_dir git_common base head staged worktree status
  local repo_root_actual git_dir_raw git_common_raw git_dir_actual git_common_actual

  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  repo_root="$(jq -r '.repo_root // empty' "$manifest" 2>/dev/null || true)"
  git_dir="$(jq -r '.git_dir // empty' "$manifest" 2>/dev/null || true)"
  git_common="$(jq -r '.git_common_dir // empty' "$manifest" 2>/dev/null || true)"
  base="$(jq -r '.base_oid // empty' "$manifest" 2>/dev/null || true)"
  [ -n "$repo_root" ] && [ -n "$git_dir" ] && [ -n "$git_common" ] || return 1
  [[ "$base" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  case "$repo_root$git_dir$git_common$base" in *[![:print:]]*) return 1 ;; esac
  case "$repo_root:$git_dir:$git_common" in *..*|*//*|*/./*) return 1 ;; esac

  repo_root_actual="$(codex_git_safe -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
  repo_root_actual="$(realpath -m -- "$repo_root_actual" 2>/dev/null || true)"
  [ "$repo_root_actual" = "$repo_root" ] || return 1
  git_dir_raw="$(codex_git_safe -C "$repo_root" rev-parse --git-dir 2>/dev/null || true)"
  git_common_raw="$(codex_git_safe -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$git_dir_raw" in /*) git_dir_actual="$git_dir_raw" ;; *) git_dir_actual="$repo_root/$git_dir_raw" ;; esac
  case "$git_common_raw" in /*) git_common_actual="$git_common_raw" ;; *) git_common_actual="$repo_root/$git_common_raw" ;; esac
  git_dir_actual="$(realpath -m -- "$git_dir_actual" 2>/dev/null || true)"
  git_common_actual="$(realpath -m -- "$git_common_actual" 2>/dev/null || true)"
  [ "$git_dir_actual" = "$git_dir" ] && [ "$git_common_actual" = "$git_common" ] || return 1
  head="$(codex_git_safe -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  staged="$(codex_git_safe -C "$repo_root" diff --cached --binary | sha256sum | awk '{print $1}')"
  worktree="$(codex_git_safe -C "$repo_root" diff --binary | sha256sum | awk '{print $1}')"
  status="$(codex_git_safe -C "$repo_root" status --porcelain=v1 --untracked-files=all | sha256sum | awk '{print $1}')"
  [[ "$staged" =~ ^[0-9a-f]{64}$ && "$worktree" =~ ^[0-9a-f]{64} && "$status" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'repo_root=%s\ngit_dir=%s\ngit_common_dir=%s\nbase_oid=%s\nhead_oid=%s\nstaged_diff_sha256=%s\nworktree_diff_sha256=%s\nstatus_sha256=%s\n' \
    "$repo_root" "$git_dir" "$git_common" "$base" "$head" "$staged" "$worktree" "$status" |
    sha256sum | awk '{print $1}'
}

codex_cwd_key() {
  local cwd
  cwd="$(codex_canonical_cwd "${1:-$PWD}")"
  codex_hash_string "$cwd"
}

codex_session_state_dir() {
  local kind="$1"
  local session_id="$2"
  local dir
  codex_valid_session_id "$session_id" || return 1
  codex_proof_root_is_safe || return 1
  dir="$(codex_proof_root)/$kind/sessions/$session_id"
  codex_state_path_is_safe "$dir" "$(codex_proof_root)" || return 1
  printf '%s\n' "$dir"
}

codex_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  local dir
  codex_proof_root_is_safe || return 1
  dir="$(codex_proof_root)/$kind/cwd/$(codex_cwd_key "$cwd")"
  codex_state_path_is_safe "$dir" "$(codex_proof_root)" || return 1
  printf '%s\n' "$dir"
}

codex_ensure_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  local dir
  dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 1
  mkdir -p "$dir" || return 1
  codex_state_path_is_safe "$dir" "$(codex_proof_root)" || return 1
  codex_canonical_cwd "$cwd" >"$dir/cwd"
  printf '%s\n' "$dir"
}

codex_cli_state_dir() {
  local kind="$1"
  local create="${2:-false}"
  local dir

  if [ -n "${CODEX_SESSION_ID:-}" ]; then
    dir="$(codex_session_state_dir "$kind" "$CODEX_SESSION_ID")" || return 1
    if [ "$create" = "true" ]; then
      mkdir -p "$dir" || return 1
      codex_state_path_is_safe "$dir" "$(codex_proof_root)" || return 1
    fi
    printf '%s\n' "$dir"
    return 0
  fi

  if [ "$create" = "true" ]; then
    codex_ensure_cwd_state_dir "$kind" "$PWD"
  else
    codex_cwd_state_dir "$kind" "$PWD"
  fi
}

codex_cli_state_file() {
  local kind="$1"
  local filename="$2"
  local create="${3:-false}"
  local dir
  dir="$(codex_cli_state_dir "$kind" "$create")" || return 1
  printf '%s/%s\n' "$dir" "$filename"
}

codex_existing_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="${3:-}"
  local cwd="${4:-}"
  local dir path

  if codex_valid_session_id "$session_id"; then
    dir="$(codex_session_state_dir "$kind" "$session_id")" || return 1
    path="$dir/$filename"
    codex_state_file_owner_is_valid "$path" && { printf '%s\n' "$path"; return 0; }
  fi

  if [ -n "$cwd" ]; then
    dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 1
    path="$dir/$filename"
    codex_state_file_owner_is_valid "$path" && { printf '%s\n' "$path"; return 0; }
  fi

  if codex_valid_session_id "$session_id"; then
    path="$(codex_proof_root)/$session_id/$filename"
    if codex_session_dir_is_safe "$(codex_proof_root)" "$session_id" &&
      codex_state_file_owner_is_valid "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  return 1
}

codex_state_session_id() {
  local file="$1"
  codex_state_file_owner_is_valid "$file" || return 1
  awk -F':[[:space:]]*' '$1 == "session_id" { print $2; exit }' "$file" 2>/dev/null
}

codex_note_state_session_id() {
  local file="$1"
  local session_id="$2"
  local existing

  codex_valid_session_id "$session_id" || return 0
  codex_state_file_owner_is_valid "$file" || return 0
  existing="$(codex_state_session_id "$file" || true)"
  [ -n "$existing" ] && return 0
  printf 'session_id: %s\n' "$session_id" >>"$file"
}

codex_mark_activity() {
  local session_id="$1"
  local cwd="$2"
  local marker_name="$3"
  local dir marker

  codex_valid_session_id "$session_id" || return 0
  case "$marker_name" in
    shell|edit|subagent) ;;
    *) return 0 ;;
  esac

  dir="$(codex_session_state_dir activity "$session_id")" || return 0
  mkdir -p "$dir" || return 0
  marker="$dir/$marker_name"
  {
    printf 'kind: %s\n' "$marker_name"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$marker"
}

codex_git_repo_root_for_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"
  local target dir repo

  if [ -n "$path" ]; then
    case "$path" in
      /*) target="$path" ;;
      *) target="$cwd/$path" ;;
    esac
  else
    target="$cwd"
  fi

  if [ -d "$target" ]; then
    dir="$target"
  else
    dir="$(dirname -- "$target")"
  fi
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    dir="$(dirname -- "$dir")"
  done
  [ -d "$dir" ] || return 1

  repo="$(codex_git_safe -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo" ] || return 1
  codex_canonical_cwd "$repo"
}

codex_repo_relative_file_path() {
  local repo="$1"
  local cwd="${2:-$PWD}"
  local path="${3:-}"
  local target rel

  [ -n "$repo" ] && [ -n "$path" ] || return 1
  case "$path" in
    /*) target="$path" ;;
    *) target="$cwd/$path" ;;
  esac

  [ ! -d "$target" ] || return 1
  rel="$(realpath -m --relative-to="$repo" "$target" 2>/dev/null || true)"
  [ -n "$rel" ] || return 1
  case "$rel" in
    "."|".."|../*|/*) return 1 ;;
  esac
  printf '%s\n' "$rel"
}

codex_note_touched_repo() {
  local session_id="$1"
  local cwd="${2:-$PWD}"
  local path="${3:-}"
  local repo dir marker key head status status_sha tmp rel_path

  codex_valid_session_id "$session_id" || return 0
  repo="$(codex_git_repo_root_for_path "$cwd" "$path" 2>/dev/null || true)"
  [ -n "$repo" ] || return 0
  rel_path="$(codex_repo_relative_file_path "$repo" "$cwd" "$path" 2>/dev/null || true)"

  dir="$(codex_session_state_dir touched-repos "$session_id")" || return 0
  mkdir -p "$dir" || return 0
  key="$(codex_cwd_key "$repo")"
  marker="$dir/$key"
  if [ -f "$marker" ]; then
    if [ -n "$rel_path" ]; then
      grep -Fxq -- "path: $rel_path" "$marker" 2>/dev/null || printf 'path: %s\n' "$rel_path" >>"$marker"
    else
      grep -Fxq 'repo_wide: true' "$marker" 2>/dev/null || printf 'repo_wide: true\n' >>"$marker"
    fi
    return 0
  fi

  head="$(codex_git_safe -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  status="$(codex_git_safe -C "$repo" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)"
  status_sha="$(codex_hash_string "$status")"
  tmp="$marker.tmp.$$"
  {
    printf 'repo: %s\n' "$repo"
    printf 'head: %s\n' "$head"
    printf 'status_sha: %s\n' "$status_sha"
    if [ -n "$rel_path" ]; then
      printf 'path: %s\n' "$rel_path"
    else
      printf 'repo_wide: true\n'
    fi
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$tmp" && mv "$tmp" "$marker"
}

codex_state_value() {
  local file="$1"
  local key="$2"
  local require_unique="${3:-true}"
  # State reads remain single-link by default. Active-marker readers opt out
  # explicitly: another link does not change that marker's owner or context.
  codex_state_file_owner_is_valid "$file" "$require_unique" || return 1
  awk -F':[[:space:]]*' -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

codex_state_file_owner_is_valid() {
  local file="$1" require_unique="${2:-true}" owner links expected
  case "$require_unique" in
    true|false) ;;
    *) return 1 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  expected="${EUID:-$(id -u 2>/dev/null || printf '%s' -1)}"
  read -r owner links < <(stat -Lc '%u %h' -- "$file" 2>/dev/null) || return 1
  [ "$owner" = "$expected" ] && { [ "$require_unique" = false ] || [ "$links" = 1 ]; }
}

# Aggregate repository IDs are path-component-safe selectors.  The plan, not
# a command-line path, maps one such ID to its canonical Git worktree.
codex_eci_aggregate_repo_id_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

# Aggregate members are explicit children of the marker-bound non-Git parent.
# A canonical sibling, ancestor, or external Git root must not become a plan
# member merely because it is otherwise a valid worktree.
codex_eci_aggregate_repo_is_strict_descendant() {
  local outer_cwd="$1" repo_root="$2"

  [ -n "$outer_cwd" ] && [ -n "$repo_root" ] || return 1
  case "$repo_root" in
  "$outer_cwd"/*) return 0 ;;
  *) return 1 ;;
  esac
}

# Aggregate staging receives a repository-selected, root-relative literal
# path. Keep the lexical and filesystem checks here so the lifecycle CLI can
# validate every item before it makes its one Git index mutation.
codex_eci_aggregate_stage_path_is_safe() {
  local repo_root="$1" relative_path="$2"
  local candidate probe parent resolved list_status ignore_status component tracked relative_bytes
  local -a components tracked_paths

  [ -n "$repo_root" ] && [ -n "$relative_path" ] || return 1
  [ "$repo_root" = "$(realpath -e -- "$repo_root" 2>/dev/null || true)" ] || return 1
  [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || return 1
  case "$relative_path" in
  /*|.|..|./*|../*|*/|*//*|*/./*|*/../*) return 1 ;;
  esac
  [[ "$relative_path" == *'*'* || "$relative_path" == *'?'* ||
    "$relative_path" == *'['* || "$relative_path" == *']'* ||
    "$relative_path" == *':('* ]] && return 1
  case "$relative_path" in *[![:print:]]*) return 1 ;; esac
  relative_bytes="$(LC_ALL=C printf '%s' "$relative_path" | wc -c)"
  case "$relative_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$relative_bytes" -le 4096 ] || return 1

  local IFS=/
  read -r -a components <<<"$relative_path"
  [ "${#components[@]}" -gt 0 ] || return 1
  probe="$repo_root"
  for component in "${components[@]}"; do
    [ -n "$component" ] || return 1
    [ "$component" != . ] && [ "$component" != .. ] || return 1
    [ "$component" != .git ] || return 1
    case "$component" in .git-*-approved-once) return 1 ;; esac
    codex_eci_control_basename "$component" && return 1
    codex_path_is_git_approval_file "$component" && return 1
    probe="$probe/$component"
    [ ! -L "$probe" ] || return 1
  done

  candidate="$repo_root/$relative_path"
  [ "$candidate" = "$(realpath -m -- "$candidate" 2>/dev/null || true)" ] || return 1

  if codex_git_safe -C "$repo_root" --literal-pathspecs ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
    mapfile -d '' -t tracked_paths < <(
      codex_git_safe -C "$repo_root" --literal-pathspecs ls-files -z --error-unmatch -- "$relative_path" 2>/dev/null
    )
    [ "${#tracked_paths[@]}" -eq 1 ] && [ "${tracked_paths[0]}" = "$relative_path" ] || return 1
    tracked=true
  else
    list_status=$?
    [ "$list_status" -eq 1 ] || return 1
    tracked=false
  fi

  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    resolved="$(realpath -e -- "$candidate" 2>/dev/null || true)"
    case "$resolved" in
    "$repo_root"/*) ;;
    *) return 1 ;;
    esac
    if [ "$tracked" = false ]; then
      if codex_git_safe -C "$repo_root" check-ignore -q -- "./$relative_path"; then
        return 1
      else
        ignore_status=$?
        [ "$ignore_status" -eq 1 ] || return 1
      fi
    fi
    return 0
  fi

  [ "$tracked" = true ] || return 1
  probe="$candidate"
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    parent="${probe%/*}"
    [ "$parent" != "$probe" ] || return 1
    probe="$parent"
  done
  [ -d "$probe" ] && [ ! -L "$probe" ] || return 1
  resolved="$(realpath -e -- "$probe" 2>/dev/null || true)"
  case "$resolved" in
  "$repo_root"|"$repo_root"/*) return 0 ;;
  *) return 1 ;;
  esac
}

# Return the one evidence directory that a declared aggregate member may use.
# The directory is deliberately separate from control records so a member's
# proof cannot be substituted from the parent session or another member.
codex_eci_aggregate_evidence_root() {
  local session_dir="$1" repo_id="$2" root session_id evidence_root

  codex_eci_aggregate_repo_id_is_valid "$repo_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_id="${session_dir##*/}"
  codex_valid_session_id "$session_id" || return 1
  [ "$session_dir" = "$root/$session_id" ] || return 1
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  evidence_root="$session_dir/eci-aggregate.$repo_id.evidence"
  codex_state_path_is_safe "$evidence_root" "$root" || return 1
  [ -d "$evidence_root" ] && [ ! -L "$evidence_root" ] || return 1
  [ "$(realpath -m -- "$evidence_root" 2>/dev/null || true)" = "$evidence_root" ] || return 1
  [ "$(realpath -e -- "$evidence_root" 2>/dev/null || true)" = "$evidence_root" ] || return 1
  printf '%s\n' "$evidence_root"
}

# Return success only for one regular, canonical evidence artifact below the
# exact namespaced root selected by an immutable aggregate plan member.
codex_eci_aggregate_evidence_artifact_is_scoped() {
  local artifact="$1" evidence_root="$2" root canonical

  root="$(codex_proof_root)"
  case "$artifact" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$artifact" in
    *[![:print:]]*|*//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  canonical="$(realpath -m -- "$artifact" 2>/dev/null || true)"
  [ "$canonical" = "$artifact" ] || return 1
  case "$artifact" in
    "$evidence_root"/*) ;;
    *) return 1 ;;
  esac
  codex_state_path_is_safe "$artifact" "$root" || return 1
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
  [ "$(realpath -e -- "$artifact" 2>/dev/null || true)" = "$artifact" ]
}

# Validate that every evidence-bearing member of an aggregate v2 manifest is
# owned by the selected member's exact namespaced evidence directory. The
# caller performs schema validation; this helper enforces path ownership even
# when copied bytes and hashes are otherwise valid.
codex_eci_aggregate_manifest_evidence_is_scoped() {
  local manifest="$1" session_dir="$2" repo_id="$3" evidence_root artifact

  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  evidence_root="$(codex_eci_aggregate_evidence_root "$session_dir" "$repo_id")" || return 1
  jq -e '
    [
      .current_diff_artifact,
      (.targets[] | .diff_artifact),
      (.rows[] | .diff_artifact),
      (.rows[] | .spawn_request_artifact),
      (.rows[] | .report_artifact),
      (.rows[] | .adjudication_artifact),
      (.rows[] | .intention_artifact),
      (.rows[] | .e2e_artifact)
    ] | length > 0 and all(.[]; . == null or type == "string")
  ' "$manifest" >/dev/null 2>&1 || return 1
  while IFS= read -r artifact; do
    codex_eci_aggregate_evidence_artifact_is_scoped "$artifact" "$evidence_root" || return 1
  done < <(jq -r '
    [
      .current_diff_artifact,
      (.targets[] | .diff_artifact),
      (.rows[] | .diff_artifact),
      (.rows[] | .spawn_request_artifact),
      (.rows[] | .report_artifact),
      (.rows[] | .adjudication_artifact),
      (.rows[] | .intention_artifact),
      (.rows[] | .e2e_artifact)
    ] | .[] | select(. != null)
  ' "$manifest")
}

# Aggregate recovery has its own namespaced proof records. Singleton lifecycle
# artifacts are local coordination residue, not competing authority: bots here
# are non-malicious and this support layer catches accidental deviation rather
# than enforcing an adversarial security boundary. Keep observing residue for
# diagnostics, but do not follow, rewrite, or block selected safe aggregate
# work because of it. The historical predicate name remains for callers.
codex_eci_aggregate_coordination_residue_seen=false
codex_eci_aggregate_normal_evidence_is_absent() {
  local session_dir="$1" path
  local nullglob_was_set=false

  codex_eci_aggregate_coordination_residue_seen=false
  shopt -q nullglob && nullglob_was_set=true
  shopt -s nullglob
  for path in \
    "$session_dir"/eci-required-critics.json* \
    "$session_dir"/eci-required-critics.* \
    "$session_dir"/eci-critic-identities.ledger* \
    "$session_dir"/eci-acceptance-anchor* \
    "$session_dir"/eci-acceptance-transaction* \
    "$session_dir"/eci-teardown-complete* \
    "$session_dir"/eci-prewrite-admitted.* \
    "$session_dir"/eci-baseline-binding* \
    "$session_dir"/baseline_head* \
    "$session_dir"/eci-commit-admitted* \
    "$session_dir"/eci-user-closed.ledger* \
    "$session_dir"/ate_nested_eci_active* \
    "$session_dir"/ate_nested_eci_completion* \
    "$session_dir"/eci_wait*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    codex_eci_aggregate_coordination_residue_seen=true
  done
  [ "$nullglob_was_set" = true ] || shopt -u nullglob
  return 0
}

# Read only the direct marker fields that establish the live current-session
# mapping. Other bytes are historical/advisory metadata: ordinary lifecycle
# work must not depend on record size, order, schema, receipt, or ownership
# ceremony. The direct final path and semantic session/CWD mapping remain the
# concrete accidental-wrong-target boundary.
codex_eci_direct_marker_cwd() {
  local marker="$1" session_id="$2" root line value marker_session='' marker_cwd=''
  local session_count=0 cwd_count=0 canonical

  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  [ "$marker" = "$root/$session_id/eci_active" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(realpath -e -- "$marker" 2>/dev/null || true)" = "$marker" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'session_id: '*)
        value="${line#session_id: }"
        if [ "$session_count" -gt 0 ] && [ "$value" != "$marker_session" ]; then
          return 1
        fi
        session_count=$((session_count + 1))
        marker_session="$value"
        ;;
      'cwd: '*)
        value="${line#cwd: }"
        canonical="$(codex_canonical_cwd "$value")"
        [ -n "$canonical" ] && [ -d "$canonical" ] && [ ! -L "$canonical" ] || return 1
        if [ "$cwd_count" -gt 0 ] && [ "$canonical" != "$marker_cwd" ]; then
          return 1
        fi
        cwd_count=$((cwd_count + 1))
        marker_cwd="$canonical"
        ;;
    esac
  done <"$marker"
  [ "$session_count" -ge 1 ] && [ "$marker_session" = "$session_id" ] || return 1
  [ "$cwd_count" -ge 1 ] && [ -n "$marker_cwd" ] || return 1
  printf '%s\n' "$marker_cwd"
}

# Aggregate lifecycle uses the same direct current-session marker mapping as
# singleton lifecycle. Keep the historical public helper name for callers.
codex_eci_aggregate_marker_cwd() {
  codex_eci_direct_marker_cwd "$@"
}

codex_eci_aggregate_marker_matches_cwd() {
  local marker="$1" session_id="$2" expected_cwd="$3" marker_cwd

  marker_cwd="$(codex_eci_aggregate_marker_cwd "$marker" "$session_id")" || return 1
  [ "$marker_cwd" = "$expected_cwd" ]
}

# Re-derive Git metadata from the selected live worktree. Stored plan copies
# are coordination residue, so only the resolved repository root and its
# actual Git topology control a mutation target.
codex_eci_aggregate_live_repo_git_dir=''
codex_eci_aggregate_live_repo_git_common_dir=''
codex_eci_aggregate_live_repo_metadata() {
  local outer_cwd="$1" repo_root="$2" actual_root git_dir_raw git_common_raw
  local actual_git_dir actual_git_common

  case "$repo_root" in /*) ;; *) return 1 ;; esac
  case "$repo_root" in *[![:print:]]*|*//*|*/./*|*/../*|*/..|*/.) return 1 ;; esac
  [ "$repo_root" = "$(realpath -m -- "$repo_root" 2>/dev/null || true)" ] || return 1
  [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || return 1
  [ "$(realpath -e -- "$repo_root" 2>/dev/null || true)" = "$repo_root" ] || return 1
  codex_eci_aggregate_repo_is_strict_descendant "$outer_cwd" "$repo_root" || return 1
  actual_root="$(codex_git_safe -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
  actual_root="$(realpath -e -- "$actual_root" 2>/dev/null || true)"
  [ "$actual_root" = "$repo_root" ] || return 1
  git_dir_raw="$(codex_git_safe -C "$repo_root" rev-parse --git-dir 2>/dev/null || true)"
  git_common_raw="$(codex_git_safe -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$git_dir_raw" in /*) actual_git_dir="$git_dir_raw" ;; *) actual_git_dir="$repo_root/$git_dir_raw" ;; esac
  case "$git_common_raw" in /*) actual_git_common="$git_common_raw" ;; *) actual_git_common="$repo_root/$git_common_raw" ;; esac
  actual_git_dir="$(realpath -e -- "$actual_git_dir" 2>/dev/null || true)"
  actual_git_common="$(realpath -e -- "$actual_git_common" 2>/dev/null || true)"
  [ -d "$actual_git_dir" ] && [ ! -L "$actual_git_dir" ] || return 1
  [ -d "$actual_git_common" ] && [ ! -L "$actual_git_common" ] || return 1
  codex_eci_aggregate_live_repo_git_dir="$actual_git_dir"
  codex_eci_aggregate_live_repo_git_common_dir="$actual_git_common"
}

# A selected aggregate child remains a real, top-level Git worktree directly
# below the marker-bound parent. When that parent is itself Git-controlled,
# its child is eligible only if the two worktrees have distinct actual common
# directories; an independently initialized nested repository is ordinary
# work, while an outer worktree or linked worktree is still the same target.
codex_eci_aggregate_selected_child_is_genuinely_independent() {
  local outer_cwd="$1" repo_root="$2" outer_inside outer_common_raw outer_common

  codex_eci_aggregate_live_repo_metadata "$outer_cwd" "$repo_root" || return 1
  outer_inside="$(codex_git_safe -C "$outer_cwd" rev-parse --is-inside-work-tree 2>/dev/null || true)"
  [ "$outer_inside" = true ] || return 0
  outer_common_raw="$(codex_git_safe -C "$outer_cwd" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$outer_common_raw" ] || return 1
  case "$outer_common_raw" in
  /*) outer_common="$outer_common_raw" ;;
  *) outer_common="$outer_cwd/$outer_common_raw" ;;
  esac
  outer_common="$(realpath -e -- "$outer_common" 2>/dev/null || true)"
  [ -d "$outer_common" ] && [ ! -L "$outer_common" ] || return 1
  [ "$codex_eci_aggregate_live_repo_git_common_dir" != "$outer_common" ]
}

# The plan is local routing residue, not an immutable authorization receipt.
# Validate only the semantic mapping needed to resolve a real, contained Git
# target; schema/order/session/hash/record-owner and copied Git fields are
# advisory and are re-derived from the current filesystem.
codex_eci_aggregate_validated_outer_cwd=''
codex_eci_aggregate_plan_is_valid() {
  local plan="$1" session_id="$2" expected_outer_cwd="${3:-}" marker="${4:-}"
  local root session_dir expected_plan plan_outer_cwd repo_count index repo_id repo_root prior
  local -a prior_roots=()

  codex_eci_aggregate_validated_outer_cwd=''
  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_dir="$root/$session_id"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  expected_plan="$session_dir/eci-aggregate-plan.json"
  [ "$plan" = "$expected_plan" ] || return 1
  [ -f "$plan" ] && [ ! -L "$plan" ] || return 1
  [ "$(realpath -e -- "$plan" 2>/dev/null || true)" = "$plan" ] || return 1
  jq -e '
    type == "object" and
    (.repositories | type == "array" and length > 0) and
    all(.repositories[];
      type == "object" and
      (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")) and
      (.repo_root | type == "string" and length > 0)) and
    (([.repositories[].id] | unique | length) == (.repositories | length))
  ' "$plan" >/dev/null 2>&1 || return 1

  if [ -n "$expected_outer_cwd" ]; then
    [ "$expected_outer_cwd" = "$(codex_canonical_cwd "$expected_outer_cwd")" ] || return 1
    plan_outer_cwd="$expected_outer_cwd"
  else
    plan_outer_cwd="$(jq -r '.outer_cwd // empty' "$plan" 2>/dev/null || true)"
    case "$plan_outer_cwd" in /*) ;; *) return 1 ;; esac
    [ "$plan_outer_cwd" = "$(codex_canonical_cwd "$plan_outer_cwd")" ] || return 1
  fi
  [ -d "$plan_outer_cwd" ] && [ ! -L "$plan_outer_cwd" ] || return 1
  if [ -n "$marker" ]; then
    [ "$marker" = "$session_dir/eci_active" ] || return 1
    codex_eci_aggregate_marker_matches_cwd "$marker" "$session_id" "$plan_outer_cwd" || return 1
  fi

  repo_count="$(jq -r '.repositories | length' "$plan" 2>/dev/null || true)"
  [[ "$repo_count" =~ ^[1-9][0-9]*$ ]] || return 1
  for ((index = 0; index < repo_count; index++)); do
    repo_id="$(jq -r ".repositories[$index].id" "$plan" 2>/dev/null || true)"
    repo_root="$(jq -r ".repositories[$index].repo_root" "$plan" 2>/dev/null || true)"
    codex_eci_aggregate_repo_id_is_valid "$repo_id" || return 1
    codex_eci_aggregate_selected_child_is_genuinely_independent "$plan_outer_cwd" "$repo_root" || return 1
    for prior in "${prior_roots[@]}"; do
      case "$repo_root" in "$prior"|"$prior"/*) return 1 ;; esac
      case "$prior" in "$repo_root"/*) return 1 ;; esac
    done
    prior_roots+=("$repo_root")
  done
  codex_eci_aggregate_validated_outer_cwd="$plan_outer_cwd"
}

# Select one validated aggregate repository without accepting a caller path.
codex_eci_aggregate_plan_select() {
  local plan="$1" session_id="$2" outer_cwd="$3" marker="$4" repo_id="$5"
  local index

  codex_eci_aggregate_repo_id_is_valid "$repo_id" || return 1
  codex_eci_aggregate_plan_is_valid "$plan" "$session_id" "$outer_cwd" "$marker" || return 1
  index="$(jq -r --arg id "$repo_id" '.repositories | map(.id) | index($id) // empty' "$plan" 2>/dev/null || true)"
  [[ "$index" =~ ^[0-9]+$ ]] || return 1
  codex_eci_aggregate_selected_id="$repo_id"
  codex_eci_aggregate_selected_root="$(jq -r ".repositories[$index].repo_root" "$plan")"
  codex_eci_aggregate_selected_child_is_genuinely_independent "$codex_eci_aggregate_validated_outer_cwd" \
    "$codex_eci_aggregate_selected_root" || return 1
  codex_eci_aggregate_selected_git_dir="$codex_eci_aggregate_live_repo_git_dir"
  codex_eci_aggregate_selected_git_common_dir="$codex_eci_aggregate_live_repo_git_common_dir"
}

# Select the single aggregate plan member that owns an arbitrary callback cwd.
# This is for boundary classification only: callers still use an explicit ID
# for every aggregate mutation. It therefore cannot become a path-to-repo
# control route.
codex_eci_aggregate_plan_select_cwd() {
  local plan="$1" session_id="$2" marker="$3" requested_cwd="$4"
  local outer_cwd canonical_cwd repo_count index repo_root match_index=""

  [ "$marker" = "$(codex_proof_root)/$session_id/eci_active" ] || return 1
  outer_cwd="$(codex_eci_aggregate_marker_cwd "$marker" "$session_id")" || return 1
  codex_eci_aggregate_plan_is_valid "$plan" "$session_id" "$outer_cwd" "$marker" || return 1
  canonical_cwd="$(codex_canonical_cwd "$requested_cwd")"
  [ -n "$canonical_cwd" ] && [ -d "$canonical_cwd" ] || return 1
  repo_count="$(jq -r '.repositories | length' "$plan" 2>/dev/null || true)"
  [[ "$repo_count" =~ ^[1-9][0-9]*$ ]] || return 1
  for ((index = 0; index < repo_count; index++)); do
    repo_root="$(jq -r ".repositories[$index].repo_root" "$plan" 2>/dev/null || true)"
    case "$canonical_cwd" in
      "$repo_root"|"$repo_root"/*)
        [ -z "$match_index" ] || return 1
        match_index="$index"
        ;;
    esac
  done
  [[ "$match_index" =~ ^[0-9]+$ ]] || return 1
  codex_eci_aggregate_selected_id="$(jq -r ".repositories[$match_index].id" "$plan")"
  codex_eci_aggregate_selected_root="$(jq -r ".repositories[$match_index].repo_root" "$plan")"
  codex_eci_aggregate_selected_child_is_genuinely_independent "$codex_eci_aggregate_validated_outer_cwd" \
    "$codex_eci_aggregate_selected_root" || return 1
  codex_eci_aggregate_selected_git_dir="$codex_eci_aggregate_live_repo_git_dir"
  codex_eci_aggregate_selected_git_common_dir="$codex_eci_aggregate_live_repo_git_common_dir"
}

# Parse the four-line active marker with shell builtins.  Stop callbacks use
# this bounded record check; avoid grep/awk/sed process fan-out on every active
# callback while retaining the same path, owner, cwd, and control-byte rules.
codex_eci_marker_metadata_is_valid() {
  local marker="$1" expected_cwd="${2:-}" root root_real marker_real dir name marker_cwd marker_owner marker_scope
  local -a lines=()

  codex_proof_root_is_safe || return 1
  root="$(codex_proof_root)"
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  root_real="$(realpath -e -- "$root" 2>/dev/null || true)"
  [ -n "$root_real" ] && [ -d "$root_real" ] || return 1
  [ ! -L "$marker" ] || return 1
  marker_real="$(realpath -e -- "$marker" 2>/dev/null || true)"
  [ -n "$marker_real" ] || return 1
  root="$root_real"
  marker="$marker_real"
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 1 ;;
  esac
  # Every reader must enforce the same finite record bound before mapfile or
  # any other line-oriented parser touches the marker.  This is deliberately
  # a cheap stat/read probe and is shared by Stop, lifecycle, discovery, and
  # refresh hooks.
  codex_eci_marker_file_is_bounded "$marker" || return 1
  codex_state_file_owner_is_valid "$marker" false || return 1
  [ "$(tail -c 1 -- "$marker" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  dir="${marker%/*}"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  name="${dir##*/}"
  if ! codex_reserved_proof_dir "$name"; then
    codex_valid_session_id "$name" || return 1
  fi
  mapfile -t lines <"$marker" || return 1
  case "${#lines[@]}" in 3|4) ;; *) return 1 ;; esac
  for line in "${lines[@]}"; do
    [[ "$line" != *[[:cntrl:]]* ]] || return 1
  done
  case "${lines[0]}" in "scope: "*) ;; *) return 1 ;; esac
  case "${lines[1]}" in "cwd: "*) ;; *) return 1 ;; esac
  case "${lines[2]}" in "session_id: "*) ;; *) return 1 ;; esac
  if [ "${#lines[@]}" -eq 4 ]; then
    case "${lines[3]}" in "created_utc: "*) ;; *) return 1 ;; esac
  fi
  marker_cwd="${lines[1]#cwd: }"
  marker_owner="${lines[2]#session_id: }"
  marker_scope="${lines[0]#scope: }"
  [ -n "$marker_scope" ] && [ -n "$marker_cwd" ] && [ "$marker_owner" = "$name" ] || return 1
  case "$marker_cwd" in /*) ;; *) return 1 ;; esac
  if [ -n "$expected_cwd" ]; then
    [ "$(codex_canonical_cwd "$marker_cwd")" = "$expected_cwd" ] || return 1
  fi
}

# Return a stable, path-free reason code for marker diagnostics.  Callers use
# this only after bounded discovery, so the code never exposes marker bytes,
# proof-root paths, or unvalidated session text to a hook consumer.
codex_eci_marker_failure_code() {
  local marker="$1" expected_cwd="${2:-}" expected_session="${3:-}"
  local root dir name marker_owner marker_cwd

  if [ ! -e "$marker" ]; then
    printf '%s\n' 'ECI_MARKER_MISSING_CURRENT'
    return 0
  fi
  root="$(codex_proof_root)"
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) printf '%s\n' 'ECI_MARKER_UNSAFE_PATH'; return 0 ;;
  esac
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    printf '%s\n' 'ECI_MARKER_UNSAFE_PATH'
    return 0
  }
  dir="${marker%/*}"
  [ -d "$dir" ] && [ ! -L "$dir" ] || {
    printf '%s\n' 'ECI_MARKER_UNSAFE_PATH'
    return 0
  }
  name="${dir##*/}"
  if ! codex_reserved_proof_dir "$name" && ! codex_valid_session_id "$name"; then
    printf '%s\n' 'ECI_MARKER_OWNERSHIP_INVALID'
    return 0
  fi
  codex_eci_marker_file_is_bounded "$marker" || {
    printf '%s\n' 'ECI_MARKER_MALFORMED'
    return 0
  }
  marker_owner="$(codex_state_value "$marker" session_id false || true)"
  marker_cwd="$(codex_state_value "$marker" cwd false || true)"
  [ -n "$marker_owner" ] && [ -n "$marker_cwd" ] || {
    printf '%s\n' 'ECI_MARKER_MALFORMED'
    return 0
  }
  [ "$marker_owner" = "$name" ] || {
    printf '%s\n' 'ECI_MARKER_OWNERSHIP_INVALID'
    return 0
  }
  codex_eci_marker_metadata_is_valid "$marker" || {
    printf '%s\n' 'ECI_MARKER_MALFORMED'
    return 0
  }
  if [ -n "$expected_session" ] && [ "$name" != "$expected_session" ]; then
    printf '%s\n' 'ECI_MARKER_SCOPE_MISMATCH'
    return 0
  fi
  if [ -n "$expected_cwd" ] &&
    ! codex_eci_marker_is_valid_for_cwd "$marker" "$expected_cwd"; then
    printf '%s\n' 'ECI_MARKER_SCOPE_MISMATCH'
    return 0
  fi
  printf '%s\n' 'ECI_MARKER_VALID'
}

# Validate the ownership encoded by a marker path without applying cwd
# ownership.  Discovery uses this before deciding whether a marker belongs to
# the current callback; a path/record mismatch is unsafe control state, not an
# inactive marker.
codex_eci_marker_path_owner_is_valid() {
  codex_eci_marker_metadata_is_valid "$1"
}

# Return only ECI markers whose path owner and embedded session_id agree.  The
# ordinary direct-session marker and the reserved legacy marker namespace are
# checked together so callers can detect duplicate active owners instead of
# returning on the first glob match.  This helper is intentionally bounded to
# one proof-root directory scan and marker metadata; it is not used for
# transcript or ledger recovery.
codex_eci_marker_is_valid_for_cwd() {
  codex_eci_marker_metadata_is_valid "$1" "$2"
}

codex_eci_markers_for_cwd() {
  local cwd="${1:-}" strict="${2:-}" expected_session="${3:-}" root canonical marker found=false
  local marker_dir marker_name marker_owner
  [ -n "$cwd" ] || return 1
  root="$(codex_proof_root)"
  if ! codex_proof_root_is_safe; then
    printf '%s\n' "$codex_eci_marker_scan_unsafe_token"
    return 0
  fi
  [ -d "$root" ] || return 1
  canonical="$(codex_canonical_cwd "$cwd")"
  while IFS= read -r marker; do
    if [ "$marker" = "$codex_eci_marker_scan_overflow_token" ] ||
      [ "$marker" = "$codex_eci_marker_scan_unsafe_token" ]; then
      printf '%s\n' "$marker"
      return 0
    fi
    # A valid marker from another session may share this cwd.  It is not
    # evidence of activity for a typed session-scoped callback; filter it by
    # path identity before validating/returning the candidate.  The empty
    # expectation deliberately retains the broad legacy discovery behavior.
    codex_eci_marker_path_session_matches "$marker" "$expected_session" || continue
    # In strict discovery, surface path/owner corruption instead of silently
    # dropping it.  Callers can then fail closed without adding recovery I/O.
    if ! codex_eci_marker_path_owner_is_valid "$marker"; then
      if [ "$strict" = strict ]; then
        marker_dir="${marker%/*}"
        marker_name="${marker_dir##*/}"
        marker_owner="$(codex_state_value "$marker" session_id false || true)"
        # A typed caller is interested in its own malformed direct marker.
        # Do not let an unrelated stale session poison every current session;
        # valid same-cwd owners still remain visible and fail closed as
        # duplicate ownership below.
        # Any existing marker that fails strict metadata validation is unsafe
        # control state.  Do not silently turn malformed session IDs or
        # malformed records into inactivity.
        printf '%s\n' "$marker"
        found=true
      fi
      continue
    fi
    if codex_eci_marker_is_valid_for_cwd "$marker" "$canonical"; then
      printf '%s\n' "$marker"
      found=true
    fi
  done < <(codex_eci_marker_candidates_bounded)
  [ "$found" = true ]
}

codex_legacy_eci_markers_for_cwd() {
  local cwd="${1:-}" expected_session="${2:-}"
  local root marker dir name marker_cwd marker_owner line_count legacy_scope_line
  local canonical_cwd canonical_marker_cwd found=false
  local -a legacy_dirs=(
    activity audit eci history pre-reviewer reviewer reviewer-dumps
    side-stop skip-stop skills
  )

  [ -n "$cwd" ] || return 1
  root="$(codex_proof_root)"
  if ! codex_proof_root_is_safe; then
    printf '%s\n' "$codex_eci_marker_scan_unsafe_token"
    return 0
  fi
  [ -d "$root" ] || return 1
  canonical_cwd="$(codex_canonical_cwd "$cwd")"

  # Legacy markers are only authoritative in reserved proof directories.
  # Probe those fixed paths directly instead of expanding every proof-root
  # child on the active Stop path.  This keeps a large set of ordinary
  # session-like directories from turning a no-marker callback into a scan.
  for name in "${legacy_dirs[@]}"; do
    marker="$root/$name/eci_active"
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    codex_eci_marker_file_is_bounded "$marker" || continue
    [ "$(tail -c 1 -- "$marker" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || continue
    dir="${marker%/*}"
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    name="${dir##*/}"
    codex_reserved_proof_dir "$name" || continue
    if [ -n "$expected_session" ]; then
      # Legacy markers live in reserved directories rather than under a
      # session-named path. Bind a typed query to the marker's embedded owner
      # so an unrelated same-cwd session cannot become its active owner.
      marker_owner="$(codex_state_value "$marker" session_id false || true)"
      [ "$marker_owner" = "$expected_session" ] || continue
    fi
    # Newline is the record separator; every other C0/DEL byte makes the
    # legacy marker malformed and therefore ineligible for control flow.
    LC_ALL=C grep -q '[[:cntrl:]]' "$marker" 2>/dev/null && continue
    line_count="$(awk 'END { print NR + 0 }' "$marker" 2>/dev/null || printf '0')"
    case "$line_count" in
      3|4) ;;
      *) continue ;;
    esac
    legacy_scope_line="$(sed -n '1p' "$marker" 2>/dev/null || true)"
    case "$legacy_scope_line" in
      "scope: "*) [ -n "${legacy_scope_line#scope: }" ] || continue ;;
      *) continue ;;
    esac
    case "$(sed -n '2p' "$marker" 2>/dev/null || true)" in
      "cwd: "*) ;;
      *) continue ;;
    esac
    case "$(sed -n '3p' "$marker" 2>/dev/null || true)" in
      "session_id: "*) ;;
      *) continue ;;
    esac
    if [ "$line_count" -eq 4 ]; then
      case "$(sed -n '4p' "$marker" 2>/dev/null || true)" in
        "created_utc: "*) ;;
        *) continue ;;
      esac
    fi
    marker_cwd="$(codex_state_value "$marker" cwd false || true)"
    [ -n "$marker_cwd" ] || continue
    marker_owner="$(codex_state_value "$marker" session_id false || true)"
    [ "$marker_owner" = "$name" ] || continue
    canonical_marker_cwd="$(codex_canonical_cwd "$marker_cwd")"
    [ "$canonical_marker_cwd" = "$canonical_cwd" ] || continue
    printf '%s\n' "$marker"
    found=true
  done

  [ "$found" = true ]
}

codex_side_stop_applies_to_session() {
  local file="$1"
  local session_id="$2"
  local command parent_session_id

  [ -f "$file" ] || return 1
  command="$(codex_state_value "$file" command || true)"
  [ "$command" = "/side" ] || return 1

  parent_session_id="$(codex_state_value "$file" parent_session_id || true)"
  if codex_valid_session_id "$parent_session_id"; then
    [ "$parent_session_id" != "$session_id" ]
    return
  fi

  return 0
}

codex_state_file_is_session_scoped() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local file="$4"
  local expected

  expected="$(codex_session_state_dir "$kind" "$session_id" 2>/dev/null || true)"
  [ -n "$expected" ] && [ "$file" = "$expected/$filename" ]
}

codex_side_stop_is_active_for_session() {
  local file="$1"
  local session_id="$2"

  [ -n "$file" ] && [ -f "$file" ] || return 1
  codex_side_stop_applies_to_session "$file" "$session_id" || return 1

  if codex_state_file_is_session_scoped side-stop side_stop "$session_id" "$file"; then
    return 0
  fi

  [ -n "$(find "$file" -mmin -60 -print 2>/dev/null)" ]
}

codex_bind_side_stop_to_session() {
  local file="$1"
  local session_id="$2"
  local dir

  [ -f "$file" ] || return 1
  dir="$(codex_session_state_dir side-stop "$session_id")" || return 1
  mkdir -p "$dir" || return 1
  cp "$file" "$dir/side_stop"
}

codex_hook_sessions_root() {
  local root

  root="$(codex_home_lexical_root)" || return 1
  printf '%s/sessions\n' "$root"
}

codex_hook_transcript_first_record() {
  local input="${1:-}"
  local sessions_root first_record

  sessions_root="$(codex_hook_sessions_root)" || return 1
  first_record="$(printf '%s' "$input" | \
    python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
      hook-transcript-first-record "$sessions_root" 2>/dev/null)" || return 1
  printf '%s\n' "$first_record"
}

codex_hook_thread_spawn_metadata() {
  local input="${1:-}"
  local sessions_root metadata

  sessions_root="$(codex_hook_sessions_root)" || return 1
  metadata="$(printf '%s' "$input" | \
    python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
      hook-transcript-thread-spawn-metadata "$sessions_root" 2>/dev/null)" || return 1
  printf '%s\n' "$metadata"
}

codex_hook_is_subagent_context() {
  local input="${1:-}"
  local metadata

  metadata="$(codex_hook_thread_spawn_metadata "$input")" || return 1
  printf '%s' "$metadata" | jq -e 'has("parent_thread_id")' >/dev/null 2>&1
}

codex_hook_transcript_first_record_is_admissible() {
  local input="${1:-}"

  codex_hook_transcript_first_record "$input" >/dev/null
}

codex_hook_parent_session_id() {
  local input="${1:-}"
  local metadata

  metadata="$(codex_hook_thread_spawn_metadata "$input")" || return 1
  printf '%s' "$metadata" | jq -r '.parent_thread_id // empty' 2>/dev/null
}

codex_path_owner_session_id() {
  local path="$1"
  local root default_root rest sid base alias_session_id

  [ -n "$path" ] || return 1

  root="$(codex_proof_root)"
  default_root="$HOME/.cache/codex-proof"
  for root in "$root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        codex_reserved_proof_dir "$sid" && return 1
        if ! codex_real_session_dir_name "$sid"; then
          alias_session_id="$(codex_proof_alias_session_id "$root/$sid" 2>/dev/null || true)"
          if [ -n "$alias_session_id" ]; then
            printf '%s\n' "$alias_session_id"
            return 0
          fi
        fi
        codex_valid_session_id "$sid" || return 1
        printf '%s\n' "$sid"
        return 0
        ;;
    esac
  done

  case "$path" in
    "$HOME/.codex/sessions/"*.jsonl)
      base="${path##*/}"
      sid="$(printf '%s\n' "$base" | sed -nE 's/^rollout-[0-9T:-]+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/\1/p')"
      if codex_valid_session_id "$sid"; then
        printf '%s\n' "$sid"
        return 0
      fi
      ;;
  esac

  return 1
}

codex_hook_allowed_session_ids() {
  local input="$1"
  local session_id parent_session_id

  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if codex_valid_session_id "$session_id"; then
    printf '%s\n' "$session_id"
  fi

  parent_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
  if codex_valid_session_id "$parent_session_id" && [ "$parent_session_id" != "$session_id" ]; then
    printf '%s\n' "$parent_session_id"
  fi
}

codex_session_owner_allowed() {
  local owner="$1"
  local allowed
  shift

  for allowed in "$@"; do
    [ "$owner" = "$allowed" ] && return 0
  done
  return 1
}

codex_remove_session_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local dir
  dir="$(codex_session_state_dir "$kind" "$session_id")" || return 0
  rm -f "$dir/$filename"
}

codex_remove_cwd_state_file() {
  local kind="$1"
  local filename="$2"
  local cwd="${3:-$PWD}"
  local dir
  dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 0
  rm -f "$dir/$filename"
}

codex_markdown_section_has_body() {
  local file="$1"
  local target="$2"

  awk -v target="$target" '
    BEGIN { target = tolower(target) }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]*/ {
      heading = $0
      sub(/^##[[:space:]]*/, "", heading)
      heading = tolower(trim(heading))
      if (in_section) exit
      if (heading == target) {
        in_section = 1
        next
      }
    }
    in_section {
      line = trim($0)
      if (line != "") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

codex_eci_terminal_verdict_error() {
  local subject="$1"
  local file="$2"
  local counts accepted retired

  counts="$(awk '
    {
      line = tolower($0)
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])(clean-pass|user-closed):/)) {
        accepted++
        scan = substr(scan, RSTART + RLENGTH)
      }
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])hard-escalation:/)) {
        retired++
        scan = substr(scan, RSTART + RLENGTH)
      }
    }
    END { print accepted + 0, retired + 0 }
  ' "$file")"
  read -r accepted retired <<EOF
$counts
EOF

  if [ "${retired:-0}" -ne 0 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:, and must not include retired marker hard-escalation:. Report a blocker requiring user input while ECI remains active.\n' "$subject"
  elif [ "${accepted:-0}" -ne 1 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:.\n' "$subject"
  fi
}

# A successful `eci-active off` publishes this small terminal receipt before
# removing the active marker.  Final-proof consumption validates the receipt
# against the still-present manifest and disengage report; it is deliberately
# outside the active Stop fast path.
codex_eci_teardown_report_path_is_safe() {
  local report_path="$1" canonical parent rest part

  case "$report_path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$report_path" in
    *[![:print:]]*|*//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  canonical="$(realpath -m -- "$report_path" 2>/dev/null || true)"
  [ "$canonical" = "$report_path" ] || return 1
  rest="${report_path#/}"; parent="/"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    [ -n "$part" ] || return 1
    parent="$parent$part"
    [ ! -L "$parent" ] || return 1
    if [ "$rest" = "$part" ]; then
      rest=""
    else
      parent="$parent/"
      rest="${rest#*/}"
    fi
  done
  [ -f "$report_path" ] && [ ! -L "$report_path" ]
}

# A successful coordinator review-gate commit admission publishes this bounded
# receipt before returning to the normal direct `git commit` call.  The
# receipt is deliberately tied to the immutable manifest/anchor and the live
# repository tuple; a stale receipt cannot authorize a later snapshot.
codex_eci_commit_admission_receipt_is_valid() {
  local receipt="$1" session_id="$2" manifest="$3"
  local root session_dir expected_receipt anchor manifest_sha repo_binding anchor_sha acceptance_version
  local receipt_bytes anchor_bytes actual
  local -a lines=()

  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_dir="$root/$session_id"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  expected_receipt="$session_dir/eci-commit-admitted"
  [ "$receipt" = "$expected_receipt" ] || return 1
  manifest="$session_dir/eci-required-critics.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  [ "$(realpath -m -- "$receipt" 2>/dev/null || true)" = "$receipt" ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  receipt_bytes="$(wc -c <"$receipt" 2>/dev/null || true)"
  case "$receipt_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$receipt_bytes" -le 4096 ] || return 1
  [ "$(tail -c 1 -- "$receipt" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$receipt" 2>/dev/null && return 1 || true
  mapfile -t lines <"$receipt" || return 1
  [ "${#lines[@]}" -eq 8 ] || return 1
  [ "${lines[0]}" = 'schema: eci-commit-admission/v1' ] || return 1
  [ "${lines[1]}" = "session_id: $session_id" ] || return 1
  [ "${lines[2]}" = 'phase: commit' ] || return 1
  [[ "${lines[3]}" == acceptance_version:\ * ]] || return 1
  [[ "${lines[4]}" == manifest_sha256:\ * ]] || return 1
  [[ "${lines[5]}" == repo_binding_sha256:\ * ]] || return 1
  [[ "${lines[6]}" == anchor_sha256:\ * ]] || return 1
  [ "${lines[7]}" = 'state: admitted' ] || return 1
  acceptance_version="${lines[3]#acceptance_version: }"
  manifest_sha="${lines[4]#manifest_sha256: }"
  repo_binding="${lines[5]#repo_binding_sha256: }"
  anchor_sha="${lines[6]#anchor_sha256: }"
  [[ "$acceptance_version" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$repo_binding" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$anchor_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$manifest_sha" ] || return 1
  [ "$(jq -r '.acceptance_version // empty' "$manifest" 2>/dev/null || true)" = "$acceptance_version" ] || return 1

  anchor="$session_dir/eci-acceptance-anchor"
  [ -f "$anchor" ] && [ ! -L "$anchor" ] || return 1
  [ "$(realpath -m -- "$anchor" 2>/dev/null || true)" = "$anchor" ] || return 1
  anchor_bytes="$(wc -c <"$anchor" 2>/dev/null || true)"
  case "$anchor_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$anchor_bytes" -le 16384 ] || return 1
  [ "$(tail -c 1 -- "$anchor" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$anchor" 2>/dev/null && return 1 || true
  actual="$(sha256sum -- "$anchor" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$anchor_sha" ] || return 1
  grep -Fq "admission:commit:$acceptance_version:$manifest_sha:" "$anchor" 2>/dev/null || return 1

  actual="$(codex_eci_live_repo_binding_sha256 "$manifest" 2>/dev/null || true)"
  [ "$actual" = "$repo_binding" ] || return 1
}

codex_eci_teardown_receipt_is_valid() {
  local receipt="$1" session_id="$2" manifest="$3"
  local expected_report_path="${4:-}" expected_report_sha="${5:-}" expected_binding="${6:-}"
  local root session_dir expected_receipt manifest_sha report_sha report_path repo_binding
  local actual
  local receipt_bytes
  local -a lines=()

  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_dir="$root/$session_id"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  expected_receipt="$session_dir/eci-teardown-complete"
  [ "$receipt" = "$expected_receipt" ] || return 1
  [ "$manifest" = "$session_dir/eci-required-critics.json" ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  receipt_bytes="$(wc -c <"$receipt" 2>/dev/null || true)"
  case "$receipt_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$receipt_bytes" -le 4096 ] || return 1
  [ "$(tail -c 1 -- "$receipt" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$receipt" 2>/dev/null && return 1 || true
  mapfile -t lines <"$receipt" || return 1
  [ "${#lines[@]}" -eq 7 ] || return 1
  [ "${lines[0]}" = 'schema: eci-teardown-complete/v1' ] || return 1
  [ "${lines[1]}" = "session_id: $session_id" ] || return 1
  [[ "${lines[2]}" == manifest_sha256:\ * ]] || return 1
  [[ "${lines[3]}" == disengage_report_path:\ * ]] || return 1
  [[ "${lines[4]}" == disengage_report_sha256:\ * ]] || return 1
  [[ "${lines[5]}" == repo_binding_sha256:\ * ]] || return 1
  [ "${lines[6]}" = 'state: complete' ] || return 1
  manifest_sha="${lines[2]#manifest_sha256: }"
  report_path="${lines[3]#disengage_report_path: }"
  report_sha="${lines[4]#disengage_report_sha256: }"
  repo_binding="${lines[5]#repo_binding_sha256: }"
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$report_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$repo_binding" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ -z "$expected_report_path" ] || [ "$report_path" = "$expected_report_path" ] || return 1
  [ -z "$expected_report_sha" ] || [ "$report_sha" = "$expected_report_sha" ] || return 1
  [ -z "$expected_binding" ] || [ "$repo_binding" = "$expected_binding" ] || return 1
  codex_eci_teardown_report_path_is_safe "$report_path" || return 1
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  actual="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$manifest_sha" ] || return 1
  actual="$(sha256sum -- "$report_path" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$report_sha" ] || return 1
  actual="$(codex_eci_live_repo_binding_sha256 "$manifest" 2>/dev/null || true)"
  [ "$actual" = "$repo_binding" ] || return 1
}

# Validate the one terminal receipt for a parent aggregate session.  It binds
# every immutable plan member to the exact namespaced v2 manifest and current
# live Git tuple that the aggregate off operation validated before marker
# removal.
codex_eci_aggregate_teardown_receipt_is_valid() {
  local receipt="$1" session_id="$2"
  local root session_dir expected_receipt plan receipt_bytes top_keys repo_keys plan_sha actual
  local report_path report_sha repo_count index repo_id manifest_sha repo_binding manifest

  codex_valid_session_id "$session_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_dir="$root/$session_id"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  expected_receipt="$session_dir/eci-aggregate-teardown-complete"
  [ "$receipt" = "$expected_receipt" ] || return 1
  codex_state_file_owner_is_valid "$receipt" || return 1
  receipt_bytes="$(wc -c <"$receipt" 2>/dev/null || true)"
  case "$receipt_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$receipt_bytes" -le 16384 ] || return 1
  [ "$(tail -c 1 -- "$receipt" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$receipt" 2>/dev/null && return 1 || true
  [ "$(awk 'END { print NR + 0 }' "$receipt" 2>/dev/null || printf 0)" -eq 1 ] || return 1
  jq -e . "$receipt" >/dev/null 2>&1 || return 1
  jq -c . "$receipt" | cmp -s - "$receipt" || return 1
  top_keys='["schema","session_id","plan_sha256","disengage_report_path","disengage_report_sha256","repositories","state"]'
  repo_keys='["id","manifest_sha256","repo_binding_sha256"]'
  jq -e --argjson expected "$top_keys" --argjson repo_expected "$repo_keys" --arg sid "$session_id" '
    (keys_unsorted == $expected) and
    (.schema == "eci-aggregate-teardown-complete/v1") and
    (.session_id == $sid) and
    (.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.disengage_report_path | type == "string") and
    (.disengage_report_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.repositories | type == "array" and length > 0 and length <= 16) and
    all(.repositories[];
      (keys_unsorted == $repo_expected) and
      (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")) and
      (.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.repo_binding_sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    ([.repositories[].id] == ([.repositories[].id] | sort)) and
    (([.repositories[].id] | unique | length) == (.repositories | length)) and
    (.state == "complete")
  ' "$receipt" >/dev/null 2>&1 || return 1
  plan="$session_dir/eci-aggregate-plan.json"
  codex_eci_aggregate_plan_is_valid "$plan" "$session_id" || return 1
  plan_sha="$(jq -r '.plan_sha256' "$receipt")"
  actual="$(sha256sum -- "$plan" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$plan_sha" ] || return 1
  report_path="$(jq -r '.disengage_report_path' "$receipt")"
  report_sha="$(jq -r '.disengage_report_sha256' "$receipt")"
  codex_eci_teardown_report_path_is_safe "$report_path" || return 1
  actual="$(sha256sum -- "$report_path" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$report_sha" ] || return 1
  repo_count="$(jq -r '.repositories | length' "$receipt" 2>/dev/null || true)"
  [ "$repo_count" = "$(jq -r '.repositories | length' "$plan" 2>/dev/null || true)" ] || return 1
  for ((index = 0; index < repo_count; index++)); do
    repo_id="$(jq -r ".repositories[$index].id" "$receipt" 2>/dev/null || true)"
    [ "$repo_id" = "$(jq -r ".repositories[$index].id" "$plan" 2>/dev/null || true)" ] || return 1
    manifest_sha="$(jq -r ".repositories[$index].manifest_sha256" "$receipt" 2>/dev/null || true)"
    repo_binding="$(jq -r ".repositories[$index].repo_binding_sha256" "$receipt" 2>/dev/null || true)"
    manifest="$session_dir/eci-aggregate.$repo_id.required-critics.json"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    actual="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
    [ "$actual" = "$manifest_sha" ] || return 1
    actual="$(codex_eci_live_repo_binding_sha256 "$manifest" 2>/dev/null || true)"
    [ "$actual" = "$repo_binding" ] || return 1
  done
}

# Read the exact tree and parent captured by one aggregate commit anchor.
# Receipt publication and Git execution consume these values instead of
# calculating a new tree after review has already completed.
codex_eci_aggregate_commit_anchor_tree_is_valid() {
  local anchor="$1" session_id="$2" repo_id="$3" manifest="$4"
  local repo_root="$5" git_dir="$6" git_common_dir="$7"
  local version manifest_sha base bytes anchor_index anchor_line
  local prefix phase anchor_version anchor_manifest anchor_diff anchor_targets anchor_binding anchor_identity
  local anchor_ledger anchor_identity_admission tree_oid parent_oid extra matches=0
  local -a lines=()

  codex_valid_session_id "$session_id" || return 1
  codex_eci_aggregate_repo_id_is_valid "$repo_id" || return 1
  [ "$anchor" = "$(codex_proof_root)/$session_id/eci-aggregate.$repo_id.acceptance-anchor" ] || return 1
  [ -f "$anchor" ] && [ ! -L "$anchor" ] || return 1
  codex_state_file_owner_is_valid "$anchor" || return 1
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  version="$(jq -r '.acceptance_version // empty' "$manifest" 2>/dev/null || true)"
  manifest_sha="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
  base="$(jq -r '.base_oid // empty' "$manifest" 2>/dev/null || true)"
  [[ "$version" =~ ^[1-9][0-9]*$ && "$manifest_sha" =~ ^[0-9a-f]{64}$ && "$base" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  bytes="$(wc -c <"$anchor" 2>/dev/null || true)"
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 16384 ] || return 1
  [ "$(tail -c 1 -- "$anchor" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$anchor" 2>/dev/null && return 1 || true
  mapfile -t lines <"$anchor" || return 1
  [ "${#lines[@]}" -ge 7 ] || return 1
  [ "${lines[0]}" = 'schema: eci-acceptance-anchor/v1' ] || return 1
  [ "${lines[1]}" = "session_id: $session_id" ] || return 1
  [ "${lines[2]}" = "repo_root: $repo_root" ] || return 1
  [ "${lines[3]}" = "git_dir: $git_dir" ] || return 1
  [ "${lines[4]}" = "git_common_dir: $git_common_dir" ] || return 1
  [ "${lines[5]}" = "base_oid: $base" ] || return 1
  for ((anchor_index = 6; anchor_index < ${#lines[@]}; anchor_index++)); do
    anchor_line="${lines[$anchor_index]}"
    IFS=: read -r prefix phase anchor_version anchor_manifest anchor_diff anchor_targets anchor_binding anchor_identity \
      anchor_ledger anchor_identity_admission tree_oid parent_oid extra <<<"$anchor_line"
    [ "$prefix" = admission ] && [ "$phase" = commit ] || continue
    [ "$anchor_version" = "$version" ] && [ "$anchor_manifest" = "$manifest_sha" ] || continue
    [[ "$anchor_diff" =~ ^[0-9a-f]{64}$ && "$anchor_targets" =~ ^[0-9a-f]{64}$ && "$anchor_binding" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$anchor_identity" =~ ^[0-9a-f]{64}$ && "$anchor_ledger" =~ ^[0-9a-f]{64}$ && "$anchor_identity_admission" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$tree_oid" =~ ^[0-9a-f]{40,64}$ && "$parent_oid" =~ ^[0-9a-f]{40,64}$ && -z "${extra:-}" ]] || return 1
    [ "$parent_oid" = "$(jq -r '.head_oid // empty' "$manifest" 2>/dev/null || true)" ] || return 1
    codex_git_safe -C "$repo_root" cat-file -e "$tree_oid^{tree}" >/dev/null 2>&1 || return 1
    matches=$((matches + 1))
    codex_eci_aggregate_commit_anchor_tree_oid="$tree_oid"
    codex_eci_aggregate_commit_anchor_parent_oid="$parent_oid"
  done
  [ "$matches" -eq 1 ]
}

# Validate the short-lived per-member aggregate commit admission. Unlike the
# singleton receipt, this state is never consumed by an arbitrary `git commit`:
# the aggregate lifecycle command owns the exact Git invocation under its lock.
codex_eci_aggregate_commit_admission_receipt_is_valid() {
  local receipt="$1" session_id="$2" repo_id="$3" message_source="$4"
  local root session_dir plan manifest anchor version expected bytes top_keys manifest_sha
  local binding anchor_sha message_sha actual tree_oid parent_oid ref_name ref_oid

  codex_valid_session_id "$session_id" || return 1
  codex_eci_aggregate_repo_id_is_valid "$repo_id" || return 1
  root="$(codex_proof_root)"
  codex_proof_root_is_safe || return 1
  session_dir="$root/$session_id"
  codex_session_dir_is_safe "$root" "$session_id" || return 1
  plan="$session_dir/eci-aggregate-plan.json"
  codex_eci_aggregate_plan_is_valid "$plan" "$session_id" || return 1
  manifest="$session_dir/eci-aggregate.$repo_id.required-critics.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  version="$(jq -r '.acceptance_version // empty' "$manifest" 2>/dev/null || true)"
  [[ "$version" =~ ^[1-9][0-9]*$ ]] || return 1
  expected="$session_dir/eci-aggregate.$repo_id.commit-admitted.$version"
  [ "$receipt" = "$expected" ] || return 1
  codex_state_file_owner_is_valid "$receipt" || return 1
  bytes="$(wc -c <"$receipt" 2>/dev/null || true)"
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 4096 ] || return 1
  [ "$(tail -c 1 -- "$receipt" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  LC_ALL=C grep -q $'\r' "$receipt" 2>/dev/null && return 1 || true
  [ "$(awk 'END { print NR + 0 }' "$receipt" 2>/dev/null || printf 0)" -eq 1 ] || return 1
  jq -e . "$receipt" >/dev/null 2>&1 || return 1
  jq -c . "$receipt" | cmp -s - "$receipt" || return 1
  top_keys='["schema","session_id","repository_id","acceptance_version","manifest_sha256","repo_binding_sha256","anchor_sha256","message_sha256","tree_oid","parent_oid","ref_name","state"]'
  jq -e --argjson expected "$top_keys" --arg sid "$session_id" --arg id "$repo_id" --arg version "$version" '
    (keys_unsorted == $expected) and
    (.schema == "eci-aggregate-commit-admission/v2") and
    (.session_id == $sid) and (.repository_id == $id) and
    (.acceptance_version == $version) and
    (.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.repo_binding_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.anchor_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.message_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.tree_oid | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.parent_oid | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.ref_name | type == "string" and startswith("refs/heads/")) and
    (.state == "admitted")
  ' "$receipt" >/dev/null 2>&1 || return 1
  codex_eci_aggregate_plan_select "$plan" "$session_id" "" "" "$repo_id" || return 1
  jq -e --arg root "$codex_eci_aggregate_selected_root" --arg git_dir "$codex_eci_aggregate_selected_git_dir" --arg git_common "$codex_eci_aggregate_selected_git_common_dir" '
    .repo_root == $root and .git_dir == $git_dir and .git_common_dir == $git_common and
    all(.rows[]; .repo_root == $root and .git_dir == $git_dir and .git_common_dir == $git_common)
  ' "$manifest" >/dev/null 2>&1 || return 1
  anchor="$session_dir/eci-aggregate.$repo_id.acceptance-anchor"
  codex_state_file_owner_is_valid "$anchor" || return 1
  codex_eci_aggregate_commit_anchor_tree_is_valid "$anchor" "$session_id" "$repo_id" "$manifest" \
    "$codex_eci_aggregate_selected_root" "$codex_eci_aggregate_selected_git_dir" "$codex_eci_aggregate_selected_git_common_dir" || return 1
  [ -f "$message_source" ] && [ ! -L "$message_source" ] || return 1
  manifest_sha="$(sha256sum -- "$manifest" 2>/dev/null | awk '{print $1}')"
  binding="$(codex_eci_live_repo_binding_sha256 "$manifest" 2>/dev/null || true)"
  anchor_sha="$(sha256sum -- "$anchor" 2>/dev/null | awk '{print $1}')"
  message_sha="$(sha256sum -- "$message_source" 2>/dev/null | awk '{print $1}')"
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ && "$binding" =~ ^[0-9a-f]{64}$ &&
    "$anchor_sha" =~ ^[0-9a-f]{64}$ && "$message_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$(jq -r '.manifest_sha256' "$receipt")" = "$manifest_sha" ] || return 1
  [ "$(jq -r '.repo_binding_sha256' "$receipt")" = "$binding" ] || return 1
  [ "$(jq -r '.anchor_sha256' "$receipt")" = "$anchor_sha" ] || return 1
  [ "$(jq -r '.message_sha256' "$receipt")" = "$message_sha" ] || return 1
  tree_oid="$(jq -r '.tree_oid' "$receipt")"
  parent_oid="$(jq -r '.parent_oid' "$receipt")"
  ref_name="$(jq -r '.ref_name' "$receipt")"
  [ "$tree_oid" = "$codex_eci_aggregate_commit_anchor_tree_oid" ] || return 1
  [ "$parent_oid" = "$codex_eci_aggregate_commit_anchor_parent_oid" ] || return 1
  codex_git_safe -C "$codex_eci_aggregate_selected_root" check-ref-format "$ref_name" >/dev/null 2>&1 || return 1
  ref_oid="$(codex_git_safe -C "$codex_eci_aggregate_selected_root" rev-parse --verify "$ref_name^{commit}" 2>/dev/null || true)"
  [ "$ref_oid" = "$parent_oid" ]
}
