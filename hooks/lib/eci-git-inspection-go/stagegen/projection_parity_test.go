package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

// TestGeneratedProjectionParity compares actual production stage queries with the generated Python engine.
//
// Example: mixed required values, raw delimiters and callback bounds preserve identical original spans.
func TestGeneratedProjectionParity(t *testing.T) {
	engine, err := compilePython("../stage_program.go")
	if err != nil {
		t.Fatal(err)
	}
	program, err := os.ReadFile("program.json")
	if err != nil {
		t.Fatal(err)
	}
	quoted, err := json.Marshal(string(program))
	if err != nil {
		t.Fatal(err)
	}
	scratch := t.TempDir()
	projection := filepath.Join(scratch, "projection.py")
	binary := filepath.Join(scratch, "inspection")
	source := append([]byte("import json,re,sys\nPROGRAM=json.loads("+string(quoted)+")\n"), engine...)
	if err := os.WriteFile(projection, source, 0600); err != nil {
		t.Fatal(err)
	}
	build := exec.Command("go", "build", "-o", binary, "..")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build production CLI: %v %s", err, out)
	}
	cases := [][]string{{"log", "-qS", "--output=x"}, {"log", "--author", "--output=x", "--output=real"}, {"show", "--decorate=short", "--output=one", "--unknown"}, {"diff", "--output=/dev/null", "--output=new"}, {"diff", "--", "--output=operand"}, {"log", "--output=one", "-S", ""}, {"log", "-S", "", "--output=later"}, {"show", "--output=one", "-G", ""}}
	overbound := []string{"diff"}
	for n := 0; n < 65; n++ {
		overbound = append(overbound, "--output=/dev/null")
	}
	cases = append(cases, overbound)
	for _, args := range cases {
		goInput, err := json.Marshal(map[string]any{"query": "offline-program", "arguments": args})
		if err != nil {
			t.Fatal(err)
		}
		pyInput, err := json.Marshal(map[string]any{"arguments": args})
		if err != nil {
			t.Fatal(err)
		}
		goCmd := exec.Command(binary)
		goCmd.Stdin = bytes.NewReader(goInput)
		goOutput, err := goCmd.CombinedOutput()
		if err != nil {
			t.Fatalf("stage query: %v %s", err, goOutput)
		}
		pyCmd := exec.Command("python3", projection)
		pyCmd.Stdin = bytes.NewReader(pyInput)
		pyOutput, err := pyCmd.CombinedOutput()
		if err != nil {
			t.Fatalf("generated stage query: %v %s", err, pyOutput)
		}
		var goResult, pyResult map[string]json.RawMessage
		if err := json.Unmarshal(goOutput, &goResult); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(pyOutput, &pyResult); err != nil {
			t.Fatal(err)
		}
		for key, value := range goResult {
			var goValue, pyValue any
			if err := json.Unmarshal(value, &goValue); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(pyResult[key], &pyValue); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(goValue, pyValue) {
				t.Fatalf("projection drift %v field %s: %s vs %s", args, key, goOutput, pyOutput)
			}
		}
		if len(goResult) != len(pyResult) {
			t.Fatalf("projection fields drift: %s vs %s", goOutput, pyOutput)
		}
	}
}
