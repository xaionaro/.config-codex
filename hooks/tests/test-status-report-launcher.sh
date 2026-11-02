#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/report file.yaml" <<'YAML'
timestamp: "2026-11-02T15:24:00Z"
state: Working
progress: []
decisions: []
blockers_risks: []
verification: []
next_focus: Finish
scope_complete: false
tasks:
  - id: '1'
    title: Complete the package
    priority: high
    impact: Report works
    effort: {min_minutes: 20, max_minutes: 30, kind: elapsed, basis: educated guess}
    status: CLOSED
    evidence: acceptance verified
top_priorities: ['1']
priority_estimates:
  - {priority: high, min_minutes: 20, max_minutes: 30, as_of: '2026-11-02T15:24:00Z', basis: educated guess, assumptions: review available, dependencies: none, critical_path: latest parallel endpoint}
completion_estimate: {min_minutes: 20, max_minutes: 30, as_of: '2026-11-02T15:24:00Z', basis: educated guess, assumptions: review available, dependencies: none, critical_path: latest parallel endpoint}
timeline:
  - job: '1'
    parent_chain: '1'
    start: '2026-11-02T14:30:00Z'
    end: '2026-11-02T15:00:00Z'
    fast: 'checkpoint'
    normal: 'unknown'
YAML

cd "$test_dir"
"$repo_root/bin/status-report" validate 'report file.yaml' | grep -q 'Schema valid'
"$repo_root/bin/status-report" render <'report file.yaml' >output.txt
grep -q 'Full task tree' output.txt
grep -q '100%' output.txt
grep -Fq '| 2026-11-02T14:30:00Z – 2026-11-02T15:00:00Z | checkpoint | unknown |' output.txt
if "$repo_root/bin/status-report" validate missing.yaml >/dev/null 2>&1; then
	printf 'missing input unexpectedly succeeded\n' >&2
	exit 1
fi
