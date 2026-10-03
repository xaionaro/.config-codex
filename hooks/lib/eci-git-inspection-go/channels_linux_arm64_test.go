//go:build linux && arm64

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// TestTraceSocketPaired proves native socket output exists while rejected observation makes no connection.
//
// Example: an AF_UNIX Trace2 destination remains untouched by Advisory.
func TestTraceSocketPaired(t *testing.T) {
	in, _, marker := fixture(t)
	listener, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(
		// Restore owned fixture resources and report cleanup failures.
		//
		// Example: leave no fixture channel or process setting after this test.
		func() {
			if err := syscall.Close(listener); err != nil {
				t.Error(err)
			}
		},
	)
	path := filepath.Join(in.Environment["HOME"], "trace.sock")
	if err := syscall.Bind(listener, &syscall.SockaddrUnix{Name: path}); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Listen(listener, 2); err != nil {
		t.Fatal(err)
	}
	in.Environment["GIT_TRACE2_EVENT"] = "af_unix:stream:" + path
	runFixture(t, in, "diff", "--no-ext-diff", "--no-textconv")
	accepted, _, err := syscall.Accept4(listener, syscall.SOCK_NONBLOCK)
	if err != nil {
		t.Fatal("native trace failed to connect", err)
	}
	data := make([]byte, 4096)
	count, err := syscall.Read(accepted, data)
	if err != nil || count == 0 {
		t.Fatal("native trace did not write", err)
	}
	if err := syscall.Close(accepted); err != nil {
		t.Fatal(err)
	}
	in.Arguments = []string{"diff", "--no-ext-diff", "--no-textconv"}
	got := Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "trace") {
		t.Fatalf("got %+v", got)
	}
	fd, _, err := syscall.Accept4(listener, syscall.SOCK_NONBLOCK)
	if err == nil {
		if closeErr := syscall.Close(fd); closeErr != nil {
			t.Error(closeErr)
		}
		t.Fatal("observer connected original trace socket")
	}
	if !errors.Is(err, syscall.EAGAIN) {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("observer ran helper")
	}
}

// TestInheritedTraceFDAdvisory proves original numeric trace destinations cannot write inherited IPC.
//
// Example: rejecting GIT_TRACE2_PERF=5 leaves an owned socketpair empty.
func TestInheritedTraceFDAdvisory(t *testing.T) {
	in, _, _ := fixture(t)
	sockets, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(
		// Restore owned fixture resources and report cleanup failures.
		//
		// Example: leave no fixture channel or process setting after this test.
		func() {
			for _, fd := range sockets {
				if err := syscall.Close(fd); err != nil {
					t.Error(err)
				}
			}
		},
	)
	in.Arguments = []string{"diff"}
	in.Environment["GIT_TRACE2_PERF"] = "5"
	got := Inspect(in)
	if got.Result != Advisory {
		t.Fatalf("got %+v", got)
	}
	data := make([]byte, 64)
	_, err = syscall.Read(sockets[0], data)
	if !errors.Is(err, syscall.EAGAIN) {
		t.Fatalf("socket effects: %v", err)
	}
}

// TestInheritedUnmodeledIPCBeforeExecution verifies started-with descriptors do not reach diagnostics.
//
// Example: an inheritable socket without an explicit trace variable remains Advisory.
func TestInheritedUnmodeledIPCBeforeExecution(t *testing.T) {
	in, _, _ := fixture(t)
	sockets, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(
		// Restore owned fixture resources and report cleanup failures.
		//
		// Example: leave no fixture channel or process setting after this test.
		func() {
			for _, fd := range sockets {
				if err := syscall.Close(fd); err != nil {
					t.Error(err)
				}
			}
		},
	)
	in.Arguments = []string{"diff", "--no-ext-diff", "--no-textconv"}
	got := Inspect(in)
	if got.Result != Advisory || !strings.Contains(got.Reason, "inherited descriptor") {
		t.Fatalf("got %+v", got)
	}
	for _, fd := range sockets {
		syscall.CloseOnExec(fd)
	}
	got = Inspect(in)
	if got.Result != NoHelper {
		t.Fatalf("CLOEXEC counterpart got %+v", got)
	}
	data := make([]byte, 64)
	_, err = syscall.Read(sockets[0], data)
	if !errors.Is(err, syscall.EAGAIN) {
		t.Fatalf("IPC effects %v", err)
	}
}
