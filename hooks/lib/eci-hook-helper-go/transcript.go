package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

const (
	dirOpenFlags  = syscall.O_RDONLY | syscall.O_CLOEXEC | syscall.O_NOFOLLOW | syscall.O_DIRECTORY
	fileOpenFlags = syscall.O_RDONLY | syscall.O_CLOEXEC | syscall.O_NOFOLLOW | syscall.O_NONBLOCK
)

// relativePartsAllowed reports whether parts is non-empty and contains no
// empty, "." or ".." component.
func relativePartsAllowed(parts []string) bool {
	if len(parts) == 0 {
		return false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// rawCharAllowed reports whether r is a printable character: codepoint >= 32
// and outside the C1 control range 127..159.
func rawCharAllowed(r rune) bool {
	return r >= 32 && (r < 127 || r > 159)
}

// rawAbsolutePathAllowed applies the raw transcript_path rules: printable
// characters only, absolute, and no empty, "." or ".." component.
func rawAbsolutePathAllowed(raw string) bool {
	for _, r := range raw {
		if !rawCharAllowed(r) {
			return false
		}
	}
	if !strings.HasPrefix(raw, "/") {
		return false
	}
	parts := strings.Split(raw, "/")
	return relativePartsAllowed(parts[1:])
}

// pathParts mirrors pathlib's parts for an absolute path: empty and "."
// components are dropped; ".." is kept so that it never matches.
func pathParts(path string) []string {
	var parts []string
	for _, part := range strings.Split(path, "/") {
		if part != "" && part != "." {
			parts = append(parts, part)
		}
	}
	return parts
}

// openAbsoluteDirectory walks an absolute, already-resolved directory path
// from "/" with O_NOFOLLOW|O_DIRECTORY at every component.
func openAbsoluteDirectory(path string) (int, bool) {
	fd, err := syscall.Open("/", dirOpenFlags, 0)
	if err != nil {
		return -1, false
	}
	for _, part := range pathParts(path) {
		if !relativePartsAllowed([]string{part}) {
			syscall.Close(fd)
			return -1, false
		}
		next, err := syscall.Openat(fd, part, dirOpenFlags, 0)
		syscall.Close(fd)
		if err != nil {
			return -1, false
		}
		fd = next
	}
	return fd, true
}

// openContainedTranscript opens raw as a regular, non-symlink *.jsonl file
// that lies under the sessions root.
func openContainedTranscript(root, raw string) (*os.File, bool) {
	if !strings.HasPrefix(root, "/") || !strings.HasPrefix(raw, "/") {
		return nil, false
	}
	rootParts := pathParts(root)
	pathPs := pathParts(raw)
	if len(pathPs) < len(rootParts) || !slices.Equal(pathPs[:len(rootParts)], rootParts) {
		return nil, false
	}
	rel := pathPs[len(rootParts):]
	if !relativePartsAllowed(rel) || !strings.HasSuffix(rel[len(rel)-1], ".jsonl") {
		return nil, false
	}

	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, false
	}
	dirFD, ok := openAbsoluteDirectory(resolved)
	if !ok {
		return nil, false
	}
	for _, part := range rel[:len(rel)-1] {
		next, err := syscall.Openat(dirFD, part, dirOpenFlags, 0)
		syscall.Close(dirFD)
		if err != nil {
			return nil, false
		}
		dirFD = next
	}
	fd, err := syscall.Openat(dirFD, rel[len(rel)-1], fileOpenFlags, 0)
	syscall.Close(dirFD)
	if err != nil {
		return nil, false
	}
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil || st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		syscall.Close(fd)
		return nil, false
	}
	return os.NewFile(uintptr(fd), raw), true
}

// readFirstRecord returns the bytes before the first newline, reading at most
// inputBudget+1 bytes. It fails when no newline appears within the budget.
func readFirstRecord(r io.Reader) ([]byte, bool) {
	buf := make([]byte, 0, inputBudget+1)
	for len(buf) <= inputBudget {
		start := len(buf)
		n, err := r.Read(buf[start:cap(buf)])
		buf = buf[:start+n]
		if i := bytes.IndexByte(buf[start:], '\n'); i >= 0 {
			return buf[:start+i], true
		}
		if errors.Is(err, io.EOF) {
			return buf, true
		}
		if err != nil {
			return nil, false
		}
	}
	return nil, false
}

// readChunkBytes caps each read of a first-record prefix, as the pre-migration
// Python reader did.
const readChunkBytes = 4096

// readFirstRecordPrefix returns the bytes before the first newline. It reads
// in chunks of at most readChunkBytes and retains at most inputBudget+1 bytes:
// the extra byte lets a record of exactly inputBudget bytes be told apart from
// an oversize one. A record longer than inputBudget whose newline does not
// appear within the first inputBudget+1 bytes is rejected, as is a record that
// reaches the bound with no newline. A missing newline on a record that ends
// at EOF within the bound is not a failure.
func readFirstRecordPrefix(r io.Reader) ([]byte, bool) {
	buf := make([]byte, inputBudget+1)
	n := 0
	eof := false
	for {
		if i := bytes.IndexByte(buf[:n], '\n'); i >= 0 {
			return buf[:i], true
		}
		if n > inputBudget {
			return nil, false
		}
		if eof {
			return buf[:n], true
		}
		end := min(n+readChunkBytes, len(buf))
		m, err := r.Read(buf[n:end])
		n += m
		if errors.Is(err, io.EOF) {
			eof = true
		} else if err != nil {
			return nil, false
		}
	}
}

// transcriptFirstRecord emits the first record of the transcript at raw when
// it is a JSON object.
func transcriptFirstRecord(root, raw string, stdout io.Writer) int {
	if !rawAbsolutePathAllowed(raw) {
		return statusRejected
	}
	file, ok := openContainedTranscript(root, raw)
	if !ok {
		return statusRejected
	}
	defer file.Close()
	record, ok := readFirstRecord(file)
	if !ok || !validBounded(record) {
		return statusRejected
	}
	var object map[string]any
	if err := json.Unmarshal(record, &object); err != nil || object == nil {
		return statusRejected
	}
	return emitBounded(record, stdout)
}

// transcriptThreadSpawnMetadata emits {"parent_thread_id":...} for a
// session_meta transcript whose subagent source is thread_spawn.
func transcriptThreadSpawnMetadata(root, raw string, stdout io.Writer) int {
	if !rawAbsolutePathAllowed(raw) {
		return statusRejected
	}
	file, ok := openContainedTranscript(root, raw)
	if !ok {
		return statusRejected
	}
	defer file.Close()
	prefix, ok := readFirstRecordPrefix(file)
	if !ok || !validBounded(prefix) {
		return statusRejected
	}
	metadata, err := parseThreadSpawnMetadata(prefix)
	if err != nil || metadata == nil {
		return statusRejected
	}
	payload, err := json.Marshal(struct {
		ParentThreadID *string `json:"parent_thread_id"`
	}{ParentThreadID: metadata.parentThreadID})
	if err != nil {
		return statusFailed
	}
	return emitBounded(payload, stdout)
}
