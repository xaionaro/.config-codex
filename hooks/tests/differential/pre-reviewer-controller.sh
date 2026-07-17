#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPEC="$ROOT/proofs/Spec/PreReviewerController.lean"
PROOFS="$ROOT/proofs/Proofs/PreReviewerController.lean"
DRIVER="$ROOT/proofs/DiffTest/PreReviewerControllerMain.lean"
CONTROLLER="$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py"
LIFECYCLE="$ROOT/hooks/tests/pre_reviewer_lifecycle.py"
HARNESS="$ROOT/hooks/tests/differential/pre-reviewer-controller.sh"
WRAPPER="$ROOT/hooks/edit-bash-pre-reviewer.sh"
PROMPT_HOOK="$ROOT/hooks/prompt-task-reminder.sh"
BOUNDED_INPUT="$ROOT/hooks/lib/bounded_hook_input.py"
TURN_STATE="$ROOT/hooks/lib/pre-reviewer-turn-state.sh"
PRUNER="$ROOT/hooks/lib/prune_pre_reviewer_turn_state.py"
REVIEWER_CALL="$ROOT/hooks/lib/reviewer-call.sh"
PROFILER="$ROOT/hooks/tests/profile_pre_reviewer_ab.py"
WATCHDOG="$ROOT/hooks/tests/process-watchdog.py"
HOOK_CONFIG="$ROOT/hooks.json"

resolve_tool() {
  local tool="$1" resolved
  resolved="$(type -P -- "$tool")" || return 1
  if command -v elan >/dev/null 2>&1; then
    case "$resolved" in
      */.elan/bin/*) resolved="$(elan which "$tool")" || return 1 ;;
    esac
  fi
  resolved="$(readlink -f -- "$resolved")" || return 1
  case "$resolved" in /*) ;; *) return 1 ;; esac
  [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

formal_artifact_identity() {
  local executable="$1" spec="${2:-$SPEC}" proofs="${3:-$PROOFS}"
  local driver="${4:-$DRIVER}" lean="${5:-}" leanc="${6:-}" lean_version
  [ -n "$lean" ] || lean="$(resolve_tool lean)" || return 1
  [ -n "$leanc" ] || leanc="$(resolve_tool leanc)" || return 1
  lean_version="$($lean --version)" || return 1
  printf 'format=pre-reviewer-formal-artifact-v2\n'
  printf 'spec_sha256=%s\n' "$(sha256sum "$spec" | awk '{print $1}')"
  printf 'proofs_sha256=%s\n' "$(sha256sum "$proofs" | awk '{print $1}')"
  printf 'driver_sha256=%s\n' "$(sha256sum "$driver" | awk '{print $1}')"
  printf 'lean_sha256=%s\n' "$(sha256sum "$lean" | awk '{print $1}')"
  printf 'lean_version_sha256=%s\n' \
    "$(printf '%s' "$lean_version" | sha256sum | awk '{print $1}')"
  printf 'leanc_sha256=%s\n' "$(sha256sum "$leanc" | awk '{print $1}')"
  printf 'executable_sha256=%s\n' \
    "$(sha256sum "$executable" | awk '{print $1}')"
}

differential_run_identity() {
  local executable="$1" python bash strace unshare jq findmnt
  local python_version bash_version strace_version findmnt_version worker_sha256
  python="$(resolve_tool python3)" || return 1
  bash="$(resolve_tool bash)" || return 1
  strace="$(resolve_tool strace)" || return 1
  unshare="$(resolve_tool unshare)" || return 1
  jq="$(resolve_tool jq)" || return 1
  findmnt="$(resolve_tool findmnt)" || return 1
  python_version="$($python --version 2>&1)" || return 1
  bash_version="$($bash --version | sed -n '1p')" || return 1
  strace_version="$($strace --version | sed -n '1p')" || return 1
  findmnt_version="$($findmnt --version | sed -n '1p')" || return 1
  printf 'format=pre-reviewer-differential-run-v1\n'
  printf 'controller_sha256=%s\n' "$(sha256sum "$CONTROLLER" | awk '{print $1}')"
  printf 'wrapper_sha256=%s\n' "$(sha256sum "$WRAPPER" | awk '{print $1}')"
  printf 'prompt_hook_sha256=%s\n' "$(sha256sum "$PROMPT_HOOK" | awk '{print $1}')"
  printf 'turn_state_sha256=%s\n' "$(sha256sum "$TURN_STATE" | awk '{print $1}')"
  printf 'lifecycle_sha256=%s\n' "$(sha256sum "$LIFECYCLE" | awk '{print $1}')"
  worker_sha256="$($python - "$LIFECYCLE" <<'PY' | sha256sum | awk '{print $1}'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("lifecycle_identity", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
sys.stdout.write(module._worker_source())
PY
)" || return 1
  printf 'generated_worker_sha256=%s\n' "$worker_sha256"
  printf 'bounded_input_sha256=%s\n' "$(sha256sum "$BOUNDED_INPUT" | awk '{print $1}')"
  printf 'pruner_sha256=%s\n' "$(sha256sum "$PRUNER" | awk '{print $1}')"
  printf 'reviewer_call_sha256=%s\n' "$(sha256sum "$REVIEWER_CALL" | awk '{print $1}')"
  printf 'profiler_sha256=%s\n' "$(sha256sum "$PROFILER" | awk '{print $1}')"
  printf 'hook_config_sha256=%s\n' "$(sha256sum "$HOOK_CONFIG" | awk '{print $1}')"
  printf 'harness_sha256=%s\n' "$(sha256sum "$HARNESS" | awk '{print $1}')"
  printf 'formal_executable_sha256=%s\n' "$(sha256sum "$executable" | awk '{print $1}')"
  printf 'python_sha256=%s\n' "$(sha256sum "$python" | awk '{print $1}')"
  printf 'python_version_sha256=%s\n' "$(printf '%s' "$python_version" | sha256sum | awk '{print $1}')"
  printf 'bash_sha256=%s\n' "$(sha256sum "$bash" | awk '{print $1}')"
  printf 'bash_version_sha256=%s\n' "$(printf '%s' "$bash_version" | sha256sum | awk '{print $1}')"
  printf 'strace_sha256=%s\n' "$(sha256sum "$strace" | awk '{print $1}')"
  printf 'strace_version_sha256=%s\n' "$(printf '%s' "$strace_version" | sha256sum | awk '{print $1}')"
  printf 'unshare_sha256=%s\n' "$(sha256sum "$unshare" | awk '{print $1}')"
  printf 'jq_sha256=%s\n' "$(sha256sum "$jq" | awk '{print $1}')"
  printf 'findmnt_path=%s\n' "$findmnt"
  printf 'findmnt_sha256=%s\n' "$(sha256sum "$findmnt" | awk '{print $1}')"
  printf 'findmnt_version_sha256=%s\n' \
    "$(printf '%s' "$findmnt_version" | sha256sum | awk '{print $1}')"
}

write_stamp() {
  local executable="$1" stamp="$2" temporary
  local spec="${3:-$SPEC}" proofs="${4:-$PROOFS}" driver="${5:-$DRIVER}"
  local lean="${6:-}" leanc="${7:-}"
  [ -x "$executable" ] || return 1
  mkdir -p "$(dirname "$stamp")" || return 1
  temporary="$(mktemp "$(dirname "$stamp")/.pre-reviewer-stamp.XXXXXX")" || return 1
  if ! formal_artifact_identity \
      "$executable" "$spec" "$proofs" "$driver" "$lean" "$leanc" \
      >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$stamp"
}

verify_artifact() {
  local executable="$1" stamp="$2" expected status
  local spec="${3:-$SPEC}" proofs="${4:-$PROOFS}" driver="${5:-$DRIVER}"
  [ -x "$executable" ] && [ -f "$stamp" ] || return 1
  expected="$(mktemp "${TMPDIR:-/tmp}/pre-reviewer-identity.XXXXXX")" || return 1
  if ! formal_artifact_identity \
      "$executable" "$spec" "$proofs" "$driver" >"$expected"; then
    rm -f -- "$expected"
    return 1
  fi
  status=0
  cmp -s -- "$expected" "$stamp" || status=$?
  rm -f -- "$expected"
  return "$status"
}

formal_build_inputs_identity() {
  local spec="$1" proofs="$2" driver="$3" lean="$4" leanc="$5"
  sha256sum "$spec" "$proofs" "$driver" "$lean" "$leanc"
}

check_production_bounds() {
  local executable="$1" publication admission maintenance backend controller hook
  local maintenance_shared_lock state_dir
  publication="$(python3 - "$CONTROLLER" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("controller_bounds", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.OUTPUT_CAP)
PY
)" || return 1
  controller="$(python3 - "$CONTROLLER" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("controller_deadline", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(int(module.CONTROLLER_TIMEOUT_SECONDS))
PY
)" || return 1
  admission="$(python3 - "$BOUNDED_INPUT" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("admission_bounds", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.INPUT_BUDGET)
PY
)" || return 1
  maintenance="$(python3 - "$PRUNER" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("pruner_bounds", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.MAX_VISITED_PER_BATCH)
PY
)" || return 1
  backend="$(env -i PATH=/usr/bin:/bin bash -c \
    '. "$1"; printf "%s\n" "$CODEX_EDIT_PRE_REVIEWER_TIMEOUT"' \
    bash "$REVIEWER_CALL")" || return 1
  hook="$(jq -r \
    '.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.statusMessage == "Checking first tool call") | .timeout' \
    "$HOOK_CONFIG")" || return 1
  [ -n "$hook" ] || return 1
  state_dir="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-lock-check.XXXXXX")" || return 1
  chmod 0700 "$state_dir" || { rm -rf -- "$state_dir"; return 1; }
  maintenance_shared_lock="$(
    python3 - "$PROMPT_HOOK" "$TURN_STATE" <<'PY'
import sys

prompt = open(sys.argv[1], encoding="utf-8").read()
turn_state = open(sys.argv[2], encoding="utf-8").read()
unlock = prompt.find("codex_unlock_pre_reviewer_turn\n        codex_prune_pre_reviewer_turn_state")
guard = '[ -z "${CODEX_TURN_LOCK_FD:-}" ] || return 1'
print("0" if unlock >= 0 and guard in turn_state else "1")
PY
  )" || { rm -rf -- "$state_dir"; return 1; }
  if ! env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" bash -c '
      . "$1"
      codex_lock_pre_reviewer_turn "$2" || exit 1
      if codex_prune_pre_reviewer_turn_state "$2"; then exit 1; fi
      codex_unlock_pre_reviewer_turn
      codex_prune_pre_reviewer_turn_state "$2"' \
      bash "$TURN_STATE" "$state_dir"; then
    maintenance_shared_lock=1
  fi
  rm -rf -- "$state_dir"
  [ "$($executable check-bounds \
    "$publication" "$admission" "$maintenance" "$backend" "$controller" "$hook" \
    "$maintenance_shared_lock")" = \
    bounds-ok ]
}

check_transcript_path_correspondence() {
  local executable="$1" label raw
  local -a components python_outputs lean_outputs raw_paths

  for label in empty valid dot dot-dot nested; do
    case "$label" in
      empty) components=() ;;
      valid) components=(rollout.jsonl) ;;
      dot) components=(. rollout.jsonl) ;;
      dot-dot) components=(.. outside.jsonl) ;;
      nested) components=(2026 07 rollout.jsonl) ;;
    esac
    python_outputs+=("$(python3 - "$BOUNDED_INPUT" "${components[@]}" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bounded_input", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("1" if module.transcript_relative_parts_are_allowed(sys.argv[2:]) else "0")
PY
)") || return 1
    lean_outputs+=("$($executable check-transcript-path "${components[@]}")") || return 1
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ] || return 1

  python_outputs=()
  lean_outputs=()
  raw_paths=(
    /sessions/rollout.jsonl
    /sessions//rollout.jsonl
    /sessions/./rollout.jsonl
    /sessions/rollout.jsonl/.
    /sessions/nested//rollout.jsonl
    sessions/rollout.jsonl
  )
  for raw in "${raw_paths[@]}"; do
    python_outputs+=("$(python3 - "$BOUNDED_INPUT" "$raw" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bounded_raw_path", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("1" if module.transcript_raw_absolute_path_is_allowed(sys.argv[2]) else "0")
PY
)") || return 1
    lean_outputs+=("$($executable check-raw-transcript-path "$raw")") || return 1
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ] || return 1

  python_outputs=()
  lean_outputs=()
  for codepoint in $(seq 0 160); do
    python_outputs+=("$(python3 - "$BOUNDED_INPUT" "$codepoint" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bounded_raw_character", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("1" if module.transcript_raw_character_is_allowed(chr(int(sys.argv[2]))) else "0")
PY
)") || return 1
    lean_outputs+=("$($executable check-transcript-codepoint "$codepoint")") || return 1
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
}

check_generated_hook_supervision_correspondence() {
  local executable="$1" new_group deadline exact_cleanup
  local -a python_outputs lean_outputs

  for new_group in 0 1; do
    for deadline in 0 1; do
      for exact_cleanup in 0 1; do
        python_outputs+=("$(python3 - "$PROFILER" \
            "$new_group" "$deadline" "$exact_cleanup" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("profile_supervision", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
accepted = module.generated_hook_supervision_accepted(
    sys.argv[2] == "1",
    sys.argv[3] == "1",
    sys.argv[4] == "1",
)
print("1" if accepted else "0")
PY
)") || return 1
        lean_outputs+=("$($executable check-generated-hook-supervision \
          "$new_group" "$deadline" "$exact_cleanup")") || return 1
      done
    done
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
}

check_declared_tool_identity_correspondence() {
  local executable="$1" unique_role exact_path exact_bytes
  local -a python_outputs lean_outputs

  for unique_role in 0 1; do
    for exact_path in 0 1; do
      for exact_bytes in 0 1; do
        python_outputs+=("$(python3 - "$PROFILER" \
            "$unique_role" "$exact_path" "$exact_bytes" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("profile_tool_identity", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
accepted = module.declared_tool_identity_accepted(
    sys.argv[2] == "1",
    sys.argv[3] == "1",
    sys.argv[4] == "1",
)
print("1" if accepted else "0")
PY
)") || return 1
        lean_outputs+=("$($executable check-declared-tool-identity \
          "$unique_role" "$exact_path" "$exact_bytes")") || return 1
      done
    done
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
}

check_profile_interruption_correspondence() {
  local executable="$1" traps tracked cleanup preserves signal_number
  local -a python_outputs lean_outputs python_statuses lean_statuses

  for traps in 0 1; do
    for tracked in 0 1; do
      for cleanup in 0 1; do
        for preserves in 0 1; do
          python_outputs+=("$(python3 - "$PROFILER" \
              "$traps" "$tracked" "$cleanup" "$preserves" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("profile_interruption", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
accepted = module.profile_interruption_supervision_accepted(
    sys.argv[2] == "1",
    sys.argv[3] == "1",
    sys.argv[4] == "1",
    sys.argv[5] == "1",
)
print("1" if accepted else "0")
PY
)") || return 1
          lean_outputs+=("$($executable check-profile-interruption \
            "$traps" "$tracked" "$cleanup" "$preserves")") || return 1
        done
      done
    done
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ] || return 1

  for signal_number in 1 2 15; do
    python_statuses+=("$(python3 - "$PROFILER" "$signal_number" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("profile_interrupt_status", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.profile_interrupt_exit_status(int(sys.argv[2])))
PY
)") || return 1
    lean_statuses+=("$($executable profile-interrupt-exit "$signal_number")") || return 1
  done
  [ "${python_statuses[*]}" = "${lean_statuses[*]}" ]
}

check_process_watchdog_drain_correspondence() {
  local executable="$1" exact independent normal interruption unrelated
  local signal_number
  local -a python_outputs lean_outputs python_statuses lean_statuses

  for exact in 0 1; do
    for independent in 0 1; do
      for normal in 0 1; do
        for interruption in 0 1; do
          for unrelated in 0 1; do
            python_outputs+=("$(python3 - "$WATCHDOG" \
                "$exact" "$independent" "$normal" "$interruption" \
                "$unrelated" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("process_watchdog", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
accepted = module.process_watchdog_drain_accepted(
    *(value == "1" for value in sys.argv[2:])
)
print("1" if accepted else "0")
PY
)") || return 1
            lean_outputs+=("$($executable check-process-watchdog-drain \
              "$exact" "$independent" "$normal" "$interruption" \
              "$unrelated")") || return 1
          done
        done
      done
    done
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ] || return 1

  for signal_number in 1 2 15; do
    python_statuses+=("$(python3 - "$WATCHDOG" "$signal_number" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("watchdog_interrupt", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.process_watchdog_interrupt_exit_status(int(sys.argv[2])))
PY
)") || return 1
    lean_statuses+=("$($executable process-watchdog-interrupt-exit \
      "$signal_number")") || return 1
  done
  [ "${python_statuses[*]}" = "${lean_statuses[*]}" ]
}

check_profile_trace_publication_correspondence() {
  local executable="$1" paths aliases atomic report runner preserves
  local -a python_outputs lean_outputs

  for paths in 0 1; do
    for aliases in 0 1; do
      for atomic in 0 1; do
        for report in 0 1; do
          for runner in 0 1; do
            for preserves in 0 1; do
              python_outputs+=("$(python3 - "$PROFILER" \
                  "$paths" "$aliases" "$atomic" "$report" "$runner" \
                  "$preserves" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("profile_trace_binding", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
accepted = module.profile_trace_publication_accepted(
    *(value == "1" for value in sys.argv[2:])
)
print("1" if accepted else "0")
PY
)") || return 1
              lean_outputs+=("$($executable check-profile-trace-publication \
                "$paths" "$aliases" "$atomic" "$report" "$runner" \
                "$preserves")") || return 1
            done
          done
        done
      done
    done
  done
  [ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
}

write_differential_stamp() {
  local executable="$1" stamp="$2" temporary
  temporary="$(mktemp "$(dirname "$stamp")/.pre-reviewer-differential.XXXXXX")" || return 1
  if ! differential_run_identity "$executable" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$stamp"
}

verify_differential_stamp() {
  local executable="$1" stamp="$2" expected status
  expected="$(mktemp "${TMPDIR:-/tmp}/pre-reviewer-differential.XXXXXX")" || return 1
  differential_run_identity "$executable" >"$expected" || {
    rm -f -- "$expected"
    return 1
  }
  status=0
  cmp -s -- "$expected" "$stamp" || status=$?
  rm -f -- "$expected"
  return "$status"
}

prepare_private_executable() {
  local executable="$1" stamp="$2" destination="$3"
  verify_artifact "$executable" "$stamp" || return 1
  rm -f -- "$destination"
  cp --reflink=never -- "$executable" "$destination" || return 1
  chmod 0700 "$destination" || return 1
  verify_artifact "$destination" "$stamp"
}

publish_artifact() {
  local executable="$1" destination_dir="$2" spec="$3" proofs="$4" driver="$5"
  local lean="$6" leanc="$7" name temporary_executable temporary_stamp
  name="preReviewerControllerDiff"
  mkdir -p -- "$destination_dir" || return 1
  temporary_executable="$(mktemp "$destination_dir/.pre-reviewer-executable.XXXXXX")" || return 1
  temporary_stamp="$(mktemp "$destination_dir/.pre-reviewer-stamp.XXXXXX")" || {
    rm -f -- "$temporary_executable"
    return 1
  }
  cp --reflink=never -- "$executable" "$temporary_executable" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  chmod 0700 "$temporary_executable" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  write_stamp "$temporary_executable" "$temporary_stamp" \
    "$spec" "$proofs" "$driver" "$lean" "$leanc" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  mv -f -- "$temporary_executable" "$destination_dir/$name" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  mv -f -- "$temporary_stamp" "$destination_dir/$name.stamp" || {
    rm -f -- "$temporary_stamp"
    return 1
  }
  verify_artifact "$destination_dir/$name" "$destination_dir/$name.stamp"
}

publish_verified_artifact() {
  local executable="$1" stamp="$2" destination_dir="$3"
  local name temporary_executable temporary_stamp
  name="preReviewerControllerDiff"
  verify_artifact "$executable" "$stamp" || return 1
  mkdir -p -- "$destination_dir" || return 1
  temporary_executable="$(mktemp "$destination_dir/.pre-reviewer-executable.XXXXXX")" || return 1
  temporary_stamp="$(mktemp "$destination_dir/.pre-reviewer-stamp.XXXXXX")" || {
    rm -f -- "$temporary_executable"
    return 1
  }
  cp --reflink=never -- "$executable" "$temporary_executable" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  cp --reflink=never -- "$stamp" "$temporary_stamp" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  chmod 0700 "$temporary_executable" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  chmod 0600 "$temporary_stamp" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  verify_artifact "$temporary_executable" "$temporary_stamp" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  mv -f -- "$temporary_executable" "$destination_dir/$name" || {
    rm -f -- "$temporary_executable" "$temporary_stamp"
    return 1
  }
  mv -f -- "$temporary_stamp" "$destination_dir/$name.stamp" || {
    rm -f -- "$temporary_stamp"
    return 1
  }
  verify_artifact "$destination_dir/$name" "$destination_dir/$name.stamp"
}

if [ "${1:-}" = --write-stamp ]; then
  [ "$#" -eq 3 ] || exit 2
  write_stamp "$2" "$3"
  exit
fi
if [ "${1:-}" = --verify-artifact ]; then
  [ "$#" -eq 3 ] || exit 2
  verify_artifact "$2" "$3"
  exit
fi
if [ "${1:-}" = --write-stamp-with-sources ]; then
  [ "$#" -eq 6 ] || exit 2
  write_stamp "$2" "$3" "$4" "$5" "$6"
  exit
fi
if [ "${1:-}" = --verify-artifact-with-sources ]; then
  [ "$#" -eq 6 ] || exit 2
  verify_artifact "$2" "$3" "$4" "$5" "$6"
  exit
fi
if [ "${1:-}" = --write-differential-stamp ]; then
  [ "$#" -eq 3 ] || exit 2
  write_differential_stamp "$2" "$3"
  exit
fi
if [ "${1:-}" = --verify-differential-stamp ]; then
  [ "$#" -eq 3 ] || exit 2
  verify_differential_stamp "$2" "$3"
  exit
fi
if [ "${1:-}" = --prepare-private ]; then
  [ "$#" -eq 4 ] || exit 2
  prepare_private_executable "$2" "$3" "$4"
  exit
fi
if [ "${1:-}" = --check-production-bounds ]; then
  [ "$#" -eq 2 ] || exit 2
  check_production_bounds "$2"
  exit
fi

build_artifact_mode=false
requested_publish_dir=""
if [ "${1:-}" = --build-artifact ]; then
  [ "$#" -eq 2 ] || exit 2
  build_artifact_mode=true
  requested_publish_dir="$2"
  shift 2
fi

build_artifact_stage_failed() {
  local stage="$1"
  if [ "$build_artifact_mode" = true ]; then
    printf 'pre-reviewer build-artifact failed: stage=%s\n' "$stage" >&2
  fi
  return 1
}

build_root=""
cleanup() {
  [ -z "$build_root" ] || rm -rf -- "$build_root"
}
trap cleanup EXIT HUP INT TERM

build_root="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-formal.XXXXXX")" || \
  build_artifact_stage_failed "setup:scratch"
private_executable="$build_root/preReviewerControllerDiff.private"
if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  published_executable="${CODEX_PRE_REVIEWER_FORMAL_EXE:-$ROOT/proofs/.lake/build/bin/preReviewerControllerDiff}"
  published_stamp="${CODEX_PRE_REVIEWER_FORMAL_STAMP:-$published_executable.stamp}"
  if [ "$build_artifact_mode" = true ]; then
    publish_verified_artifact \
      "$published_executable" "$published_stamp" "$requested_publish_dir" || \
      build_artifact_stage_failed "reuse:publication"
    exit 0
  fi
else
  findmnt_path="$(resolve_tool findmnt)" || \
    build_artifact_stage_failed "build:resolve-findmnt"
  [ "$("$findmnt_path" -n -o FSTYPE --target "${TMPDIR:-/tmp}")" = tmpfs ] || {
    if [ "$build_artifact_mode" != true ]; then
      printf '%s\n' 'pre-reviewer formal build requires tmpfs TMPDIR' >&2
    fi
    build_artifact_stage_failed "build:tmpfs"
  }
  lean="$(resolve_tool lean)" || build_artifact_stage_failed "build:resolve-lean"
  leanc="$(resolve_tool leanc)" || build_artifact_stage_failed "build:resolve-leanc"
  toolchain_root="$(cd "$(dirname "$lean")/.." && pwd)" || \
    build_artifact_stage_failed "build:toolchain-root"
  project="$build_root/project"
  mkdir -p "$project/Spec" "$project/Proofs" "$project/DiffTest" \
    "$build_root/home" "$build_root/tmp" || \
    build_artifact_stage_failed "build:project-directories"
  cp "$SPEC" "$project/Spec/PreReviewerController.lean" || \
    build_artifact_stage_failed "build:copy-spec"
  cp "$PROOFS" "$project/Proofs/PreReviewerController.lean" || \
    build_artifact_stage_failed "build:copy-proofs"
  cp "$DRIVER" "$project/DiffTest/PreReviewerControllerMain.lean" || \
    build_artifact_stage_failed "build:copy-driver"
  private_inputs_before="$(formal_build_inputs_identity \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc")" || \
    build_artifact_stage_failed "build:input-identity-before"
  if [ -n "${CODEX_PRE_REVIEWER_BUILD_AUDIT:-}" ]; then
    if ! python3 - "$CODEX_PRE_REVIEWER_BUILD_AUDIT" \
      "${CODEX_PRE_REVIEWER_BUILD_AUDIT_ROOT:-}" <<'PY'
import os
from pathlib import Path
import stat
import sys

audit = Path(sys.argv[1])
root = Path(sys.argv[2])
metadata = root.lstat()
if (
    not audit.is_absolute()
    or not root.is_absolute()
    or not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.getuid()
    or stat.S_IMODE(metadata.st_mode) != 0o700
    or audit.is_symlink()
    or not audit.parent.resolve().is_relative_to(root.resolve())
):
    raise SystemExit("invalid generated controller-build audit path")
audit.parent.mkdir(parents=True, exist_ok=True)
flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(audit, flags, 0o600)
try:
    os.write(descriptor, b"controller-build\n")
finally:
    os.close(descriptor)
PY
    then
      build_artifact_stage_failed "build:audit"
    fi
  fi
  for module in Spec/PreReviewerController Proofs/PreReviewerController \
      DiffTest/PreReviewerControllerMain; do
    (cd "$project" && \
      env -i PATH=/usr/bin:/bin HOME="$build_root/home" TMPDIR="$build_root/tmp" \
        LEAN_PATH="$project:$toolchain_root/lib/lean" \
        "$lean" -o "$module.olean" -i "$module.ilean" \
        -c "$module.c" "$module.lean") || \
      build_artifact_stage_failed "build:compile:$module"
  done
  lean_executable="$build_root/preReviewerControllerDiff"
  env -i PATH="$(dirname "$leanc"):/usr/bin:/bin" HOME="$build_root/home" \
    TMPDIR="$build_root/tmp" "$leanc" -O2 -o "$lean_executable" \
    "$project/Spec/PreReviewerController.c" \
    "$project/Proofs/PreReviewerController.c" \
    "$project/DiffTest/PreReviewerControllerMain.c" || \
    build_artifact_stage_failed "build:link"
  private_inputs_after="$(formal_build_inputs_identity \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc")" || \
    build_artifact_stage_failed "build:input-identity-after"
  [ "$private_inputs_after" = "$private_inputs_before" ] || \
    build_artifact_stage_failed "build:input-mutation"
  cmp -s "$SPEC" "$project/Spec/PreReviewerController.lean" || \
    build_artifact_stage_failed "build:spec-correspondence"
  cmp -s "$PROOFS" "$project/Proofs/PreReviewerController.lean" || \
    build_artifact_stage_failed "build:proofs-correspondence"
  cmp -s "$DRIVER" "$project/DiffTest/PreReviewerControllerMain.lean" || \
    build_artifact_stage_failed "build:driver-correspondence"
  publish_dir="${requested_publish_dir:-${CODEX_PRE_REVIEWER_FORMAL_PUBLISH_DIR:-$ROOT/proofs/.lake/build/bin}}"
  publish_artifact "$lean_executable" "$publish_dir" \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc" || \
    build_artifact_stage_failed "build:publication"
  published_executable="$publish_dir/preReviewerControllerDiff"
  published_stamp="$published_executable.stamp"
  if [ "$build_artifact_mode" = true ]; then
    exit 0
  fi
fi

prepare_private_executable "$published_executable" "$published_stamp" "$private_executable"
differential_stamp="$build_root/differential-run.stamp"
write_differential_stamp "$private_executable" "$differential_stamp"
check_production_bounds "$private_executable"
check_transcript_path_correspondence "$private_executable"
check_generated_hook_supervision_correspondence "$private_executable"
check_declared_tool_identity_correspondence "$private_executable"
check_profile_interruption_correspondence "$private_executable"
check_process_watchdog_drain_correspondence "$private_executable"
check_profile_trace_publication_correspondence "$private_executable"

python3 "$ROOT/hooks/tests/pre_reviewer_lifecycle.py" \
  --root "$ROOT" --lean "$private_executable" "$@"
verify_differential_stamp "$private_executable" "$differential_stamp"
