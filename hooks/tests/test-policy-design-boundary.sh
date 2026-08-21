#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for skill in \
  "$ROOT/skills/explore-critique-implement/SKILL.md" \
  "$ROOT/skills/agent-teams-execution/SKILL.md"; do
  grep -Fq '### Design-versus-implementation boundary' "$skill"
  grep -Fq 'blast radius and repair nature' "$skill"
  grep -Fq 'substantial scale-up would amplify' "$skill"
  grep -Fq 'semantic/model/contract errors' "$skill"
  grep -Fq 'contained blast radius' "$skill"
  grep -Fq 'may label it REJECT when its evidence supports that label' "$skill"
  grep -Fq 'coordinator alone adjudicates final impact' "$skill"
  grep -Fq 'never a design REJECT after that adjudication' "$skill"
  grep -Fq 'resolves or records every such finding' "$skill"
  grep -Fq 'security boundary is design-level' "$skill"
  grep -Fq 'mechanical call-site correction' "$skill"
done

printf '%s\n' 'design-boundary policy assertions: PASS'
