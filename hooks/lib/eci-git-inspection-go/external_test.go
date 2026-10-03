package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestNativeExternalDiffEnvironmentPairs verifies ordinary and inherited-equal native preparation.
//
// Example: suppressed equal assignments retain the actual first child's 1/2 counters.
func TestNativeExternalDiffEnvironmentPairs(t *testing.T) {
	in, _, marker := fixture(t)
	other := filepath.Join(in.CWD, "other.txt")
	if err := os.WriteFile(other, []byte("old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runFixture(t, in, "add", "other.txt")
	runFixture(t, in, "commit", "-qm", "other")
	if err := os.WriteFile(other, []byte("new\n"), 0600); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(in.Environment["HOME"], "external")
	script := "#!/bin/sh\nprintf '%s/%s\\n' \"$GIT_DIFF_PATH_COUNTER\" \"$GIT_DIFF_PATH_TOTAL\" >> '" + marker + "'\n"
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	for _, values := range [][2]string{{"old", "old"}, {"1", "2"}, {"1", "old"}, {"old", "2"}} {
		in.Environment["GIT_DIFF_PATH_COUNTER"] = values[0]
		in.Environment["GIT_DIFF_PATH_TOTAL"] = values[1]
		in.Arguments = []string{"--no-pager", "-c", "diff.external=" + helper, "diff", "--", "file.txt", "other.txt"}
		runFixture(t, in, in.Arguments...)
		native, err := os.ReadFile(marker)
		if err != nil {
			t.Fatal(err)
		}
		if string(native) != "1/2\n2/2\n" {
			t.Fatalf("native counters %q", native)
		}
		if err := os.Remove(marker); err != nil {
			t.Fatal(err)
		}
		got := Inspect(in)
		if got.Result != Helper || got.Category != "external-diff" {
			t.Fatalf("values %v got %+v", values, got)
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("observer executed external helper")
		}
		runFixture(t, in, got.Hatch...)
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("raw hatch executed external helper")
		}
	}
	in.Arguments = []string{"-c", "diff.external=" + helper + " 'quote!\ntrace: run_command: GIT_DIFF_PATH_COUNTER=77 GIT_DIFF_PATH_TOTAL=99'", "diff", "--", "file.txt", "other.txt"}
	runFixture(t, in, in.Arguments...)
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	got := Inspect(in)
	if got.Result != Helper || got.Target != "/bin/sh" {
		t.Fatalf("quoted got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("quoted certificate ran helper")
	}
}

// TestExternalTraceRejectsAmbiguity verifies source grammar and exact first-child correlation.
//
// Example: a later matching record cannot replace the first unrelated child.
func TestExternalTraceRejectsAmbiguity(t *testing.T) {
	first := traceEvent{Argv: []string{"/helper", "arg"}, UseShell: true}
	base := map[string]string{"GIT_DIFF_PATH_COUNTER": "1", "GIT_DIFF_PATH_TOTAL": "2"}
	for _, text := range []string{
		"", "00:00:00.000001 run-command.c:673 trace: run_command: GIT_DIFF_PATH_COUNTER=1 GIT_DIFF_PATH_TOTAL=2 '/helper arg\n",
		"00:00:00.000001 run-command.c:673 trace: run_command: GIT_DIFF_PATH_COUNTER=01 GIT_DIFF_PATH_TOTAL=2 /helper arg\n",
		"00:00:00.000001 run-command.c:673 trace: run_command: GIT_DIFF_PATH_COUNTER=1 GIT_DIFF_PATH_TOTAL=2 /other arg\n00:00:00.000002 run-command.c:673 trace: run_command: /helper arg\n",
		"00:00:00.000001 run-command.c:673 trace: run_command: cd /foreign; /helper arg\n",
		"00:00:00.000001 run-command.c:673 trace: run_command: OTHER=1 /helper arg\n",
	} {
		if _, err := externalChildEnvironment([]byte(text), first, base); err == nil {
			t.Fatalf("accepted malformed capture %q", text)
		}
	}
	for _, text := range []string{
		"00:00:00.000001 run-command.c:673 trace: run_command: GIT_DIFF_PATH_COUNTER=1 GIT_DIFF_PATH_TOTAL=2 /helper arg\n",
		"00:00:00.000001 run-command.c:673 trace: run_command: /helper arg\n",
	} {
		env, err := externalChildEnvironment([]byte(text), first, base)
		if err != nil || env["GIT_DIFF_PATH_COUNTER"] != "1" || env["GIT_DIFF_PATH_TOTAL"] != "2" {
			t.Fatalf("got %v %v", env, err)
		}
	}
	if _, err := externalChildEnvironment([]byte(strings.Repeat("x", 128)), first, base); err == nil {
		t.Fatal("unframed capture accepted")
	}
}

// TestFirstLaunchPrefixNeverReadsArguments verifies numeric-looking helper text cannot become native env.
//
// Example: an initial shell assignment inside argv[0] is correlated as argv, not a prefix.
func TestFirstLaunchPrefixNeverReadsArguments(t *testing.T) {
	first := traceEvent{Argv: []string{"GIT_DIFF_PATH_COUNTER=99 /helper", "arg"}, UseShell: true}
	data := []byte("00:00:00.000001 run-command.c:673 trace: run_command: GIT_DIFF_PATH_COUNTER=1 GIT_DIFF_PATH_TOTAL=2 'GIT_DIFF_PATH_COUNTER=99 /helper' arg\n")
	env, err := externalChildEnvironment(data, first, map[string]string{})
	if err != nil || env["GIT_DIFF_PATH_COUNTER"] != "1" {
		t.Fatalf("got %v %v", env, err)
	}
}

// TestAmbiguousFirstChildClassification prevents map iteration from choosing a preparation category.
//
// Example: a short external-diff preparation sharing textconv's command remains Advisory.
func TestAmbiguousFirstChildClassification(t *testing.T) {
	first := traceEvent{Argv: []string{"/helper", "file.txt"}, UseShell: true}
	category, target := classify(first, map[string]string{"diff.external": "/helper", "diff.sample.textconv": "/helper"}, map[string]string{})
	if category != "" || target != "" {
		t.Fatalf("ambiguous category %q target %q", category, target)
	}
}

// TestFirstFsmonitorWithSharedExternalCommand proves source argv shape resolves a known auxiliary.
//
// Example: external diff's two/eight-plus argument forms cannot describe fsmonitor's three arguments.
func TestFirstFsmonitorWithSharedExternalCommand(t *testing.T) {
	in, helper, marker := fixture(t)
	in.Arguments = []string{"-c", "core.fsmonitor=" + helper, "-c", "diff.external=" + helper, "diff", "--", "file.txt"}
	runFixture(t, in, in.Arguments...)
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("native auxiliary missing", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	got := Inspect(in)
	if got.Result != Helper || got.Category != "fsmonitor" {
		t.Fatalf("got %+v", got)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("observer auxiliary executed")
	}
}
