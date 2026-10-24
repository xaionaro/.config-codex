package checks_test

import (
	"bytes"
	"context"
	"debug/buildinfo"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// launcherFixture owns disposable module, cache and caller directories.
//
// Example: a compiler-double test creates one isolated fixture per case.
type launcherFixture struct {
	Root, Source, Cache, Caller, Launcher string
	Env                                   []string
}

// writeFile writes an exact disposable fixture and fails on I/O errors.
//
// Example: writeFile creates a generated module's main.go.
func writeFile(
	t *testing.T,
	path string,
	content string,
	mode os.FileMode,
) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// newFixture isolates launcher inputs without copying canonical source.
//
// Example: tests select a baseline using OWNED_COMMAND_TEST_LAUNCHER.
func newFixture(t *testing.T) launcherFixture {
	t.Helper()
	root := t.TempDir()
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	f := launcherFixture{Root: root, Source: filepath.Join(root, "source"), Cache: filepath.Join(root, "cache"), Caller: filepath.Join(root, "caller"), Launcher: os.Getenv("OWNED_COMMAND_TEST_LAUNCHER")}
	if f.Launcher == "" {
		var err error
		f.Launcher, err = filepath.Abs("../../bin/owned-command")
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, dir := range []string{f.Source, f.Caller} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(f.Source, "go.mod"), "module disposable.example/probe\n\ngo 1.24\n", 0600)
	writeFile(t, filepath.Join(f.Source, "main.go"), "package main\nfunc main() {}\n", 0600)
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if strings.HasPrefix(key, "GO") || key == "CGO_ENABLED" || key == "OWNED_COMMAND_SOURCE" || key == "OWNED_COMMAND_CACHE" {
			continue
		}
		f.Env = append(f.Env, item)
	}
	f.Env = append(f.Env, "OWNED_COMMAND_SOURCE="+f.Source, "OWNED_COMMAND_CACHE="+f.Cache, "GOENV=off", "GOTOOLCHAIN=local", "XDG_CONFIG_HOME="+filepath.Join(f.Root, "config"))
	return f
}

// command creates a bounded launcher subprocess with untouched fixture inputs.
//
// Example: a native-policy test adds foreign caller settings to Env.
func (f launcherFixture) command(args ...string) (*exec.Cmd, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	cmd := exec.CommandContext(ctx, f.Launcher, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel =
		// Cancellation retires the disposable process group, including compiler barriers.
		//
		// Example: a failed readiness assertion cannot leave a blocked compiler behind.
		func() error {
			err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			if errors.Is(err, syscall.ESRCH) {
				return os.ErrProcessDone
			}
			return err
		}
	cmd.Env = f.Env
	cmd.Dir = f.Caller
	return cmd, cancel
}

// run executes the launcher and retains both output streams and native status.
//
// Example: negative controls inspect a compiler error without stale execution.
func (f launcherFixture) run(
	t *testing.T,
	args ...string,
) (string, string, error) {
	t.Helper()
	cmd, cancel := f.command(args...)
	defer cancel()
	var out, errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	cmd.Stdin = strings.NewReader("stdin-token")
	err := cmd.Run()
	return out.String(), errOut.String(), err
}

// requireSuccess rejects any failed launcher invocation.
//
// Example: cold and warm cache checks both require the emitted program.
func requireSuccess(
	t *testing.T,
	f launcherFixture,
) {
	t.Helper()
	out, stderr, err := f.run(t)
	if err != nil || out != "child\n" || stderr != "" {
		t.Fatalf("stdout=%q stderr=%q err=%v", out, stderr, err)
	}
}

// TestDefaultSourceUsesCodexHome requires the default owner without a project checkout.
//
// Example: an unrelated caller builds only HOME/.codex/tools/owned-command.
func TestDefaultSourceUsesCodexHome(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	canonical := filepath.Join(f.Root, ".codex", "tools", "owned-command")
	if err := os.MkdirAll(filepath.Dir(canonical), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(f.Source, canonical); err != nil {
		t.Fatal(err)
	}
	f.Source = canonical
	var env []string
	for _, item := range f.Env {
		key, _, _ := strings.Cut(item, "=")
		if key != "HOME" && key != "OWNED_COMMAND_SOURCE" {
			env = append(env, item)
		}
	}
	f.Env = append(env, "HOME="+f.Root)
	requireSuccess(t, f)
	requireSuccess(t, f)
	if count := buildCount(t, f); count != 1 {
		t.Fatalf("default owner cold/warm builds=%d; want 1", count)
	}
	if _, err := os.Stat(filepath.Join(f.Root, "go", "src")); !os.IsNotExist(err) {
		t.Fatalf("default owner unexpectedly depends on a project checkout: %v", err)
	}
}

// installCompilerDouble creates an instrumented compiler external boundary.
//
// Example: a build error is controlled by a file without mocking shell logic.
func installCompilerDouble(
	t *testing.T,
	f *launcherFixture,
) {
	t.Helper()
	bin := filepath.Join(f.Root, "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	script := `#!/usr/bin/env bash
set -euo pipefail
if [[ -f $DOUBLE_ROOT/query-fail ]]; then
 failure=$(cat "$DOUBLE_ROOT/query-fail")
 phase=
 case "$1" in
 version) phase=version; if [[ $failure == post-version && -e $DOUBLE_ROOT/postbuild ]]; then phase=post-version; fi;;
 env) case "${2:-}" in GOHOSTOS) phase=bootstrap;; GOOS) phase=steady;; GOAMD64) if [[ ${GOAMD64+x} != x ]]; then phase=defaults; fi;; esac;;
 esac
 if [[ $failure == "$phase" ]]; then printf 'deliberate %s query failure\n' "$phase" >&2; exit 24; fi
fi
case "$1" in
 version) printf 'go version %s linux/amd64\n' "$(cat "$DOUBLE_ROOT/version")";;
 env)
 shift
 if [[ $# == 1 && $1 == GOAMD64 && ${GOENV-} == off && ${GOAMD64+x} != x ]]; then env > "$DOUBLE_ROOT/defaults-env"; fi
 for name in "$@"; do
 case "$name" in
 GOHOSTOS) echo linux;; GOHOSTARCH) echo amd64;; GOROOT) echo "$DOUBLE_ROOT";; GOVERSION) cat "$DOUBLE_ROOT/version";;
 GOOS) echo "${GOOS:-linux}";; GOARCH) echo "${GOARCH:-amd64}";;
 GOTOOLCHAIN) echo "${GOTOOLCHAIN:-local}";;
 GOAMD64) echo "${GOAMD64:-v1}";; GOARM64) echo "${GOARM64:-v8.0}";; GOARM) echo "${GOARM:-7}";; GO386) echo "${GO386:-sse2}";;
 GOPATH) echo "${GOPATH:-$DOUBLE_ROOT/gopath}";; GOMODCACHE) echo "${GOMODCACHE:-$DOUBLE_ROOT/gopath/pkg/mod}";;
 CGO_ENABLED) echo "${CGO_ENABLED:-0}";; GO111MODULE) echo "${GO111MODULE:-on}";; GOWORK) echo "${GOWORK:-off}";; GOFLAGS) echo "${GOFLAGS-}";;
 GOEXPERIMENT|GOFIPS140) echo "${!name-}";; *) echo "${!name-}";;
 esac
 done;;
 build)
 printf 'build\n' >> "$DOUBLE_ROOT/builds"
 if [[ -f $DOUBLE_ROOT/build-stdout ]]; then cat "$DOUBLE_ROOT/build-stdout"; fi
 touch "$DOUBLE_ROOT/postbuild"
 env > "$DOUBLE_ROOT/build-env"
 if [[ -e $DOUBLE_ROOT/fail ]]; then echo 'deliberate compiler failure' >&2; exit 23; fi
 if [[ -e $DOUBLE_ROOT/mutate ]]; then printf '\n// observed mutation\n' >> main.go; fi
 if [[ -p $DOUBLE_ROOT/build-gate ]]; then echo ready > "$DOUBLE_ROOT/build-ready"; read -r token < "$DOUBLE_ROOT/build-gate"; fi
 shift
 while [[ $# -gt 0 ]]; do if [[ $1 == -o ]]; then shift; output=$1; fi; shift; done
 cat > "$output" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${DOUBLE_CHILD_LOG:-} ]]; then printf 'executed\n' >> "$DOUBLE_CHILD_LOG"; fi
if [[ -p $DOUBLE_ROOT/child-gate && ${DOUBLE_CHILD_SKIP:-0} != 1 ]]; then echo ready > "$DOUBLE_ROOT/child-ready"; read -r token < "$DOUBLE_ROOT/child-gate"; fi
if [[ ${1:-} == --report-goroot ]]; then printf '%s\n' "${GOROOT-}"; exit 0; fi
if [[ ${1:-} == --report-path ]]; then printf '%s\n' "$0"; exit 0; fi
printf 'child\n'
CHILD
 chmod +x "$output";;
 *) echo "unexpected compiler request: $*" >&2; exit 99;;
esac
`
	writeFile(t, filepath.Join(bin, "go"), script, 0700)
	writeFile(t, filepath.Join(f.Root, "version"), "go1.26.5\n", 0600)
	f.Env = append(f.Env, "PATH="+bin+":"+os.Getenv("PATH"), "DOUBLE_ROOT="+f.Root)
}

// buildCount counts actual double compile requests, rather than cache metadata.
//
// Example: a warm hit keeps this count unchanged.
func buildCount(
	t *testing.T,
	f launcherFixture,
) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(f.Root, "builds"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(data), "build\n")
}

// cachedExecutables enumerates only published executable leaves.
//
// Example: source mutations must not publish another cache leaf.
func cachedExecutables(
	t *testing.T,
	f launcherFixture,
) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(f.Cache, "*", "owned-command"))
	if err != nil {
		t.Fatal(err)
	}
	return paths
}

// TestCacheLifecycle checks content identity and repair of damaged cache leaves.
//
// Example: preserved modification time must not hide a changed source body.
func TestCacheLifecycle(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	requireSuccess(t, f)
	requireSuccess(t, f)
	if n := buildCount(t, f); n != 1 {
		t.Fatalf("cold/warm builds=%d", n)
	}
	paths := cachedExecutables(t, f)
	if len(paths) != 1 {
		t.Fatalf("published=%v", paths)
	}
	if err := os.Remove(paths[0]); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, f)
	if err := os.Chmod(paths[0], 0600); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, f)
	if n := buildCount(t, f); n != 3 {
		t.Fatalf("repair builds=%d", n)
	}
	main := filepath.Join(f.Source, "main.go")
	info, err := os.Stat(main)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, main, "package main\nfunc main() {} // changed\n", 0600)
	if err := os.Chtimes(main, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, f)
	changedPath := executedPath(t, f)
	extra := filepath.Join(f.Source, "extra.go")
	writeFile(t, extra, "package main\n", 0600)
	requireSuccess(t, f)
	addedPath := executedPath(t, f)
	if addedPath == changedPath {
		t.Fatal("added source reused prior cache key")
	}
	if err := os.Remove(extra); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, f)
	if removedPath := executedPath(t, f); removedPath != changedPath {
		t.Fatalf("removed source selected %q; want prior key %q", removedPath, changedPath)
	}
	if n := buildCount(t, f); n != 5 {
		t.Fatalf("content/add/remove builds=%d; removal should reuse original content key", n)
	}
}

// resolvePath requires the launcher's single-line prepared executable protocol.
//
// Example: a successful resolver preserves spaces and never prints child output.
func resolvePath(t *testing.T, f launcherFixture) string {
	t.Helper()
	out, stderr, err := f.run(t, "--resolve-executable")
	path := strings.TrimSuffix(out, "\n")
	if err != nil || !strings.HasSuffix(out, "\n") || strings.ContainsAny(path, "\r\n") || !filepath.IsAbs(path) {
		t.Fatalf("resolve stdout=%q stderr=%q err=%v", out, stderr, err)
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		t.Fatalf("resolved path is not executable: %q: %v", path, err)
	}
	return path
}

// TestResolvedExecutableLifetime separates preparation from direct execution.
//
// Example: source changes publish a new version while an older selected path still runs.
func TestResolvedExecutableLifetime(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	f.Cache = filepath.Join(f.Root, "cache with spaces ")
	log := filepath.Join(f.Root, "child-executions")
	f.Env = append(f.Env, "OWNED_COMMAND_CACHE="+f.Cache, "DOUBLE_CHILD_LOG="+log)
	writeFile(t, filepath.Join(f.Root, "build-stdout"), "compiler-note\n", 0600)
	out, diagnostic, err := f.run(t, "--resolve-executable")
	if err != nil || diagnostic != "compiler-note\n" {
		t.Fatalf("build diagnostic stdout=%q stderr=%q err=%v", out, diagnostic, err)
	}
	first := strings.TrimSuffix(out, "\n")
	if next := resolvePath(t, f); next != first || buildCount(t, f) != 1 {
		t.Fatalf("cold/warm resolution changed selection: first=%q next=%q", first, next)
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatalf("resolution executed the child: %v", err)
	}
	writeFile(t, filepath.Join(f.Source, "main.go"), "package main\nfunc main() {} // changed\n", 0600)
	second := resolvePath(t, f)
	if second == first || buildCount(t, f) != 2 {
		t.Fatalf("source change did not select a new version: %q %q", first, second)
	}
	bin := filepath.Join(f.Root, "only-bash")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/bin/bash", filepath.Join(bin, "bash")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{first, second} {
		cmd := exec.CommandContext(t.Context(), path)
		cmd.Env = append(f.Env, "PATH="+bin)
		cmd.Dir = f.Caller
		if data, err := cmd.CombinedOutput(); err != nil || string(data) != "child\n" {
			t.Fatalf("prepared version needs compiler or lost retention: %q: %s %v", path, data, err)
		}
	}
	if data, err := os.ReadFile(log); err != nil || string(data) != "executed\nexecuted\n" {
		t.Fatalf("direct execution count=%q err=%v", data, err)
	}
	if err := exec.Command("flock", "-n", filepath.Join(f.Cache, "build.lock"), "true").Run(); err != nil {
		t.Fatalf("resolution retained the cache lock: %v", err)
	}
}

// TestResolverRejectsInvalidOrFailedPreparation never returns a stale pathname.
//
// Example: build stdout belongs to stderr even when compilation fails.
func TestResolverRejectsInvalidOrFailedPreparation(t *testing.T) {
	for _, failure := range []string{"arguments", "query", "build", "mutation", "CR", "LF"} {
		t.Run(failure,
			// Each failed preparation must report no selectable executable.
			//
			// Example: a rejected CR pathname still works through ordinary execution.
			func(t *testing.T) {
				f := newFixture(t)
				installCompilerDouble(t, &f)
				args := []string{"--resolve-executable"}
				switch failure {
				case "arguments":
					args = append(args, "--", "unexpected")
				case "query":
					writeFile(t, filepath.Join(f.Root, "query-fail"), "bootstrap", 0600)
				case "build":
					writeFile(t, filepath.Join(f.Root, "fail"), "", 0600)
					writeFile(t, filepath.Join(f.Root, "build-stdout"), "compiler-note\n", 0600)
				case "mutation":
					writeFile(t, filepath.Join(f.Root, "mutate"), "", 0600)
				case "CR":
					f.Cache += "\rpart"
					f.Env = append(f.Env, "OWNED_COMMAND_CACHE="+f.Cache)
				case "LF":
					f.Cache += "\npart"
					f.Env = append(f.Env, "OWNED_COMMAND_CACHE="+f.Cache)
				}
				out, stderr, err := f.run(t, args...)
				if err == nil || out != "" || stderr == "" {
					t.Fatalf("failed resolution returned a path: stdout=%q stderr=%q err=%v", out, stderr, err)
				}
				if failure == "arguments" {
					if _, err := os.Stat(filepath.Join(f.Root, "builds")); !os.IsNotExist(err) {
						t.Fatalf("invalid arguments reached preparation: %v", err)
					}
				}
				if failure == "CR" || failure == "LF" {
					requireSuccess(t, f)
				}
			})
	}
}

// TestConcurrentResolversPublishOnce uses compiler barriers to prove serialization.
//
// Example: two cold resolvers return the same executable after one checked build.
func TestConcurrentResolversPublishOnce(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	makeFIFO(t, filepath.Join(f.Root, "build-gate"))
	makeFIFO(t, filepath.Join(f.Root, "build-ready"))
	first, cancelFirst := f.command("--resolve-executable")
	defer cancelFirst()
	second, cancelSecond := f.command("--resolve-executable")
	defer cancelSecond()
	var firstOut, secondOut bytes.Buffer
	first.Stdout, second.Stdout = &firstOut, &secondOut
	for _, cmd := range []*exec.Cmd{first, second} {
		t.Cleanup(
			// Join every started resolver even after a barrier assertion fails.
			//
			// Example: cancellation retires a compiler waiting on the build FIFO.
			func() {
				if cmd.Process != nil && cmd.ProcessState == nil {
					if err := cmd.Cancel(); err != nil && !errors.Is(err, os.ErrProcessDone) {
						t.Error(err)
					}
					if err := cmd.Wait(); err != nil {
						var exit *exec.ExitError
						if !errors.As(err, &exit) {
							t.Error(err)
						}
					}
				}
			})
	}
	if err := first.Start(); err != nil {
		t.Fatal(err)
	}
	readBarrier(t, filepath.Join(f.Root, "build-ready"))
	if err := exec.Command("flock", "-n", filepath.Join(f.Cache, "build.lock"), "true").Run(); err == nil {
		t.Fatal("build barrier did not retain cache lock")
	}
	if err := second.Start(); err != nil {
		t.Fatal(err)
	}
	releaseBarrier(t, filepath.Join(f.Root, "build-gate"))
	for _, cmd := range []*exec.Cmd{first, second} {
		if err := cmd.Wait(); err != nil {
			t.Fatal(err)
		}
	}
	path := strings.TrimSuffix(firstOut.String(), "\n")
	if firstOut.String() != secondOut.String() || !filepath.IsAbs(path) || buildCount(t, f) != 1 {
		t.Fatalf("concurrent resolution first=%q second=%q builds=%d", firstOut.String(), secondOut.String(), buildCount(t, f))
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm()&0111 == 0 {
		t.Fatalf("concurrent result is not executable: %q %v", path, err)
	}
	if err := exec.Command("flock", "-n", filepath.Join(f.Cache, "build.lock"), "true").Run(); err != nil {
		t.Fatalf("resolvers retained the build lock: %v", err)
	}
}

// TestResolvedNativeExecution retains the execution caller's state without a compiler.
//
// Example: preparation environment is replaced by direct-call environment and exit37.
func TestResolvedNativeExecution(t *testing.T) {
	f := newFixture(t)
	writeFile(t, filepath.Join(f.Source, "main.go"), `package main
import("encoding/json";"io";"os")
func main(){cwd,err:=os.Getwd();if err!=nil{panic(err)};input,err:=io.ReadAll(os.Stdin);if err!=nil{panic(err)};if err:=json.NewEncoder(os.Stdout).Encode([]string{cwd,os.Getenv("RESOLVED_TOKEN"),string(input),os.Args[1]});err!=nil{panic(err)};if _,err:=os.Stderr.WriteString("diagnostic");err!=nil{panic(err)};os.Exit(37)}
`, 0600)
	f.Env = append(f.Env, "RESOLVED_TOKEN=preparation")
	path := resolvePath(t, f)
	cmd := exec.CommandContext(t.Context(), path, "space argument;$()")
	cmd.Dir = f.Caller
	cmd.Env = append(f.Env, "PATH=/no-compiler", "RESOLVED_TOKEN=execution")
	cmd.Stdin = strings.NewReader("input")
	var out, diagnostic bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &diagnostic
	err := cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 37 || diagnostic.String() != "diagnostic" {
		t.Fatalf("native direct status=%v stderr=%q", err, diagnostic.String())
	}
	var got []string
	if err := json.Unmarshal(out.Bytes(), &got); err != nil || strings.Join(got, "|") != strings.Join([]string{f.Caller, "execution", "input", "space argument;$()"}, "|") {
		t.Fatalf("direct caller state changed: %q %v", out.String(), err)
	}
}

// TestCompilerFailureAndMutation rejects stale fallback and partial publication.
//
// Example: a changed source during compilation must produce no new executable.
func TestCompilerFailureAndMutation(t *testing.T) {
	for _, mode := range []string{"fail", "mutate"} {
		t.Run(mode,
			// Each subtest independently owns its fixture and compiler failure mode.
			//
			// Example: the mutation case must reject publication after source changes.
			func(t *testing.T) {
				f := newFixture(t)
				installCompilerDouble(t, &f)
				requireSuccess(t, f)
				writeFile(t, filepath.Join(f.Source, "extra.go"), "package main\n", 0600)
				writeFile(t, filepath.Join(f.Root, mode), "yes", 0600)
				out, stderr, err := f.run(t)
				if err == nil || out != "" {
					t.Fatalf("stale execution: out=%q err=%v", out, err)
				}
				if mode == "fail" && !strings.Contains(stderr, "deliberate compiler failure") {
					t.Fatalf("compiler error lost: %q", stderr)
				}
				if mode == "mutate" && !strings.Contains(stderr, "source changed") {
					t.Fatalf("mutation error lost: %q", stderr)
				}
				if paths := cachedExecutables(t, f); len(paths) != 1 {
					t.Fatalf("partial publication: %v", paths)
				}
				leftovers, err := filepath.Glob(filepath.Join(f.Cache, ".build.*"))
				if err != nil {
					t.Fatal(err)
				}
				if len(leftovers) != 0 {
					t.Fatalf("temporary directories: %v", leftovers)
				}
				if err := os.Remove(filepath.Join(f.Root, mode)); err != nil {
					t.Fatal(err)
				}
				requireSuccess(t, f)
			})
	}
}

// TestEffectiveCacheInputs checks compiler version and retained build settings.
//
// Example: changing GOMODCACHE invalidates the previously built executable.
func TestEffectiveCacheInputs(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	requireSuccess(t, f)
	writeFile(t, filepath.Join(f.Root, "version"), "go1.26.6\n", 0600)
	requireSuccess(t, f)
	for _, setting := range []string{"GOPATH=/disposable-path", "GOMODCACHE=/disposable-modules", "GOEXPERIMENT=example-experiment", "GOFIPS140=latest"} {
		f.Env = append(f.Env, setting)
		requireSuccess(t, f)
	}
	if n := buildCount(t, f); n != 6 {
		t.Fatalf("cache input changes yielded %d builds; want 6", n)
	}
}

// TestRealCompilerNativePolicy proves host policy and caller transparency.
//
// Example: forced external linking cannot invoke an unusable foreign C compiler.
func TestRealCompilerNativePolicy(t *testing.T) {
	f := newFixture(t)
	source := `package main
import("encoding/json";"io";"os";"runtime")
func main(){cwd,err:=os.Getwd();if err!=nil{panic(err)};input,err:=io.ReadAll(os.Stdin);if err!=nil{panic(err)};if err:=os.WriteFile("relative.receipt",[]byte("receipt"),0600);err!=nil{panic(err)};if err:=json.NewEncoder(os.Stdout).Encode(map[string]any{"cwd":cwd,"args":os.Args[1:],"stdin":string(input),"GOOS":os.Getenv("GOOS"),"GOARCH":os.Getenv("GOARCH"),"GOENV":os.Getenv("GOENV"),"GOFLAGS":os.Getenv("GOFLAGS"),"GO_EXTLINK_ENABLED":os.Getenv("GO_EXTLINK_ENABLED"),"native":runtime.GOOS+"/"+runtime.GOARCH});err!=nil{panic(err)};if _,err:=os.Stderr.WriteString("stderr-token");err!=nil{panic(err)};os.Exit(125)}
`
	writeFile(t, filepath.Join(f.Source, "main.go"), source, 0600)
	// A conflicting persisted module/work/flags policy must be suppressed.
	writeFile(t, filepath.Join(f.Caller, "review.env"), "GO111MODULE=off\nGOWORK=/nonexistent/work\nGOFLAGS=-mod=vendor\nGOPROXY=off\nGOSUMDB=off\n", 0600)
	f.Env = append(f.Env, "GOENV=review.env", "GOOS=windows", "GOARCH=amd64", "GO111MODULE=off", "GOWORK=/nonexistent/work", "GOFLAGS=-nonexistent-flag", "CGO_ENABLED=1", "GO_EXTLINK_ENABLED=1", "CC=/nonexistent/foreign-target-cc", "GOAMD64=v4", "GOARM64=v9.5")
	out, stderr, err := f.run(t, "space arg", "literal;$()")
	exit, ok := err.(*exec.ExitError)
	if !ok || exit.ExitCode() != 125 {
		t.Fatalf("status=%v stdout=%q stderr=%q", err, out, stderr)
	}
	var got struct {
		Cwd                                                             string   `json:"cwd"`
		Args                                                            []string `json:"args"`
		Stdin, GOOS, GOARCH, GOENV, GOFLAGS, GO_EXTLINK_ENABLED, Native string
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatal(err)
	}
	if got.Cwd != f.Caller || got.Stdin != "stdin-token" || got.Native != runtime.GOOS+"/"+runtime.GOARCH || strings.Join(got.Args, "|") != "space arg|literal;$()" || got.GOOS != "windows" || got.GOARCH != "amd64" || got.GOENV != "review.env" || got.GOFLAGS != "-nonexistent-flag" || got.GO_EXTLINK_ENABLED != "1" || stderr != "stderr-token" {
		t.Fatalf("caller state changed: %+v stderr=%q", got, stderr)
	}
	if data, err := os.ReadFile(filepath.Join(f.Caller, "relative.receipt")); err != nil || string(data) != "receipt" {
		t.Fatalf("relative receipt=%q err=%v", data, err)
	}
	if _, err := os.Stat(filepath.Join(f.Source, "relative.receipt")); !os.IsNotExist(err) {
		t.Fatalf("receipt leaked to source cwd: %v", err)
	}
}

// TestRealCompilerExternalLinkIsolation isolates the forced-link regression.
//
// Example: an inherited foreign CC remains visible to the launched child.
func TestRealCompilerExternalLinkIsolation(t *testing.T) {
	f := newFixture(t)
	writeFile(t, filepath.Join(f.Source, "main.go"), "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"child\")}\n", 0600)
	f.Env = append(f.Env, "GO_EXTLINK_ENABLED=1", "CC=/nonexistent/foreign-target-cc")
	requireSuccess(t, f)
}

// TestRelativeGOENVRetainsEffectiveCacheIdentity proves caller-relative defaults.
//
// Example: editing only the persisted GOPATH must produce a distinct cache key.
func TestRelativeGOENVRetainsEffectiveCacheIdentity(t *testing.T) {
	f := newFixture(t)
	writeFile(t, filepath.Join(f.Source, "main.go"), "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"child\")}\n", 0600)
	config := filepath.Join(f.Caller, "review.env")
	writeFile(t, config, "GOPATH="+filepath.Join(f.Root, "path-one")+"\nGOPROXY=off\nGOSUMDB=off\n", 0600)
	f.Env = append(f.Env, "GOENV=review.env")
	requireSuccess(t, f)
	writeFile(t, config, "GOPATH="+filepath.Join(f.Root, "path-two")+"\nGOPROXY=off\nGOSUMDB=off\n", 0600)
	requireSuccess(t, f)
	if paths := cachedExecutables(t, f); len(paths) != 2 {
		t.Fatalf("relative GOENV effective GOPATH change produced %d keys, want 2", len(paths))
	}
}

// makeFIFO creates an observable subprocess barrier without timing sleeps.
//
// Example: a compiler double blocks until its test releases build-gate.
func makeFIFO(
	t *testing.T,
	path string,
) {
	t.Helper()
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
}

// readBarrier waits for a subprocess to reach an instrumented boundary.
//
// Example: build-ready proves the first compiler owns the cache lock.
func readBarrier(
	t *testing.T,
	path string,
) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, "cat", path).Output()
	if err != nil || string(data) != "ready\n" {
		t.Fatalf("barrier=%q err=%v", data, err)
	}
}

// releaseBarrier unblocks one FIFO-controlled subprocess.
//
// Example: child-gate lets a launched program exit after a lock check.
func releaseBarrier(
	t *testing.T,
	path string,
) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "bash", "-c", "printf 'continue\n' > \"$1\"", "barrier", path).CombinedOutput(); err != nil {
		t.Fatalf("release barrier: %v %s", err, out)
	}
}

// TestConcurrentBuildAndChildLockRelease checks serialization and exec lifetime.
//
// Example: another launcher may finish while the first child remains blocked.
func TestConcurrentBuildAndChildLockRelease(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	for _, name := range []string{"build-gate", "build-ready"} {
		makeFIFO(t, filepath.Join(f.Root, name))
	}
	first, cancelFirst := f.command()
	defer cancelFirst()
	if err := first.Start(); err != nil {
		t.Fatal(err)
	}
	// Cleanup waits for every process started by the test even after assertions fail.
	defer func() {
		cancelFirst()
		if first.ProcessState == nil {
			if err := first.Wait(); err != nil {
				if _, ok := err.(*exec.ExitError); !ok {
					t.Error(err)
				}
			}
		}
	}()
	readBarrier(t, filepath.Join(f.Root, "build-ready"))
	lock := exec.Command("flock", "-n", filepath.Join(f.Cache, "build.lock"), "true")
	if err := lock.Run(); err == nil {
		t.Fatal("build lock is not held during compilation")
	}
	second, cancelSecond := f.command()
	defer cancelSecond()
	if err := second.Start(); err != nil {
		t.Fatal(err)
	}
	// Cleanup accounts for the second competing launcher on failure.
	defer func() {
		cancelSecond()
		if second.ProcessState == nil {
			if err := second.Wait(); err != nil {
				if _, ok := err.(*exec.ExitError); !ok {
					t.Error(err)
				}
			}
		}
	}()
	releaseBarrier(t, filepath.Join(f.Root, "build-gate"))
	if err := first.Wait(); err != nil {
		t.Fatal(err)
	}
	if err := second.Wait(); err != nil {
		t.Fatal(err)
	}
	if n := buildCount(t, f); n != 1 {
		t.Fatalf("concurrent builds=%d, want 1", n)
	}
	for _, name := range []string{"child-gate", "child-ready"} {
		makeFIFO(t, filepath.Join(f.Root, name))
	}
	child, cancelChild := f.command()
	defer cancelChild()
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	// Cleanup reaps the child even if release-before-exec is broken.
	defer func() {
		cancelChild()
		if child.ProcessState == nil {
			if err := child.Wait(); err != nil {
				if _, ok := err.(*exec.ExitError); !ok {
					t.Error(err)
				}
			}
		}
	}()
	readBarrier(t, filepath.Join(f.Root, "child-ready"))
	if err := exec.Command("flock", "-n", filepath.Join(f.Cache, "build.lock"), "true").Run(); err != nil {
		t.Fatalf("lock retained by final child: %v", err)
	}
	next := f
	next.Env = append(append([]string(nil), f.Env...), "DOUBLE_CHILD_SKIP=1")
	requireSuccess(t, next)
	if child.ProcessState != nil {
		t.Fatal("first child unexpectedly exited before release")
	}
	releaseBarrier(t, filepath.Join(f.Root, "child-gate"))
	if err := child.Wait(); err != nil {
		t.Fatal(err)
	}
}

// executedPath observes which immutable leaf the launcher actually selected.
//
// Example: removing an added source file must return to the earlier content key.
func executedPath(
	t *testing.T,
	f launcherFixture,
) string {
	t.Helper()
	out, stderr, err := f.run(t, "--report-path")
	if err != nil || stderr != "" {
		t.Fatalf("path query stdout=%q stderr=%q err=%v", out, stderr, err)
	}
	return strings.TrimSpace(out)
}

// TestNativePolicyAndRetainedEnvironment checks host policy and transport.
//
// Example: target overrides preserve the configured module proxy and caches.
func TestNativePolicyAndRetainedEnvironment(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	f.Env = append(f.Env, "GOPROXY=https://proxy.invalid.example", "GOSUMDB=off", "GONOPROXY=private.example", "GONOSUMDB=private.example", "GOPRIVATE=private.example", "GOCACHE="+filepath.Join(f.Root, "go-cache"), "GOTMPDIR="+f.Root, "GOOS=windows", "GOARCH=arm64", "GOAMD64=v4", "GO_EXTLINK_ENABLED=1")
	requireSuccess(t, f)
	data, err := os.ReadFile(filepath.Join(f.Root, "build-env"))
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []string{"GOOS=linux", "GOARCH=amd64", "GOAMD64=v1", "GO111MODULE=on", "GOWORK=off", "CGO_ENABLED=0", "GOFLAGS= ", "GO_EXTLINK_ENABLED=0", "GOTOOLCHAIN=local", "GOPROXY=https://proxy.invalid.example", "GOSUMDB=off", "GOPRIVATE=private.example", "GONOPROXY=private.example", "GONOSUMDB=private.example", "GOCACHE=" + filepath.Join(f.Root, "go-cache"), "GOTMPDIR=" + f.Root} {
		if !strings.Contains("\n"+string(data), "\n"+item+"\n") {
			t.Errorf("build environment missing %q", item)
		}
	}
}

// TestRealCompilerNativeDefaults checks recorded ISA against selected Go defaults.
//
// Example: caller v9.5 tuning must not replace the compiler's host ARM64 default.
func TestRealCompilerNativeDefaults(t *testing.T) {
	f := newFixture(t)
	writeFile(t, filepath.Join(f.Source, "main.go"), "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"child\")}\n", 0600)
	f.Env = append(f.Env, "GOAMD64=v4", "GOARM64=v9.5", "CGO_ENABLED=1")
	requireSuccess(t, f)
	paths := cachedExecutables(t, f)
	if len(paths) != 1 {
		t.Fatalf("published paths=%v", paths)
	}
	info, err := buildinfo.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	settings := make(map[string]string)
	for _, setting := range info.Settings {
		settings[setting.Key] = setting.Value
	}
	if settings["GOOS"] != runtime.GOOS || settings["GOARCH"] != runtime.GOARCH || settings["CGO_ENABLED"] != "0" || info.Main.Path != "disposable.example/probe" {
		t.Fatalf("native/module/cgo metadata=%v module=%v", settings, info.Main)
	}
	archVar := map[string]string{"386": "GO386", "amd64": "GOAMD64", "arm": "GOARM", "arm64": "GOARM64", "mips": "GOMIPS", "mipsle": "GOMIPS", "mips64": "GOMIPS64", "mips64le": "GOMIPS64", "ppc64": "GOPPC64", "ppc64le": "GOPPC64", "riscv64": "GORISCV64", "wasm": "GOWASM"}[runtime.GOARCH]
	if archVar == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	probe := exec.CommandContext(ctx, filepath.Join(runtime.GOROOT(), "bin", "go"), "env", archVar)
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if strings.HasPrefix(key, "GO") || key == "CGO_ENABLED" {
			continue
		}
		probe.Env = append(probe.Env, item)
	}
	probe.Env = append(probe.Env, "GOENV=off", "GOTOOLCHAIN=local", "GOOS="+runtime.GOOS, "GOARCH="+runtime.GOARCH, "GO_EXTLINK_ENABLED=0", "CGO_ENABLED=0")
	out, err := probe.Output()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := settings[archVar], strings.TrimSpace(string(out)); got != want || got == "" {
		t.Fatalf("native tuning %s=%q, selected compiler default=%q", archVar, got, want)
	}
}

// TestRequestedToolchainCacheIdentity preserves the requested selection in keys.
//
// Example: local versus auto can resolve one compiler but remain distinct requests.
func TestRequestedToolchainCacheIdentity(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	requireSuccess(t, f)
	f.Env = append(f.Env, "GOTOOLCHAIN=auto")
	requireSuccess(t, f)
	if n := buildCount(t, f); n != 2 {
		t.Fatalf("requested toolchain builds=%d, want 2", n)
	}
}

// TestFinalGOENVAndNativeStatus checks absent, empty and off caller states.
//
// Example: child status 37 is forwarded without rewriting empty GOENV to off.
func TestFinalGOENVAndNativeStatus(t *testing.T) {
	for _, state := range []string{"absent", "empty", "off"} {
		t.Run(state,
			// Each case proves a distinct final environment state and native exit value.
			//
			// Example: the absent case checks LookupEnv, not just an empty string.
			func(t *testing.T) {
				f := newFixture(t)
				writeFile(t, filepath.Join(f.Source, "main.go"), `package main
import("fmt";"os";"strconv")
func main(){v,ok:=os.LookupEnv("GOENV");fmt.Printf("%t:%s",ok,v);code,err:=strconv.Atoi(os.Args[1]);if err!=nil{panic(err)};os.Exit(code)}
`, 0600)
				var env []string
				for _, item := range f.Env {
					if !strings.HasPrefix(item, "GOENV=") {
						env = append(env, item)
					}
				}
				f.Env = env
				switch state {
				case "empty":
					f.Env = append(f.Env, "GOENV=")
				case "off":
					f.Env = append(f.Env, "GOENV=off")
				}
				for _, code := range []string{"0", "37", "125"} {
					out, stderr, err := f.run(t, code)
					want := "false:"
					switch state {
					case "empty":
						want = "true:"
					case "off":
						want = "true:off"
					}
					if out != want || stderr != "" {
						t.Fatalf("final environment stdout=%q want=%q stderr=%q", out, want, stderr)
					}
					if code == "0" {
						if err != nil {
							t.Fatal(err)
						}
						continue
					}
					exit, ok := err.(*exec.ExitError)
					if !ok || exit.Error() != "exit status "+code {
						t.Fatalf("status=%v want=%s", err, code)
					}
				}
			})
	}
}

// TestSelectedRootOverridesCallerRoot isolates selected compiler root ownership.
//
// Example: a downloaded toolchain root replaces caller GOROOT only for compilation.
func TestSelectedRootOverridesCallerRoot(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	f.Env = append(f.Env, "GOROOT=/caller/root")
	requireSuccess(t, f)
	for _, name := range []string{"build-env", "defaults-env"} {
		data, err := os.ReadFile(filepath.Join(f.Root, name))
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains("\n"+string(data), "\nGOROOT="+f.Root+"\n") {
			t.Fatalf("%s did not select compiler GOROOT=%s", name, f.Root)
		}
	}
	out, stderr, err := f.run(t, "--report-goroot")
	if err != nil || out != "/caller/root\n" || stderr != "" {
		t.Fatalf("final caller GOROOT stdout=%q stderr=%q err=%v", out, stderr, err)
	}
}

// TestSelectedCompilerPathCacheIdentity distinguishes identical compiler copies.
//
// Example: selecting a different compiler root publishes another cache key.
func TestSelectedCompilerPathCacheIdentity(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	// Keep dependency cache identity fixed while changing only compiler selection.
	f.Env = append(f.Env, "GOPATH="+filepath.Join(f.Root, "fixed-path"), "GOMODCACHE="+filepath.Join(f.Root, "fixed-modules"))
	requireSuccess(t, f)
	other := f
	other.Root = filepath.Join(f.Root, "other-compiler")
	installCompilerDouble(t, &other)
	requireSuccess(t, other)
	if paths := cachedExecutables(t, f); len(paths) != 2 {
		t.Fatalf("compiler root/path change published %d keys, want 2", len(paths))
	}
}

// TestSelectedCompilerBytesCacheIdentity separates compiler content from version.
//
// Example: changing a compiler at its existing path must invalidate a warm cache.
func TestSelectedCompilerBytesCacheIdentity(t *testing.T) {
	f := newFixture(t)
	installCompilerDouble(t, &f)
	requireSuccess(t, f)
	compiler := filepath.Join(f.Root, "bin", "go")
	body, err := os.ReadFile(compiler)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, compiler, string(body)+"\n# same reported version, different compiler bytes\n", 0700)
	requireSuccess(t, f)
	if n := buildCount(t, f); n != 2 {
		t.Fatalf("compiler byte change builds=%d, want 2", n)
	}
}

// TestCompilerQueryFailures rejects stale cache execution in every query phase.
//
// Example: a post-build fingerprint failure cleans the unpublished temporary binary.
func TestCompilerQueryFailures(t *testing.T) {
	for _, phase := range []string{"bootstrap", "defaults", "steady", "version", "post-version"} {
		t.Run(phase,
			// Each query phase fails against a preexisting good executable.
			//
			// Example: a warm cache does not hide a compiler-selection error.
			func(t *testing.T) {
				f := newFixture(t)
				installCompilerDouble(t, &f)
				requireSuccess(t, f)
				if err := os.Remove(filepath.Join(f.Root, "postbuild")); err != nil {
					t.Fatal(err)
				}
				if phase == "post-version" {
					writeFile(t, filepath.Join(f.Source, "extra.go"), "package main\n", 0600)
				}
				writeFile(t, filepath.Join(f.Root, "query-fail"), phase, 0600)
				out, stderr, err := f.run(t)
				if err == nil || out != "" || !strings.Contains(stderr, "deliberate "+phase+" query failure") {
					t.Fatalf("query failure out=%q stderr=%q err=%v", out, stderr, err)
				}
				if paths := cachedExecutables(t, f); len(paths) != 1 {
					t.Fatalf("query failure published stale/partial executable: %v", paths)
				}
				leftovers, err := filepath.Glob(filepath.Join(f.Cache, ".build.*"))
				if err != nil {
					t.Fatal(err)
				}
				if len(leftovers) != 0 {
					t.Fatalf("query failure temporary directories=%v", leftovers)
				}
				if err := os.Remove(filepath.Join(f.Root, "query-fail")); err != nil {
					t.Fatal(err)
				}
				requireSuccess(t, f)
			})
	}
}

// TestExportedGoFunctionCompilerDiscovery selects PATH compilers behind functions.
//
// Example: an exported forwarding function remains available to the final child.
func TestExportedGoFunctionCompilerDiscovery(t *testing.T) {
	for _, callerGo := range []bool{false, true} {
		t.Run(strconv.FormatBool(callerGo),
			// Each case keeps the inherited function while varying a caller-local file.
			//
			// Example: a misleading executable named go must not replace the PATH compiler.
			func(t *testing.T) {
				f := newFixture(t)
				writeFile(t, filepath.Join(f.Source, "main.go"), `package main
import("encoding/json";"os";"runtime")
func main(){cwd,err:=os.Getwd();if err!=nil{panic(err)};if err:=json.NewEncoder(os.Stdout).Encode(map[string]string{"cwd":cwd,"function":os.Getenv("BASH_FUNC_go%%"),"native":runtime.GOOS+"/"+runtime.GOARCH});err!=nil{panic(err)}}
`, 0600)
				// exportedGo is Bash's standard environment representation of this function.
				//
				// Example: go() { command go "$@"; }; export -f go.
				const exportedGo = "() {  command go \"$@\"\n}"
				f.Env = append(f.Env, "BASH_FUNC_go%%="+exportedGo)
				if callerGo {
					writeFile(t, filepath.Join(f.Caller, "go"), "#!/bin/sh\nprintf 'wrong caller compiler\\n' >&2\nexit 91\n", 0700)
				}
				out, stderr, err := f.run(t)
				if err != nil || stderr != "" {
					t.Fatalf("PATH compiler discovery stdout=%q stderr=%q err=%v", out, stderr, err)
				}
				var got struct {
					Cwd, Function, Native string
				}
				if err := json.Unmarshal([]byte(out), &got); err != nil {
					t.Fatal(err)
				}
				if got.Cwd != f.Caller || got.Function != exportedGo || got.Native != runtime.GOOS+"/"+runtime.GOARCH {
					t.Fatalf("caller state or native compiler changed: %+v", got)
				}
			})
	}
}

// TestMissingGoDiagnostic explains unavailable PATH compilers without stale execution.
//
// Example: removing Go after a cached build still reports the missing compiler.
func TestMissingGoDiagnostic(t *testing.T) {
	for _, warm := range []bool{false, true} {
		t.Run(strconv.FormatBool(warm),
			// Each case excludes Go while retaining the launcher's preliminary tools.
			//
			// Example: an exported forwarding function cannot satisfy PATH discovery.
			func(t *testing.T) {
				f := newFixture(t)
				installCompilerDouble(t, &f)
				if warm {
					requireSuccess(t, f)
				}
				bin := filepath.Join(f.Root, "without-go")
				if err := os.Mkdir(bin, 0700); err != nil {
					t.Fatal(err)
				}
				for _, name := range []string{"bash", "realpath"} {
					path, err := exec.LookPath(name)
					if err != nil {
						t.Fatal(err)
					}
					if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
						t.Fatal(err)
					}
				}
				f.Env = append(f.Env, "PATH="+bin, "BASH_FUNC_go%%=() {  command go \"$@\"\n}")
				out, stderr, err := f.run(t)
				var exit *exec.ExitError
				if !errors.As(err, &exit) || exit.ExitCode() != 1 || out != "" || !strings.Contains(stderr, "owned-command: Go compiler not found in PATH") {
					t.Fatalf("missing Go stdout=%q stderr=%q err=%v", out, stderr, err)
				}
				wantLeaves := 0
				if warm {
					wantLeaves = 1
					if count := buildCount(t, f); count != 1 {
						t.Fatalf("missing Go triggered builds=%d", count)
					}
				}
				if leaves := cachedExecutables(t, f); len(leaves) != wantLeaves {
					t.Fatalf("missing Go changed cache leaves=%v", leaves)
				}
			})
	}
}
