package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunHookEnvelope(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_PROOF_ROOT", filepath.Join(home, "proof"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "false")
	markerDir := filepath.Join(home, "proof", "hook-envelope")
	if err := os.MkdirAll(markerDir, 0700); err != nil {
		t.Fatal(err)
	}
	marker := "scope: hook envelope\ncwd: /tmp\nsession_id: hook-envelope\ncreated_utc: 2026-10-04T00:00:00Z\n"
	if err := os.WriteFile(filepath.Join(markerDir, "eci_active"), []byte(marker), 0600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name, input string
		denied      bool
	}{
		{"ordinary allow", `{"session_id":"hook-envelope","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"cat ordinary"}}`, false},
		{"concrete root removal", `{"session_id":"hook-envelope","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"rm -rf /"}}`, true},
		{"malformed advisory", `{`, false},
		{"other tool", `{"tool_name":"Read","tool_input":{"command":"rm -rf /"}}`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if status := RunHook(strings.NewReader(test.input), &output); status != 0 {
				t.Fatalf("hook status=%d, want0", status)
			}
			if !test.denied {
				if output.Len() != 0 {
					t.Fatalf("allow output=%q", output.String())
				}
				return
			}
			var envelope struct {
				HookSpecificOutput HookSpecificOutput `json:"hookSpecificOutput"`
			}
			if err := json.Unmarshal(output.Bytes(), &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.HookSpecificOutput.HookEventName != "PreToolUse" || envelope.HookSpecificOutput.PermissionDecision != "deny" || envelope.HookSpecificOutput.PermissionDecisionReason == "" {
				t.Fatalf("invalid hook denial: %s", &output)
			}
		})
	}
}

func TestHookGitDefaultsPreserveAllCommandEffects(t *testing.T) {
	tests := []struct {
		name    string
		command string
		denied  bool
	}{
		{"diff options", "git diff --output=ordinary.patch", false},
		{"log options", "git log --all --format=%H", false},
		{"other verb", "git fsck --lost-found", false},
		{"harmless find action", "find . -exec cat '{}' ';'", false},
		{"long concrete effect", "printf '%s' '" + strings.Repeat("x", maxCommandBytes) + "'; rm -rf /", true},
		{"many concrete effects", strings.Repeat("printf ok;", maxSegments+1) + "rm -rf /", true},
		{"compound concrete effect", "git diff --output=ordinary.patch; rm -rf /", true},
		{"nested concrete effect", "git diff; bash -c 'rm -rf /'", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := Request{Provider: ProviderCodex, Role: RoleCoordinator, CWD: t.TempDir(), Marker: MarkerActive, ActiveSession: "hook-test", Command: test.command, HookMode: true, CollectShellCommands: true}
			result := Classify(request)
			if got := result.Decision == DecisionDeny; got != test.denied {
				t.Fatalf("denied=%v, want %v: %#v", got, test.denied, result)
			}
			if !test.denied && (result.ShellAnalysis == nil || len(result.ShellAnalysis.Commands) == 0) {
				t.Fatal("callback lost command records for native effect routing")
			}
		})
	}
}

func TestHookOutputWritesReuseParsedEffects(t *testing.T) {
	for _, test := range []struct {
		command string
		writes  bool
	}{
		{"cat 'a>b'", false},
		{"printf note > ordinary", true},
		{"cat ordinary 2>&1", false},
		{"bash -c 'printf note >> ordinary'", true},
	} {
		request := Request{Provider: ProviderCodex, Role: RoleCoordinator, CWD: t.TempDir(), Marker: MarkerInactive, Command: test.command, HookMode: true, CollectShellCommands: true}
		result := Classify(request)
		if result.ShellAnalysis == nil || result.ShellAnalysis.OutputWrites != test.writes {
			t.Fatalf("command=%q output writes=%#v want %v", test.command, result.ShellAnalysis, test.writes)
		}
	}
}

func TestHookInactivePermissiveFinalization(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	gate := filepath.Join(home, ".codex", "bin", "eci-command-gate-mode")
	if err := os.MkdirAll(filepath.Dir(gate), 0700); err != nil {
		t.Fatal(err)
	}
	build := exec.Command("go", "build", "-o", gate, ".")
	build.Dir = filepath.Join("..", "eci-command-gate-mode-go")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build optional finalizer: %v: %s", err, output)
	}
	t.Setenv("HOME", home)
	t.Setenv("CODEX_PROOF_ROOT", filepath.Join(home, "proof"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "true")
	config := filepath.Join(home, "config", "eci", "command-gate-mode")
	if err := os.MkdirAll(filepath.Dir(config), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config, []byte("permissive\n"), 0600); err != nil {
		t.Fatal(err)
	}
	input := HookInput{SessionID: "inactive", CWD: home, ToolName: "Bash"}
	input.ToolInput.Command = "'" + gate + "' set enforcing"
	callback, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if status := RunHook(bytes.NewReader(callback), &output); status != 0 || output.Len() != 0 {
		t.Fatalf("inactive permissive callback status=%d output=%s", status, &output)
	}
	if err := os.WriteFile(config, []byte("enforcing\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if status := RunHook(bytes.NewReader(callback), &output); status != 0 || !strings.Contains(output.String(), `"permissionDecision":"deny"`) {
		t.Fatalf("inactive enforcing callback status=%d output=%s", status, &output)
	}
	if !strings.Contains(output.String(), string(CodeControlOwnerRequired)) {
		t.Fatalf("resolved worker control effect lost its ownership diagnostic: %s", &output)
	}
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "false")
	output.Reset()
	if status := RunHook(bytes.NewReader(callback), &output); status != 0 || output.Len() != 0 {
		t.Fatalf("quoted coordinator control target denied: status=%d output=%s", status, &output)
	}
}

func TestHookAnalysisNeverExecutesTimeout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_PROOF_ROOT", filepath.Join(home, "proof"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "true")
	t.Setenv("PATH", home+":/usr/bin:/bin")
	sentinel := filepath.Join(home, "wrapper-executed")
	if err := os.WriteFile(filepath.Join(home, "timeout"), []byte("#!/bin/sh\nprintf called > '"+sentinel+"'\nexec /usr/bin/timeout \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	markerDir := filepath.Join(home, "proof", "timeout-owner")
	if err := os.MkdirAll(markerDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(markerDir, "eci_active"), []byte("scope: callback\ncwd: "+home+"\nsession_id: timeout-owner\n"), 0600); err != nil {
		t.Fatal(err)
	}
	input := HookInput{SessionID: "timeout-owner", CWD: home, ToolName: "Bash"}
	input.ToolInput.Command = "timeout 5 git add ordinary"
	callback, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if status := RunHook(bytes.NewReader(callback), &output); status != 0 || !strings.Contains(output.String(), string(CodeWorkerGitOwnershipDenied)) {
		t.Fatalf("finite timeout child lost ownership effect: status=%d output=%s", status, &output)
	}
	if _, err := os.Stat(sentinel); !os.IsNotExist(err) {
		t.Fatalf("callback executed inspected timeout wrapper: %v", err)
	}
}

func TestHookBookkeepingUsesNativeGit(t *testing.T) {
	home := t.TempDir()
	if output, err := exec.Command("/usr/bin/git", "-C", home, "init").CombinedOutput(); err != nil {
		t.Fatalf("init fixture: %v: %s", err, output)
	}
	t.Setenv("HOME", home)
	t.Setenv("CODEX_PROOF_ROOT", filepath.Join(home, "proof"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "true")
	t.Setenv("PATH", home+":/usr/bin:/bin")
	sentinel := filepath.Join(home, "git-wrapper-executed")
	if err := os.WriteFile(filepath.Join(home, "git"), []byte("#!/bin/sh\nprintf called > '"+sentinel+"'\nexec /usr/bin/git \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	input := HookInput{SessionID: "mutation", CWD: home, ToolName: "Bash"}
	input.ToolInput.Command = "printf data > ordinary"
	callback, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if status := RunHook(bytes.NewReader(callback), &output); status != 0 || output.Len() != 0 {
		t.Fatalf("owned write denied: status=%d output=%s", status, &output)
	}
	if _, err := os.Stat(sentinel); !os.IsNotExist(err) {
		t.Fatalf("bookkeeping executed PATH git wrapper: %v", err)
	}
}

func TestHookOwnedLinkCleanup(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_PROOF_ROOT", filepath.Join(home, "proof"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("CODEX_HOOK_IS_SUBAGENT", "true")
	markerDir := filepath.Join(home, "proof", "cleanup")
	if err := os.MkdirAll(markerDir, 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(markerDir, "eci_active")
	if err := os.WriteFile(marker, []byte("scope: callback\ncwd: "+home+"\nsession_id: cleanup\n"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "marker-link")
	hardlink := filepath.Join(home, "marker-hardlink")
	if err := os.Symlink(marker, link); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(marker, hardlink); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		command string
		denied  bool
	}{
		{"rm '" + link + "'", false},
		{"rm '" + hardlink + "'", false},
		{"mv '" + link + "' '" + filepath.Join(home, "moved-link") + "'", false},
		{"tee '" + link + "'", true},
		{"tee '" + hardlink + "'", true},
		{"rm '" + marker + "'", true},
	} {
		input := HookInput{SessionID: "cleanup", CWD: home, ToolName: "Bash"}
		input.ToolInput.Command = test.command
		callback, err := json.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		RunHook(bytes.NewReader(callback), &output)
		if got := output.Len() != 0; got != test.denied {
			t.Fatalf("command=%s denied=%v want=%v output=%s", test.command, got, test.denied, &output)
		}
	}
}
