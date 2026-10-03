//go:build linux && arm64

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
)

// TestCertificateInterruptionChild provides a disposable tracer stopped after its child's initial exec.
//
// Example: the parent kills this tracer to verify that the helper cannot resume.
func TestCertificateInterruptionChild(t *testing.T) {
	if os.Getenv("ECI_CERTIFICATE_CHILD") != "1" {
		return
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	path := os.Getenv("ECI_CERTIFICATE_HELPER")
	c, err := startInitialExec(path, []string{path}, "/", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	var status syscall.WaitStatus
	if _, err := syscall.Wait4(c.Process.Pid, &status, 0, nil); err != nil || !status.Stopped() || status.StopSignal() != syscall.SIGTRAP {
		t.Fatalf("initial stop %v %v", status, err)
	}
	if _, err := fmt.Fprintf(os.Stdout, "%d\n", c.Process.Pid); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGSTOP); err != nil {
		t.Fatal(err)
	}
	select {}
}

// TestInterruptedCertificateKillsAndReaps proves tracer death cannot resume the initial executable.
//
// Example: killing the observer kills and allows reaping its untouched helper.
func TestInterruptedCertificateKillsAndReaps(t *testing.T) {
	in, _, marker := fixture(t)
	helper := filepath.Join(in.Environment["HOME"], "interrupt-helper")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho reached > '"+marker+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, _, errno := syscall.Syscall6(syscall.SYS_PRCTL, 36, 1, 0, 0, 0, 0); errno != 0 {
		t.Fatal(errno)
	}
	t.Cleanup(
		// Restore owned fixture resources and report cleanup failures.
		//
		// Example: leave no fixture channel or process setting after this test.
		func() {
			if _, _, errno := syscall.Syscall6(syscall.SYS_PRCTL, 36, 0, 0, 0, 0, 0); errno != 0 {
				t.Error(errno)
			}
		},
	)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	tracer := exec.Command(executable, "-test.run=^TestCertificateInterruptionChild$")
	tracer.Env = []string{"ECI_CERTIFICATE_CHILD=1", "ECI_CERTIFICATE_HELPER=" + helper}
	stdout, err := tracer.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := tracer.Start(); err != nil {
		t.Fatal(err)
	}
	var pid int
	if _, err := fmt.Fscanln(stdout, &pid); err != nil {
		t.Fatal(err)
	}
	if err := tracer.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	var exit *exec.ExitError
	if err := tracer.Wait(); !errors.As(err, &exit) {
		t.Fatalf("tracer reap %v", err)
	}
	var status syscall.WaitStatus
	reaped, err := syscall.Wait4(pid, &status, 0, nil)
	if err != nil {
		t.Fatal("reap orphan initial exec", err)
	}
	if reaped != pid || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("tracee resumed or unreaped: pid=%d status=%v", reaped, status)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("interrupted certificate executed helper", err)
	}
}
