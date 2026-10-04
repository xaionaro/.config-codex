//go:build !linux || !arm64

package main

import (
	"fmt"
	"io"
	"os/exec"
	"syscall"
)

// inheritedDescriptorAdmission refuses unmodeled descriptor inheritance on unsupported platforms.
//
// Example: non-Linux invocation retains Advisory before execution.
func inheritedDescriptorAdmission() error {
	return fmt.Errorf("unsupported inherited descriptor platform")
}

// writeFilter refuses an unmodeled process-filter platform.
//
// Example: unsupported architectures return Advisory before replay.
func writeFilter(output io.Writer) error { return fmt.Errorf("unsupported process-filter platform") }

// certifyInitialExec refuses an unmodeled initial-exec platform.
//
// Example: non-Linux invocations retain Advisory admission.
func certifyInitialExec(
	event traceEvent,
	cwd string,
	env map[string]string,
) error {
	return fmt.Errorf("unsupported initial-exec platform")
}

// isolateObservationProcess leaves unsupported platforms under their existing pre-execution admission boundary.
//
// Example: non-Linux sandbox creation fails before a native process can be started.
func isolateObservationProcess(command *exec.Cmd) error {
	return fmt.Errorf("unsupported observation process platform")
}

// effectiveAccess refuses unsupported kernel access evidence.
//
// Example: an unsupported platform retains advisory intent.
func effectiveAccess(
	path string,
	mode uintptr,
) bool {
	return false
}

// localIntentDomain refuses unsupported filesystem evidence.
//
// Example: an unsupported platform retains advisory intent.
func localIntentDomain(path string) bool { return false }

// regularIntentAccess refuses unsupported writable-handle evidence.
//
// Example: an unsupported platform retains advisory intent.
func regularIntentAccess(
	raw string,
	target string,
	expected *syscall.Stat_t,
) bool {
	return false
}
