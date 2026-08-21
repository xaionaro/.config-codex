#!/usr/bin/env bash

set -Eeuo pipefail
trap 'status=$?; printf "classifier failure: line=%s status=%s command=%q\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
classifier_tmp_parent="$(realpath -m -- "${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}")"
mkdir -p -- "$classifier_tmp_parent"
TMP_ROOT="$(mktemp -d "$classifier_tmp_parent/eci-classifier-${BASHPID}.XXXXXX")"
kimi_root="${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}"
subagent_transcript=""
export XDG_CONFIG_HOME="$TMP_ROOT/xdg-config"
export XDG_STATE_HOME="$TMP_ROOT/xdg-state"
mkdir -p "$XDG_CONFIG_HOME/eci"
chmod 700 "$XDG_CONFIG_HOME" "$XDG_CONFIG_HOME/eci"
printf '%s\n' enforcing >"$XDG_CONFIG_HOME/eci/command-gate-mode"
chmod 600 "$XDG_CONFIG_HOME/eci/command-gate-mode"

proof_root="$TMP_ROOT/proof"
mkdir -p "$proof_root/t00-session"
printf '%s\n' \
  'scope: classifier test' \
  "cwd: $ROOT" \
  'session_id: t00-session' \
  'created_utc: 2026-08-14T00:00:00Z' \
  >"$proof_root/t00-session/eci_active"
high_level_log="$proof_root/t00-session/high_level_log.md"
printf '%s\n' '# baseline' >"$high_level_log"
evidence_dir="$proof_root/t00-session/evidence"
evidence_file="$evidence_dir/inspection.txt"
instructions_file="$proof_root/t00-session/instructions.md"
mkdir -p "$evidence_dir"
printf '%s\n' 'proof evidence' >"$evidence_file"
printf '%s\n' '# coordinator instructions' >"$instructions_file"
printf '%s\n' 'outside proof root' >"$TMP_ROOT/outside-proof.txt"
ln -s -- "$TMP_ROOT/outside-proof.txt" "$evidence_dir/outside-link"
log_bytes="$(wc -c <"$high_level_log")"
log_sha256="$(sha256sum -- "$high_level_log" | awk '{print $1}')"
printf '%s\n' \
  'schema: eci-high-level-log-anchor/v1' \
  'session_id: t00-session' \
  "log_path: $high_level_log" \
  "bytes: $log_bytes" \
  "sha256: $log_sha256" \
  >"$proof_root/t00-session/high_level_log.anchor"

# The runtime route validates the same marker/cwd binding and advances the
# bounded prefix anchor under the mutation lock.
CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session CODEX_HOME="$ROOT" \
  "$ROOT/bin/eci-active" ledger-append 'coordinator entry' >/dev/null
first_timestamp_line="$(tail -n 1 -- "$high_level_log")"
[[ "$first_timestamp_line" =~ ^##\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ -\ coordinator\ entry$ ]]
CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session CODEX_HOME="$ROOT" \
  "$ROOT/bin/eci-active" ledger-append 'second timestamp entry' >/dev/null
second_timestamp_line="$(tail -n 1 -- "$high_level_log")"
[[ "$second_timestamp_line" =~ ^##\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ -\ second\ timestamp\ entry$ ]]
first_timestamp="${first_timestamp_line#'## '}"; first_timestamp="${first_timestamp%% - *}"
second_timestamp="${second_timestamp_line#'## '}"; second_timestamp="${second_timestamp%% - *}"
[[ "$first_timestamp" < "$second_timestamp" ]]

subagent_codex_home="$TMP_ROOT/codex-home"
external_skill_root="$TMP_ROOT/external/skills/escape"
mkdir -p "$subagent_codex_home/bin" "$subagent_codex_home/sessions" \
  "$subagent_codex_home/skills/test" "$external_skill_root"
cp -- "$ROOT/bin/eci-active" "$subagent_codex_home/bin/eci-active"
chmod +x "$subagent_codex_home/bin/eci-active"
printf '%s\n' '# worker Codex instructions' >"$subagent_codex_home/CODEX.md"
printf '%s\n' '# worker agent instructions' >"$subagent_codex_home/AGENTS.md"
printf '%s\n' '# worker test skill' >"$subagent_codex_home/skills/test/SKILL.md"
mkfifo "$subagent_codex_home/skills/test/not-a-source.fifo"
printf '%s\n' '# outside skill' >"$external_skill_root/SKILL.md"
ln -s -- "$external_skill_root" "$subagent_codex_home/skills/escape"

run_hook() {
  local command="$1" output
  output="$TMP_ROOT/output"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" KIMI_CODE_HOME="$kimi_root" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_without_marker() {
  local command="$1" output
  output="$TMP_ROOT/output-without-marker"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-no-marker",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$TMP_ROOT/no-marker-proof" CODEX_HOME="$ROOT" KIMI_CODE_HOME="$kimi_root" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_with_kimi_home() {
  local command="$1" companion_home="$2" output
  output="$TMP_ROOT/output-with-kimi-home"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" KIMI_CODE_HOME="$companion_home" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_without_kimi_home() {
  local command="$1" output
  output="$TMP_ROOT/output-without-kimi-home"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
    env -u KIMI_CODE_HOME CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_with_transcript() {
  local command="$1" output transcript
  output="$TMP_ROOT/output-with-transcript"
  transcript="$TMP_ROOT/main-transcript.jsonl"
  printf '%s\n' '{"timestamp":"2026-08-18T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session"}}' >"$transcript"
  jq -cn --arg cwd "$ROOT" --arg command "$command" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_with_transcript_pager() {
  local command="$1" output transcript
  output="$TMP_ROOT/output-with-transcript-pager"
  transcript="$TMP_ROOT/main-transcript-pager.jsonl"
  printf '%s\n' '{"timestamp":"2026-08-18T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session"}}' >"$transcript"
  jq -cn --arg cwd "$ROOT" --arg command "$command" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" KIMI_CODE_HOME="$kimi_root" GIT_PAGER=cat PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_subagent_hook() {
  local command="$1" output transcript
  output="$TMP_ROOT/subagent-output"
  transcript="$subagent_codex_home/sessions/codex-validate-bash-subagent-$BASHPID.jsonl"
  subagent_transcript="$transcript"
  printf '%s\n' '{"timestamp":"2026-08-15T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Test","agent_role":"default"}}}}}' >"$transcript"
  jq -cn --arg cwd "$ROOT" --arg command "$command" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$subagent_codex_home" PATH="$subagent_codex_home/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_subagent_hook_at_root() {
  local command="$1" alternate_root="$2" alternate_home="$3" output transcript
  output="$TMP_ROOT/subagent-output-at-root"
  transcript="$subagent_codex_home/sessions/codex-validate-bash-subagent-$BASHPID-at-root.jsonl"
  subagent_transcript="$transcript"
  printf '%s\n' '{"timestamp":"2026-08-15T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Test","agent_role":"default"}}}}}' >"$transcript"
  jq -cn --arg cwd "$ROOT" --arg command "$command" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$alternate_root" HOME="$alternate_home" CODEX_HOME="$subagent_codex_home" PATH="$subagent_codex_home/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_role_hook() {
  local role="$1" command="$2"
  case "$role" in
    coordinator) run_hook "$command" ;;
    worker) run_subagent_hook "$command" ;;
    *) printf 'unknown test role: %s\n' "$role" >&2; return 1 ;;
  esac
}

assert_role_environment_denied() {
  local role="$1" command="$2" code="$3" token="$4" argv_index="$5"
  local forbidden_value="${6:-}" reason_fragment="${7:-}" output
  output="$(run_role_hook "$role" "$command")"
  jq -e --arg code "[$code]" --arg token "$token" --arg argv_index "$argv_index" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($code)) and
    (.hookSpecificOutput.permissionDecisionReason | contains("phase=PreToolUse")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=environment-boundary")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("segment=1")) and
    (.hookSpecificOutput.permissionDecisionReason | contains(("token=" + $token))) and
    (.hookSpecificOutput.permissionDecisionReason | contains(("argv_index=" + $argv_index))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null || {
    printf 'environment denial mismatch: role=%s command=%q\n' "$role" "$command" >&2
    cat -- "$output" >&2
    return 1
  }
  if [ -n "$forbidden_value" ] && grep -F -- "$forbidden_value" "$output" >/dev/null; then
    printf 'environment context diagnostic leaked assignment value: role=%s command=%q\n' "$role" "$command" >&2
    cat -- "$output" >&2
    return 1
  fi
  if [ -n "$reason_fragment" ] && ! grep -F -- "$reason_fragment" "$output" >/dev/null; then
    printf 'environment diagnostic omitted reason detail: role=%s command=%q detail=%s\n' \
      "$role" "$command" "$reason_fragment" >&2
    cat -- "$output" >&2
    return 1
  fi
}

assert_allowed() {
  local command="$1" output
  output="$(run_hook "$command")"
  [ ! -s "$output" ] || {
    cat "$output" >&2
    return 1
  }
}

assert_denied() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null || {
    printf 'assert_denied failed: command=%q output=%s\n' "$command" "$output" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

assert_unknown() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
  ' "$output" >/dev/null || {
    printf 'assert_unknown failed: command=%q output=%s\n' "$command" "$output" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

zero_marker_commit_output="$(run_hook_without_marker "git commit -m 'inactive boundary'")"
[ ! -s "$zero_marker_commit_output" ] || {
  cat -- "$zero_marker_commit_output" >&2
  exit 1
}

# Inline-code diagnostics identify the exact switch and argv position, like a
# compiler diagnostic identifies the offending token and location.
launcher_output="$(run_hook "bash -c 'printf launcher'")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=-c")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=1")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-interpreter-launch")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("invoke a literal script path or direct executable argv"))
' <<<"$(cat -- "$launcher_output")" >/dev/null
assert_allowed "bash hooks/tests/test-validate-bash-classifier.sh"
assert_allowed "bash -x hooks/tests/test-validate-bash-classifier.sh"
assert_unknown "bash -x hooks/tests/test-validate-bash-classifier.sh 2>&1 | tail -n 20"
assert_allowed "bash -x -n hooks/tests/test-validate-bash-classifier.sh"
assert_unknown "bash -x hooks/tests/test-validate-bash-classifier.sh 2>&1 | tail -n 201"
missing_instructions="$proof_root/t00-session/instructions.md"
missing_output="$(run_hook "cat $missing_instructions")"
[ ! -s "$missing_output" ]
worker_missing_output="$(run_subagent_hook "find -P $proof_root/t00-session/missing -maxdepth 1 -print")"
[ ! -s "$worker_missing_output" ]

assert_source_write_denied() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_COORDINATOR_SOURCE_WRITE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=coordinator-source-write")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("path=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=coordinator-source-write")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
}

assert_lifecycle_denied() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e --arg command "$command" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_LIFECYCLE_ARGUMENTS_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("phase=PreToolUse")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=eci-lifecycle")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("provider arguments")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("canonical Codex/Kimi eci-active control binary")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
}

assert_lifecycle_identity_denied() {
  local command="$1" expected_name="$2" observed_name="$3" output
  output="$(run_hook "$command")"
  jq -e --arg expected_name "$expected_name" --arg observed_name "$observed_name" '
    .hookSpecificOutput.permissionDecision == "deny" and
    ((.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_LIFECYCLE_IDENTITY_DENIED]")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_LIFECYCLE_IDENTITY_DENIED]"))) and
    (.hookSpecificOutput.permissionDecisionReason | contains($expected_name)) and
    (.hookSpecificOutput.permissionDecisionReason | contains($observed_name)) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
}

# A novel finite executable is ordinary project work, not an allowlist miss.
assert_allowed "unrecognized-command"
assert_allowed "git -C $ROOT status --short"
assert_allowed "git -C $ROOT status --branch"
assert_allowed "git -C $ROOT status --short --branch"
assert_allowed "git -C $ROOT status --short --branch -- hooks/validate-bash.sh"
assert_allowed "git -C $ROOT status --short hooks/validate-bash.sh"
assert_allowed "git -C $ROOT status --short -- hooks/validate-bash.sh"
assert_allowed "git -C $ROOT diff --stat hooks/validate-bash.sh"
assert_allowed "git -C $ROOT diff --stat -- hooks/validate-bash.sh"
assert_allowed "git -C $ROOT diff --cached --stat"
assert_allowed "git -C $ROOT diff --staged --stat"
assert_allowed "git diff -- hooks/validate-bash.sh | sed -n '1,260p'"
assert_allowed "git -C $ROOT diff -- AGENTS.md"
assert_allowed "git -C $ROOT diff AGENTS.md"
assert_allowed "git -C $ROOT log -1 --oneline hooks/validate-bash.sh"
assert_allowed "git -C $ROOT log -5 --oneline hooks/validate-bash.sh"
assert_allowed "git -C $ROOT log -1 -- AGENTS.md"
assert_allowed "date -u +%Y-%m-%dT%H:%M:%SZ"
assert_allowed "date --utc +%Y-%m-%dT%H:%M:%SZ"
assert_allowed "date -u +%s"
assert_allowed "git -C $ROOT show --stat -1 hooks/validate-bash.sh"
assert_allowed "git -C $ROOT show -- AGENTS.md"
assert_allowed "eci-active --help"
assert_unknown "~/.codex/bin/eci-active status"
assert_unknown "~/.codex/bin/eci-active --help"
raw_lifecycle_assignment_output="$(run_hook "CODEX_SESSION_ID=t00-session $ROOT/bin/eci-active status")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=leading-assignment"))' "$raw_lifecycle_assignment_output" >/dev/null
assert_allowed "env CODEX_SESSION_ID=t00-session $ROOT/bin/eci-active status"
assert_allowed "env CODEX_SESSION_ID=t00-session $ROOT/bin/eci-active ledger-append 'bounded coordinator entry'"
assert_allowed "env TMPDIR=/tmp CODEX_SESSION_ID=t00-session $ROOT/bin/eci-active --help"
assert_lifecycle_identity_denied "env KIMI_SESSION_ID=t00-session $ROOT/bin/eci-active status" CODEX_SESSION_ID KIMI_SESSION_ID
assert_lifecycle_identity_denied "env CODEX_SESSION_ID=wrong-session $ROOT/bin/eci-active ledger-append 'mismatch probe'" CODEX_SESSION_ID wrong-session

# ECI ownership admission is ecosystem-neutral: after reserved ownership and
# shell-indirection checks, finite direct argv vectors for ordinary build/test
# tools are admitted without maintaining an executable allowlist.
for ordinary_literal in \
  "go test ./..." \
  "cargo test --workspace" \
  "pytest -q tests" \
  "python3 -m pytest tests" \
  "python3 tools/check.py --mode strict" \
  "node scripts/check.mjs" \
  "npm test -- --runInBand" \
  "make -B test" \
  "cmake --build build --target test" \
  "ctest --test-dir build --output-on-failure" \
  "ninja -C build test" \
  "meson test -C build" \
  "mvn -q test" \
  "./gradlew test" \
  "bash scripts/test.sh" \
  "novel-tool --flag value" \
  "./tools/repo-check --context" \
  "rg -n -C 3 'needle' hooks"; do
  assert_allowed "$ordinary_literal"
done

# Direct shell/interpreter indirection and ownership-protected operations stay
# denied with compiler-style diagnostics; this is not an executable safety
# allowlist.
for protected_literal in \
  "eval 'go test ./...'" \
  "python3 -c 'print(1)'" \
  "node -e 'console.log(1)'" \
  "env -S python3 -m pytest tests" \
  "go test \$(printf ./...)" \
  $'go test ./...\nrm -f marker' \
  "git commit -m 'blocked'" \
  "git reset --hard"; do
  assert_unknown "$protected_literal"
done

if [[ "$kimi_root" = /* ]] && [ -d "$kimi_root" ] && [ ! -L "$kimi_root" ] &&
  [ -f "$kimi_root/bin/eci-active" ] && [ ! -L "$kimi_root/bin/eci-active" ]; then
  assert_allowed "$kimi_root/bin/eci-active status"
  assert_allowed "$kimi_root/bin/eci-active --help"
  assert_allowed "env KIMI_SESSION_ID=t00-session $kimi_root/bin/eci-active status"
  assert_lifecycle_identity_denied "env CODEX_SESSION_ID=t00-session $kimi_root/bin/eci-active status" KIMI_SESSION_ID CODEX_SESSION_ID
  assert_lifecycle_identity_denied "env KIMI_SESSION_ID=wrong-session $kimi_root/bin/eci-active ledger-append 'mismatch probe'" KIMI_SESSION_ID wrong-session
  assert_allowed "$kimi_root/bin/eci-active on 'peer coordinator scope'"
  assert_allowed "$kimi_root/bin/eci-active off /tmp/eci-peer-disengage.md"
  assert_lifecycle_denied "$kimi_root/bin/eci-active on peer-scope extra"
  peer_worker_output="$(run_subagent_hook "$kimi_root/bin/eci-active status")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$peer_worker_output" >/dev/null
  altered_kimi_root="$TMP_ROOT/altered-kimi-home"
  mkdir -p "$altered_kimi_root/bin"
  cp -- "$kimi_root/bin/eci-active" "$altered_kimi_root/bin/eci-active"
  printf '\n' >>"$altered_kimi_root/bin/eci-active"
  altered_peer_output="$(run_hook_with_kimi_home "$altered_kimi_root/bin/eci-active status" "$altered_kimi_root")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$altered_peer_output" >/dev/null
fi
assert_allowed "ps -o pid,etime,stat,cmd"
assert_allowed "ps -o pid,cmd"
assert_allowed "ps -o pid,etime,stat,cmd | head -n 5"
adb_worker_output="$(run_subagent_hook "adb devices -l")"
[ ! -s "$adb_worker_output" ]
ordinary_worker_write_output="$(run_subagent_hook "touch hooks/generated-worker-source")"
[ ! -s "$ordinary_worker_write_output" ]
xargs_worker_output="$(run_subagent_hook "xargs novel-worker-tool")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=xargs")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-launch"))
' "$xargs_worker_output" >/dev/null
broad_worker_output="$(run_subagent_hook "rm -rf /")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_BROAD_DESTRUCTIVE_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("path=/")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=broad-destructive")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("segment=1")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=2")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=/"))
' "$broad_worker_output" >/dev/null
coordinator_source_output="$(run_hook "touch hooks/generated-coordinator-source")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_COORDINATOR_SOURCE_WRITE_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=coordinator-source-write")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=hooks/generated-coordinator-source"))
' "$coordinator_source_output" >/dev/null
coordinator_tmp_output="$(run_hook "touch /tmp/eci-finite-literal-probe")"
[ ! -s "$coordinator_tmp_output" ]
for ordinary_worker_shell in \
  "bash -e scripts/test.sh" \
  "bash -x scripts/test.sh" \
  "bash -O extglob scripts/test.sh" \
  "bash --noprofile scripts/test.sh" \
  "sh -e scripts/test.sh" \
  "./tools/eci-review-gate.sh verify" \
  "novel-worker-tool --flag value"; do
  ordinary_worker_output="$(run_subagent_hook "$ordinary_worker_shell")"
  [ ! -s "$ordinary_worker_output" ] || {
    printf 'ordinary finite worker argv was denied: %s\n' "$ordinary_worker_shell" >&2
    cat -- "$ordinary_worker_output" >&2
    exit 1
  }
done
worker_help_output="$(run_subagent_hook "eci-active --help")"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$worker_help_output" >/dev/null
worker_ps_output="$(run_subagent_hook "ps -o pid,etime,stat,cmd")"
[ ! -s "$worker_ps_output" ]
assert_source_write_denied "chmod 755 hooks/pre-commit-go-mod.sh hooks/install-pre-commit-go-mod.sh hooks/tests/test-pre-commit-go-mod.sh"
assert_source_write_denied "chmod 755 hooks/validate-bash.sh"
assert_source_write_denied "chmod 644 hooks/pre-commit-go-mod.sh"
assert_source_write_denied "chmod 644 hooks/validate-bash.sh"
chmod_worker_output="$(run_subagent_hook "chmod 755 hooks/pre-commit-go-mod.sh")"
[ ! -s "$chmod_worker_output" ]
pager_output="$(run_hook_with_transcript_pager "git -C $ROOT status --short")"
[ ! -s "$pager_output" ]
if [[ "$kimi_root" = /* ]] && [ -d "$kimi_root" ] && [ ! -L "$kimi_root" ] &&
  [ "$(realpath -m -- "$kimi_root")" = "$kimi_root" ]; then
  if [ -f "$kimi_root/hooks/tests/test-block-no-progress.sh" ] && [ ! -L "$kimi_root/hooks/tests/test-block-no-progress.sh" ]; then
    assert_allowed "bash $kimi_root/hooks/tests/test-block-no-progress.sh"
    assert_allowed "$kimi_root/hooks/tests/test-block-no-progress.sh"
    default_kimi_output="$(run_hook_without_kimi_home "$kimi_root/hooks/tests/test-block-no-progress.sh")"
    [ ! -s "$default_kimi_output" ] || {
      cat -- "$default_kimi_output" >&2
      return 1
    }
  fi
  assert_allowed "git -C $kimi_root status --short"
  assert_allowed "git -C $kimi_root status --short --branch"
  assert_allowed "git -C $kimi_root log -5 --oneline"
  assert_allowed "git -C $kimi_root diff -- AGENTS.md"
  assert_allowed "git -C $kimi_root diff --stat"
  assert_source_write_denied "chmod 755 $kimi_root/hooks/pre-commit-go-mod.sh $kimi_root/hooks/install-pre-commit-go-mod.sh"
  assert_allowed "bash hooks/install-pre-commit-go-mod.sh"
  assert_allowed "bash $kimi_root/hooks/install-pre-commit-go-mod.sh"
  assert_allowed "bash hooks/install-pre-commit-go-mod.sh --repair-hardlink $kimi_root"
  assert_denied "bash hooks/install-pre-commit-go-mod.sh --repair-hardlink $ROOT"
fi
assert_allowed "ls -ld $ROOT/sessions"
assert_allowed "find /tmp -maxdepth 1 -type d -name 'codex-eci-edit-controls.*' -print"
assert_allowed "readlink -f $ROOT/sessions"
assert_allowed "find /tmp -maxdepth 1 -type d -print"
# This exercises the validator's real `shutil.which("mktemp")` resolution;
# on the deployment host it resolves through the trusted cargo coreutils path.
assert_allowed "mktemp -d /tmp/codex-eci-coreutils.XXXXXX"
assert_allowed "mktemp -d /tmp/codex-eci-probe.XXXXXX"
assert_unknown "mktemp -d /tmp/codex-eci-probe.XXXXXX extra"
assert_unknown 'mktemp -d /tmp/codex-eci-probe-$(date).XXXXXX'
worker_mktemp_output="$(run_subagent_hook "mktemp -d /tmp/codex-eci-probe.XXXXXX")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_COORDINATOR_ROUTE_DENIED]") and contains("phase=PreToolUse") and contains("operation=coordinator-route") and contains("subject=command=wrapper=literal") and contains("rejected command=wrapper=literal") and contains("payload=mktemp -d /tmp/codex-eci-probe.XXXXXX") and contains("coordinator-only temporary-directory setup") and contains("reason:") and contains("remediation:"))
' "$worker_mktemp_output" >/dev/null
glob_output="$(run_hook "ls -la /tmp/*")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=*")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=shell-expansion")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
' "$glob_output" >/dev/null
assert_allowed "realpath /usr/bin/tail"
assert_allowed "ls -l /usr/bin/tail"
assert_allowed "readlink /usr/bin/tail"
worker_tmp_output="$(run_subagent_hook "find /tmp -maxdepth 1 -type d -print")"
[ ! -s "$worker_tmp_output" ]

# Coordinator project inspection accepts finite literal lists from the
# validated companion Kimi root, including bounded find/stat forms.
kimi_find_a="$kimi_root/.codex-runner-test.0dcfk8kp"
kimi_find_b="$kimi_root/.codex-runner-test.pjj7ll1a"
assert_allowed "ls -ld $kimi_root $kimi_find_a $kimi_find_b"
assert_allowed "find $kimi_find_a $kimi_find_b -maxdepth 2 -type f -print | head -n 40"
assert_allowed "stat -Lc '%i %a %n' $kimi_root/hooks/validate-bash.sh $kimi_root/hooks/tests/run.sh"
assert_allowed "stat -Lc '%i %a %h %n' $kimi_root/hooks/validate-bash.sh $kimi_root/hooks/tests/run.sh"
assert_allowed "stat -c '%d:%i %a %h %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -c '%y %s %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -Lc '%F %s %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -Lc '%F %N' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -Lc '%i %a %h %s %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -c '%s' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -c '%a %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "stat -c '%A %n' $kimi_root/hooks/validate-bash.sh"
assert_allowed "ls -1 $evidence_dir"
assert_allowed "find -P $evidence_dir -maxdepth 2 -type f -print"
assert_allowed "stat -c '%a %n' $evidence_file"
assert_allowed "stat -Lc '%i %a %h %n' $evidence_file"
assert_allowed "cat $instructions_file"
assert_allowed "sed -n '1p' $instructions_file"
assert_allowed "rg -n 'proof evidence' $evidence_dir"
assert_allowed "rg -n -i 'proof evidence' $evidence_dir"
assert_allowed "readlink -f $evidence_file"
assert_allowed "realpath $evidence_file"
assert_allowed "realpath -e $evidence_file && stat -Lc '%d:%i %a %h %n' $proof_root"
for coordinator_syntax_denial in \
  "find $kimi_find_a $kimi_find_b -maxdepth 2 -type f -exec rm -f {} \;" \
  "find $kimi_find_a $kimi_find_b -maxdepth 2 -type f -print > $TMP_ROOT/find-output" \
  "find $kimi_find_a $kimi_find_b* -maxdepth 2 -type f -print" \
  "ls -ld $kimi_root $kimi_find_b*" \
  "stat -Lc '%i %a %n' $kimi_root/hooks/validate-bash.sh > $TMP_ROOT/stat-output"; do
  assert_denied "$coordinator_syntax_denial"
done
for coordinator_finite_argv in \
  "find $kimi_find_a $kimi_find_b -maxdepth 2 -type f -print /etc/passwd" \
  "find $kimi_find_a $kimi_find_b/../outside -maxdepth 2 -type f -print" \
  "ls -ld $kimi_root $kimi_find_b/../outside" \
  "stat -Lc '%i %a %n' $kimi_root/hooks/../outside" \
  "realpath -e $evidence_file && rm -f $TMP_ROOT/denied"; do
  assert_allowed "$coordinator_finite_argv"
done
assert_denied "cat $evidence_dir/outside-link"
worker_kimi_find_output="$(run_subagent_hook "find $kimi_find_a $kimi_find_b -maxdepth 2 -type f -print | head -n 40")"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$worker_kimi_find_output" >/dev/null
worker_kimi_stat_output="$(run_subagent_hook "stat -Lc '%F %N' $kimi_root/hooks/validate-bash.sh")"
[ ! -s "$worker_kimi_stat_output" ]
worker_readlink_output="$(run_subagent_hook "readlink -f $ROOT/sessions")"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$worker_readlink_output" >/dev/null
for git_read_argv in \
  "git -C $ROOT -C $ROOT status --short" \
  "git -C $TMP_ROOT status --short" \
  "git -C $ROOT status --short ../outside" \
  "git -C $ROOT diff --stat /etc/passwd" \
  "git -C $ROOT diff -- /etc/passwd" \
  "git -C $ROOT diff -- ../outside" \
  "git -C $ROOT diff -- AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md AGENTS.md" \
  "git -C $ROOT log -1 --oneline ':(exclude)hooks'" \
  "git -C $ROOT show --stat -1 hooks//validate-bash.sh"; do
  assert_allowed "$git_read_argv"
done
assert_denied "git -C $ROOT diff -- :(exclude)AGENTS.md"
git_context_output="$(run_hook "git -C $ROOT -c user.name=test status --short")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_GIT_EXECUTION_CONTEXT_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=git-execution-context")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=-c argv_index=3")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("bounded coordinator Git route"))
' "$git_context_output" >/dev/null
git_environment_output="$(run_hook "GIT_DIR=$TMP_ROOT git -C $ROOT status --short")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=GIT_DIR=")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=leading-assignment"))
' "$git_environment_output" >/dev/null

# Read-only ls remains admitted through the full classifier when a transcript
# prevents the transcriptless fast path, including absolute inspection paths.
ls_output="$(run_hook_with_transcript "ls -la $ROOT")"
[ ! -s "$ls_output" ] || {
  cat -- "$ls_output" >&2
  exit 1
}

assert_commit() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("ECI commit boundary denied")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("unrecognized command form") | not)
  ' "$output" >/dev/null
}

# Active-ECI preparation is a coordinator-only bounded route.  It admits
# explicit path lists for staging/index transitions, while wrappers, pathspec
# magic, and broad/destructive forms remain unknown.
for prep in \
  "git add -- hooks/validate-bash.sh" \
  "git rm -- hooks/validate-bash.sh" \
  "git mv -- hooks/validate-bash.sh hooks/validate-bash.sh" \
  "git restore --staged -- hooks/validate-bash.sh"; do
  assert_allowed "$prep"
done
for unsafe_prep in \
  "git add ." \
  "git add -- ../outside" \
  "git rm -r -- hooks/validate-bash.sh" \
  "git mv -- hooks/validate-bash.sh ../outside" \
  "git restore --staged hooks/validate-bash.sh" \
  "env git add -- hooks/validate-bash.sh"; do
  assert_unknown "$unsafe_prep"
done
for worker_prep in \
  "git add -- hooks/validate-bash.sh" \
  "git rm -- hooks/validate-bash.sh" \
  "git mv -- hooks/validate-bash.sh hooks/validate-bash.sh" \
  "git restore --staged -- hooks/validate-bash.sh"; do
  worker_output="$(run_subagent_hook "$worker_prep")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("acceptance-sensitive Git mutation"))' "$worker_output" >/dev/null
done

assert_denied() {
  local command="$1" output
  output="$(run_hook "$command")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null || {
    printf 'assert_denied failed: command=%q output=%s\n' "$command" "$output" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

# Executable identity is not an allowlist boundary. A finite direct argv stays
# ordinary even when a task-owned executable happens to be named `git`.
fake_bin="$TMP_ROOT/fake-bin"
mkdir -p "$fake_bin"
cp -- /bin/true "$fake_bin/git"
chmod +x "$fake_bin/git"
assert_allowed "$fake_bin/git status"

assert_subagent_lifecycle_denied() {
  local command="$1" output
  output="$(run_subagent_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    ((.hookSpecificOutput.permissionDecisionReason | contains("Only the main/orchestrator may mutate ECI lifecycle")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("Only the main thread/orchestrator may disengage ECI with eci-active off")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("ECI_COMMAND_WRAPPER_UNSUPPORTED")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("ECI_COMMAND_DYNAMIC_INDIRECTION_DENIED")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("ECI_PLAN_DYNAMIC_LAUNCH_DENIED")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("ECI_ENVIRONMENT_OPTION_DENIED")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("unsupported shell/interpreter wrapper")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("unsupported shell/interpreter launcher")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("ECI_CONTROL_OWNER_REQUIRED")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("command path owned by the coordinator")))
  ' "$output" >/dev/null
}

assert_subagent_unknown_command_denied() {
  local command="$1" output
  output="$(run_subagent_hook "$command")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null || {
    printf 'failed subagent command: %s\n' "$command" >&2
    cat "$output" >&2
    return 1
  }
}

eci="$ROOT/bin/eci-active"
# Activation is a coordinator-owned ECI lifecycle control action.  It must be
# admitted by the command classifier so a new ECI task can start through the
# canonical lifecycle binary rather than bypassing the PreToolUse boundary.
assert_allowed "$eci on classifier-activation"
assert_allowed "$eci --help"
assert_allowed "$eci status"
assert_allowed "$eci ledger-append 'entry with \`literal\` and \$dollar'"

# Exercise the real wait/resume path as a parser regression.  In particular,
# resume must clear the state without taking a syntax-error branch.
wait_report="$proof_root/t00-session/eci_user_owned_wait.md"
printf '%s\n' \
  '# ECI User-Owned Wait' \
  'state: user-owned-wait' \
  'blocker_id: classifier-resume' \
  'state_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'owner: user' \
  'brp_result: exhausted-no-feasible-internal-path' \
  'user_owned_input: unobtainable' \
  'unblock_kind: input' \
  'unblock: changed user-owned input required' \
  >"$wait_report"
CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session CODEX_HOME="$ROOT" \
  "$eci" wait "$wait_report" >/dev/null
CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session CODEX_HOME="$ROOT" \
  "$eci" resume bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null
[ ! -e "$proof_root/t00-session/eci_wait" ]

for lifecycle in \
  "$eci off $TMP_ROOT/disengage.md" \
  "$eci wait $TMP_ROOT/eci_user_owned_wait.md" \
  "$eci resume aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "$ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "$eci ledger-append one-line-entry" \
  "$eci nested-enter 1 2 t00-session" \
  "$eci nested-accept" \
  "$eci nested-exit" \
  "$eci manifest-write $proof_root/t00-session/eci-required-critics.json.source"; do
  assert_allowed "$lifecycle"
done
stale_report="$proof_root/019ff790-0000-7000-8000-000000000001/disengage.md"
assert_allowed "$eci off $stale_report"

# A deployed CODEX_HOME may be reached through a symlink even though the
# lifecycle binary itself is the canonical file.  Compare resolved executable
# paths rather than rejecting this safe alias.
alias_home="$TMP_ROOT/codex-home-alias"
ln -s "$ROOT" "$alias_home"
alias_output="$TMP_ROOT/alias-output"
jq -cn --arg cwd "$ROOT" --arg command "$alias_home/bin/eci-active off $TMP_ROOT/disengage.md" \
  '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$alias_home" PATH="$alias_home/bin:$PATH" \
    bash "$ROOT/hooks/validate-bash.sh" >"$alias_output"
[ ! -s "$alias_output" ]

# Canonical review-gate identity is protected before ordinary finite-literal
# admission, including shell-script invocation and malformed argument shapes.
for launcher in \
  "$ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash $ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash -e $ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash -x $ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash -O extglob $ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash --noprofile $ROOT/hooks/eci-review-gate.sh commit t00-session" \
  "bash $ROOT/hooks/eci-review-gate.sh unknown t00-session" \
  "bash $ROOT/hooks/eci-review-gate.sh commit" \
  "bash $ROOT/hooks/eci-review-gate.sh commit t00-session extra"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_REVIEW_GATE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-review-gate")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("provider=codex")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("role=worker")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("marker=active")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("segment=1")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("path=n/a")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-lifecycle-control")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
done
output="$(run_subagent_hook "python3 -c 'open(\"$proof_root/t00-session/eci_wait\",\"w\").write(\"x\")'")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=-c")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=1")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-interpreter-launch"))
' "$output" >/dev/null
for launcher in \
  "bash -O extglob $ROOT/hooks/stop-gate.sh" \
  "bash --noprofile $ROOT/hooks/stop-gate.sh" \
  "bash -n hooks/stop-gate.sh" \
  "sh -e $ROOT/hooks/stop-gate.sh"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_CONTROL_OWNER_REQUIRED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-control")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-lifecycle-control")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
done

# Explicit hook test entry points remain bounded worker routes.
output="$(run_subagent_hook "bash hooks/tests/test-eci-fast-path.sh")"
[ ! -s "$output" ]
output="$(run_subagent_hook "bash hooks/tests/test-validate-bash-git-approvals.sh")"
[ ! -s "$output" ]
output="$(run_subagent_hook "bash hooks/tests/test-pre-commit-go-mod.sh")"
[ ! -s "$output" ]

# Ordinary repository-local test scripts are admitted as finite literals; a
# reviewed digest is not executable authority outside protected routes.
mutable_script="$ROOT/hooks/tests/test-eci-fast-path.sh"
mutable_backup="$TMP_ROOT/test-eci-fast-path.backup"
cp -- "$mutable_script" "$mutable_backup"
printf '%s\n' '# worker mutation probe' >>"$mutable_script"
output="$(run_subagent_hook "bash hooks/tests/test-eci-fast-path.sh")"
cp -- "$mutable_backup" "$mutable_script"
[ ! -s "$output" ]
assert_allowed "eci-active nested-exit"

# Startup-sensitive execution context must not be attached to an allowlisted
# test script.  In particular, a BASH_ENV probe must be denied before the
# reviewed script could start; validation itself must not execute the probe.
bash_env_probe="$TMP_ROOT/bash-env-probe"
printf '%s\n' "touch '$TMP_ROOT/bash-env-ran'" >"$bash_env_probe"
for injected in \
  "BASH_ENV=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "ENV=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "CDPATH=$TMP_ROOT bash hooks/tests/test-eci-fast-path.sh" \
  "PYTHONSTARTUP=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "RUBYOPT=-r$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "NODE_OPTIONS=--require=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "PERL5OPT=-I$TMP_ROOT bash hooks/tests/test-eci-fast-path.sh" \
  "PATH=$TMP_ROOT bash hooks/tests/test-eci-fast-path.sh" \
  "env BASH_ENV=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh" \
  "env -S 'BASH_ENV=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh'"; do
  assert_denied "$injected"
done
[ ! -e "$TMP_ROOT/bash-env-ran" ]
output="$(run_subagent_hook "BASH_ENV=$bash_env_probe bash hooks/tests/test-eci-fast-path.sh")"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null
[ ! -e "$TMP_ROOT/bash-env-ran" ]

for lifecycle in \
  "env -u CODEX_ROLE bash $subagent_codex_home/bin/eci-active nested-enter 1 2 t00-session" \
  "env -u CODEX_ROLE bash $subagent_codex_home/bin/eci-active nested-accept" \
  "env -u CODEX_ROLE bash $subagent_codex_home/bin/eci-active nested-exit" \
  "env -u CODEX_ROLE bash $subagent_codex_home/bin/eci-active manifest-write $proof_root/t00-session/eci-required-critics.json.source" \
  "env -u CODEX_ROLE command bash $subagent_codex_home/bin/eci-active nested-exit"; do
  assert_subagent_lifecycle_denied "$lifecycle"
done

# A copied lifecycle binary remains protected by identity, while an ordinary
# finite executable is admitted without an executable-name allowlist.
copied_eci="$TMP_ROOT/eci-active-copy"
copied_worker="$TMP_ROOT/worker-script"
cp -- "$ROOT/bin/eci-active" "$copied_eci"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$copied_worker"
chmod +x "$copied_eci" "$copied_worker"
for launcher in \
  "$copied_eci off $TMP_ROOT/disengage.md" \
  "$copied_eci wait $TMP_ROOT/eci_user_owned_wait.md"; do
  output="$(run_subagent_hook "$launcher")"
  [ ! -s "$output" ]
done
output="$(run_subagent_hook "$copied_worker")"
[ ! -s "$output" ]

# Dynamic execution-context mutation and writer forms remain protected.
for launcher in \
  "export PATH=$TMP_ROOT" \
  "hash -p $copied_worker eci-active" \
  "PATH=$TMP_ROOT eci-unknown-helper"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    ((.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]"))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
    ((.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-launch")) or
     (.hookSpecificOutput.permissionDecisionReason | contains("predicate=leading-assignment"))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
done
output="$(run_subagent_hook "gitleaks detect -r")"
[ ! -s "$output" ]
for launcher in \
  "gitleaks detect --report-path $proof_root/t00-session/report.json" \
  "gitleaks detect --report-path=$proof_root/t00-session/report.json" \
  "diff --to-file $proof_root/t00-session/diff.out $ROOT/hooks/validate-bash.sh" \
  "sort -o $proof_root/t00-session/sort.out $ROOT/hooks/validate-bash.sh"; do
  assert_subagent_unknown_command_denied "$launcher"
done

# The reserved eci-stage lifecycle target remains coordinator-owned when its
# visible argv selects lifecycle verbs.
renamed_eci="$subagent_codex_home/bin/eci-stage"
cp -- "$ROOT/bin/eci-active" "$renamed_eci"
chmod +x "$renamed_eci"
for launcher in \
  "eci-stage ledger-append one-line-entry" \
  "eci-stage nested-enter 1 2 t00-session"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_CONTROL_OWNER_REQUIRED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-control")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-lifecycle-control"))' "$output" >/dev/null
done

# eval is arbitrary shell indirection, including when its payload appears to
# contain only a copied lifecycle command or a Git acceptance command.
for launcher in \
  "eval '$subagent_codex_home/bin/eci-active ledger-append one-line-entry'" \
  "eval '$subagent_codex_home/bin/eci-active nested-enter 1 2 t00-session'" \
  "eval 'git commit'"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null
done

# Source indirection is dynamic shell execution and remains denied.
for launcher in \
  "source /tmp/eci-escape.sh" \
  ". /tmp/eci-escape.sh"; do
  output="$(run_subagent_hook "$launcher")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null
done

# Transparent wrappers around one visible finite argv remain executable-
# agnostic.  The same wrappers must preserve a visible Git acceptance denial.
for launcher in \
  "env" \
  "exec" \
  "nohup" \
  "setsid" \
  "sudo" \
  "doas" \
  "systemd-run --unit eci"; do
  output="$(run_subagent_hook "$launcher /tmp/eci-escape.sh")"
  [ ! -s "$output" ]
  output="$(run_subagent_hook "$launcher git commit -m nope")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]") and contains("operation=worker-git-ownership") and contains("git commit -m nope") and contains("token=commit") and contains("main/orchestrator"))
  ' "$output" >/dev/null
done

# Bounded resource wrappers recurse into one finite literal argv.  An ordinary
# payload remains ordinary, while a visible Git acceptance mutation remains
# coordinator-owned through the same wrapper.
for wrapper in \
  "timeout 5" \
  "time" \
  "nice" \
  "prlimit --cpu=1" \
  "chronic"; do
  output="$(run_subagent_hook "$wrapper /tmp/eci-escape.sh")"
  [ ! -s "$output" ]
  output="$(run_subagent_hook "$wrapper git commit -m nope")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]") and contains("operation=worker-git-ownership") and contains("git commit -m nope") and contains("token=commit") and contains("main/orchestrator"))
  ' "$output" >/dev/null
done

# Lifecycle ownership is based on the visible mutation verb, not successful
# CLI arity.  Extra arguments and `on` must not become worker escape routes.
for lifecycle in \
  "env -u CODEX_ROLE $subagent_codex_home/bin/eci-active on worker-scope extra" \
  "source $subagent_codex_home/bin/eci-active off $TMP_ROOT/disengage.md extra" \
  "env -u CODEX_ROLE bash -c 'source $subagent_codex_home/bin/eci-active on worker-scope extra'"; do
  assert_subagent_lifecycle_denied "$lifecycle"
done

# Acceptance-sensitive Git history mutations remain main/orchestrator-only;
# this is independent of the ordinary worker edit route.
for command in \
  "git commit" \
  "env -u CODEX_ROLE git commit"; do
  output="$(run_subagent_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-git-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=commit")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("main/orchestrator"))
  ' "$output" >/dev/null
done
output="$(run_subagent_hook "bash -c 'git commit'")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=-c")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-interpreter-launch"))
' "$output" >/dev/null

# Unsupported shell launchers must not hide lifecycle mutation from the
# subagent ownership gate. These strings are parsed as control commands, not
# executed by this regression.
for lifecycle in \
  "source $subagent_codex_home/bin/eci-active off $TMP_ROOT/disengage.md" \
  ". $subagent_codex_home/bin/eci-active wait $TMP_ROOT/eci_user_owned_wait.md" \
  "$subagent_codex_home/bin/eci-active ledger-append one-line-entry" \
  "source bin/eci-active wait $TMP_ROOT/eci_user_owned_wait.md" \
  "env -u CODEX_ROLE bash -c 'source bin/eci-active wait $TMP_ROOT/eci_user_owned_wait.md'" \
  "env -S '$subagent_codex_home/bin/eci-active resume aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'" \
  "xargs -n 1 $subagent_codex_home/bin/eci-active off $TMP_ROOT/disengage.md"; do
  assert_subagent_lifecycle_denied "$lifecycle"
done
output="$(run_subagent_hook "find . -exec $subagent_codex_home/bin/eci-active off $TMP_ROOT/disengage.md \\;")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=-exec")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-find-action"))
' "$output" >/dev/null

# Lifecycle identity does not make dynamic shell indirection admissible.
# Coordinators use the canonical executable directly rather than source or
# inline-code launchers.
for dynamic_lifecycle in \
  "source ./bin/eci-active off $TMP_ROOT/disengage.md" \
  "env -u CODEX_ROLE bash -c 'source $ROOT/bin/eci-active wait $TMP_ROOT/eci_user_owned_wait.md'"; do
  output="$(run_hook "$dynamic_lifecycle")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_DYNAMIC_LAUNCH_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=source") or contains("token=-c")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-launch") or contains("predicate=dynamic-interpreter-launch"))
  ' "$output" >/dev/null
done

assert_subagent_control_denied() {
  local command="$1" output
  output="$(run_subagent_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("phase=PreToolUse")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
}

# Workers may edit repository files, but cannot mutate proof-root control
# records through generic shell/file utilities or a nested shell payload.
for mutation in \
  "rm -f $proof_root/t00-session/eci_active" \
  "unlink $proof_root/t00-session/eci_active" \
  "shred -f $proof_root/t00-session/eci_active" \
  "find $proof_root -name eci_active -delete" \
  "env -u CODEX_ROLE rm -f $proof_root/t00-session/eci_wait" \
  "printf forged > $proof_root/t00-session/eci_wait" \
  "printf forged > $proof_root/t00-session/high_level_log.anchor" \
  "cp $ROOT/hooks/validate-bash.sh $proof_root/t00-session/eci-required-critics.json" \
  "bash -c 'printf forged > $proof_root/t00-session/eci-teardown-complete'" \
  "touch $proof_root/t00-session/eci-acceptance-anchor" \
  "command rm -f $proof_root/t00-session/eci_active" \
  "timeout 5 bash -c 'printf forged > $proof_root/t00-session/eci_wait'" \
  "env -S 'printf forged > $proof_root/t00-session/eci-required-critics.json'" \
  "find . -exec rm -f $proof_root/t00-session/eci-teardown-complete \\;"; do
  assert_subagent_control_denied "$mutation"
done

# A visible dd destination names the exact live record and remains protected.
for mutation in \
  "dd if=/dev/null of=$proof_root/t00-session/eci_wait"; do
  assert_subagent_control_denied "$mutation"
done

# Reserved state is protected by name even before the file exists; a worker
# must not bootstrap coordinator evidence through a generic writer.
for mutation in \
  "touch $proof_root/t00-session/eci-required-critics.json" \
  "touch $proof_root/t00-session/eci-required-critics.commit.1.ledger" \
  "touch $proof_root/t00-session/eci-critic-identities.ledger" \
  "touch $proof_root/t00-session/eci-acceptance-anchor" \
  "touch $proof_root/t00-session/eci-acceptance-transaction" \
  "touch $proof_root/t00-session/eci-teardown-complete" \
  "touch $proof_root/t00-session/baseline_head"; do
  assert_subagent_control_denied "$mutation"
done

# Recognizable writer options that name an exact live record remain protected.
for mutation in \
  "rsync $ROOT/hooks/validate-bash.sh $proof_root/t00-session/eci_wait" \
  "rsync --log-file=$proof_root/t00-session/eci_wait $ROOT/hooks/validate-bash.sh $TMP_ROOT/worker-copy" \
  "rsync --batch-file=$proof_root/t00-session/eci_wait $ROOT/hooks/validate-bash.sh $TMP_ROOT/worker-copy"; do
  assert_subagent_control_denied "$mutation"
done

# Attached dd destinations remain exact live-control attempts.
for mutation in \
  "dd of=$proof_root/t00-session/eci_wait if=/dev/null" \
  "dd if=/dev/null of=$proof_root/t00-session/eci_wait"; do
  assert_subagent_control_denied "$mutation"
done

# Lexical control paths remain protected even when their final component is a
# symlink resolving outside the proof root.
symlink_target="$TMP_ROOT/external-control"
printf forged >"$symlink_target"
ln -s "$symlink_target" "$proof_root/t00-session/eci_wait-link"
assert_subagent_control_denied "rm -f $proof_root/t00-session/eci_wait-link"
assert_subagent_control_denied "printf forged > $proof_root/t00-session/eci_wait-link"

# Tilde expansion must resolve against the active proof-root home, not evade
# the path-aware control-file mutation check.
tilde_home="$TMP_ROOT/tilde-home"
tilde_root="$tilde_home/.cache/codex-proof"
mkdir -p "$tilde_root/t00-session"
output="$(run_subagent_hook_at_root "rm -f ~/.cache/codex-proof/t00-session/eci_active" "$tilde_root" "$tilde_home")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=shell-expansion"))' "$output" >/dev/null

# The cache parent may itself be symlinked.  Canonicalize the candidate before
# applying the proof-root control-path check so this deployment layout cannot
# evade the worker mutation boundary.
symlink_cache_home="$TMP_ROOT/symlink-cache-home"
symlink_cache_target="$TMP_ROOT/symlink-cache-target"
mkdir -p "$symlink_cache_home" "$symlink_cache_target"
ln -s "$symlink_cache_target" "$symlink_cache_home/.cache"
ln -s "$proof_root" "$symlink_cache_target/codex-proof"
output="$(run_subagent_hook_at_root "rm -f ~/.cache/codex-proof/t00-session/eci_active" "$proof_root" "$symlink_cache_home")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=shell-expansion"))' "$output" >/dev/null
ordinary_worker_file="$TMP_ROOT/ordinary-worker-file"
output="$(run_subagent_hook "printf ordinary > $ordinary_worker_file")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and (.hookSpecificOutput.permissionDecisionReason | contains("token=>")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=redirection"))' "$output" >/dev/null

# Branch/remote mutators are unknown under ECI; safe inspection forms remain
# read-only.
for command in \
  "git branch -d doomed" \
  "git branch feature" \
  "git branch --set-upstream-to=origin/main" \
  "git remote add origin https://example.invalid/repo.git" \
  "git remote set-url origin https://example.invalid/repo.git"; do
  assert_unknown "$command"
done
for protected_ref in \
  "git branch --set-upstream-to=origin/main" \
  "git branch feature" \
  "git remote set-url origin https://example.invalid/repo.git"; do
  output="$(run_hook "$protected_ref")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_GIT_BRANCH_REMOTE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=git-branch-remote")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("subcommand=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
  output="$(run_subagent_hook "$protected_ref")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-git-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-git-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("argv_index=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
done
# `git archive` reads a tree and emits an archive; it does not mutate Git
# acceptance/history.  Direct and explicit-output forms are ordinary finite
# project work because the destination is not an exact live-control artifact.
assert_allowed "git archive HEAD"
archive_worker_output="$(run_subagent_hook "git archive HEAD")"
[ ! -s "$archive_worker_output" ]
for command in \
  "git archive --output=$proof_root/t00-session/archive.tar HEAD" \
  "git archive --format=tar --output=$proof_root/t00-session/archive.tar HEAD"; do
  assert_allowed "$command"
  archive_worker_output="$(run_subagent_hook "$command")"
  [ ! -s "$archive_worker_output" ]
done

# Explorers may inspect project, skill, Git, and bounded proof metadata without
# being mistaken for worker launchers.  These are literal read-only forms;
# shell indirection, redirects, and proof-state writes remain covered below.
for command in \
  "sed -n '1p' CODEX.md" \
  "sed -n '1p' skills/explore-critique-implement/SKILL.md" \
  "printenv PATH" \
  "rg --files -g '*.md' ." \
  "find . -maxdepth 1 -type f -print"; do
  explorer_output="$(run_subagent_hook "$command")"
  [ ! -s "$explorer_output" ] || {
    cat -- "$explorer_output" >&2
    exit 1
  }
done
# Workers may read bounded coordinator handoff documents, but lifecycle
# markers and redirects remain denied by the control-path boundary.
for command in \
  "cat $instructions_file" \
  "sed -n '1p' $instructions_file" \
  "rg -n coordinator $high_level_log"; do
  control_read_output="$(run_subagent_hook "$command")"
  [ ! -s "$control_read_output" ] || {
    cat -- "$control_read_output" >&2
    exit 1
  }
done
control_read_output="$(run_subagent_hook "cat $proof_root/t00-session/eci_active")"
jq -e --arg target "$proof_root/t00-session/eci_active" '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_LIVE_CONTROL_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=plan-segment")) and
  (.hookSpecificOutput.permissionDecisionReason | contains(("token=" + $target))) and
  (.hookSpecificOutput.permissionDecisionReason | contains(("path=" + $target))) and
  (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-live-control")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
' "$control_read_output" >/dev/null
# Workers must be able to load canonical provider instructions and installed
# skill resources even when those files are hard-linked elsewhere.  Claimed
# instruction paths that are missing, outside configured roots, or escape
# through a symlink fail with their exact path-ownership reason.
instruction_read_output="$(run_subagent_hook "wc -l $ROOT/CODEX.md $ROOT/skills/explore-critique-implement/SKILL.md $ROOT/skills/writing-status-reports/SKILL.md $ROOT/skills/harness-tuning/SKILL.md")"
[ ! -s "$instruction_read_output" ]
instruction_read_output="$(run_subagent_hook "wc -l $subagent_codex_home/CODEX.md $subagent_codex_home/AGENTS.md $subagent_codex_home/skills/test/SKILL.md")"
[ ! -s "$instruction_read_output" ]
instruction_read_output="$(run_subagent_hook "rg -n worker $subagent_codex_home/skills/test")"
[ ! -s "$instruction_read_output" ]
instruction_read_output="$(run_subagent_hook "git log --format=%H -- skills/writing-status-reports/SKILL.md CODEX.md")"
[ ! -s "$instruction_read_output" ]
for instruction_case in \
  "$subagent_codex_home/skills/missing/SKILL.md|missing-instruction-source" \
  "$external_skill_root/SKILL.md|outside-instruction-root" \
  "$subagent_codex_home/skills/escape/SKILL.md|symlink-escape" \
  "$subagent_codex_home/skills/test/not-a-source.fifo|not-regular-file"; do
  instruction_path="${instruction_case%%|*}"
  instruction_failure="${instruction_case#*|}"
  instruction_read_output="$(run_subagent_hook "cat $instruction_path")"
  jq -e --arg token "$instruction_path" --arg failure "$instruction_failure" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_INSTRUCTION_READ_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-instruction-read")) and
    (.hookSpecificOutput.permissionDecisionReason | contains(("token=" + $token))) and
    (.hookSpecificOutput.permissionDecisionReason | contains(("failure=" + $failure))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("resolved=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("instruction_root=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$instruction_read_output" >/dev/null
done
# Git history reads over canonical instruction sources do not weaken the
# protected Git ownership boundary.
for protected_worker_git in \
  "git commit -m forbidden" \
  "git config user.name worker" \
  "git reset --hard HEAD" \
  "git worktree add /tmp/eci-worker-tree HEAD"; do
  instruction_read_output="$(run_subagent_hook "$protected_worker_git")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$instruction_read_output" >/dev/null
done
# Finite direct Git inspection is ordinary worker project work. Protected Git
# mutations and executable-helper options are rejected by their own ownership
# recognizers rather than by a read-command allowlist.
for command in \
  "git status --short" \
  "git status --short --branch" \
  "git submodule status" \
  "git diff --stat" \
  "git log -1 --oneline" \
  "git branch --all --contains HEAD"; do
  assert_allowed "$command"
  worker_git_output="$(run_subagent_hook "$command")"
  [ ! -s "$worker_git_output" ] || {
    cat -- "$worker_git_output" >&2
    exit 1
  }
done
worker_git_chain_output="$(run_subagent_hook 'git status --short && git submodule status && git diff --stat')"
[ ! -s "$worker_git_chain_output" ]
for environment_role in coordinator worker; do
  for environment_command in \
    "printenv PATH" \
    "printenv PATH PWD" \
    "env FOO=bar novel-tool --flag value" \
    "env -i novel-tool" \
    "env -u FOO novel-tool" \
    "rg -n 'env | sort' hooks/validate-bash.sh"; do
    environment_output="$(run_role_hook "$environment_role" "$environment_command")"
    [ ! -s "$environment_output" ] || {
      printf 'environment matrix unexpectedly denied: role=%s command=%q\n' "$environment_role" "$environment_command" >&2
      cat -- "$environment_output" >&2
      exit 1
    }
  done
  assert_role_environment_denied "$environment_role" "env" ECI_ENVIRONMENT_ENUMERATION_DENIED env 0
  assert_role_environment_denied "$environment_role" "env | sort" ECI_ENVIRONMENT_ENUMERATION_DENIED env 0
  assert_role_environment_denied "$environment_role" "env | sort | rg '^PATH='" ECI_ENVIRONMENT_ENUMERATION_DENIED env 0
  assert_role_environment_denied "$environment_role" "printenv" ECI_ENVIRONMENT_ENUMERATION_DENIED printenv 0
  assert_role_environment_denied "$environment_role" "printenv OPENAI_API_KEY" ECI_ENVIRONMENT_NAME_DENIED OPENAI_API_KEY 1
  assert_role_environment_denied "$environment_role" "printenv PATH OPENAI_API_KEY" ECI_ENVIRONMENT_NAME_DENIED OPENAI_API_KEY 2
  assert_role_environment_denied "$environment_role" "printenv PATH PATH" ECI_ENVIRONMENT_ENUMERATION_DENIED PATH 2 "" duplicated
  assert_role_environment_denied "$environment_role" "printenv PATH=bad" ECI_ENVIRONMENT_ENUMERATION_DENIED PATH=bad 1 "" identifier
  assert_role_environment_denied "$environment_role" "printenv -- PATH" ECI_ENVIRONMENT_OPTION_DENIED -- 1 "" unsupported
  assert_role_environment_denied "$environment_role" "env FOO=bar" ECI_ENVIRONMENT_ENUMERATION_DENIED env 0
  assert_role_environment_denied "$environment_role" "env -S 'novel-tool'" ECI_ENVIRONMENT_OPTION_DENIED -S 1 "" split-string
  assert_role_environment_denied "$environment_role" "env -u" ECI_ENVIRONMENT_OPTION_DENIED -u 1 "" "missing its required argument"
  assert_role_environment_denied "$environment_role" "env --unknown novel-tool" ECI_ENVIRONMENT_OPTION_DENIED --unknown 1 "" unsupported
  assert_role_environment_denied "$environment_role" "env --unset= novel-tool" ECI_ENVIRONMENT_OPTION_DENIED --unset= 1 "" "not a valid identifier"
  assert_role_environment_denied "$environment_role" "printenv PATH | env" ECI_ENVIRONMENT_ENUMERATION_DENIED env 0
  assert_role_environment_denied "$environment_role" \
    "env BASH_ENV=eci-private-bash-value bash script.sh" \
    ECI_ENVIRONMENT_CONTEXT_DENIED BASH_ENV 1 eci-private-bash-value
  assert_role_environment_denied "$environment_role" \
    "env GIT_DIR=eci-private-git-value git status" \
    ECI_ENVIRONMENT_CONTEXT_DENIED GIT_DIR 1 eci-private-git-value
  environment_output="$(run_role_hook "$environment_role" "env FOO=bar rm -rf /")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_BROAD_DESTRUCTIVE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("path=/")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=broad-destructive"))
  ' "$environment_output" >/dev/null
done
worker_unknown_output="$(run_subagent_hook "unrecognized-worker-command")"
[ ! -s "$worker_unknown_output" ]

# Transcriptless coordinator-shaped payloads still use the same ownership
# gate.  An ordinary finite read outside the repository is not a protected
# ECI capability and must not require executable- or path-name allowlisting.
transcriptless_outside_output="$(run_hook "cat /etc/passwd")"
[ ! -s "$transcriptless_outside_output" ]


# Read-only batches may contain only finite semicolon/pipeline segments.  The
# active coordinator path admits these segments, while ambiguous operators and
# wrappers remain compiler-diagnostic denials.
for batch in \
  "bash hooks/tests/test-eci-fast-path.sh && bash hooks/tests/test-eci-post-compact-refresh.sh" \
  "bash hooks/tests/test-eci-fast-path.sh && bash -n hooks/stop-gate.sh" \
  "git status --short || true" \
  "git status --short --branch && git diff --stat" \
  "rg -n 'ECI' $ROOT/hooks/validate-bash.sh | head -n 5" \
  "git diff -U8 -- hooks/validate-bash.sh hooks/tests/test-validate-bash-classifier.sh hooks/tests/test-eci-command-syntax-gating.sh | rg -n -C 18 'coordinator_compound_inspection_route|eci_finite_literal_argv|WORKER_COMMAND|operator/token=|adb devices|rev-parse|git status --short --branch'" \
  "ps -eo pid,ppid,etimes,stat,args | rg 'test-validate-bash|test-eci-command-syntax|test-pretooluse-latency|validate-bash.sh|worker_stat_root_cause|codex exec'" \
  "printf '%s\\n' coordinator ; git -C $ROOT status --short ; rg -n 'ECI' hooks/validate-bash.sh | head -n 5" \
  "ls -la $ROOT | wc -l" \
  "git status --short ; git diff --stat" \
  "rg --files -g '*.md' . | head -n 5" \
  "ls -la $ROOT && wc -l $ROOT/CODEX.md" \
  "git -C $ROOT log -1 --oneline" \
  "git -C $ROOT diff --check" \
  "git -C $ROOT submodule status" \
  "bash hooks/tests/test-eci-fast-path.sh && rm -f $TMP_ROOT/denied" \
  "bash hooks/tests/test-eci-fast-path.sh && bash hooks/tests/test-not-allowlisted.sh" \
  "git status --short || rm -f $TMP_ROOT/denied" \
  "ls -la $ROOT || wc -l $ROOT/CODEX.md"; do
  assert_allowed "$batch"
done
for batch in \
  "bash hooks/tests/test-eci-fast-path.sh && bash -c 'true'" \
  "bash -x hooks/tests/test-eci-review-gate.sh 2>&1 | tail -n 200" \
  "bash -x hooks/tests/test-eci-review-gate.sh 2>&1 | cat" \
  "bash -x hooks/tests/test-eci-review-gate.sh > $TMP_ROOT/trace" \
  "find -P $ROOT -maxdepth 1 -name CODEX.md -o -name AGENTS.md 2>/dev/null | head -n 5" \
  "ls -la $ROOT > $TMP_ROOT/read-output"; do
  assert_denied "$batch"
done
for batch in \
  "env" \
  "env | sort" \
  "env | sort | rg '^OPENAI_API_KEY='" \
  "env | sort | rg '^(PATH|OPENAI_API_KEY)='"; do
  assert_denied "$batch"
done
assert_allowed "git branch --show-current"
assert_allowed "git remote -v"
assert_allowed "git remote show origin"
for command in \
  "git branch -d doomed" \
  "git remote add origin https://example.invalid/repo.git"; do
  output="$(run_subagent_hook "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-git-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=worker-git-ownership")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null
done

assert_allowed "/tmp/eci-active off $TMP_ROOT/disengage.md"
assert_denied "PATH=/tmp eci-active off $TMP_ROOT/disengage.md"
assert_denied "CODEX_HOME=/tmp eci-active off $TMP_ROOT/disengage.md"
assert_denied "env PATH=/tmp eci-active off $TMP_ROOT/disengage.md"
assert_denied "env -i eci-active off $TMP_ROOT/disengage.md"
assert_denied "env -u PATH eci-active off $TMP_ROOT/disengage.md"
assert_denied "command -p eci-active off $TMP_ROOT/disengage.md"
for command in \
  "git -c user.name=test commit" \
  "git -c diff.external=/tmp/evil diff" \
  "git diff --textconv" \
  "git diff --ext-diff" \
  "git -c core.pager=cat status --short" \
  "git commit --git-dir /tmp/other.git" \
  "git commit --work-tree /tmp/other" \
  "git commit --exec-path /tmp/other" \
  "git --config-env user.name=GIT_NAME commit" \
  "git --exec-path /tmp commit" \
  "git --namespace test commit" \
  "env git commit" \
  "timeout 5 git commit" \
  "systemd-run --unit eci git commit" \
  "xargs git commit"; do
  assert_unknown "$command"
done
for command in \
  "git commit -m 'bounded message'" \
  "git commit --message=bounded" \
  "git commit -a --amend --no-verify --signoff" \
  "git commit --allow-empty" \
  "git commit -c prior-message"; do
  assert_commit "$command"
done
for command in \
  "env GIT_EXTERNAL_DIFF=/tmp/evil git diff --stat" \
  "env GIT_DIR=/tmp/other.git git status --short" \
  "GIT_EXTERNAL_DIFF=/tmp/evil git diff --stat"; do
  assert_unknown "$command"
done
assert_unknown ""
# A quoted search pattern containing the words `go test` is not an invocation
# of the Go test executable and must remain on the read-only path.
assert_allowed "rg -n 'go test' hooks/validate-bash.sh"
assert_allowed "rg -n -i 'go test' hooks/validate-bash.sh"
assert_allowed "rg -n -i subagent $kimi_root/hooks $kimi_root/bin"
assert_allowed "git grep -n -i subagent -- hooks bin"
assert_allowed "stat -c '%d:%i %a %h %n' hooks/pre-commit-go-mod.sh $kimi_root/hooks/pre-commit-go-mod.sh"
assert_allowed "rg -c 'run_hook|run_subagent_hook|assert_' hooks/tests/test-validate-bash-classifier.sh"
quoted_backtick_pattern="rg -n 'literal \` text' hooks/validate-bash.sh"
assert_allowed "$quoted_backtick_pattern"
assert_allowed "rg -n '...{64}...' hooks/validate-bash.sh"
assert_allowed 'rg -n "...{64}..." hooks/validate-bash.sh'
assert_allowed "stat -c '%y %n' hooks/validate-bash.sh"
# Executable and script names are not an ownership boundary.  A missing or
# novel finite script argv is admitted; execution reports its own file error.
assert_allowed "bash hooks/tests/test-not-allowlisted.sh"
assert_allowed "sed -n '1p' $high_level_log"
assert_allowed "sed --quiet '1,2p' $high_level_log"
# The coordinator inspection route admits bounded read-only inspection of
# approved repository sources as well as proof-root evidence.
assert_allowed "sed -n '1p' $ROOT/hooks/validate-bash.sh"
for sed_command in \
  "sed -i '1p' $high_level_log" \
  "sed -n '1d' $high_level_log" \
  "sed -n '1p' $high_level_log $high_level_log" \
  "sed -n '1p' -" \
  "sed -n '1p' $proof_root/t00-session/../t00-session/high_level_log.md"; do
  assert_allowed "$sed_command"
done
assert_allowed "awk '{print 1}' $ROOT/hooks/validate-bash.sh"
parameter_output="$(run_hook 'printf "%s" "$UNTRUSTED_COMMAND"')"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_SYNTAX_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("predicate=dynamic-expansion"))' "$parameter_output" >/dev/null
assert_allowed $'cat /dev/null\nrm -f /tmp/eci-multiline-marker'
assert_denied $'sh -c "cat /dev/null\nrm -f /tmp/eci-nested-marker"'
assert_denied $'eval "cat /dev/null\nrm -f /tmp/eci-eval-marker"'

for command in \
  "cat $ROOT/hooks/validate-bash.sh > $TMP_ROOT/read-output" \
  "cat $ROOT/hooks/validate-bash.sh >> $TMP_ROOT/read-output" \
  "cat < $ROOT/hooks/validate-bash.sh" \
  "cat << EOF" \
  "cat >| $TMP_ROOT/read-output" \
  "diff -o $TMP_ROOT/diff-output $ROOT/hooks/validate-bash.sh $ROOT/hooks/validate-bash.sh" \
  "diff --output $TMP_ROOT/diff-output $ROOT/hooks/validate-bash.sh $ROOT/hooks/validate-bash.sh" \
  "diff --to-file $TMP_ROOT/diff-output $ROOT/hooks/validate-bash.sh" \
  "sort -o $TMP_ROOT/sort-output $ROOT/hooks/validate-bash.sh" \
  "gitleaks detect -r" \
  "gitleaks detect --report-path $TMP_ROOT/report-output" \
  "gitleaks detect --report-path=$TMP_ROOT/report-output"; do
  assert_unknown "$command"
done

assert_denied "cat <(rm -f $TMP_ROOT/process-substitution-marker)"
assert_denied "cat >($TMP_ROOT/process-substitution-marker)"
assert_denied "echo {danger}"
[ ! -e "$TMP_ROOT/process-substitution-marker" ]

# Raw shell redirection cannot prove the lock, cap preflight, prefix, and
# anchor update. It is denied even for the canonical log; use the lifecycle
# command above instead.
assert_unknown "printf '%s\\n' appended >> $high_level_log"
assert_unknown "printf '%s\\n' rewritten > $high_level_log"
assert_unknown "printf '%s\\n' alias >> ./high_level_log.md"
log_alias="$proof_root/t00-session/high-level-log-alias.md"
ln -s "$high_level_log" "$log_alias"
assert_unknown "printf '%s\\n' alias >> $log_alias"
# A symlink remains a bounded inspection target only when its resolved path
# stays under an approved root.
assert_allowed "sed -n '1p' $log_alias"
outside_log="$TMP_ROOT/outside-high-level-log.md"
printf '%s\n' '# outside proof root' >"$outside_log"
outside_log_alias="$proof_root/t00-session/high-level-log-outside-alias.md"
ln -s "$outside_log" "$outside_log_alias"
outside_alias_output="$(run_hook "sed -n '1p' $outside_log_alias")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PROOF_PATH_ESCAPE_DENIED]")) and (.hookSpecificOutput.permissionDecisionReason | contains("operation=proof-path-ownership"))' "$outside_alias_output" >/dev/null
before_log="$(cat -- "$high_level_log")"
# The real route performs the append and advances its anchor under the
# mutation lock; its output is intentionally not admitted as a raw redirect.
CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session CODEX_HOME="$ROOT" \
  "$ROOT/bin/eci-active" ledger-append 'append-route' >/dev/null
append_route_line="$(tail -n 1 -- "$high_level_log")"
[[ "$append_route_line" =~ ^##\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ -\ append-route$ ]]

# The lifecycle route preflights the total byte budget before writing. A
# nearly-full anchored log must remain byte-identical when the next entry
# would cross the cap.
cap_session="cap-session"
cap_root="$TMP_ROOT/cap-proof"
cap_dir="$cap_root/$cap_session"
mkdir -p "$cap_dir"
printf '%s\n' \
  'scope: cap probe' \
  "cwd: $ROOT" \
  "session_id: $cap_session" \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$cap_dir/eci_active"
cap_log="$cap_dir/high_level_log.md"
head -c 1048569 /dev/zero | tr '\0' x >"$cap_log"
printf '\n' >>"$cap_log"
cap_bytes="$(wc -c <"$cap_log")"
cap_hash="$(sha256sum -- "$cap_log" | awk '{print $1}')"
printf '%s\n' \
  'schema: eci-high-level-log-anchor/v1' \
  "session_id: $cap_session" \
  "log_path: $cap_log" \
  "bytes: $cap_bytes" \
  "sha256: $cap_hash" \
  >"$cap_dir/high_level_log.anchor"
cap_anchor_hash="$(sha256sum -- "$cap_dir/high_level_log.anchor" | awk '{print $1}')"
if CODEX_PROOF_ROOT="$cap_root" CODEX_SESSION_ID="$cap_session" CODEX_HOME="$ROOT" \
    "$ROOT/bin/eci-active" ledger-append '0123456789' >"$TMP_ROOT/cap-append.out" 2>"$TMP_ROOT/cap-append.err"; then
  printf '%s\n' 'oversized ledger append unexpectedly succeeded' >&2
  exit 1
fi
[ "$(wc -c <"$cap_log")" = "$cap_bytes" ]
[ "$(sha256sum -- "$cap_log" | awk '{print $1}')" = "$cap_hash" ]
[ "$(sha256sum -- "$cap_dir/high_level_log.anchor" | awk '{print $1}')" = "$cap_anchor_hash" ]

# A middle insertion, replacement, or truncation invalidates the anchored
# prefix and must not be admitted as another append. Restore the exact bytes
# and anchor between probes so the final positive route remains meaningful.
stable_log="$(cat -- "$high_level_log")"
stable_anchor="$(cat -- "$proof_root/t00-session/high_level_log.anchor")"
printf '%s\n%s' 'forged middle' "$stable_log" >"$high_level_log"
assert_unknown "printf '%s\\n' rejected >> $high_level_log"
printf '%s' "$stable_log" >"$high_level_log"
printf '%s' "$stable_anchor" >"$proof_root/t00-session/high_level_log.anchor"
: >"$high_level_log"
assert_unknown "printf '%s\\n' rejected-after-truncate >> $high_level_log"
printf '%s' "$stable_log" >"$high_level_log"
printf '%s' "$stable_anchor" >"$proof_root/t00-session/high_level_log.anchor"

# Keep the user-authorized Git reset/worktree boundary in the focused
# classifier suite so its red/green behavior is exercised by the allowlisted
# test entry point.
bash "$ROOT/hooks/tests/test-validate-bash-git-approvals.sh"
printf '%s\n' 'validate-bash classifier tests: PASS'
