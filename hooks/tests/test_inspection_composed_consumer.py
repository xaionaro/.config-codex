#!/usr/bin/env python3
"""Exercise composed inspection records through the actual shell consumer."""
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    """Verify that the shipped shell consumer uses its composed CLI finding."""
    source = Path(__file__).resolve().parents[1].joinpath('validate-bash.sh').read_text()
    start = source.index('enforce_git_mutation_gate() {')
    end = source.index('\n}\n', start) + 3
    with tempfile.TemporaryDirectory(prefix='inspection-consumer-') as temporary:
        root = Path(temporary)
        subprocess.run(['git', 'init', '-q', str(root / 'repo')], check=True)
        binary = root / 'bin' / 'eci-git-inspection'
        binary.parent.mkdir()
        target = str(root / 'report')
        record = json.dumps({'schema': 'git-inspection-output-v1', 'repository': str(root / 'repo')})
        binary.write_text('#!/usr/bin/python3\nimport json,sys\nrequest=json.load(sys.stdin)\nassert request["query"]=="consume-inspection"\nprint(json.dumps({"effect":"explicit-access-checked-git-output-intent","target":' + repr(target) + ',"stdout_argv":["git","diff"]}))\n')
        binary.chmod(0o755)
        fixture = '''set -euo pipefail
cwd=$REPO
hook_is_subagent=true
syntax_eci_markers=(private)
ECI_CROSS_SCOPE_GATE_ENABLED=false
command='git diff --output=report'
validate_active_marker_binding() { :; }
git_protected_worktree_target_detail() { :; }
codex_git_safe() { git "$@"; }
git_mutation_specs() { printf '%s\\n' output "inspection-output:$RECORD"; }
deny_eci() { printf '%s\\n' "$*"; exit 77; }
''' + source[start:end] + '\nenforce_git_mutation_gate\n'
        environment = dict(os.environ, CODEX_CONFIGURED_HOME=str(root), RECORD=record, REPO=str(root / "repo"))
        result = subprocess.run(['bash'], input=fixture, text=True, capture_output=True, env=environment)
        assert result.returncode == 77, (result.returncode, result.stdout, result.stderr)
        assert 'explicit access-checked Git output request' in result.stdout, result.stdout
        assert target in result.stdout
        assert not Path(target).exists()
        print('actual composed consumer positive PASS')


if __name__ == '__main__':
    main()
