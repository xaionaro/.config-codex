package main

import (
	"bytes"
	ctxpkg "context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DestinationQuery describes the original InspectionContext and already proved output callback values.
//
// Example: the helper receives all retained names, even if native observation is unavailable.
type DestinationQuery struct {
	Query       string            `json:"query"`
	Base        string            `json:"base"`
	Directories []*string         `json:"directories"`
	Options     []string          `json:"options"`
	Environment map[string]string `json:"environment"`
	Known       bool              `json:"known"`
	Outputs     []string          `json:"outputs"`
	Spans       [][]int           `json:"spans"`
	Arguments   []string          `json:"arguments"`
}

// outputContext limits target inference to an ordinary original worktree InspectionContext.
//
// Example: cumulative -C follows symlinks before dot-dot and prefix matches the original physical cwd.
func outputContext(q DestinationQuery) (result InspectionContext) {
	result = InspectionContext{Certainty: SnapshotAvailabilityAdvisory}
	safe := map[string]bool{"--no-pager": true, "--literal-pathspecs": true, "--glob-pathspecs": true, "--noglob-pathspecs": true, "--icase-pathspecs": true}
	if !q.Known || !filepath.IsAbs(q.Base) {
		return result
	}
	for _, option := range q.Options {
		if !safe[option] {
			return result
		}
	}
	for key, value := range q.Environment {
		if value == "" {
			continue
		}
		if strings.HasPrefix(key, "LD_") || strings.HasPrefix(key, "GIT_TRACE") {
			return result
		}
		switch key {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG", "GLIBC_TUNABLES", "GCONV_PATH", "LOCPATH", "MALLOC_TRACE":
			return result
		}
	}
	physical, identities, valid := originalContext(q.Base, q.Directories)
	if !valid {
		return result
	}
	invocation := Invocation{CWD: physical, Environment: q.Environment}
	sandbox, err := newSandbox(invocation)
	if err != nil {
		return result
	}
	// Cleanup failure invalidates the query snapshot.
	//
	// Example: unavailable owned-state cleanup keeps the result advisory.
	defer func() {
		if err := os.RemoveAll(sandbox.dir); err != nil {
			result = InspectionContext{Certainty: SnapshotAvailabilityAdvisory}
		}
	}()
	version, _, status, err := sandbox.run([]string{"--version"}, metadataOutput)
	if err != nil || status != 0 || strings.TrimSpace(string(version)) != "git version 2.51.0" {
		return result
	}
	values := []string{}
	for _, query := range []string{"--absolute-git-dir", "--show-toplevel", "--show-prefix"} {
		bounded, cancel := ctxpkg.WithTimeout(ctxpkg.Background(), time.Second)
		args := append(append([]string{}, q.Options...), "rev-parse", query)
		output, _, status, err := sandbox.runContext(bounded, args, metadataOutput)
		cancel()
		if err != nil || status != 0 || len(output) > inspectionPathLimit+1 {
			return result
		}
		values = append(values, strings.TrimSuffix(string(output), "\n"))
	}
	gitDir, err := filepath.EvalSymlinks(values[0])
	if err != nil {
		return result
	}
	root, err := filepath.EvalSymlinks(values[1])
	if err != nil {
		return result
	}
	original, err := filepath.EvalSymlinks(root + "/" + values[2])
	if err != nil || original != physical {
		return result
	}
	for _, value := range []string{physical, root, gitDir, values[2]} {
		if len(value) > inspectionPathLimit {
			return result
		}
	}
	return InspectionContext{Base: q.Base, Directories: q.Directories, DirectoryIdentities: identities, CWD: physical, Worktree: root, GitDir: gitDir, Prefix: values[2], Certainty: SnapshotAvailabilitySnapshot}
}

// outputDestination maps an original callback name to a certain snapshot or an advisory value.
//
// Example: dangling aliases and missing ancestors never become invented create targets.
func outputDestination(
	value string,
	c InspectionContext,
) OutputDestination {
	d := OutputDestination{Spelling: value, Identity: SnapshotAvailabilityAdvisory, Endpoint: EndpointKindUnresolved, Decision: OutputIntentAdvisory}
	if c.Certainty != SnapshotAvailabilitySnapshot || value == "" || strings.IndexByte(value, 0) >= 0 || strings.HasSuffix(value, "/") || strings.HasPrefix(value, "//") {
		return d
	}
	raw := value
	if !filepath.IsAbs(raw) {
		raw = c.CWD + "/" + raw
	}
	if len(raw) > inspectionPathLimit || len(strings.Split(raw, "/")) > inspectionPathDepthLimit {
		return d
	}
	target, err := filepath.EvalSymlinks(raw)
	if err == nil {
		if len(target) > inspectionPathLimit || target == "/proc" || strings.HasPrefix(target, "/proc/") || target == "/sys" || strings.HasPrefix(target, "/sys/") {
			return d
		}
		info, err := os.Stat(target)
		if err != nil {
			return d
		}
		state, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return d
		}
		switch {
		case info.Mode().IsRegular():
			d.Endpoint = EndpointKindRegular
			// A checked callback intent is distinct from a certified successful native write.
			if regularIntentAccess(raw, target, state) {
				d.Decision = OutputIntentAccessCheckedOutputIntent
				d.Access = AccessEvidenceKernelChecked
			}
		case info.Mode()&os.ModeCharDevice != 0:
			null, err := os.Stat("/dev/null")
			if err != nil || null.Mode()&os.ModeCharDevice == 0 {
				return d
			}
			ns, ok := null.Sys().(*syscall.Stat_t)
			// Linux null has the established device number 1:3; aliases additionally preserve inode identity.
			if !ok || ns.Rdev != inspectionNullDeviceNumber || state.Dev != ns.Dev || state.Ino != ns.Ino || state.Rdev != ns.Rdev {
				return d
			}
			d.Endpoint = EndpointKindNull
			if effectiveAccess(raw, 2) {
				d.Decision = OutputIntentHarmlessEndpoint
				d.Access = AccessEvidenceKernelChecked
			}
		default:
			return d
		}
		d.Target = target
		d.Identity = SnapshotAvailabilitySnapshot
		d.Device = &state.Dev
		d.Inode = &state.Ino
		return d
	}
	if !os.IsNotExist(err) {
		return d
	}
	if _, err := os.Lstat(raw); !os.IsNotExist(err) {
		return d
	}
	separator := strings.LastIndex(raw, "/")
	if separator < 0 {
		return d
	}
	leaf := raw[separator+1:]
	if leaf == "" || leaf == "." || leaf == ".." {
		return d
	}
	parent, err := filepath.EvalSymlinks(raw[:separator])
	if err != nil {
		return d
	}
	target = parent + "/" + leaf
	if len(target) > inspectionPathLimit || strings.HasPrefix(target, "/proc/") || strings.HasPrefix(target, "/sys/") {
		return d
	}
	info, err := os.Stat(parent)
	if err != nil || !info.IsDir() {
		return d
	}
	state, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return d
	}
	d.Target = target
	d.Identity = SnapshotAvailabilitySnapshot
	d.Endpoint = EndpointKindAbsentLeaf
	// The checked creation intent does not certify successful native creation.
	// Both write and directory search access use the effective-credential kernel predicate.
	if localIntentDomain(parent) && effectiveAccess(raw[:separator], 3) {
		d.Decision = OutputIntentAccessCheckedOutputIntent
		d.Access = AccessEvidenceKernelChecked
	}
	d.ParentDevice = &state.Dev
	d.ParentInode = &state.Ino
	return d
}

// queryDestinations retains each name without promoting unsupported target metadata.
//
// Example: an all-null bounded prefix is returned independently of parser tail completeness.
func queryDestinations(data []byte) ([]byte, error) {
	var q DestinationQuery
	if decodeDestinationQuery(data, &q) != nil || q.Query != "destinations" || len(q.Outputs) > inspectionDestinationLimit || len(q.Outputs) != len(q.Spans) {
		return nil, fmt.Errorf("invalid destination query or response")
	}
	c := outputContext(q)
	destinations := []OutputDestination{}
	for n, value := range q.Outputs {
		if len(value) > inspectionPathLimit || len(q.Spans[n]) != 2 {
			return nil, fmt.Errorf("invalid destination query or response")
		}
		d := outputDestination(value, c)
		d.Ordinal = n
		d.OptionIndex = q.Spans[n][0]
		d.ValueIndex = q.Spans[n][1]
		destinations = append(destinations, d)
	}
	result, err := json.Marshal(struct {
		Query        string              `json:"query"`
		Context      InspectionContext   `json:"context"`
		Destinations []OutputDestination `json:"destinations"`
	}{"destinations", c, destinations})
	if err != nil || len(result) > invocationByteLimit {
		return nil, fmt.Errorf("invalid destination query or response")
	}
	return result, nil
}

// decodeDestinationQuery admits one bounded, closed original-context request.
//
// Example: unknown fields or trailing documents remain advisory.
func decodeDestinationQuery(
	data []byte,
	query *DestinationQuery,
) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(query); err != nil {
		return err
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); err != io.EOF {
		return fmt.Errorf("expected one query document")
	}
	if len(query.Directories) > inspectionDirectoryLimit || len(query.Outputs) > inspectionDestinationLimit || len(query.Base) > inspectionPathLimit {
		return fmt.Errorf("query exceeds context bounds")
	}
	for _, value := range query.Outputs {
		if len(value) > inspectionPathLimit || strings.IndexByte(value, 0) >= 0 {
			return fmt.Errorf("output path exceeds bounded domain")
		}
	}
	for _, value := range query.Directories {
		if value == nil || len(*value) > inspectionPathLimit || strings.IndexByte(*value, 0) >= 0 {
			return fmt.Errorf("directory operand exceeds bounded domain")
		}
	}
	return nil
}
