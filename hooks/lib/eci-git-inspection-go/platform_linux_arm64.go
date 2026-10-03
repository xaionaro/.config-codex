//go:build linux && arm64

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

const (
	// bpfLoadAbsolute loads a seccomp_data word using the Linux classic BPF ABI.
	//
	// Example: load the architecture before interpreting arm64 syscall numbers.
	bpfLoadAbsolute = 0x20
	// bpfJumpEqual compares the BPF accumulator with a constant.
	//
	// Example: select clone process creation calls.
	bpfJumpEqual = 0x15
	// bpfJumpSet tests an accumulator bit mask.
	//
	// Example: permit the CLONE_THREAD flag for pthreads.
	bpfJumpSet = 0x45
	// bpfReturn terminates the filter with a seccomp decision.
	//
	// Example: deny process creation with EAGAIN.
	bpfReturn = 0x06
	// seccompAllow allows a source-supported native syscall.
	//
	// Example: ordinary file reads remain available inside read-only mounts.
	seccompAllow = 0x7fff0000
	// seccompErrno returns the low-word errno to the native syscall caller.
	//
	// Example: clone3 returns ENOSYS to let pthreads fall back to clone.
	seccompErrno = 0x00050000
	// seccompKill refuses an architecture that does not match the admitted filter ABI.
	//
	// Example: an unexpected non-arm64 syscall architecture cannot use arm64 numbers.
	seccompKill = 0
	// auditArchitectureARM64 identifies little-endian AArch64 Linux in seccomp_data.
	//
	// Example: the filter checks the architecture word before the syscall number.
	auditArchitectureARM64 = 0xc00000b7
	// seccompArchitectureOffset locates the architecture word in struct seccomp_data.
	//
	// Example: load offset four before checking auditArchitectureARM64.
	seccompArchitectureOffset = 4
	// seccompFirstArgumentOffset locates the low word of syscall argument zero.
	//
	// Example: clone flags carry CLONE_THREAD in the first argument.
	seccompFirstArgumentOffset = 16
	// cloneThread identifies thread creation in the Linux clone ABI.
	//
	// Example: threaded grep retains its pthread pool.
	cloneThread = 0x00010000
	// syscallClone3 is the Linux generic clone3 number missing from the frozen syscall package.
	//
	// Example: return ENOSYS so libc can use the modeled clone ABI.
	syscallClone3 = 435
)

// inheritedDescriptorAdmission rejects unowned started-with channels before any subprocess.
//
// Example: a socket without FD_CLOEXEC returns Advisory rather than reaching Git.
func inheritedDescriptorAdmission() error {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return fmt.Errorf("inspect inherited descriptors: %w", err)
	}
	for _, entry := range entries {
		fd, err := strconv.Atoi(entry.Name())
		if err != nil {
			return fmt.Errorf("decode inherited descriptor: %w", err)
		}
		if fd < 3 {
			continue
		}
		flags, _, errno := syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), syscall.F_GETFD, 0)
		if errno == syscall.EBADF {
			continue
		}
		if errno != 0 {
			return fmt.Errorf("inspect inherited descriptor flags: %w", errno)
		}
		if flags&syscall.FD_CLOEXEC == 0 {
			return fmt.Errorf("unmodeled inherited descriptor before observation")
		}
	}
	return nil
}

// writeFilter emits arm64 seccomp allowing pthreads while rejecting processes and host IPC.
//
// Example: bubblewrap consumes the filter through owned descriptor 3.
func writeFilter(output io.Writer) error {
	filters := []syscall.SockFilter{
		{Code: bpfLoadAbsolute, K: seccompArchitectureOffset},
		{Code: bpfJumpEqual, K: auditArchitectureARM64, Jt: 1},
		{Code: bpfReturn, K: seccompKill},
		{Code: bpfLoadAbsolute, K: 0},
		{Code: bpfJumpEqual, K: syscall.SYS_CLONE, Jf: 4},
		{Code: bpfLoadAbsolute, K: seccompFirstArgumentOffset},
		{Code: bpfJumpSet, K: cloneThread, Jt: 1},
		{Code: bpfReturn, K: seccompErrno | uint32(syscall.EAGAIN)},
		{Code: bpfReturn, K: seccompAllow},
		{Code: bpfJumpEqual, K: syscallClone3, Jf: 1},
		{Code: bpfReturn, K: seccompErrno | uint32(syscall.ENOSYS)},
	}
	// IPC cannot be made effect-free merely by mounting the filesystem read-only.
	for _, number := range []uint32{syscall.SYS_SOCKET, syscall.SYS_SOCKETPAIR, syscall.SYS_BIND, syscall.SYS_LISTEN, syscall.SYS_CONNECT, syscall.SYS_SENDTO, syscall.SYS_SENDMSG, syscall.SYS_SENDMMSG, syscall.SYS_PTRACE, syscall.SYS_PROCESS_VM_WRITEV, syscall.SYS_MSGGET, syscall.SYS_MSGCTL, syscall.SYS_MSGRCV, syscall.SYS_MSGSND, syscall.SYS_SHMGET, syscall.SYS_SHMCTL, syscall.SYS_SHMAT, syscall.SYS_SHMDT, syscall.SYS_SEMGET, syscall.SYS_SEMCTL, syscall.SYS_SEMTIMEDOP, syscall.SYS_SEMOP} {
		filters = append(filters, syscall.SockFilter{Code: bpfJumpEqual, K: number, Jf: 1}, syscall.SockFilter{Code: bpfReturn, K: seccompErrno | uint32(syscall.EPERM)})
	}
	filters = append(filters, syscall.SockFilter{Code: bpfReturn, K: seccompAllow})
	if err := binary.Write(output, binary.LittleEndian, filters); err != nil {
		return fmt.Errorf("write process/IPC filter: %w", err)
	}
	return nil
}

// certifyInitialExec kills and reaps an exact successful kernel exec at its initial ptrace stop.
//
// Example: a shebang interpreter is stopped before any interpreter instructions execute.
func certifyInitialExec(
	event traceEvent,
	cwd string,
	env map[string]string,
) error {
	if len(event.Argv) == 0 {
		return fmt.Errorf("empty helper argv")
	}
	if event.CWD != "" {
		cwd = event.CWD
	}
	args := append([]string{}, event.Argv...)
	if event.UseShell && strings.ContainsAny(args[0], "|&;<>()$`\\\"' \t\n*?[#~=%") {
		command := args[0]
		if len(args) > 1 {
			command += " \"$@\""
		}
		args = append([]string{"/bin/sh", "-c", command}, args...)
	}
	executable, err := resolveProgram(args[0], cwd, env)
	if err != nil {
		return fmt.Errorf("helper initial exec preparation: %w", err)
	}
	info, err := os.Stat(executable)
	if err != nil {
		return fmt.Errorf("helper initial exec: %w", err)
	}
	if info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
		return fmt.Errorf("unsupported helper privilege context")
	}
	size, xattrErr := syscall.Getxattr(executable, "security.capability", nil)
	if xattrErr != nil && !errors.Is(xattrErr, syscall.ENODATA) && !errors.Is(xattrErr, syscall.ENOTSUP) {
		return fmt.Errorf("inspect helper capabilities: %w", xattrErr)
	}
	if xattrErr == nil && size > 0 {
		return fmt.Errorf("unsupported helper capabilities")
	}
	if os.Getuid() != os.Geteuid() || os.Getgid() != os.Getegid() {
		return fmt.Errorf("unsupported current credential context")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if !strings.Contains(args[0], "/") {
		args[0] = executable
	}
	c, err := startInitialExec(executable, args, cwd, env)
	if err != nil {
		return fmt.Errorf("helper initial exec certificate: %w", err)
	}
	var status syscall.WaitStatus
	pid, waitErr := syscall.Wait4(c.Process.Pid, &status, 0, nil)
	killErr := c.Process.Kill()
	reapErr := c.Wait()
	var exit *exec.ExitError
	if reapErr != nil && !errors.As(reapErr, &exit) {
		return fmt.Errorf("reap stopped helper: %w", reapErr)
	}
	if killErr != nil {
		return fmt.Errorf("kill stopped helper: %w", killErr)
	}
	if waitErr != nil {
		return fmt.Errorf("wait for initial exec: %w", waitErr)
	}
	if pid != c.Process.Pid || !status.Stopped() || status.StopSignal() != syscall.SIGTRAP {
		return fmt.Errorf("unexpected initial exec stop")
	}
	if exit == nil || !exit.Sys().(syscall.WaitStatus).Signaled() || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		return fmt.Errorf("initial exec cleanup not certified")
	}
	return nil
}

// startInitialExec begins an exec-only traced child while the caller owns a locked OS thread.
//
// Example: certifyInitialExec waits for the initial SIGTRAP and then kills the child.
func startInitialExec(
	executable string,
	args []string,
	cwd string,
	env map[string]string,
) (*exec.Cmd, error) {
	c := exec.Command(executable)
	c.Args = args
	c.Dir = cwd
	c.Env = sortedEnvironmentList(env)
	// The locked creating thread owns the child's lifetime even if the tracer is interrupted.
	// Go's fork protocol installs this signal and checks the parent-death race before exec.
	c.SysProcAttr = &syscall.SysProcAttr{Ptrace: true, Pdeathsig: syscall.SIGKILL}
	if err := c.Start(); err != nil {
		return nil, err
	}
	return c, nil
}
