#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${CODEX_TEST_TURN_CAPTURE_HELPER:-$ROOT/hooks/lib/turn_capture_validator.py}"
labels=(
  exact mismatch prompt-3999 prompt-4000 prompt-4001
  prompt-multibyte-4000 prompt-multibyte-4002
  id-4096 id-4097 id-multibyte-4096 id-multibyte-4098
  empty nul replacement
  turn-empty turn-ascii-4095 turn-ascii-4096 turn-ascii-4097
  turn-two-byte-4096 turn-two-byte-4098
  turn-four-byte-4096 turn-four-byte-4100 turn-mixed-4096
)
expected=(1 0 1 1 0 1 0 1 0 1 0 1 0 1 0 1 1 0 1 0 1 0 1)
turn_labels=(
  turn-empty turn-ascii-4095 turn-ascii-4096 turn-ascii-4097
  turn-two-byte-4096 turn-two-byte-4098
  turn-four-byte-4096 turn-four-byte-4100 turn-mixed-4096
)
turn_expected=(0 1 1 0 1 0 1 0 1)

if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  [ -x "$ROOT/proofs/.lake/build/bin/turnCaptureDiff" ]
else
  build_log="$(mktemp "${TMPDIR:-/tmp}/turn-capture-lean-build.XXXXXX")"
  trap 'rm -f "$build_log"' EXIT HUP INT TERM
  python3 "$ROOT/hooks/tests/process-watchdog.py" --timeout 300 --log "$build_log" \
    --cwd "$ROOT/proofs" -- lake build turnCaptureDiff || { cat "$build_log" >&2; exit 1; }
fi
mapfile -t lean_outputs < <("$ROOT/proofs/.lake/build/bin/turnCaptureDiff" "${labels[@]}")
mapfile -t python_outputs < <(
  python3 - "$HELPER" "${labels[@]}" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("validator", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def values(label: str) -> tuple[str, str, str]:
    cases = {
        "exact": ("turn", "turn", "prompt"),
        "mismatch": ("turn", "other", "prompt"),
        "prompt-3999": ("turn", "turn", "x" * 3999),
        "prompt-4000": ("turn", "turn", "x" * 4000),
        "prompt-4001": ("turn", "turn", "x" * 4001),
        "prompt-multibyte-4000": ("turn", "turn", "é" * 2000),
        "prompt-multibyte-4002": ("turn", "turn", "é" * 2001),
        "id-4096": ("x" * 4096, "x" * 4096, "prompt"),
        "id-4097": ("x" * 4097, "x" * 4097, "prompt"),
        "id-multibyte-4096": ("é" * 2048, "é" * 2048, "prompt"),
        "id-multibyte-4098": ("é" * 2049, "é" * 2049, "prompt"),
        "empty": ("turn", "turn", ""),
        "nul": ("turn", "turn", "a\0b"),
        "replacement": ("turn", "turn", "before-�-after"),
        "turn-empty": ("", "", "prompt"),
        "turn-ascii-4095": ("x" * 4095, "x" * 4095, "prompt"),
        "turn-ascii-4096": ("x" * 4096, "x" * 4096, "prompt"),
        "turn-ascii-4097": ("x" * 4097, "x" * 4097, "prompt"),
        "turn-two-byte-4096": ("é" * 2048, "é" * 2048, "prompt"),
        "turn-two-byte-4098": ("é" * 2049, "é" * 2049, "prompt"),
        "turn-four-byte-4096": ("😀" * 1024, "😀" * 1024, "prompt"),
        "turn-four-byte-4100": ("😀" * 1025, "😀" * 1025, "prompt"),
        "turn-mixed-4096": ("x" * 4090 + "é😀", "x" * 4090 + "é😀", "prompt"),
    }
    return cases[label]


for label in sys.argv[2:]:
    expected_turn_id, turn_id, prompt = values(label)
    capture = json.dumps(
        {"turn_id": turn_id, "prompt": prompt},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode()
    try:
        module.validate_capture_bytes(capture, json.dumps(expected_turn_id, ensure_ascii=False))
    except ValueError:
        print("0")
    else:
        print("1")
PY
)

mapfile -t shell_outputs < <(
  for label in "${turn_labels[@]}"; do
    case "$label" in
      turn-empty) turn_id= ;;
      turn-ascii-4095) printf -v turn_id '%*s' 4095 ''; turn_id=${turn_id// /x} ;;
      turn-ascii-4096) printf -v turn_id '%*s' 4096 ''; turn_id=${turn_id// /x} ;;
      turn-ascii-4097) printf -v turn_id '%*s' 4097 ''; turn_id=${turn_id// /x} ;;
      turn-two-byte-4096) printf -v turn_id '%*s' 2048 ''; turn_id=${turn_id// /é} ;;
      turn-two-byte-4098) printf -v turn_id '%*s' 2049 ''; turn_id=${turn_id// /é} ;;
      turn-four-byte-4096) printf -v turn_id '%*s' 1024 ''; turn_id=${turn_id// /😀} ;;
      turn-four-byte-4100) printf -v turn_id '%*s' 1025 ''; turn_id=${turn_id// /😀} ;;
      turn-mixed-4096) printf -v turn_id '%*s' 4090 ''; turn_id=${turn_id// /x}; turn_id+="é😀" ;;
    esac
    input=$(jq -cn --arg turn_id "$turn_id" '{turn_id:$turn_id}')
    extracted=$(bash -c '. "$1"; codex_hook_turn_id_json "$2"' \
      bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$input")
    canonical=$(jq -cn --arg turn_id "$turn_id" '$turn_id')
    if [ -n "$extracted" ] && [ "$extracted" = "$canonical" ]; then
      printf '1\n'
    else
      printf '0\n'
    fi
  done
)

[ "${lean_outputs[*]}" = "${expected[*]}" ]
[ "${python_outputs[*]}" = "${expected[*]}" ]
[ "${shell_outputs[*]}" = "${turn_expected[*]}" ]
printf 'turn capture differential cases: %s\n' "${#labels[@]}"
