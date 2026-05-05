# Shellcheck-friendly library: drop reviewer violations not grounded in rules.
# shellcheck shell=bash

reviewer_filter_migration_summary="$HOME/.codex/memories/migration-import/ACTIVE-SUMMARY.md"
reviewer_filter_legacy_summary="$HOME/.codex/memories/claude"'-import/ACTIVE-SUMMARY.md'

if [ -z "${REVIEWER_FILTER_CORPUS_FILES+x}" ]; then
  REVIEWER_FILTER_CORPUS_FILES="$HOME/.codex/CODEX.md $HOME/.codex/hooks/stop-checklist.md $reviewer_filter_migration_summary"
  if [ -f "$reviewer_filter_legacy_summary" ]; then
    REVIEWER_FILTER_CORPUS_FILES="$REVIEWER_FILTER_CORPUS_FILES $reviewer_filter_legacy_summary"
  fi
fi
: "${REVIEWER_FILTER_THRESHOLD:=0.15}"

filter_violations() {
  local result_json="$1"
  shift || true
  [ -n "$result_json" ] || { printf '%s' "$result_json"; return 0; }

  local static_corpus_text extra_text filtered
  static_corpus_text=$(
    # shellcheck disable=SC2086 # Space-separated corpus list is intentional.
    cat $REVIEWER_FILTER_CORPUS_FILES 2>/dev/null || true
  )
  extra_text=$(
    for corpus_file in "$@"; do
      if [ -n "$corpus_file" ]; then
        cat "$corpus_file" 2>/dev/null || true
      fi
    done
  )

  filtered=$(printf '%s' "$result_json" | python3 -c '
import json, re, sys

static_corpus_raw = sys.argv[1]
extra_raw = sys.argv[2]
corpus = static_corpus_raw.lower()
threshold = float(sys.argv[3])

STOPWORDS = {
    "a", "an", "and", "any", "as", "be", "by", "for", "from", "if",
    "in", "is", "it", "of", "on", "or", "that", "the", "then", "this",
    "to", "was", "were", "with", "you", "your",
    "after", "again", "all", "always", "before", "current", "each",
    "end", "ending", "every", "must", "need", "needs", "requested",
    "required", "should", "stop", "stopping", "turn",
    "assistant", "entry", "user",
}
SYNONYMS = {
    "ran": "execute",
    "run": "execute",
    "running": "execute",
    "runs": "execute",
    "executed": "execute",
    "executes": "execute",
    "executing": "execute",
    "suite": "test",
    "ended": "stop",
    "ending": "stop",
    "stopped": "stop",
    "stopping": "stop",
}


def grams(words):
    if len(words) < 3:
        return set(words)
    return set(" ".join(words[i:i + 3]) for i in range(len(words) - 2))


def section_text(source, name):
    pattern = r"(?ims)^## " + re.escape(name) + r"\s*\n(.*?)(?=^## [A-Z_]+|\Z)"
    return re.findall(pattern, source)


def entry_texts(sections):
    entries = []
    for section in sections:
        found = re.findall(r"(?is)<entry>(.*?)</entry>", section)
        entries.extend(found or [section])
    return entries


def raw_tokens(text):
    tokens = []
    for token in re.findall(r"[a-z0-9]+(?:[._/-][a-z0-9]+)*", text.lower()):
        tokens.extend(part for part in re.split(r"[._/-]+", token) if part)
    return tokens


def normalize_token(token):
    token = SYNONYMS.get(token, token)
    if len(token) > 3 and token.endswith("s"):
        token = token[:-1]
    return SYNONYMS.get(token, token)


def signal_tokens(text):
    tokens = set()
    for token in raw_tokens(text):
        token = normalize_token(token)
        if len(token) >= 2 and token not in STOPWORDS:
            tokens.add(token)
    return tokens


def evidence_grounded_in_current(evidence):
    evidence = " ".join((evidence or "").lower().split())
    current = " ".join(current_text.lower().split())
    if not evidence:
        return False
    if evidence in current:
        return True
    evidence_tokens = signal_tokens(evidence)
    current_tokens = signal_tokens(current_text)
    return bool(evidence_tokens) and len(evidence_tokens & current_tokens) / len(evidence_tokens) >= 0.5


def matches_user_history_agreement(violation):
    if not history_entries:
        return False
    if not evidence_grounded_in_current(violation.get("evidence") or ""):
        return False
    rule_tokens = signal_tokens(violation.get("rule") or "")
    if len(rule_tokens) < 2:
        return False
    for entry in history_entries:
        entry_tokens = signal_tokens(entry)
        shared = rule_tokens & entry_tokens
        required = 3 if min(len(rule_tokens), len(entry_tokens)) >= 3 else 2
        if len(shared) >= required and len(shared) / min(len(rule_tokens), len(entry_tokens)) >= 0.5:
            return True
    return False


cw = re.sub(r"\s+", " ", corpus).split()
cg = grams(cw)
history_entries = entry_texts(section_text(extra_raw, "USER_HISTORY"))
current_text = "\n".join(section_text(extra_raw, "CURRENT_TURN"))

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

kept = []
for violation in data.get("violations", []) or []:
    rw = re.sub(r"\s+", " ", (violation.get("rule") or "").lower()).split()
    rg = grams(rw)
    if (rg and len(rg & cg) / len(rg) >= threshold) or matches_user_history_agreement(violation):
        kept.append(violation)
data["violations"] = kept
if not kept and data.get("verdict") == "fail":
    data["verdict"] = "pass"
print(json.dumps(data, separators=(",", ":")))
' "$static_corpus_text" "$extra_text" "$REVIEWER_FILTER_THRESHOLD" 2>/dev/null)

  if [ -z "$filtered" ]; then
    printf '%s' "$result_json"
  else
    printf '%s' "$filtered"
  fi
}
