package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestHookWorkerGitFamilies verifies native defaults and complete nested routing.
//
// Example: git diff stays native while a later git add uses the typed CLI.
func TestHookWorkerGitFamilies(t *testing.T) {
	root := t.TempDir()
	for _, command := range []string{"git diff --output=diff.txt", "git show --format=%H", "git log --all", "git bisect reset", "git branch feature", "git status", "git worktree list"} {
		t.Run(command,
			// Verify each native verb keeps its original option semantics.
			//
			// Example: diff --output remains a native command.
			func(t *testing.T) {
				request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true, ApprovedRoots: []string{root}}
				result := Classify(request)
				if diagnostic := inspectHookEffects(request, result); diagnostic != nil {
					t.Fatalf("native command denied: %+v", diagnostic)
				}
			})
	}
	for _, command := range []string{"git add --help", "git reset --dry-run", "git switch topic", "git update-index --refresh", "git worktree add next", "git diff; git add file", "bash -c 'git diff; git commit -m checkpoint'", "printf '%s' \"$(git rebase topic)\"", "timeout 5 git add file", "command git restore file", "env -C " + root + " git add file"} {
		t.Run(command,
			// Verify each reachable selected mutation has the typed route.
			//
			// Example: a nested add cannot disappear behind a native diff.
			func(t *testing.T) {
				request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: root, Command: command, CollectShellCommands: true, ApprovedRoots: []string{root}}
				result := Classify(request)
				diagnostic := inspectHookEffects(request, result)
				if diagnostic == nil || diagnostic.Code != CodeWorkerGitOwnershipDenied {
					t.Fatalf("want typed Worker Git route, got %+v (analysis=%+v)", diagnostic, result.ShellAnalysis)
				}
				if !strings.Contains(diagnostic.Remediation, "eci-worker-git") || !strings.Contains(diagnostic.Remediation, "run-once") {
					t.Fatalf("missing bounded hatch: %+v", diagnostic)
				}
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
		if output, err := exec.Command("git", "init", "-q", directory).CombinedOutput(); err != nil {
			t.Fatalf("init fixture: %v: %s", err, output)
		}
	}
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, CollectShellCommands: true, ApprovedRoots: []string{root}}
	request.Command = "git -C " + foreign + " add file"
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_GIT_CROSS_SCOPE_DENIED") {
		t.Fatalf("foreign mutation scope missing: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, foreign)
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
		t.Fatalf("declared repository denied: %+v", diagnostic)
	}
	for _, command := range []string{"git add file", "git add -A file", "git reset -- file", "git reset file", "git -C " + foreign + " diff --output=result"} {
		request.Command = command
		if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
			t.Fatalf("scoped/read-only command %s denied: %+v", command, diagnostic)
		}
	}
	for _, command := range []string{"git reset --hard", "git reset", "git reset -- .", "git add -A", "git add -A -- ."} {
		request.Command = command
		if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != CodeBroadDestructiveDenied {
			t.Fatalf("broad mutation %s allowed: %+v", command, diagnostic)
		}
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
		if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
			t.Fatalf("legitimate route %s denied: %+v", command, diagnostic)
		}
	}
	request.Command = lifecycle + " off"
	if diagnostic := hookTestDiagnostic(request); diagnostic == nil || diagnostic.Code != CodeControlOwnerRequired {
		t.Fatalf("Worker lifecycle mutation was not routed: %+v", diagnostic)
	}
	request.Command = "bash " + script
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_WORKER_SCRIPT_TARGET_DENIED") {
		t.Fatalf("foreign script was not denied: %+v", diagnostic)
	}
	request.Command = "bash -O extglob " + script
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != hookCodeWorkerScriptTargetDenied {
		t.Fatalf("shell option value obscured the script target: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, other)
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
		t.Fatalf("declared script target denied: %+v", diagnostic)
	}
	installer := filepath.Join(provider, "hooks", "install-pre-commit-go-mod.sh")
	requireHookDirectory(t, filepath.Dir(installer))
	requireHookFile(t, installer, "#!/bin/sh\nexit 0\n")
	request.Command = "bash " + installer
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_WORKER_HOOK_INSTALLER_DENIED") {
		t.Fatalf("provider installer ownership missing: %+v", diagnostic)
	}
	request.Role = RoleCoordinator
	request.Command = "bash " + script
	request.ApprovedRoots = []string{provider}
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != DiagnosticCode("ECI_COORDINATOR_SCRIPT_TARGET_DENIED") {
		t.Fatalf("coordinator foreign script boundary missing: %+v", diagnostic)
	}
	request.ApprovedRoots = append(request.ApprovedRoots, other)
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
		t.Fatalf("declared coordinator dependency script denied: %+v", diagnostic)
	}
	request.Command = "env CODEX_SESSION_ID=foreign " + lifecycle + " off"
	if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil || diagnostic.Code != CodeControlIdentityDenied {
		t.Fatalf("foreign lifecycle session target allowed: %+v analysis=%+v", diagnostic, Classify(request).ShellAnalysis)
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
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
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
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
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
	if diagnostic == nil || diagnostic.Path != resolvePathIdentity(other) {
		t.Fatalf("want selected target %s, got %+v", other, diagnostic)
	}
	result.ShellAnalysis.Commands[0].UnknownArguments = []int{3}
	if diagnostic := inspectHookEffects(request, result); diagnostic != nil {
		t.Fatalf("unknown verb denied: %+v", diagnostic)
	}
	result.ShellAnalysis.Commands[0].Reachability = segmentUnreachable
	if diagnostic := inspectHookEffects(request, result); diagnostic != nil {
		t.Fatalf("unreachable record denied: %+v", diagnostic)
	}
}

// TestHookGitAbsoluteContextWithUnknownCWD retains absolute selector evidence.
//
// Example: git -C /dependency add file selects that repository after unknown cd.
func TestHookGitAbsoluteContextWithUnknownCWD(t *testing.T) {
	root := t.TempDir()
	foreign := t.TempDir()
	if output, err := exec.Command("git", "init", "-q", foreign).CombinedOutput(); err != nil {
		t.Fatalf("init fixture: %v: %s", err, output)
	}
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleCoordinator, Marker: MarkerActive, CWD: root, ApprovedRoots: []string{root}}
	result := Result{ShellAnalysis: &ShellAnalysis{Commands: []ShellCommandRecord{{Argv: []string{"git", "-C", foreign, "add", "file"}, CWDKnown: false, Reachability: segmentReachable}}}}
	if diagnostic := inspectHookEffects(request, result); diagnostic == nil || diagnostic.Code != hookCodeGitCrossScopeDenied {
		t.Fatalf("absolute repository evidence lost: %+v", diagnostic)
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
		if diagnostic := inspectHookControlWriter(request, []token{{value: "touch"}, {value: target}}, 1); diagnostic != nil {
			t.Fatalf("owned target denied: %+v", diagnostic)
		}
	}
	for _, target := range []string{current, filepath.Join(root, "owner", "eci_wait"), foreign, filepath.Join(root, "other", "project-understanding.md")} {
		if diagnostic := inspectHookControlWriter(request, []token{{value: "tee"}, {value: target}}, 1); diagnostic == nil {
			t.Fatalf("control target %s allowed", target)
		}
	}
	if diagnostic := inspectHookControlWriter(request, []token{{value: "rm"}, {value: "-rf"}, {value: root}}, 1); diagnostic == nil {
		t.Fatal("ancestor removal with live markers allowed")
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
	if err := os.Symlink(hook, alias); err != nil {
		t.Fatal(err)
	}
	request := Request{HookMode: true, Provider: ProviderCodex, Role: RoleWorker, Marker: MarkerActive, CWD: provider, CollectShellCommands: true, ApprovedRoots: []string{provider}}
	for _, command := range []string{"rm -f generated.cache", "rm -rf bin/__pycache__", "rm -rf missing-directory", "rm -f " + alias} {
		request.Command = command
		if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic != nil {
			t.Fatalf("narrow cleanup denied: %+v", diagnostic)
		}
	}
	for _, command := range []string{"rm -f " + hook, "rm -rf " + provider, "mv " + hook + " " + filepath.Join(provider, "saved-hook")} {
		request.Command = command
		if diagnostic := inspectHookEffects(request, Classify(request)); diagnostic == nil {
			t.Fatalf("live-hook destruction allowed: %s", command)
		}
	}
}
