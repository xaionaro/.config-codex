#!/usr/bin/env bash
# Synchronize one provider's hook runtime through an explicit coordinator route.

eci_runtime_sync_fail() {
  local code="$1"
  shift
  printf '[%s] ECI runtime synchronization denied: %s\n' "$code" "$*" >&2
  return 1
}

eci_runtime_sync_abs_path() {
  local value="$1" normalized
  case "$value" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[![:print:]]* | *//* | */./* | */../* | */.. | */.) return 1 ;;
  esac
  normalized="$(realpath -m -- "$value" 2>/dev/null || true)"
  [ -n "$normalized" ] && [ "$normalized" = "$value" ]
}

eci_runtime_sync_tmp_root() {
  local home="${HOME:-}" root
  [ -n "$home" ] || return 1
  eci_runtime_sync_abs_path "$home" || return 1
  root="$home/tmp"
  [ -d "$root" ] || return 1
  root="$(realpath -e -- "$root" 2>/dev/null || true)"
  [ -n "$root" ] || return 1
  [ "$root" != / ] && [ "$root" != /tmp ] && [[ "$root" != /tmp/* ]] || return 1
  printf '%s\n' "$root"
}

eci_runtime_sync_provider_home() {
  local provider="$1" home="${HOME:-}" root
  case "$provider" in
    codex) root="${CODEX_HOME:-$home/.codex}" ;;
    kimi) root="${KIMI_CODE_HOME:-$home/.kimi-code}" ;;
    *) eci_runtime_sync_fail ECI_RUNTIME_SYNC_PROVIDER_UNKNOWN "provider=$provider"; return 1 ;;
  esac
  eci_runtime_sync_abs_path "$root" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_INVALID "provider=$provider source=$root is not absolute and lexically normalized"
    return 1
  }
  [ -d "$root" ] && [ ! -L "$root" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_MISSING "provider=$provider source=$root is not a canonical directory"
    return 1
  }
  [ "$(realpath -e -- "$root" 2>/dev/null || true)" = "$root" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_ALIAS "provider=$provider source=$root resolves through an alias"
    return 1
  }
  printf '%s\n' "$root"
}

eci_runtime_sync_validate_root() {
  local provider="$1" root="$2" uid mode required
  eci_runtime_sync_abs_path "$root" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_INVALID "provider=$provider target=$root is not absolute and lexically normalized"
    return 1
  }
  [ -d "$root" ] && [ ! -L "$root" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_MISSING "provider=$provider target=$root is not a canonical directory"
    return 1
  }
  [ "$(realpath -e -- "$root" 2>/dev/null || true)" = "$root" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_ALIAS "provider=$provider target=$root resolves through an alias"
    return 1
  }
  case "$provider:$root" in
    codex:*/.codex|kimi:*/.kimi-code) ;;
    *) eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_PROVIDER_MISMATCH "provider=$provider target=$root has the wrong provider directory name"; return 1 ;;
  esac
  uid="$(id -u)"
  mode="$(stat -c '%a' -- "$root" 2>/dev/null || true)"
  [ -n "$mode" ] && [ "$(stat -c '%u' -- "$root" 2>/dev/null || true)" = "$uid" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_METADATA "provider=$provider target=$root is not owned by uid=$uid"
    return 1
  }
  case "$mode" in
    ''|*[!0-9]*) eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_METADATA "provider=$provider target=$root has no numeric mode"; return 1 ;;
  esac
  (( (8#$mode & 2) == 0 )) || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_METADATA "provider=$provider target=$root is world-writable mode=$mode"
    return 1
  }
  for required in bin/eci-active hooks/validate-bash.sh; do
    [ -f "$root/$required" ] && [ ! -L "$root/$required" ] || {
      eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_IDENTITY "provider=$provider target=$root lacks canonical installation file $required"
      return 1
    }
    [ "$(stat -c '%u' -- "$root/$required" 2>/dev/null || true)" = "$uid" ] || {
      eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_METADATA "provider=$provider target=$root/$required is not owned by uid=$uid"
      return 1
    }
  done
}

eci_runtime_sync_add_root() {
  local candidate="$1" root
  [ -n "$candidate" ] || return 0
  root="$(realpath -m -- "$candidate" 2>/dev/null || true)"
  [ -n "$root" ] || return 0
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  case "\n${eci_runtime_sync_roots:-}\n" in
    *$'\n'"$root"$'\n'*) return 0 ;;
  esac
  eci_runtime_sync_roots="${eci_runtime_sync_roots:-}$root
"
}

eci_runtime_sync_discover_targets() {
  local provider="$1" source_root="$2" configured mount candidate relative variable value
  local explicit_roots=""
  local -a configured_roots=()
  eci_runtime_sync_roots=""
  eci_runtime_sync_add_root "$source_root"
  case "$provider" in
    codex) variable=CODEX_RUNTIME_ROOTS ;;
    kimi) variable=KIMI_RUNTIME_ROOTS ;;
  esac
  configured="${!variable:-${ECI_RUNTIME_ROOTS:-}}"
  if [ -n "$configured" ]; then
    IFS=: read -r -a configured_roots <<<"$configured"
    for value in "${configured_roots[@]}"; do
      candidate="$(realpath -m -- "$value" 2>/dev/null || true)"
      eci_runtime_sync_validate_root "$provider" "$candidate" || return 1
      explicit_roots="${explicit_roots}${candidate}"$'\n'
      eci_runtime_sync_add_root "$value"
    done
  fi
  # Derive alternate mount-backed spellings from mountinfo instead of baking a
  # particular /mnt path into policy.  Only existing provider-shaped roots are
  # admitted; unrelated mounts are ignored before any write is attempted.
  relative="${source_root#/}"
  while IFS= read -r mount; do
    [ -n "$mount" ] || continue
    case "$mount" in *[![:print:]]*|*\ *|*\\*) continue ;; esac
    candidate="/$mount/$relative"
    eci_runtime_sync_add_root "$candidate"
  done < <(awk '{print $5}' /proc/self/mountinfo 2>/dev/null || true)
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "\n$explicit_roots" in
      *$'\n'"$root"$'\n'*) ;;
      *) eci_runtime_sync_validate_root "$provider" "$root" || continue ;;
    esac
    printf '%s\n' "$root"
  done <<<"${eci_runtime_sync_roots:-}"
}

eci_runtime_sync_collect() {
  local provider="$1" source_root="$2" stage_root="$3" relative source mode parent sha
  : >"$stage_root/manifest.tsv"
  {
    case "$provider" in
      codex) printf '%s\n' hooks.json ;;
      kimi) printf '%s\n' config.toml ;;
      *) eci_runtime_sync_fail ECI_RUNTIME_SYNC_PROVIDER_UNKNOWN "provider=$provider has no registered configuration entrypoint"; return 1 ;;
    esac
    # Both providers register the coordinator lifecycle through this binary;
    # the provider-specific config above is the only root-level difference.
    printf '%s\n' bin/eci-active
    [ -f "$source_root/bin/eci-command-gate-mode" ] && printf '%s\n' bin/eci-command-gate-mode
    find "$source_root/hooks" -type f ! -path "$source_root/hooks/tests/*" ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '*.pyo' -printf 'hooks/%P\n' 2>/dev/null
  } | LC_ALL=C sort -u | while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in
      /*|*..*|*[![:print:]]*) eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_PATH "source=$source_root relative=$relative is not a safe manifest path"; return 1 ;;
    esac
    source="$source_root/$relative"
    [ -f "$source" ] && [ ! -L "$source" ] || {
      eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_FILE "source=$source is not a canonical regular file"
      return 1
    }
    [ "$(stat -c '%u' -- "$source" 2>/dev/null || true)" = "$(id -u)" ] || {
      eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_METADATA "source=$source is not owned by uid=$(id -u)"
      return 1
    }
    mode="$(stat -c '%a' -- "$source" 2>/dev/null || true)"
    case "$mode" in ''|*[!0-9]*) eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_METADATA "source=$source has no numeric mode"; return 1 ;; esac
    parent="$stage_root/${relative%/*}"
    [ "$parent" = "$stage_root/$relative" ] && parent="$stage_root"
    mkdir -p -- "$parent"
    install -m "$mode" -- "$source" "$stage_root/$relative"
    sha="$(sha256sum -- "$source" | awk '{print $1}')"
    printf '%s\t%s\t%s\n' "$relative" "$sha" "$mode" >>"$stage_root/manifest.tsv"
  done
}

eci_runtime_sync_validate_parent() {
  local root="$1" relative="$2" parent="$root" component
  parent="${relative%/*}"
  [ "$parent" = "$relative" ] && return 0
  while [ "$parent" != . ] && [ -n "$parent" ]; do
    component="${parent%%/*}"
    if [ "$component" = "$parent" ]; then
      parent=""
    else
      parent="${parent#*/}"
    fi
  done
  [ -d "$root/${relative%/*}" ] && [ ! -L "$root/${relative%/*}" ] || return 1
  [ "$(realpath -e -- "$root/${relative%/*}" 2>/dev/null || true)" = "$root/${relative%/*}" ]
}

eci_runtime_sync_publish_target() {
  local provider="$1" source_root="$2" target_root="$3" stage_root="$4" target_stage relative sha mode source target parent target_sha target_mode receipt
  local target_tmp="$target_root/.eci-runtime-sync.$$.${RANDOM}"
  receipt="$target_root/.eci-runtime-sync-manifest"
  [ ! -e "$target_tmp" ] && [ ! -L "$target_tmp" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TRANSACTION_EXISTS "provider=$provider target=$target_root transaction=$target_tmp already exists"
    return 1
  }
  mkdir -- "$target_tmp" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TRANSACTION_CREATE "provider=$provider target=$target_root transaction=$target_tmp could not be created"
    return 1
  }
  if (
    while IFS=$'\t' read -r relative sha mode; do
      source="$stage_root/$relative"
      target="$target_root/$relative"
      parent="${target%/*}"
      [ -d "$parent" ] && [ ! -L "$parent" ] || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_PARENT "provider=$provider target=$target parent is missing or aliased"
        return 1
      }
      [ "$(realpath -e -- "$parent" 2>/dev/null || true)" = "$parent" ] || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_PARENT "provider=$provider target=$target parent is not canonical"
        return 1
      }
      if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || {
          eci_runtime_sync_fail ECI_RUNTIME_SYNC_TARGET_FILE "provider=$provider target=$target is not a replaceable regular file"
          return 1
        }
      fi
      if [[ "$relative" == */* ]]; then
        mkdir -p -- "$target_tmp/${relative%/*}" || return 1
      fi
      install -m "$mode" -- "$source" "$target_tmp/$relative" || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_STAGE_TARGET "provider=$provider target=$target could not be staged"
        return 1
      }
      mv -f -- "$target_tmp/$relative" "$target" || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_PUBLISH "provider=$provider source=$source target=$target atomic publish failed"
        return 1
      }
      [ -f "$target" ] && [ ! -L "$target" ] || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_VERIFY "provider=$provider target=$target is not a regular file after publish"
        return 1
      }
      target_sha="$(sha256sum -- "$target" | awk '{print $1}')"
      target_mode="$(stat -c '%a' -- "$target" 2>/dev/null || true)"
      [ "$target_sha" = "$sha" ] && [ "$target_mode" = "$mode" ] || {
        eci_runtime_sync_fail ECI_RUNTIME_SYNC_VERIFY "provider=$provider source=$source target=$target digest_or_mode_mismatch source_sha=$sha target_sha=$target_sha source_mode=$mode target_mode=$target_mode"
        return 1
      }
    done <"$stage_root/manifest.tsv"
    install -m 600 -- "$stage_root/manifest.tsv" "$target_tmp/.eci-runtime-sync-manifest"
    mv -f -- "$target_tmp/.eci-runtime-sync-manifest" "$receipt"
  ); then
    :
  else
    local status=$?
    rm -rf -- "$target_tmp"
    return "$status"
  fi
  rm -rf -- "$target_tmp"
  printf 'ECI runtime synchronized: provider=%s source=%s target=%s files=%s receipt=%s inode_relation=%s\n' \
    "$provider" "$source_root" "$target_root" "$(wc -l <"$stage_root/manifest.tsv")" "$receipt" \
    "$(if [ "$source_root" -ef "$target_root" ] 2>/dev/null; then printf same-root; else printf separate-root; fi)"
}

eci_runtime_sync_publish_source_receipt() {
  local provider="$1" source_root="$2" stage_root="$3" receipt="$source_root/.eci-runtime-sync-manifest"
  local receipt_tmp="$source_root/.eci-runtime-sync-source.$$.${RANDOM}"
  [ ! -e "$receipt_tmp" ] && [ ! -L "$receipt_tmp" ] || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TRANSACTION_EXISTS "provider=$provider source=$source_root transaction=$receipt_tmp already exists"
    return 1
  }
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
      eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_RECEIPT "provider=$provider source=$receipt is not a replaceable regular file"
      return 1
    }
  fi
  mkdir -- "$receipt_tmp" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TRANSACTION_CREATE "provider=$provider source=$source_root transaction=$receipt_tmp could not be created"
    return 1
  }
  if install -m 600 -- "$stage_root/manifest.tsv" "$receipt_tmp/manifest" &&
    mv -f -- "$receipt_tmp/manifest" "$receipt"; then
    rmdir -- "$receipt_tmp"
    printf 'ECI runtime source receipt refreshed: provider=%s source=%s receipt=%s\n' \
      "$provider" "$source_root" "$receipt"
    return 0
  fi
  rm -rf -- "$receipt_tmp"
  eci_runtime_sync_fail ECI_RUNTIME_SYNC_SOURCE_RECEIPT "provider=$provider source=$receipt could not be published atomically"
  return 1
}

eci_runtime_sync_run() {
  local provider="$1" source_root="$2" tmp_root stage_root target_root targets_file count=0
  source_root="$(eci_runtime_sync_provider_home "$provider")" || return 1
  eci_runtime_sync_validate_root "$provider" "$source_root" || return 1
  tmp_root="$(eci_runtime_sync_tmp_root)" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_TMP_INVALID "provider=$provider requires a canonical user-scoped temporary directory at ${HOME:-<missing>}/tmp"
    return 1
  }
  stage_root="$(mktemp -d "$tmp_root/eci-runtime-sync.XXXXXX")" || {
    eci_runtime_sync_fail ECI_RUNTIME_SYNC_STAGE_CREATE "provider=$provider could not create staging directory under $tmp_root"
    return 1
  }
  if ! eci_runtime_sync_collect "$provider" "$source_root" "$stage_root"; then
    rm -rf -- "$stage_root"
    return 1
  fi
  targets_file="$stage_root/targets"
  if ! eci_runtime_sync_discover_targets "$provider" "$source_root" >"$targets_file"; then
    rm -rf -- "$stage_root"
    return 1
  fi
  while IFS= read -r target_root; do
    [ -n "$target_root" ] || continue
    [ "$target_root" = "$source_root" ] && continue
    if ! eci_runtime_sync_publish_target "$provider" "$source_root" "$target_root" "$stage_root"; then
      rm -rf -- "$stage_root"
      return 1
    fi
    count=$((count + 1))
  done <"$targets_file"
  if ! eci_runtime_sync_publish_source_receipt "$provider" "$source_root" "$stage_root"; then
    rm -rf -- "$stage_root"
    return 1
  fi
  rm -rf -- "$stage_root"
  printf 'ECI runtime synchronization complete: provider=%s source=%s targets=%s staging=cleaned\n' "$provider" "$source_root" "$count"
}
