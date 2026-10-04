package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func contextFixture(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	cwd := t.TempDir()
	t.Setenv("CODEX_PROOF_ROOT", root)
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "")
	return root, cwd
}
func contextMarker(t *testing.T, root, sid, cwd string) {
	t.Helper()
	dir := filepath.Join(root, sid)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "eci_active"), []byte("scope: test\ncwd: "+cwd+"\nsession_id: "+sid+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
}
func TestHookContextParentPrefix(t *testing.T) {
	root, cwd := contextFixture(t)
	contextMarker(t, root, "parent", cwd)
	transcript := filepath.Join(t.TempDir(), "transcript.jsonl")
	metadata := `{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}`
	if err := os.WriteFile(transcript, []byte(metadata+"\n"+strings.Repeat("x", 2<<20)), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := hookRequest(HookInput{SessionID: "child", CWD: cwd, TranscriptPath: transcript})
	if err != nil {
		t.Fatal(err)
	}
	if got.Role != RoleWorker || got.ActiveSession != "parent" || got.Marker != MarkerActive || len(got.ActiveMarkers) != 1 {
		t.Fatalf("context=%+v", got)
	}
}
func TestHookContextMarkerAliasAndInvalid(t *testing.T) {
	root, cwd := contextFixture(t)
	contextMarker(t, root, "session_owner", cwd)
	got, err := hookRequest(HookInput{SessionID: "owner", CWD: cwd})
	if err != nil {
		t.Fatal(err)
	}
	if got.ActiveSession != "session_owner" || got.Marker != MarkerActive {
		t.Fatalf("context=%+v", got)
	}
	if err := os.WriteFile(filepath.Join(root, "session_owner", "eci_active"), []byte("broken\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err = hookRequest(HookInput{SessionID: "owner", CWD: cwd})
	if err != nil {
		t.Fatal(err)
	}
	if got.Marker == MarkerActive || len(got.ActiveMarkers) != 0 {
		t.Fatalf("invalid marker accepted: %+v", got)
	}
}
func TestHookContextExplicitWorkerAndActivity(t *testing.T) {
	root, cwd := contextFixture(t)
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "1")
	input := HookInput{SessionID: "child", CWD: cwd}
	input.ToolInput.Command = "cat ordinary"
	request, err := hookRequest(input)
	if err != nil {
		t.Fatal(err)
	}
	if request.Role != RoleWorker || request.Command != "cat ordinary" {
		t.Fatalf("request=%+v", request)
	}
	readonly := Result{ShellAnalysis: &ShellAnalysis{Commands: []ShellCommandRecord{{Argv: []string{"cat", "ordinary"}}}}}
	if err := recordHookActivity(request, readonly); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "activity")); !os.IsNotExist(err) {
		t.Fatalf("worker read created activity: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "touched-repos")); !os.IsNotExist(err) {
		t.Fatalf("read-only command touched repositories: %v", err)
	}
	request.Role = RoleCoordinator
	if err := recordHookActivity(request, readonly); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "activity")); !os.IsNotExist(err) {
		t.Fatalf("coordinator read created activity: %v", err)
	}
	request.Command = "printf data > output"
	if err := recordHookActivity(request, Result{ShellAnalysis: &ShellAnalysis{OutputWrites: true}}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "activity", "sessions", "child", "shell"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "kind: shell\n") {
		t.Fatalf("activity=%q", data)
	}
}

func TestHookContextDependencyAndRootAlias(t *testing.T) {
	root, cwd := contextFixture(t)
	contextMarker(t, root, "owner", cwd)
	alias := filepath.Join(t.TempDir(), "proof")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_PROOF_ROOT", alias)
	dependency := t.TempDir()
	data := "schema: eci-additional-repository/v1\nsession_id: owner\ncwd: " + cwd + "\nrepository: " + dependency + "\nreason: fix dependency\nstate: active\n"
	if err := os.WriteFile(filepath.Join(root, "owner", "eci-additional-repository"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := hookRequest(HookInput{SessionID: "owner", CWD: dependency})
	if err != nil {
		t.Fatal(err)
	}
	canonicalDependency, err := hookCanonicalPath(dependency)
	if err != nil {
		t.Fatal(err)
	}
	canonicalRoot, err := hookCanonicalPath(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.ApprovedRoots) != 2 || got.ApprovedRoots[1] != canonicalDependency || got.ActiveMarkers[0] != filepath.Join(canonicalRoot, "owner", "eci_active") {
		t.Fatalf("context=%+v", got)
	}
}

func TestHookContextOversizedFirstRecordTail(t *testing.T) {
	root, cwd := contextFixture(t)
	contextMarker(t, root, "parent", cwd)
	transcript := filepath.Join(t.TempDir(), "transcript.jsonl")
	metadata := `{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}},"tail":"` + strings.Repeat("x", 2<<20) + `"}}`
	if err := os.WriteFile(transcript, []byte(metadata), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := hookRequest(HookInput{SessionID: "child", CWD: cwd, TranscriptPath: transcript})
	if err != nil {
		t.Fatal(err)
	}
	if got.ActiveSession != "parent" || got.Role != RoleWorker {
		t.Fatalf("context=%+v", got)
	}
}

func TestHookContextTouchedBaseline(t *testing.T) {
	root, cwd := contextFixture(t)
	if output, err := exec.Command("git", "-C", cwd, "init").CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v: %s", err, output)
	}
	request := Request{Role: RoleWorker, ActiveSession: "owner", HookSessionID: "child", CWD: cwd, Command: "printf data > output"}
	result := Result{ShellAnalysis: &ShellAnalysis{OutputWrites: true}}
	if err := recordHookActivity(request, result); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "touched-repos", "sessions", "child"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("records=%d", len(entries))
	}
	data, err := os.ReadFile(filepath.Join(root, "touched-repos", "sessions", "child", entries[0].Name()))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "status_sha: ") || !strings.Contains(string(data), "head: \n") || !strings.Contains(string(data), "repo_wide: true\n") {
		t.Fatalf("baseline=%q", data)
	}
	if _, err := os.Stat(filepath.Join(root, "touched-repos", "sessions", "owner")); !os.IsNotExist(err) {
		t.Fatalf("parent state created: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "activity")); !os.IsNotExist(err) {
		t.Fatalf("worker mutation created activity: %v", err)
	}
}

func TestHookContextDirectOwnerBeyondPeerCap(t *testing.T) {
	root, cwd := contextFixture(t)
	for index := 0; index < 65; index++ {
		contextMarker(t, root, fmt.Sprintf("aaa-%02d", index), cwd)
	}
	contextMarker(t, root, "zzz-owner", cwd)
	request, err := hookRequest(HookInput{SessionID: "zzz-owner", CWD: cwd})
	if err != nil {
		t.Fatal(err)
	}
	if request.Marker != MarkerActive || request.ActiveSession != "zzz-owner" {
		t.Fatalf("direct owner hidden: %+v", request)
	}
	if !hookReadonlyCommand(ShellCommandRecord{Argv: []string{"git", "-C", cwd, "diff"}}) || hookReadonlyCommand(ShellCommandRecord{Argv: []string{"git", "add", "diff"}}) {
		t.Fatal("git arguments confused with command verb")
	}
}

func TestHookContextTypedDependencyTouched(t *testing.T) {
	root, cwd := contextFixture(t)
	dependency := t.TempDir()
	if output, err := exec.Command("git", "-C", dependency, "init").CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v: %s", err, output)
	}
	request := Request{Role: RoleWorker, ActiveSession: "parent", HookSessionID: "child", CWD: cwd}
	analysis := &ShellAnalysis{Commands: []ShellCommandRecord{{Argv: []string{"eci-worker-git", "--repo", dependency, "inspect"}}}}
	if err := recordHookActivity(request, Result{ShellAnalysis: analysis}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "touched-repos")); !os.IsNotExist(err) {
		t.Fatalf("inspect touched dependency: %v", err)
	}
	analysis.Commands[0].Argv[3] = "stage"
	if err := recordHookActivity(request, Result{ShellAnalysis: analysis}); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "touched-repos", "sessions", "child"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("touched=%d", len(entries))
	}
	data, err := os.ReadFile(filepath.Join(root, "touched-repos", "sessions", "child", entries[0].Name()))
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := hookCanonicalPath(dependency)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "repo: "+canonical+"\n") {
		t.Fatalf("wrong repository: %q", data)
	}
}

func TestHookContextAssignmentReadonly(t *testing.T) {
	if !hookReadonlyCommand(ShellCommandRecord{Argv: []string{"KEY=value", "cat", "ordinary"}}) {
		t.Fatal("assignment-prefixed read marked mutable")
	}
	if hookReadonlyCommand(ShellCommandRecord{Argv: []string{"KEY=value", "git", "add", "ordinary"}}) {
		t.Fatal("assignment-prefixed mutation marked readonly")
	}
}
