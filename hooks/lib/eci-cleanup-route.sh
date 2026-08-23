#!/usr/bin/env bash

# Shared coordinator cleanup capability parser.  This is intentionally kept
# provider-neutral and hard-linked into the Codex and Kimi hook trees.  The
# caller must have completed the compiled plan; this route adds only the live
# provider-home, temporary-root, and inode checks that the planner cannot do.
ECI_SHARED_CLEANUP_ROUTE_DETAIL=""
eci_shared_cleanup_route() {
  [ "${hook_is_subagent:-false}" != true ] || return 1
  local detail
  detail="$(python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

command = sys.argv[1]
def reject(reason):
    print("coordinator-cleanup-route command=" + command + " reason=" + reason)
    raise SystemExit(1)

if any(mark in command for mark in ("\n", "\r", "$", "`", "'", '"')):
    reject("literal cleanup command contains quoting, substitution, or newlines")
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    reject("shell quoting is unbalanced")
temporary_unqualified_file_remove = False
if tokens and tokens[0] == "mv":
    if len(tokens) != 4 or tokens[1] != "--":
        reject("expected exactly mv -- <approved-artifact> <quarantine-destination>")
    mode = "mv"
    paths = tokens[2:]
elif len(tokens) >= 3 and tokens[0] == "rm" and tokens[1] == "-f":
    mode = "-f"
    if tokens[2] == "--":
        paths = tokens[3:]
    else:
        paths = tokens[2:]
        temporary_unqualified_file_remove = True
    if len(paths) > 64:
        reject("cleanup target list exceeds the 64-path bound")
    if len(paths) != len(set(paths)):
        reject("cleanup target list contains duplicate paths")
elif len(tokens) >= 4 and tokens[0] == "rm" and tokens[2] == "--":
    mode = tokens[1]
    if mode not in {"-f", "-rf"}:
        reject("rm option must be exactly -f for files or -rf for directories")
    paths = tokens[3:]
    if len(paths) > 64:
        reject("cleanup target list exceeds the 64-path bound")
    if len(paths) != len(set(paths)):
        reject("cleanup target list contains duplicate paths")
else:
    reject("expected rm -f -- <files>, rm -rf -- <directories>, or mv -- <artifact> <quarantine-destination>")
if not paths:
    reject("cleanup target list is empty")

if temporary_unqualified_file_remove:
    temporary_roots = set()
    home = os.environ.get("HOME", "")
    canonical_home = os.path.realpath(home) if home else ""
    def canonical_directory(raw):
        if (not raw or not os.path.isabs(raw) or
                os.path.normpath(raw) != raw):
            return ""
        canonical = os.path.realpath(raw)
        if (not os.path.isabs(canonical) or
                os.path.normpath(canonical) != canonical or
                not os.path.isdir(canonical) or os.path.islink(canonical) or
                os.path.realpath(canonical) != canonical):
            return ""
        if canonical == "/tmp" or canonical.startswith("/tmp/"):
            return ""
        home_scoped = bool(canonical_home and
                           (canonical == canonical_home or
                            canonical.startswith(canonical_home + os.sep)))
        if os.path.islink(raw) and not home_scoped:
            return ""
        return canonical

    for raw in (
            os.environ.get("CODEX_TMPDIR", ""),
            os.environ.get("TMPDIR", ""),
            os.path.join(home, "tmp") if home else "",
    ):
        canonical = canonical_directory(raw)
        if canonical:
            temporary_roots.add(canonical)
    if not temporary_roots:
        reject("no canonical temporary directory is available")
    for path in paths:
        if not os.path.isabs(path) or os.path.normpath(path) != path:
            reject("path=" + path + " reason=temporary cleanup requires canonical absolute paths")
        parent = os.path.dirname(path)
        canonical_parent = os.path.realpath(parent)
        if canonical_parent not in temporary_roots:
            reject("path=" + path + " reason=unqualified rm -f is limited to canonical temporary roots")
        if os.path.islink(path):
            reject("path=" + path + " reason=symlink targets are not cleanup-eligible")
        if os.path.lexists(path) and (not os.path.isfile(path) or os.path.realpath(path) != path):
            reject("path=" + path + " reason=temporary cleanup requires a canonical regular file")
        ancestor = parent
        while not os.path.lexists(ancestor) and ancestor != os.path.dirname(ancestor):
            ancestor = os.path.dirname(ancestor)
        canonical_ancestor = os.path.realpath(ancestor)
        if not any(canonical_ancestor == root or canonical_ancestor.startswith(root + os.sep)
                   for root in temporary_roots):
            reject("path=" + path + " reason=temporary cleanup parent escapes canonical temporary roots")
    print("ok")
    raise SystemExit(0)

home = os.environ.get("HOME", "")
homes = []
for value, fallback in (
    (os.environ.get("CODEX_HOME", ""), os.path.join(home, ".codex")),
    (os.environ.get("KIMI_CODE_HOME", ""), os.path.join(home, ".kimi-code")),
):
    root = value or fallback
    if not root or not os.path.isabs(root) or os.path.normpath(root) != root:
        continue
    if not os.path.isdir(root) or os.path.islink(root):
        continue
    canonical_root = os.path.realpath(root)
    if (not os.path.isabs(canonical_root) or
            os.path.normpath(canonical_root) != canonical_root or
            not os.path.isdir(canonical_root) or os.path.islink(canonical_root) or
            os.path.realpath(canonical_root) != canonical_root):
        continue
    if canonical_root != root:
        canonical_home = os.path.realpath(home) if home else ""
        if (not home or not os.path.isabs(home) or os.path.normpath(home) != home or
                not os.path.isdir(home) or os.path.islink(home) or
                not canonical_home or os.path.realpath(canonical_home) != canonical_home or
                os.path.dirname(root) != home or
                os.path.realpath(os.path.dirname(root)) != canonical_home):
            continue
    homes.append((root, canonical_root))
if not homes:
    reject("no canonical Codex or Kimi home is available")

root_files = {"config-new.toml", "migrations-effort.json"}
root_dirs = {"cron", "search-index", "workspace-trust", "bin/__pycache__", "bin/tests/__pycache__", "hooks/tests/__pycache__"}
runner_file = re.compile(r"^\.codex-runner-test\.[A-Za-z0-9._-]+$")
def approved_path(path):
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        return None, "target path must be canonical absolute"
    for root, canonical_root in homes:
        if path == root or path.startswith(root + os.sep):
            canonical_path = os.path.realpath(path)
            if (canonical_path != canonical_root and
                    not canonical_path.startswith(canonical_root + os.sep)):
                return root, "resolved target escapes canonical provider home"
            relative = os.path.relpath(canonical_path, canonical_root)
            if relative in root_files or relative == "bin/codex-pending-couriers":
                return root, "file"
            if relative in root_dirs:
                return root, "directory"
            if os.path.dirname(relative) in ("", ".") and runner_file.fullmatch(os.path.basename(relative)):
                if os.path.isdir(path):
                    return root, "directory"
                if os.path.isfile(path):
                    return root, "file"
                return root, "unapproved generated path"
            return root, "unapproved generated path"
    return None, "target is outside canonical Codex/Kimi homes"

if mode == "mv":
    source, destination = paths
    root, kind = approved_path(source)
    if root is None:
        reject("path=" + source + " reason=" + kind)
    if kind == "unapproved generated path":
        reject("path=" + source + " reason=path is not an approved generated artifact")
    if os.path.islink(source):
        reject("path=" + source + " reason=symlink targets are not cleanup-eligible")
    if (kind == "file" and (not os.path.isfile(source) or os.path.islink(source))) or (kind == "directory" and (not os.path.isdir(source) or os.path.islink(source))):
        reject("path=" + source + " reason=approved artifact is missing or not canonical")
    configured_tmpdir = os.environ.get("TMPDIR") or os.path.join(home, "tmp")
    if not os.path.isabs(configured_tmpdir) or os.path.normpath(configured_tmpdir) != configured_tmpdir:
        reject("configured TMPDIR must be an absolute normalized path")
    real_tmpdir = os.path.realpath(configured_tmpdir)
    if not os.path.isabs(real_tmpdir) or os.path.normpath(real_tmpdir) != real_tmpdir or not os.path.isdir(real_tmpdir) or os.path.islink(real_tmpdir) or os.path.realpath(real_tmpdir) != real_tmpdir:
        reject("configured TMPDIR does not resolve to a canonical directory")
    canonical_home = os.path.realpath(home) if home else ""
    home_scoped_tmp = bool(canonical_home and
                           (real_tmpdir == canonical_home or
                            real_tmpdir.startswith(canonical_home + os.sep)))
    if os.path.islink(configured_tmpdir) and not home_scoped_tmp:
        reject("configured TMPDIR symlink must resolve within the home-scoped temporary tree")
    if real_tmpdir == "/tmp" or real_tmpdir.startswith("/tmp/"):
        reject("configured TMPDIR must resolve to a non-system temporary directory")
    temporary_roots = {real_tmpdir}
    destination_parent = os.path.dirname(destination)
    allowed_temp_roots = ",".join(sorted(temporary_roots))
    destination_parent_real = os.path.realpath(destination_parent)
    if (not os.path.isabs(destination) or os.path.normpath(destination) != destination or
            os.path.islink(destination_parent) or destination_parent_real not in temporary_roots):
        reject("destination must be a direct child of the canonical non-system TMPDIR or home-scoped temporary root; configured_tmpdir=" + configured_tmpdir + "; real_tmpdir=" + real_tmpdir + "; destination_parent=" + destination_parent + "; allowed_temp_roots=" + allowed_temp_roots)
    if not re.fullmatch(r"eci-generated-cleanup-[A-Za-z0-9._-]+", os.path.basename(destination)):
        reject("destination basename must match eci-generated-cleanup-<literal-safe-name>")
    if os.path.lexists(destination):
        reject("destination must not already exist")
else:
  for path in paths:
    root, kind = approved_path(path)
    if root is None:
        reject("path=" + path + " reason=" + kind)
    if kind == "unapproved generated path":
        reject("path=" + path + " reason=path is not an approved generated artifact")
    if os.path.islink(path):
        reject("path=" + path + " reason=symlink targets are not cleanup-eligible")
    if mode == "-f":
        if kind != "file":
            reject("path=" + path + " reason=-f requires an approved regular file")
        if not os.path.isfile(path) or os.path.islink(path):
            reject("path=" + path + " reason=approved file is missing or not a canonical regular file")
    else:
        if kind != "directory":
            reject("path=" + path + " reason=-rf requires an approved generated directory")
        if not os.path.isdir(path) or os.path.islink(path):
            reject("path=" + path + " reason=approved directory is missing or not canonical")
print("ok")
PY
  )" && {
    ECI_SHARED_CLEANUP_ROUTE_DETAIL=""
    return 0
  }
  ECI_SHARED_CLEANUP_ROUTE_DETAIL="${detail:-coordinator-cleanup-route reason=command is outside the bounded cleanup grammar}"
  return 1
}
