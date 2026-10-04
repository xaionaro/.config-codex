package main

import (
	"bytes"
	"os"
	"path/filepath"
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
