package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// fixture creates an ordinary repository and a helper whose entry writes a marker.
//
// Example: fixture(t) supplies native and observed inspection inputs.
func fixture(t *testing.T) (Invocation, string, string) {
	t.Helper()
	dir, err := os.MkdirTemp(os.TempDir(), "eci-inspection-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(
		// Remove the owned fixture and report any cleanup failure.
		//
		// Example: temporary repository removal never hides a filesystem error.
		func() {
			if err := os.RemoveAll(dir); err != nil {
				t.Error(err)
			}
		},
	)
	repo := filepath.Join(dir, "repo")
	if err := os.Mkdir(repo, 0700); err != nil {
		t.Fatal(err)
	}
	// Native cwd observations use the physical fixture identity while cleanup owns the original path.
	//
	// Example: a mounted TMPDIR alias does not become an apparent foreign working directory.
	repo, err = filepath.EvalSymlinks(repo)
	if err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"PATH": "/usr/bin:/bin", "HOME": dir, "TMPDIR": "/tmp", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"}
	in := Invocation{CWD: repo, Environment: env}
	runFixture(t, in, "init", "-q")
	runFixture(t, in, "config", "user.name", "Example")
	runFixture(t, in, "config", "user.email", "example@example.invalid")
	marker := filepath.Join(dir, "marker")
	helper := filepath.Join(dir, "helper")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho reached >> '"+marker+"'\ncat \"$1\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".gitattributes"), []byte("file.txt diff=sample\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "file.txt"), []byte("old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runFixture(t, in, "add", ".gitattributes", "file.txt")
	runFixture(t, in, "commit", "-qm", "initial")
	runFixture(t, in, "config", "diff.sample.textconv", helper)
	if err := os.WriteFile(filepath.Join(repo, "file.txt"), []byte("new\n"), 0600); err != nil {
		t.Fatal(err)
	}
	return in, helper, marker
}

// runFixture executes a fixed fixture setup operation in its owned repository.
//
// Example: runFixture(t, in, "init", "-q") initializes a disposable repository.
func runFixture(
	t *testing.T,
	in Invocation,
	args ...string,
) string {
	t.Helper()
	c := exec.Command("/usr/bin/git", args...)
	c.Dir = in.CWD
	c.Env = environmentList(in.Environment)
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("fixture %v: %v %s", args, err, out)
	}
	return string(out)
}

// TestNativePairedTextconv verifies native execution and observer entry prevention.
//
// Example: go test -run TestNativePairedTextconv exercises historical conversion.
func TestNativePairedTextconv(t *testing.T) {
	in, _, marker := fixture(t)
	runFixture(t, in, "show", "--textconv", "HEAD:file.txt")
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("native helper did not run", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	in.Arguments = []string{"--no-pager", "show", "--textconv", "HEAD:file.txt"}
	got := Inspect(in)
	if got.Result != Helper || got.Category != "textconv" {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("helper ran under observer: %v", err)
	}
}

// TestLoaderAdvisoryBeforeExecution proves rejected loader controls cannot create output.
//
// Example: LD_DEBUG_OUTPUT cannot write an observer loader log.
func TestLoaderAdvisoryBeforeExecution(t *testing.T) {
	in, _, _ := fixture(t)
	in.Arguments = []string{"diff"}
	in.Environment["LD_DEBUG"] = "libs"
	in.Environment["LD_DEBUG_OUTPUT"] = filepath.Join(in.Environment["HOME"], "loader")
	got := Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "loader") {
		t.Fatalf("got %+v", got)
	}
	matches, _ := filepath.Glob(in.Environment["LD_DEBUG_OUTPUT"] + "*")
	if len(matches) != 0 {
		t.Fatal(matches)
	}
}

// TestRawNoHelper tests a benign counterpart and original preservation.
//
// Example: disabled conversion leaves the original index untouched.
func TestRawNoHelper(t *testing.T) {
	in, _, marker := fixture(t)
	before, _ := os.ReadFile(filepath.Join(in.CWD, ".git", "index"))
	in.Arguments = []string{"--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"}
	got := Inspect(in)
	if got.Result != NoHelper {
		t.Fatalf("got %+v", got)
	}
	after, _ := os.ReadFile(filepath.Join(in.CWD, ".git", "index"))
	if string(before) != string(after) {
		t.Fatal("index changed")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("helper ran")
	}
}

// TestSelectedNativeCases exercises actual selection, option order, historical and threaded paths.
//
// Example: a no-output pickaxe comparison still reaches conversion.
func TestSelectedNativeCases(t *testing.T) {
	in, _, marker := fixture(t)
	cases := []struct {
		name string
		args []string
		want Result
	}{
		{"pickaxe", []string{"diff", "-Sabsent", "--name-only", "--", "file.txt"}, Helper},
		{"regex-pickaxe", []string{"diff", "-Gabsent", "--", "file.txt"}, Helper},
		{"quiet", []string{"diff", "--quiet", "--textconv", "--", "file.txt"}, Helper},
		{"historical", []string{"show", "--textconv", "HEAD:file.txt"}, Helper},
		{"log-context", []string{"log", "-U3", "--", "file.txt"}, Helper},
		{"log-stat", []string{"log", "--patch-with-stat", "--", "file.txt"}, Helper},
		{"threaded-grep", []string{"grep", "--threads=4", "--textconv", "new", "--", "file.txt"}, Helper},
		{"clean-cached", []string{"diff", "--cached", "--", "file.txt"}, NoHelper},
		{"check", []string{"diff", "--check", "--", "file.txt"}, NoHelper},
		{"unrelated", []string{"diff", "--", ".gitattributes"}, NoHelper},
		{"last-patch-wins", []string{"diff", "--no-patch", "-p", "--", "file.txt"}, Helper},
		{"last-no-patch-wins", []string{"diff", "-p", "--no-patch", "--", "file.txt"}, NoHelper},
		{"grep-no-match", []string{"grep", "--no-textconv", "absent", "--", "file.txt"}, NoHelper},
	}
	for _, tc := range cases {
		t.Run(tc.name,
			// Check one named native counterpart and forbid observer helper execution.
			//
			// Example: a missing helper stays Advisory without a marker.
			func(t *testing.T) {
				in.Arguments = append([]string{"--no-pager"}, tc.args...)
				got := Inspect(in)
				if got.Result != tc.want {
					t.Fatalf("got %+v want %v", got, tc.want)
				}
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatal("observer helper executed", err)
				}
			},
		)
	}
}

// TestMissingAndUnlaunchableHelpers verifies that a child event alone cannot deny inspection.
//
// Example: missing shebang interpreters return Advisory despite a blocked observer fork.
func TestMissingAndUnlaunchableHelpers(t *testing.T) {
	in, _, marker := fixture(t)
	for _, tc := range []struct {
		name string
		body string
		mode os.FileMode
	}{
		{"missing", "", 0}, {"nonexec", "#!/bin/sh\nexit 0\n", 0600},
		{"missing-interpreter", "#!/no/such/interpreter\n", 0700},
		{"enoexec", "echo should-not-run\n", 0700},
	} {
		t.Run(tc.name,
			// Check one named native counterpart and forbid observer helper execution.
			//
			// Example: a missing helper stays Advisory without a marker.
			func(t *testing.T) {
				path := filepath.Join(in.Environment["HOME"], tc.name)
				if tc.body != "" {
					if err := os.WriteFile(path, []byte(tc.body), tc.mode); err != nil {
						t.Fatal(err)
					}
				}
				in.Arguments = []string{"-c", "diff.sample.textconv=" + path, "show", "--textconv", "HEAD:file.txt"}
				got := Inspect(in)
				if got.Result != Advisory {
					t.Fatalf("got %+v", got)
				}
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatal("helper ran")
				}
			},
		)
	}
}

// TestFsmonitorFirstAndDaemon exercises the first auxiliary and pre-replay daemon exclusion.
//
// Example: later conversion cannot replace a missing first fsmonitor helper.
func TestFsmonitorFirstAndDaemon(t *testing.T) {
	in, helper, marker := fixture(t)
	in.Arguments = []string{"-c", "core.fsmonitor=" + helper + " monitor", "diff", "--", "file.txt"}
	got := Inspect(in)
	if got.Result != Helper || got.Category != "fsmonitor" {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("fsmonitor ran")
	}
	in.Arguments = []string{"-c", "core.fsmonitor=" + filepath.Join(in.Environment["HOME"], "missing"), "diff", "--", "file.txt"}
	got = Inspect(in)
	if got.Result != Advisory {
		t.Fatalf("first missing hook got %+v", got)
	}
	in.Arguments = []string{"-c", "core.fsmonitor=true", "diff", "--", "file.txt"}
	got = Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "daemon") {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("daemon proof ran converter")
	}
}

// TestConditionalIncludesAndCache verifies same-path Git config and native cache validity.
//
// Example: a historical textconv cache hit completes without reaching a child.
func TestConditionalIncludesAndCache(t *testing.T) {
	in, helper, marker := fixture(t)
	include := filepath.Join(in.Environment["HOME"], "included")
	if err := os.WriteFile(include, []byte("[diff \"sample\"]\n textconv = "+helper+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runFixture(t, in, "config", "--unset", "diff.sample.textconv")
	physical, err := filepath.EvalSymlinks(in.CWD)
	if err != nil {
		t.Fatal(err)
	}
	runFixture(t, in, "config", "includeIf.gitdir:"+physical+"/.git.path", include)
	in.Arguments = []string{"show", "--textconv", "HEAD:file.txt"}
	got := Inspect(in)
	if got.Result != Helper {
		t.Fatalf("conditional include got %+v", got)
	}
	runFixture(t, in, "config", "diff.sample.cachetextconv", "true")
	runFixture(t, in, "show", "--textconv", "HEAD:file.txt")
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	got = Inspect(in)
	if got.Result != NoHelper {
		t.Fatalf("cache hit got %+v", got)
	}
	in.Arguments = []string{"-c", "diff.sample.textconv=" + helper + " changed", "show", "--textconv", "HEAD:file.txt"}
	got = Inspect(in)
	if got.Result != Helper {
		t.Fatalf("cache invalidation got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("cached observer ran helper")
	}
}

// TestTraceChannelsAndHatch checks early trace exclusion and command-specific hatch syntax.
//
// Example: grep's native parser accepts the returned raw hatch.
func TestTraceChannelsAndHatch(t *testing.T) {
	in, _, marker := fixture(t)
	in.Arguments = []string{"grep", "--textconv", "new", "--", "file.txt"}
	got := Inspect(in)
	if got.Result != Helper {
		t.Fatalf("got %+v", got)
	}
	for _, arg := range got.Hatch {
		if arg == "--no-ext-diff" {
			t.Fatal("grep hatch has invalid diff flag")
		}
	}
	runFixture(t, in, got.Hatch...)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("raw hatch ran helper")
	}
	for _, value := range []string{"5", "af_unix:stream:" + filepath.Join(in.Environment["HOME"], "trace.sock"), filepath.Join(in.Environment["HOME"], "trace-output")} {
		in.Environment["GIT_TRACE2_PERF"] = value
		got = Inspect(in)
		if got.Result != Advisory || !strings.Contains(got.Reason, "trace") {
			t.Fatalf("got %+v", got)
		}
	}
}

// TestCustomGitIsNotExecuted proves that version-shaped wrapper output is insufficient admission.
//
// Example: a PATH wrapper that writes a marker remains Advisory without invocation.
func TestCustomGitIsNotExecuted(t *testing.T) {
	in, _, marker := fixture(t)
	bin := filepath.Join(in.Environment["HOME"], "bin")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte("#!/bin/sh\necho bad > '"+marker+"'\necho 'git version 2.51.0'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	in.Environment["PATH"] = bin + ":/usr/bin:/bin"
	in.Arguments = []string{"diff"}
	got := Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "native Git identity") {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("custom Git wrapper executed")
	}
}

// TestExactQuietAndPickaxeNative compares reached helper effects without guessing from options.
//
// Example: native and observer agree on a quiet changed-worktree diff.
func TestExactQuietAndPickaxeNative(t *testing.T) {
	in, _, marker := fixture(t)
	for _, args := range [][]string{{"diff", "-Sabsent", "--name-only", "--", "file.txt"}, {"diff", "--quiet", "--", "file.txt"}} {
		c := exec.Command("/usr/bin/git", args...)
		c.Dir = in.CWD
		c.Env = environmentList(in.Environment)
		out, err := c.CombinedOutput()
		if err != nil {
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Fatalf("native: %v %s", err, out)
			}
		}
		_, statErr := os.Stat(marker)
		nativeReached := statErr == nil
		if nativeReached {
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
		}
		in.Arguments = args
		got := Inspect(in)
		t.Logf("args=%v nativeHelper=%t observer=%+v", args, nativeReached, got)
		if nativeReached && got.Result != Helper || !nativeReached && got.Result != NoHelper {
			t.Fatalf("native/observer mismatch")
		}
	}
}

// TestNativePreparationEnvironment compares actual Git helper inputs with source-matched Trace2 capture.
//
// Example: a subdirectory invocation retains its GIT_PREFIX and native config parameter encoding.
func TestNativePreparationEnvironment(t *testing.T) {
	in, _, marker := fixture(t)
	root := in.CWD
	subdir := filepath.Join(root, "subdir")
	if err := os.Mkdir(subdir, 0700); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(in.Environment["HOME"], "env-helper")
	snapshot := filepath.Join(in.Environment["HOME"], "native-env")
	script := "#!/bin/sh\nprintf '%s\\n' \"$PATH\" \"$GIT_EXEC_PATH\" \"$GIT_PREFIX\" \"$GIT_CONFIG_PARAMETERS\" \"$GIT_PAGER\" > '" + snapshot + "'\ncat \"$1\"\n"
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	in.CWD = subdir
	in.Arguments = []string{"--no-pager", "-c", "diff.sample.textconv=" + helper, "-c", "test.example=apostrophe' and bang!", "show", "--textconv", "HEAD:file.txt"}
	runFixture(t, in, in.Arguments...)
	native, err := os.ReadFile(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	s, err := newSandbox(in)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(
		// Restore owned fixture resources and report cleanup failures.
		//
		// Example: leave no fixture channel or process setting after this test.
		func() {
			if err := os.RemoveAll(s.dir); err != nil {
				t.Error(err)
			}
		},
	)
	_, events, _, err := s.run(in.Arguments, replayOutput)
	if err != nil {
		t.Fatal(err)
	}
	captured, err := capturedGitEnvironment(in.Environment, events, "show", s.cwd)
	if err != nil {
		t.Fatal(err)
	}
	expected := strings.Join([]string{captured["PATH"], captured["GIT_EXEC_PATH"], captured["GIT_PREFIX"], captured["GIT_CONFIG_PARAMETERS"], captured["GIT_PAGER"]}, "\n") + "\n"
	if string(native) != expected {
		t.Fatalf("native %q captured %q", native, expected)
	}
	if captured["GIT_PREFIX"] != "subdir/" {
		t.Fatalf("incorrect prefix %q", captured["GIT_PREFIX"])
	}
	if err := os.Remove(snapshot); err != nil {
		t.Fatal(err)
	}
	got := Inspect(in)
	if got.Result != Helper {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(snapshot); !os.IsNotExist(err) {
		t.Fatal("certificate ran helper")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("original helper ran")
	}
}

// TestStatusFsmonitorAndUnsupportedDomains verifies built-in ownership and bounded unsupported states.
//
// Example: ordinary status reaches fsmonitor, while daemon mode stays Advisory.
func TestStatusFsmonitorAndUnsupportedDomains(t *testing.T) {
	in, helper, marker := fixture(t)
	in.Arguments = []string{"-c", "core.fsmonitor=" + helper + " monitor", "status", "--short"}
	got := Inspect(in)
	if got.Result != Helper || got.Category != "fsmonitor" {
		t.Fatalf("got %+v", got)
	}
	runFixture(t, in, got.Hatch...)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("raw status helper ran")
	}
	for _, args := range [][]string{{"add", "file.txt"}, {"diff", "--no-index", "a", "b"}, {"grep", "-f", "/dev/fd/3"}, {"log", "--stdin"}, {"--git-dir=.git", "diff"}, {"--paginate", "log"}} {
		in.Arguments = args
		got = Inspect(in)
		if got.Result != Advisory {
			t.Fatalf("args %v got %+v", args, got)
		}
	}
	in.Arguments = []string{"diff"}
	in.Environment["GIT_INDEX_FILE"] = filepath.Join(in.CWD, ".git", "index")
	got = Inspect(in)
	if got.Result != Advisory {
		t.Fatalf("alternate index got %+v", got)
	}
	delete(in.Environment, "GIT_INDEX_FILE")
	if err := os.WriteFile(filepath.Join(in.CWD, ".git", "objects", "info", "alternates"), []byte("/unmodeled/store\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got = Inspect(in)
	if got.Result != Advisory {
		t.Fatalf("alternate store got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("unsupported proof ran helper")
	}
}

// TestAttachedAuxiliaryInputAdvisory proves unsupported file/pager inputs are detected before replay.
//
// Example: grep -fFILE cannot consume an unavailable original FIFO.
func TestAttachedAuxiliaryInputAdvisory(t *testing.T) {
	in, _, marker := fixture(t)
	for _, args := range [][]string{{"grep", "-ffile.txt"}, {"grep", "-O/bin/cat", "new"}, {"grep", "--open-files-in-pager=/bin/cat", "new"}, {"diff", "-Ofile.txt"}} {
		in.Arguments = args
		got := Inspect(in)
		if got.Result != Advisory || !strings.Contains(got.Reason, "unsupported input/output") {
			t.Fatalf("args %v got %+v", args, got)
		}
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("unsupported inputs ran helper")
	}
}

// TestConversionLoaderControlsAdvisory prevents unmodeled libc module lookup before all subprocesses.
//
// Example: GCONV_PATH cannot load a custom conversion module during observation.
func TestConversionLoaderControlsAdvisory(t *testing.T) {
	in, _, marker := fixture(t)
	in.Arguments = []string{"diff"}
	for _, key := range []string{"GCONV_PATH", "LOCPATH", "MALLOC_TRACE"} {
		in.Environment[key] = filepath.Join(in.Environment["HOME"], "loader-control")
		got := Inspect(in)
		if got.Result != Advisory || !strings.Contains(got.Reason, "loader") {
			t.Fatalf("%s got %+v", key, got)
		}
		for _, entry := range observerEnvironment(in.Environment) {
			if strings.HasPrefix(entry, key+"=") {
				t.Fatalf("effectful infrastructure environment %s", key)
			}
		}
		delete(in.Environment, key)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("loader controls ran helper")
	}
}

// TestAdministrativeCWDAdvisory prevents a worktree-root certificate for an administrative invocation.
//
// Example: git -C .git inherits a different helper cwd and remains unsupported.
func TestAdministrativeCWDAdvisory(t *testing.T) {
	in, _, marker := fixture(t)
	in.CWD = filepath.Join(in.CWD, ".git")
	in.Arguments = []string{"show", "--textconv", "HEAD:file.txt"}
	got := Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "administrative cwd") {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("administrative observer helper ran")
	}
}

// TestNativeNumericFsmonitorDaemonAdmission checks Git's real boolean grammar before replay.
//
// Example: core.fsmonitor=2 is daemon mode, while zero remains disabled.
func TestNativeNumericFsmonitorDaemonAdmission(t *testing.T) {
	in, _, marker := fixture(t)
	for _, value := range []string{"2", "-1", "0x2", "1k"} {
		native := runFixture(t, in, "-c", "core.fsmonitor="+value, "config", "--type=bool", "--get", "core.fsmonitor")
		if native != "true\n" {
			t.Fatalf("native boolean %q=%q", value, native)
		}
		in.Arguments = []string{"-c", "core.fsmonitor=" + value, "diff", "--no-ext-diff", "--no-textconv"}
		got := Inspect(in)
		if got.Result != Advisory || !strings.Contains(got.Reason, "daemon") {
			t.Fatalf("%q got %+v", value, got)
		}
	}
	for _, value := range []string{"0", "false", "off", "no"} {
		in.Arguments = []string{"-c", "core.fsmonitor=" + value, "diff", "--no-ext-diff", "--no-textconv"}
		got := Inspect(in)
		if got.Result != NoHelper {
			t.Fatalf("disabled %q got %+v", value, got)
		}
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("daemon boundary ran helper")
	}
}

// TestRelativeHelperNativeCWDForAllVerbs checks ordinary repository discovery before helper preparation.
//
// Example: log and show from a subdirectory still inherit the discovered worktree root.
func TestRelativeHelperNativeCWDForAllVerbs(t *testing.T) {
	in, _, marker := fixture(t)
	root := in.CWD
	sub := filepath.Join(root, "subdir")
	if err := os.Mkdir(sub, 0700); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(root, "relative-helper")
	script := "#!/bin/sh\nprintf '%s\\n%s\\n' \"$PWD\" \"$GIT_PREFIX\" >> '" + marker + "'\nif test -f \"$1\"; then cat \"$1\"; fi\n"
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	in.CWD = sub
	for _, args := range [][]string{
		{"diff", "--", "../file.txt"}, {"show", "--textconv", "HEAD:file.txt"},
		{"log", "-p", "--", "../file.txt"}, {"grep", "--textconv", "new", "--", "../file.txt"},
		{"status", "--short", "--", "../file.txt"},
	} {
		in.Arguments = append([]string{"--no-pager", "-c", "diff.sample.textconv=./relative-helper", "-c", "core.fsmonitor=./relative-helper"}, args...)
		runFixture(t, in, in.Arguments...)
		native, err := os.ReadFile(marker)
		if err != nil {
			t.Fatal(err)
		}
		physical, err := filepath.EvalSymlinks(root)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(string(native), physical+"\nsubdir/\n") {
			t.Fatalf("%v native cwd/prefix %q", args, native)
		}
		if err := os.Remove(marker); err != nil {
			t.Fatal(err)
		}
		s, err := newSandbox(in)
		if err != nil {
			t.Fatal(err)
		}
		_, events, _, err := s.run(in.Arguments, replayOutput)
		if err != nil {
			t.Fatal(err)
		}
		captured, err := capturedGitEnvironment(in.Environment, events, args[0], s.cwd)
		if err != nil {
			t.Fatal(err)
		}
		if captured["GIT_PREFIX"] != "subdir/" {
			t.Fatalf("%v captured prefix %q", args, captured["GIT_PREFIX"])
		}
		if err := os.RemoveAll(s.dir); err != nil {
			t.Fatal(err)
		}
		got := Inspect(in)
		if got.Result != Helper {
			t.Fatalf("%v got %+v", args, got)
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("observer relative helper ran")
		}
	}
}

// TestRawHatchPreservesStatusAndGrepOperands checks command-specific disabling without duplicated selectors.
//
// Example: status appears once and grep's context argument remains an argument to its option.
func TestRawHatchPreservesStatusAndGrepOperands(t *testing.T) {
	status := rawHatch([]string{"--no-pager", "status", "--short", "--", "file.txt"}, 1, true)
	expected := []string{"--no-pager", "-c", "core.fsmonitor=false", "status", "--short", "--", "file.txt"}
	if !slices.Equal(status, expected) {
		t.Fatalf("status hatch %v", status)
	}
	in, _, marker := fixture(t)
	in.Arguments = []string{"grep", "--textconv", "--after-context", "1", "-e", "new", "--", "file.txt"}
	got := Inspect(in)
	if got.Result != Helper {
		t.Fatalf("got %+v", got)
	}
	runFixture(t, in, got.Hatch...)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("raw grep ran helper")
	}
}
