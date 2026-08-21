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
codex_eci_marker_scan_max_root_entries=64
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

# Enumerate only a finite number of immediate proof-root entries.  Callers
# treat the overflow token as unsafe control state; no active Stop path should
# walk an unbounded set of unrelated session-like directories.
codex_eci_marker_candidates_bounded() {
  local root entry marker count=0

  root="$(codex_proof_root)"
  if ! codex_proof_root_is_safe; then
    printf '%s\n' "$codex_eci_marker_scan_unsafe_token"
    return 0
  fi
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' entry; do
    count=$((count + 1))
    if [ "$count" -gt "$codex_eci_marker_scan_max_root_entries" ]; then
      printf '%s\n' "$codex_eci_marker_scan_overflow_token"
      return 0
    fi
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    marker="$entry/eci_active"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      printf '%s\n' "$marker"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
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
  if command -v python3 >/dev/null 2>&1; then
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
    eci_active|eci_active.*|goal_state|goal_state.*|eci_wait|eci_wait.*|eci_user_owned_wait.md|eci_user_owned_wait.md.*|eci-required-critics.json|eci-required-critics.json.*|eci-required-critics.*|eci-critic-identities.ledger|eci-critic-identities.ledger.*|eci-acceptance-anchor|eci-acceptance-anchor.*|eci-acceptance-transaction|eci-acceptance-transaction.*|eci-teardown-complete|eci-teardown-complete.*|eci-prewrite-admitted.*|eci-baseline-binding|eci-baseline-binding.*|baseline_head|baseline_head.*|eci-commit-admitted|eci-commit-admitted.*|eci-user-closed.ledger|eci-user-closed.ledger.*|ate_nested_eci_active|ate_nested_eci_active.*|ate_nested_eci_completion|ate_nested_eci_completion.*|eci-blocker-report.md|stop_timestamps|stop_loop_state|stop_loop_state.*|disengage.md|user-closed.md|proof.md|instructions.md|project-understanding.md|project-understanding.md.*|high_level_log.md|high_level_log.md.*|latest-status-report.md|latest-status-report.md.*|high_level_log.anchor|high_level_log.anchor.*|high_level_log.md.tmp.*)
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
  local actual_root default_root root rest sid filename

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
    printf '%s' "${1:-}" | sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "${1:-}" | python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    return 1
  fi
}

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
  # Proof/control records are authoritative state.  Read only a regular,
  # owner-owned, single-link file so a hardlink alias cannot make a reader
  # consume bytes published through an unrelated path.  This also rejects a
  # symlink final component before awk opens it.
  codex_state_file_owner_is_valid "$file" || return 1
  awk -F':[[:space:]]*' -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

codex_state_file_owner_is_valid() {
  local file="$1" owner links expected
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  expected="${EUID:-$(id -u 2>/dev/null || printf '%s' -1)}"
  read -r owner links < <(stat -Lc '%u %h' -- "$file" 2>/dev/null) || return 1
  [ "$owner" = "$expected" ] && [ "$links" = 1 ]
}

# Parse the four-line active marker with shell builtins.  Stop callbacks use
# this bounded record check; avoid grep/awk/sed process fan-out on every active
# callback while retaining the same path, owner, cwd, and control-byte rules.
codex_eci_marker_metadata_is_valid() {
  local marker="$1" expected_cwd="${2:-}" root dir name marker_cwd marker_owner marker_scope
  local -a lines=()

  root="$(codex_proof_root)"
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 1 ;;
  esac
  # Every reader must enforce the same finite record bound before mapfile or
  # any other line-oriented parser touches the marker.  This is deliberately
  # a cheap stat/read probe and is shared by Stop, lifecycle, discovery, and
  # refresh hooks.
  codex_eci_marker_file_is_bounded "$marker" || return 1
  codex_state_file_owner_is_valid "$marker" || return 1
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
  marker_owner="$(codex_state_value "$marker" session_id || true)"
  marker_cwd="$(codex_state_value "$marker" cwd || true)"
  [ -n "$marker_owner" ] && [ "$marker_owner" = "$name" ] || {
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
        marker_owner="$(codex_state_value "$marker" session_id || true)"
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
    codex_eci_marker_path_session_matches "$marker" "$expected_session" || continue
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
    marker_cwd="$(codex_state_value "$marker" cwd || true)"
    [ -n "$marker_cwd" ] || continue
    marker_owner="$(codex_state_value "$marker" session_id || true)"
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
  local configured_root="${CODEX_HOME:-$HOME/.codex}"

  case "$configured_root" in
    /*) printf '%s/sessions\n' "$configured_root" ;;
    *) return 1 ;;
  esac
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
