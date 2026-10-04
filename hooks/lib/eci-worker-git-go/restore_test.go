package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// fixtureRestoreAlias creates an exact tracked leaf beneath one owned alias shape.
//
// Example: a regular-file alias blocks dir/nested/file without touching its sentinel.
func fixtureRestoreAlias(
	t *testing.T,
	kind string,
) (string, string, string) {
	t.Helper()
	root := fixtureRepository(t)
	if err := os.MkdirAll(filepath.Join(root, "dir/nested"), 0755); err != nil {
		t.Fatal(err)
	}
	leaf := filepath.Join(root, "dir/nested/file")
	if err := os.WriteFile(leaf, []byte("base\n"), 0644); err != nil {
		t.Fatal(err)
	}
	fixtureGit(t, root, "add", "--", "dir/nested/file")
	fixtureGit(t, root, "commit", "-qm", "nested exact leaf")
	for _, name := range []string{"dir/nested/file", "unrelated.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("staged\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	fixtureGit(t, root, "add", "--", "dir/nested/file", "unrelated.txt")
	if err := os.RemoveAll(filepath.Join(root, "dir")); err != nil {
		t.Fatal(err)
	}
	target, sentinel := "", ""
	switch kind {
	case "file":
		target = "ordinary"
		sentinel = filepath.Join(root, target)
	case "internal", "nested-alias":
		target = "ordinary"
		sentinel = filepath.Join(root, target, "nested/file")
	case "external":
		target = t.TempDir()
		sentinel = filepath.Join(target, "nested/file")
	case "dangling":
		target = "missing"
	case "loop":
		target = "dir"
	default:
		t.Fatalf("unsupported fixture kind %q", kind)
	}
	if sentinel != "" {
		if err := os.MkdirAll(filepath.Dir(sentinel), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(sentinel, []byte("sentinel\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if kind == "nested-alias" {
		if err := os.Rename(filepath.Join(root, "ordinary/nested"), filepath.Join(root, "ordinary/actual")); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("actual", filepath.Join(root, "ordinary/nested")); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(target, filepath.Join(root, "dir")); err != nil {
		t.Fatal(err)
	}
	return root, target, sentinel
}

// TestRestoreAncestorDiagnosisAndRecovery checks the actual owned recovery route and preserved state.
//
// Example: an external-directory alias is named before resolution, moved aside, and restored exactly.
func TestRestoreAncestorDiagnosisAndRecovery(t *testing.T) {
	for _, kind := range []string{"file", "external", "internal", "nested-alias", "dangling", "loop"} {
		// Each shape uses independent worktree, index, HEAD, and sentinel state.
		t.Run(kind, func(t *testing.T) {
			root, target, sentinel := fixtureRestoreAlias(t, kind)
			head := fixtureGit(t, root, "rev-parse", "HEAD")
			branch := fixtureGit(t, root, "symbolic-ref", "HEAD")
			tree := fixtureGit(t, root, "write-tree")
			index, err := os.ReadFile(filepath.Join(root, ".git/index"))
			if err != nil {
				t.Fatal(err)
			}
			err = executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "both", "--", "dir/nested/file")
			diagnostic := ""
			if err != nil {
				diagnostic = err.Error()
			}
			t.Logf("refusal diagnostic: %s", diagnostic)
			if err == nil || !strings.Contains(diagnostic, "dir/nested/file") || !strings.Contains(diagnostic, "ancestor symlink \"dir\"") || !strings.Contains(diagnostic, "mv -- <ancestor> <saved-alias>") || !strings.Contains(diagnostic, "index-only") {
				t.Errorf("missing selected-ancestor diagnostic and bounded route: %v", err)
			}
			if got, err := os.Readlink(filepath.Join(root, "dir")); err != nil || got != target {
				t.Fatalf("refusal changed alias: %q %v", got, err)
			}
			if got, err := os.ReadFile(filepath.Join(root, ".git/index")); err != nil || !bytes.Equal(got, index) {
				t.Fatalf("refusal changed raw index: %v", err)
			}
			if fixtureGit(t, root, "write-tree") != tree || fixtureGit(t, root, "symbolic-ref", "HEAD") != branch || fixtureGit(t, root, "rev-parse", "HEAD") != head {
				t.Fatal("refusal changed semantic index, HEAD, or branch")
			}
			if got, err := os.ReadFile(filepath.Join(root, "unrelated.txt")); err != nil || string(got) != "staged\n" {
				t.Fatalf("refusal changed unrelated worktree: %q %v", got, err)
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "index", "--", "dir/nested/file"); err != nil {
				t.Fatalf("index-only recovery failed: %v", err)
			}
			if got := fixtureGit(t, root, "show", ":dir/nested/file"); got != "base" {
				t.Fatalf("selected index leaf=%q", got)
			}
			if got := fixtureGit(t, root, "show", ":unrelated.txt"); got != "staged" {
				t.Fatalf("unrelated staged leaf=%q", got)
			}
			if err := os.Rename(filepath.Join(root, "dir"), filepath.Join(root, "saved-alias")); err != nil {
				t.Fatal(err)
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file"); err != nil {
				t.Fatalf("owned move-aside recovery failed: %v", err)
			}
			if got, err := os.ReadFile(filepath.Join(root, "dir/nested/file")); err != nil || string(got) != "base\n" {
				t.Fatalf("restored exact leaf=%q %v", got, err)
			}
			if got, err := os.Readlink(filepath.Join(root, "saved-alias")); err != nil || got != target {
				t.Fatalf("saved alias changed: %q %v", got, err)
			}
			if sentinel != "" {
				if got, err := os.ReadFile(sentinel); err != nil || string(got) != "sentinel\n" {
					t.Fatalf("referent changed: %q %v", got, err)
				}
			}
			if fixtureGit(t, root, "rev-parse", "HEAD") != head || fixtureGit(t, root, "symbolic-ref", "HEAD") != branch || fixtureGit(t, root, "show", ":unrelated.txt") != "staged" {
				t.Fatal("recovery changed HEAD or unrelated staged content")
			}
			t.Log("index-only and owned move-aside recovery preserved selected alias spelling, sentinel, HEAD, and unrelated staged entry")
		})
	}
}

// TestRestoreProtectionPrecedesMoveAdvice checks protected lexical roots before recovery advice.
//
// Example: a symlink-spelled configured provider root must not be offered as a movable ancestor.
func TestRestoreProtectionPrecedesMoveAdvice(t *testing.T) {
	for _, kind := range []string{"proof-root-alias", "kimi-proof-root-alias", "provider-root-alias", "configured-provider-root-alias", "kimi-provider-root-alias", "hook-parent-alias"} {
		// Each configured control alias is owned by a private provider fixture.
		t.Run(kind, func(t *testing.T) {
			root := fixtureRepository(t)
			path, alias, target := "", "", ""
			switch kind {
			case "proof-root-alias", "kimi-proof-root-alias":
				var sentinel string
				root, target, sentinel = fixtureRestoreAlias(t, "external")
				if sentinel == "" {
					t.Fatal("missing proof sentinel")
				}
				path, alias = "dir/nested/file", "dir"
				variable := "CODEX_PROOF_ROOT"
				if kind == "kimi-proof-root-alias" {
					variable = "KIMI_PROOF_ROOT"
				}
				t.Setenv(variable, filepath.Join(root, alias))
			case "provider-root-alias", "configured-provider-root-alias", "kimi-provider-root-alias":
				path, alias, target = "runtime-link/hooks/validate-bash.sh", "runtime-link", "physical-runtime"
				if err := os.MkdirAll(filepath.Dir(filepath.Join(root, path)), 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(root, path), []byte("live\n"), 0644); err != nil {
					t.Fatal(err)
				}
				fixtureGit(t, root, "add", "--", path)
				fixtureGit(t, root, "commit", "-qm", "provider alias control")
				if err := os.Rename(filepath.Join(root, alias), filepath.Join(root, target)); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, filepath.Join(root, alias)); err != nil {
					t.Fatal(err)
				}
				variable := "CODEX_HOME"
				switch kind {
				case "configured-provider-root-alias":
					variable = "CODEX_CONFIGURED_HOME"
				case "kimi-provider-root-alias":
					variable = "KIMI_CODE_HOME"
				}
				t.Setenv(variable, filepath.Join(root, alias))
			case "hook-parent-alias":
				path, alias, target = "hooks/validate-bash.sh", "hooks", "physical-hooks"
				if err := os.Rename(filepath.Join(root, alias), filepath.Join(root, target)); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, filepath.Join(root, alias)); err != nil {
					t.Fatal(err)
				}
			}
			head := fixtureGit(t, root, "rev-parse", "HEAD")
			branch := fixtureGit(t, root, "symbolic-ref", "HEAD")
			tree := fixtureGit(t, root, "write-tree")
			sentinel, err := os.ReadFile(filepath.Join(root, path))
			if err != nil {
				t.Fatal(err)
			}
			index, err := os.ReadFile(filepath.Join(root, ".git/index"))
			if err != nil {
				t.Fatal(err)
			}
			err = executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", path)
			diagnostic := ""
			if err != nil {
				diagnostic = err.Error()
			}
			t.Logf("protected diagnostic: %s", diagnostic)
			if err == nil || !strings.Contains(diagnostic, "protected live") || !strings.Contains(diagnostic, "index-only") || strings.Contains(diagnostic, "mv --") || strings.Contains(diagnostic, "move that exact") {
				t.Errorf("protected alias received movable-entry advice: %v", err)
			}
			if got, err := os.Readlink(filepath.Join(root, alias)); err != nil || got != target {
				t.Fatalf("protected alias changed: %q %v", got, err)
			}
			if got, err := os.ReadFile(filepath.Join(root, ".git/index")); err != nil || !bytes.Equal(got, index) {
				t.Fatalf("protected refusal changed raw index: %v", err)
			}
			if got, err := os.ReadFile(filepath.Join(root, path)); err != nil || !bytes.Equal(got, sentinel) {
				t.Fatalf("protected refusal changed sentinel: %v", err)
			}
			if fixtureGit(t, root, "rev-parse", "HEAD") != head || fixtureGit(t, root, "symbolic-ref", "HEAD") != branch || fixtureGit(t, root, "write-tree") != tree {
				t.Fatal("protected refusal changed HEAD, branch, or semantic index")
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "index", "--", path); err != nil {
				t.Fatalf("protected index-only recovery failed: %v", err)
			}
		})
	}
}

// TestRestoreAliasSourcesPreserveTypedSelection checks index and non-HEAD tree recovery.
//
// Example: a staged tree supplies selected content after moving an ordinary file alias aside.
func TestRestoreAliasSourcesPreserveTypedSelection(t *testing.T) {
	for _, sourceKind := range []string{"index", "tree"} {
		// Each source is selected without changing its corresponding stored blobs.
		t.Run(sourceKind, func(t *testing.T) {
			root, target, sentinel := fixtureRestoreAlias(t, "file")
			source := sourceKind
			if sourceKind == "tree" {
				source = fixtureGit(t, root, "write-tree")
				if source == fixtureGit(t, root, "rev-parse", "HEAD^{tree}") {
					t.Fatal("source must differ from HEAD tree")
				}
			}
			head := fixtureGit(t, root, "rev-parse", "HEAD")
			index, err := os.ReadFile(filepath.Join(root, ".git/index"))
			if err != nil {
				t.Fatal(err)
			}
			err = executeFixtureOperation(t, root, "restore", "--source", source, "--destination", "worktree", "--", "dir/nested/file")
			if err == nil || !strings.Contains(err.Error(), "ancestor symlink \"dir\"") {
				t.Fatalf("missing source-specific refusal: %v", err)
			}
			if got, err := os.ReadFile(filepath.Join(root, ".git/index")); err != nil || !bytes.Equal(got, index) {
				t.Fatalf("source refusal changed index: %v", err)
			}
			if err := os.Rename(filepath.Join(root, "dir"), filepath.Join(root, "saved-alias")); err != nil {
				t.Fatal(err)
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", source, "--destination", "worktree", "--", "dir/nested/file"); err != nil {
				t.Fatal(err)
			}
			if got, err := os.ReadFile(filepath.Join(root, "dir/nested/file")); err != nil || string(got) != "staged\n" {
				t.Fatalf("wrong source content: %q %v", got, err)
			}
			if got, err := os.ReadFile(sentinel); err != nil || string(got) != "sentinel\n" {
				t.Fatalf("referent changed: %q %v", got, err)
			}
			if got, err := os.Readlink(filepath.Join(root, "saved-alias")); err != nil || got != target {
				t.Fatalf("saved alias changed: %q %v", got, err)
			}
			if fixtureGit(t, root, "rev-parse", "HEAD") != head || fixtureGit(t, root, "show", ":unrelated.txt") != "staged" {
				t.Fatal("source recovery changed unrelated state")
			}
		})
	}
}

// TestRestoreDisposableAliasesRetainOwnedRecovery protects lexical identities rather than alias referents.
//
// Example: moving a disposable alias beside a configured provider alias preserves the provider's live hook.
func TestRestoreDisposableAliasesRetainOwnedRecovery(t *testing.T) {
	for _, kind := range []string{"physical-proof", "provider-near-prefix", "provider-without-hook"} {
		// Each disposable entry can be moved without changing any protected referent.
		t.Run(kind, func(t *testing.T) {
			root, _, sentinel := fixtureRestoreAlias(t, "internal")
			switch kind {
			case "physical-proof":
				t.Setenv("CODEX_PROOF_ROOT", filepath.Join(root, "ordinary"))
			case "provider-near-prefix":
				if err := os.MkdirAll(filepath.Join(root, "ordinary/hooks"), 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(root, "ordinary/hooks/validate-bash.sh"), []byte("live\n"), 0644); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("ordinary", filepath.Join(root, "dir-protected")); err != nil {
					t.Fatal(err)
				}
				t.Setenv("CODEX_HOME", filepath.Join(root, "dir-protected"))
				t.Setenv("CODEX_CONFIGURED_HOME", filepath.Join(root, "dir-protected"))
			case "provider-without-hook":
				t.Setenv("CODEX_HOME", filepath.Join(root, "dir"))
				t.Setenv("CODEX_CONFIGURED_HOME", filepath.Join(root, "dir"))
			}
			err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file")
			if err == nil || !strings.Contains(err.Error(), "mv -- <ancestor> <saved-alias>") {
				t.Fatalf("disposable entry lost bounded route: %v", err)
			}
			if err := os.Rename(filepath.Join(root, "dir"), filepath.Join(root, "saved-alias")); err != nil {
				t.Fatal(err)
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file"); err != nil {
				t.Fatal(err)
			}
			if got, err := os.ReadFile(sentinel); err != nil || string(got) != "sentinel\n" {
				t.Fatalf("disposable recovery changed referent: %q %v", got, err)
			}
			if kind == "provider-near-prefix" {
				if got, err := os.ReadFile(filepath.Join(root, "dir-protected/hooks/validate-bash.sh")); err != nil || string(got) != "live\n" {
					t.Fatalf("provider hook changed: %q %v", got, err)
				}
			}
		})
	}
}

// TestRestoreProtectsConsumedHookAliases distinguishes traversed entries from shared referents.
//
// Example: a hook using dir/.. consumes dir even when its final referent is outside dir.
func TestRestoreProtectsConsumedHookAliases(t *testing.T) {
	for _, shape := range []string{"relative", "absolute", "chain", "nested", "dotdot", "root-dotdot", "dangling", "loop", "file", "sharing", "near-prefix", "no-hook"} {
		// Each trace runs in an independent exact-leaf fixture.
		t.Run(shape, func(t *testing.T) {
			kind := "internal"
			switch shape {
			case "nested":
				kind = "nested-alias"
			case "dangling", "loop", "file":
				kind = shape
			}
			root, target, sentinel := fixtureRestoreAlias(t, kind)
			hook := filepath.Join(root, "hooks/validate-bash.sh")
			if err := os.Remove(hook); err != nil {
				t.Fatal(err)
			}
			link := "../dir/nested/file"
			consumed := true
			switch shape {
			case "absolute":
				link = root + "/dir/nested/file"
			case "chain":
				if err := os.Symlink("dir/nested/file", filepath.Join(root, "chain")); err != nil {
					t.Fatal(err)
				}
				link = "../chain"
			case "dotdot":
				if err := os.WriteFile(filepath.Join(root, "hook-source"), []byte("live\n"), 0644); err != nil {
					t.Fatal(err)
				}
				link = "../dir/../hook-source"
			case "root-dotdot":
				if err := os.MkdirAll(filepath.Join(root, "runtime/hooks"), 0755); err != nil {
					t.Fatal(err)
				}
				hook = root + "/dir/../runtime/hooks/validate-bash.sh"
				if err := os.WriteFile(hook, []byte("live\n"), 0644); err != nil {
					t.Fatal(err)
				}
				t.Setenv("CODEX_HOME", root+"/dir/../runtime")
				t.Setenv("CODEX_CONFIGURED_HOME", root+"/dir/../runtime")
			case "sharing":
				link = "../ordinary/nested/file"
				consumed = false
			case "near-prefix":
				if err := os.Symlink("ordinary", filepath.Join(root, "dir-longer")); err != nil {
					t.Fatal(err)
				}
				link = "../dir-longer/nested/file"
				consumed = false
			case "no-hook":
				t.Setenv("CODEX_HOME", filepath.Join(root, "dir"))
				t.Setenv("CODEX_CONFIGURED_HOME", filepath.Join(root, "dir"))
				consumed = false
			}
			if shape != "root-dotdot" && shape != "no-hook" {
				if err := os.Symlink(link, hook); err != nil {
					t.Fatal(err)
				}
			}
			var live []byte
			if shape != "dangling" && shape != "loop" && shape != "file" && shape != "no-hook" {
				var err error
				live, err = os.ReadFile(hook)
				if err != nil {
					t.Fatal(err)
				}
			}
			tree := fixtureGit(t, root, "write-tree")
			head := fixtureGit(t, root, "rev-parse", "HEAD")
			branch := fixtureGit(t, root, "symbolic-ref", "HEAD")
			index, err := os.ReadFile(filepath.Join(root, ".git/index"))
			if err != nil {
				t.Fatal(err)
			}
			err = executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "both", "--", "dir/nested/file")
			if err == nil {
				t.Fatal("missing alias refusal")
			}
			if strings.Contains(err.Error(), "protected live") != consumed || strings.Contains(err.Error(), "mv --") == consumed {
				t.Errorf("wrong dependency advice: %v", err)
			}
			if got, err := os.Readlink(filepath.Join(root, "dir")); err != nil || got != target {
				t.Fatalf("alias changed: %q %v", got, err)
			}
			if got, err := os.ReadFile(filepath.Join(root, ".git/index")); err != nil || !bytes.Equal(got, index) {
				t.Fatalf("raw index changed: %v", err)
			}
			if fixtureGit(t, root, "write-tree") != tree || fixtureGit(t, root, "rev-parse", "HEAD") != head || fixtureGit(t, root, "symbolic-ref", "HEAD") != branch {
				t.Fatal("refusal changed repository state")
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "index", "--", "dir/nested/file"); err != nil {
				t.Fatal(err)
			}
			if fixtureGit(t, root, "show", ":dir/nested/file") != "base" || fixtureGit(t, root, "show", ":unrelated.txt") != "staged" {
				t.Fatal("wrong index-only selection")
			}
			if !consumed {
				if err := os.Rename(filepath.Join(root, "dir"), filepath.Join(root, "saved-alias")); err != nil {
					t.Fatal(err)
				}
				if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file"); err != nil {
					t.Fatal(err)
				}
				if got, err := os.ReadFile(sentinel); err != nil || string(got) != "sentinel\n" {
					t.Fatalf("referent changed: %q %v", got, err)
				}
			}
			if live != nil {
				if got, err := os.ReadFile(hook); err != nil || !bytes.Equal(got, live) {
					t.Fatalf("hook disconnected or changed: %v", err)
				}
			}
		})
	}
}

// TestRestorePermissionLimitedHookTracePreservesKnownAliases retains a partial dependency prefix.
//
// Example: inaccessible content leaves an earlier hook alias protected without blocking file.txt.
func TestRestorePermissionLimitedHookTracePreservesKnownAliases(t *testing.T) {
	for _, visitedAlias := range []bool{false, true} {
		// Permissions belong only to this disposable fixture and are restored for cleanup.
		t.Run(strconv.FormatBool(visitedAlias), func(t *testing.T) {
			root, _, _ := fixtureRestoreAlias(t, "internal")
			blocked := filepath.Join(root, "ordinary/inaccessible")
			if err := os.Mkdir(blocked, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(blocked, "source"), []byte("live\n"), 0644); err != nil {
				t.Fatal(err)
			}
			hook := filepath.Join(root, "hooks/validate-bash.sh")
			if err := os.Remove(hook); err != nil {
				t.Fatal(err)
			}
			target := "../ordinary/inaccessible/source"
			if visitedAlias {
				target = "../dir/inaccessible/source"
			}
			if err := os.Symlink(target, hook); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(blocked, 0000); err != nil {
				t.Fatal(err)
			}
			// Restore owned permissions even if the assertions fail.
			t.Cleanup(func() {
				if err := os.Chmod(blocked, 0755); err != nil {
					t.Error(err)
				}
			})
			if _, err := os.Lstat(filepath.Join(blocked, "source")); !errors.Is(err, os.ErrPermission) {
				t.Skipf("permission boundary unavailable: %v", err)
			}
			if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("changed\n"), 0644); err != nil {
				t.Fatal(err)
			}
			if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "file.txt"); err != nil {
				t.Fatalf("unrelated restore blocked: %v", err)
			}
			if got, err := os.ReadFile(filepath.Join(root, "file.txt")); err != nil || string(got) != "base\n" {
				t.Fatalf("unrelated content incorrect: %q %v", got, err)
			}
			if visitedAlias {
				err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file")
				if err == nil || !strings.Contains(err.Error(), "protected live") || strings.Contains(err.Error(), "mv --") {
					t.Fatalf("known prefix lost protection: %v", err)
				}
				if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "index", "--", "dir/nested/file"); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

// TestRestoreIgnoresCleanedHookDecoy follows raw configured roots through symlink-sensitive dotdot.
//
// Example: portal/../runtime names an external live runtime while its cleaned spelling has a decoy.
func TestRestoreIgnoresCleanedHookDecoy(t *testing.T) {
	root, _, sentinel := fixtureRestoreAlias(t, "internal")
	external := t.TempDir()
	for _, directory := range []string{filepath.Join(external, "sub"), filepath.Join(external, "runtime/hooks"), filepath.Join(root, "runtime/hooks")} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(external, "sub"), filepath.Join(root, "portal")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(external, "runtime/hooks/validate-bash.sh"), []byte("actual hook\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../dir/nested/file", filepath.Join(root, "runtime/hooks/validate-bash.sh")); err != nil {
		t.Fatal(err)
	}
	rawRoot := root + "/portal/../runtime"
	t.Setenv("CODEX_HOME", rawRoot)
	t.Setenv("CODEX_CONFIGURED_HOME", rawRoot)
	hook := rawRoot + "/hooks/validate-bash.sh"
	if got, err := os.ReadFile(hook); err != nil || string(got) != "actual hook\n" {
		t.Fatalf("wrong actual hook: %q %v", got, err)
	}
	err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file")
	if err == nil || !strings.Contains(err.Error(), "mv --") || strings.Contains(err.Error(), "protected live") {
		t.Fatalf("cleaned decoy protected disposable entry: %v", err)
	}
	if err := os.Rename(filepath.Join(root, "dir"), filepath.Join(root, "saved-alias")); err != nil {
		t.Fatal(err)
	}
	if err := executeFixtureOperation(t, root, "restore", "--source", "head", "--destination", "worktree", "--", "dir/nested/file"); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(hook); err != nil || string(got) != "actual hook\n" {
		t.Fatalf("actual hook changed: %q %v", got, err)
	}
	if got, err := os.ReadFile(sentinel); err != nil || string(got) != "sentinel\n" {
		t.Fatalf("referent changed: %q %v", got, err)
	}
}

// TestRestoreNestedHookDependencyKeepsSharingAliasMovable protects a visited nested entry only.
//
// Example: ordinary/nested is consumed by a hook while ordinary/share names the same directory independently.
func TestRestoreNestedHookDependencyKeepsSharingAliasMovable(t *testing.T) {
	root, _, _ := fixtureRestoreAlias(t, "nested-alias")
	hook := filepath.Join(root, "hooks/validate-bash.sh")
	if err := os.Remove(hook); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../dir/nested/file", hook); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("actual", filepath.Join(root, "ordinary/share")); err != nil {
		t.Fatal(err)
	}
	paths, err := liveProtectedPaths()
	if err != nil {
		t.Fatal(err)
	}
	for _, probe := range []struct {
		name     string
		consumed bool
	}{{"ordinary/nested/file", true}, {"ordinary/share/file", false}} {
		err := (Repository{Worktree: root}).checkRestoreAncestors(probe.name, paths)
		if err == nil || strings.Contains(err.Error(), "protected live") != probe.consumed || strings.Contains(err.Error(), "mv --") == probe.consumed {
			t.Fatalf("nested identity classification %q: %v", probe.name, err)
		}
	}
}

// TestLiveDependenciesRetainUnexpectedErrorContext preserves unknown filesystem errors.
//
// Example: an invalid native component wraps its PathError rather than returning a successful partial trace.
func TestLiveDependenciesRetainUnexpectedErrorContext(t *testing.T) {
	root := t.TempDir()
	path := root + "/\x00"
	_, err := livePathDependencies(path)
	var pathError *os.PathError
	if err == nil || !strings.Contains(err.Error(), "inspect live dependency") || !errors.As(err, &pathError) {
		t.Fatalf("unexpected inspection error lost context: %v", err)
	}
	if _, err := livePathDependencies("relative/path"); err == nil {
		t.Fatal("relative path silently admitted")
	}
}
