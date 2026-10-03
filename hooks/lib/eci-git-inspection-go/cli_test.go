package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
)

// TestCLIJSONProtocol verifies strict single-input framing and closed wire results.
//
// Example: unknown fields yield structured Advisory with no execution attempt.
func TestCLIJSONProtocol(t *testing.T) {
	for _, input := range []string{"", `{`, `{"extra":true}`, `{} {}`, `{} trailing`, strings.Repeat(" ", 4*1024*1024) + "{}", `{"cwd":"relative","arguments":["diff"],"environment":{}}`} {
		var output bytes.Buffer
		if err := runCLI(strings.NewReader(input), &output); err != nil {
			t.Fatal(err)
		}
		var reply struct {
			Result string `json:"result"`
			Reason string `json:"reason"`
		}
		if err := json.Unmarshal(output.Bytes(), &reply); err != nil {
			t.Fatal(err)
		}
		if reply.Result != "Advisory" || reply.Reason == "" {
			t.Fatalf("reply %+v", reply)
		}
	}
	in, _, marker := fixture(t)
	in.Arguments = []string{"show", "--textconv", "HEAD:file.txt"}
	input, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := runCLI(bytes.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"result":"Helper"`) || !strings.Contains(output.String(), `"category":"textconv"`) {
		t.Fatal(output.String())
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("CLI executed helper")
	}
	output.Reset()
	if err := runCLI(strings.NewReader(string(input)+strings.Repeat(" ", 4*1024*1024)), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"result":"Advisory"`) {
		t.Fatal("oversized JSON reached observation", output.String())
	}
}

// rejectedWriter reports an output boundary failure without accepting JSON bytes.
//
// Example: rejectedWriter models a caller that closed its stdout pipe.
type rejectedWriter struct{}

// Write exposes an io.ErrClosedPipe rather than silently dropping a result.
//
// Example: runCLI returns the closed-pipe error to its main boundary.
func (rejectedWriter) Write(data []byte) (int, error) { return 0, io.ErrClosedPipe }

// TestCLIOutputFailure ensures transport errors cannot masquerade as successful observation.
//
// Example: a closed stdout pipe yields an error.
func TestCLIOutputFailure(t *testing.T) {
	if err := runCLI(strings.NewReader("{}"), rejectedWriter{}); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("got %v", err)
	}
	for _, value := range []Result{Helper, NoHelper, Advisory} {
		if data, err := json.Marshal(value); err != nil || len(data) < 2 {
			t.Fatalf("%v %s", err, data)
		}
	}
	if _, err := json.Marshal(Result(99)); err == nil {
		t.Fatal("unknown result encoded")
	}
}

// TestCLIRejectsLossyUnicode prevents JSON replacement from changing the original invocation.
//
// Example: unpaired surrogate paths are Advisory before diagnostic subprocesses.
func TestCLIRejectsLossyUnicode(t *testing.T) {
	for _, input := range [][]byte{
		[]byte(`{"cwd":"/repo","arguments":["diff"],"environment":{"EXAMPLE":"\ud800"}}`),
		[]byte(`{"cwd":"/repo","arguments":["diff"],"environment":{"EXAMPLE":"\udc00"}}`),
		[]byte(`{"cwd":"/repo","arguments":["diff"],"environment":{"EXAMPLE":"\ud800\u0041"}}`),
		append([]byte(`{"cwd":"/repo","arguments":["diff"],"environment":{"EXAMPLE":"`), append([]byte{0xff}, []byte(`"}}`)...)...),
	} {
		var out bytes.Buffer
		if err := runCLI(bytes.NewReader(input), &out); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), `"result":"Advisory"`) || !strings.Contains(out.String(), "Unicode") {
			t.Fatalf("lossy JSON accepted: %s", out.String())
		}
	}
	if !exactJSONUnicode([]byte(`{"value":"\ud83d\ude00","literal":"\\ud800"}`)) {
		t.Fatal("valid surrogate pair or literal escape rejected")
	}
}
