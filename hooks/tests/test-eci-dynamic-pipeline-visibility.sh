#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOST_HOME="${HOME:?}"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-dynamic-pipeline.XXXXXX")"
fixture_hook="$(mktemp "$ROOT/hooks/.validate-bash-dynamic-pipeline.${BASHPID}.XXXXXX")"
proof_root="$TMP_ROOT/proof"
sid=t00-dynamic-pipeline
input="$TMP_ROOT/input.json"
output="$TMP_ROOT/output.json"
stderr_output="$TMP_ROOT/stderr.txt"
transcript="$TMP_ROOT/codex-home/sessions/dynamic-pipeline.jsonl"

trap 'rm -f -- "$fixture_hook"; rm -rf -- "$TMP_ROOT"' EXIT

# Exercise the private hook body, removing a line-2 bypass if present.
cp -- "$ROOT/hooks/validate-bash.sh" "$fixture_hook"
sed -i '2{/^exit 0$/d;}' -- "$fixture_hook"
cmp -- "$fixture_hook" <(sed '2{/^exit 0$/d;}' -- "$ROOT/hooks/validate-bash.sh") || {
  printf '%s\n' 'dynamic-pipeline fixture changed bytes other than an optional line-2 bypass' >&2
  exit 1
}

mkdir -p -- "$proof_root/$sid" "$(dirname -- "$transcript")"
printf '%s\n' \
  'scope: dynamic pipeline visibility test' \
  "cwd: $ROOT" \
  "session_id: $sid" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$proof_root/$sid/eci_active"
printf '%s\n' '{"timestamp":"2026-08-28T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-dynamic-pipeline","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Test","agent_role":"default"}}}}}' >"$transcript"

run_hook() {
  local role="$1" subagent="$2" command="$3"
  local callback_transcript=""
  [ "$subagent" != true ] || callback_transcript="$transcript"

  jq -cn --arg command "$command" --arg cwd "$ROOT" --arg transcript "$callback_transcript" \
    --arg sid "$sid" \
    '{session_id:$sid,cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' >"$input"
  HOME="$HOST_HOME" CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_HOOK_IS_SUBAGENT="$subagent" CODEX_ROLE="$role" \
    bash "$fixture_hook" <"$input" >"$output" 2>"$stderr_output"
}

assert_dynamic_pipeline_allowed() {
  local role="$1" subagent="$2"

  run_hook "$role" "$subagent" 'printf "$HOME" | cat'
  [ ! -s "$stderr_output" ] || {
    printf 'dynamic pipeline hook stderr: role=%s\n' "$role" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'dynamic pipeline was blocked by syntax alone: role=%s\n' "$role" >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_ordinary_pipeline_allowed() {
  local command="$1"

  run_hook worker true "$command"
  [ ! -s "$stderr_output" ] || {
    printf '%s\n' 'finite inspection pipeline hook emitted stderr:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf '%s\n' 'finite inspection pipeline was blocked without a concrete target effect:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_broad_pipeline_stays_denied() {
  local role="$1" subagent="$2"

  run_hook "$role" "$subagent" "find $ROOT -delete | cat"
  jq -e --arg target "$ROOT" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("ECI_BROAD_DESTRUCTIVE_DENIED")) and
    (.hookSpecificOutput.permissionDecisionReason | contains($target)) and
    (.hookSpecificOutput.permissionDecisionReason | contains("separately reviewed") | not) and
    (.hookSpecificOutput.permissionDecisionReason | contains("split the pipeline") | not)
  ' "$output" >/dev/null || {
    printf '%s\n' 'broad destructive pipeline was not denied by its concrete target:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

# The value is dynamic, but this command has no resolved write/destructive
# target. It must reach normal execution for both ordinary worker and
# coordinator work.
assert_dynamic_pipeline_allowed worker true
assert_dynamic_pipeline_allowed coordinator false
assert_ordinary_pipeline_allowed "find $ROOT -type f | head -n 1"
assert_ordinary_pipeline_allowed "find $ROOT -type f -exec printf '%s\\n' '{}' \\; | cat"
assert_ordinary_pipeline_allowed "python3 -c 'print(1)' | cat"
assert_ordinary_pipeline_allowed "python3 -c 'open(\"result.txt\", \"w\").write(\"x\")' | cat"
assert_ordinary_pipeline_allowed 'printf item | xargs printf'
assert_ordinary_pipeline_allowed 'timeout 1 printf item | cat'
assert_broad_pipeline_stays_denied worker true
assert_broad_pipeline_stays_denied coordinator false

printf '%s\n' 'dynamic pipeline visibility assertions: PASS'
