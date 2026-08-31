#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-provider-dispatch.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
controlled_home="$TMP_ROOT/home"
codex_home="$controlled_home/.codex"
alternate_codex="$TMP_ROOT/alternate-codex"
kimi_home="$TMP_ROOT/kimi"
mkdir -p "$codex_home/bin" "$alternate_codex/bin" "$kimi_home/bin"
printf '#!/usr/bin/env bash\nprintf "codex:%%s\\n" "$1"\n' >"$codex_home/bin/eci-active"
printf '#!/usr/bin/env bash\nprintf "alternate:%%s\\n" "$1"\n' >"$alternate_codex/bin/eci-active"
printf '#!/usr/bin/env bash\nprintf "kimi:%%s\\n" "$1"\n' >"$TMP_ROOT/kimi/bin/eci-active"
chmod 700 "$codex_home/bin/eci-active" "$alternate_codex/bin/eci-active" "$kimi_home/bin/eci-active"

dispatch="$ROOT/bin/eci-active-dispatch"
[ "$(env -u KIMI_SESSION_ID -u KIMI_THREAD_ID -u KIMI_PROOF_ROOT HOME="$controlled_home" CODEX_HOME="$alternate_codex" KIMI_CODE_HOME="$kimi_home" CODEX_SESSION_ID=codex-session PATH="$kimi_home/bin:$PATH" "$dispatch" status)" = codex:status ]
[ "$(env -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u CODEX_PROOF_ROOT HOME="$controlled_home" CODEX_HOME="$alternate_codex" KIMI_CODE_HOME="$kimi_home" KIMI_SESSION_ID=kimi-session PATH="$codex_home/bin:$PATH" "$dispatch" status)" = kimi:status ]
[ "$(env -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u CODEX_PROOF_ROOT -u KIMI_SESSION_ID -u KIMI_THREAD_ID -u KIMI_PROOF_ROOT HOME="$controlled_home" CODEX_HOME="$alternate_codex" KIMI_CODE_HOME="$kimi_home" "$dispatch" status)" = codex:status ]
[ "$(env HOME="$controlled_home" CODEX_HOME="$alternate_codex" KIMI_CODE_HOME="$kimi_home" CODEX_SESSION_ID=codex-session KIMI_SESSION_ID=kimi-session KIMI_PROOF_ROOT="$TMP_ROOT/kimi-proof" "$dispatch" status)" = codex:status ]
printf '%s\n' 'ECI provider dispatch assertions: PASS'
