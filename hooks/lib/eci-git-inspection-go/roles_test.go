package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestNativeEmittedHatchRoles executes the actual hatch and checks native helper effects.
//
// Example: the -- consumed by -e cannot become the insertion boundary.
func TestNativeEmittedHatchRoles(t *testing.T) {
	for _, args := range [][]string{
		{"grep", "--threads=1", "--textconv", "-e", "--", "--", "file.txt"},
		{"grep", "--threads=1", "--textconv", "--max-depth", "1", "-e", "new", "--", "file.txt"},
		{"grep", "--threads=1", "--textconv", "-nFe--", "--", "file.txt"},
		{"grep", "--threads=1", "--textconv", "(", "-e", "--", "--or", "-e", "new", ")", "--", "file.txt"},
		{"grep", "--threads=1", "--no-textconv", "--textconv", "-e", "new", "-e", "--", "--", "file.txt"},
	} {
		// Establish native reachability before executing the advertised raw route.
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			in, helper, marker := fixture(t)
			if err := os.WriteFile(helper, []byte("#!/bin/sh\necho reached >> '"+marker+"'\nprintf '%s\\n' -- new\n"), 0700); err != nil {
				t.Fatal(err)
			}
			in.Arguments = args
			runFixture(t, in, args...)
			if _, err := os.Stat(marker); err != nil {
				t.Fatal("native callback absent", err)
			}
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
			got := Inspect(in)
			if got.Result != Helper {
				t.Fatalf("native viable helper: %+v", got)
			}
			command := exec.Command("/usr/bin/git", got.Hatch...)
			command.Dir, command.Env = in.CWD, environmentList(in.Environment)
			output, err := command.CombinedOutput()
			if err != nil {
				if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 1 {
					t.Fatalf("hatch invalid: %v %s argv=%v", err, output, got.Hatch)
				}
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("hatch callback: %v argv=%v", err, got.Hatch)
			}
			raw := in
			raw.Arguments = got.Hatch
			if observation := Inspect(raw); observation.Result != NoHelper {
				t.Fatalf("hatch observation: %+v argv=%v", observation, got.Hatch)
			}
		})
	}
}

// TestArgumentQueryIsPure checks output facts without any usable native context.
//
// Example: unsupported loader input and nonexistent cwd do not erase an output fact.
func TestArgumentQueryIsPure(t *testing.T) {
	request := `{"query":"argument-roles","cwd":"/nonexistent/eci-role-query","arguments":["diff","--stat-width=80","--output=owned","--unknown-role"],"environment":{"LD_PRELOAD":"/unavailable"}}`
	var output bytes.Buffer
	if err := runCLI(strings.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	var result struct {
		Query    string `json:"query"`
		Output   bool   `json:"output"`
		Complete bool   `json:"complete"`
	}
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Query != "argument-roles" || !result.Output || result.Complete {
		t.Fatalf("lost pure output fact: %s", output.String())
	}
}

// TestArgumentRoleFacts checks orthogonal effects, exact boundaries and bounded unknown suffixes.
//
// Example: a known auxiliary value looking like --output is consumed literally.
func TestArgumentRoleFacts(t *testing.T) {
	cases := []struct {
		args                       []string
		output, complete, eligible bool
		boundary                   int
	}{
		{[]string{"log", "--no-merges", "--output=x"}, true, true, false, 3},
		{[]string{"log", "--merges", "--output=x"}, true, true, false, 3},
		{[]string{"log", "--follow", "--output=x"}, true, true, false, 3},
		{[]string{"diff", "--stat-width=80", "--output=x"}, true, true, false, 3},
		{[]string{"diff", "--stat-width", "80", "--output=x", "--unknown"}, true, false, false, 5},
		{[]string{"diff", "--unknown", "--output=x"}, false, false, false, 3},
		{[]string{"diff", "--stat", "--output=x"}, true, true, false, 3},
		{[]string{"diff", "-O", "--output=order", "--output=x"}, true, true, false, 4},
		{[]string{"diff", "-O--output=order"}, false, true, false, 2},
		{[]string{"grep", "-f", "--output=pattern"}, false, true, false, 3},
		{[]string{"grep", "-O", "pattern", "--", "--output=leaf"}, false, true, false, 2},
		{[]string{"grep", "-ne", "--", "--", "file"}, false, true, true, 3},
		{[]string{"grep", "--max-depth", "1", "-e", "new", "file"}, false, true, true, 5},
		{[]string{"grep", "(", "-e", "--", "--or", "-e", "new", ")", "--", "file"}, false, true, true, 8},
		{[]string{"grep", "pattern", "--output=x"}, false, true, true, 1},
		{[]string{"log", "HEAD", "--author", "--output=author", "--output=x"}, true, true, false, 5},
		{[]string{"log", "--date", "iso", "--encoding=UTF-8", "--output=x"}, true, true, false, 5},
		{[]string{"log", "--pretty", "--output=x"}, true, true, false, 3},
		{[]string{"log", "--format", "--output=x"}, false, false, false, 3},
		{[]string{"log", "--filter=blob:none", "--output=x"}, true, true, false, 3},
		{[]string{"diff", "--", "--output=leaf", "-"}, false, true, true, 1},
		{[]string{"--config-env", "core.fsmonitor=MONITOR", "diff", "--output=x"}, true, true, false, 4},
		{[]string{"--attr-source=HEAD", "diff", "--output=x"}, true, true, false, 3},
		{[]string{"--exec-path=empty", "diff", "--output=x"}, true, true, false, 3},
		{[]string{"--exec-path", "diff", "--output=x"}, false, false, false, 3},
		{[]string{"-c", "core.foo", "diff", "--output=x"}, true, true, false, 4},
		{[]string{"-c", "core.fsmonitor=false", "grep", "-e", "--", "--", "file"}, false, true, true, 5},
		{[]string{"-ccore.fsmonitor=false", "diff", "--output=x"}, false, false, false, 3},
		{[]string{"diff", "--output"}, false, false, false, 2},
	}
	for _, test := range cases {
		result := AnalyzeArguments(test.args)
		if result.Output != test.output || result.Complete != test.complete || result.Eligible != test.eligible || result.Boundary != test.boundary {
			t.Fatalf("argv=%v result=%+v", test.args, result)
		}
	}
	reason := AnalyzeArguments([]string{"diff", "--" + strings.Repeat("界", 2000)}).Reason
	if len(reason) > roleReasonByteLimit || !json.Valid([]byte(`"`+reason+`"`)) {
		t.Fatalf("unbounded or lossy reason bytes=%d", len(reason))
	}
	for _, args := range [][]string{nil, {"-c"}, {"-c", "missing"}, {"--git-dir"}, {"grep", "-e"}, {"grep", "--max-depth"}, {"diff", "--textconv=x"}, {"status", "--unknown"}, {"--namespace", "scope", "status"}, {"--bare", "status"}, {"-Cowned", "status"}, {"--config-env=value", "status"}, {"--attr-source", "HEAD", "status"}} {
		if result := AnalyzeArguments(args); result.Eligible {
			t.Fatalf("unsupported context eligible: %+v", result)
		}
	}
}

// TestSharedDiffRoles checks shared flags and required values without guessing unknown suffixes.
//
// Example: --find-object consumes an output-looking value while --cc leaves output visible.
func TestSharedDiffRoles(t *testing.T) {
	for _, option := range []string{"--no-merges", "--merges", "--follow"} {
		for _, args := range [][]string{
			{"log", option, "--", "--output=literal"},
			{"log", option, "-S", "--output=consumed"},
		} {
			if result := AnalyzeArguments(args); result.Output || !result.Complete || !result.Eligible {
				t.Fatalf("literal or consumed output argv=%v result=%+v", args, result)
			}
		}
		if result := AnalyzeArguments([]string{"log", option, "--output=x", "--unknown"}); !result.Output || result.Complete || result.Eligible {
			t.Fatalf("lost positive fact option=%s result=%+v", option, result)
		}
	}
	for _, verb := range []string{"diff", "log", "show"} {
		cases := []struct {
			args             []string
			output, complete bool
		}{
			{[]string{verb, "--cc", "--output=x"}, true, true},
			{[]string{verb, "--cc", "--output=x", "--unknown"}, true, false},
			{[]string{verb, "--cc", "--unknown", "--output=x"}, false, false},
			{[]string{verb, "--cc", "--", "--output=literal"}, false, true},
			{[]string{verb, "--find-object=object", "--output=x"}, true, true},
			{[]string{verb, "--find-object", "object", "--output=x"}, true, true},
			{[]string{verb, "--find-object", "--output=consumed"}, false, true},
			{[]string{verb, "--find-object=--output=consumed"}, false, true},
			{[]string{verb, "--find-object"}, false, false},
			{[]string{verb, "--cc=value", "--output=x"}, false, false},
		}
		for _, test := range cases {
			result := AnalyzeArguments(test.args)
			if result.Output != test.output || result.Complete != test.complete || result.Eligible != (test.complete && !test.output) {
				t.Fatalf("argv=%v result=%+v", test.args, result)
			}
		}
	}
	for _, verb := range []string{"diff", "show", "grep", "status"} {
		for _, option := range []string{"--no-merges", "--merges", "--follow"} {
			if result := AnalyzeArguments([]string{verb, option, "--output=x"}); result.Complete || result.Output {
				t.Fatalf("unsupported applicability argv=%s %s result=%+v", verb, option, result)
			}
		}
	}
}

// TestNativeOutputFacts pairs known roles with native file creation even before a later invalid option.
//
// Example: stat-width consumes its value and preserves a subsequent concrete output request.
func TestNativeOutputFacts(t *testing.T) {
	for _, prefix := range [][]string{
		{"diff", "--stat-width=80", "--no-textconv"}, {"diff", "--inter-hunk-context", "2"}, {"diff", "--diff-algorithm", "minimal"}, {"log", "--date", "iso"}, {"log", "--encoding", "UTF-8"}, {"diff"},
		{"log", "--no-merges"}, {"log", "--merges"}, {"log", "--follow", "--", "file.txt"},
		{"diff", "--cc"}, {"log", "--cc"}, {"show", "--cc"},
		{"diff", "--find-object=0000000000000000000000000000000000000000"}, {"diff", "--find-object", "0000000000000000000000000000000000000000"},
		{"log", "--find-object=0000000000000000000000000000000000000000"}, {"log", "--find-object", "0000000000000000000000000000000000000000"},
		{"show", "--find-object=0000000000000000000000000000000000000000"}, {"show", "--find-object", "0000000000000000000000000000000000000000"},
	} {
		// Every native output lives in the owned fixture and is removed by its fixture cleanup.
		t.Run(strings.Join(prefix, " "), func(t *testing.T) {
			in, _, _ := fixture(t)
			destination := in.Environment["HOME"] + "/native-output"
			args := append([]string{}, prefix...)
			if prefix[0] == "log" && prefix[1] == "--follow" {
				args = []string{"log", "--follow", "--output=" + destination, "--", "file.txt"}
			} else {
				args = append(args, "--output="+destination)
			}
			invalid := len(prefix) == 1
			if invalid {
				args = append(args, "--unknown-role")
			} else if prefix[0] == "diff" {
				args = append(args, "--", "file.txt")
			}
			result := AnalyzeArguments(args)
			if !result.Output || result.Eligible || result.Complete == invalid {
				t.Fatalf("lost native output role: %+v", result)
			}
			command := exec.Command("/usr/bin/git", args...)
			command.Dir, command.Env = in.CWD, environmentList(in.Environment)
			_, err := command.CombinedOutput()
			if !invalid && err != nil {
				t.Fatal(err)
			}
			if invalid && err == nil {
				t.Fatal("native unknown role unexpectedly accepted")
			}
			if _, err := os.Stat(destination); err != nil {
				t.Fatal("native output absent", err)
			}
		})
	}
}

// TestNativeRoleMetadataOptions preserves helper observation across source-defined metadata values.
//
// Example: date and encoding consume values without suppressing a later native textconv.
func TestNativeRoleMetadataOptions(t *testing.T) {
	for _, args := range [][]string{
		{"diff", "--stat-width=80", "-p", "--", "file.txt"},
		{"diff", "--inter-hunk-context", "2", "--", "file.txt"},
		{"diff", "--diff-algorithm", "minimal", "--", "file.txt"},
		{"log", "--date", "iso", "-p", "--", "file.txt"},
		{"log", "--encoding", "UTF-8", "-p", "--", "file.txt"},
	} {
		// Compare native callback reachability with its isolated certificate on the same argv.
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			in, _, marker := fixture(t)
			original := append([]string{}, args...)
			in.Arguments = args
			runFixture(t, in, args...)
			if _, err := os.Stat(marker); err != nil {
				t.Fatal("native callback absent", err)
			}
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
			result := Inspect(in)
			if result.Result != Helper {
				t.Fatalf("lost metadata-option helper: %+v", result)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("observer callback: %v", err)
			}
			if strings.Join(args, "\x00") != strings.Join(original, "\x00") {
				t.Fatal("analysis modified original argument bytes")
			}
			command := exec.Command("/usr/bin/git", result.Hatch...)
			command.Dir, command.Env = in.CWD, environmentList(in.Environment)
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf("emitted hatch invalid: %v %s", err, output)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("emitted hatch callback: %v", err)
			}
		})
	}
}

// TestNativeStatWidthWithoutPatch preserves native stat-only completion without inventing a helper.
//
// Example: --stat-width enables statistics while an explicit -p would request converted patches.
func TestNativeStatWidthWithoutPatch(t *testing.T) {
	in, _, marker := fixture(t)
	in.Arguments = []string{"diff", "--stat-width=80", "--", "file.txt"}
	runFixture(t, in, in.Arguments...)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("native stat invoked callback: %v", err)
	}
	if result := Inspect(in); result.Result != NoHelper {
		t.Fatalf("stat-only result: %+v", result)
	}
}
