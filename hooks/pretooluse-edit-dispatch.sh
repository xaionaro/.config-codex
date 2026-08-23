#!/usr/bin/env bash

set -euo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$hook_dir/lib/codex-tmp.sh"
codex_init_tmp || true
tmp_dir="$(mktemp -d "$TMPDIR/codex-edit-dispatch.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

input_file="$tmp_dir/input.json"
cat >"$input_file"

tool_name="$(jq -r '.tool_name // empty' <"$input_file" 2>/dev/null || true)"
case "$tool_name" in
  apply_patch) validator="$hook_dir/validate-apply-patch.sh" ;;
  Edit|Write|MultiEdit|NotebookEdit) validator="$hook_dir/validate-edit-write.sh" ;;
  *) exit 0 ;;
esac

# Keep the synchronous gate set minimal without making a policy decision from
# an edit fixture.  The ATE hook has exactly one input-dependent predicate
# (the orchestrator role), while the security hook is advisory and can only
# emit a reminder when one of its documented tokens occurs in the payload.
# A false positive here merely retains the old extra process; a false
# negative would suppress a denial/reminder, so the matcher is intentionally
# a superset of the Python reminder predicates.
security_reminder_candidate() {
  case "$1" in
    *'.github/workflows/'*|*'child_process.exec'*|*'exec('*|*'execSync('*|*'new Function'*|*'eval('*|\
    *'dangerouslySetInnerHTML'*|*'document.write'*|*'.innerHTML ='*|*'.innerHTML='*|*'pickle'*|\
    *'os.system'*|*'from os import system'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Denying gates precede the advisory security reminder in the collection
# order. This keeps a reminder from hiding a validator, ECI, or ATE denial.
gates=(
  "$validator"
  "$hook_dir/eci-active-gate.sh"
)
case "${CODEX_ROLE:-}" in
  lead|coordinator) gates+=("$hook_dir/ate-orchestrator-gate.sh") ;;
esac
if [ "${ENABLE_SECURITY_REMINDER:-1}" != 0 ] && security_reminder_candidate "$(<"$input_file")"; then
  gates+=("$hook_dir/security-reminder.py")
fi
pids=()
for index in "${!gates[@]}"; do
  output_file="$tmp_dir/output-$index"
  error_file="$tmp_dir/error-$index"
  case "${gates[$index]}" in
    *.py) python3 "${gates[$index]}" <"$input_file" >"$output_file" 2>"$error_file" & ;;
    *) bash "${gates[$index]}" <"$input_file" >"$output_file" 2>"$error_file" & ;;
  esac
  pids[$index]=$!
done

statuses=()
# One denial is sufficient to reject an edit.  The validators run in parallel
# for the common allow path, but stop the remaining advisory/ownership gates
# as soon as the authoritative edit validator has produced a decision.  This
# avoids making a fast worker/control denial wait for unrelated gate startup.
if wait "${pids[0]}"; then
  statuses[0]=0
else
  statuses[0]=$?
fi
if [ "${statuses[0]}" -ne 0 ] || [ -s "$tmp_dir/output-0" ] || [ -s "$tmp_dir/error-0" ]; then
  for index in "${!pids[@]}"; do
    [ "$index" -eq 0 ] || kill "${pids[$index]}" 2>/dev/null || true
  done
  for index in "${!pids[@]}"; do
    [ "$index" -eq 0 ] || wait "${pids[$index]}" 2>/dev/null || true
  done
  if [ -s "$tmp_dir/error-0" ]; then
    cat "$tmp_dir/error-0" >&2
  fi
  [ ! -s "$tmp_dir/output-0" ] || cat "$tmp_dir/output-0"
  exit "${statuses[0]}"
fi
for index in "${!pids[@]}"; do
  [ "$index" -eq 0 ] && continue
  if wait "${pids[$index]}"; then
    statuses[$index]=0
  else
    statuses[$index]=$?
  fi
done

emitted=false
for index in "${!gates[@]}"; do
  if [ -s "$tmp_dir/error-$index" ]; then
    cat "$tmp_dir/error-$index" >&2
  fi
  if [ "$emitted" = false ] && [ -s "$tmp_dir/output-$index" ]; then
    cat "$tmp_dir/output-$index"
    emitted=true
  fi
done

for index in "${!statuses[@]}"; do
  if [ "${statuses[$index]}" -ne 0 ]; then
    exit "${statuses[$index]}"
  fi
done
