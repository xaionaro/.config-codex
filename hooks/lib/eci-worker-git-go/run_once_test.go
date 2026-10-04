package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestRunOnceRequiresAuthorizationAndReason checks rejection before Git runs.
//
// Example: a whitespace reason never executes the supplied Git alias.
func TestRunOnceRequiresAuthorizationAndReason(t *testing.T) {
	root := fixtureRepository(t)
	marker := filepath.Join(t.TempDir(), "runs")
	t.Setenv("GIT_ONCE_MARKER", marker)
	valid := []string{"--repo", root, "run-once", "--reason", "user approved this alias", "--user-authorized", "--", "-c", `alias.once=!printf x >> "$GIT_ONCE_MARKER"`, "once"}
	var output, diagnostic bytes.Buffer
	streams := Streams{Output: &output, Error: &diagnostic}
	blank := append([]string(nil), valid...)
	blank[4] = " \t\n"
	missingAuthorization := append(append([]string(nil), valid[:5]...), valid[6:]...)
	for _, arguments := range [][]string{blank, missingAuthorization, valid[:7]} {
		if code := Run(arguments, streams); code == 0 {
			t.Fatalf("invalid request succeeded: %q", arguments)
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatalf("invalid request executed Git: %v", err)
		}
	}
	if code := Run(valid, streams); code != 0 {
		t.Fatalf("valid request failed: %d: %s", code, diagnostic.String())
	}
	if content, err := os.ReadFile(marker); err != nil || string(content) != "x" {
		t.Fatalf("expected exactly one invocation: %q: %v", content, err)
	}
}

// TestRunOncePreservesNativeExit checks that Git's exit status survives the CLI.
//
// Example: a Git alias exiting 37 makes the escape invocation exit 37.
func TestRunOncePreservesNativeExit(t *testing.T) {
	root := fixtureRepository(t)
	var output, diagnostic bytes.Buffer
	if code := Run([]string{"--repo", root, "run-once", "--reason", "approved status check", "--user-authorized", "--", "-c", "alias.failure=!exit 37", "failure"}, Streams{Output: &output, Error: &diagnostic}); code != 37 {
		t.Fatalf("native exit changed: %d: %s", code, diagnostic.String())
	}
}
