#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CANONICAL_CODEX_HOME="${HOME:?HOME must be set}/.codex"
HOOKS_JSON="$CANONICAL_CODEX_HOME/hooks.json"
DISPATCHER="$CANONICAL_CODEX_HOME/bin/eci-active-dispatch"
CONFIG_TOML="$CANONICAL_CODEX_HOME/config.toml"
CONTEXT7_MCP="$CANONICAL_CODEX_HOME/bin/context7-mcp"
LAUNCHERS=(
  "$HOME/.local/bin/codex"
  "$HOME/bin/codex"
)
EXPECTED_HOOK_COMMANDS=(
  "bash -lc 'exec \"\$HOME/.codex/hooks/session-snapshot.sh\"'"
  "bash -c 'exec \"\$HOME/.codex/hooks/eci-post-compact-refresh.sh\"'"
  "bash -lc 'exec \"\$HOME/.codex/hooks/prompt-task-reminder.sh\"'"
  "bash \"\$HOME/.codex/hooks/validate-bash.sh\""
  "bash \"\$HOME/.codex/hooks/pretooluse-edit-dispatch.sh\""
  "bash \"\$HOME/.codex/hooks/pretooluse-edit-dispatch.sh\""
  "bash -lc 'exec \"\$HOME/.codex/hooks/stop-gate.sh\"'"
)
failures=0

fail() {
  printf 'FAIL %s\n' "$*" >&2
  failures=$((failures + 1))
}

[ "$ROOT" = "$CANONICAL_CODEX_HOME" ] ||
  fail "test root must be the HOME-derived canonical Codex home: root=$ROOT home=$CANONICAL_CODEX_HOME"

for launcher in "${LAUNCHERS[@]}"; do
  if ! grep -Eq '^[[:space:]]*export[[:space:]]+CODEX_HOME="\$HOME/\.codex"[[:space:]]*$' "$launcher"; then
    fail "$launcher must force CODEX_HOME=\"\$HOME/.codex\""
  fi
done

# The provider dispatcher is itself a lifecycle authority boundary. Codex
# must select the same literal HOME-rooted installation as the launchers, not
# an arbitrary inherited CODEX_HOME; provider-dispatch exercises the runtime
# behavior with a conflicting environment value.
if ! grep -Fqx '  provider_home="${HOME:?}/.codex"' "$DISPATCHER"; then
  fail "$DISPATCHER must bind the Codex provider home to \${HOME}/.codex"
fi

# The contract is intentionally evaluated under a different HOME rather than
# relying on the account used to run this test. The exact launcher line above
# is then the only source of the selected Codex home.
controlled_home='/codex-runtime-single-source-controlled-home'
controlled_codex_home="$(
  env -i HOME="$controlled_home" PATH=/usr/bin:/bin \
    bash -c 'export CODEX_HOME="$HOME/.codex"; printf %s "$CODEX_HOME"'
)"
[ "$controlled_codex_home" = "$controlled_home/.codex" ] ||
  fail "HOME-derived launcher contract expanded to $controlled_codex_home"

if ! grep -Fqx 'args = ["-lc", "exec \"$HOME/.codex/bin/context7-mcp\""]' "$CONFIG_TOML"; then
  fail "context7 MCP must launch from the literal \$HOME/.codex source"
fi

if ! grep -Fqx 'Also follow `$HOME/.codex/CODEX.md` as user-level guidance when it does not conflict with higher-priority Codex instructions.' "$CONFIG_TOML"; then
  fail "developer guidance must select the literal \$HOME/.codex/CODEX.md source"
fi
if ! grep -Fqx 'Ported skills live in `$HOME/.codex/skills`; use matching skills for Go, Python, tests, debugging, UI, Android, porting, skill/prompt work, and explicit delegated-agent work.' "$CONFIG_TOML"; then
  fail "developer guidance must select the literal \$HOME/.codex/skills source"
fi
if grep -Fq '$CODEX_HOME/' "$CONFIG_TOML"; then
  fail "developer guidance must not select an inherited CODEX_HOME source"
fi

if ! grep -Fqx 'canonical_provider_home="${HOME:?HOME must be set}/.codex"' "$CONTEXT7_MCP"; then
  fail "context7 MCP must bind itself to the HOME-derived Codex source"
fi
if grep -Fq 'CODEX_HOME' "$CONTEXT7_MCP"; then
  fail "context7 MCP must not select its source or cache through CODEX_HOME"
fi

# A stale/copied Stop hook must not recover its helpers from its own location.
# It must re-exec the HOME-bound source before parsing state.  Deliberately
# poison CODEX_HOME too: it is not a lifecycle-source selector.
source_probe_root="$(mktemp -d "${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}/codex-stop-source.XXXXXX")"
source_probe_hook="$source_probe_root/hooks/stop-gate.sh"
source_probe_proof="$source_probe_root/proof"
source_probe_output="$source_probe_root/output.json"
mkdir -p "$source_probe_root/hooks" "$source_probe_proof"
cp -- "$CANONICAL_CODEX_HOME/hooks/stop-gate.sh" "$source_probe_hook"
if ! jq -cn --arg cwd "$CANONICAL_CODEX_HOME" \
  '{session_id:"source-root-probe",cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  env -u CODEX_ROLE HOME="$HOME" CODEX_HOME="$source_probe_root" \
    CODEX_SESSION_ID=source-root-probe CODEX_PROOF_ROOT="$source_probe_proof" \
    "$source_probe_hook" >"$source_probe_output"; then
  fail "copied Stop hook did not transfer to the HOME-bound source"
elif ! jq -e '. == {"continue":true}' "$source_probe_output" >/dev/null; then
  fail "copied Stop hook did not return the canonical source result"
fi
rm -rf -- "$source_probe_root"

if ! jq -e '
  [.hooks | .. | objects | select(.type? == "command") | .command] |
  length > 0 and all(.[]; type == "string")
' "$HOOKS_JSON" >/dev/null; then
  fail "$HOOKS_JSON must contain command hooks"
else
  mapfile -t hook_commands < <(
    jq -r '.hooks | .. | objects | select(.type? == "command") | .command' "$HOOKS_JSON"
  )
  if [ "${#hook_commands[@]}" -ne "${#EXPECTED_HOOK_COMMANDS[@]}" ]; then
    fail "$HOOKS_JSON changed its configured hook command count"
  fi
  for index in "${!EXPECTED_HOOK_COMMANDS[@]}"; do
    hook_command="${hook_commands[$index]:-}"
    if [ "$hook_command" != "${EXPECTED_HOOK_COMMANDS[$index]}" ]; then
      fail "$HOOKS_JSON changed hook target or HOME-rooted launcher at index $index: $hook_command"
    fi
    case "$hook_command" in
      *'$HOME/.codex/hooks/'*) ;;
      *) fail "hook command must use the literal \$HOME/.codex/hooks/ root: $hook_command" ;;
    esac
    case "$hook_command" in
      *'/home/'*|*'/mnt/'*|*'${CODEX_HOME'*|*'$CODEX_HOME'*|*'~/.codex'*)
        fail "hook command must not select a fallback or alternate Codex root: $hook_command"
        ;;
    esac
  done
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'canonical Codex runtime selection assertions: PASS\n'
