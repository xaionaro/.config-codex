#!/usr/bin/env bash
# Stop hook: require a checklist pass before ending.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
codex_init_tmp || true
codex_install_fail_open_trap stop-gate

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
transcript_path=$(printf '%s' "$input" | jq -r 'if (.transcript_path? | type) == "string" then .transcript_path else "" end' 2>/dev/null || true)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"
root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
proof_root_canonical="$(realpath -m -- "$root" 2>/dev/null || true)"
proof_root_dev=""
proof_root_ino=""
proof_root_parent_canonical=""
proof_root_parent_dev=""
proof_root_parent_ino=""
if [ -d "$proof_root_canonical" ] && [ ! -L "$proof_root_canonical" ]; then
  proof_root_identity="$(stat -Lc '%d:%i' -- "$proof_root_canonical" 2>/dev/null || true)"
  if [[ "$proof_root_identity" == *:* ]]; then
    proof_root_dev="${proof_root_identity%%:*}"
    proof_root_ino="${proof_root_identity#*:}"
  fi
fi
proof_root_parent_canonical="$(realpath -m -- "$(dirname -- "$root")" 2>/dev/null || true)"
if [ -d "$proof_root_parent_canonical" ] && [ ! -L "$proof_root_parent_canonical" ]; then
  proof_root_parent_identity="$(stat -Lc '%d:%i' -- "$proof_root_parent_canonical" 2>/dev/null || true)"
  if [[ "$proof_root_parent_identity" == *:* ]]; then
    proof_root_parent_dev="${proof_root_parent_identity%%:*}"
    proof_root_parent_ino="${proof_root_parent_identity#*:}"
  fi
fi
if [ -n "$proof_root_canonical" ]; then
  proof_dir="$proof_root_canonical/$session_id"
else
  proof_dir="$root/$session_id"
fi

proof_root_is_stable() {
  local current_identity current_path current_parent_identity current_parent_path

  [ -n "$proof_root_dev" ] && [ -n "$proof_root_ino" ] || return 1
  [ -n "$proof_root_parent_dev" ] && [ -n "$proof_root_parent_ino" ] || return 1
  [ -d "$proof_root_canonical" ] && [ ! -L "$proof_root_canonical" ] || return 1
  current_identity="$(stat -Lc '%d:%i' -- "$proof_root_canonical" 2>/dev/null || true)"
  [ "$current_identity" = "$proof_root_dev:$proof_root_ino" ] || return 1
  [ -d "$proof_root_parent_canonical" ] && [ ! -L "$proof_root_parent_canonical" ] || return 1
  current_parent_identity="$(stat -Lc '%d:%i' -- "$proof_root_parent_canonical" 2>/dev/null || true)"
  [ "$current_parent_identity" = "$proof_root_parent_dev:$proof_root_parent_ino" ] || return 1
  current_path="$(realpath -m -- "$root" 2>/dev/null || true)"
  [ "$current_path" = "$proof_root_canonical" ] || return 1
  current_parent_path="$(realpath -m -- "$(dirname -- "$root")" 2>/dev/null || true)"
  [ "$current_parent_path" = "$proof_root_parent_canonical" ]
}

proof_session_dev=""
proof_session_ino=""

ensure_proof_session_dir() {
  local identity

  proof_root_is_stable || return 1
  identity="$(python3 - "$root" "$proof_root_canonical" "$session_id" \
    "$proof_root_dev" "$proof_root_ino" "$proof_root_parent_canonical" \
    "$proof_root_parent_dev" "$proof_root_parent_ino" <<'PY'
import os
import stat
import sys

configured_root, canonical_root, session_name, expected_root_dev, expected_root_ino, \
    expected_parent, expected_parent_dev, expected_parent_ino = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(1)
parent_info = os.stat(expected_parent, follow_symlinks=False)
if (not stat.S_ISDIR(parent_info.st_mode) or
        (str(parent_info.st_dev), str(parent_info.st_ino)) != (expected_parent_dev, expected_parent_ino)):
    raise SystemExit(1)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (not stat.S_ISDIR(root_info.st_mode) or
            (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino)):
        raise SystemExit(1)
    try:
        session_fd = os.open(session_name, flags, dir_fd=root_fd)
    except FileNotFoundError:
        os.mkdir(session_name, mode=0o700, dir_fd=root_fd)
        session_fd = os.open(session_name, flags, dir_fd=root_fd)
    try:
        session_info = os.fstat(session_fd)
        if not stat.S_ISDIR(session_info.st_mode):
            raise SystemExit(1)
        print(f"{session_info.st_dev}:{session_info.st_ino}")
    finally:
        os.close(session_fd)
    os.fsync(root_fd)
finally:
    os.close(root_fd)
PY
  )" || return 1
  [[ "$identity" == *:* ]] || return 1
  proof_session_dev="${identity%%:*}"
  proof_session_ino="${identity#*:}"
  [[ "$proof_session_dev" =~ ^[0-9]+$ ]] && [[ "$proof_session_ino" =~ ^[0-9]+$ ]]
}

proof_session_is_stable() {
  [ -n "$proof_session_dev" ] && [ -n "$proof_session_ino" ] || return 1
  proof_root_is_stable || return 1
  python3 - "$root" "$proof_root_canonical" "$session_id" \
    "$proof_root_dev" "$proof_root_ino" "$proof_session_dev" "$proof_session_ino" <<'PY'
import os
import stat
import sys

configured_root, canonical_root, session_name, expected_root_dev, expected_root_ino, \
    expected_session_dev, expected_session_ino = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(1)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino):
        raise SystemExit(1)
    session_fd = os.open(session_name, flags, dir_fd=root_fd)
    try:
        session_info = os.fstat(session_fd)
        if (not stat.S_ISDIR(session_info.st_mode) or
                (str(session_info.st_dev), str(session_info.st_ino)) !=
                (expected_session_dev, expected_session_ino)):
            raise SystemExit(1)
    finally:
        os.close(session_fd)
finally:
    os.close(root_fd)
PY
}

proof_write_file() {
  local target="$1"
  local mode="${2:-600}"
  case "$target" in
    ""|*/*|.*) return 1 ;;
  esac
  proof_session_is_stable || return 1
  python3 -c '
import os
import secrets
import stat
import sys

configured_root, canonical_root, session_name, expected_root_dev, expected_root_ino, \
    expected_session_dev, expected_session_ino, target, mode = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(1)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino):
        raise SystemExit(1)
    session_fd = os.open(session_name, flags, dir_fd=root_fd)
    try:
        session_info = os.fstat(session_fd)
        if (not stat.S_ISDIR(session_info.st_mode) or
                (str(session_info.st_dev), str(session_info.st_ino)) !=
                (expected_session_dev, expected_session_ino)):
            raise SystemExit(1)
        data = sys.stdin.buffer.read(16 * 1024 * 1024 + 1)
        if len(data) > 16 * 1024 * 1024:
            raise SystemExit(1)
        temp = f".{target}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=session_fd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise SystemExit(1)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fchmod(fd, int(mode, 8))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, target, src_dir_fd=session_fd, dst_dir_fd=session_fd)
        os.fsync(session_fd)
    finally:
        os.close(session_fd)
finally:
    os.close(root_fd)
' "$root" "$proof_root_canonical" "$session_id" \
    "$proof_root_dev" "$proof_root_ino" "$proof_session_dev" "$proof_session_ino" \
    "$target" "$mode"
}

proof_remove_file() {
  local target="$1"
  case "$target" in
    ""|*/*|.*) return 1 ;;
  esac
  proof_session_is_stable || return 1
  python3 - "$root" "$proof_root_canonical" "$session_id" \
    "$proof_root_dev" "$proof_root_ino" "$proof_session_dev" "$proof_session_ino" "$target" <<'PY'
import os
import stat
import sys

configured_root, canonical_root, session_name, expected_root_dev, expected_root_ino, \
    expected_session_dev, expected_session_ino, target = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(1)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino):
        raise SystemExit(1)
    session_fd = os.open(session_name, flags, dir_fd=root_fd)
    try:
        session_info = os.fstat(session_fd)
        if (not stat.S_ISDIR(session_info.st_mode) or
                (str(session_info.st_dev), str(session_info.st_ino)) !=
                (expected_session_dev, expected_session_ino)):
            raise SystemExit(1)
        try:
            entry = os.stat(target, dir_fd=session_fd, follow_symlinks=False)
        except FileNotFoundError:
            raise SystemExit(0)
        if not (stat.S_ISREG(entry.st_mode) or stat.S_ISLNK(entry.st_mode)):
            raise SystemExit(1)
        os.unlink(target, dir_fd=session_fd)
        os.fsync(session_fd)
    finally:
        os.close(session_fd)
finally:
    os.close(root_fd)
PY
}

proof_write_history_file() {
  local history_key="$1"
  local target="$2"
  [[ "$history_key" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$target" =~ ^[A-Za-z0-9_-]+\.log$|^repo_identity$ ]] || return 1
  proof_root_is_stable || return 1
  python3 -c '
import os
import secrets
import stat
import sys

configured_root, canonical_root, expected_root_dev, expected_root_ino, history_key, target = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(1)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino):
        raise SystemExit(1)
    try:
        history_fd = os.open("history", flags, dir_fd=root_fd)
    except FileNotFoundError:
        os.mkdir("history", mode=0o700, dir_fd=root_fd)
        history_fd = os.open("history", flags, dir_fd=root_fd)
    try:
        try:
            key_fd = os.open(history_key, flags, dir_fd=history_fd)
        except FileNotFoundError:
            os.mkdir(history_key, mode=0o700, dir_fd=history_fd)
            key_fd = os.open(history_key, flags, dir_fd=history_fd)
        try:
            data = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
            if len(data) > 4 * 1024 * 1024:
                raise SystemExit(1)
            temp = f".{target}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=key_fd)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise SystemExit(1)
                view = memoryview(data)
                while view:
                    written = os.write(fd, view)
                    view = view[written:]
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temp, target, src_dir_fd=key_fd, dst_dir_fd=key_fd)
            os.fsync(key_fd)
        finally:
            os.close(key_fd)
    finally:
        os.close(history_fd)
    os.fsync(root_fd)
finally:
    os.close(root_fd)
' "$root" "$proof_root_canonical" "$proof_root_dev" "$proof_root_ino" \
    "$history_key" "$target"
}

proof_read_history_last_line() {
  local history_key="$1"
  local target="$2"
  [[ "$history_key" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$target" =~ ^[A-Za-z0-9_-]+\.log$|^repo_identity$ ]] || return 2
  proof_root_is_stable || return 2
  python3 - "$root" "$proof_root_canonical" "$proof_root_dev" "$proof_root_ino" \
    "$history_key" "$target" <<'PY'
import os
import stat
import sys

configured_root, canonical_root, expected_root_dev, expected_root_ino, history_key, target = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
if os.path.realpath(configured_root) != canonical_root:
    raise SystemExit(2)
root_fd = os.open(canonical_root, flags)
try:
    root_info = os.fstat(root_fd)
    if (str(root_info.st_dev), str(root_info.st_ino)) != (expected_root_dev, expected_root_ino):
        raise SystemExit(2)
    try:
        history_fd = os.open("history", flags, dir_fd=root_fd)
        key_fd = os.open(history_key, flags, dir_fd=history_fd)
        file_fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=key_fd)
    except FileNotFoundError:
        raise SystemExit(1)
    try:
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 4 * 1024 * 1024:
            raise SystemExit(2)
        data = os.read(file_fd, 4 * 1024 * 1024 + 1)
    finally:
        os.close(file_fd)
        os.close(key_fd)
        os.close(history_fd)
    if len(data) > 4 * 1024 * 1024:
        raise SystemExit(2)
    lines = data.decode("utf-8").splitlines()
    if lines:
        print(lines[-1])
finally:
    os.close(root_fd)
PY
}

update_generic_stop_timestamps() {
  local session_name="$1"

  [ -n "$proof_root_canonical" ] &&
    [ -n "$proof_root_dev" ] && [ -n "$proof_root_ino" ] || return 1
  python3 - "$proof_root_canonical" "$session_name" "$proof_root_dev" \
    "$proof_root_ino" <<'PY'
import os
import fcntl
import secrets
import stat
import subprocess
import sys
import time

root, session_name, expected_root_dev, expected_root_ino = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
root_fd = os.open(root, flags)
temp_name = None
lock_fd = None
lock_held = False

def same_identity(info, dev, ino):
    return str(info.st_dev) == dev and str(info.st_ino) == ino

def path_is_root():
    try:
        info = os.stat(root, follow_symlinks=False)
    except OSError:
        return False
    return same_identity(info, expected_root_dev, expected_root_ino) and stat.S_ISDIR(info.st_mode)

try:
    root_info = os.fstat(root_fd)
    if not same_identity(root_info, expected_root_dev, expected_root_ino) or not path_is_root():
        raise SystemExit(1)
    try:
        session_fd = os.open(session_name, flags, dir_fd=root_fd)
    except FileNotFoundError:
        try:
            os.mkdir(session_name, mode=0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        session_fd = os.open(session_name, flags, dir_fd=root_fd)
    try:
        session_info = os.fstat(session_fd)
        if not stat.S_ISDIR(session_info.st_mode):
            raise SystemExit(1)

        try:
            lock_fd = os.open(
                "stop_timestamps.lock",
                os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=session_fd,
            )
        except OSError:
            raise SystemExit(1)
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_nlink != 1:
            raise SystemExit(1)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        lock_held = True
        # The serialization point is deliberately before the clock read. A
        # callback that arrived earlier must not be discarded merely because
        # another callback acquired the lock first and observed a later time.
        try:
            clock = subprocess.check_output(["date", "+%s"], text=True).strip()
        except (OSError, subprocess.SubprocessError):
            raise SystemExit(1)
        if not clock.isdigit():
            raise SystemExit(1)
        wall_now = int(time.time())
        now = min(int(clock), wall_now)
        cutoff = wall_now - 300

        def session_is_current():
            try:
                root_entry = os.stat(session_name, dir_fd=root_fd, follow_symlinks=False)
            except OSError:
                return False
            return (stat.S_ISDIR(root_entry.st_mode) and
                    root_entry.st_dev == session_info.st_dev and root_entry.st_ino == session_info.st_ino)

        if not path_is_root() or not session_is_current():
            raise SystemExit(1)

        stale_temps = sorted(
            name for name in os.listdir(session_fd)
            if name.startswith(".stop_timestamps.tmp.")
        )
        if len(stale_temps) > 64:
            raise SystemExit(1)
        for stale_name in stale_temps:
            stale_info = os.stat(stale_name, dir_fd=session_fd, follow_symlinks=False)
            if not stat.S_ISREG(stale_info.st_mode) or stale_info.st_nlink != 1:
                raise SystemExit(1)
            os.unlink(stale_name, dir_fd=session_fd)
        if stale_temps:
            os.fsync(session_fd)

        timestamps_name = "stop_timestamps"
        old_identity = None
        old_values = []
        try:
            old_entry = os.stat(timestamps_name, dir_fd=session_fd, follow_symlinks=False)
        except FileNotFoundError:
            old_entry = None
        if old_entry is not None:
            if not stat.S_ISREG(old_entry.st_mode) or old_entry.st_nlink != 1:
                raise SystemExit(1)
            old_identity = (old_entry.st_dev, old_entry.st_ino)
            old_fd = os.open(timestamps_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=session_fd)
            try:
                current_old = os.fstat(old_fd)
                if (current_old.st_dev, current_old.st_ino) != old_identity:
                    raise SystemExit(1)
                data = bytearray()
                while True:
                    chunk = os.read(old_fd, 65536)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > 1048576:
                        raise SystemExit(1)
            finally:
                os.close(old_fd)
            complete_data = bytes(data)
            if complete_data and not complete_data.endswith(b"\n"):
                complete_data = complete_data[:complete_data.rfind(b"\n") + 1]
            for raw in complete_data.split(b"\n"):
                if (not raw or any(byte < 0x30 or byte > 0x39 for byte in raw) or
                        (raw.startswith(b"0") and raw != b"0")):
                    continue
                value = int(raw)
                if cutoff <= value <= wall_now:
                    old_values.append(value)

        values = old_values + [now]
        for _ in range(32):
            candidate = ".stop_timestamps.tmp.%s.%s" % (os.getpid(), secrets.token_hex(8))
            try:
                temp_fd = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=session_fd,
                )
            except FileExistsError:
                continue
            temp_name = candidate
            break
        else:
            raise SystemExit(1)
        try:
            temp_info = os.fstat(temp_fd)
            if not stat.S_ISREG(temp_info.st_mode) or temp_info.st_nlink != 1:
                raise SystemExit(1)
            payload = ("".join(str(value) + "\n" for value in values)).encode("ascii")
            view = memoryview(payload)
            while view:
                written = os.write(temp_fd, view)
                view = view[written:]
            os.fsync(temp_fd)
        finally:
            os.close(temp_fd)

        if not path_is_root() or not session_is_current():
            raise SystemExit(1)
        try:
            current_target = os.stat(timestamps_name, dir_fd=session_fd, follow_symlinks=False)
        except FileNotFoundError:
            current_target = None
        if old_identity is None:
            if current_target is not None:
                raise SystemExit(1)
        elif (current_target is None or not stat.S_ISREG(current_target.st_mode) or
              current_target.st_nlink != 1 or
              (current_target.st_dev, current_target.st_ino) != old_identity):
            raise SystemExit(1)
        current_temp = os.stat(temp_name, dir_fd=session_fd, follow_symlinks=False)
        if (not stat.S_ISREG(current_temp.st_mode) or current_temp.st_nlink != 1 or
                (current_temp.st_dev, current_temp.st_ino) != (temp_info.st_dev, temp_info.st_ino)):
            raise SystemExit(1)
        os.replace(temp_name, timestamps_name, src_dir_fd=session_fd, dst_dir_fd=session_fd)
        temp_name = None
        os.fsync(session_fd)
        if not path_is_root() or not session_is_current():
            raise SystemExit(1)
        print(len(values))
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=session_fd)
            except FileNotFoundError:
                pass
        if lock_held:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(session_fd)
finally:
    os.close(root_fd)
PY
}

legacy_eci_markers_for_cwd_safe() {
  local canonical_cwd

  [ -n "$proof_root_canonical" ] &&
    [ -n "$proof_root_dev" ] && [ -n "$proof_root_ino" ] || return 1
  canonical_cwd="$(codex_canonical_cwd "$cwd")" || return 1
  python3 - "$proof_root_canonical" "$proof_root_dev" "$proof_root_ino" \
    "$canonical_cwd" <<'PY'
import os
import stat
import sys

root, expected_dev, expected_ino, wanted_cwd = sys.argv[1:]
reserved = {
    "activity", "audit", "eci", "history", "pre-reviewer", "reviewer",
    "reviewer-dumps", "side-stop", "skip-stop", "skills",
}

def is_reserved(name):
    return name in reserved or name.startswith("security-warnings-")

flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
root_fd = os.open(root, flags)
try:
    root_info = os.fstat(root_fd)
    if ((str(root_info.st_dev), str(root_info.st_ino)) != (expected_dev, expected_ino)):
        raise SystemExit(1)
    root_path_info = os.stat(root, follow_symlinks=False)
    if (not stat.S_ISDIR(root_path_info.st_mode) or
            (str(root_path_info.st_dev), str(root_path_info.st_ino)) != (expected_dev, expected_ino)):
        raise SystemExit(1)
    for name in sorted(os.listdir(root_fd)):
        if not is_reserved(name):
            continue
        try:
            session_info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(session_info.st_mode):
            continue
        try:
            session_fd = os.open(name, flags, dir_fd=root_fd)
        except OSError:
            continue
        try:
            opened_session = os.fstat(session_fd)
            if (opened_session.st_dev, opened_session.st_ino) != (session_info.st_dev, session_info.st_ino):
                continue
            try:
                marker_info = os.stat("eci_active", dir_fd=session_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(marker_info.st_mode) or marker_info.st_nlink != 1:
                continue
            marker_fd = os.open("eci_active", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=session_fd)
            try:
                opened_marker = os.fstat(marker_fd)
                if (opened_marker.st_dev, opened_marker.st_ino) != (marker_info.st_dev, marker_info.st_ino):
                    continue
                data = bytearray()
                oversized = False
                while True:
                    chunk = os.read(marker_fd, 65536)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > 1048576:
                        oversized = True
                        break
                if oversized:
                    continue
                if (not data.endswith(b"\n") or b"\x00" in data or
                        any(byte < 0x20 and byte != 0x0a for byte in data) or 0x7f in data):
                    continue
                try:
                    lines = bytes(data).decode("utf-8").splitlines()
                except UnicodeDecodeError:
                    continue
                if (len(lines) not in (3, 4) or
                        not lines[0].startswith("scope: ") or
                        not lines[1].startswith("cwd: ") or
                        not lines[2].startswith("session_id: ")):
                    continue
                scope = lines[0][len("scope: "):]
                marker_cwd = lines[1][len("cwd: "):]
                marker_owner = lines[2][len("session_id: "):]
                if (not scope or not marker_cwd or marker_owner != name or
                        not is_reserved(marker_owner) or not marker_cwd.startswith("/") or
                        os.path.realpath(marker_cwd) != wanted_cwd):
                    continue
                if len(lines) == 4:
                    if not lines[3].startswith("created_utc: "):
                        continue
                    created = lines[3][len("created_utc: "):]
                    try:
                        parsed = __import__("datetime").datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
                    except ValueError:
                        continue
                    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != created:
                        continue
                if marker_cwd and os.path.realpath(marker_cwd) == wanted_cwd:
                    print(os.path.join(root, name, "eci_active"))
            finally:
                os.close(marker_fd)
        finally:
            os.close(session_fd)
finally:
    os.close(root_fd)
PY
}

json_continue() {
  jq -n '{continue: true}'
}

eci_recovery_owner=""
eci_recovery_generation=""
eci_recovery_artifact=""
eci_recovery_lock=""
eci_recovery_count=""
eci_recovery_marker=""
eci_recovery_owner_dir=""
eci_recovery_root=""
eci_recovery_root_dev=""
eci_recovery_root_ino=""
eci_recovery_owner_dev=""
eci_recovery_owner_ino=""
eci_recovery_lock_owner=""
eci_recovery_lock_token=""
eci_recovery_lock_lease_seconds=60
eci_recovery_lock_attempts=160
eci_recovery_lock_dev=""
eci_recovery_lock_ino=""
eci_recovery_observed_lock_dev=""
eci_recovery_observed_lock_ino=""
eci_recovery_observed_lock_token=""
eci_recovery_heartbeat_pid=""
eci_recovery_marker_valid=false
eci_marker_owner=""
eci_marker_cwd=""
eci_marker_created=""
eci_marker_scope=""

eci_recovery_blocked_reason() {
  printf 'ECI stop-loop recovery remains blocked for owner session %s and marker generation %s because recovery state is concurrently changing or unavailable; remain blocked.' \
    "$eci_recovery_owner" "$eci_recovery_generation"
}

eci_hash_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
  else
    return 1
  fi
}

eci_canonical_path() {
  local path="$1"
  local canonical

  canonical="$(realpath -m -- "$path" 2>/dev/null || true)"
  case "$canonical" in
    /*) printf '%s\n' "$canonical" ;;
    *) return 1 ;;
  esac
}

eci_lexical_path() {
  local path="$1"
  local lexical

  lexical="$(realpath -m -s -- "$path" 2>/dev/null || true)"
  case "$lexical" in
    /*) printf '%s\n' "$lexical" ;;
    *) return 1 ;;
  esac
}

eci_marker_has_no_control() {
  local value="$1"

  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

eci_marker_bytes_are_safe() {
  local marker="$1"

  python3 - "$marker" <<'PY'
import os
import stat
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(1)
    data = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
        if len(data) > 1048576:
            raise SystemExit(1)
finally:
    os.close(fd)

if b"\x00" in data or any(byte < 0x20 and byte != 0x0a for byte in data) or 0x7f in data:
    raise SystemExit(1)
if not data.endswith(b"\n"):
    raise SystemExit(1)
PY
}

eci_validate_marker() {
  local marker="$1"
  local last_byte cwd_canonical input_cwd_canonical
  local -a lines=()

  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  eci_marker_bytes_are_safe "$marker" || return 1
  last_byte="$(tail -c 1 -- "$marker" 2>/dev/null | od -An -t x1 | tr -d ' \n' || true)"
  [ "$last_byte" = 0a ] || return 1
  mapfile -t lines <"$marker" || return 1
  [ "${#lines[@]}" -eq 4 ] || return 1
  [[ "${lines[0]}" == "scope: "* ]] || return 1
  [[ "${lines[1]}" == "cwd: "* ]] || return 1
  [[ "${lines[2]}" == "session_id: "* ]] || return 1
  [[ "${lines[3]}" == "created_utc: "* ]] || return 1

  eci_marker_scope="${lines[0]#scope: }"
  eci_marker_cwd="${lines[1]#cwd: }"
  eci_marker_owner="${lines[2]#session_id: }"
  eci_marker_created="${lines[3]#created_utc: }"
  [ -n "$eci_marker_scope" ] && [ -n "$eci_marker_cwd" ] || return 1
  eci_marker_has_no_control "$eci_marker_scope" || return 1
  eci_marker_has_no_control "$eci_marker_cwd" || return 1
  eci_marker_has_no_control "$eci_marker_owner" || return 1
  eci_marker_has_no_control "$eci_marker_created" || return 1
  [[ "$eci_marker_cwd" = /* ]] || return 1
  cwd_canonical="$(eci_canonical_path "$eci_marker_cwd" || true)"
  [ -n "$cwd_canonical" ] || return 1
  input_cwd_canonical="$(eci_canonical_path "$cwd" || true)"
  [ -n "$input_cwd_canonical" ] && [ "$cwd_canonical" = "$input_cwd_canonical" ] || return 1
  codex_valid_session_id "$eci_marker_owner" || return 1
  codex_reserved_proof_dir "$eci_marker_owner" && return 1
  [[ "$eci_marker_created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ "$(date -u -d "$eci_marker_created" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)" = "$eci_marker_created" ] || return 1
  return 0
}

eci_recovery_identity() {
  local marker="$1"
  local root marker_canonical expected_marker owner_dir marker_generation owner_identity root_identity

  eci_recovery_marker_valid=false
  marker="$(eci_canonical_path "$marker" || true)"
  [ -n "$marker" ] || return 1
  eci_validate_marker "$marker" || return 1
  eci_recovery_marker_valid=true
  eci_recovery_owner="$eci_marker_owner"
  root="$(eci_canonical_path "$(codex_proof_root)" || true)"
  marker_canonical="$(eci_canonical_path "$marker" || true)"
  [ -n "$root" ] && [ -n "$marker_canonical" ] || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 2
  root_identity="$(stat -Lc '%d:%i' -- "$root" 2>/dev/null || true)"
  [ -n "$root_identity" ] || return 2
  eci_recovery_root="$root"
  eci_recovery_root_dev="${root_identity%%:*}"
  eci_recovery_root_ino="${root_identity#*:}"
  [[ "$eci_recovery_root_dev" =~ ^[0-9]+$ ]] &&
    [[ "$eci_recovery_root_ino" =~ ^[0-9]+$ ]] || return 2
  owner_dir="$root/$eci_marker_owner"
  [ "$marker_canonical" = "$owner_dir/eci_active" ] || return 2
  expected_marker="$owner_dir/eci_active"
  [ "$marker_canonical" = "$expected_marker" ] || return 2
  [ -f "$marker_canonical" ] && [ ! -L "$marker_canonical" ] || return 1
  marker_generation="$(eci_hash_file "$marker_canonical" || true)"
  [[ "$marker_generation" =~ ^[0-9a-f]{64}$ ]] || return 1

  eci_recovery_owner="$eci_marker_owner"
  eci_recovery_generation="$marker_generation"
  eci_recovery_marker="$marker_canonical"
  eci_recovery_owner_dir="$owner_dir"
  [ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || return 2
  owner_identity="$(stat -Lc '%d:%i' -- "$owner_dir" 2>/dev/null || true)"
  [ -n "$owner_identity" ] || return 2
  eci_recovery_owner_dev="${owner_identity%%:*}"
  eci_recovery_owner_ino="${owner_identity#*:}"
  [[ "$eci_recovery_owner_dev" =~ ^[0-9]+$ ]] &&
    [[ "$eci_recovery_owner_ino" =~ ^[0-9]+$ ]] || return 2
  eci_recovery_artifact="$owner_dir/eci-stop-loop-recovery.$marker_generation.json"
  eci_recovery_lock="$owner_dir/eci-stop-loop-recovery.$marker_generation.lock"
  eci_recovery_lock_owner="$eci_recovery_lock/owner"
  eci_recovery_count="$owner_dir/eci-stop-loop-recovery.$marker_generation.timestamps"
  return 0
}

eci_marker_identity_unchanged() {
  local marker="$1"
  local marker_canonical marker_generation

  eci_validate_marker "$marker" || return 1
  marker_canonical="$(eci_canonical_path "$marker" || true)"
  [ "$marker_canonical" = "$eci_recovery_marker" ] || return 1
  [ "$eci_marker_owner" = "$eci_recovery_owner" ] || return 1
  marker_generation="$(eci_hash_file "$marker_canonical" || true)"
  [ "$marker_generation" = "$eci_recovery_generation" ] || return 1
  return 0
}

eci_owner_dir_is_stable() {
  local identity

  [ -d "$eci_recovery_root" ] && [ ! -L "$eci_recovery_root" ] || return 1
  identity="$(stat -Lc '%d:%i' -- "$eci_recovery_root" 2>/dev/null || true)"
  [ "$identity" = "$eci_recovery_root_dev:$eci_recovery_root_ino" ] || return 1
  [ -d "$eci_recovery_owner_dir" ] && [ ! -L "$eci_recovery_owner_dir" ] || return 1
  identity="$(stat -Lc '%d:%i' -- "$eci_recovery_owner_dir" 2>/dev/null || true)"
  [ "$identity" = "$eci_recovery_owner_dev:$eci_recovery_owner_ino" ]
}

eci_recovery_paths_are_safe() {
  local state_path

  eci_owner_dir_is_stable || return 1
  [ ! -L "$eci_recovery_artifact" ] || return 1
  [ ! -L "$eci_recovery_count" ] || return 1
  [ ! -L "$eci_recovery_lock" ] || return 1
  if [ -e "$eci_recovery_artifact" ] && [ ! -f "$eci_recovery_artifact" ]; then
    return 1
  fi
  if [ -e "$eci_recovery_count" ] && [ ! -f "$eci_recovery_count" ]; then
    return 1
  fi
  if [ -e "$eci_recovery_lock" ] && [ ! -d "$eci_recovery_lock" ]; then
    return 1
  fi
  if [ -e "$eci_recovery_lock_owner" ] && [ ! -f "$eci_recovery_lock_owner" ]; then
    return 1
  fi
  if [ -e "$eci_recovery_lock_owner" ] && [ -L "$eci_recovery_lock_owner" ]; then
    return 1
  fi
  for state_path in "$eci_recovery_artifact" "$eci_recovery_count" "$eci_recovery_lock_owner"; do
    if [ -e "$state_path" ] && [ "$(stat -c '%h' -- "$state_path" 2>/dev/null || printf '0')" -ne 1 ]; then
      return 1
    fi
  done
  return 0
}

eci_flush_file() {
  local file="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import os
import stat
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  elif command -v sync >/dev/null 2>&1; then
    sync -d -- "$file" 2>/dev/null || sync >/dev/null 2>&1 || true
  fi
}

eci_flush_directory() {
  local directory="$1"
  local expected_dev="${2:-}"
  local expected_ino="${3:-}"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$directory" "$expected_dev" "$expected_ino" <<'PY'
import os
import sys

fd = os.open(
    sys.argv[1],
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(fd)
    if sys.argv[2] and (str(info.st_dev), str(info.st_ino)) != (sys.argv[2], sys.argv[3]):
        raise SystemExit(1)
    os.fsync(fd)
finally:
    os.close(fd)
PY
  fi
}

eci_write_existing_temp() {
  local file="$1"
  local mode="${2:-}"
  local expected_dir="${3:-}"
  local expected_dev="${4:-}"
  local expected_ino="${5:-}"
  local expected_file_dev="${6:-}"
  local expected_file_ino="${7:-}"
  local expected_token="${8:-}"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os
import stat
import sys

file_name, mode, expected_dir, expected_dev, expected_ino, expected_file_dev, expected_file_ino, expected_token = sys.argv[1:]
if not expected_dir or not expected_dev or not expected_ino:
    raise SystemExit(1)
if os.path.normpath(os.path.dirname(file_name)) != os.path.normpath(expected_dir):
    raise SystemExit(1)
directory_fd = os.open(
    expected_dir,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    directory_info = os.fstat(directory_fd)
    if (str(directory_info.st_dev), str(directory_info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(1)
    fd = os.open(
        os.path.basename(file_name),
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode) or stat_result.st_nlink != 1:
            raise RuntimeError("temporary state is not a regular file")
        if expected_file_dev and (str(stat_result.st_dev), str(stat_result.st_ino)) != (expected_file_dev, expected_file_ino):
            raise RuntimeError("temporary state inode changed")
        if expected_token:
            os.lseek(fd, 0, os.SEEK_SET)
            if os.read(fd, len(expected_token) + 1) != (expected_token + "\n").encode("ascii"):
                raise RuntimeError("temporary state token changed")
            os.ftruncate(fd, 0)
            os.lseek(fd, 0, os.SEEK_SET)
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(fd, view)
                view = view[written:]
        if mode:
            os.fchmod(fd, int(mode, 8))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
' "$file" "$mode" "$expected_dir" "$expected_dev" "$expected_ino" \
    "$expected_file_dev" "$expected_file_ino" "$expected_token"
    return $?
  fi
  return 1
}

eci_remove_recovery_lock_directory() {
  local directory="$1"
  local lock_name="$2"
  local expected_dir_dev="$3"
  local expected_dir_ino="$4"
  local expected_lock_dev="${5:-}"
  local expected_lock_ino="${6:-}"
  local expected_token="${7:-}"

  python3 - "$directory" "$lock_name" "$expected_dir_dev" "$expected_dir_ino" \
    "$expected_lock_dev" "$expected_lock_ino" "$expected_token" <<'PY'
import os
import stat
import sys

directory, lock_name, expected_dir_dev, expected_dir_ino, expected_lock_dev, expected_lock_ino, expected_token = sys.argv[1:]
parent_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    parent_info = os.fstat(parent_fd)
    if (str(parent_info.st_dev), str(parent_info.st_ino)) != (expected_dir_dev, expected_dir_ino):
        raise SystemExit(1)
    try:
        lock_info = os.stat(lock_name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if not stat.S_ISDIR(lock_info.st_mode):
        raise SystemExit(1)
    if expected_lock_dev and (str(lock_info.st_dev), str(lock_info.st_ino)) != (expected_lock_dev, expected_lock_ino):
        raise SystemExit(1)
    lock_fd = os.open(
        lock_name,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_fd,
    )
    try:
        lock_info = os.fstat(lock_fd)
        if expected_lock_dev and (str(lock_info.st_dev), str(lock_info.st_ino)) != (expected_lock_dev, expected_lock_ino):
            raise SystemExit(1)
        if expected_token:
            try:
                owner_fd = os.open("owner", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=lock_fd)
            except OSError:
                raise SystemExit(1)
            try:
                owner_info = os.fstat(owner_fd)
                if not stat.S_ISREG(owner_info.st_mode) or owner_info.st_nlink != 1 or owner_info.st_size > 4096:
                    raise SystemExit(1)
                owner_bytes = os.read(owner_fd, 4097)
            finally:
                os.close(owner_fd)
            if len(owner_bytes) > 4096 or not owner_bytes.endswith(b"\n"):
                raise SystemExit(1)
            try:
                owner_lines = owner_bytes.decode("ascii").splitlines()
            except UnicodeDecodeError:
                raise SystemExit(1)
            if len(owner_lines) != 4 or owner_lines[3] != "token: " + expected_token:
                raise SystemExit(1)
        for entry_name in os.listdir(lock_fd):
            if entry_name != "owner" and not entry_name.startswith(".owner."):
                raise SystemExit(1)
            entry = os.stat(entry_name, dir_fd=lock_fd, follow_symlinks=False)
            if not stat.S_ISREG(entry.st_mode) or entry.st_nlink > 2:
                raise SystemExit(1)
            os.unlink(entry_name, dir_fd=lock_fd)
        os.fsync(lock_fd)
    finally:
        os.close(lock_fd)
    os.rmdir(lock_name, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

eci_remove_temp_in_directory() {
  local file="$1"
  local directory="$2"
  local expected_dev="$3"
  local expected_ino="$4"
  local expected_file_dev="${5:-}"
  local expected_file_ino="${6:-}"
  local expected_token="${7:-}"
  local expected_hash="${8:-}"

  python3 - "$file" "$directory" "$expected_dev" "$expected_ino" \
    "$expected_file_dev" "$expected_file_ino" "$expected_token" "$expected_hash" <<'PY'
import hashlib
import os
import stat
import sys

file_name, directory, expected_dev, expected_ino, expected_file_dev, expected_file_ino, expected_token, expected_hash = sys.argv[1:]
if os.path.normpath(os.path.dirname(file_name)) != os.path.normpath(directory):
    raise SystemExit(0)
directory_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(directory_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(0)
    name = os.path.basename(file_name)
    try:
        entry = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if (expected_file_dev and
        (str(entry.st_dev), str(entry.st_ino)) != (expected_file_dev, expected_file_ino)):
        raise SystemExit(0)
    if expected_token:
        fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        try:
            if os.read(fd, len(expected_token) + 1) != (expected_token + "\n").encode("ascii"):
                raise SystemExit(0)
        finally:
            os.close(fd)
    if expected_hash:
        fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        try:
            digest = hashlib.sha256()
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                digest.update(chunk)
        finally:
            os.close(fd)
        if digest.hexdigest() != expected_hash:
            raise SystemExit(0)
    if stat.S_ISREG(entry.st_mode) and entry.st_nlink <= 2 or stat.S_ISLNK(entry.st_mode):
        os.unlink(name, dir_fd=directory_fd)
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

eci_link_temp_in_directory() {
  local file="$1"
  local target="$2"
  local directory="$3"
  local expected_dev="$4"
  local expected_ino="$5"
  local expected_file_dev="${6:-}"
  local expected_file_ino="${7:-}"
  local expected_hash="${8:-}"

  python3 - "$file" "$target" "$directory" "$expected_dev" "$expected_ino" \
    "$expected_file_dev" "$expected_file_ino" "$expected_hash" <<'PY'
import ctypes
import hashlib
import os
import stat
import sys

file_name, target_name, directory, expected_dev, expected_ino, expected_file_dev, expected_file_ino, expected_hash = sys.argv[1:]
if (os.path.normpath(os.path.dirname(file_name)) != os.path.normpath(directory) or
        os.path.normpath(os.path.dirname(target_name)) != os.path.normpath(directory)):
    raise SystemExit(3)
directory_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(directory_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(3)
    source_name = os.path.basename(file_name)
    source_fd = os.open(source_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
    try:
        source = os.fstat(source_fd)
        if not stat.S_ISREG(source.st_mode) or source.st_nlink != 1:
            raise SystemExit(3)
        if expected_file_dev and (str(source.st_dev), str(source.st_ino)) != (expected_file_dev, expected_file_ino):
            raise SystemExit(3)
        if expected_hash:
            digest = hashlib.sha256()
            while True:
                chunk = os.read(source_fd, 65536)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != expected_hash:
                raise SystemExit(3)
        try:
            target = os.stat(os.path.basename(target_name), dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            target = None
        if target is not None:
            if stat.S_ISREG(target.st_mode) and target.st_nlink == 1:
                raise SystemExit(2)
            raise SystemExit(3)
        libc = ctypes.CDLL(None, use_errno=True)
        libc.linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        libc.linkat.restype = ctypes.c_int
        if libc.linkat(-100, f"/proc/self/fd/{source_fd}".encode(), directory_fd,
                      os.path.basename(target_name).encode(), 0x400) != 0:
            raise OSError(ctypes.get_errno(), "descriptor-anchored install failed")
        try:
            current = os.stat(source_name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None and (current.st_dev, current.st_ino) == (source.st_dev, source.st_ino):
            os.unlink(source_name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        os.close(source_fd)
finally:
    os.close(directory_fd)
PY
}

eci_replace_temp_in_directory() {
  local file="$1"
  local target="$2"
  local directory="$3"
  local expected_dev="$4"
  local expected_ino="$5"
  local expected_file_dev="${6:-}"
  local expected_file_ino="${7:-}"
  local expected_hash="${8:-}"

  python3 - "$file" "$target" "$directory" "$expected_dev" "$expected_ino" \
    "$expected_file_dev" "$expected_file_ino" "$expected_hash" <<'PY'
import ctypes
import hashlib
import os
import stat
import sys

file_name, target_name, directory, expected_dev, expected_ino, expected_file_dev, expected_file_ino, expected_hash = sys.argv[1:]
if (os.path.normpath(os.path.dirname(file_name)) != os.path.normpath(directory) or
        os.path.normpath(os.path.dirname(target_name)) != os.path.normpath(directory)):
    raise SystemExit(1)
directory_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(directory_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(1)
    source_name = os.path.basename(file_name)
    source_fd = os.open(source_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
    try:
        source = os.fstat(source_fd)
        if not stat.S_ISREG(source.st_mode) or source.st_nlink != 1:
            raise SystemExit(1)
        if expected_file_dev and (str(source.st_dev), str(source.st_ino)) != (expected_file_dev, expected_file_ino):
            raise SystemExit(1)
        if expected_hash:
            digest = hashlib.sha256()
            while True:
                chunk = os.read(source_fd, 65536)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != expected_hash:
                raise SystemExit(1)
        try:
            target = os.stat(os.path.basename(target_name), dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            target = None
        if target is not None:
            if not stat.S_ISREG(target.st_mode) or target.st_nlink != 1:
                raise SystemExit(1)
            current_target = os.stat(os.path.basename(target_name), dir_fd=directory_fd, follow_symlinks=False)
            if (current_target.st_dev, current_target.st_ino) != (target.st_dev, target.st_ino):
                raise SystemExit(1)
            os.unlink(os.path.basename(target_name), dir_fd=directory_fd)
        libc = ctypes.CDLL(None, use_errno=True)
        libc.linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        libc.linkat.restype = ctypes.c_int
        if libc.linkat(-100, f"/proc/self/fd/{source_fd}".encode(), directory_fd,
                      os.path.basename(target_name).encode(), 0x400) != 0:
            raise OSError(ctypes.get_errno(), "descriptor-anchored replacement failed")
        try:
            current = os.stat(source_name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None and (current.st_dev, current.st_ino) == (source.st_dev, source.st_ino):
            os.unlink(source_name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        os.close(source_fd)
finally:
    os.close(directory_fd)
PY
}

eci_mkdir_lock_in_owner() {
  python3 - "$eci_recovery_owner_dir" "$(basename "$eci_recovery_lock")" \
    "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" <<'PY'
import errno
import os
import sys

directory, name, expected_dev, expected_ino = sys.argv[1:]
directory_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(directory_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(3)
    try:
        os.mkdir(name, mode=0o700, dir_fd=directory_fd)
    except FileExistsError:
        raise SystemExit(1)
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

eci_create_temp_in_directory() {
  local directory="$1"
  local expected_dev="$2"
  local expected_ino="$3"
  local prefix="$4"

  python3 - "$directory" "$expected_dev" "$expected_ino" "$prefix" <<'PY'
import os
import secrets
import stat
import sys

directory, expected_dev, expected_ino, prefix = sys.argv[1:]
directory_fd = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(directory_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(1)
    for _ in range(32):
        name = prefix + secrets.token_hex(6)
        try:
            fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=directory_fd,
            )
        except FileExistsError:
            continue
        try:
            created = os.fstat(fd)
            if not stat.S_ISREG(created.st_mode) or created.st_nlink != 1:
                os.unlink(name, dir_fd=directory_fd)
                raise SystemExit(1)
            token = secrets.token_hex(16)
            os.write(fd, (token + "\n").encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(directory_fd)
        print(f"{os.path.join(directory, name)}|{created.st_dev}:{created.st_ino}|{token}")
        raise SystemExit(0)
    raise SystemExit(1)
finally:
    os.close(directory_fd)
PY
}

eci_expected_recovery_reason() {
  local event_key="eci-stop-loop-recovery:$eci_recovery_owner:$eci_recovery_generation"

  printf 'ECI stop-loop recovery active for owner session %s and marker generation %s. Perform exactly one distinct recovery action, then await an event with matching key %s; duplicate or missing keys, repeated callbacks, timers, status, and timeouts are no-ops.\n' \
    "$eci_recovery_owner" "$eci_recovery_generation" "$event_key"
}

eci_verify_exact_file() {
  local file="$1"
  local expected="$2"

  python3 - "$file" "$expected" <<'PY'
import os
import stat
import sys

flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(sys.argv[1], flags)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(1)
    actual = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        actual += chunk
        if len(actual) > 65536:
            raise SystemExit(1)
    expected = (sys.argv[2] + "\n").encode("utf-8")
    raise SystemExit(0 if actual == expected else 1)
finally:
    os.close(fd)
PY
}

eci_read_epoch_lines() {
  local file="$1"
  local cutoff="$2"
  local now="$3"

  python3 - "$file" "$cutoff" "$now" <<'PY'
import os
import stat
import sys

flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(sys.argv[1], flags)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(2)
    data = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
        if len(data) > 65536:
            raise SystemExit(2)
finally:
    os.close(fd)

if data and not data.endswith(b"\n"):
    raise SystemExit(2)
cutoff = int(sys.argv[2])
now = int(sys.argv[3])
for raw in data.split(b"\n"):
    if not raw or (raw.startswith(b"0") and raw != b"0"):
        continue
    if not raw.isdigit():
        continue
    value = int(raw)
    if cutoff <= value <= now:
        print(value)
PY
}

eci_read_lock_metadata_snapshot() {
  python3 - "$eci_recovery_lock_owner" <<'PY'
import os
import stat
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 4096:
        raise SystemExit(1)
    data = os.read(fd, 4097)
finally:
    os.close(fd)
if len(data) > 4096 or not data.endswith(b"\n"):
    raise SystemExit(1)
if any(byte < 0x20 and byte != 0x0a for byte in data) or 0x7f in data:
    raise SystemExit(1)
lines = data.decode("ascii").splitlines()
if len(lines) != 4:
    raise SystemExit(1)
if not all(line.startswith(prefix) for line, prefix in zip(
    lines, ("pid: ", "start_time: ", "lease_until: ", "token: ")
)):
    raise SystemExit(1)
print("\n".join(lines))
PY
}

eci_read_recovery_reason() {
  local expected_reason expected_json

  [ -f "$eci_recovery_artifact" ] && [ ! -L "$eci_recovery_artifact" ] || return 1
  expected_reason="$(eci_expected_recovery_reason)"
  expected_json="$(jq -cn \
    --arg owner "$eci_recovery_owner" \
    --arg marker "$eci_recovery_marker" \
    --arg generation "$eci_recovery_generation" \
    --arg reason "$expected_reason" \
    --arg event_key "eci-stop-loop-recovery:$eci_recovery_owner:$eci_recovery_generation" \
    '{schema:"eci-stop-loop-recovery/v1",owner_session_id:$owner,marker_path:$marker,marker_generation:$generation,threshold:5,last_action:"stop-hook block emitted",next_distinct_action:"read instructions or stop-checklist and identify the failing step",event_key:$event_key,reason:$reason}')" || return 1
  eci_verify_exact_file "$eci_recovery_artifact" "$expected_json" || return 1
  printf '%s' "$expected_reason"
}

eci_process_start_time() {
  local pid="$1"

  python3 - "$pid" <<'PY'
import pathlib
import sys

record = pathlib.Path("/proc") / sys.argv[1] / "stat"
data = record.read_bytes()
tail = data.rsplit(b")", 1)[-1].split()
print(tail[19].decode("ascii"))
PY
}

eci_lock_metadata_valid() {
  local now snapshot
  local -a fields=()

  [ -f "$eci_recovery_lock_owner" ] && [ ! -L "$eci_recovery_lock_owner" ] || return 1
  [ "$(stat -c '%h' -- "$eci_recovery_lock_owner" 2>/dev/null || printf '0')" -eq 1 ] || return 1
  snapshot="$(eci_read_lock_metadata_snapshot 2>/dev/null)" || return 1
  mapfile -t fields <<<"$snapshot" || return 1
  [ "${#fields[@]}" -eq 4 ] || return 1
  [[ "${fields[0]}" == "pid: "* ]] || return 1
  [[ "${fields[1]}" == "start_time: "* ]] || return 1
  [[ "${fields[2]}" == "lease_until: "* ]] || return 1
  [[ "${fields[3]}" == "token: "* ]] || return 1
  eci_lock_pid="${fields[0]#pid: }"
  eci_lock_start="${fields[1]#start_time: }"
  eci_lock_lease_until="${fields[2]#lease_until: }"
  eci_lock_token_on_disk="${fields[3]#token: }"
  [[ "$eci_lock_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$eci_lock_start" =~ ^[0-9]+$ ]] || return 1
  [[ "$eci_lock_lease_until" =~ ^[0-9]+$ ]] || return 1
  [[ "$eci_lock_token_on_disk" =~ ^[0-9a-f]{64}$ ]] || return 1
  now="$(date +%s)"
  [ "$eci_lock_lease_until" -le $((now + eci_recovery_lock_lease_seconds * 2)) ] || return 1
  return 0
}

eci_lock_is_stale() {
  local now lock_mtime age current_start lock_identity owner_mtime stale_token=""

  [ -d "$eci_recovery_lock" ] && [ ! -L "$eci_recovery_lock" ] || return 1
  lock_identity="$(stat -Lc '%d:%i' -- "$eci_recovery_lock" 2>/dev/null || true)"
  [[ "$lock_identity" == *:* ]] || return 1
  eci_recovery_observed_lock_dev="${lock_identity%%:*}"
  eci_recovery_observed_lock_ino="${lock_identity#*:}"
  eci_recovery_observed_lock_token=""
  now="$(date +%s)"
  if eci_lock_metadata_valid; then
    stale_token="$eci_lock_token_on_disk"
    if [ "$eci_lock_lease_until" -ge "$now" ]; then
      return 1
    fi
    current_start="$(eci_process_start_time "$eci_lock_pid" 2>/dev/null || true)"
    owner_mtime="$(stat -c '%Y' -- "$eci_recovery_lock_owner" 2>/dev/null || printf '0')"
    if [ "$current_start" = "$eci_lock_start" ] && kill -0 "$eci_lock_pid" 2>/dev/null &&
      [ "$now" -lt $((owner_mtime + eci_recovery_lock_lease_seconds * 2)) ]; then
      return 1
    fi
    eci_recovery_observed_lock_token="$stale_token"
    return 0
  fi
  lock_mtime="$(stat -c '%Y' -- "$eci_recovery_lock" 2>/dev/null || printf '0')"
  age=$((now - lock_mtime))
  [ "$age" -ge $((eci_recovery_lock_lease_seconds * 2)) ] ||
    [ "$age" -le $((-eci_recovery_lock_lease_seconds * 2)) ]
}

eci_reclaim_stale_lock() {
  local current_identity

  eci_lock_is_stale || return 1
  [ -d "$eci_recovery_lock" ] && [ ! -L "$eci_recovery_lock" ] || return 1
  current_identity="$(stat -Lc '%d:%i' -- "$eci_recovery_lock" 2>/dev/null || true)"
  [ "$current_identity" = "$eci_recovery_observed_lock_dev:$eci_recovery_observed_lock_ino" ] || return 1
  if [ -n "$eci_recovery_observed_lock_token" ]; then
    eci_lock_metadata_valid || return 1
    [ "$eci_lock_token_on_disk" = "$eci_recovery_observed_lock_token" ] || return 1
  fi
  eci_remove_recovery_lock_directory "$eci_recovery_owner_dir" \
    "$(basename "$eci_recovery_lock")" "$eci_recovery_owner_dev" \
    "$eci_recovery_owner_ino" "$eci_recovery_observed_lock_dev" \
    "$eci_recovery_observed_lock_ino" "$eci_recovery_observed_lock_token" 2>/dev/null
}

eci_write_lock_owner() {
  local now start owner_tmp owner_tmp_record owner_tmp_identity lock_identity
  local owner_tmp_dev owner_tmp_ino owner_tmp_token owner_tmp_hash

  start="$(eci_process_start_time "$$" 2>/dev/null || true)"
  [ -n "$start" ] || return 1
  lock_identity="$(stat -Lc '%d:%i' -- "$eci_recovery_lock" 2>/dev/null || true)"
  [ -n "$lock_identity" ] || return 1
  eci_recovery_lock_dev="${lock_identity%%:*}"
  eci_recovery_lock_ino="${lock_identity#*:}"
  [[ "$eci_recovery_lock_dev" =~ ^[0-9]+$ ]] &&
    [[ "$eci_recovery_lock_ino" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  eci_recovery_lock_token="$(printf '%s:%s:%s:%s' "$eci_recovery_owner" "$$" "$start" "$now" | sha256sum | awk '{print $1}')"
  owner_tmp_record="$(eci_create_temp_in_directory "$eci_recovery_lock" \
    "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" '.owner.' 2>/dev/null || true)"
  owner_tmp="${owner_tmp_record%%|*}"
  owner_tmp_identity="${owner_tmp_record#*|}"
  owner_tmp_dev="${owner_tmp_identity%%:*}"
  owner_tmp_ino="${owner_tmp_identity#*:}"
  owner_tmp_ino="${owner_tmp_ino%%|*}"
  owner_tmp_token="${owner_tmp_record##*|}"
  [[ "$owner_tmp_record" == *'|'*'|'* ]] || return 1
  [ -n "$owner_tmp" ] || return 1
  if ! {
    printf 'pid: %s\n' "$$"
    printf 'start_time: %s\n' "$start"
    printf 'lease_until: %s\n' "$((now + eci_recovery_lock_lease_seconds))"
    printf 'token: %s\n' "$eci_recovery_lock_token"
  } | eci_write_existing_temp "$owner_tmp" 600 "$eci_recovery_lock" \
    "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" "$owner_tmp_dev" "$owner_tmp_ino" "$owner_tmp_token"; then
    eci_remove_temp_in_directory "$owner_tmp" "$eci_recovery_lock" \
      "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" "$owner_tmp_dev" "$owner_tmp_ino" "$owner_tmp_token" || true
    return 1
  fi
  owner_tmp_hash="$(eci_hash_file "$owner_tmp" || true)"
  [[ "$owner_tmp_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  if ! eci_link_temp_in_directory "$owner_tmp" "$eci_recovery_lock_owner" \
    "$eci_recovery_lock" "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" \
    "$owner_tmp_dev" "$owner_tmp_ino" "$owner_tmp_hash" 2>/dev/null; then
    eci_remove_temp_in_directory "$owner_tmp" "$eci_recovery_lock" \
      "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" "$owner_tmp_dev" "$owner_tmp_ino" "" "$owner_tmp_hash" || true
    return 1
  fi
  eci_flush_directory "$eci_recovery_lock" "$eci_recovery_lock_dev" \
    "$eci_recovery_lock_ino" || return 1
  return 0
}

eci_touch_lock_owner() {
  python3 - "$eci_recovery_lock" "$eci_recovery_lock_dev" \
    "$eci_recovery_lock_ino" <<'PY'
import os
import stat
import sys

lock_path, expected_dev, expected_ino = sys.argv[1:]
lock_fd = os.open(
    lock_path,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(lock_fd)
    if (str(info.st_dev), str(info.st_ino)) != (expected_dev, expected_ino):
        raise SystemExit(1)
    owner = os.stat("owner", dir_fd=lock_fd, follow_symlinks=False)
    if not stat.S_ISREG(owner.st_mode) or owner.st_nlink != 1:
        raise SystemExit(1)
    os.utime("owner", None, dir_fd=lock_fd, follow_symlinks=False)
    os.fsync(lock_fd)
finally:
    os.close(lock_fd)
PY
}

eci_start_lock_heartbeat() {
  local parent_pid="$$"
  local parent_start

  parent_start="$(eci_process_start_time "$parent_pid" 2>/dev/null || true)"
  [ -n "$parent_start" ] || return 1
  (
    while [ "$(eci_process_start_time "$parent_pid" 2>/dev/null || true)" = "$parent_start" ] &&
      kill -0 "$parent_pid" 2>/dev/null; do
      sleep 1
      eci_touch_lock_owner 2>/dev/null || exit 0
    done
  ) &
  eci_recovery_heartbeat_pid="$!"
}

eci_stop_lock_heartbeat() {
  if [ -n "${eci_recovery_heartbeat_pid:-}" ]; then
    kill "$eci_recovery_heartbeat_pid" 2>/dev/null || true
    wait "$eci_recovery_heartbeat_pid" 2>/dev/null || true
    eci_recovery_heartbeat_pid=""
  fi
}

eci_acquire_recovery_lock() {
  local attempt

  for ((attempt = 1; attempt <= eci_recovery_lock_attempts; attempt++)); do
    eci_recovery_paths_are_safe || return 1
    if [ ! -e "$eci_recovery_lock" ] && eci_mkdir_lock_in_owner 2>/dev/null; then
      if eci_write_lock_owner; then
        eci_start_lock_heartbeat || {
          eci_remove_recovery_lock_directory "$eci_recovery_owner_dir" \
            "$(basename "$eci_recovery_lock")" "$eci_recovery_owner_dev" \
            "$eci_recovery_owner_ino" "$eci_recovery_lock_dev" "$eci_recovery_lock_ino" \
            2>/dev/null || true
          return 1
        }
        return 0
      fi
      eci_remove_recovery_lock_directory "$eci_recovery_owner_dir" \
        "$(basename "$eci_recovery_lock")" "$eci_recovery_owner_dev" \
        "$eci_recovery_owner_ino" 2>/dev/null || true
      return 1
    fi
    eci_owner_dir_is_stable || return 1
    [ ! -L "$eci_recovery_lock" ] || return 1
    [ -d "$eci_recovery_lock" ] || return 1
    if { [ "$attempt" -eq 1 ] || [ $((attempt % 4)) -eq 0 ]; } && eci_reclaim_stale_lock; then
      continue
    fi
    sleep 0.01
  done
  return 1
}

eci_release_recovery_lock() {
  eci_stop_lock_heartbeat
  if [ ! -d "$eci_recovery_lock" ] || [ -L "$eci_recovery_lock" ]; then
    return 0
  fi
  if eci_lock_metadata_valid && [ "${eci_lock_token_on_disk:-}" = "${eci_recovery_lock_token:-}" ] &&
    [ "${eci_lock_pid:-}" = "$$" ]; then
    eci_remove_recovery_lock_directory "$eci_recovery_owner_dir" \
      "$(basename "$eci_recovery_lock")" "$eci_recovery_owner_dev" \
      "$eci_recovery_owner_ino" "$eci_recovery_lock_dev" \
      "$eci_recovery_lock_ino" "$eci_recovery_lock_token" 2>/dev/null || true
  fi
}

eci_recovery_reason() {
  local marker="$1"
  local now cutoff tmp recent_count recovery_reason verified_reason artifact_tmp expected_reason recent_content
  local tmp_record tmp_identity tmp_dev tmp_ino tmp_token tmp_hash
  local artifact_tmp_record artifact_tmp_identity artifact_tmp_dev artifact_tmp_ino artifact_tmp_token artifact_tmp_hash
  local initial_generation initial_marker identity_status

  if eci_recovery_identity "$marker"; then
    :
  else
    identity_status=$?
    if [ "$identity_status" -eq 2 ] && [ "$eci_recovery_marker_valid" = true ]; then
      eci_recovery_blocked_reason
      return 0
    fi
    return 1
  fi
  if ! eci_recovery_paths_are_safe; then
    eci_recovery_blocked_reason
    return 0
  fi
  if [ -e "$eci_recovery_artifact" ]; then
    recovery_reason="$(eci_read_recovery_reason || true)"
    [ -n "$recovery_reason" ] || recovery_reason="ECI stop-loop recovery artifact is invalid or conflicting; remain blocked."
    printf '%s' "$recovery_reason"
    return 0
  fi
  initial_generation="$eci_recovery_generation"
  initial_marker="$eci_recovery_marker"
  if ! eci_acquire_recovery_lock; then
    eci_recovery_blocked_reason
    return 0
  fi
  if ! eci_marker_identity_unchanged "$marker" ||
    [ "$eci_recovery_generation" != "$initial_generation" ] ||
    [ "$eci_recovery_marker" != "$initial_marker" ]; then
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  fi
  eci_recovery_paths_are_safe || {
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  }
  if [ -e "$eci_recovery_artifact" ]; then
    recovery_reason="$(eci_read_recovery_reason || true)"
    [ -n "$recovery_reason" ] || recovery_reason="ECI stop-loop recovery artifact is invalid or conflicting; remain blocked."
    eci_release_recovery_lock
    printf '%s' "$recovery_reason"
    return 0
  fi

  now="$(date +%s)"
  cutoff=$((now - 300))
  tmp_record="$(eci_create_temp_in_directory "$eci_recovery_owner_dir" \
    "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
    ".eci-stop-loop-recovery-count.$eci_recovery_generation." 2>/dev/null || true)"
  tmp="${tmp_record%%|*}"
  tmp_identity="${tmp_record#*|}"
  tmp_dev="${tmp_identity%%:*}"
  tmp_ino="${tmp_identity#*:}"
  tmp_ino="${tmp_ino%%|*}"
  tmp_token="${tmp_record##*|}"
  [[ "$tmp_record" == *'|'*'|'* ]] || tmp=""
  [ -n "$tmp" ] || {
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  }
  if [ -e "$eci_recovery_count" ]; then
    if ! recent_content="$(eci_read_epoch_lines "$eci_recovery_count" "$cutoff" "$now" 2>/dev/null)"; then
      eci_remove_temp_in_directory "$tmp" "$eci_recovery_owner_dir" \
        "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$tmp_dev" "$tmp_ino" "$tmp_token" || true
      eci_release_recovery_lock
      eci_recovery_blocked_reason
      return 0
    fi
  else
    recent_content=""
  fi
  if [ -n "$recent_content" ]; then
    recent_content="$recent_content
$now"
  else
    recent_content="$now"
  fi
  if ! printf '%s\n' "$recent_content" | eci_write_existing_temp "$tmp" "" \
    "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
    "$tmp_dev" "$tmp_ino" "$tmp_token"; then
    eci_remove_temp_in_directory "$tmp" "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$tmp_dev" "$tmp_ino" "$tmp_token" || true
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  fi
  recent_count="$(awk 'END { print NR + 0 }' "$tmp")"
  tmp_hash="$(eci_hash_file "$tmp" || true)"
  [[ "$tmp_hash" =~ ^[0-9a-f]{64}$ ]] || {
    eci_remove_temp_in_directory "$tmp" "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$tmp_dev" "$tmp_ino" "" "$tmp_hash" || true
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  }
  [ ! -L "$eci_recovery_count" ] || {
    eci_remove_temp_in_directory "$tmp" "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$tmp_dev" "$tmp_ino" "$tmp_token" || true
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  }
  if ! eci_replace_temp_in_directory "$tmp" "$eci_recovery_count" \
    "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
    "$tmp_dev" "$tmp_ino" "" "" "$tmp_hash"; then
    eci_remove_temp_in_directory "$tmp" "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$tmp_dev" "$tmp_ino" "" "$tmp_hash" || true
    eci_release_recovery_lock
    eci_recovery_blocked_reason
    return 0
  fi
  eci_flush_directory "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" \
    "$eci_recovery_owner_ino" || true

  if [ "$recent_count" -ge 5 ]; then
    expected_reason="$(eci_expected_recovery_reason)"
    artifact_tmp_record="$(eci_create_temp_in_directory "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
      ".eci-stop-loop-recovery-artifact.$eci_recovery_generation." 2>/dev/null || true)"
    artifact_tmp="${artifact_tmp_record%%|*}"
    artifact_tmp_identity="${artifact_tmp_record#*|}"
    artifact_tmp_dev="${artifact_tmp_identity%%:*}"
    artifact_tmp_ino="${artifact_tmp_identity#*:}"
    artifact_tmp_ino="${artifact_tmp_ino%%|*}"
    artifact_tmp_token="${artifact_tmp_record##*|}"
    [[ "$artifact_tmp_record" == *'|'*'|'* ]] || artifact_tmp=""
    if [ -z "$artifact_tmp" ] || ! jq -cn \
      --arg owner "$eci_recovery_owner" \
      --arg marker "$eci_recovery_marker" \
      --arg generation "$eci_recovery_generation" \
      --arg reason "$expected_reason" \
      --arg event_key "eci-stop-loop-recovery:$eci_recovery_owner:$eci_recovery_generation" \
      '{schema:"eci-stop-loop-recovery/v1",owner_session_id:$owner,marker_path:$marker,marker_generation:$generation,threshold:5,last_action:"stop-hook block emitted",next_distinct_action:"read instructions or stop-checklist and identify the failing step",event_key:$event_key,reason:$reason}' \
      | eci_write_existing_temp "$artifact_tmp" 444 "$eci_recovery_owner_dir" \
        "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$artifact_tmp_dev" "$artifact_tmp_ino" "$artifact_tmp_token"; then
      [ -n "$artifact_tmp" ] && eci_remove_temp_in_directory "$artifact_tmp" \
        "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
        "$artifact_tmp_dev" "$artifact_tmp_ino" "$artifact_tmp_token" || true
      eci_release_recovery_lock
      eci_recovery_blocked_reason
      return 0
    fi
    artifact_tmp_hash="$(eci_hash_file "$artifact_tmp" || true)"
    if [[ ! "$artifact_tmp_hash" =~ ^[0-9a-f]{64}$ ]]; then
      eci_remove_temp_in_directory "$artifact_tmp" "$eci_recovery_owner_dir" \
        "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$artifact_tmp_dev" "$artifact_tmp_ino" "" "$artifact_tmp_hash" || true
      eci_release_recovery_lock
      eci_recovery_blocked_reason
      return 0
    fi
    if [ -L "$eci_recovery_artifact" ]; then
      recovery_reason="ECI stop-loop recovery artifact is invalid or conflicting; remain blocked."
    elif eci_link_temp_in_directory "$artifact_tmp" "$eci_recovery_artifact" \
      "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" \
      "$artifact_tmp_dev" "$artifact_tmp_ino" "$artifact_tmp_hash" 2>/dev/null; then
      eci_flush_directory "$eci_recovery_owner_dir" "$eci_recovery_owner_dev" \
        "$eci_recovery_owner_ino" || true
      recovery_reason="$(eci_read_recovery_reason || true)"
      [ -n "$recovery_reason" ] || recovery_reason="ECI stop-loop recovery could not verify its immutable artifact; remain blocked."
    elif [ -f "$eci_recovery_artifact" ]; then
      recovery_reason="$(eci_read_recovery_reason || true)"
      [ -n "$recovery_reason" ] || recovery_reason="ECI stop-loop recovery artifact is invalid or conflicting; remain blocked."
    else
      recovery_reason="ECI stop-loop recovery could not install its immutable artifact; remain blocked."
    fi
    eci_remove_temp_in_directory "$artifact_tmp" "$eci_recovery_owner_dir" \
      "$eci_recovery_owner_dev" "$eci_recovery_owner_ino" "$artifact_tmp_dev" "$artifact_tmp_ino" "" "$artifact_tmp_hash" || true
    eci_release_recovery_lock
    printf '%s' "$recovery_reason"
    return 0
  fi

  eci_release_recovery_lock
  return 1
}

json_block() {
  local reason="$1"
  local eci_marker="${2:-}" recovery_reason

  if ! proof_root_is_stable; then
    jq -n '{decision: "block", reason: "Configured proof root changed or became unavailable; remain blocked without writing recovery state."}'
    return 0
  fi

  if [ -n "$eci_marker" ]; then
    recovery_reason="$(eci_recovery_reason "$eci_marker" 2>/dev/null || true)"
    [ -n "$recovery_reason" ] && reason="$recovery_reason"
  elif [ -n "${proof_dir:-}" ]; then
    local recent_count
    if ! recent_count="$(update_generic_stop_timestamps "$session_id" 2>/dev/null)"; then
      jq -n '{decision: "block", reason: "Unable to safely update generic stop timestamps; remain blocked without writing recovery state."}'
      return 0
    fi

    if [ "$recent_count" -ge 5 ]; then
      reason="$reason LOOP DETECTED ($recent_count blocks in 5min). Recovery flow: read instructions or stop-checklist, identify failing step, stop again, do not retry same approach."
    fi
  fi

  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

active_eci_marker_for_stop() {
  local marker side_stop parent_session_id is_subagent_context=false

  if codex_hook_is_subagent_context "$input"; then
    is_subagent_context=true
  fi

  if codex_valid_session_id "$session_id"; then
    if [ "$is_subagent_context" = true ]; then
      parent_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
      [ "$session_id" = "$parent_session_id" ] && return 1
    fi

    marker="$(eci_canonical_path "$proof_root_canonical/$session_id/eci_active" || true)"
    [ -n "$marker" ] && [ -f "$marker" ] && { printf '%s\n' "$marker"; return 0; }

    [ "$is_subagent_context" = true ] && return 1

    side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)
    parent_session_id="$(codex_state_value "$side_stop" parent_session_id || true)"
    if codex_valid_session_id "$parent_session_id"; then
      marker="$(eci_canonical_path "$proof_root_canonical/$parent_session_id/eci_active" || true)"
      [ -n "$marker" ] && [ -f "$marker" ] && { printf '%s\n' "$marker"; return 0; }
    fi
  fi

  [ "$is_subagent_context" = true ] && return 1

  legacy_eci_markers_for_cwd_safe 2>/dev/null | head -n1
}

block_if_eci_active_for_stop() {
  local marker

  marker="$(active_eci_marker_for_stop || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  json_block "ECI is active for this stop attempt via marker $marker. Never stop until the ECI task is complete. Continue the ECI task, update the session project-understanding ledger, or use blocker-resolution-protocol before reporting a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>." "$marker"
  return 0
}

if ! proof_root_is_stable; then
  jq -n '{decision: "block", reason: "Configured proof root changed or became unavailable; remain blocked without writing recovery state."}'
  exit 0
fi

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) json_continue; exit 0 ;;
esac

if block_if_eci_active_for_stop; then
  exit 0
fi

if [ -z "$transcript_path" ]; then
  json_continue
  exit 0
fi

if ! ensure_proof_session_dir || ! proof_session_is_stable; then
  jq -n '{decision: "block", reason: "Configured proof root changed or became unavailable; remain blocked without writing recovery state."}'
  exit 0
fi

git_change_summary() {
  local repo="$1"
  local baseline="$2"
  local base status changed=false

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
      if ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
        printf 'commits changed since baseline %s..HEAD\n' "$base"
        changed=true
      fi
    fi
  fi

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    changed=true
  fi

  [ "$changed" = "true" ]
}

git_dirty_summary() {
  local repo="$1"
  local status

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    return 0
  fi

  return 1
}

git_head_summary() {
  local repo="$1"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$repo" log -1 --oneline 2>/dev/null || true
}

indent_text() {
  sed 's/^/  /'
}

touched_repo_change_summary() {
  local marker="$1"
  local repo base_status_sha status status_sha repo_wide path path_status found=false

  repo="$(codex_state_value "$marker" repo || true)"
  [ -n "$repo" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)"
  [ -n "$status" ] || return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path_status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal -- "$path" 2>/dev/null || true)"
    [ -n "$path_status" ] || continue
    if [ "$found" = false ]; then
      printf '%s\n' "$repo"
      found=true
    fi
    printf '%s\n' "$path_status" | indent_text
  done < <(awk 'index($0, "path: ") == 1 { print substr($0, 7) }' "$marker" 2>/dev/null)
  [ "$found" = true ] && return 0

  repo_wide="$(codex_state_value "$marker" repo_wide || true)"
  [ "$repo_wide" = true ] || return 1

  base_status_sha="$(codex_state_value "$marker" status_sha || true)"
  status_sha="$(codex_hash_string "$status")"

  if [ -n "$status" ] && [ -n "$base_status_sha" ] && [ "$status_sha" != "$base_status_sha" ]; then
    printf '%s\n' "$repo"
    printf '%s\n' "$status" | indent_text
    return 0
  fi

  return 1
}

touched_repos_change_summary() {
  local session_id="$1"
  local dir marker found=false summary

  dir="$(codex_session_state_dir touched-repos "$session_id" 2>/dev/null || true)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  for marker in "$dir"/*; do
    [ -f "$marker" ] || continue
    summary="$(touched_repo_change_summary "$marker" || true)"
    [ -n "$summary" ] || continue
    printf '%s\n' "$summary"
    found=true
  done

  [ "$found" = "true" ]
}

format_gitleaks_findings() {
  local report="$1"

  jq -r '
    .[] |
    "\(.File // "<unknown>"):\((.StartLine // "?") | tostring) \(.RuleID // "unknown") \(.Description // "possible secret")"
  ' "$report" 2>/dev/null
}

run_gitleaks_command() {
  local report="$1"
  shift
  local out rc

  out=$("$@" 2>&1)
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      printf '%s\n' "$out" >"${report}.err"
      return 2
      ;;
  esac
}

run_secret_scan() {
  local repo="$1"
  local baseline="$2"
  local proof_dir="$3"
  local report findings worktree_report commit_report scan_dir
  local tmp_index base findings_count worktree_dirty commit_changed scan_rc errors=""
  local -a reports

  for findings in gitleaks-report.json gitleaks-findings.txt \
    gitleaks-worktree-report.json gitleaks-commit-report.json \
    gitleaks-worktree-report.json.err gitleaks-commit-report.json.err; do
    proof_remove_file "$findings" 2>/dev/null || return 2
  done
  scan_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-gitleaks.XXXXXX")" || return 2
  report="$scan_dir/gitleaks-report.json"
  findings="$scan_dir/gitleaks-findings.txt"
  worktree_report="$scan_dir/gitleaks-worktree-report.json"
  commit_report="$scan_dir/gitleaks-commit-report.json"

  if ! command -v gitleaks >/dev/null 2>&1; then
    printf '%s\n' "gitleaks not found on PATH" | proof_write_file gitleaks-findings.txt 600 || true
    rm -rf "$scan_dir"
    return 2
  fi

  worktree_dirty=false
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
    worktree_dirty=true
  fi

  commit_changed=false
  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null &&
      ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
      commit_changed=true
    fi
  fi

  if [ "$worktree_dirty" = "true" ]; then
    tmp_index=$(mktemp "$scan_dir/gitleaks-index.XXXXXX")
    rm -f "$tmp_index"
    if GIT_INDEX_FILE="$tmp_index" git -C "$repo" read-tree HEAD >/dev/null 2>&1; then
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" add -N -- . >/dev/null 2>&1 || true
      scan_rc=0
      GIT_INDEX_FILE="$tmp_index" run_gitleaks_command "$worktree_report" \
        gitleaks protect --source "$repo" --redact --no-banner --log-level error \
          --report-format json --report-path "$worktree_report" || scan_rc=$?
      case "$scan_rc" in
        0|1)
          [ -f "$worktree_report" ] || errors="$errors worktree"
          ;;
        *) errors="$errors worktree" ;;
      esac
    else
      printf '%s\n' "could not prepare temporary git index for worktree scan" >"${worktree_report}.err"
      errors="$errors worktree"
    fi
    rm -f "$tmp_index"
  fi

  if [ "$commit_changed" = "true" ]; then
    scan_rc=0
    run_gitleaks_command "$commit_report" \
      gitleaks detect --source "$repo" --log-opts "$base..HEAD" --redact --no-banner \
        --log-level error --report-format json --report-path "$commit_report" || scan_rc=$?
    case "$scan_rc" in
      0|1)
        [ -f "$commit_report" ] || errors="$errors commits"
        ;;
      *) errors="$errors commits" ;;
    esac
  fi

  reports=()
  [ -f "$worktree_report" ] && reports+=("$worktree_report")
  [ -f "$commit_report" ] && reports+=("$commit_report")
  if [ "${#reports[@]}" -gt 0 ]; then
    jq -s 'add' "${reports[@]}" >"$report" 2>/dev/null || cp "${reports[0]}" "$report"
  else
    printf '[]\n' >"$report"
  fi
  if ! cat "$report" | proof_write_file gitleaks-report.json 600; then
    rm -rf "$scan_dir"
    return 2
  fi

  if [ -n "$errors" ]; then
    {
      printf '%s\n' "gitleaks failed for:$errors"
      [ -s "${worktree_report}.err" ] && cat "${worktree_report}.err"
      [ -s "${commit_report}.err" ] && cat "${commit_report}.err"
    } | proof_write_file gitleaks-findings.txt 600 || true
    rm -rf "$scan_dir"
    return 2
  fi

  findings_count=$(jq 'length' "$report" 2>/dev/null || printf '0')
  if [ "${findings_count:-0}" -gt 0 ]; then
    format_gitleaks_findings "$report" | proof_write_file gitleaks-findings.txt 600 || true
    rm -rf "$scan_dir"
    return 1
  fi

  proof_remove_file gitleaks-findings.txt 2>/dev/null || true
  rm -rf "$scan_dir"
  return 0
}

canonical_existing_path() {
  local path="$1"
  local dir base canonical_dir

  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    canonical_dir="$( (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir" )"
    printf '%s/%s\n' "$canonical_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

git_common_dir() {
  local repo="$1"
  local common top

  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    canonical_existing_path "$common"
    return
  fi

  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  case "$common" in
    /*) canonical_existing_path "$common" ;;
    *) canonical_existing_path "${top:-$repo}/$common" ;;
  esac
}

repo_identity() {
  local repo="$1"
  local top common

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$repo")"
    top="$(canonical_existing_path "$top")"
    common="$(git_common_dir "$repo")"
    printf 'git:%s:%s\n' "$top" "$common"
  else
    printf 'nogit:%s\n' "$(codex_canonical_cwd "$repo")"
  fi
}

activity_marker_summary() {
  local session_id="$1"
  local cwd="$2"
  local marker name found=""

  for name in shell edit subagent; do
    marker=$(codex_existing_state_file activity "$name" "$session_id" "$cwd" 2>/dev/null || true)
    [ -n "$marker" ] && found="$found $name"
  done

  printf '%s\n' "$found"
}

transcript_has_activity_since_last_user() {
  local transcript="$1"

  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  jq -e -s '
    def response_item_type($e):
      $e.payload.type // $e.payload.item.type // "";
    def content_of($e):
      $e.message.content // $e.payload.message.content // $e.payload.item.content // $e.payload.content // "";
    def event_role($e):
      if $e.type == "user" then "user"
      elif $e.type == "assistant" then "assistant"
      elif $e.type == "response_item" then
        if response_item_type($e) == "function_call" then "assistant"
        elif response_item_type($e) == "function_call_output" then "tool_result"
        else ($e.payload.role // $e.payload.item.role // "") end
      elif $e.type == "message" then ($e.role // "")
      else "" end;
    def is_real_user($e):
      event_role($e) == "user"
      and ((content_of($e) | type) == "string")
      and ((content_of($e) | test("^[[:space:]]*<(hook_prompt|subagent_notification|turn_aborted)"; "i")) | not)
      and (($e.isMeta // $e.message.isMeta // false) | not);
    def call_records($e):
      if $e.type == "response_item" and response_item_type($e) == "function_call" then
        [{
          name: ($e.payload.name // $e.payload.item.name // ""),
          arguments: (($e.payload.arguments // $e.payload.item.arguments // "") | tostring)
        }]
      else
        (content_of($e) as $c
        | if ($c | type) == "array" then
          [$c[] | select(.type == "tool_use" or .type == "function_call")
            | {name: (.name // ""), arguments: ((.input // .arguments // "") | tostring)}]
        else [] end)
      end;
    def active_call($c):
      (($c.name // "") | test("(^|\\.)(apply_patch|Edit|Write|MultiEdit|spawn_agent|send_input|wait_agent|close_agent|resume_agent)$"))
      or
      (($c.name // "") == "multi_tool_use.parallel"
        and (($c.arguments // "") | test("functions\\.(apply_patch|spawn_agent|send_input|wait_agent|close_agent|resume_agent)")));
    . as $all
    | ([ $all | to_entries[] | select(is_real_user(.value)) | .key ] | last // -1) as $last_user
    | $last_user >= 0 and
      ([ $all | to_entries[]
        | select(.key > $last_user and event_role(.value) == "assistant")
        | call_records(.value)[]
        | select(active_call(.)) ] | length) > 0
  ' "$transcript" >/dev/null 2>&1
}

if codex_hook_is_subagent_context "$input"; then
  case "${CODEX_ROLE:-}" in
    lead|coordinator)
      json_continue
      exit 0
      ;;
  esac

  reminder="$proof_dir/subagent-commit-reminder.md"
  skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
  if [ -n "$skip" ]; then
    proof_remove_file "$(basename "$reminder")" 2>/dev/null || true
    json_continue
    exit 0
  fi

  subagent_change_summary="$(touched_repos_change_summary "$session_id" || true)"
  if [ -n "$subagent_change_summary" ]; then
    {
      cat <<EOF
# Subagent Commit Reminder

This subagent has dirty files in repos it modified.
Commit only owned completed dirty paths modified by this subagent. Do not commit unrelated dirty files.
If committing is unsafe, use the blocker-resolution-protocol skill for real blockers before reporting the blocker and affected paths to the orchestrator.

Bypass only when handoff with dirty work is intentional:
  CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on

Changed repos:
EOF
      printf '%s\n' "$subagent_change_summary" | indent_text
    } | proof_write_file "$(basename "$reminder")" 600 || {
      json_block "Unable to safely write the subagent commit reminder; remain blocked."
      exit 0
    }
    json_block "This subagent has dirty files it modified. Read $reminder; commit only owned completed dirty paths, report the blocker after blocker-resolution-protocol, or bypass intentional dirty handoff with CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on; then stop again."
    exit 0
  fi
  proof_remove_file "$(basename "$reminder")" 2>/dev/null || true
  json_continue
  exit 0
fi

repo="${cwd:-$PWD}"
side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)

if codex_side_stop_is_active_for_session "$side_stop" "$session_id"; then
  json_continue
  exit 0
fi

proof="$proof_dir/proof.md"
instructions="$proof_dir/instructions.md"
baseline="$proof_dir/baseline_head"
skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
eci_active="$proof_root_canonical/$session_id/eci_active"
legacy_eci_active="$(legacy_eci_markers_for_cwd_safe 2>/dev/null | head -n1 || true)"
ate_active=$(codex_existing_state_file ate ate_active "$session_id" "$cwd" 2>/dev/null || true)
task_active=$(codex_existing_state_file active-task task_active "$session_id" "$cwd" 2>/dev/null || true)
activity_summary="$(activity_marker_summary "$session_id" "$cwd")"
change_summary="$(git_change_summary "$repo" "$baseline" || true)"
changed=false
[ -n "$change_summary" ] && changed=true
transcript_activity=false
if transcript_has_activity_since_last_user "$transcript_path"; then
  transcript_activity=true
fi
repo_is_git=false
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_is_git=true
fi

proof_session_is_stable || {
  jq -n '{decision: "block", reason: "Configured proof session changed or became unavailable; remain blocked without writing session state."}'
  exit 0
}

proof_recovery_text() {
  printf ' Legacy proof files are optional. Update or remove %s using %s; if that file is missing, read %s.' \
    "$proof" "$instructions" "$HOME/.codex/hooks/stop-checklist.md"
}

block_proof_validation() {
  json_block "$1$(proof_recovery_text)"
  exit 0
}

if [ -n "$eci_active" ] && [ -f "$eci_active" ]; then
  json_block "ECI is active for this session. Never stop until the ECI task is complete. If work is not done, dispatch remaining work to subagents and use wait_agent; do not stop while they run. Continue the ECI task, update the session project-understanding ledger, or use blocker-resolution-protocol before reporting a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>." "$eci_active"
  exit 0
fi

if [ -n "$legacy_eci_active" ] && [ -f "$legacy_eci_active" ]; then
  json_block "ECI is active for this workspace via legacy marker $legacy_eci_active. Never stop until the ECI task is complete. Continue the ECI task, update the session project-understanding ledger, or use blocker-resolution-protocol before reporting a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>." "$legacy_eci_active"
  exit 0
fi

if [ -n "$skip" ] && [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ -n "$ate_active" ] && [ -f "$ate_active" ]; then
  ate_phase=$(codex_state_value "$ate_active" phase || true)
  case "$ate_phase" in
    awaiting_user|closed) ;;
    *)
      json_block "ATE is active for this session. Continue the agent team task, update the session project-understanding ledger, use blocker-resolution-protocol before reporting a real blocker, or close ATE before stopping."
      exit 0
      ;;
  esac
fi

# Early exit: if this session did no mutation work since the last user
# message and no persisted indicators exist, skip the stop gate regardless of
# pre-existing dirt from prior sessions.
if [ "$transcript_activity" != "true" ] &&
  [ ! -f "$proof" ] &&
  [ "$changed" != "true" ] &&
  [ -z "$task_active" ] &&
  [ -z "$activity_summary" ]; then
  json_continue
  exit 0
fi

reviewer_out=""
if reviewer_out=$(printf '%s' "$input" | "$HOOK_DIR/system-prompt-reviewer.sh"); then
  if [ -n "$reviewer_out" ] &&
    printf '%s' "$reviewer_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf '%s\n' "$reviewer_out"
    exit 0
  fi
fi

if [ -f "$proof" ]; then
  if codex_markdown_section_has_body "$proof" "ECI completion certificate"; then
    if ! codex_markdown_section_has_body "$proof" "Stop checklist walkthrough" || ! codex_markdown_section_has_body "$proof" "Incomplete compliance"; then
      block_proof_validation "ECI completion proof must include non-empty Stop checklist walkthrough and Incomplete compliance sections."
    fi

    marker_error="$(codex_eci_terminal_verdict_error "ECI completion proof" "$proof")"
    if [ -n "$marker_error" ]; then
      block_proof_validation "$marker_error"
    fi
  elif ! grep -qiE 'fast.exit|fast exit' "$proof"; then
    missing=""
    grep -qi '^##[[:space:]]*Summary' "$proof" || missing="$missing Summary"
    grep -qi '^##[[:space:]]*Verification' "$proof" || missing="$missing Verification"
    grep -qi '^##[[:space:]]*Requirements' "$proof" || missing="$missing Requirements"
    grep -qi '^##[[:space:]]*Root Cause' "$proof" || missing="$missing Root-Cause"
    grep -qi '^##[[:space:]]*Claim Inventory' "$proof" || missing="$missing Claim-Inventory"
    grep -qi '^##[[:space:]]*Pre-Mortem' "$proof" || missing="$missing Pre-Mortem"
    grep -qi '^##[[:space:]]*Adversarial Critique' "$proof" || missing="$missing Adversarial-Critique"
    grep -qi '^##[[:space:]]*Rule-Compliance Self-Audit' "$proof" || missing="$missing Rule-Compliance-Self-Audit"
    grep -qi '^##[[:space:]]*Gaps' "$proof" || missing="$missing Gaps"

    if [ -n "$missing" ]; then
      block_proof_validation "Proof file is missing required sections:$missing."
    fi

    audit_section=$(awk '
      /^##[[:space:]]*Rule-Compliance Self-Audit/ { in_audit=1; next }
      in_audit && /^##[[:space:]]/ { in_audit=0 }
      in_audit { print }
    ' "$proof")
    audit_hashes=$(mktemp "${TMPDIR:-/tmp}/codex-audit-hashes.XXXXXX")
    audit_errs=$(printf '%s\n' "$audit_section" | awk -v hashfile="$audit_hashes" '
      function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      function check_sources(raw, label,   body, n, i, item, nonempty, has_codex) {
        body = raw
        sub(/^[^:]*:[[:space:]]*/, "", body)
        n = split(body, parts, ",")
        nonempty = 0
        has_codex = 0
        for (i = 1; i <= n; i++) {
          item = trim(parts[i])
          if (item == "") {
            print label ": empty audit source"
          } else {
            nonempty++
          }
          if (item ~ /CODEX\.md/) has_codex = 1
        }
        if (nonempty < 3) print label ": need at least three non-empty sources"
        if (!has_codex) print label ": must include CODEX.md among the sources"
      }
      function finish_violation() {
        if (violation_count == 0) return
        if (!has_corr) print "violation #" violation_count ": no correction marker"
        if (blocker_seen && !blocker_input) print "violation #" violation_count ": blocker missing non-empty input"
        if (blocker_seen && !blocker_command) print "violation #" violation_count ": blocker missing non-empty command"
      }

      /^[[:space:]]*[Cc][Ll][Ee][Aa][Nn]-[Ss][Cc][Aa][Nn]:[[:space:]]*/ {
        clean_count++
        check_sources($0, "clean-scan")
        next
      }

      /^[[:space:]]*[-*]*[[:space:]]*[Vv]iolation:/ {
        finish_violation()
        violation_count++
        has_corr = 0
        blocker_seen = 0
        blocker_input = 0
        blocker_command = 0
        next
      }

      violation_count > 0 && /^[[:space:]]*commit:[[:space:]]*[0-9a-fA-F]{7,40}/ {
        has_corr = 1
        match($0, /[0-9a-fA-F]{7,40}/)
        print substr($0, RSTART, RLENGTH) > hashfile
        next
      }

      violation_count > 0 && /^[[:space:]]*```(edit|grep|restate)/ {
        has_corr = 1
        next
      }

      violation_count > 0 && /^[[:space:]]*blocker:[[:space:]]*$/ {
        has_corr = 1
        blocker_seen = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*input:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*input:[[:space:]]*/, "", value)
        if (trim(value) != "") blocker_input = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*command:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*command:[[:space:]]*/, "", value)
        value = trim(value)
        lower = tolower(value)
        if (value == "") {
          blocker_command = 0
        } else if (lower ~ /^(tbd|todo|later|fix later|figure out|placeholder|none|n\/a|\.\.\.|<.*>)$/) {
          print "violation #" violation_count ": blocker command is a placeholder"
        } else {
          blocker_command = 1
        }
        next
      }

      END {
        finish_violation()
        if (clean_count == 0 && violation_count == 0) print "empty audit: provide clean-scan: or Violation:"
        if (clean_count > 0 && violation_count > 0) print "mutual-exclusion: use clean-scan or Violation:, not both"
      }
    ')

    if [ -n "$audit_errs" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit grammar failure: $audit_errs"
    fi

    bad_commits=""
    if [ -s "$audit_hashes" ]; then
      while IFS= read -r audit_hash; do
        if [ "$repo_is_git" != "true" ] ||
          ! git -C "$repo" cat-file -e "${audit_hash}^{commit}" 2>/dev/null ||
          ! git -C "$repo" merge-base --is-ancestor "$audit_hash" HEAD 2>/dev/null; then
          bad_commits="$bad_commits $audit_hash"
        fi
      done <"$audit_hashes"
    fi
    if [ -n "$bad_commits" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit has unreachable audit commit(s):$bad_commits."
    fi

    audit_sha=$(printf '%s' "$audit_section" | sha256sum | awk '{print $1}')
    cur_head=""
    workdir_dirty=0
    if [ "$repo_is_git" = "true" ]; then
      cur_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
      if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
        workdir_dirty=1
      fi
    fi

    history_identity="$(repo_identity "$repo")"
    history_key="$(codex_hash_string "$history_identity")"
    if ! printf '%s\n' "$history_identity" | proof_write_history_file "$history_key" repo_identity; then
      block_proof_validation "Unable to safely write repository history state."
    fi
    last_line=""
    history_read_status=0
    last_line="$(proof_read_history_last_line "$history_key" "$session_id.log" 2>/dev/null)" || history_read_status=$?
    if [ "$history_read_status" -eq 2 ]; then
      block_proof_validation "Unable to safely read repository history state."
    fi
    if [ "$history_read_status" -eq 0 ] && [ -n "$last_line" ]; then
      prev_sha=$(printf '%s' "$last_line" | cut -d'|' -f1)
      prev_head=$(printf '%s' "$last_line" | cut -d'|' -f2)

      if [ "$audit_sha" = "$prev_sha" ]; then
        if [ "$workdir_dirty" = "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: identical audit plus dirty tree."
        fi
        if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: HEAD advance from $prev_head to $cur_head with a byte-identical audit."
        fi

        rescan_ok=$(printf '%s\n' "$audit_section" | awk '
          function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
          }
          /^[[:space:]]*[Rr]escanned:[[:space:]]*/ {
            body = $0
            sub(/^[^:]*:[[:space:]]*/, "", body)
            n = split(body, parts, ",")
            nonempty = 0
            has_codex = 0
            empty = 0
            for (i = 1; i <= n; i++) {
              item = trim(parts[i])
              if (item == "") empty = 1
              else nonempty++
              if (item ~ /CODEX\.md/) has_codex = 1
            }
            if (nonempty >= 3 && has_codex && !empty) ok = 1
          }
          END { print ok ? 1 : 0 }
        ')
        if [ "$rescan_ok" != "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: missing/invalid rescanned: for byte-identical audit on unchanged repo."
        fi
      fi

      if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ] && [ -s "$audit_hashes" ]; then
        range_ok=0
        while IFS= read -r audit_hash; do
          if [ "$audit_hash" != "$prev_head" ] &&
            git -C "$repo" merge-base --is-ancestor "$prev_head" "$audit_hash" 2>/dev/null &&
            git -C "$repo" merge-base --is-ancestor "$audit_hash" "$cur_head" 2>/dev/null; then
            range_ok=1
            break
          fi
        done <"$audit_hashes"
        if [ "$range_ok" = "0" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: old-only commit range after HEAD movement."
        fi
      fi
    fi

    if ! printf '%s|%s|%s\n' "$audit_sha" "$cur_head" "$(date -u +%s)" |
      proof_write_history_file "$history_key" "$session_id.log"; then
      block_proof_validation "Unable to safely write repository history state."
    fi
    rm -f "$audit_hashes"
  fi

  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  proof_remove_file proof.md 2>/dev/null || true
  proof_remove_file instructions.md 2>/dev/null || true
  proof_remove_file baseline_head 2>/dev/null || true
  dirty_summary="$(git_dirty_summary "$repo" || true)"
  if [ -n "$dirty_summary" ]; then
    git_status_at_accept="$proof_dir/git-status-at-accept.txt"
    printf '%s\n' "$dirty_summary" | proof_write_file git-status-at-accept.txt 600 || {
      json_block "Unable to safely write the accepted git-status snapshot; remain blocked."
      exit 0
    }
    json_block "Verification proof accepted (legacy path), but git state is still dirty. Read $git_status_at_accept, relay the relevant result to the user, commit owned completed changes or state unrelated blockers, then stop."
  else
    json_block "Verification proof accepted (legacy path). Relay the relevant result to the user, then stop."
  fi
  exit 0
fi

if [ "$stop_active" = "true" ]; then
  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  proof_remove_file instructions.md 2>/dev/null || true
  proof_remove_file baseline_head 2>/dev/null || true
  json_continue
  exit 0
fi

if [ "$changed" != "true" ]; then
  head_summary="$(git_head_summary "$repo")"
  [ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
  activity_display="${activity_summary# }"
  [ -n "$activity_display" ] || activity_display="none"
  if ! {
    cat <<EOF
# Stop Checklist Review

Automated checks already run by stop-gate:
- Git state: clean. No changed git state was detected.
- HEAD: $head_summary
- Activity markers: $activity_display

Do not rerun automated git checks unless investigating a reported failure.

Manual checks remaining:
1. Verify the applicable non-automated stop-checklist items.
2. If ECI or ATE was used, verify the session project-understanding ledger was updated.
3. If any item failed, fix it before stopping.
EOF
  } | proof_write_file instructions.md 600; then
    jq -n '{decision: "block", reason: "Unable to safely write the stop checklist; remain blocked."}'
    exit 0
  fi

  json_block "Automated stop checks passed. Follow $instructions for remaining manual checks, then stop again."
  exit 0
fi

head_summary="$(git_head_summary "$repo")"
[ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
dirty_summary="$(git_dirty_summary "$repo" || true)"
[ -n "$dirty_summary" ] || dirty_summary="clean"
secret_scan_rc=0
run_secret_scan "$repo" "$baseline" "$proof_dir" || secret_scan_rc=$?
case "$secret_scan_rc" in
  0) secret_scan_status="passed (gitleaks)" ;;
  1)
    json_block "Automated secret scan found possible secrets. Read $proof_dir/gitleaks-findings.txt, remove or explicitly remediate them, then stop again."
    exit 0
    ;;
  *)
    json_block "Automated secret scan could not complete. Read $proof_dir/gitleaks-findings.txt, fix the scanner failure, then stop again."
    exit 0
    ;;
esac
{
  cat <<EOF
# Automated Stop Checks

Automated checks already run by stop-gate:
- Git changes since the session baseline: present.
- Dirty worktree: $dirty_summary
- HEAD: $head_summary
- Secret scan: $secret_scan_status
- Change summary:
EOF
  printf '%s\n' "$change_summary" | indent_text
  cat <<'EOF'

Do not rerun automated git checks unless investigating a reported failure.

EOF
  cat "$HOME/.codex/hooks/stop-verification.md"
} | proof_write_file instructions.md 600 || {
  jq -n '{decision: "block", reason: "Unable to safely write automated stop instructions; remain blocked."}'
  exit 0
}

json_block "Automated stop checks found changed git state. Follow $instructions for remaining verification, then stop again."
