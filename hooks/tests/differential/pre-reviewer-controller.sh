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
BOUNDED_INPUT="$ROOT/hooks/lib/bounded_hook_input.py"
PRUNER="$ROOT/hooks/lib/prune_pre_reviewer_turn_state.py"
REVIEWER_CALL="$ROOT/hooks/lib/reviewer-call.sh"
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
  local executable="$1" python bash strace unshare jq
  local python_version bash_version strace_version worker_sha256
  python="$(resolve_tool python3)" || return 1
  bash="$(resolve_tool bash)" || return 1
  strace="$(resolve_tool strace)" || return 1
  unshare="$(resolve_tool unshare)" || return 1
  jq="$(resolve_tool jq)" || return 1
  python_version="$($python --version 2>&1)" || return 1
  bash_version="$($bash --version | sed -n '1p')" || return 1
  strace_version="$($strace --version | sed -n '1p')" || return 1
  printf 'format=pre-reviewer-differential-run-v1\n'
  printf 'controller_sha256=%s\n' "$(sha256sum "$CONTROLLER" | awk '{print $1}')"
  printf 'wrapper_sha256=%s\n' "$(sha256sum "$WRAPPER" | awk '{print $1}')"
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
  [ "$($executable check-bounds \
    "$publication" "$admission" "$maintenance" "$backend" "$controller" "$hook")" = \
    bounds-ok ]
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

build_root=""
cleanup() {
  [ -z "$build_root" ] || rm -rf -- "$build_root"
}
trap cleanup EXIT HUP INT TERM

build_root="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-formal.XXXXXX")"
private_executable="$build_root/preReviewerControllerDiff.private"
if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  published_executable="${CODEX_PRE_REVIEWER_FORMAL_EXE:-$ROOT/proofs/.lake/build/bin/preReviewerControllerDiff}"
  published_stamp="${CODEX_PRE_REVIEWER_FORMAL_STAMP:-$published_executable.stamp}"
else
  [ "$(findmnt -n -o FSTYPE --target "${TMPDIR:-/tmp}")" = tmpfs ] || {
    printf '%s\n' 'pre-reviewer formal build requires tmpfs TMPDIR' >&2
    exit 1
  }
  lean="$(resolve_tool lean)" || exit 1
  leanc="$(resolve_tool leanc)" || exit 1
  toolchain_root="$(cd "$(dirname "$lean")/.." && pwd)"
  project="$build_root/project"
  mkdir -p "$project/Spec" "$project/Proofs" "$project/DiffTest" \
    "$build_root/home" "$build_root/tmp"
  cp "$SPEC" "$project/Spec/PreReviewerController.lean"
  cp "$PROOFS" "$project/Proofs/PreReviewerController.lean"
  cp "$DRIVER" "$project/DiffTest/PreReviewerControllerMain.lean"
  private_inputs_before="$(formal_build_inputs_identity \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc")" || exit 1
  for module in Spec/PreReviewerController Proofs/PreReviewerController \
      DiffTest/PreReviewerControllerMain; do
    (cd "$project" && \
      env -i PATH=/usr/bin:/bin HOME="$build_root/home" TMPDIR="$build_root/tmp" \
        LEAN_PATH="$project:$toolchain_root/lib/lean" \
        "$lean" -o "$module.olean" -i "$module.ilean" \
        -c "$module.c" "$module.lean")
  done
  lean_executable="$build_root/preReviewerControllerDiff"
  env -i PATH="$(dirname "$leanc"):/usr/bin:/bin" HOME="$build_root/home" \
    TMPDIR="$build_root/tmp" "$leanc" -O2 -o "$lean_executable" \
    "$project/Spec/PreReviewerController.c" \
    "$project/Proofs/PreReviewerController.c" \
    "$project/DiffTest/PreReviewerControllerMain.c"
  private_inputs_after="$(formal_build_inputs_identity \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc")" || exit 1
  [ "$private_inputs_after" = "$private_inputs_before" ] || exit 1
  cmp -s "$SPEC" "$project/Spec/PreReviewerController.lean" || exit 1
  cmp -s "$PROOFS" "$project/Proofs/PreReviewerController.lean" || exit 1
  cmp -s "$DRIVER" "$project/DiffTest/PreReviewerControllerMain.lean" || exit 1
  publish_dir="${CODEX_PRE_REVIEWER_FORMAL_PUBLISH_DIR:-$ROOT/proofs/.lake/build/bin}"
  publish_artifact "$lean_executable" "$publish_dir" \
    "$project/Spec/PreReviewerController.lean" \
    "$project/Proofs/PreReviewerController.lean" \
    "$project/DiffTest/PreReviewerControllerMain.lean" "$lean" "$leanc"
  published_executable="$publish_dir/preReviewerControllerDiff"
  published_stamp="$published_executable.stamp"
fi

prepare_private_executable "$published_executable" "$published_stamp" "$private_executable"
differential_stamp="$build_root/differential-run.stamp"
write_differential_stamp "$private_executable" "$differential_stamp"
check_production_bounds "$private_executable"

python3 "$ROOT/hooks/tests/pre_reviewer_lifecycle.py" \
  --root "$ROOT" --lean "$private_executable" "$@"
verify_differential_stamp "$private_executable" "$differential_stamp"
