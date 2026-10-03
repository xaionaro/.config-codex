package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestNativeAggregateTraceBound requires overflow to invalidate a fully drained native run.
//
// Example: a log-sized stream of otherwise valid records cannot certify NoHelper.
func TestNativeAggregateTraceBound(t *testing.T) {
	for _, kind := range []string{"events", "trace-bytes", "launch-bytes"} {
		// Each protocol producer writes only owned inherited descriptors inside the sandbox.
		t.Run(kind, func(t *testing.T) {
			in, _, _ := fixture(t)
			s, err := newSandbox(in)
			if err != nil {
				t.Fatal(err)
			}
			// Cleanup remains observable even when overflow is rejected.
			defer func() {
				if err := os.RemoveAll(s.dir); err != nil {
					t.Error(err)
				}
			}()
			s.git = "/bin/sh"
			script := "i=0; while [ $i -lt 8200 ]; do printf '{\"event\":\"region_enter\"}\\n' >&4; i=$((i+1)); done"
			switch kind {
			case "trace-bytes":
				script = "i=0; while [ $i -lt 9000 ]; do printf '{\"event\":\"region_enter\",\"message\":\"%1024s\"}\\n' x >&4; i=$((i+1)); done"
			case "launch-bytes":
				script = "i=0; while [ $i -lt 9000 ]; do printf '%1024s' x >&5; i=$((i+1)); done; printf '{\"event\":\"exit\"}\\n' >&4"
			}
			_, events, status, err := s.run([]string{"-c", script}, replayOutput)
			if err == nil || status != 0 || len(events) != 0 {
				t.Fatalf("incomplete capture accepted: kind=%s events=%d status=%d err=%v", kind, len(events), status, err)
			}
			entries, scanErr := os.ReadDir(s.dir)
			if scanErr != nil {
				t.Fatal(scanErr)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), "trace-") || strings.HasPrefix(entry.Name(), "launch-") {
					info, statErr := os.Stat(filepath.Join(s.dir, entry.Name()))
					if statErr != nil {
						t.Fatal(statErr)
					}
					if info.Size() > 8*1024*1024 {
						t.Fatalf("unbounded transient capture: %s size=%d", entry.Name(), info.Size())
					}
				}
			}
			if !strings.Contains(err.Error(), "exceeded") {
				t.Fatal(fmt.Sprintf("wrong overflow error: %v", err))
			}
		})
	}
}

// TestCompleteTraceDecodeBoundaries pairs each supported budget with malformed or incomplete evidence.
//
// Example: exactly 8192 records are complete, while one additional record is unsupported.
func TestCompleteTraceDecodeBoundaries(t *testing.T) {
	for _, count := range []int{8191, 8192, 8193} {
		data := bytes.Repeat([]byte("{\"event\":\"exit\"}\n"), count)
		events, err := decodeTraceCapture(context.Background(), data)
		if (err != nil) != (count > 8192) {
			t.Fatalf("events=%d retained=%d err=%v", count, len(events), err)
		}
	}
	for _, size := range []int{traceCaptureByteLimit - 1, traceCaptureByteLimit, traceCaptureByteLimit + 1} {
		data := []byte{}
		for record := 0; record < 4; record++ {
			n := size / 4
			if record == 3 {
				n = size - len(data)
			}
			if n < 20 {
				t.Fatal("test record too short")
			}
			data = append(data, []byte("{\"event\":\"exit\"}")...)
			data = append(data, bytes.Repeat([]byte(" "), n-17)...)
			data = append(data, '\n')
		}
		_, err := decodeTraceCapture(context.Background(), data)
		if (err != nil) != (size > traceCaptureByteLimit) {
			t.Fatalf("bytes=%d err=%v", size, err)
		}
	}
	for _, data := range []string{"{\"event\":\"exit\"}", "{invalid}\n", "{\"event\":\"\\ud800\"}\n"} {
		if _, err := decodeTraceCapture(context.Background(), []byte(data)); err == nil {
			t.Fatalf("accepted incomplete/malformed %q", data)
		}
	}
	if events, err := decodeTraceCapture(context.Background(), []byte("{\"event\":\"é\\n\"}\n")); err != nil || len(events) != 1 {
		t.Fatalf("lossless unicode: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := decodeTraceCapture(ctx, []byte("{\"event\":\"exit\"}\n")); err == nil {
		t.Fatal("decode escaped cancellation")
	}
}

// TestTraceCollectorCancellationJoins stops an inherited pipe that never reaches native EOF.
//
// Example: a deadline does not leave the collector blocked on a retained writer.
func TestTraceCollectorCancellationJoins(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	capture, err := newTraceCapture(ctx, 128)
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	if _, err := capture.finish(); err == nil {
		t.Fatal("cancelled capture reported complete")
	}
}

// TestNativeCaptureStartFailureAndCancellation verifies owned descriptor cleanup and process reaping.
//
// Example: a stalled sandbox is killed and waited before the observer returns.
func TestNativeCaptureStartFailureAndCancellation(t *testing.T) {
	for _, kind := range []string{"start-failure", "cancel"} {
		// Each failure begins with a fresh sandbox and one opaque-process deadline.
		t.Run(kind, func(t *testing.T) {
			in, _, _ := fixture(t)
			s, err := newSandbox(in)
			if err != nil {
				t.Fatal(err)
			}
			// Cleanup is part of the failed observation contract.
			defer func() {
				if err := os.RemoveAll(s.dir); err != nil {
					t.Error(err)
				}
			}()
			before, err := os.ReadDir("/proc/self/fd")
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			s.git = "/bin/sh"
			if kind == "start-failure" {
				s.bwrap = "/nonexistent-owned-sandbox-program"
			}
			started := time.Now()
			if _, events, _, err := s.runContext(ctx, []string{"-c", "while :; do :; done"}, replayOutput); err == nil || len(events) != 0 {
				t.Fatalf("failed capture accepted: %v", err)
			}
			if time.Since(started) > 2*time.Second {
				t.Fatal("capture exceeded shared deadline cleanup bound")
			}
			after, err := os.ReadDir("/proc/self/fd")
			if err != nil {
				t.Fatal(err)
			}
			if len(after) != len(before) {
				t.Fatalf("descriptor leak: before=%d after=%d", len(before), len(after))
			}
			children, err := filepath.Glob("/proc/self/task/*/children")
			if err != nil {
				t.Fatal(err)
			}
			for _, file := range children {
				data, err := os.ReadFile(file)
				if err != nil {
					t.Fatal(err)
				}
				if strings.TrimSpace(string(data)) != "" {
					t.Fatalf("unreaped native child: %s", data)
				}
			}
		})
	}
}
