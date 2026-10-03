package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestNativeUnsupportedAdministration pairs ordinary discovery with unsupported native layouts.
//
// Example: a native split index is rejected without entering a configured converter.
func TestNativeUnsupportedAdministration(t *testing.T) {
	for _, kind := range []string{"linked-worktree", "split-index", "malformed-config", "trace-config", "bare", "sparse", "promisor", "symlink", "missing-path-helper", "bad-revision"} {
		// Each fixture first establishes the admitted counterpart.
		t.Run(kind, func(t *testing.T) {
			in, _, marker := fixture(t)
			in.Arguments = []string{"diff"}
			if got := Inspect(in); got.Result != Helper {
				t.Fatalf("ordinary counterpart: %+v", got)
			}
			switch kind {
			case "linked-worktree":
				linked := filepath.Join(filepath.Dir(in.CWD), "linked")
				runFixture(t, in, "worktree", "add", "--detach", linked, "HEAD")
				in.CWD = linked
			case "split-index":
				runFixture(t, in, "update-index", "--split-index")
			case "malformed-config":
				if err := os.WriteFile(filepath.Join(in.CWD, ".git", "config"), []byte("[broken\n"), 0600); err != nil {
					t.Fatal(err)
				}
			case "trace-config":
				runFixture(t, in, "config", "trace2.eventtarget", marker)
			case "bare":
				in.Arguments = []string{"-c", "core.bare=true", "diff"}
			case "sparse":
				in.Arguments = []string{"-c", "core.sparseCheckout=true", "diff"}
			case "promisor":
				if err := os.WriteFile(filepath.Join(in.CWD, ".git", "objects", "pack", "pack-boundary.promisor"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Symlink(marker, filepath.Join(in.CWD, ".git", "owned-link")); err != nil {
					t.Fatal(err)
				}
			case "missing-path-helper":
				runFixture(t, in, "config", "diff.sample.textconv", "eci-missing-helper")
			case "bad-revision":
				in.Arguments = []string{"show", "missing-revision"}
			}
			if got := Inspect(in); got.Result != Advisory {
				t.Fatalf("unsupported %s: %+v", kind, got)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("helper or trace effect: %v", err)
			}
		})
	}
}

// TestNativeCaptureCompleteness rejects lost startup evidence from a real native trace.
//
// Example: removing a worktree event prevents an invented certificate cwd.
func TestNativeCaptureCompleteness(t *testing.T) {
	in, _, _ := fixture(t)
	s, err := newSandbox(in)
	if err != nil {
		t.Fatal(err)
	}
	// Owned sandbox cleanup remains part of the assertion.
	defer func() {
		if err := os.RemoveAll(s.dir); err != nil {
			t.Error(err)
		}
	}()
	_, events, _, err := s.run([]string{"diff"}, replayOutput)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := capturedGitEnvironment(in.Environment, events, "diff", in.CWD); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"worktree", "PATH", "HOME", "command", "malformed-value", "conflicting-worktree", "outside-cwd"} {
		// Remove or corrupt exactly the evidence named by this case.
		t.Run(kind, func(t *testing.T) {
			changed := make([]traceEvent, 0, len(events)+1)
			for _, event := range events {
				if kind == "worktree" && event.Event == "def_repo" || event.Event == "def_param" && event.Param == kind {
					continue
				}
				if kind == "command" && event.Event == "cmd_name" {
					event.Name = "other"
				}
				if kind == "malformed-value" && event.Event == "def_param" && event.Param == "HOME" {
					event.Value = json.RawMessage(`42`)
				}
				changed = append(changed, event)
				if kind == "conflicting-worktree" && event.Event == "def_repo" {
					changed = append(changed, traceEvent{Event: "def_repo", Worktree: filepath.Dir(in.CWD)})
				}
			}
			cwd := in.CWD
			if kind == "outside-cwd" {
				cwd = filepath.Dir(in.CWD)
			}
			if _, err := capturedGitEnvironment(in.Environment, changed, "diff", cwd); err == nil {
				t.Fatalf("accepted incomplete %s", kind)
			}
		})
	}
}

// TestLaunchProtocolBoundaries rejects malformed first records before a plausible later launch.
//
// Example: duplicate preparation assignments remain ambiguous when their values agree.
func TestLaunchProtocolBoundaries(t *testing.T) {
	first := traceEvent{Argv: []string{"/helper", "file"}, CWD: "/repo"}
	base := map[string]string{"GIT_DIFF_PATH_COUNTER": "1", "GIT_DIFF_PATH_TOTAL": "1"}
	prefix := "12:34:56.000000 run-command.c:673 trace: run_command: "
	valid := prefix + "cd /repo; /helper file\n"
	if _, err := externalChildEnvironment([]byte(valid), first, base); err != nil {
		t.Fatal(err)
	}
	for _, payload := range []string{"cd /other; /helper file", "cd /repo /helper file", "cd /repo", "cd /repo; GIT_DIFF_PATH_TOTAL=1 GIT_DIFF_PATH_TOTAL=1 /helper file", "cd /repo; /helper 'file", "cd /repo; /helper \\x", "cd /repo; /helper $file"} {
		if _, err := externalChildEnvironment([]byte(prefix+payload+"\n"), first, base); err == nil {
			t.Fatalf("accepted %q", payload)
		}
	}
	for _, record := range []string{"bad framing\n", "12:34:56.000000 extra run-command.c:673 trace: run_command: /helper\n", "99:99:99.000000 run-command.c:673 trace: run_command: /helper\n", strings.Replace(valid, "run-command.c:673", "run-command.c:674", 1)} {
		if _, err := firstLaunchRecord([]byte(record + valid)); err == nil {
			t.Fatalf("accepted ambiguous first record %q", record)
		}
	}
}

// TestAdmissionProtocolBoundaries pairs complete literal input with malformed transport contexts.
//
// Example: a comma in an environment key cannot become a wildcard request.
func TestAdmissionProtocolBoundaries(t *testing.T) {
	for _, key := range []string{"", "1NAME", "A,B", "A*", "A=B", "A-KEY"} {
		if literalEnvironmentKey(key) {
			t.Fatalf("accepted key %q", key)
		}
	}
	for _, key := range []string{"PATH", "_CUSTOM", "A1_B"} {
		if !literalEnvironmentKey(key) {
			t.Fatalf("rejected key %q", key)
		}
	}
	for _, args := range [][]string{nil, {"-c"}, {"-c", "bare"}, {"-c", "trace2.eventtarget=/tmp/trace", "diff"}, {"diff", "/proc/self/fd/7"}} {
		if _, reason := admission(Invocation{CWD: "/", Arguments: args}); reason == "" {
			t.Fatalf("accepted %v", args)
		}
	}
	if _, reason := admission(Invocation{CWD: "/", Arguments: []string{"diff"}, Environment: map[string]string{"A,B": "x"}}); reason == "" {
		t.Fatal("accepted nonliteral environment")
	}
	config, err := readConfig([]byte("core.fsmonitor\x00"))
	if err != nil || config["core.fsmonitor"] != "true" {
		t.Fatalf("bare native config: %v %v", config, err)
	}
}

// TestOwnedFilesystemAdmission exercises unavailable storage without changing shared tools.
//
// Example: an unreadable owned pack directory prevents any observer subprocess.
func TestOwnedFilesystemAdmission(t *testing.T) {
	for _, kind := range []string{"no-repository", "pack-permission", "admin-permission", "relative-tmp", "missing-tmp", "missing-git"} {
		// Restrict only owned fixture paths and restore their permissions before cleanup.
		t.Run(kind, func(t *testing.T) {
			in, _, marker := fixture(t)
			in.Arguments = []string{"diff"}
			switch kind {
			case "no-repository":
				in.CWD = filepath.Dir(in.CWD)
			case "pack-permission", "admin-permission":
				path := filepath.Join(in.CWD, ".git", "objects", "pack")
				if kind == "admin-permission" {
					path = filepath.Join(in.CWD, ".git", "hooks")
				}
				if err := os.Chmod(path, 0); err != nil {
					t.Fatal(err)
				}
				// Restore owned directory access so cleanup remains reliable.
				defer func() {
					if err := os.Chmod(path, 0700); err != nil {
						t.Error(err)
					}
				}()
			case "relative-tmp":
				in.Environment["TMPDIR"] = "scratch"
			case "missing-tmp":
				in.Environment["TMPDIR"] = filepath.Join(filepath.Dir(in.CWD), "unavailable-scratch")
			case "missing-git":
				in.Environment["PATH"] = filepath.Dir(in.CWD)
			}
			if got := Inspect(in); got.Result != Advisory {
				t.Fatalf("%s: %+v", kind, got)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("unexpected effect: %v", err)
			}
		})
	}
}

// TestCertificatePreparationBoundaries pairs executable PATH resolution with absent and privileged helpers.
//
// Example: a setuid-marked owned executable is outside the certificate domain.
func TestCertificatePreparationBoundaries(t *testing.T) {
	in, helper, marker := fixture(t)
	env := map[string]string{"PATH": "."}
	resolved, err := resolveProgram(filepath.Base(helper), filepath.Dir(helper), env)
	if err != nil || resolved != helper {
		t.Fatalf("relative PATH: %q %v", resolved, err)
	}
	if _, err := resolveProgram("helper", in.CWD, nil); err == nil {
		t.Fatal("accepted absent PATH")
	}
	if err := certifyInitialExec(traceEvent{}, in.CWD, env); err == nil {
		t.Fatal("accepted empty argv")
	}
	if err := certifyInitialExec(traceEvent{Argv: []string{"missing"}}, in.CWD, env); err == nil {
		t.Fatal("accepted unavailable helper")
	}
	if err := os.Chmod(helper, 0700|os.ModeSetuid); err != nil {
		t.Fatal(err)
	}
	if err := certifyInitialExec(traceEvent{Argv: []string{helper}}, in.CWD, env); err == nil {
		t.Fatal("accepted privilege-changing helper")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("unexpected effect: %v", err)
	}
}

// TestTransportEscapeBoundaries checks truncated and invalid Unicode alongside a valid scalar.
//
// Example: a truncated escape is rejected before JSON can replace its bytes.
func TestTransportEscapeBoundaries(t *testing.T) {
	for _, input := range []string{`"\`, `"\u12`, `"\uZZZZ"`} {
		if exactJSONUnicode([]byte(input)) {
			t.Fatalf("accepted %q", input)
		}
	}
	if !exactJSONUnicode([]byte(`"\u0041"`)) {
		t.Fatal("rejected valid scalar")
	}
	if _, err := parseLaunchTokens([]byte("'unterminated")); err == nil {
		t.Fatal("accepted unclosed native quote")
	}
	for _, event := range []traceEvent{{}, {Argv: []string{"/helper"}}} {
		if category, _ := classify(event, nil, nil); category != "" {
			t.Fatal("classified unknown child")
		}
	}
	event := traceEvent{UseShell: true, Argv: []string{"/helper", "file"}}
	if category, _ := classify(event, nil, map[string]string{"GIT_EXTERNAL_DIFF": "/helper"}); category != "external-diff" {
		t.Fatalf("environment external attribution: %q", category)
	}
}

// TestNativeInspectionArgumentRoles pairs native helper reachability with literal and consumed option-like text.
//
// Example: a tracked --output=literal leaf is inspected after the real delimiter.
func TestNativeInspectionArgumentRoles(t *testing.T) {
	for _, kind := range []string{"literal", "grep-pattern", "log-author"} {
		// Native callbacks establish the original effect before isolated replay.
		t.Run(kind, func(t *testing.T) {
			in, helper, marker := fixture(t)
			if err := os.WriteFile(helper, []byte("#!/bin/sh\necho reached >> '"+marker+"'\ncat -- \"$1\"\n"), 0700); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "literal":
				name := "--output=literal"
				if err := os.WriteFile(filepath.Join(in.CWD, name), []byte("old\n"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(in.CWD, ".gitattributes"), []byte(name+" diff=sample\n"), 0600); err != nil {
					t.Fatal(err)
				}
				runFixture(t, in, "add", "--", name, ".gitattributes")
				runFixture(t, in, "commit", "-qm", "literal baseline")
				if err := os.WriteFile(filepath.Join(in.CWD, name), []byte("new\n"), 0600); err != nil {
					t.Fatal(err)
				}
				in.Arguments = []string{"diff", "--", name}
			case "grep-pattern":
				if err := os.WriteFile(filepath.Join(in.CWD, "file.txt"), []byte("--output=pattern\n"), 0600); err != nil {
					t.Fatal(err)
				}
				in.Arguments = []string{"grep", "--textconv", "-F", "-e", "--output=pattern", "--", "file.txt"}
			case "log-author":
				runFixture(t, in, "config", "user.name", "--output=Example")
				runFixture(t, in, "add", "file.txt")
				runFixture(t, in, "commit", "-qm", "author baseline")
				in.Arguments = []string{"log", "HEAD", "-p", "-1", "--author", "--output=Example", "--", "file.txt"}
			}
			runFixture(t, in, in.Arguments...)
			if _, err := os.Stat(marker); err != nil {
				t.Fatal("native callback absent", err)
			}
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
			if got := Inspect(in); got.Result != Helper {
				t.Fatalf("native viable helper: %+v", got)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("observer callback effect: %v", err)
			}
		})
	}
}

// TestInspectionRoleBoundaries keeps auxiliary options unsupported while admitting literal option values.
//
// Example: diff still recognizes an output option after a revision, but not after --.
func TestInspectionRoleBoundaries(t *testing.T) {
	for _, args := range [][]string{
		{"diff", "HEAD", "--output=result"}, {"log", "HEAD", "--output", "result"}, {"show", "HEAD", "-Oorder"},
		{"grep", "-nO/bin/cat", "pattern"}, {"grep", "-fpatterns"}, {"diff", "--unknown-arity", "--output=result"},
		{"log", "--pretty", "--output=result"}, {"grep", "--regexp=pattern"}, {"grep", "-e"}, {"log", "--author"},
		{"grep", "--threads"}, {"status", "--unknown"}, {"grep", "--", "/dev/fd/3"},
	} {
		if _, reason := admission(Invocation{CWD: "/", Arguments: args}); reason == "" {
			t.Fatalf("admitted unresolved or auxiliary role %v", args)
		}
	}
	for _, args := range [][]string{
		{"diff", "--", "--output=literal", "-Oleaf"}, {"grep", "pattern", "-Oleaf"},
		{"grep", "-ne--output=pattern", "--", "file"}, {"grep", "--textconv", "--threads", "4", "-e", "/dev/fd/3"},
		{"log", "HEAD", "--author", "--output=author", "--format=%s"}, {"show", "--pretty", "HEAD"},
		{"diff", "-S", "--output=pattern", "-U3"}, {"diff", "--inter-hunk-context", "3"}, {"status", "--porcelain=v1"},
		{"grep", "--", "--output=literal"}, {"log", "--author=--output=author"},
	} {
		if _, reason := admission(Invocation{CWD: "/", Arguments: args}); reason != "" {
			t.Fatalf("rejected literal value or leaf %v: %s", args, reason)
		}
	}
}

// TestNativeAuxiliaryRolesRemainAdvisory pairs native callback effects with early auxiliary refusal.
//
// Example: a valid orderfile changes native ordering but remains outside the replay domain.
func TestNativeAuxiliaryRolesRemainAdvisory(t *testing.T) {
	for _, kind := range []string{"orderfile", "output", "patternfile"} {
		// Native callbacks establish that each excluded option has an actual effectful command.
		t.Run(kind, func(t *testing.T) {
			in, _, marker := fixture(t)
			owned := filepath.Join(in.Environment["HOME"], "option-input")
			switch kind {
			case "orderfile":
				if err := os.WriteFile(owned, []byte("file.txt\n"), 0600); err != nil {
					t.Fatal(err)
				}
				in.Arguments = []string{"diff", "HEAD", "-O", owned, "--", "file.txt"}
			case "output":
				in.Arguments = []string{"diff", "HEAD", "--output=" + owned, "--", "file.txt"}
			case "patternfile":
				if err := os.WriteFile(owned, []byte("new\n"), 0600); err != nil {
					t.Fatal(err)
				}
				in.Arguments = []string{"grep", "--textconv", "-f", owned, "--", "file.txt"}
			}
			runFixture(t, in, in.Arguments...)
			if _, err := os.Stat(marker); err != nil {
				t.Fatal("native callback absent", err)
			}
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
			if kind == "output" {
				if err := os.Remove(owned); err != nil {
					t.Fatal(err)
				}
			}
			if got := Inspect(in); got.Result != Advisory {
				t.Fatalf("auxiliary context admitted: %+v", got)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("preflight callback effect: %v", err)
			}
			if kind == "output" {
				if _, err := os.Stat(owned); !os.IsNotExist(err) {
					t.Fatalf("preflight output effect: %v", err)
				}
			}
		})
	}
}

// TestNativeDelimitedDashLeaf pairs a tracked dash filename with native helper and harmless raw inspection.
//
// Example: diff -- - selects a repository leaf rather than stream input.
func TestNativeDelimitedDashLeaf(t *testing.T) {
	in, helper, marker := fixture(t)
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho reached >> '"+marker+"'\nprintf 'converted new\n'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(in.CWD, "-"), []byte("old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(in.CWD, ".gitattributes"), []byte("- diff=sample\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runFixture(t, in, "add", "--", "-", ".gitattributes")
	runFixture(t, in, "commit", "-qm", "dash baseline")
	if err := os.WriteFile(filepath.Join(in.CWD, "-"), []byte("new\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"diff", "--", "-"}, {"grep", "--textconv", "new", "--", "-"}} {
		in.Arguments = args
		runFixture(t, in, args...)
		if _, err := os.Stat(marker); err != nil {
			t.Fatal("native callback absent", err)
		}
		if err := os.Remove(marker); err != nil {
			t.Fatal(err)
		}
		if got := Inspect(in); got.Result != Helper {
			t.Fatalf("literal dash refused: %+v", got)
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatalf("observer callback effect: %v", err)
		}
	}
	in.Arguments = []string{"diff", "--no-textconv", "--no-ext-diff", "--", "-"}
	if got := Inspect(in); got.Result != NoHelper {
		t.Fatalf("raw dash: %+v", got)
	}
	for _, args := range [][]string{{"diff", "-"}, {"grep", "new", "-"}, {"diff", "--", "/dev/fd/3"}, {"grep", "new", "--", "/proc/self/fd/3"}} {
		in.Arguments = args
		if got := Inspect(in); got.Result != Advisory {
			t.Fatalf("stream context admitted: %+v", got)
		}
	}
}
