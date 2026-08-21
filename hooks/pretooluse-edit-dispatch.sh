#!/usr/bin/env bash

set -euo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-edit-dispatch.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

input_file="$tmp_dir/input.json"
cat >"$input_file"

tool_name="$(jq -r '.tool_name // empty' <"$input_file" 2>/dev/null || true)"
case "$tool_name" in
  apply_patch) validator="$hook_dir/validate-apply-patch.sh" ;;
  Edit|Write|MultiEdit|NotebookEdit) validator="$hook_dir/validate-edit-write.sh" ;;
  *) exit 0 ;;
esac

# Denying gates precede the advisory security reminder in the collection
# order. This keeps a reminder from hiding a validator, ECI, or ATE denial.
gates=(
  "$validator"
  "$hook_dir/eci-active-gate.sh"
  "$hook_dir/ate-orchestrator-gate.sh"
  "$hook_dir/security-reminder.py"
)
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
for index in "${!pids[@]}"; do
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
