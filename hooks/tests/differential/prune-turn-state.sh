#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${CODEX_TEST_PRUNE_HELPER:-$ROOT/hooks/lib/prune_pre_reviewer_turn_state.py}"
SPEC="$ROOT/proofs/Spec/PruneTurnState.lean"
PROOFS="$ROOT/proofs/Proofs/PruneTurnState.lean"
DRIVER="$ROOT/proofs/DiffTest/PruneMain.lean"

resolve_tool() {
  local tool="$1" resolved
  resolved="$(type -P -- "$tool")" || return 1
  if command -v elan >/dev/null 2>&1; then
    case "$resolved" in
      */.elan/bin/*) resolved="$(elan which "$tool")" || return 1 ;;
    esac
  fi
  resolved="$(readlink -f -- "$resolved")" || return 1
  [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

prune_artifact_identity() {
  local executable="$1" lean leanc lean_version
  lean="$(resolve_tool lean)" || return 1
  leanc="$(resolve_tool leanc)" || return 1
  lean_version="$($lean --version)" || return 1
  printf 'format=prune-formal-artifact-v1\n'
  printf 'spec_sha256=%s\n' "$(sha256sum "$SPEC" | awk '{print $1}')"
  printf 'proofs_sha256=%s\n' "$(sha256sum "$PROOFS" | awk '{print $1}')"
  printf 'driver_sha256=%s\n' "$(sha256sum "$DRIVER" | awk '{print $1}')"
  printf 'lean_sha256=%s\n' "$(sha256sum "$lean" | awk '{print $1}')"
  printf 'lean_version_sha256=%s\n' \
    "$(printf '%s' "$lean_version" | sha256sum | awk '{print $1}')"
  printf 'leanc_sha256=%s\n' "$(sha256sum "$leanc" | awk '{print $1}')"
  printf 'executable_sha256=%s\n' \
    "$(sha256sum "$executable" | awk '{print $1}')"
}

write_prune_stamp() {
  local executable="$1" stamp="$2" temporary
  [ -x "$executable" ] || return 1
  temporary="$(mktemp "$(dirname "$stamp")/.prune-stamp.XXXXXX")" || return 1
  if ! prune_artifact_identity "$executable" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$stamp"
}

verify_prune_artifact() {
  local executable="$1" stamp="$2" expected status
  [ -x "$executable" ] && [ -f "$stamp" ] || return 1
  expected="$(mktemp "${TMPDIR:-/tmp}/prune-identity.XXXXXX")" || return 1
  prune_artifact_identity "$executable" >"$expected" || {
    rm -f -- "$expected"
    return 1
  }
  status=0
  cmp -s -- "$expected" "$stamp" || status=$?
  rm -f -- "$expected"
  return "$status"
}

publish_prune_artifact() {
  local executable="$1" destination_dir="$2" temporary_executable temporary_stamp status
  mkdir -p -- "$destination_dir" || return 1
  temporary_executable="$(mktemp "$destination_dir/.prune-executable.XXXXXX")" || return 1
  temporary_stamp="$(mktemp "$destination_dir/.prune-stamp.XXXXXX")" || {
    rm -f -- "$temporary_executable"
    return 1
  }
  status=0
  cp --reflink=never -- "$executable" "$temporary_executable" || status=$?
  if [ "$status" -eq 0 ]; then chmod 0700 "$temporary_executable" || status=$?; fi
  if [ "$status" -eq 0 ]; then
    write_prune_stamp "$temporary_executable" "$temporary_stamp" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$temporary_executable" "$destination_dir/pruneTurnStateDiff" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$temporary_stamp" "$destination_dir/pruneTurnStateDiff.stamp" || status=$?
  fi
  rm -f -- "$temporary_executable" "$temporary_stamp"
  [ "$status" -eq 0 ] || return "$status"
  verify_prune_artifact \
    "$destination_dir/pruneTurnStateDiff" \
    "$destination_dir/pruneTurnStateDiff.stamp"
}

build_prune_artifact() {
  local destination_dir="$1" findmnt_path lean leanc toolchain_root build_root project
  local module executable inputs_before inputs_after
  findmnt_path="$(resolve_tool findmnt)" || return 1
  [ "$($findmnt_path -n -o FSTYPE --target "${TMPDIR:-/tmp}")" = tmpfs ] || return 1
  lean="$(resolve_tool lean)" || return 1
  leanc="$(resolve_tool leanc)" || return 1
  toolchain_root="$(cd "$(dirname "$lean")/.." && pwd)"
  inputs_before="$(sha256sum "$SPEC" "$PROOFS" "$DRIVER" "$lean" "$leanc")" || return 1
  build_root="$(mktemp -d "${TMPDIR:-/tmp}/prune-formal.XXXXXX")" || return 1
  trap 'rm -rf -- "$build_root"' RETURN
  project="$build_root/project"
  mkdir -p "$project/Spec" "$project/Proofs" "$project/DiffTest" \
    "$build_root/home" "$build_root/tmp"
  cp "$SPEC" "$project/Spec/PruneTurnState.lean"
  cp "$PROOFS" "$project/Proofs/PruneTurnState.lean"
  cp "$DRIVER" "$project/DiffTest/PruneMain.lean"
  for module in Spec/PruneTurnState Proofs/PruneTurnState DiffTest/PruneMain; do
    (cd "$project" && \
      env -i PATH=/usr/bin:/bin HOME="$build_root/home" TMPDIR="$build_root/tmp" \
        LEAN_PATH="$project:$toolchain_root/lib/lean" \
        "$lean" -o "$module.olean" -i "$module.ilean" \
        -c "$module.c" "$module.lean")
  done
  executable="$build_root/pruneTurnStateDiff"
  env -i PATH="$(dirname "$leanc"):/usr/bin:/bin" HOME="$build_root/home" \
    TMPDIR="$build_root/tmp" "$leanc" -O2 -o "$executable" \
    "$project/Spec/PruneTurnState.c" \
    "$project/Proofs/PruneTurnState.c" \
    "$project/DiffTest/PruneMain.c"
  inputs_after="$(sha256sum "$SPEC" "$PROOFS" "$DRIVER" "$lean" "$leanc")" || return 1
  [ "$inputs_after" = "$inputs_before" ] || return 1
  cmp -s "$SPEC" "$project/Spec/PruneTurnState.lean" || return 1
  cmp -s "$PROOFS" "$project/Proofs/PruneTurnState.lean" || return 1
  cmp -s "$DRIVER" "$project/DiffTest/PruneMain.lean" || return 1
  publish_prune_artifact "$executable" "$destination_dir"
  rm -rf -- "$build_root"
  trap - RETURN
}

case "${1:-}" in
  --build-artifact)
    [ "$#" -eq 2 ] || exit 2
    build_prune_artifact "$2"
    exit
    ;;
  --verify-artifact)
    [ "$#" -eq 3 ] || exit 2
    verify_prune_artifact "$2" "$3"
    exit
    ;;
esac

names=(
  capture-turn-key.json claim-turn-key
  .capture-turn-key.redacted.A0 .capture-turn-key.capped.A0
  .capture-turn-key.json.A0 .capture-turn-key.validated.A0
  .capture-turn-key.consumed.A0 .capture-turn-key.prompt.A0
  capture-turn-.json capture-turn-key.json.extra capture-turn-key!.json
  claim-turn- claim-turn-key.json .capture-turn-key.unknown.A0
  .capture-turn-key.capped. .capture-turn-key.capped.A-0
  .capture-turn-key.capped.A0.extra unrelated
)

if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  formal_executable="${CODEX_PRUNE_FORMAL_EXE:-$ROOT/proofs/.lake/build/bin/pruneTurnStateDiff}"
  formal_stamp="${CODEX_PRUNE_FORMAL_STAMP:-$formal_executable.stamp}"
  verify_prune_artifact "$formal_executable" "$formal_stamp"
else
  build_log="$(mktemp "${TMPDIR:-/tmp}/prune-lean-build.XXXXXX")"
  trap 'rm -f "$build_log"' EXIT HUP INT TERM
  python3 "$ROOT/hooks/tests/process-watchdog.py" --timeout 300 --log "$build_log" \
    --cwd "$ROOT/proofs" -- lake build pruneTurnStateDiff || { cat "$build_log" >&2; exit 1; }
  formal_executable="$ROOT/proofs/.lake/build/bin/pruneTurnStateDiff"
fi
mapfile -t lean_outputs < <("$formal_executable" "${names[@]}")
mapfile -t python_outputs < <(
  python3 - "$HELPER" "${names[@]}" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pruner", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
for name in sys.argv[2:]:
    print("1" if module.is_prunable_name(name) else "0")
PY
)

[ "${#lean_outputs[@]}" -eq "${#names[@]}" ]
[ "${python_outputs[*]}" = "${lean_outputs[*]}" ]
revalidation_cases=(
  'revalidate|0|0|0' 'revalidate|0|0|1'
  'revalidate|0|1|0' 'revalidate|0|1|1'
  'revalidate|1|0|0' 'revalidate|1|0|1'
  'revalidate|1|1|0' 'revalidate|1|1|1'
)
mapfile -t lean_revalidation_outputs < <(
  "$formal_executable" "${revalidation_cases[@]}"
)
mapfile -t python_revalidation_outputs < <(
  python3 - "$HELPER" "${revalidation_cases[@]}" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pruner", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
for case in sys.argv[2:]:
    marker, lock, observed, current = case.split("|")
    if marker != "revalidate":
        raise SystemExit(1)
    selected = module._delete_after_revalidation(
        lock == "1",
        observed == "1",
        current == "1",
    )
    print("1" if selected else "0")
PY
)
[ "${#lean_revalidation_outputs[@]}" -eq "${#revalidation_cases[@]}" ]
[ "${python_revalidation_outputs[*]}" = "${lean_revalidation_outputs[*]}" ]
printf 'prune namespace differential cases: %s\n' "${#names[@]}"
printf 'prune revalidation differential cases: %s\n' "${#revalidation_cases[@]}"
