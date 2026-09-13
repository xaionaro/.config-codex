#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-configured-pretooluse.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

FIXTURE_HOME="$TMP_ROOT/home"
FIXTURE_ROOT="$FIXTURE_HOME/.codex"
FIXTURE_PROOF="$TMP_ROOT/proof"
FIXTURE_SESSION='configured-pretooluse'
FIXTURE_CONFIG="$TMP_ROOT/config"
FIXTURE_STATE="$TMP_ROOT/state"

mkdir -p -- "$FIXTURE_ROOT" "$FIXTURE_PROOF/$FIXTURE_SESSION" \
  "$FIXTURE_CONFIG/eci" "$FIXTURE_STATE"
cp -a -- "$ROOT/hooks" "$FIXTURE_ROOT/hooks"
sed -i '2{/^exit 0$/d;}' -- "$FIXTURE_ROOT/hooks/validate-bash.sh"
sed -i '2{/^exit 0$/d;}' -- "$FIXTURE_ROOT/hooks/pretooluse-edit-dispatch.sh"
printf '%s\n' enforcing >"$FIXTURE_CONFIG/eci/command-gate-mode"
printf 'scope: configured consumer regression\ncwd: %s\nsession_id: %s\n' \
  "$FIXTURE_ROOT" "$FIXTURE_SESSION" >"$FIXTURE_PROOF/$FIXTURE_SESSION/eci_active"

cat >"$FIXTURE_ROOT/hooks/validate-apply-patch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"synthetic configured apply_patch validator denial"}}'
EOF
cat >"$FIXTURE_ROOT/hooks/validate-edit-write.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"synthetic configured edit validator denial"}}'
EOF
cat >"$FIXTURE_ROOT/hooks/eci-active-gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 -- "$FIXTURE_ROOT/hooks/validate-apply-patch.sh" \
  "$FIXTURE_ROOT/hooks/validate-edit-write.sh" "$FIXTURE_ROOT/hooks/eci-active-gate.sh"

run_configured_consumer() {
  local matcher="$1" input="$2" required_reason="$3" callback output

  callback="$(jq -er --arg matcher "$matcher" \
    '.hooks.PreToolUse[] | select(.matcher == $matcher) | .hooks[] | select(.type == "command") | .command' \
    "$ROOT/hooks.json")"
  output="$TMP_ROOT/${matcher//[^[:alnum:]]/_}.json"
  printf '%s' "$input" |
    HOME="$FIXTURE_HOME" CODEX_PROOF_ROOT="$FIXTURE_PROOF" \
      XDG_CONFIG_HOME="$FIXTURE_CONFIG" XDG_STATE_HOME="$FIXTURE_STATE" \
      bash -c "$callback" >"$output"
  jq -e --arg required_reason "$required_reason" '
    .hookSpecificOutput.hookEventName == "PreToolUse" and
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($required_reason))
  ' "$output" >/dev/null || {
    printf 'configured consumer did not reach its enabled guard: matcher=%s callback=%s\n' \
      "$matcher" "$callback" >&2
    cat -- "$output" >&2
    return 1
  }
}

run_configured_consumer '^Bash$' \
  "$(jq -cn --arg cwd "$FIXTURE_ROOT" --arg session "$FIXTURE_SESSION" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:"rm -rf /"}}')" \
  ECI_BROAD_DESTRUCTIVE_DENIED
run_configured_consumer '^apply_patch$' \
  "$(jq -cn --arg cwd "$FIXTURE_ROOT" --arg session "$FIXTURE_SESSION" \
    '{session_id:$session,cwd:$cwd,tool_name:"apply_patch",tool_input:{patch:"*** Begin Patch"}}')" \
  'synthetic configured apply_patch validator denial'
run_configured_consumer '^(Edit|Write|MultiEdit|NotebookEdit)$' \
  "$(jq -cn --arg cwd "$FIXTURE_ROOT" --arg session "$FIXTURE_SESSION" \
    '{session_id:$session,cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"notes.txt",old_string:"old",new_string:"new"}}')" \
  'synthetic configured edit validator denial'

printf '%s\n' 'configured PreToolUse consumers: PASS'
