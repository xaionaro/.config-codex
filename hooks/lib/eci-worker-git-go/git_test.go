package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestStageRemovalsRequiresExactTrackedEntries rejects recursive directory selection.
//
// Example: naming a removed directory cannot stage both descendant removals.
func TestStageRemovalsRequiresExactTrackedEntries(t *testing.T) {
	root := fixtureRepository(t)
	if err := os.Mkdir(filepath.Join(root, "removed-dir"), 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "b"} {
		if err := os.WriteFile(filepath.Join(root, "removed-dir", name), []byte("base\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	fixtureGit(t, root, "add", "--", "removed-dir")
	index := fixtureGit(t, root, "write-tree")
	if err := os.RemoveAll(filepath.Join(root, "removed-dir")); err != nil {
		t.Fatal(err)
	}
	if err := executeFixtureOperation(t, root, "stage-removals", "--", "removed-dir"); err == nil {
		t.Fatal("directory removal swept unnamed descendants")
	}
	if fixtureGit(t, root, "write-tree") != index {
		t.Fatal("directory rejection changed index")
	}
	if err := executeFixtureOperation(t, root, "stage-removals", "--", "removed-dir/a"); err != nil {
		t.Fatal(err)
	}
	if fixtureGit(t, root, "show", ":removed-dir/b") != "base" {
		t.Fatal("exact removal changed sibling")
	}
}

// TestFixedMutationOperationsPreserveUnselectedState exercises every remaining named effect.
//
// Example: index-only removal cannot delete the corresponding live file.
func TestFixedMutationOperationsPreserveUnselectedState(t *testing.T) {
	for _, kind := range []string{"stage-removals", "restore-index", "restore-worktree", "restore-both", "remove-index", "remove-worktree", "remove-both", "move", "commit"} {
		t.Run(kind, func(t *testing.T) {
			root := fixtureRepository(t)
			head := fixtureGit(t, root, "rev-parse", "HEAD")
			unrelated := fixtureGit(t, root, "show", ":unrelated.txt")
			var arguments []string
			switch kind {
			case "stage-removals":
				if err := os.Remove(filepath.Join(root, "file.txt")); err != nil {
					t.Fatal(err)
				}
				arguments = []string{"stage-removals", "--", "file.txt"}
			case "restore-index", "restore-worktree", "restore-both":
				if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("changed\n"), 0644); err != nil {
					t.Fatal(err)
				}
				fixtureGit(t, root, "add", "--", "file.txt")
				destination := kind[len("restore-"):]
				arguments = []string{"restore", "--source", "head", "--destination", destination, "--", "file.txt"}
			case "remove-index", "remove-worktree", "remove-both":
				arguments = []string{"remove", "--destination", kind[len("remove-"):], "--", "file.txt"}
			case "move":
				arguments = []string{"move", "--", "file.txt", "moved.txt"}
			case "commit":
				if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("changed\n"), 0644); err != nil {
					t.Fatal(err)
				}
				fixtureGit(t, root, "add", "--", "file.txt")
				arguments = []string{"commit", "--message", "prepared index checkpoint"}
			}
			if err := executeFixtureOperation(t, root, arguments...); err != nil {
				t.Fatal(err)
			}
			if fixtureGit(t, root, "show", ":unrelated.txt") != unrelated {
				t.Fatal("unselected index changed")
			}
			content, fileErr := os.ReadFile(filepath.Join(root, "file.txt"))
			switch kind {
			case "remove-index":
				if fileErr != nil || string(content) != "base\n" {
					t.Fatal("index removal changed live file")
				}
				if fixtureGit(t, root, "ls-files", "--", "file.txt") != "" {
					t.Fatal("index removal kept entry")
				}
			case "stage-removals", "remove-worktree", "remove-both", "move":
				if !os.IsNotExist(fileErr) {
					t.Fatalf("expected absent original: %v", fileErr)
				}
			case "restore-index":
				if fileErr != nil || string(content) != "changed\n" || fixtureGit(t, root, "show", ":file.txt") != "base" {
					t.Fatal("index restore changed worktree or missed index")
				}
			case "restore-worktree", "restore-both":
				if fileErr != nil || string(content) != "base\n" {
					t.Fatal("worktree restoration missed content")
				}
			case "commit":
				if fixtureGit(t, root, "show", "HEAD:file.txt") != "changed" || fixtureGit(t, root, "rev-parse", "HEAD^") != head {
					t.Fatal("prepared commit did not append expected content")
				}
			}
			if kind != "commit" && fixtureGit(t, root, "rev-parse", "HEAD") != head {
				t.Fatal("unexpected HEAD mutation")
			}
			if kind == "move" && fixtureGit(t, root, "show", ":moved.txt") != "base" {
				t.Fatal("move missed destination")
			}
			if kind == "remove-worktree" && fixtureGit(t, root, "show", ":file.txt") != "base" {
				t.Fatal("worktree removal changed index")
			}
		})
	}
}

// TestStageHunksChecksEntireFrozenPatch preserves unnamed staged entries and worktree content.
//
// Example: a patch that includes an unlisted file is rejected before index mutation.
func TestStageHunksChecksEntireFrozenPatch(t *testing.T) {
	root := fixtureRepository(t)
	patch := filepath.Join(t.TempDir(), "selected.patch")
	if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("changed\n"), 0644); err != nil {
		t.Fatal(err)
	}
	diff := fixtureGit(t, root, "diff", "--", "file.txt") + "\n"
	if err := os.WriteFile(patch, []byte(diff), 0600); err != nil {
		t.Fatal(err)
	}
	if err := executeFixtureOperation(t, root, "stage-hunks", "--patch-file", patch, "--", "file.txt"); err != nil {
		t.Fatal(err)
	}
	if fixtureGit(t, root, "show", ":file.txt") != "changed" {
		t.Fatal("patch missed index")
	}
	index := fixtureGit(t, root, "write-tree")
	if err := os.WriteFile(filepath.Join(root, "unrelated.txt"), []byte("unlisted\n"), 0644); err != nil {
		t.Fatal(err)
	}
	diff = fixtureGit(t, root, "diff", "--", "unrelated.txt") + "\n"
	if err := os.WriteFile(patch, []byte(diff), 0600); err != nil {
		t.Fatal(err)
	}
	if err := executeFixtureOperation(t, root, "stage-hunks", "--patch-file", patch, "--", "file.txt"); err == nil {
		t.Fatal("unlisted patch admitted")
	}
	if fixtureGit(t, root, "write-tree") != index {
		t.Fatal("rejected patch changed index")
	}
}

// TestStageHunksRejectsUnlistedRenameSource includes both endpoints in patch ownership.
//
// Example: naming only the destination cannot authorize removal of the old index entry.
func TestStageHunksRejectsUnlistedRenameSource(t *testing.T) {
	root := fixtureRepository(t)
	fixtureGit(t, root, "mv", "--", "file.txt", "renamed.txt")
	diff := fixtureGit(t, root, "diff", "--cached", "--find-renames", "HEAD") + "\n"
	fixtureGit(t, root, "restore", "--source=HEAD", "--staged", "--", "file.txt", "renamed.txt")
	index := fixtureGit(t, root, "write-tree")
	patch := filepath.Join(t.TempDir(), "rename.patch")
	if err := os.WriteFile(patch, []byte(diff), 0600); err != nil {
		t.Fatal(err)
	}
	if err := executeFixtureOperation(t, root, "stage-hunks", "--patch-file", patch, "--", "renamed.txt"); err == nil {
		t.Fatal("unlisted rename source admitted")
	}
	if fixtureGit(t, root, "write-tree") != index {
		t.Fatal("rejected rename patch changed index")
	}
}
