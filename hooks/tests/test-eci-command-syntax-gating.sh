#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-command-syntax.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export XDG_CONFIG_HOME="$TMP_ROOT/xdg-config"
export XDG_STATE_HOME="$TMP_ROOT/xdg-state"
mkdir -p "$XDG_CONFIG_HOME/eci"
chmod 700 "$XDG_CONFIG_HOME" "$XDG_CONFIG_HOME/eci"
printf '%s\n' enforcing >"$XDG_CONFIG_HOME/eci/command-gate-mode"
chmod 600 "$XDG_CONFIG_HOME/eci/command-gate-mode"

run_hook() {
  local hook proof_root session_id command output
  hook="$1"
  proof_root="$2"
  session_id="$3"
  command="$4"
  output="$5"
  jq -cn --arg cwd "$ROOT" --arg session_id "$session_id" --arg command "$command" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" KIMI_PROOF_ROOT="$proof_root" \
      CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$hook" >"$output"
}

run_cleanup_hook() {
  local hook command output
  hook="$1"
  command="$2"
  output="$3"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"cleanup-syntax",cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$cleanup_home" CODEX_PROOF_ROOT="$cleanup_proof" KIMI_PROOF_ROOT="$cleanup_proof" \
      CODEX_HOME="$cleanup_codex" KIMI_CODE_HOME="$cleanup_kimi" PATH="$ROOT/bin:$PATH" \
      bash "$hook" >"$output"
}

assert_inactive_allows_multiline() {
  local hook="$1" proof_root output
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive.out"
  local command=$'printf \'%s\\n\' first\nprintf \'%s\\n\' second'
  mkdir -p "$proof_root"
  run_hook "$hook" "$proof_root" inactive-syntax "$command" "$output"
  [ ! -s "$output" ] || {
    printf 'inactive multiline command was ECI-blocked by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_inactive_allows_shell_substitution() {
  local hook="$1" proof_root output
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive-substitution"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive-substitution.out"
  local command='printf "%s\\n" "$(printf nested)"'
  mkdir -p "$proof_root"
  run_hook "$hook" "$proof_root" inactive-substitution "$command" "$output"
  [ ! -s "$output" ] || {
    printf 'inactive shell substitution was ECI-blocked by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_inactive_allows_bounded_read_only() {
  local hook="$1" proof_root output session_id=inactive-read-only log_path
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive-read-only"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-inactive-read-only.out"
  mkdir -p "$proof_root/$session_id"
  log_path="$proof_root/$session_id/high_level_log.md"
  printf '%s\n' '# inactive read-only log' >"$log_path"
  run_hook "$hook" "$proof_root" "$session_id" "sed -n '1p' $log_path" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "git -C $ROOT status --short" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "git -C $ROOT branch --all --contains HEAD" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "git -C $ROOT branch --all --contains HEAD~1" "$output"
  [ ! -s "$output" ] || return 1
}

assert_unbound_marker_allows_multiline() {
  local hook="$1" proof_root output
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-unbound"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-unbound.out"
  local command=$'printf \'%s\\n\' first\nprintf \'%s\\n\' second'
  mkdir -p "$proof_root/other-session"
  printf '%s\n' \
    'scope: syntax-gating test' \
    "cwd: $ROOT" \
    'session_id: other-session' \
    'created_utc: 2026-08-18T00:00:00Z' \
    >"$proof_root/other-session/eci_active"
  run_hook "$hook" "$proof_root" active-syntax "$command" "$output"
  [ ! -s "$output" ] || {
    printf 'unbound multiline command was ECI-blocked by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_active_overflow_without_owner_allows() {
  local hook="$1" proof_root output session_id=active-overflow
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-active-overflow"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-active-overflow.out"
  for i in $(seq 1 65); do
    mkdir -p "$proof_root/unrelated-$i"
    printf 'scope: unrelated overflow\ncwd: /other/cwd\nsession_id: unrelated-%s\n' "$i" \
      >"$proof_root/unrelated-$i/eci_active"
  done
  run_hook "$hook" "$proof_root" "$session_id" "git status --short" "$output"
  [ ! -s "$output" ] || {
    printf 'inactive callback was denied solely by an unrelated marker-scan overflow by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_active_allows_multiline_plan() {
  local hook="$1" proof_root output
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-active"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-active.out"
  local command=$'printf \'%s\\n\' first\nprintf \'%s\\n\' second'
  local session_id=active-syntax
  if [[ "$hook" == */.kimi-code/* ]]; then
    mkdir -p "$proof_root/$session_id"
    printf '%s\n' \
      'scope: syntax-gating test' \
      "cwd: $ROOT" \
      "session_id: $session_id" \
      'created_utc: 2026-08-18T00:00:00Z' \
      >"$proof_root/$session_id/eci_active"
  else
    mkdir -p "$proof_root/$session_id"
    printf '%s\n' \
      'scope: syntax-gating test' \
      "cwd: $ROOT" \
      "session_id: $session_id" \
      'created_utc: 2026-08-18T00:00:00Z' \
      >"$proof_root/$session_id/eci_active"
  fi
  printf '%s\n' '# active read-only log' >"$proof_root/$session_id/high_level_log.md"
  run_hook "$hook" "$proof_root" "$session_id" "$command" "$output"
  [ ! -s "$output" ] || {
    printf 'active finite multiline plan was ECI-blocked by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_active_allows_bounded_read_only() {
  local hook="$1" proof_root output session_id=active-read-only log_path evidence_dir evidence_file outside_file
  proof_root="$TMP_ROOT/$(basename "$(dirname "$hook")")-active-read-only"
  output="$TMP_ROOT/$(basename "$(dirname "$hook")")-active-read-only.out"
  mkdir -p "$proof_root/$session_id"
  printf '%s\n' \
    'scope: syntax-gating test' \
    "cwd: $ROOT" \
    "session_id: $session_id" \
    'created_utc: 2026-08-18T00:00:00Z' \
    >"$proof_root/$session_id/eci_active"
  log_path="$proof_root/$session_id/high_level_log.md"
  printf '%s\n' '# active read-only log' >"$log_path"
  run_hook "$hook" "$proof_root" "$session_id" "ls -li $ROOT/hooks/validate-bash.sh" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "stat -c '%y %n' $ROOT/hooks/validate-bash.sh" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "stat -c '%d:%i %a %h %n' $ROOT/hooks/validate-bash.sh" "$output"
  [ ! -s "$output" ] || return 1
  for environment_command in \
    "printenv PATH" \
    "printenv PATH PWD" \
    "env FOO=bar novel-tool --flag value" \
    "env -i novel-tool" \
    "env -u FOO novel-tool"; do
    run_hook "$hook" "$proof_root" "$session_id" "$environment_command" "$output"
    [ ! -s "$output" ] || return 1
  done
  for environment_case in \
    "env;ECI_ENVIRONMENT_ENUMERATION_DENIED;token=env;argv_index=0" \
    "env | sort;ECI_ENVIRONMENT_ENUMERATION_DENIED;token=env;argv_index=0" \
    "env | sort | rg '^PATH=';ECI_ENVIRONMENT_ENUMERATION_DENIED;token=env;argv_index=0" \
    "printenv;ECI_ENVIRONMENT_ENUMERATION_DENIED;token=printenv;argv_index=0" \
    "printenv OPENAI_API_KEY;ECI_ENVIRONMENT_NAME_DENIED;token=OPENAI_API_KEY;argv_index=1"; do
    IFS=';' read -r environment_command environment_code environment_token environment_index <<<"$environment_case"
    run_hook "$hook" "$proof_root" "$session_id" "$environment_command" "$output"
    jq -e --arg code "[$environment_code]" --arg token "$environment_token" --arg index "$environment_index" '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | contains($code)) and
      (.hookSpecificOutput.permissionDecisionReason | contains("operation=environment-boundary")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("segment=1")) and
      (.hookSpecificOutput.permissionDecisionReason | contains($token)) and
      (.hookSpecificOutput.permissionDecisionReason | contains($index)) and
      (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
    ' "$output" >/dev/null || return 1
  done
  run_hook "$hook" "$proof_root" "$session_id" "sed -n '1p' $log_path" "$output"
  [ ! -s "$output" ] || return 1
  evidence_dir="$proof_root/$session_id/evidence"
  evidence_file="$evidence_dir/inspection.txt"
  outside_file="$TMP_ROOT/outside-proof.txt"
  mkdir -p "$evidence_dir"
  printf '%s\n' 'proof evidence' >"$evidence_file"
  printf '%s\n' 'outside proof root' >"$outside_file"
  ln -sfn -- "$outside_file" "$evidence_dir/outside-link"
  run_hook "$hook" "$proof_root" "$session_id" "cat $evidence_file" "$output"
  [ ! -s "$output" ] || return 1
  run_hook "$hook" "$proof_root" "$session_id" "cat $evidence_dir/outside-link" "$output"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PROOF_PATH_ESCAPE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=proof-path-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains(("path=" + $path))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("resolved=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("proof_root=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' --arg path "$evidence_dir/outside-link" "$output" >/dev/null || return 1
  run_hook "$hook" "$proof_root" "$session_id" "git -C $ROOT status --short" "$output"
  [ ! -s "$output" ] || return 1
}

assert_active_cleanup_route() {
  local hook="$1" output="$TMP_ROOT/cleanup-route.out" multiline_cleanup_command
  cleanup_home="$TMP_ROOT/cleanup-home"
  cleanup_codex="$cleanup_home/.codex"
  cleanup_kimi="$cleanup_home/.kimi-code"
  cleanup_proof="$TMP_ROOT/cleanup-proof"
  rm -rf -- "$cleanup_home" "$cleanup_proof"
  mkdir -p \
    "$cleanup_codex/bin/__pycache__" "$cleanup_codex/bin/tests/__pycache__" "$cleanup_codex/hooks/tests/__pycache__" \
    "$cleanup_kimi/bin/__pycache__" "$cleanup_kimi/bin/tests/__pycache__" "$cleanup_kimi/hooks/tests/__pycache__" \
    "$cleanup_proof/cleanup-syntax"
  printf '%s\n' \
    'scope: syntax-gating cleanup test' \
    "cwd: $ROOT" \
    'session_id: cleanup-syntax' \
    'created_utc: 2026-08-20T00:00:00Z' \
    >"$cleanup_proof/cleanup-syntax/eci_active"
  for home in "$cleanup_codex" "$cleanup_kimi"; do
    mkdir -p "$home/bin" "$home/hooks/tests"
    for name in config-new.toml migrations-effort.json; do
      printf '%s\n' generated >"$home/$name"
    done
    for name in cron search-index workspace-trust; do
      mkdir -p "$home/$name"
    done
    printf '%s\n' generated >"$home/bin/codex-pending-couriers"
    mkdir -p "$home/.codex-runner-test.cleanup_01-"
  done

  cleanup_allow() {
    local command="$1"
    run_cleanup_hook "$hook" "$command" "$output"
    [ ! -s "$output" ] || {
      printf 'cleanup command was denied: %s\n' "$command" >&2
      cat -- "$output" >&2
      return 1
    }
  }
  cleanup_deny() {
    local command="$1" expected_detail="${2:-}"
    run_cleanup_hook "$hook" "$command" "$output"
    jq -e --arg expected_detail "$expected_detail" '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | contains("ECI_COMMAND_NOT_ALLOWLISTED")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("coordinator-cleanup-route")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("remediation:")) and
      ($expected_detail == "" or (.hookSpecificOutput.permissionDecisionReason | contains($expected_detail)))
    ' "$output" >/dev/null || {
      printf 'unsafe cleanup command was not specifically denied: %s\n' "$command" >&2
      cat -- "$output" >&2
      return 1
    }
  }

  cleanup_real_tmpdir="$cleanup_home/tmp"
  mkdir -p "$cleanup_real_tmpdir"
  export TMPDIR="$cleanup_real_tmpdir"
  export CODEX_TMPDIR="$cleanup_real_tmpdir"
  cleanup_quarantine="$cleanup_real_tmpdir/eci-generated-cleanup-syntax-gating"
  rm -rf -- "$cleanup_quarantine"
  cleanup_allow "mv -- $cleanup_codex/migrations-effort.json $cleanup_quarantine"
  printf '%s\n' existing >"$cleanup_quarantine"
  cleanup_deny "mv -- $cleanup_codex/migrations-effort.json $cleanup_quarantine" "destination must not already exist"
  rm -f -- "$cleanup_quarantine"
  cleanup_deny "mv -- $cleanup_codex/migrations-effort.json $cleanup_real_tmpdir/not-eci-cleanup"
  cleanup_deny "mv -- $cleanup_codex/other-generated-file $cleanup_real_tmpdir/eci-generated-cleanup-unknown"

  cleanup_deny "rm -f -- $cleanup_codex/.codex-runner-test.cleanup_01-"
  cleanup_allow "rm -f -- $cleanup_codex/config-new.toml $cleanup_codex/bin/codex-pending-couriers"
  cleanup_allow "rm -rf -- $cleanup_codex/.codex-runner-test.cleanup_01-"
  cleanup_allow "rm -rf -- $cleanup_codex/cron $cleanup_codex/search-index $cleanup_kimi/workspace-trust $cleanup_codex/bin/__pycache__ $cleanup_codex/bin/tests/__pycache__ $cleanup_kimi/hooks/tests/__pycache__"
  cleanup_deny "rm -rf -- $cleanup_codex/config-new.toml"
  cleanup_deny "rm -f -- $cleanup_codex/bin/__pycache__"
  cleanup_deny "rm -f $cleanup_codex/config-new.toml"
  cleanup_deny "rm -f -- $cleanup_codex/other-generated-file"
  cleanup_deny "rm -f -- $cleanup_codex/.codex-runner-test.bad!"
  cleanup_deny "rm -f -- $cleanup_home/outside-generated-file"
  cleanup_deny "rm -f -- $cleanup_codex/../outside-generated-file"
  cleanup_deny "rm -f -- \"$cleanup_codex/config-new.toml\""
  printf -v multiline_cleanup_command 'rm -f -- "%s"\ntrue' "$cleanup_codex/config-new.toml"
  run_cleanup_hook "$hook" "$multiline_cleanup_command" "$output"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("ECI_COMMAND_SYNTAX_DENIED")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=acceptance-boundary")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
  # Pair the active syntax denial with inactive passthrough so the cleanup
  # exception cannot become a global multiline-syntax ban.
  mv -- "$cleanup_proof/cleanup-syntax/eci_active" "$cleanup_proof/cleanup-syntax/eci_active.inactive"
  run_cleanup_hook "$hook" "$multiline_cleanup_command" "$output"
  [ ! -s "$output" ] || {
    printf 'inactive multiline cleanup was ECI-blocked by %s:\n' "$hook" >&2
    cat -- "$output" >&2
    return 1
  }
  mv -- "$cleanup_proof/cleanup-syntax/eci_active.inactive" "$cleanup_proof/cleanup-syntax/eci_active"
  printf '%s\n' outside >"$cleanup_home/outside-generated-file"
  cleanup_deny "rm -f -- $cleanup_codex/workspace-trust"
  rm -rf -- "$cleanup_codex/workspace-trust"
  cleanup_deny "rm -rf -- $cleanup_codex/workspace-trust"
  mkdir -p "$cleanup_codex/workspace-trust"
  printf '%s\n' outside >"$cleanup_home/symlink-target"
  ln -s -- "$cleanup_home/symlink-target" "$cleanup_codex/.codex-runner-test.link"
  cleanup_deny "rm -f -- $cleanup_codex/.codex-runner-test.link"
  cleanup_deny "rm -f -- $(printf '%s ' "$cleanup_codex/config-new.toml" | sed 's/ $//') $cleanup_codex/config-new.toml"
  rm -rf -- "$cleanup_quarantine"
}

assert_inactive_allows_multiline "$ROOT/hooks/validate-bash.sh"
assert_inactive_allows_shell_substitution "$ROOT/hooks/validate-bash.sh"
assert_inactive_allows_bounded_read_only "$ROOT/hooks/validate-bash.sh"
assert_unbound_marker_allows_multiline "$ROOT/hooks/validate-bash.sh"
assert_active_allows_multiline_plan "$ROOT/hooks/validate-bash.sh"
assert_active_allows_bounded_read_only "$ROOT/hooks/validate-bash.sh"
assert_active_overflow_without_owner_allows "$ROOT/hooks/validate-bash.sh"
assert_active_cleanup_route "$ROOT/hooks/validate-bash.sh"

KIMI_ROOT="/home/pheona/.kimi-code"
assert_inactive_allows_multiline "$KIMI_ROOT/hooks/validate-bash.sh"
assert_inactive_allows_shell_substitution "$KIMI_ROOT/hooks/validate-bash.sh"
assert_inactive_allows_bounded_read_only "$KIMI_ROOT/hooks/validate-bash.sh"
assert_unbound_marker_allows_multiline "$KIMI_ROOT/hooks/validate-bash.sh"
assert_active_allows_multiline_plan "$KIMI_ROOT/hooks/validate-bash.sh"
assert_active_allows_bounded_read_only "$KIMI_ROOT/hooks/validate-bash.sh"
assert_active_cleanup_route "$KIMI_ROOT/hooks/validate-bash.sh"

printf 'ECI command syntax gating regression passed for Codex and Kimi\n'
