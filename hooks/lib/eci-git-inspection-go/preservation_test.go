package main

import (
	"crypto/sha256"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"testing"
)

// repositoryEntry preserves a byte and metadata snapshot independent of directory enumeration.
//
// Example: native notes-cache and index writes change the hash or modification time.
type repositoryEntry struct {
	Mode     os.FileMode
	Modified int64
	Hash     [32]byte
}

// snapshotRepository records original worktree, index, references, objects and caches.
//
// Example: compare a snapshot before and after observer execution to detect original writes.
func snapshotRepository(
	root string,
) (map[string]repositoryEntry, error) {
	entries := map[string]repositoryEntry{}
	if err := snapshotDirectory(root, root, entries); err != nil {
		return nil, err
	}
	return entries, nil
}

// snapshotDirectory adds exact regular fixture entries while preserving original file modes and mtimes.
//
// Example: directory metadata detects newly created or removed Git administration entries.
func snapshotDirectory(
	root string,
	directory string,
	snapshot map[string]repositoryEntry,
) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		record := repositoryEntry{Mode: info.Mode(), Modified: info.ModTime().UnixNano()}
		switch {
		case entry.IsDir():
			if err := snapshotDirectory(root, path, snapshot); err != nil {
				return err
			}
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			record.Hash = sha256.Sum256(data)
		default:
			return fmt.Errorf("unmodeled fixture entry %s", relative)
		}
		snapshot[relative] = record
	}
	return nil
}

// TestOriginalRepositoryStatePreserved falsifies original writes across every admitted helper family.
//
// Example: observation leaves worktree, index, refs, objects and textconv caches unchanged.
func TestOriginalRepositoryStatePreserved(t *testing.T) {
	in, helper, marker := fixture(t)
	runFixture(t, in, "config", "diff.sample.cachetextconv", "true")
	runFixture(t, in, "show", "--textconv", "HEAD:file.txt")
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	before, err := snapshotRepository(in.CWD)
	if err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"diff", "-Sabsent", "--name-only", "--", "file.txt"},
		{"log", "-U3", "--", "file.txt"},
		{"show", "--textconv", "HEAD:file.txt"},
		{"grep", "--threads=4", "--textconv", "new", "--", "file.txt"},
		{"-c", "core.fsmonitor=" + helper + " monitor", "status", "--short"},
		{"-c", "diff.external=" + helper + " external", "diff", "--", "file.txt"},
		{"diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"},
	} {
		in.Arguments = args
		got := Inspect(in)
		if got.Result != Helper && got.Result != NoHelper {
			t.Fatalf("args %v got %+v", args, got)
		}
		after, err := snapshotRepository(in.CWD)
		if err != nil {
			t.Fatal(err)
		}
		if !maps.Equal(before, after) {
			t.Fatalf("original repository modified by %v", args)
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("observer executed helper")
		}
	}
}
