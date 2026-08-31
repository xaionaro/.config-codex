#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-normal-git-admission.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

# The live hook intentionally has a temporary line-2 bypass while this repair
# is in progress.  Exercise a complete private runtime with only that bypass
# removed, so this test continues to validate the actual gate source.
HOME_ROOT="$TMP_ROOT/home"
RUNTIME_ROOT="$HOME_ROOT/.codex"
mkdir -p -- "$RUNTIME_ROOT" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
cp -a -- "$SOURCE_ROOT/hooks" "$RUNTIME_ROOT"
mkdir -p -- "$RUNTIME_ROOT/bin"
cp -a -- "$SOURCE_ROOT/bin/eci-command-gate-mode" "$RUNTIME_ROOT/bin/"
[ "$(sed -n '2p' -- "$RUNTIME_ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'expected the live validate-bash temporary bypass at line 2' >&2
  exit 1
}
sed -i '2d' -- "$RUNTIME_ROOT/hooks/validate-bash.sh"

# Refresh only this private fixture's planner receipt. This keeps the test on
# the real hook path while avoiding a source build for every Git probe.
PLANNER_DIR="$RUNTIME_ROOT/hooks/lib/eci-command-plan-go"
(
  cd -- "$PLANNER_DIR"
  /usr/lib/go-1.24/bin/go build -trimpath -buildvcs=false -o eci-command-plan .
)
chmod 755 -- "$PLANNER_DIR/eci-command-plan"
planner_go_mod_sha="$(sha256sum -- "$PLANNER_DIR/go.mod" | awk '{print $1}')"
planner_main_sha="$(sha256sum -- "$PLANNER_DIR/main.go" | awk '{print $1}')"
planner_classifier_sha="$(sha256sum -- "$PLANNER_DIR/classifier.go" | awk '{print $1}')"
planner_binary_sha="$(sha256sum -- "$PLANNER_DIR/eci-command-plan" | awk '{print $1}')"
planner_binary_size="$(stat -Lc '%s' -- "$PLANNER_DIR/eci-command-plan")"
awk \
  -v go_mod="$planner_go_mod_sha" \
  -v main="$planner_main_sha" \
  -v classifier="$planner_classifier_sha" \
  -v binary="$planner_binary_sha" \
  -v size="$planner_binary_size" '
  $1 == "source_go.mod_sha256" { print $1 "\t" go_mod; next }
  $1 == "source_main.go_sha256" { print $1 "\t" main; next }
  $1 == "source_classifier.go_sha256" { print $1 "\t" classifier; next }
  $1 == "binary_sha256" { print $1 "\t" binary; next }
  $1 == "binary_size" { print $1 "\t" size; next }
  { print }
' "$PLANNER_DIR/.eci-command-plan.provenance" >"$PLANNER_DIR/.eci-command-plan.provenance.tmp"
mv -- "$PLANNER_DIR/.eci-command-plan.provenance.tmp" "$PLANNER_DIR/.eci-command-plan.provenance"
chmod 600 -- "$PLANNER_DIR/.eci-command-plan.provenance"

printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"

REPO="$TMP_ROOT/repo"
FOREIGN_REPO="$TMP_ROOT/foreign-repo"
NON_REPO="$TMP_ROOT/not-a-repository"
for path in "$REPO" "$FOREIGN_REPO"; do
  mkdir -p -- "$path"
  git -C "$path" init -q
  git -C "$path" config user.email normal-git-test@example.invalid
  git -C "$path" config user.name 'Normal Git Test'
  printf 'base\n' >"$path/file.txt"
  printf '{"fixture":true}\n' >"$path/hooks.json"
  printf '# Fixture\n' >"$path/README.md"
  git -C "$path" add -- file.txt hooks.json README.md
  git -C "$path" commit -qm initial
done
REPO="$(realpath -e -- "$REPO")"
FOREIGN_REPO="$(realpath -e -- "$FOREIGN_REPO")"
mkdir -p -- "$NON_REPO"
NON_REPO="$(realpath -e -- "$NON_REPO")"

SESSION='normal-git-session'
PROOF_ROOT="$TMP_ROOT/proof"
mkdir -p -- "$PROOF_ROOT/$SESSION"
printf '%s\n' \
  'scope: normal Git admission regression' \
  "cwd: $REPO" \
  "session_id: $SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$PROOF_ROOT/$SESSION/eci_active"

run_hook() {
  local command="$1" role="${2:-coordinator}" output="$TMP_ROOT/output.json" stderr=/dev/null
  local subagent=false
  if [ "$role" = worker ]; then
    subagent=true
  fi
  local -a runner=(bash)
  if [ "${DEBUG_GIT_HOOK:-false}" = true ]; then
    runner=(bash -x)
    stderr="$TMP_ROOT/hook-xtrace.log"
  fi
  jq -cn --arg session "$SESSION" --arg cwd "$REPO" --arg command "$command" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$HOME_ROOT" CODEX_HOME="$RUNTIME_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
      CODEX_ROLE="$role" CODEX_HOOK_IS_SUBAGENT="$subagent" \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$RUNTIME_ROOT/bin:$PATH" \
      "${runner[@]}" "$RUNTIME_ROOT/hooks/validate-bash.sh" >"$output" 2>>"$stderr"
  printf '%s\n' "$output"
}

assert_allowed() {
  local command="$1" role="${2:-coordinator}" output
  output="$(run_hook "$command" "$role")"
  if [ -s "$output" ]; then
    printf 'ordinary Git command was denied: %q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  fi
}

assert_denied_code() {
  local command="$1" code="$2" role="${3:-coordinator}" detail="${4:-}" output
  output="$(run_hook "$command" "$role")"
  jq -e --arg code "[$code]" --arg detail "$detail" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($code)) and
    ($detail == "" or (.hookSpecificOutput.permissionDecisionReason | contains($detail)))
  ' "$output" >/dev/null || {
    printf 'expected concrete %s denial for: %q\n' "$code" "$command" >&2
    cat -- "$output" >&2
    [ "${DEBUG_GIT_HOOK:-false}" != true ] || tail -n 240 -- "$TMP_ROOT/hook-xtrace.log" >&2
    return 1
  }
}

# Normal commits must not need an approval artifact or a review receipt.
assert_allowed "git commit -m 'ordinary commit'"

# Command spelling, `-C`, environment setup, and punctuation are not an
# accidental mistake by themselves.  The target remains this active repo.
assert_allowed "git -C $REPO commit -am 'ordinary commit'"
assert_allowed "env GIT_EDITOR=true /usr/bin/git -C $REPO commit --allow-empty -m 'ordinary commit'"
assert_allowed "printf prepare && git -C $REPO commit -m 'ordinary commit'"
[ ! -e "$REPO/.git-commit-approved-once" ]
[ ! -e "$PROOF_ROOT/$SESSION/eci-required-critics.json" ]
[ ! -e "$PROOF_ROOT/$SESSION/eci-commit-admitted" ]

# Targeted index changes are ordinary repository work.
assert_allowed "git -C $REPO add -- file.txt"
assert_allowed "git -C $REPO restore --staged -- file.txt"
assert_allowed "git -C $REPO reset -- file.txt"

# A worker's local index may stage explicit same-repository paths. The private
# fixture removes the live temporary bypass above, so these exercise the real
# planner and target resolver rather than an early exit.
assert_allowed "git add -- hooks.json" worker
assert_allowed "git add README.md" worker

# A valid timeout launch prefix does not change the Git target or effect. The
# worker may still stage a named path in this repository, while resolved
# foreign, whole-worktree, and reset-working-tree effects retain their
# concrete diagnostics.
assert_allowed "timeout 5 git add -- hooks.json" worker
assert_allowed "timeout +5 git add -- hooks.json" worker
assert_allowed "timeout -p 5 git add -- hooks.json" worker
assert_allowed "timeout -f 5 git add -- hooks.json" worker
assert_allowed "timeout --preserve-status 5 git add -- hooks.json" worker
assert_allowed "timeout --foreground 5 git add -- hooks.json" worker
assert_denied_code "timeout 5 git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "timeout -f 5 git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "timeout 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout +5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout -p 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout -f 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout --preserve-status 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout --foreground 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
assert_denied_code "timeout 5 git add -A" ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=-A"
assert_denied_code "timeout 5 git add --all" ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=--all"
assert_denied_code "timeout 5 git reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=reset-working-tree target=$REPO"
assert_denied_code "printf prepare && timeout 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO selector=."
# Timeout does not turn history acceptance into local index work.
assert_denied_code "timeout 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit"
# An incomplete timeout invocation or an unfamiliar launcher has no resolved
# Git effect for this advisory extractor. Let its own runtime decide it.
assert_allowed "timeout not-a-duration git add ." worker
assert_allowed "timeout --not-a-timeout-option 5 git add ." worker
assert_allowed "chronic git add ." worker

# Preserve only resolved accidental-risk boundaries.
assert_denied_code "git -C $REPO reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED
assert_denied_code "env GIT_EDITOR=true /usr/bin/git -C $REPO reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED
assert_denied_code "git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
# The same resolved foreign target stays cross-scope through ordinary wrapper
# and sequencing spellings. Punctuation is not the boundary; the target is.
assert_denied_code "env GIT_EDITOR=true /usr/bin/git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
assert_denied_code "printf prepare && git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
# A target that does not resolve to a repository has no known cross-scope
# mutation. Let Git report its ordinary runtime error instead of manufacturing
# an ECI denial from incomplete target information.
assert_allowed "git -C $NON_REPO add -- file.txt"

# The worker keeps the same concrete target/effect boundary: foreign staging,
# a known whole-worktree selector, and a working-tree reset remain denied.
assert_denied_code "git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO"
assert_denied_code "git reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=reset-working-tree target=$REPO"

printf '%s\n' 'normal Git admission: PASS'
