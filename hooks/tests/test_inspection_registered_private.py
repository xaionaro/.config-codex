#!/usr/bin/env python3
"""Run the registered Bash hook in a source-built, disposable private runtime."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import platform
import subprocess
import tempfile
import time


SOURCE = Path(__file__).resolve().parents[2]


def run(arguments: list[str], **options: object) -> subprocess.CompletedProcess[str]:
    """Run an owned fixture command and retain its output."""
    return subprocess.run(arguments, text=True, capture_output=True, check=True, **options)


def main() -> None:
    """Build source copies and exercise registered inspection controls."""
    started_at = datetime.now(timezone.utc).isoformat()
    began = time.monotonic()
    binary = Path(os.environ['INSPECTION_FIXTURE_BINARY']).resolve()
    with tempfile.TemporaryDirectory(prefix='inspection-registered-') as temporary:
        root = Path(temporary)
        runtime = root / 'home/.codex'
        runtime.mkdir(parents=True)
        shutil.copytree(SOURCE / 'hooks', runtime / 'hooks', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        # Remove copied native build products; compile only this private runtime.
        for path in (runtime / 'hooks').rglob('*'):
            if path.is_file() and path.read_bytes()[:4] == b'\x7fELF':
                path.unlink()
        hook = runtime / 'hooks/validate-bash.sh'
        source = hook.read_text()
        source_sha = hashlib.sha256(source.encode()).hexdigest()
        prefix, remainder = source.split('exit 0\n', 1)
        assert all(not line or line.startswith('#') for line in prefix.splitlines())
        hook.write_text(prefix + remainder)
        shutil.copy2(SOURCE / 'hooks.json', runtime / 'hooks.json')
        (runtime / 'bin').mkdir()
        shutil.copy2(binary, runtime / 'bin/eci-git-inspection')
        binary_sha = hashlib.sha256((runtime / 'bin/eci-git-inspection').read_bytes()).hexdigest()
        for name in ('eci-command-gate-mode', 'eci-safe-import', 'eci-worker-git', 'eci-command-plan'):
            module = runtime / 'hooks/lib' / (name + '-go')
            destination = module / name if name == 'eci-command-plan' else runtime / 'bin' / name
            run(['go', 'build', '-trimpath', '-buildvcs=false', '-o', str(destination), '.'], cwd=module)
        for name in ('eci-active', 'eci-active-dispatch'):
            shutil.copy2(SOURCE / 'bin' / name, runtime / 'bin' / name)
        proof = root / 'proof/private-inspection'
        proof.mkdir(parents=True)
        repository = root / 'repo'
        foreign = root / 'foreign'
        for repo in (repository, foreign):
            run(['git', 'init', '-q', str(repo)])
            (repo / 'file').write_text('old\n')
            run(['git', '-C', str(repo), 'add', 'file'])
            run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'initial'])
            (repo / 'file').write_text('new\n')
        (proof / 'eci_active').write_text(f'scope: private inspection integration\ncwd: {repository}\nsession_id: private-inspection\ncreated_utc: 2026-10-04T00:00:00Z\n')
        config = root / 'config/eci'
        config.mkdir(parents=True)
        (config / 'command-gate-mode').write_text('enforcing\n')
        native_tmp = root / 'native-tmp'
        native_tmp.mkdir()
        registration = json.loads((runtime / 'hooks.json').read_text())
        launcher = next(h['command'] for row in registration['hooks']['PreToolUse'] if row['matcher'] == '^Bash$' for h in row['hooks'] if h['type'] == 'command')
        assert launcher == 'bash "$HOME/.codex/hooks/validate-bash.sh"'
        environment = dict(os.environ, HOME=str(root / 'home'), CODEX_PROOF_ROOT=str(root / 'proof'), CODEX_SESSION_ID='private-inspection', CODEX_HOOK_IS_SUBAGENT='true', XDG_CONFIG_HOME=str(root / 'config'), TMPDIR=str(native_tmp), CODEX_TMPDIR=str(native_tmp), PATH=str(runtime / 'bin') + ':' + os.environ['PATH'])

        def decision(command: str, expected: str | None) -> str:
            """Check one registered callback without executing its original command."""
            callback = json.dumps({'session_id': 'private-inspection', 'cwd': str(repository), 'tool_input': {'command': command}})
            result = run(['bash', '-c', launcher.replace('bash ', 'bash -x ') if os.environ.get('INSPECTION_FIXTURE_DEBUG') else launcher], input=callback, env=environment, cwd=repository)
            reason = json.loads(result.stdout)['hookSpecificOutput']['permissionDecisionReason'] if result.stdout.strip() else ''
            if os.environ.get('INSPECTION_FIXTURE_DEBUG'):
                (Path(os.environ['INSPECTION_FIXTURE_DEBUG']) / ('hook-' + str(len(command)) + '.trace')).write_text(result.stderr)
            assert (expected in reason) if expected else not reason, (command, expected, reason, result.stderr)
            return reason

        decision('git add -- file', 'ECI_WORKER_GIT_OWNERSHIP_DENIED')
        for leaf in ('existing', 'new'):
            output = repository / leaf
            if leaf == 'existing':
                output.write_text('keep\n')
            reason = decision(f'git diff --output={leaf} -- file', 'ECI_GIT_OUTPUT_WRITE_DENIED')
            assert str(output.resolve()) in reason and 'explicit access-checked Git output request' in reason
            assert output.read_text() == 'keep\n' if output.exists() else leaf == 'new'
            recovery = reason.split('stdout inspection: ', 1)[1].split('; conversion', 1)[0]
            decision(recovery, None)
            run(['bash', '-c', recovery], cwd=repository, env=environment)
            assert output.read_text() == 'keep\n' if output.exists() else leaf == 'new'
            native = repository / ('native-' + leaf)
            run(['git', '-C', str(repository), 'diff', '--output=' + str(native), '--', 'file'])
            assert native.read_text()
        readonly = repository / 'readonly'
        readonly.write_text('keep\n')
        readonly.chmod(0o400)
        decision('git diff --output=readonly -- file', None)
        denied_parent = repository / 'no-write'
        denied_parent.mkdir(mode=0o500)
        decision('git diff --output=no-write/report -- file', None)
        decision('git diff --output=/dev/null -- file', None)
        decision('git diff --unknown --output=uncertain -- file', None)
        decision('git diff ' + ' '.join('--output=/dev/null' for _ in range(65)) + ' -- file', None)
        decision(f'git -C {shlex.quote(str(foreign))} status', 'ECI_GIT_CROSS_SCOPE_DENIED')
        decision(f'git status && git -C {shlex.quote(str(foreign))} status', 'ECI_GIT_CROSS_SCOPE_DENIED')
        marker = repository / 'helper-marker'
        helper = repository / 'external-helper'
        helper.write_text('#!/bin/sh\nprintf entered > ' + shlex.quote(str(marker)) + '\n')
        helper.chmod(0o755)
        run(['git', '-C', str(repository), 'config', 'diff.external', str(helper)])
        decision('git diff --ext-diff -- file', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        reason = decision('git diff --ext-diff --output=/dev/null -- file', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        decision('git diff --ext-diff --output=/dev/null -- file && git status', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        assert not marker.exists()
        recovery = reason.split('raw inspection: ', 1)[1].split('; conversion', 1)[0]
        decision(recovery, None)
        run(['bash', '-c', recovery], cwd=repository, env=environment)
        assert not marker.exists()
        run(['git', '-C', str(repository), 'diff', '--ext-diff', '--output=/dev/null', '--', 'file'])
        assert marker.read_text() == 'entered'
        marker.unlink()
        installed = runtime / 'bin/eci-git-inspection'
        native_binary = runtime / 'bin/eci-git-inspection-real'
        installed.rename(native_binary)
        installed.write_text('#!/usr/bin/python3\nimport json,os,subprocess,sys\ndata=sys.stdin.buffer.read()\nrequest=json.loads(data)\nif request.get("query")=="destinations":\n print(os.environ.get("INSPECTION_MAPPER_RESPONSE","{}"))\nelse:\n sys.exit(subprocess.run([' + repr(str(native_binary)) + '],input=data).returncode)\n')
        installed.chmod(0o755)
        decision('git diff --ext-diff --output=/dev/null -- file', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        decision('git diff --ext-diff -- file', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        environment['INSPECTION_MAPPER_RESPONSE'] = '{invalid}'
        decision('git diff --ext-diff --output=/dev/null -- file', 'ECI_GIT_EXECUTION_CONTEXT_DENIED')
        environment.pop('INSPECTION_MAPPER_RESPONSE')
        assert not marker.exists()
        decision(f'git -C {shlex.quote(str(foreign))} diff --output=report -- file', 'ECI_GIT_CROSS_SCOPE_DENIED')
        run([str(runtime / 'bin/eci-active'), 'repository-allow-on', str(foreign.resolve()), 'private dependency inspection'], cwd=repository, env=environment)
        decision(f'git -C {shlex.quote(str(foreign))} diff --output=report -- file', None)
        print('registered PRIVATE native referral/output/access/null/helper/mapper/foreign/declaration/recovery/count PASS')
        print(json.dumps({'started_at_utc': started_at, 'finished_at_utc': datetime.now(timezone.utc).isoformat(), 'elapsed_monotonic_seconds': round(time.monotonic() - began, 3), 'hook_source_sha256': source_sha, 'inspection_binary_sha256': binary_sha, 'environment': {'os': platform.system(), 'architecture': platform.machine(), 'git': run(['git', '--version']).stdout.strip(), 'go': run(['go', 'version']).stdout.strip()}, 'command': shlex.join(['python3', str(Path(__file__).resolve())]), 'inspection_fixture_binary': str(binary), 'scope': 'PRIVATE registered source integration; no live installation or acceptance claim'}))


if __name__ == '__main__':
    main()
