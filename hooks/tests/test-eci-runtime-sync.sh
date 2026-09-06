#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_ROOT="${HOME:?HOME must be set}"
TMP_BASE="$(realpath -e -- "$HOME_ROOT/tmp")"
case "$TMP_BASE" in
  /) printf 'runtime-sync test: unusable temporary root: %s\n' "$TMP_BASE" >&2; exit 1 ;;
esac
TEST_ROOT="$(mktemp -d "$TMP_BASE/eci-runtime-sync-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

make_provider_tree() {
  local root="$1"
  mkdir -p -- "$root/tmp" "$root/.codex/bin" "$root/.codex/hooks/lib" "$root/runtime/.codex/bin" "$root/runtime/.codex/hooks/lib"
  printf '{"provider":"codex"}\n' >"$root/.codex/hooks.json"
  printf '#!/usr/bin/env bash\nprintf canonical-active\\n' >"$root/.codex/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf canonical-dispatch\\n' >"$root/.codex/bin/eci-active-dispatch"
  printf '#!/usr/bin/env bash\nprintf canonical-runtime-sync\\n' >"$root/.codex/bin/eci-runtime-sync"
  printf '#!/usr/bin/env bash\nprintf canonical-validator\\n' >"$root/.codex/hooks/validate-bash.sh"
  printf 'nested canonical helper\n' >"$root/.codex/hooks/lib/nested.sh"
  chmod 775 "$root/.codex/bin/eci-active" "$root/.codex/bin/eci-active-dispatch" "$root/.codex/bin/eci-runtime-sync" "$root/.codex/hooks/validate-bash.sh"
  chmod 664 "$root/.codex/hooks.json" "$root/.codex/hooks/lib/nested.sh"
  printf 'stale\n' >"$root/runtime/.codex/hooks.json"
  printf '#!/usr/bin/env bash\nprintf stale-active\\n' >"$root/runtime/.codex/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf stale-dispatch\\n' >"$root/runtime/.codex/bin/eci-active-dispatch"
  printf '#!/usr/bin/env bash\nprintf stale-runtime-sync\\n' >"$root/runtime/.codex/bin/eci-runtime-sync"
  printf '#!/usr/bin/env bash\nprintf stale-validator\\n' >"$root/runtime/.codex/hooks/validate-bash.sh"
  printf 'stale nested\n' >"$root/runtime/.codex/hooks/lib/nested.sh"
  chmod 600 "$root/runtime/.codex/hooks.json" "$root/runtime/.codex/hooks/lib/nested.sh"
  chmod 700 "$root/runtime/.codex/bin/eci-active" "$root/runtime/.codex/bin/eci-active-dispatch" "$root/runtime/.codex/bin/eci-runtime-sync" "$root/runtime/.codex/hooks/validate-bash.sh"
}

make_kimi_tree() {
  local root="$1"
  mkdir -p -- "$root/tmp" "$root/.kimi-code/bin" "$root/.kimi-code/hooks/lib" "$root/runtime/.kimi-code/bin" "$root/runtime/.kimi-code/hooks/lib"
  printf 'provider = "kimi"\n' >"$root/.kimi-code/config.toml"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-active\\n' >"$root/.kimi-code/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-dispatch\\n' >"$root/.kimi-code/bin/eci-active-dispatch"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-runtime-sync\\n' >"$root/.kimi-code/bin/eci-runtime-sync"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-validator\\n' >"$root/.kimi-code/hooks/validate-bash.sh"
  printf 'nested canonical kimi helper\n' >"$root/.kimi-code/hooks/lib/nested.sh"
  chmod 775 "$root/.kimi-code/bin/eci-active" "$root/.kimi-code/bin/eci-active-dispatch" "$root/.kimi-code/bin/eci-runtime-sync" "$root/.kimi-code/hooks/validate-bash.sh"
  chmod 664 "$root/.kimi-code/config.toml" "$root/.kimi-code/hooks/lib/nested.sh"
  printf stale >"$root/runtime/.kimi-code/config.toml"
  printf stale >"$root/runtime/.kimi-code/bin/eci-active"
  printf stale >"$root/runtime/.kimi-code/bin/eci-active-dispatch"
  printf stale >"$root/runtime/.kimi-code/bin/eci-runtime-sync"
  printf stale >"$root/runtime/.kimi-code/hooks/validate-bash.sh"
  printf stale >"$root/runtime/.kimi-code/hooks/lib/nested.sh"
  chmod 700 "$root/runtime/.kimi-code/bin/eci-active" "$root/runtime/.kimi-code/bin/eci-active-dispatch" "$root/runtime/.kimi-code/bin/eci-runtime-sync" "$root/runtime/.kimi-code/hooks/validate-bash.sh"
  chmod 600 "$root/runtime/.kimi-code/config.toml" "$root/runtime/.kimi-code/hooks/lib/nested.sh"
}

run_sync() {
  local provider="$1" source_root="$2" target_root="$3"
  run_sync_with_home "$provider" "$source_root" "$target_root" "$source_root"
}

run_sync_with_home() {
  local provider="$1" source_root="$2" target_root="$3" selected_home="$4"
  if [ "$provider" = codex ]; then
    HOME="$selected_home" CODEX_RUNTIME_ROOTS="$target_root/.codex" \
      bash -c '. "$1/hooks/lib/eci-runtime-sync.sh"; eci_runtime_sync_run codex "$2/.codex"' _ "$ROOT" "$source_root"
  else
    HOME="$selected_home" KIMI_CODE_HOME="$source_root/.kimi-code" KIMI_RUNTIME_ROOTS="$target_root/.kimi-code" \
      bash -c '. "$1/hooks/lib/eci-runtime-sync.sh"; eci_runtime_sync_run kimi "$2/.kimi-code"' _ "$ROOT" "$source_root"
  fi
}

make_provider_tree "$TEST_ROOT"
# A planner build keeps its private Go work below the source tree. This is an
# accidental collection race, not a security/integrity boundary: normal
# source must still sync while this known transient directory is omitted.
planner_source_dir="$TEST_ROOT/.codex/hooks/lib/eci-command-plan-go"
planner_transaction="$planner_source_dir/.eci-command-plan.txn.fixture"
mkdir -p -- "$planner_transaction"/{home,config,cache,tmp,gopath,gocache,gomodcache,source}
mkdir -p -- "$TEST_ROOT/runtime/.codex/hooks/lib/eci-command-plan-go"
chmod 700 -- "$planner_transaction" "$planner_transaction"/{home,config,cache,tmp,gopath,gocache,gomodcache,source}
printf 'package main\n' >"$planner_source_dir/main.go"
printf 'transient cache\n' >"$planner_transaction/gocache/cache-entry"
printf 'package main\n' >"$planner_transaction/source/main.go"
safe_importer_transaction_temporary="$planner_transaction/.eci-safe-import.live-helper"
printf 'transient safe importer build\n' >"$safe_importer_transaction_temporary"
chmod 600 -- "$planner_transaction/gocache/cache-entry" "$planner_transaction/source/main.go"
planner_transaction_digest="$(sha256sum -- "$planner_transaction/gocache/cache-entry" | awk '{print $1}')"
# The safe importer must build beneath this already-pruned private planner
# transaction, never below its source directory where collection could race
# a partial binary into a runtime publication.
grep -Fq 'safe_importer_build_local "$source_root" "$transaction"' "$ROOT/bin/eci-runtime-sync"
grep -Fq 'mktemp "$transaction/.eci-safe-import.XXXXXX"' "$ROOT/bin/eci-runtime-sync"
run_sync codex "$TEST_ROOT" "$TEST_ROOT/runtime"
cmp "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/runtime/.codex/hooks.json"
cmp "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/runtime/.codex/bin/eci-active"
cmp "$TEST_ROOT/.codex/bin/eci-active-dispatch" "$TEST_ROOT/runtime/.codex/bin/eci-active-dispatch"
cmp "$TEST_ROOT/.codex/bin/eci-runtime-sync" "$TEST_ROOT/runtime/.codex/bin/eci-runtime-sync"
cmp "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/runtime/.codex/hooks/validate-bash.sh"
cmp "$TEST_ROOT/.codex/hooks/lib/nested.sh" "$TEST_ROOT/runtime/.codex/hooks/lib/nested.sh"
cmp "$planner_source_dir/main.go" "$TEST_ROOT/runtime/.codex/hooks/lib/eci-command-plan-go/main.go"
[ -d "$planner_transaction" ]
[ "$(sha256sum -- "$planner_transaction/gocache/cache-entry" | awk '{print $1}')" = "$planner_transaction_digest" ]
[ ! -e "$TEST_ROOT/runtime/.codex/hooks/lib/eci-command-plan-go/.eci-command-plan.txn.fixture" ]
[ -f "$safe_importer_transaction_temporary" ]
[ ! -e "$TEST_ROOT/runtime/.codex/hooks/lib/eci-command-plan-go/.eci-command-plan.txn.fixture/.eci-safe-import.live-helper" ]
if grep -Fq 'hooks/lib/eci-command-plan-go/.eci-command-plan.txn.fixture/' "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest"; then
  printf 'runtime-sync test: planner transaction leaked into the manifest\n' >&2
  exit 1
fi
[ -f "$TEST_ROOT/.codex/.eci-runtime-sync-manifest" ]
grep -q $'^bin/eci-active\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/.codex/.eci-runtime-sync-manifest"
grep -q $'^bin/eci-active-dispatch\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/.codex/.eci-runtime-sync-manifest"
grep -q $'^bin/eci-runtime-sync\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/.codex/.eci-runtime-sync-manifest"
[ "$(stat -c '%a' "$TEST_ROOT/.codex/hooks.json")" = "$(stat -c '%a' "$TEST_ROOT/runtime/.codex/hooks.json")" ]
[ -f "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest" ]
# Runtime receipts describe the last publication; a stale non-file receipt
# must not turn a normal source-to-target repair into a denial. Keep the
# unreplaceable metadata in place, but still publish managed runtime files.
rm -- "$TEST_ROOT/.codex/.eci-runtime-sync-manifest" "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest"
mkdir -- "$TEST_ROOT/.codex/.eci-runtime-sync-manifest" "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest"
printf '#!/usr/bin/env bash\nprintf repaired-active\\n' >"$TEST_ROOT/.codex/bin/eci-active"
chmod 775 -- "$TEST_ROOT/.codex/bin/eci-active"
run_sync codex "$TEST_ROOT" "$TEST_ROOT/runtime"
cmp "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/runtime/.codex/bin/eci-active"
[ -d "$TEST_ROOT/.codex/.eci-runtime-sync-manifest" ]
[ -d "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest" ]
# A deployed runtime may be incomplete precisely because a previous
# synchronization was interrupted.  Its missing managed leaf must be
# restored from the complete source rather than preventing self-repair.
rm -- "$TEST_ROOT/runtime/.codex/bin/eci-active-dispatch"
run_sync codex "$TEST_ROOT" "$TEST_ROOT/runtime"
cmp "$TEST_ROOT/.codex/bin/eci-active-dispatch" "$TEST_ROOT/runtime/.codex/bin/eci-active-dispatch"
[ -d "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest" ]

# A configured provider root may be a mount or symlink spelling. Synchronize
# the resolved provider directory rather than rejecting an otherwise correct
# declared target.
symlink_target_parent="$TEST_ROOT/symlink-target"
mkdir -p -- "$symlink_target_parent"
ln -s -- "$TEST_ROOT/runtime/.codex" "$symlink_target_parent/.codex"
run_sync codex "$TEST_ROOT" "$symlink_target_parent"
[ -L "$symlink_target_parent/.codex" ]
[ "$(readlink -- "$symlink_target_parent/.codex")" = "$TEST_ROOT/runtime/.codex" ]
cmp "$TEST_ROOT/.codex/bin/eci-runtime-sync" "$TEST_ROOT/runtime/.codex/bin/eci-runtime-sync"

home_alias="$TEST_ROOT/home-alias"
ln -s -- "$TEST_ROOT" "$home_alias"
# `$HOME/.codex` remains the selected source with a parent alias. The helper
# receives the source directory physically from eci-active, so it must bind
# it to the resolved HOME authority rather than compare physical and lexical
# strings directly.
run_sync_with_home codex "$TEST_ROOT" "$TEST_ROOT/runtime" "$home_alias"

# A user may intentionally point HOME/tmp at the system temporary directory.
# That affects only staging location, not the resolved Codex source or the
# declared runtime target, so synchronization must create and clean a private
# transaction there instead of treating the alias as an admission failure.
rmdir -- "$TEST_ROOT/tmp"
ln -s -- /tmp "$TEST_ROOT/tmp"
run_sync codex "$TEST_ROOT" "$TEST_ROOT/runtime"
[ -L "$TEST_ROOT/tmp" ]
[ "$(readlink -- "$TEST_ROOT/tmp")" = /tmp ]
if find "$TEST_ROOT/runtime/.codex" -maxdepth 1 -name '.eci-runtime-sync.*' -print -quit | grep -q .; then
  printf 'runtime-sync test: transaction directory leaked after success\n' >&2
  exit 1
fi

# A source edit after a file has entered the staging tree belongs to the next
# sync. The published target and both descriptive receipts must describe the
# staged snapshot, rather than combining old staged bytes with a new live
# source digest and failing midway through publication.
race_root="$TEST_ROOT/snapshot-race"
race_source="$race_root/.codex/hooks/lib/nested.sh"
race_target="$race_root/runtime/.codex/hooks/lib/nested.sh"
race_fake_bin="$race_root/fake-bin"
race_sentinel="$race_root/source-changed-after-stage"
race_output="$race_root/snapshot-race-output"
make_provider_tree "$race_root"
race_staged_hash="$(sha256sum -- "$race_source" | awk '{print $1}')"
mkdir -- "$race_fake_bin"
cat >"$race_fake_bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source_arg=''
after_separator=false
for argument in "$@"; do
  if [ "$after_separator" = true ]; then
    source_arg="$argument"
    break
  fi
  [ "$argument" = -- ] && after_separator=true
done

/usr/bin/install "$@"
if [ "$source_arg" = "${ECI_RUNTIME_SYNC_RACE_SOURCE:-}" ] &&
  [ ! -e "${ECI_RUNTIME_SYNC_RACE_SENTINEL:-}" ]; then
  : >"$ECI_RUNTIME_SYNC_RACE_SENTINEL"
  printf '%s\n' 'nested source changed after staged copy' >"$ECI_RUNTIME_SYNC_RACE_SOURCE"
fi
EOF
chmod 755 -- "$race_fake_bin/install"
PATH="$race_fake_bin:$PATH" \
  ECI_RUNTIME_SYNC_RACE_SOURCE="$race_source" \
  ECI_RUNTIME_SYNC_RACE_SENTINEL="$race_sentinel" \
  HOME="$race_root" CODEX_RUNTIME_ROOTS="$race_root/runtime/.codex" \
  bash -c '. "$1/hooks/lib/eci-runtime-sync.sh"; eci_runtime_sync_run codex "$2/.codex"' _ "$ROOT" "$race_root" >"$race_output" 2>&1
[ -f "$race_sentinel" ]
grep -qx 'nested source changed after staged copy' "$race_source"
grep -qx 'nested canonical helper' "$race_target"
grep -Fq 'ECI runtime maintenance advisory: source changed after staging; published snapshot remains current until the next sync:' "$race_output"
for race_receipt in "$race_root/.codex/.eci-runtime-sync-manifest" "$race_root/runtime/.codex/.eci-runtime-sync-manifest"; do
  [ "$(awk -F '\t' '$1 == "hooks/lib/nested.sh" { print $2 }' "$race_receipt")" = "$race_staged_hash" ]
done
[ "$(sha256sum -- "$race_target" | awk '{print $1}')" = "$race_staged_hash" ]
# The following ordinary sync picks up the later source edit; it is not lost
# or treated as a permanent mismatch.
run_sync codex "$race_root" "$race_root/runtime"
cmp -- "$race_source" "$race_target"

make_kimi_tree "$TEST_ROOT/kimi"
run_sync kimi "$TEST_ROOT/kimi" "$TEST_ROOT/kimi/runtime"
cmp "$TEST_ROOT/kimi/.kimi-code/config.toml" "$TEST_ROOT/kimi/runtime/.kimi-code/config.toml"
cmp "$TEST_ROOT/kimi/.kimi-code/bin/eci-active" "$TEST_ROOT/kimi/runtime/.kimi-code/bin/eci-active"
cmp "$TEST_ROOT/kimi/.kimi-code/bin/eci-active-dispatch" "$TEST_ROOT/kimi/runtime/.kimi-code/bin/eci-active-dispatch"
cmp "$TEST_ROOT/kimi/.kimi-code/bin/eci-runtime-sync" "$TEST_ROOT/kimi/runtime/.kimi-code/bin/eci-runtime-sync"
cmp "$TEST_ROOT/kimi/.kimi-code/hooks/validate-bash.sh" "$TEST_ROOT/kimi/runtime/.kimi-code/hooks/validate-bash.sh"
cmp "$TEST_ROOT/kimi/.kimi-code/hooks/lib/nested.sh" "$TEST_ROOT/kimi/runtime/.kimi-code/hooks/lib/nested.sh"
[ -f "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest" ]
grep -q $'^bin/eci-active\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest"
grep -q $'^bin/eci-active-dispatch\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest"
grep -q $'^bin/eci-runtime-sync\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest"
[ -f "$TEST_ROOT/kimi/runtime/.kimi-code/.eci-runtime-sync-manifest" ]
# The standalone peer route must also treat its receipt as status, not as a
# prerequisite for copying the selected runtime surface.  peer-apply is
# codex-launcher-only by contract: the bin derives the provider from its own
# install root and reserves peer sync for the canonical Codex home, so a
# Kimi-launcher copy must fail source resolution.  Exercise the route through
# a codex-launcher copy; invoking "$ROOT/bin/eci-runtime-sync" here only works
# when this test happens to run from the Codex tree.
peer_receipt="$TEST_ROOT/kimi/.kimi-code/.eci-codex-kimi-peer-sync-manifest"
mkdir -- "$peer_receipt"
peer_launcher_bin="$TEST_ROOT/peer-launcher/.codex/bin"
mkdir -p -- "$peer_launcher_bin"
cp -- "$ROOT/bin/eci-runtime-sync" "$peer_launcher_bin/eci-runtime-sync"
chmod 755 "$peer_launcher_bin/eci-runtime-sync"
HOME="$TEST_ROOT" "$peer_launcher_bin/eci-runtime-sync" peer-apply --target "$TEST_ROOT/kimi/.kimi-code"
[ -d "$peer_receipt" ]
cmp "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/kimi/.kimi-code/bin/eci-active"
[ ! -e "$TEST_ROOT/kimi/.kimi-code/hooks/lib/eci-command-plan-go/.eci-command-plan.txn.fixture" ]
# This inode assertion intentionally exercises the installed shared Kimi
# runtime, so this script remains deployment-dependent and is not registered
# as a source-only aggregate regression.
[ "$ROOT/hooks/lib/eci-runtime-sync.sh" -ef "/home/pheona/.kimi-code/hooks/lib/eci-runtime-sync.sh" ]

# The compiled planner is built from the Codex source and may be copied to a
# Kimi peer on another filesystem. Its dedicated route must rebuild the local
# binary, publish equivalent peer bytes when available, and preserve Kimi
# provider configuration.
planner_root="$TEST_ROOT/planner-pair"
planner_codex="$planner_root/.codex"
planner_kimi="$planner_root/.kimi-code"
planner_dir='hooks/lib/eci-command-plan-go'
safe_import_dir='hooks/lib/eci-safe-import-go'
mkdir -p -- "$planner_root/tmp" "$planner_codex/bin" "$planner_codex/$planner_dir" "$planner_kimi/$planner_dir" \
  "$planner_codex/$safe_import_dir" "$planner_kimi/$safe_import_dir"
cp -- "$ROOT/bin/eci-runtime-sync" "$planner_codex/bin/eci-runtime-sync"
for planner_source in go.mod classifier.go main.go; do
  cp -- "$ROOT/$planner_dir/$planner_source" "$planner_codex/$planner_dir/$planner_source"
done
# The Kimi tree carries only the peer-published safe-importer binary; its Go
# sources are built from the canonical Codex tree by design (the bin's
# safe_importer_build_local runs under the Codex source root).  When this
# test runs from the Kimi tree, stage the fixture sources from there.
safe_import_source_root="$ROOT"
if [ ! -f "$ROOT/$safe_import_dir/go.mod" ]; then
  safe_import_source_root="${HOME:?}/.codex"
fi
for safe_import_source in go.mod main.go; do
  cp -- "$safe_import_source_root/$safe_import_dir/$safe_import_source" "$planner_codex/$safe_import_dir/$safe_import_source"
done
printf '%s\n' 'provider = "preserve-kimi-config"' >"$planner_kimi/config.toml"
printf '%s\n' stale-codex >"$planner_codex/$planner_dir/eci-command-plan"
printf '%s\n' stale-kimi >"$planner_kimi/$planner_dir/eci-command-plan"
chmod 775 "$planner_codex/$planner_dir/eci-command-plan"
chmod 755 "$planner_kimi/$planner_dir/eci-command-plan"

# A historical commit accidentally captured a recursive planner binary below
# the planner source root. It is outside the selected build inputs, so normal
# maintenance must preserve it and still publish the current planner.
planner_stale_root="$planner_codex/$planner_dir/hooks"
planner_stale_dir="$planner_stale_root/lib/eci-command-plan-go"
planner_stale_binary="$planner_stale_dir/eci-command-plan"
planner_kimi_stale_root="$planner_kimi/$planner_dir/hooks"
planner_kimi_stale_dir="$planner_kimi_stale_root/lib/eci-command-plan-go"
planner_kimi_stale_binary="$planner_kimi_stale_dir/eci-command-plan"
planner_stale_blob="$TEST_ROOT/known-stale-planner"
# The historical residue commit predates the Kimi tree's own history; resolve
# whichever provider repository actually holds the object.
planner_stale_repo="$ROOT"
if ! git -C "$planner_stale_repo" cat-file -e "a1928cc:hooks/lib/eci-command-plan-go/hooks/lib/eci-command-plan-go/eci-command-plan" 2>/dev/null; then
  planner_stale_repo="${HOME:?}/.codex"
fi
git -C "$planner_stale_repo" show a1928cc:hooks/lib/eci-command-plan-go/hooks/lib/eci-command-plan-go/eci-command-plan >"$planner_stale_blob"
mkdir -p -- "$planner_stale_dir"
cp -- "$planner_stale_blob" "$planner_stale_binary"
chmod 755 "$planner_stale_binary"
mkdir -p -- "$planner_kimi_stale_dir"
cp -- "$planner_stale_blob" "$planner_kimi_stale_binary"
chmod 755 "$planner_kimi_stale_binary"
planner_kimi_config_digest="$(sha256sum -- "$planner_kimi/config.toml" | awk '{print $1}')"

planner_residue_state() {
  local root="$1" binary="$2" entries digest size mode

  entries="$(find -P "$root" -printf '%P\t%y\t%m\t%s\n' 2>/dev/null | LC_ALL=C sort)"
  if [ -L "$root" ]; then
    digest="symlink:$(readlink -- "$root")"
    size="$(stat -c '%s' -- "$root" 2>/dev/null || true)"
    mode="$(stat -c '%a' -- "$root" 2>/dev/null || true)"
  elif [ -f "$binary" ] && [ ! -L "$binary" ]; then
    digest="$(sha256sum -- "$binary" | awk '{print $1}')"
    size="$(stat -Lc '%s' -- "$binary")"
    mode="$(stat -Lc '%a' -- "$binary")"
  else
    digest=''
    size=''
    mode=''
  fi
  printf 'entries\n%s\ndigest=%s\nsize=%s\nmode=%s\n' "$entries" "$digest" "$size" "$mode"
}

planner_kimi_residue_state="$(planner_residue_state "$planner_kimi_stale_root" "$planner_kimi_stale_binary")"

assert_kimi_residue_unchanged() {
  [ "$(planner_residue_state "$planner_kimi_stale_root" "$planner_kimi_stale_binary")" = "$planner_kimi_residue_state" ] || {
    printf 'runtime-sync test: planner cleanup changed Kimi residue\n' >&2
    exit 1
  }
  cmp -- "$planner_stale_blob" "$planner_kimi_stale_binary"
}

# Ambient Go flags can be left over from an unrelated local build. The
# planner selects its own source and build options, so this fixture records if
# those ambient settings unexpectedly affect publication.
planner_ambient_root="$TEST_ROOT/planner-ambient"
planner_ambient_bin="$planner_ambient_root/bin"
planner_fake_go_marker="$planner_ambient_root/fake-go-invoked"
planner_toolexec_marker="$planner_ambient_root/toolexec-invoked"
planner_fake_go="$planner_ambient_bin/go"
planner_toolexec="$planner_ambient_root/toolexec"
planner_overlay="$planner_ambient_root/overlay.json"
planner_overlay_main="$planner_ambient_root/overlay-main.go"
mkdir -p -- "$planner_ambient_bin" "$planner_ambient_root/cache" "$planner_ambient_root/modcache"
printf '%s\n' 'package main' 'func main() {}' >"$planner_overlay_main"
printf '{"Replace":{"%s":"%s"}}\n' \
  "$planner_codex/$planner_dir/main.go" "$planner_overlay_main" >"$planner_overlay"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf %%s fake-go-invoked > %q\n' "$planner_fake_go_marker"
  printf '%s\n' 'exec /usr/lib/go-1.24/bin/go "$@"'
} >"$planner_fake_go"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf %%s toolexec-invoked > %q\n' "$planner_toolexec_marker"
  printf '%s\n' 'exec "$@"'
} >"$planner_toolexec"
chmod 755 "$planner_fake_go" "$planner_toolexec"

run_planner_sync() {
  HOME="$planner_root" KIMI_CODE_HOME="$planner_kimi" \
    "$planner_codex/bin/eci-runtime-sync" "$@" --target "$planner_kimi"
}

run_planner_sync_with_ambient_go_settings() {
  HOME="$planner_root" \
    PATH="$planner_ambient_bin:$PATH" \
    GOFLAGS="-overlay=$planner_overlay -toolexec=$planner_toolexec" \
    GOENV="$planner_ambient_root/go.env" \
    GOCACHE="$planner_ambient_root/cache" \
    GOMODCACHE="$planner_ambient_root/modcache" \
    GOPROXY='https://invalid.example' \
    KIMI_CODE_HOME="$planner_kimi" \
    "$planner_codex/bin/eci-runtime-sync" "$@" --target "$planner_kimi"
}

if run_planner_sync planner-check >/dev/null 2>&1; then
  printf 'runtime-sync test: split planner pair unexpectedly passed check\n' >&2
  exit 1
fi
run_planner_sync_with_ambient_go_settings planner-apply
[ -f "$planner_stale_binary" ]
cmp -- "$planner_stale_blob" "$planner_stale_binary"
assert_kimi_residue_unchanged
[ ! -e "$planner_fake_go_marker" ] || {
  printf 'runtime-sync test: planner-apply inherited caller PATH Go\n' >&2
  exit 1
}
[ ! -e "$planner_toolexec_marker" ] || {
  printf 'runtime-sync test: planner-apply inherited caller GOFLAGS toolexec\n' >&2
  exit 1
}
cmp -- "$planner_codex/$planner_dir/eci-command-plan" "$planner_kimi/$planner_dir/eci-command-plan"
[ "$(stat -c '%a' "$planner_codex/$planner_dir/eci-command-plan")" = 755 ]
[ -x "$planner_codex/$safe_import_dir/eci-safe-import" ]
[ -x "$planner_kimi/$safe_import_dir/eci-safe-import" ]
cmp -- "$planner_codex/$safe_import_dir/eci-safe-import" "$planner_kimi/$safe_import_dir/eci-safe-import"
grep -qx 'provider = "preserve-kimi-config"' "$planner_kimi/config.toml"
[ "$(sha256sum -- "$planner_kimi/config.toml" | awk '{print $1}')" = "$planner_kimi_config_digest" ]
[ -f "$planner_codex/$planner_dir/.eci-command-plan.provenance" ]
[ "$(stat -c '%a' "$planner_codex/$planner_dir/.eci-command-plan.provenance")" = 600 ]
# planner-apply publishes the path-free provenance receipt to both provider
# trees; the peer copy must be an owner-only content-identical record.
[ -f "$planner_kimi/$planner_dir/.eci-command-plan.provenance" ]
[ "$(stat -c '%a' "$planner_kimi/$planner_dir/.eci-command-plan.provenance")" = 600 ]
cmp -- "$planner_codex/$planner_dir/.eci-command-plan.provenance" "$planner_kimi/$planner_dir/.eci-command-plan.provenance"
run_planner_sync planner-check

# The installed/deployed copy is only a launcher.  Planner maintenance must
# select HOME/.codex as its source, rather than refusing to repair because the
# launcher itself lives under a mounted runtime copy.
planner_deployed_sync="$planner_root/runtime/.codex/bin/eci-runtime-sync"
mkdir -p -- "${planner_deployed_sync%/*}"
cp -- "$planner_codex/bin/eci-runtime-sync" "$planner_deployed_sync"
chmod 755 -- "$planner_deployed_sync"
HOME="$planner_root" KIMI_CODE_HOME="$planner_kimi" \
  "$planner_deployed_sync" planner-check --target "$planner_kimi"

# A declared Kimi target may use a mounted/symlinked spelling. Planner
# maintenance validates the resolved provider directory, not its spelling.
planner_target_alias_parent="$planner_root/planner-target-alias"
mkdir -p -- "$planner_target_alias_parent"
ln -s -- "$planner_kimi" "$planner_target_alias_parent/.kimi-code"
HOME="$planner_root" KIMI_CODE_HOME="$planner_kimi" \
  "$planner_codex/bin/eci-runtime-sync" planner-check --target "$planner_target_alias_parent/.kimi-code"

# A resolved directory with the wrong provider name remains a concrete target
# error and must be rejected before any build or publication begins.
planner_wrong_target="$planner_root/not-a-kimi-provider"
mkdir -p -- "$planner_wrong_target"
if HOME="$planner_root" KIMI_CODE_HOME="$planner_kimi" \
  "$planner_codex/bin/eci-runtime-sync" planner-apply --target "$planner_wrong_target" >"$planner_root/wrong-target-output" 2>&1; then
  printf 'runtime-sync test: wrong planner provider target was accepted\n' >&2
  exit 1
fi
grep -Fq 'ECI_RUNTIME_SYNC_PLANNER_PROVIDER' "$planner_root/wrong-target-output"

# A stale transaction directory is recoverable build residue. It must not
# turn the next normal maintenance run into a source-layout rejection.
planner_interrupted_transaction="$planner_codex/$planner_dir/.eci-command-plan.txn.interrupted"
mkdir -p -- "$planner_interrupted_transaction/gocache"
printf '%s\n' transient >"$planner_interrupted_transaction/gocache/entry"
run_planner_sync planner-apply
[ ! -e "$planner_interrupted_transaction" ] && [ ! -L "$planner_interrupted_transaction" ]

# A legacy directory lock left by an interrupted older runtime is merely
# residue. A new maintenance run must not turn it into a permanent self-lock.
planner_legacy_lock="$planner_codex/$planner_dir/.eci-command-plan.lock"
mkdir -p -- "$planner_legacy_lock/gocache"
printf '%s\n' transient >"$planner_legacy_lock/gocache/entry"
run_planner_sync planner-apply
[ -d "$planner_legacy_lock" ]

# The receipt is a diagnostic snapshot of a published build, not authority
# needed to repair it. A stale symlink receipt must be replaced without
# touching its target.
planner_receipt="$planner_codex/$planner_dir/.eci-command-plan.provenance"
planner_receipt_outside="$planner_root/planner-receipt-outside"
printf '%s\n' unchanged >"$planner_receipt_outside"
rm -f -- "$planner_receipt"
ln -s -- "$planner_receipt_outside" "$planner_receipt"
run_planner_sync planner-apply
[ ! -L "$planner_receipt" ]
[ "$(cat -- "$planner_receipt_outside")" = unchanged ]
[ -f "$planner_receipt" ]

# Even an unusable historic receipt path is diagnostic-only. The binary pair
# must still be publishable; a future run can refresh the receipt once that
# path becomes replaceable.
rm -f -- "$planner_receipt"
mkdir -- "$planner_receipt"
run_planner_sync planner-apply
[ -d "$planner_receipt" ]
rmdir -- "$planner_receipt"

# The standalone synchronizer discovers itself through pwd -P. It must still
# accept a logical HOME whose `.codex` child resolves to that exact source.
planner_home_alias="$TEST_ROOT/planner-home-alias"
ln -s -- "$planner_root" "$planner_home_alias"
HOME="$planner_home_alias" KIMI_CODE_HOME="$planner_kimi" \
  "$planner_codex/bin/eci-runtime-sync" planner-check --target "$planner_kimi"

# An empty residual scaffold is likewise non-build data. It must not affect
# the published Kimi configuration or planner pair.
mkdir -p -- "$planner_stale_root"
run_planner_sync planner-apply >/dev/null
[ -d "$planner_stale_root" ]
assert_kimi_residue_unchanged
[ "$(sha256sum -- "$planner_kimi/config.toml" | awk '{print $1}')" = "$planner_kimi_config_digest" ]

# Role metadata is lifecycle-routing context, not a build-input boundary. A
# normal provider publication remains available when that route invokes it.
CODEX_ROLE=worker run_planner_sync planner-apply >/dev/null

recreate_known_stale_tree() {
  mkdir -p -- "$planner_stale_dir"
  cp -- "$planner_stale_blob" "$planner_stale_binary"
  chmod 755 "$planner_stale_binary"
}

expect_planner_cleanup_recovery() {
  local label="$1"
  if ! run_planner_sync planner-apply >/dev/null 2>&1; then
    printf 'runtime-sync test: %s blocked normal planner maintenance\n' "$label" >&2
    exit 1
  fi
  assert_kimi_residue_unchanged
  [ "$(sha256sum -- "$planner_kimi/config.toml" | awk '{print $1}')" = "$planner_kimi_config_digest" ] || {
    printf 'runtime-sync test: %s changed Kimi configuration during recovery\n' "$label" >&2
    exit 1
  }
}

# A structurally exact historical tree is non-build residue: its old binary
# content and mode neither grants it authority nor blocks maintenance.
mkdir -p -- "$planner_stale_dir"
printf '%s\n' malformed >"$planner_stale_binary"
chmod 775 "$planner_stale_binary"
if ! run_planner_sync planner-apply >/dev/null 2>&1; then
  printf 'runtime-sync test: exact stale planner residue blocked maintenance\n' >&2
  exit 1
fi
[ -f "$planner_stale_binary" ] && grep -qx malformed "$planner_stale_binary" || {
  printf 'runtime-sync test: exact stale planner residue was unexpectedly changed\n' >&2
  exit 1
}
assert_kimi_residue_unchanged
[ "$(sha256sum -- "$planner_kimi/config.toml" | awk '{print $1}')" = "$planner_kimi_config_digest" ] || {
  printf 'runtime-sync test: exact stale planner recovery changed Kimi configuration\n' >&2
  exit 1
}

recreate_known_stale_tree
printf '%s\n' extra >"$planner_stale_dir/extra"
expect_planner_cleanup_recovery 'extra stale planner entry'
[ -f "$planner_stale_dir/extra" ]

# A symlink at the exact residue path is never followed or removed.
planner_symlink_target="$TEST_ROOT/stale-symlink-target"
printf '%s\n' unchanged >"$planner_symlink_target"
rm -rf -- "$planner_stale_root"
ln -s -- "$planner_symlink_target" "$planner_stale_root"
expect_planner_cleanup_recovery 'symlink stale planner root'
[ "$(cat -- "$planner_symlink_target")" = unchanged ]
rm -f -- "$planner_stale_root"

# An unrelated top-level planner entry is not build input. Maintenance must
# publish the selected planner sources without deleting that ordinary file.
recreate_known_stale_tree
printf '%s\n' unrelated >"$planner_codex/$planner_dir/unrelated"
expect_planner_cleanup_recovery 'unrelated top-level planner entry'
[ -f "$planner_codex/$planner_dir/unrelated" ]
rm -f -- "$planner_codex/$planner_dir/unrelated"
rm -rf -- "$planner_stale_root"

# If this test process can change ownership, confirm that ownership of
# non-build residue is diagnostic-only. Otherwise this portability case is
# skipped without changing normal maintenance behavior.
nobody_uid="$(id -u nobody 2>/dev/null || true)"
if [ -n "$nobody_uid" ] && [ "$nobody_uid" != "$(id -u)" ] && recreate_known_stale_tree && chown "$nobody_uid" "$planner_stale_dir" "$planner_stale_binary" 2>/dev/null; then
  expect_planner_cleanup_recovery 'different-owner stale planner residue'
  chown "$(id -u):$(id -g)" "$planner_stale_dir" "$planner_stale_binary" 2>/dev/null || true
  rm -rf -- "$planner_stale_root" 2>/dev/null || true
else
  rm -f -- "$planner_stale_binary" 2>/dev/null || true
  rmdir -- "$planner_stale_dir" "$planner_stale_root/lib" "$planner_stale_root" 2>/dev/null || true
fi

mkdir -p -- "$TEST_ROOT/failure/tmp" "$TEST_ROOT/failure/.codex/bin" "$TEST_ROOT/failure/.codex/hooks/lib" "$TEST_ROOT/failure/runtime/.codex/bin" "$TEST_ROOT/failure/runtime/.codex/hooks/lib"
cp -- "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/failure/.codex/hooks.json"
cp -- "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/failure/.codex/bin/eci-active"
cp -- "$TEST_ROOT/.codex/bin/eci-active-dispatch" "$TEST_ROOT/failure/.codex/bin/eci-active-dispatch"
cp -- "$TEST_ROOT/.codex/bin/eci-runtime-sync" "$TEST_ROOT/failure/.codex/bin/eci-runtime-sync"
cp -- "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/failure/.codex/hooks/validate-bash.sh"
cp -- "$TEST_ROOT/.codex/hooks/lib/nested.sh" "$TEST_ROOT/failure/.codex/hooks/lib/nested.sh"
cp -- "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/failure/runtime/.codex/hooks.json"
cp -- "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/failure/runtime/.codex/bin/eci-active"
cp -- "$TEST_ROOT/.codex/bin/eci-active-dispatch" "$TEST_ROOT/failure/runtime/.codex/bin/eci-active-dispatch"
cp -- "$TEST_ROOT/.codex/bin/eci-runtime-sync" "$TEST_ROOT/failure/runtime/.codex/bin/eci-runtime-sync"
cp -- "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/failure/runtime/.codex/hooks/validate-bash.sh"
outside="$TEST_ROOT/failure/outside"
mkdir -- "$outside"
printf 'must remain unchanged\n' >"$outside/nested.sh"
rmdir -- "$TEST_ROOT/failure/runtime/.codex/hooks/lib"
ln -s -- "$outside" "$TEST_ROOT/failure/runtime/.codex/hooks/lib"
if run_sync codex "$TEST_ROOT/failure" "$TEST_ROOT/failure/runtime" >"$TEST_ROOT/failure-output" 2>&1; then
  printf 'runtime-sync test: unsafe destination was accepted\n' >&2
  exit 1
fi
grep -Fq 'ECI_RUNTIME_SYNC_TARGET_PARENT' "$TEST_ROOT/failure-output" || {
  printf 'runtime-sync test: unsafe destination did not reach the parent-link rejection:\n' >&2
  cat -- "$TEST_ROOT/failure-output" >&2
  exit 1
}
grep -qx 'must remain unchanged' "$outside/nested.sh"
if find "$TEST_ROOT/failure/runtime/.codex" -maxdepth 1 -name '.eci-runtime-sync.*' -print -quit | grep -q .; then
  printf 'runtime-sync test: transaction directory leaked after failure\n' >&2
  exit 1
fi

if rg -n 'mktemp[^\n]*/tmp|TMPDIR=/tmp' "$ROOT/hooks/lib/eci-runtime-sync.sh"; then
  printf 'runtime-sync test: system /tmp usage found\n' >&2
  exit 1
fi

printf 'eci-runtime-sync: PASS\n'
