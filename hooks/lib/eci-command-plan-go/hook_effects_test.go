package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestHookWorkerGitFamilies verifies native defaults and complete nested routing.
//
// Example: git diff stays native while a later git add uses the typed CLI.
func TestHookWorkerGitFamilies(t *testing.T) {
	root := t.TempDir()
	for _, command := range []string{"git diff --output=diff.txt", "git show --format=%H", "git log --all", "git bisect reset", "git branch feature", "git status", "git restore file", "git restore --staged file", "git restore --staged --worktree file", "git restore --worktree --staged file", "git apply patch", "git apply --index patch", "git apply --cached patch", "git worktree list", "git worktree move old new", "git worktree remove old", "git worktree lock old", "git worktree unlock old", "git worktree repair old", "git worktree prune"} {
		t.Run(command,
			// Verify each native verb keeps its original option semantics.
			//
			// Example: diff --output remains a native command.
			func(t *testing.T) {
				request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true, ApprovedRoots: []string{root}}
				result := Classify(request)
				{
					diagnostic := inspectHookEffects(request, result)
					require.Falsef(t, diagnostic != nil, "native command denied: %+v", diagnostic)
				}
			})
	}
	for _, command := range []string{"git add --help", "git rm --cached file", "git mv old new", "git reset --dry-run", "git checkout topic", "git switch topic", "git update-index --refresh", "git read-tree HEAD", "git merge topic", "git rebase topic", "git cherry-pick -n HEAD", "git revert -n HEAD", "git am patch", "git commit -n -m checkpoint", "git stash", "git pull", "git worktree add next", "git diff; git add file", "git restore --staged file; git stash", "git apply --index patch; git pull", "git worktree repair old; git add file", "bash -c 'git diff; git commit -m checkpoint'", "printf '%s' \"$(git rebase topic)\"", "timeout 5 git add file", "command git checkout file", "env -C " + root + " git add file"} {
		t.Run(command,
			// Verify each reachable selected mutation has the typed route.
			//
			// Example: a nested add cannot disappear behind a native diff.
			func(t *testing.T) {
				request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true, ApprovedRoots: []string{root}}
				result := Classify(request)
				diagnostic := inspectHookEffects(request, result)
				require.Falsef(t, diagnostic == nil || diagnostic.Code != CodeWorkerGitOwnershipDenied, "want typed Worker Git route, got %+v (analysis=%+v)", diagnostic, result.ShellAnalysis)
				require.Falsef(t, !strings.Contains(diagnostic.Remediation, "eci-worker-git") || !strings.Contains(diagnostic.Remediation, "run-once"), "missing bounded hatch: %+v", diagnostic)
			})
	}
}

// TestHookCoordinatorGitTargets verifies concrete scope and broad mutations.
//
// Example: the owner can add one file, but a foreign repository needs declaration.
func TestHookCoordinatorGitTargets(t *testing.T) {
	root := t.TempDir()
	foreign := t.TempDir()
	for _, directory := range []string{root, foreign} {
		{
			output, err := exec.Command("git", "init", "-q", directory).CombinedOutput()
			require.NoErrorf(t, err, "init fixture: %v: %s", err, output)
		}
	}
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, CollectShellCommands: true, ApprovedRoots: []string{root}}
	request.Command = "git -C " + foreign + " add file"
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_GIT_CROSS_SCOPE_DENIED"), "foreign mutation scope missing: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, foreign)
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic != nil, "declared repository denied: %+v", diagnostic)
	}
	for _, command := range []string{"git add file", "git add -A file", "git reset -- file", "git reset file", "git -C " + foreign + " diff --output=result"} {
		request.Command = command
		{
			diagnostic := inspectHookEffects(request, Classify(request))
			require.Falsef(t, diagnostic != nil, "scoped/read-only command %s denied: %+v", command, diagnostic)
		}
	}
	for _, command := range []string{"git reset --hard", "git reset", "git reset -- .", "git add -A", "git add -A -- ."} {
		request.Command = command
		{
			diagnostic := inspectHookEffects(request, Classify(request))
			require.Falsef(t, diagnostic == nil || diagnostic.Code != CodeBroadDestructiveDenied, "broad mutation %s allowed: %+v", command, diagnostic)
		}
	}
}

// TestHookGitPreviewSemantics binds preview interpretation to the selected verb.
//
// Example: commit -n bypasses hooks while add -n is a dry run.
func TestHookGitPreviewSemantics(t *testing.T) {
	for _, current := range []struct {
		Command  string
		Mutation bool
	}{
		{Command: "commit -n -m checkpoint", Mutation: true},
		{Command: "commit --dry-run -m checkpoint", Mutation: false},
		{Command: "commit -m --dry-run", Mutation: true},
		{Command: "commit --message --dry-run", Mutation: true},
		{Command: "commit -am --dry-run", Mutation: true},
		{Command: "commit --message=--dry-run", Mutation: true},
		{Command: "commit -F --dry-run", Mutation: true},
		{Command: "commit -m --help", Mutation: true},
		{Command: "commit -- --dry-run", Mutation: true},
		{Command: "commit -m checkpoint --dry-run", Mutation: false},
		{Command: "cherry-pick -n HEAD", Mutation: true},
		{Command: "revert -n HEAD", Mutation: true},
		{Command: "pull -n", Mutation: true},
		{Command: "fetch -n", Mutation: true},
		{Command: "reset --dry-run", Mutation: true},
		{Command: "cherry-pick --dry-run HEAD", Mutation: true},
		{Command: "add -n file", Mutation: false},
		{Command: "rm -n file", Mutation: false},
		{Command: "mv -n old new", Mutation: false},
		{Command: "clean -n", Mutation: false},
		{Command: "push -n", Mutation: false},
		{Command: "fetch --dry-run", Mutation: false},
		{Command: "add --dry-run file", Mutation: false},
		{Command: "commit --help", Mutation: false},
	} {
		arguments := []token{{value: "git"}}
		for _, value := range strings.Fields(current.Command) {
			arguments = append(arguments, token{value: value})
		}
		require.Equalf(t, current.Mutation, hookGitCoordinatorMutation(arguments, 1), "preview semantics: %s", current.Command)
	}
	root := t.TempDir()
	for _, command := range []string{"git commit -n -m checkpoint", "git commit -m --dry-run", "git commit -- --dry-run", "git commit -m --help"} {
		request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true}
		diagnostic := inspectHookEffects(request, Classify(request))
		require.NotNil(t, diagnostic, command)
		require.Equal(t, hookCodeCommitProducerRequired, diagnostic.Code, command)
	}
	for _, command := range []string{"git commit --dry-run -m checkpoint", "git commit -m checkpoint --dry-run"} {
		request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true}
		require.Nil(t, inspectHookEffects(request, Classify(request)), command)
	}
}

// TestHookLifecycleAndScriptTargets verifies concrete execution ownership.
//
// Example: an existing foreign script is denied until its repository is declared.
func TestHookLifecycleAndScriptTargets(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	provider := filepath.Join(home, ".codex")
	requireHookDirectory(t, filepath.Join(provider, "bin"))
	lifecycle := filepath.Join(provider, "bin", "eci-active")
	requireHookFile(t, lifecycle, "#!/bin/sh\nexit 0\n")
	other := t.TempDir()
	script := filepath.Join(other, "check.sh")
	requireHookFile(t, script, "#!/bin/sh\nexit 0\n")
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, ActiveSession: "owner", CWD: provider, CollectShellCommands: true, ApprovedRoots: []string{provider}}
	for _, command := range []string{lifecycle + " status", lifecycle + " --help", lifecycle + " repository-allow-on " + other + " reason", "bash -n " + script, "bash -nx " + script, "bash --unknown-option " + script} {
		request.Command = command
		{
			diagnostic := inspectHookEffects(request, Classify(request))
			require.Falsef(t, diagnostic != nil, "legitimate route %s denied: %+v", command, diagnostic)
		}
	}
	request.Command = lifecycle + " off"
	{
		diagnostic := hookTestDiagnostic(request)
		require.Falsef(t, diagnostic == nil || diagnostic.Code != CodeControlOwnerRequired, "Worker lifecycle mutation was not routed: %+v", diagnostic)
	}
	request.Command = "bash " + script
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_WORKER_SCRIPT_TARGET_DENIED"), "foreign script was not denied: %+v", diagnostic)
	}
	request.Command = "bash -O extglob " + script
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != hookCodeWorkerScriptTargetDenied, "shell option value obscured the script target: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, other)
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic != nil, "declared script target denied: %+v", diagnostic)
	}
	installer := filepath.Join(provider, "hooks", "install-pre-commit-go-mod.sh")
	requireHookDirectory(t, filepath.Dir(installer))
	requireHookFile(t, installer, "#!/bin/sh\nexit 0\n")
	request.Command = "bash " + installer
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_WORKER_HOOK_INSTALLER_DENIED"), "provider installer ownership missing: %+v", diagnostic)
	}
	request.Role = RoleCoordinator
	request.Command = "bash " + script
	request.ApprovedRoots = []string{provider}
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_COORDINATOR_SCRIPT_TARGET_DENIED"), "coordinator foreign script boundary missing: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, other)
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic != nil, "declared coordinator dependency script denied: %+v", diagnostic)
	}
	request.Command = "env CODEX_SESSION_ID=foreign " + lifecycle + " off"
	{
		diagnostic := inspectHookEffects(request, Classify(request))
		require.Falsef(t, diagnostic == nil || diagnostic.Code != CodeControlIdentityDenied, "foreign lifecycle session target allowed: %+v analysis=%+v", diagnostic, Classify(request).ShellAnalysis)
	}
}

// requireHookDirectory creates a fixture directory and reports setup failures.
//
// Example: a fixture lifecycle executable needs an existing bin directory.
func requireHookDirectory(
	t *testing.T,
	path string,
) {
	t.Helper()
	require.NoError(t, os.MkdirAll(path, 0o700))
}

// requireHookFile creates an executable fixture without invoking its contents.
//
// Example: script ownership tests resolve a shebang file on disk.
func requireHookFile(
	t *testing.T,
	path string,
	contents string,
) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte(contents), 0o700))
}

// TestHookGitDirectoryFacts verifies resolved directory and argument uncertainty.
//
// Example: an absolute -C still identifies a target after an unknown cd.
func TestHookGitDirectoryFacts(t *testing.T) {
	root := t.TempDir()
	other := t.TempDir()
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: root, ApprovedRoots: []string{root}}
	result := Result{ShellAnalysis: &ShellAnalysis{Commands: []ShellCommandRecord{{Argv: []string{"git", "-C", other, "add", "file"}, CWD: root, CWDKnown: true, Reachability: segmentReachable}}}}
	diagnostic := inspectHookEffects(request, result)
	require.Falsef(t, diagnostic == nil || diagnostic.Path != resolvePathIdentity(other), "want selected target %s, got %+v", other, diagnostic)
	result.ShellAnalysis.Commands[0].UnknownArguments = []int{3}
	{
		diagnostic := inspectHookEffects(request, result)
		require.Falsef(t, diagnostic != nil, "unknown verb denied: %+v", diagnostic)
	}
	result.ShellAnalysis.Commands[0].Reachability = segmentUnreachable
	{
		diagnostic := inspectHookEffects(request, result)
		require.Falsef(t, diagnostic != nil, "unreachable record denied: %+v", diagnostic)
	}
}

// TestHookGitAbsoluteContextWithUnknownCWD retains absolute selector evidence.
//
// Example: git -C /dependency add file selects that repository after unknown cd.
func TestHookGitAbsoluteContextWithUnknownCWD(t *testing.T) {
	root := t.TempDir()
	foreign := t.TempDir()
	{
		output, err := exec.Command("git", "init", "-q", foreign).CombinedOutput()
		require.NoErrorf(t, err, "init fixture: %v: %s", err, output)
	}
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, ApprovedRoots: []string{root}}
	result := Result{ShellAnalysis: &ShellAnalysis{Commands: []ShellCommandRecord{{Argv: []string{"git", "-C", foreign, "add", "file"}, CWDKnown: false, Reachability: segmentReachable}}}}
	{
		diagnostic := inspectHookEffects(request, result)
		require.Falsef(t, diagnostic == nil || diagnostic.Code != hookCodeGitCrossScopeDenied, "absolute repository evidence lost: %+v", diagnostic)
	}
}

// hookTestDiagnostic retains planner-owned denials before callback-owned checks.
//
// Example: a canonical lifecycle owner diagnostic can precede shell publication.
func hookTestDiagnostic(request Request) *Diagnostic {
	result := Classify(request)
	if result.Diagnostic != nil {
		return result.Diagnostic
	}
	return inspectHookEffects(request, result)
}

// TestHookControlWriterTargets distinguishes owned notes and foreign live state.
//
// Example: an ordinary project file stays writable while a sibling marker does not.
func TestHookControlWriterTargets(t *testing.T) {
	root := t.TempDir()
	current := filepath.Join(root, "owner", "eci_active")
	foreign := filepath.Join(root, "other", "eci_active")
	requireHookDirectory(t, filepath.Dir(current))
	requireHookDirectory(t, filepath.Dir(foreign))
	requireHookFile(t, current, "scope: fixture\ncwd: "+root+"\nsession_id: owner\n")
	requireHookFile(t, foreign, "scope: fixture\ncwd: "+root+"\nsession_id: other\n")
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, ActiveSession: "owner", CWD: root, CWDKnown: true, ActiveMarkers: []string{current, foreign}}
	for _, target := range []string{filepath.Join(root, "file"), filepath.Join(root, "owner", "project-understanding.md")} {
		{
			diagnostic := inspectHookControlWriter(request, []token{{value: "touch"}, {value: target}}, 1)
			require.Falsef(t, diagnostic != nil, "owned target denied: %+v", diagnostic)
		}
	}
	for _, target := range []string{current, filepath.Join(root, "owner", "eci_wait"), foreign, filepath.Join(root, "other", "project-understanding.md")} {
		{
			diagnostic := inspectHookControlWriter(request, []token{{value: "tee"}, {value: target}}, 1)
			require.Falsef(t, diagnostic == nil, "control target %s allowed", target)
		}
	}
	{
		diagnostic := inspectHookControlWriter(request, []token{{value: "rm"}, {value: "-rf"}, {value: root}}, 1)
		require.False(t, diagnostic == nil, "ancestor removal with live markers allowed")
	}
}

// TestHookCleanupTargets protects existing live hooks while retaining leaf cleanup.
//
// Example: deleting a generated cache leaf is harmless; deleting its live hook is not.
func TestHookCleanupTargets(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	provider := filepath.Join(home, ".codex")
	hook := filepath.Join(provider, "hooks", "validate-bash.sh")
	requireHookDirectory(t, filepath.Dir(hook))
	requireHookFile(t, hook, "#!/bin/sh\nexit 0\n")
	alias := filepath.Join(provider, "owned-hook-alias")
	require.NoError(t, os.Symlink(hook, alias))
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: provider, CollectShellCommands: true, ApprovedRoots: []string{provider}}
	for _, command := range []string{"rm -f generated.cache", "rm -rf bin/__pycache__", "rm -rf missing-directory", "rm -f " + alias} {
		request.Command = command
		{
			diagnostic := inspectHookEffects(request, Classify(request))
			require.Falsef(t, diagnostic != nil, "narrow cleanup denied: %+v", diagnostic)
		}
	}
	for _, command := range []string{"rm -f " + hook, "rm -rf " + provider, "mv " + hook + " " + filepath.Join(provider, "saved-hook")} {
		request.Command = command
		{
			diagnostic := inspectHookEffects(request, Classify(request))
			require.Falsef(t, diagnostic == nil, "live-hook destruction allowed: %s", command)
		}
	}
}
