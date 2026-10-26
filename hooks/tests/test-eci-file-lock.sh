#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-file-lock.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

source "$ROOT/hooks/lib/codex-file-lock.sh"
source "$ROOT/hooks/lib/codex-proof-state.sh"

BASE_PATH="$PATH"
CALL_LOG="$TMP_ROOT/lock-calls.log"
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"

write_platform_stub() {
  local platform="$1"
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$platform" >"$FAKE_BIN/uname"
  chmod +x "$FAKE_BIN/uname"
}

write_lock_stub() {
  local command_name="$1"
  cat >"$FAKE_BIN/$command_name" <<'SH'
#!/bin/sh
printf '%s' "$0" >>"$CODEX_FILE_LOCK_TEST_LOG"
for argument in "$@"; do
  printf ' <%s>' "$argument" >>"$CODEX_FILE_LOCK_TEST_LOG"
done
printf '\n' >>"$CODEX_FILE_LOCK_TEST_LOG"
SH
  chmod +x "$FAKE_BIN/$command_name"
}

write_lock_stub lockf
write_lock_stub flock
: >"$CALL_LOG"

# Standard descriptors are outside this API; rejection must preserve streams.
for descriptor in 0 1 2; do
  (
    status=0
    codex_file_lock_acquire_fd "$descriptor" blocking 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
    status=0
    codex_file_lock_release_fd "$descriptor" 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
    eval "true >&$descriptor"
  )
done

exec {darwin_fd}>>"$TMP_ROOT/darwin.lock"
write_platform_stub Darwin
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_acquire_fd "$darwin_fd" blocking
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_acquire_fd "$darwin_fd" nonblocking
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_release_fd "$darwin_fd"
grep -Eq '/lockf <-s> <[0-9]+>$' "$CALL_LOG"
grep -Eq '/lockf <-s> <-t> <0> <[0-9]+>$' "$CALL_LOG"
grep -Eq '/lockf <-s> <-t> <0> </dev/fd/[0-9]+> </usr/bin/true>$' "$CALL_LOG"

: >"$CALL_LOG"
exec {linux_fd}>>"$TMP_ROOT/linux.lock"
write_platform_stub Linux
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_acquire_fd "$linux_fd" blocking
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_acquire_fd "$linux_fd" nonblocking
PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
  codex_file_lock_release_fd "$linux_fd"
grep -Eq '/flock <-x> <[0-9]+>$' "$CALL_LOG"
grep -Eq '/flock <-n> <-x> <[0-9]+>$' "$CALL_LOG"
grep -Eq '/flock <-u> <[0-9]+>$' "$CALL_LOG"

write_platform_stub Plan9
if PATH="$FAKE_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_LOG="$CALL_LOG" \
    codex_file_lock_acquire_fd 9 blocking 2>/dev/null; then
  printf '%s\n' 'unsupported platform unexpectedly acquired a lock' >&2
  exit 1
fi

# Release still closes the descriptor when platform discovery or unlocking fails,
# and reports the original utility status.
assert_release_failure_closes_fd() {
  local expected="$1" descriptor status=0
  exec {descriptor}>>"$TMP_ROOT/failed-release.lock"
  PATH="$FAKE_BIN:$BASE_PATH" codex_file_lock_release_fd "$descriptor" || status=$?
  [ "$status" -eq "$expected" ]
  if (eval "true >&$descriptor") 2>/dev/null; then
    printf '%s\n' 'failed release retained its descriptor' >&2
    exit 1
  fi
}
printf '#!/bin/sh\nexit 38\n' >"$FAKE_BIN/uname"
assert_release_failure_closes_fd 38
(
  eval() { return 39; }
  status=0
  PATH="$FAKE_BIN:$BASE_PATH" codex_file_lock_release_fd 9 || status=$?
  [ "$status" -eq 38 ]
)
write_platform_stub Linux
printf '#!/bin/sh\nexit 37\n' >"$FAKE_BIN/flock"
assert_release_failure_closes_fd 37

# The native platform path must hold the actual OS lock until release.
NATIVE_PLATFORM="$(command uname -s)"
native_lock_available() {
  case "$NATIVE_PLATFORM" in
    Darwin) /usr/bin/lockf -k -s -t 0 "$1" /usr/bin/true ;;
    Linux) command flock -n "$1" /bin/true ;;
    *) return 2 ;;
  esac
}
exec {native_fd}>>"$TMP_ROOT/native.lock"
native_inode="$(ls -i "$TMP_ROOT/native.lock" | awk '{print $1}')"
PATH="$BASE_PATH" codex_file_lock_acquire_fd "$native_fd" nonblocking
exec {contended_fd}>>"$TMP_ROOT/native.lock"
if codex_file_lock_acquire_fd "$contended_fd" nonblocking; then
  printf '%s\n' 'contended helper acquisition unexpectedly succeeded' >&2
  exit 1
fi
codex_file_lock_release_fd "$contended_fd" 2>/dev/null || true
if native_lock_available "$TMP_ROOT/native.lock" 2>/dev/null; then
  printf '%s\n' 'failed acquisition cleanup released another owner lock' >&2
  exit 1
fi
case "$NATIVE_PLATFORM" in
  Darwin)
    if /usr/bin/lockf -k -s -t 0 "$TMP_ROOT/native.lock" /usr/bin/true 2>/dev/null; then
      printf '%s\n' 'lockf did not observe the held descriptor lock' >&2
      exit 1
    fi
    ;;
  Linux)
    if command flock -n "$TMP_ROOT/native.lock" /bin/true 2>/dev/null; then
      printf '%s\n' 'flock did not observe the held descriptor lock' >&2
      exit 1
    fi
    ;;
  *)
    printf 'no native lock assertion for %s\n' "$NATIVE_PLATFORM" >&2
    exit 1
    ;;
esac
# A duplicate must not keep the released lock alive.
exec {duplicate_fd}>&"$native_fd"
codex_file_lock_release_fd "$native_fd"
case "$NATIVE_PLATFORM" in
  Darwin) /usr/bin/lockf -k -s -t 0 "$TMP_ROOT/native.lock" /usr/bin/true ;;
  Linux) command flock -n "$TMP_ROOT/native.lock" /bin/true ;;
esac
eval "exec ${duplicate_fd}>&-"
[ "$native_inode" = "$(ls -i "$TMP_ROOT/native.lock" | awk '{print $1}')" ]

# A process that exits without an explicit release must not leave a stale lock.
bash -c 'source "$1"; exec 9>>"$2"; codex_file_lock_acquire_fd 9 blocking' \
  bash "$ROOT/hooks/lib/codex-file-lock.sh" "$TMP_ROOT/exited.lock"
native_lock_available "$TMP_ROOT/exited.lock"

# The proof-state consumer must fail closed while another descriptor owns its
# lock, then consume its private fixture after that descriptor is released.
PROOF_RECORD="$TMP_ROOT/proof-state-record"
PROOF_LOCK="$TMP_ROOT/proof-state.lock"
codex_eci_accidental_override_record_path() { printf '%s\n' "$PROOF_RECORD"; }
codex_eci_lock_path() { printf '%s\n' "$PROOF_LOCK"; }
codex_eci_accidental_override_record_is_valid() { return 0; }
printf '%s\n' 'fixture record' >"$PROOF_RECORD"
exec {proof_lock_fd}>>"$PROOF_LOCK"
codex_file_lock_acquire_fd "$proof_lock_fd" nonblocking
if codex_eci_accidental_override_consume session validate-bash lock-test-session "$ROOT" payload; then
  printf '%s\n' 'proof-state consumed while its common lock was busy' >&2
  exit 1
fi
[ -f "$PROOF_RECORD" ] && [ ! -e "$PROOF_RECORD.claim" ]
codex_file_lock_release_fd "$proof_lock_fd"
codex_eci_accidental_override_consume session validate-bash lock-test-session "$ROOT" payload
[ ! -e "$PROOF_RECORD" ] && [ ! -e "$PROOF_RECORD.claim" ]

# A source-only Git-tool module must compile once under concurrent cold starts.
RUNTIME_ROOT="$TMP_ROOT/runtime/.codex"
BUILD_BIN="$TMP_ROOT/build-bin"
BUILD_LOG="$TMP_ROOT/build-calls.log"
mkdir -p "$RUNTIME_ROOT/bin" "$RUNTIME_ROOT/hooks/lib" "$BUILD_BIN"
cp "$ROOT/hooks/lib/eci-runtime-sync.sh" \
  "$ROOT/hooks/lib/eci-native-binary.sh" \
  "$ROOT/hooks/lib/codex-file-lock.sh" \
  "$RUNTIME_ROOT/hooks/lib/"
mkdir -p "$RUNTIME_ROOT/hooks/lib/eci-worker-git-go"
printf '%s\n' 'module fixture.invalid/eci-worker-git' 'go 1.23' \
  >"$RUNTIME_ROOT/hooks/lib/eci-worker-git-go/go.mod"
cat >"$BUILD_BIN/go" <<'SH'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
printf 'build\n' >>"$CODEX_FILE_LOCK_TEST_BUILD_LOG"
sleep 0.2
printf '#!/bin/sh\nexit 0\n' >"$output"
SH
chmod +x "$BUILD_BIN/go"
: >"$BUILD_LOG"
PATH="$BUILD_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_BUILD_LOG="$BUILD_LOG" \
  bash -c 'source "$1"; eci_runtime_build_missing "$2" eci-worker-git' \
  bash "$RUNTIME_ROOT/hooks/lib/eci-runtime-sync.sh" "$RUNTIME_ROOT" &
first_build=$!
PATH="$BUILD_BIN:$BASE_PATH" CODEX_FILE_LOCK_TEST_BUILD_LOG="$BUILD_LOG" \
  bash -c 'source "$1"; eci_runtime_build_missing "$2" eci-worker-git' \
  bash "$RUNTIME_ROOT/hooks/lib/eci-runtime-sync.sh" "$RUNTIME_ROOT" &
second_build=$!
wait "$first_build"
wait "$second_build"
[ "$(grep -c '^build$' "$BUILD_LOG")" -eq 1 ]
[ -x "$RUNTIME_ROOT/bin/eci-worker-git" ]

printf '%s\n' 'portable file lock and proof-state tests: PASS'
