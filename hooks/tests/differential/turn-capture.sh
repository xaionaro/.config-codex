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
)
expected=(1 0 1 1 0 1 0 1 0 1 0 1 0 1)

(cd "$ROOT/proofs" && lake build turnCaptureDiff >/dev/null)
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

[ "${lean_outputs[*]}" = "${expected[*]}" ]
[ "${python_outputs[*]}" = "${expected[*]}" ]
printf 'turn capture differential cases: %s\n' "${#labels[@]}"
