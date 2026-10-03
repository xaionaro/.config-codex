package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestReplayOutputDiscard verifies that complete native blob output has no retained payload.
//
// Example: a 64 MiB inspection retains trace evidence and exits successfully.
func TestReplayOutputDiscard(t *testing.T) {
	in, _, _ := fixture(t)
	if err := os.Truncate(filepath.Join(in.CWD, "file.txt"), 64*1024*1024); err != nil {
		t.Fatal(err)
	}
	blob := runFixture(t, in, "hash-object", "-w", "file.txt")
	in.Arguments = []string{"show", strings.TrimSpace(blob)}
	s, err := newSandbox(in)
	if err != nil {
		t.Fatal(err)
	}
	// Owned trace files must be removed even when the assertion fails.
	defer func() {
		if err := os.RemoveAll(s.dir); err != nil {
			t.Error(err)
		}
	}()
	output, events, status, err := s.run(in.Arguments, replayOutput)
	if err != nil || status != 0 || len(events) == 0 || len(output) != 0 {
		t.Fatalf("retained replay bytes=%d events=%d status=%d err=%v", len(output), len(events), status, err)
	}
}

// TestMetadataOutputOverflow requires draining oversized config instead of parsing a prefix.
//
// Example: native config completes with status zero while excess capture is rejected.
func TestMetadataOutputOverflow(t *testing.T) {
	in, _, _ := fixture(t)
	runFixture(t, in, "config", "example.large", strings.Repeat("x", 70000))
	for index := 0; index < 20; index++ {
		runFixture(t, in, "config", "--add", "example.large", strings.Repeat("y", 70000))
	}
	s, err := newSandbox(in)
	if err != nil {
		t.Fatal(err)
	}
	// Clean up the owned observer state after reading native metadata.
	defer func() {
		if err := os.RemoveAll(s.dir); err != nil {
			t.Error(err)
		}
	}()
	_, _, status, err := s.run([]string{"config", "--null", "--list"}, metadataOutput)
	if err == nil || status != 0 {
		t.Fatalf("overflow status=%d err=%v", status, err)
	}
	if got := Inspect(Invocation{CWD: in.CWD, Arguments: []string{"diff"}, Environment: in.Environment}); got.Result != Advisory {
		t.Fatalf("overflow finding: %+v", got)
	}
}

// TestOutputWriterBoundary pairs exact-limit writes with drained excess.
//
// Example: an oversized write reports all bytes consumed without growing the retained prefix.
func TestOutputWriterBoundary(t *testing.T) {
	for _, size := range []int{outputCaptureByteLimit - 1, outputCaptureByteLimit, outputCaptureByteLimit + 1} {
		output := boundedOutput{limit: outputCaptureByteLimit}
		count, err := io.Copy(&output, strings.NewReader(strings.Repeat("x", size)))
		if err != nil || count != int64(size) || output.buffer.Len() != min(size, outputCaptureByteLimit) || output.overflow != (size > outputCaptureByteLimit) {
			t.Fatalf("size=%d count=%d retained=%d overflow=%t err=%v", size, count, output.buffer.Len(), output.overflow, err)
		}
	}
}

// TestDiagnosticDrainPreservesExit proves that excess stderr does not signal EPIPE or alter exit status.
//
// Example: a native producer writes past the limit and still reaches its explicit exit seven.
func TestDiagnosticDrainPreservesExit(t *testing.T) {
	for _, size := range []int{outputCaptureByteLimit - 1, outputCaptureByteLimit + 1} {
		output := boundedOutput{limit: outputCaptureByteLimit}
		command := exec.Command("/bin/sh", "-c", fmt.Sprintf("head -c %d /dev/zero >&2 || exit 99; exit 7", size))
		command.Stderr = &output
		err := command.Run()
		exit, ok := err.(*exec.ExitError)
		if !ok || exit.ExitCode() != 7 || output.buffer.Len() != min(size, outputCaptureByteLimit) || output.overflow != (size > outputCaptureByteLimit) {
			t.Fatalf("size=%d status=%v retained=%d overflow=%t", size, err, output.buffer.Len(), output.overflow)
		}
	}
}

// TestUnknownOutputPurpose refuses unspecified native output semantics before launch.
//
// Example: the zero enum value cannot select a capture policy implicitly.
func TestUnknownOutputPurpose(t *testing.T) {
	if _, _, _, err := (&sandbox{}).run(nil, 0); err == nil {
		t.Fatal("accepted unspecified output purpose")
	}
}

// TestSandboxDiagnosticOverflow verifies production draining and its overflow error before trace interpretation.
//
// Example: an owned shell emits excess stderr inside the real sandbox and still reaches exit seven.
func TestSandboxDiagnosticOverflow(t *testing.T) {
	for _, size := range []int{outputCaptureByteLimit - 1, outputCaptureByteLimit, outputCaptureByteLimit + 1} {
		// Exercise each boundary with a fresh native sandbox and private trace descriptors.
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			in, _, _ := fixture(t)
			s, err := newSandbox(in)
			if err != nil {
				t.Fatal(err)
			}
			// This protocol producer replaces only the test sandbox's selected executable.
			s.git = "/bin/sh"
			// Owned sandbox files must be removed after both successful and rejected output.
			defer func() {
				if err := os.RemoveAll(s.dir); err != nil {
					t.Error(err)
				}
			}()
			command := fmt.Sprintf("i=0; while [ \"$i\" -lt %d ]; do printf '%%1024s' x >&2 || exit 99; i=$((i+1)); done;", size/1024)
			if remainder := size % 1024; remainder != 0 {
				command += fmt.Sprintf("printf '%%%ds' x >&2 || exit 99;", remainder)
			}
			command += "exit 7"
			_, _, status, err := s.run([]string{"-c", command}, replayOutput)
			if status != 7 || err == nil {
				t.Fatalf("size=%d status=%d err=%v", size, status, err)
			}
			if size > outputCaptureByteLimit {
				if err.Error() != "native metadata or diagnostic output exceeded supported size" {
					t.Fatalf("wrong overflow failure: %v", err)
				}
			} else if !strings.HasPrefix(err.Error(), "sandbox or native Trace2 unavailable:") {
				t.Fatalf("bounded output rejected before missing trace evidence: %v", err)
			}
		})
	}
}
