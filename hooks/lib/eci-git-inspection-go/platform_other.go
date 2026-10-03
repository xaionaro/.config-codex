//go:build !linux || !arm64

package main

import (
	"fmt"
	"io"
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
