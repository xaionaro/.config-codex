package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// Streams provides operation IO without storing process-global streams in repository state.
//
// Example: a private fixture captures output while native Git retains its diagnostics.
type Streams struct {
	Input  io.Reader
	Output io.Writer
	Error  io.Writer
}

// ExecuteOperation validates literal targets before running a fixed Git operation.
//
// Example: unstage changes named index entries without touching worktree content.
func ExecuteOperation(
	ctx context.Context,
	operation Operation,
	streams Streams,
) error {
	repository, err := ResolveRepository(ctx, operation.Repo)
	if err != nil {
		return err
	}
	worktreeWrite := operation.Kind == Move ||
		((operation.Kind == Restore || operation.Kind == Remove) && operation.Destination != IndexDestination)
	if err := repository.CheckPaths(operation.Paths, worktreeWrite); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(streams.Output, "eci-worker-git: worktree=%q gitdir=%q index=%q\n", repository.Worktree, repository.GitDir, repository.Index); err != nil {
		return fmt.Errorf("report repository identity before operation: %w", err)
	}
	arguments := []string{}
	switch operation.Kind {
	case StageContent:
		for _, path := range operation.Paths {
			info, err := os.Lstat(repository.Worktree + "/" + path)
			if err != nil {
				return fmt.Errorf("stage-content requires existing leaf %q: %w", path, err)
			}
			if info.IsDir() {
				return fmt.Errorf("stage-content requires exact file or symlink names, not directory %q", path)
			}
		}
		arguments = []string{"add", "--"}
	case Unstage:
		head := repository.Command(ctx, "rev-parse", "--verify", "--quiet", "HEAD")
		if err := head.Run(); err != nil {
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				return fmt.Errorf("unstage HEAD lookup: %w", err)
			}
			branch, branchErr := repository.Command(ctx, "symbolic-ref", "--quiet", "HEAD").Output()
			if branchErr != nil {
				return fmt.Errorf("unstage unborn branch lookup: %w", branchErr)
			}
			branchName := string(bytes.TrimSuffix(branch, []byte("\n")))
			if branchName == "" {
				return fmt.Errorf("unstage has no known unborn branch")
			}
			refErr := repository.Command(ctx, "show-ref", "--verify", "--quiet", branchName).Run()
			if !errors.As(refErr, &exit) || exit.ExitCode() != 1 {
				return fmt.Errorf("unstage requires an existing HEAD or proven unborn branch")
			}
			arguments = []string{"rm", "--cached", "--ignore-unmatch", "--"}
			break
		}
		arguments = []string{"restore", "--source=HEAD", "--staged", "--"}
	case StageRemovals:
		for _, path := range operation.Paths {
			if _, err := os.Lstat(filepath.Join(repository.Worktree, path)); !os.IsNotExist(err) {
				return fmt.Errorf("stage-removals requires an absent worktree path: %q", path)
			}
			selected, err := repository.Command(ctx, "ls-files", "-z", "--error-unmatch", "--", path).Output()
			if err != nil {
				return fmt.Errorf("stage-removals requires an exact tracked entry %q: %w", path, err)
			}
			for _, name := range bytes.Split(bytes.TrimSuffix(selected, []byte{0}), []byte{0}) {
				if string(name) != path {
					return fmt.Errorf("stage-removals rejects directory selection %q; name each removed entry", path)
				}
			}
		}
		arguments = []string{"add", "-u", "--"}
	case StageHunks:
		return repository.ApplySelectedPatch(ctx, operation, streams)
	case Restore:
		arguments = []string{"restore", "--no-recurse-submodules"}
		if operation.Source != IndexSource {
			source := operation.TreeOID
			if operation.Source == HeadSource {
				source = "HEAD"
			}
			arguments = append(arguments, "--source="+source)
		}
		switch operation.Destination {
		case IndexDestination:
			arguments = append(arguments, "--staged")
		case WorktreeDestination:
			arguments = append(arguments, "--worktree")
		case BothDestination:
			arguments = append(arguments, "--staged", "--worktree")
		}
		arguments = append(arguments, "--")
	case Remove:
		switch operation.Destination {
		case IndexDestination:
			arguments = []string{"rm", "--cached", "--force", "-r", "--"}
		case BothDestination:
			arguments = []string{"rm", "--force", "-r", "--"}
		case WorktreeDestination:
			for _, path := range operation.Paths {
				if err := os.RemoveAll(filepath.Join(repository.Worktree, path)); err != nil {
					return fmt.Errorf("remove worktree path %q: %w", path, err)
				}
			}
			return nil
		}
	case Move:
		if _, err := os.Lstat(filepath.Join(repository.Worktree, operation.Paths[1])); !os.IsNotExist(err) {
			return fmt.Errorf("move requires an absent exact destination: %q", operation.Paths[1])
		}
		arguments = []string{"mv", "--"}
	case Commit:
		arguments = []string{"commit", "--message", operation.Message}
	default:
		return fmt.Errorf("unsupported operation kind")
	}
	arguments = append(arguments, operation.Paths...)
	command := repository.Command(ctx, arguments...)
	command.Stdin, command.Stdout, command.Stderr = streams.Input, streams.Output, streams.Error
	if err := command.Run(); err != nil {
		return fmt.Errorf("fixed Git operation failed: %w", err)
	}
	return nil
}

// ApplySelectedPatch freezes patch bytes and verifies every native-selected index target.
//
// Example: an extra unnamed patch file is rejected before the index is touched.
func (r Repository) ApplySelectedPatch(
	ctx context.Context,
	operation Operation,
	streams Streams,
) (_err error) {
	info, err := os.Stat(operation.PatchFile)
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("patch input must be an existing regular file")
	}
	patch, err := os.ReadFile(operation.PatchFile)
	if err != nil {
		return fmt.Errorf("read selected patch: %w", err)
	}
	temporary, err := os.MkdirTemp(r.GitDir, ".eci-worker-git-index-")
	if err != nil {
		return fmt.Errorf("create patch index preview: %w", err)
	}
	defer func() { _err = errors.Join(_err, os.RemoveAll(temporary)) }()
	preview := r
	preview.Index = filepath.Join(temporary, "index")
	index, err := os.ReadFile(r.Index)
	switch {
	case err == nil:
		if err := os.WriteFile(preview.Index, index, 0600); err != nil {
			return err
		}
	case errors.Is(err, os.ErrNotExist):
		if err := preview.Command(ctx, "read-tree", "--empty").Run(); err != nil {
			return err
		}
	default:
		return fmt.Errorf("read patch starting index: %w", err)
	}
	baseline, err := preview.Command(ctx, "write-tree").Output()
	if err != nil {
		return fmt.Errorf("read preview starting tree: %w", err)
	}
	apply := preview.Command(ctx, "apply", "--cached", "-")
	apply.Stdin = bytes.NewReader(patch)
	apply.Stdout, apply.Stderr = streams.Output, streams.Error
	if err := apply.Run(); err != nil {
		return fmt.Errorf("preview patch: %w", err)
	}
	query := preview.Command(ctx, "diff", "--cached", "--no-renames", "--name-only", "-z", string(bytes.TrimSuffix(baseline, []byte("\n"))), "--")
	output, err := query.Output()
	if err != nil {
		return fmt.Errorf("read complete preview selection: %w", err)
	}
	allowed := make(map[string]bool, len(operation.Paths))
	for _, name := range operation.Paths {
		allowed[name] = true
	}
	records := bytes.Split(output, []byte{0})
	if len(records) < 2 || len(records[len(records)-1]) != 0 {
		return fmt.Errorf("patch has no complete changed target selection")
	}
	for _, name := range records[:len(records)-1] {
		if !allowed[string(name)] {
			return fmt.Errorf("patch selects an unlisted target: %q", name)
		}
	}
	for _, arguments := range [][]string{{"apply", "--cached", "--check", "-"}, {"apply", "--cached", "-"}} {
		command := r.Command(ctx, arguments...)
		command.Stdin = bytes.NewReader(patch)
		command.Stdout, command.Stderr = streams.Output, streams.Error
		if err := command.Run(); err != nil {
			return fmt.Errorf("apply selected index patch: %w", err)
		}
	}
	return nil
}
