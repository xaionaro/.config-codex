package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	// outputCaptureByteLimit bounds complete metadata and diagnostic prefixes separately.
	//
	// Example: excess output is drained and invalidates the observation.
	outputCaptureByteLimit = 1024 * 1024
	// observationDeadline bounds opaque native processes without resuming blocked helpers.
	//
	// Example: a native input stall becomes Advisory after ten seconds.
	observationDeadline = 10 * time.Second
	// launchCaptureByteLimit bounds the transient native preparation capture.
	//
	// Example: an oversized or incomplete launch capture cannot certify a helper.
	launchCaptureByteLimit = 8 * 1024 * 1024
	// traceEventByteLimit bounds one complete Trace2 JSON event.
	//
	// Example: a malformed oversized event becomes Advisory.
	traceEventByteLimit = 4 * 1024 * 1024
)

// outputPurpose selects the closed set of native stdout handling policies.
//
// Example: replayOutput sends inspection stdout directly to the private null device.
type outputPurpose int

const (
	// metadataOutput retains bounded complete metadata for interpretation.
	//
	// Example: effective config must be captured completely before parsing.
	metadataOutput outputPurpose = iota + 1
	// replayOutput discards stdout while preserving native exit and trace evidence.
	//
	// Example: showing a large blob retains no stdout bytes.
	replayOutput
)

// boundedOutput drains every write while retaining at most its limit.
//
// Example: overflow records rejected output without causing native EPIPE.
type boundedOutput struct {
	buffer   bytes.Buffer
	limit    int
	overflow bool
}

// Write consumes all bytes and records whether the complete payload exceeded the bound.
//
// Example: writing limit+1 bytes returns the original count and no pipe error.
func (output *boundedOutput) Write(data []byte) (int, error) {
	retained := len(data)
	if remaining := output.limit - output.buffer.Len(); retained > remaining {
		retained = remaining
		output.overflow = true
	}
	// bytes.Buffer.Write always returns a nil error and consumes the supplied bytes.
	_, _ = output.buffer.Write(data[:retained])
	return len(data), nil
}

// traceEvent contains the Git 2.51 event fields needed for first-child evidence.
//
// Example: child_start supplies prospective argv before blocked process creation.
type traceEvent struct {
	Event      string          `json:"event"`
	Thread     string          `json:"thread"`
	Name       string          `json:"name"`
	Argv       []string        `json:"argv"`
	CWD        string          `json:"cd"`
	UseShell   bool            `json:"use_shell"`
	ChildClass string          `json:"child_class"`
	Message    string          `json:"msg"`
	Code       int             `json:"code"`
	ChildID    int             `json:"child_id"`
	PID        int             `json:"pid"`
	Param      string          `json:"param"`
	Value      json.RawMessage `json:"value"`
	Worktree   string          `json:"worktree"`
}

// sandbox owns disposable same-path administration, temporary storage and trace files.
//
// Example: sandbox.run executes config or observation with the original root read-only.
type sandbox struct {
	dir         string
	cwd         string
	gitdir      string
	tmpdir      string
	env         map[string]string
	bwrap       string
	git         string
	launchTrace []byte
}

// advisory explains why no executable-helper conclusion can be established.
//
// Example: advisory("unsupported index") preserves ordinary inspection admission.
func advisory(reason string) Observation { return Observation{Result: Advisory, Reason: reason} }

// admission rejects contexts that cannot be observed faithfully before running subprocesses.
//
// Example: effective loader debug controls return an explanatory reason immediately.
func admission(in Invocation) (int, string) {
	for key, value := range in.Environment {
		if !literalEnvironmentKey(key) {
			return 0, "unsupported environment key for literal native capture"
		}
		if value != "" && unmodeledLoaderKey(key) {
			return 0, "unmodeled loader environment: " + key
		}
		if value != "" && value != "0" && (strings.HasPrefix(key, "GIT_TRACE") || key == "GIT_FLUSH") {
			return 0, "unmodeled original trace or inherited descriptor channel: " + key
		}
		switch key {
		case "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_ATTR_SOURCE":
			if value != "" && key != "GIT_CONFIG_NOSYSTEM" {
				return 0, "unsupported repository/config environment: " + key
			}
		}
	}
	if runtime.GOOS != "linux" || runtime.GOARCH != "arm64" {
		return 0, "unsupported platform; requires Linux arm64"
	}
	if !filepath.IsAbs(in.CWD) {
		return 0, "cwd must be an absolute existing physical path"
	}
	roles := AnalyzeArguments(in.Arguments)
	if !roles.Complete || !roles.Eligible {
		return 0, roles.Reason
	}
	return roles.VerbIndex, ""
}

// unmodeledLoaderKey identifies controls for unmodeled dynamic loading or libc trace/locale lookup.
//
// Example: GCONV_PATH can select loadable conversion modules outside ordinary Git semantics.
func unmodeledLoaderKey(key string) bool {
	return strings.HasPrefix(key, "LD_") || key == "GLIBC_TUNABLES" || key == "GCONV_PATH" || key == "LOCPATH" || key == "MALLOC_TRACE"
}

// literalEnvironmentKey admits exactly the identifier syntax Trace2 can request without reinterpretation.
//
// Example: PATH is admitted, while an environment name containing a comma is Advisory.
func literalEnvironmentKey(key string) bool {
	if key == "" {
		return false
	}
	for index, char := range key {
		if char == '_' || char >= 'A' && char <= 'Z' || char >= 'a' && char <= 'z' {
			continue
		}
		if index != 0 && char >= '0' && char <= '9' {
			continue
		}
		return false
	}
	return true
}

// newSandbox prepares original same-path overlays without executing Git or helpers.
//
// Example: newSandbox(in) isolates ordinary .git and TMPDIR writes.
func newSandbox(in Invocation) (*sandbox, error) {
	physical, err := filepath.EvalSymlinks(in.CWD)
	if err != nil {
		return nil, fmt.Errorf("resolve cwd: %w", err)
	}
	gitdir := ""
	for path := physical; ; path = filepath.Dir(path) {
		candidate := filepath.Join(path, ".git")
		info, err := os.Lstat(candidate)
		if err == nil {
			if !info.IsDir() {
				return nil, fmt.Errorf("unsupported linked/separate or symlink administration")
			}
			gitdir = candidate
			break
		}
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("inspect administration: %w", err)
		}
		if filepath.Dir(path) == path {
			return nil, fmt.Errorf("ordinary .git directory not found")
		}
	}
	for _, name := range []string{"commondir", "objects/info/alternates", "objects/info/http-alternates", "shallow", "info/sparse-checkout"} {
		if _, err := os.Lstat(filepath.Join(gitdir, name)); !os.IsNotExist(err) {
			return nil, fmt.Errorf("unsupported repository layout: %s", name)
		}
	}
	if physical == gitdir || strings.HasPrefix(physical, gitdir+"/") {
		return nil, fmt.Errorf("unsupported administrative cwd")
	}
	entries, err := os.ReadDir(filepath.Join(gitdir, "objects", "pack"))
	if err != nil {
		return nil, fmt.Errorf("inspect object pack layout: %w", err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".promisor") {
			return nil, fmt.Errorf("unsupported promisor object store")
		}
	}
	tmp := in.Environment["TMPDIR"]
	if tmp == "" {
		tmp = "/tmp"
	}
	if !filepath.IsAbs(tmp) {
		return nil, fmt.Errorf("unsupported relative TMPDIR")
	}
	tmp, err = filepath.EvalSymlinks(tmp)
	if err != nil {
		return nil, fmt.Errorf("resolve TMPDIR: %w", err)
	}
	if physical == tmp || strings.HasPrefix(physical, tmp+"/") || strings.HasPrefix(gitdir, tmp+"/") {
		return nil, fmt.Errorf("TMPDIR overlaps worktree; isolated replay unavailable")
	}
	git, err := resolveProgram("git", physical, in.Environment)
	if err != nil {
		return nil, err
	}
	selected, err := os.Stat(git)
	if err != nil {
		return nil, err
	}
	native, err := os.Stat("/usr/bin/git")
	if err != nil || !os.SameFile(selected, native) {
		return nil, fmt.Errorf("unsupported native Git identity")
	}
	bwrap := "/usr/bin/bwrap"
	if info, err := os.Stat(bwrap); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("trusted bubblewrap unavailable")
	}
	dir, err := os.MkdirTemp("/var/tmp", "eci-git-inspection-")
	if err != nil {
		return nil, fmt.Errorf("create owned overlay: %w", err)
	}
	s := &sandbox{dir: dir, cwd: physical, gitdir: gitdir, tmpdir: tmp, env: in.Environment, bwrap: bwrap, git: git}
	if err := os.Mkdir(filepath.Join(dir, "tmp"), 0700); err != nil {
		return nil, errors.Join(err, os.RemoveAll(dir))
	}
	if err := validateAdministration(gitdir); err != nil {
		return nil, errors.Join(err, os.RemoveAll(dir))
	}
	return s, nil
}

// validateAdministration refuses unmodeled administrative symlinks and mutable stores.
//
// Example: copied textconv notes remain at the same logical .git path inside the mount.
func validateAdministration(source string) error {
	// The read-only lower tree is reused; native writes go into an invisible tmpfs overlay.
	entries, err := os.ReadDir(source)
	if err != nil {
		return fmt.Errorf("read administration: %w", err)
	}
	for _, entry := range entries {
		path := filepath.Join(source, entry.Name())
		if entry.IsDir() {
			if err := validateAdministration(path); err != nil {
				return err
			}
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("inspect administration: %w", err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("unsupported nonregular administration: %s", path)
		}
		if strings.HasPrefix(entry.Name(), "sharedindex.") {
			return fmt.Errorf("unsupported split index")
		}
	}
	return nil
}

// run executes a Git subprocess behind the same-path write and process boundaries.
//
// Example: run(configArgs, metadataOutput) reads includes without touching original state.
func (s *sandbox) run(
	args []string,
	purpose outputPurpose,
) (output []byte, events []traceEvent, status int, runErr error) {
	ctx, cancel := context.WithTimeout(context.Background(), observationDeadline)
	defer cancel()
	return s.runContext(ctx, args, purpose)
}

// runContext keeps native execution, collection and decoding within one supplied deadline.
//
// Example: Inspect shares its observation budget across config, version and replay.
func (s *sandbox) runContext(
	ctx context.Context,
	args []string,
	purpose outputPurpose,
) (output []byte, events []traceEvent, status int, runErr error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if purpose != metadataOutput && purpose != replayOutput {
		return nil, nil, 0, fmt.Errorf("unknown native output purpose")
	}
	filter, err := os.CreateTemp(s.dir, "filter-")
	if err != nil {
		return nil, nil, 0, err
	}
	// Record cleanup failure rather than asserting a successful observation.
	//
	// Example: a filter descriptor close failure invalidates the observation.
	defer func() {
		if err := filter.Close(); err != nil {
			runErr = errors.Join(runErr, fmt.Errorf("close observer filter: %w", err))
		}
	}()
	if err := writeFilter(filter); err != nil {
		return nil, nil, 0, err
	}
	if _, err := filter.Seek(0, 0); err != nil {
		return nil, nil, 0, err
	}
	trace, err := newTraceCapture(ctx, traceCaptureByteLimit)
	if err != nil {
		return nil, nil, 0, err
	}
	launch, err := newTraceCapture(ctx, launchCaptureByteLimit)
	if err != nil {
		cancel()
		_, closeErr := trace.finish()
		return nil, nil, 0, errors.Join(err, closeErr)
	}
	bargs := []string{"--die-with-parent", "--ro-bind", "/", "/", "--dev", "/dev", "--unshare-net", "--overlay-src", s.gitdir, "--tmp-overlay", s.gitdir, "--overlay-src", s.tmpdir, "--tmp-overlay", s.tmpdir, "--chdir", s.cwd, "--seccomp", "3"}
	bargs = append(bargs, s.git)
	bargs = append(bargs, args...)
	c := exec.CommandContext(ctx, s.bwrap, bargs...)
	if err := isolateObservationProcess(c); err != nil {
		cancel()
		_, traceErr := trace.finish()
		_, launchErr := launch.finish()
		return nil, nil, 0, errors.Join(err, traceErr, launchErr)
	}
	c.Dir = s.cwd
	c.Env = observerEnvironment(s.env)
	c.ExtraFiles = []*os.File{filter, trace.Writer, launch.Writer}
	stdout := boundedOutput{limit: outputCaptureByteLimit}
	stderr := boundedOutput{limit: outputCaptureByteLimit}
	if purpose == metadataOutput {
		c.Stdout = &stdout
	}
	c.Stderr = &stderr
	err = c.Start()
	if err != nil {
		cancel()
		_, traceErr := trace.finish()
		_, launchErr := launch.finish()
		return nil, nil, 0, errors.Join(fmt.Errorf("start sandbox: %w", err), traceErr, launchErr)
	}
	// Closing each parent's writer immediately permits collector EOF after native exit.
	// finish joins while the native process still runs and both collectors drain concurrently.
	traceData, traceErr := trace.finish()
	s.launchTrace, err = launch.finish()
	captureErr := errors.Join(traceErr, err)
	err = c.Wait()
	status = 0
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			status = exit.ExitCode()
		} else {
			return nil, nil, 0, fmt.Errorf("start sandbox: %w", err)
		}
	}
	if ctx.Err() != nil {
		return nil, nil, status, fmt.Errorf("observation deadline exceeded")
	}
	if stdout.overflow || stderr.overflow {
		return nil, nil, status, fmt.Errorf("native metadata or diagnostic output exceeded supported size")
	}
	if captureErr != nil {
		return nil, nil, status, fmt.Errorf("collect native trace: %w", captureErr)
	}
	events, err = decodeTraceCapture(ctx, traceData)
	if err != nil {
		return nil, nil, status, err
	}
	if len(events) == 0 {
		return nil, nil, status, fmt.Errorf("sandbox or native Trace2 unavailable: %s", strings.TrimSpace(stderr.buffer.String()))
	}
	return stdout.buffer.Bytes(), events, status, nil
}

// observerEnvironment isolates instrumentation while preserving original Git semantic inputs.
//
// Example: GIT_TRACE2_EVENT=4 targets the owned inherited trace descriptor.
func observerEnvironment(original map[string]string) []string {
	env := make(map[string]string, len(original)+8)
	for key, value := range original {
		if !unmodeledLoaderKey(key) {
			env[key] = value
		}
	}
	for _, key := range []string{"GIT_TRACE", "GIT_TRACE_SETUP", "GIT_TRACE_PACKET", "GIT_TRACE_PERFORMANCE", "GIT_TRACE_SHALLOW", "GIT_TRACE_CURL", "GIT_TRACE2", "GIT_TRACE2_PERF", "GIT_TRACE2_EVENT"} {
		env[key] = "0"
	}
	env["GIT_TRACE2_EVENT"] = "4"
	env["GIT_TRACE"] = "5"
	keys := make(map[string]bool, len(original)+16)
	for key := range original {
		if unmodeledLoaderKey(key) {
			continue
		}
		keys[key] = true
	}
	for _, key := range []string{"PATH", "GIT_EXEC_PATH", "GIT_PREFIX", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_PAGER", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS", "GIT_OPTIONAL_LOCKS"} {
		keys[key] = true
	}
	list := make([]string, 0, len(keys))
	for key := range keys {
		list = append(list, key)
	}
	sort.Strings(list)
	env["GIT_TRACE2_ENV_VARS"] = strings.Join(list, ",")
	return environmentList(env)
}

// capturedGitEnvironment reconstructs source-matched setup state from owned Trace2 def_param events.
//
// Example: effective PATH includes Git's exec directory before original PATH components.
func capturedGitEnvironment(
	original map[string]string,
	events []traceEvent,
	verb string,
	initialCWD string,
) (map[string]string, error) {
	env := make(map[string]string, len(original)+16)
	for key, value := range original {
		env[key] = value
	}
	env["GIT_PREFIX"] = ""
	matched := false
	captured := map[string]bool{}
	worktree := ""
	for _, event := range events {
		if event.Event == "child_start" {
			break
		}
		if event.Event == "def_repo" && event.Worktree != "" {
			if worktree != "" && worktree != event.Worktree {
				return nil, fmt.Errorf("ambiguous native worktree setup")
			}
			worktree = event.Worktree
		}
		if event.Event == "cmd_name" {
			matched = event.Name == verb
			continue
		}
		if matched && event.Event == "def_param" && !strings.HasPrefix(event.Param, "GIT_TRACE") {
			var value string
			if err := json.Unmarshal(event.Value, &value); err != nil {
				return nil, fmt.Errorf("decode native effective environment: %w", err)
			}
			env[event.Param] = value
			captured[event.Param] = true
		}
	}
	if !matched || env["GIT_EXEC_PATH"] == "" || env["PATH"] == "" {
		return nil, fmt.Errorf("effective native setup environment not captured")
	}
	for key, value := range original {
		if key == "GIT_PREFIX" || strings.HasPrefix(key, "GIT_TRACE") || unmodeledLoaderKey(key) && value == "" || value == "" {
			continue
		}
		if !captured[key] {
			return nil, fmt.Errorf("incomplete native effective environment capture: %s", key)
		}
	}
	if !captured["GIT_EXEC_PATH"] || !captured["PATH"] {
		return nil, fmt.Errorf("native PATH setup not captured")
	}
	// Diff emits cmd_name before its own setup. Ordinary discovery later sets this exact prefix.
	if worktree == "" {
		return nil, fmt.Errorf("native worktree setup not captured")
	}
	prefix, err := filepath.Rel(worktree, initialCWD)
	if err != nil || prefix == ".." || strings.HasPrefix(prefix, "../") {
		return nil, fmt.Errorf("native setup cwd outside captured worktree")
	}
	if prefix == "." {
		env["GIT_PREFIX"] = ""
	} else {
		env["GIT_PREFIX"] = filepath.ToSlash(prefix) + "/"
	}
	return env, nil
}

// readConfig decodes native NUL-delimited config at the original administration paths.
//
// Example: conditional gitdir includes appear under their original effective keys.
func readConfig(data []byte) (map[string]string, error) {
	// TODO: Return config alone; this decoder has no error-producing branch.
	config := map[string]string{}
	for _, record := range bytes.Split(data, []byte{0}) {
		if len(record) == 0 {
			continue
		}
		parts := bytes.SplitN(record, []byte{'\n'}, 2)
		if len(parts) == 1 {
			config[strings.ToLower(string(parts[0]))] = "true"
			continue
		}
		config[strings.ToLower(string(parts[0]))] = string(parts[1])
	}
	return config, nil
}

// resolveProgram reproduces Git's executable PATH selection without spawning a diagnostic.
//
// Example: a relative PATH component is resolved against the child cwd.
func resolveProgram(
	name string,
	cwd string,
	env map[string]string,
) (string, error) {
	if strings.Contains(name, "/") {
		if !filepath.IsAbs(name) {
			name = filepath.Join(cwd, name)
		}
		return name, nil
	}
	path, exists := env["PATH"]
	if !exists {
		return "", fmt.Errorf("unmodeled absent PATH")
	}
	for _, dir := range strings.Split(path, ":") {
		candidate := filepath.Join(dir, name)
		if !filepath.IsAbs(candidate) {
			candidate = filepath.Join(cwd, candidate)
		}
		info, err := os.Stat(candidate)
		if err == nil && !info.IsDir() && info.Mode().Perm()&0111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("executable unavailable on original PATH: %s", name)
}

// rawHatch reuses the analyzer boundary without altering original argument bytes.
//
// Example: conversion overrides follow every parsed option and precede real operands.
func rawHatch(
	args []string,
	verb int,
	monitor bool,
) []string {
	roles := AnalyzeArguments(args)
	if !roles.Complete || !roles.Eligible || roles.VerbIndex != verb {
		return nil
	}
	result := append([]string{}, args[:verb]...)
	if monitor {
		result = append(result, "-c", "core.fsmonitor=false")
	}
	if args[verb] == "status" {
		return append(result, args[verb:]...)
	}
	result = append(result, args[verb:roles.Boundary]...)
	if args[verb] != "grep" {
		result = append(result, "--no-ext-diff")
	}
	result = append(result, "--no-textconv")
	return append(result, args[roles.Boundary:]...)
}

// classify attributes only source-matched first child preparations.
//
// Example: textconv has exactly the configured command and one prepared filename.
func classify(
	event traceEvent,
	config map[string]string,
	env map[string]string,
) (string, string) {
	if len(event.Argv) == 0 || !event.UseShell {
		return "", ""
	}
	command := event.Argv[0]
	categories := map[string]bool{}
	// Git external diff supplies either an unmerged name or the full pair and optional rename fields.
	externalShape := len(event.Argv) == 2 || len(event.Argv) == 8 || len(event.Argv) == 9 || len(event.Argv) == 10
	if config["core.fsmonitor"] == command && len(event.Argv) == 3 && (event.Argv[1] == "1" || event.Argv[1] == "2") {
		categories["fsmonitor"] = true
	}
	for key, value := range config {
		if strings.HasPrefix(key, "diff.") && strings.HasSuffix(key, ".textconv") && value == command && len(event.Argv) == 2 {
			categories["textconv"] = true
		}
		if ((key == "diff.external") || (strings.HasPrefix(key, "diff.") && strings.HasSuffix(key, ".command"))) && value == command && externalShape {
			categories["external-diff"] = true
		}
	}
	if env["GIT_EXTERNAL_DIFF"] == command && command != "" && externalShape {
		categories["external-diff"] = true
	}
	if len(categories) == 1 {
		for category := range categories {
			return category, command
		}
	}
	return "", ""
}

// sortedEnvironmentList provides stable child environment entries for native preparation.
//
// Example: deterministic ordering makes fixture evidence reproducible.
func sortedEnvironmentList(env map[string]string) []string {
	out := environmentList(env)
	sort.Strings(out)
	return out
}
