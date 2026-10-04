package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
)

// DirectoryIdentity identifies one resolved raw directory operand.
//
// Example: retargeting a base alias changes its inode dependency.
type DirectoryIdentity struct {
	Target string `json:"target"`
	Device uint64 `json:"device"`
	Inode  uint64 `json:"inode"`
}

// UnmarshalJSON admits only the closed native helper observation vocabulary.
//
// Example: unknown observation values stay outside the helper finding domain.
func (r *Result) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch value {
	case "Helper":
		*r = Helper
	case "NoHelper":
		*r = NoHelper
	case "Advisory":
		*r = Advisory
	default:
		return fmt.Errorf("unknown helper result: %q", value)
	}
	return nil
}

// queryHelper independently observes an unchanged all-null original invocation.
//
// Example: optional output-target mapping failure cannot erase a reached textconv.
func queryHelper(data []byte) ([]byte, error) {
	var q DestinationQuery
	if decodeDestinationQuery(data, &q) != nil || !q.Known || len(q.Outputs) > inspectionDestinationLimit {
		return nil, fmt.Errorf("invalid helper query")
	}
	physical, identities, ok := originalContext(q.Base, q.Directories)
	h := HelperRecord{Query: "helper", Observation: advisory("original output replay eligibility remains advisory")}
	if !ok {
		return marshalHelperRecord(h)
	}
	c := InspectionContext{Base: q.Base, Directories: q.Directories, DirectoryIdentities: identities, CWD: physical, Certainty: SnapshotAvailabilitySnapshot}
	h.Context = c
	proof := OfflineAnalyze(q.Arguments)
	if !proof.Complete || len(proof.Outputs) != len(q.Outputs) {
		return marshalHelperRecord(h)
	}
	for n, value := range proof.Outputs {
		if value != q.Outputs[n] {
			return nil, fmt.Errorf("invalid helper query")
		}
		d := outputDestination(value, c)
		d.Ordinal = n
		h.Destinations = append(h.Destinations, d)
		if d.Decision != OutputIntentHarmlessEndpoint || d.Access != AccessEvidenceKernelChecked {
			return marshalHelperRecord(h)
		}
	}
	h.Observation = Inspect(Invocation{CWD: physical, Arguments: append(append([]string{}, q.Options...), q.Arguments...), Environment: q.Environment})
	if !contextFresh(c) {
		h.Observation = advisory("original context changed during observation")
	}
	for _, d := range h.Destinations {
		if !endpointFresh(d, c) {
			h.Observation = advisory("original output changed during observation")
		}
	}
	return marshalHelperRecord(h)
}

// originalContext resolves raw directory operands in their original order.
//
// Example: a changed -C alias cannot authorize the obsolete physical target.
func originalContext(
	base string,
	directories []*string,
) (string, []DirectoryIdentity, bool) {
	if !filepath.IsAbs(base) || !boundedContextPath(base) || len(directories) > inspectionDirectoryLimit {
		return "", nil, false
	}
	physical, err := filepath.EvalSymlinks(base)
	if err != nil {
		return "", nil, false
	}
	identities := []DirectoryIdentity{}

	identity, ok := resolveDirectoryIdentity(physical)
	if !ok {
		return "", nil, false
	}
	identities = append(identities, identity)
	for _, directory := range directories {
		if directory == nil || !boundedContextPath(*directory) || strings.IndexByte(*directory, 0) >= 0 {
			return "", nil, false
		}
		if *directory != "" {
			raw := *directory
			if !filepath.IsAbs(raw) {
				raw = physical + "/" + raw
			}
			if !boundedContextPath(raw) {
				return "", nil, false
			}
			physical, err = filepath.EvalSymlinks(raw)
			if err != nil {
				return "", nil, false
			}
		}
		identity, ok := resolveDirectoryIdentity(physical)
		if !ok {
			return "", nil, false
		}
		identities = append(identities, identity)
	}
	return physical, identities, true
}

// contextFresh checks the complete stored original-context dependency chain.
//
// Example: a retargeted base or an earlier -C operand invalidates dependent effects.
func contextFresh(c InspectionContext) bool {
	physical, identities, ok := originalContext(c.Base, c.Directories)
	if !ok || c.Certainty != SnapshotAvailabilitySnapshot || physical != c.CWD || !reflect.DeepEqual(identities, c.DirectoryIdentities) {
		return false
	}
	if c.Worktree == "" && c.GitDir == "" {
		return true
	}
	root, err := filepath.EvalSymlinks(c.Worktree)
	if err != nil || root != c.Worktree {
		return false
	}
	gitdir, err := filepath.EvalSymlinks(c.GitDir)
	if err != nil || gitdir != c.GitDir {
		return false
	}
	fromPrefix, err := filepath.EvalSymlinks(root + "/" + c.Prefix)
	return err == nil && fromPrefix == physical
}

// endpointFresh rechecks identity and access for every dependency endpoint.
//
// Example: a now failing null alias blocks conclusions about later callbacks.
func endpointFresh(
	d OutputDestination,
	c InspectionContext,
) bool {
	now := outputDestination(d.Spelling, c)
	return d.Identity == SnapshotAvailabilitySnapshot && now.Identity == SnapshotAvailabilitySnapshot &&
		d.Target == now.Target && d.Endpoint == now.Endpoint && d.Decision == now.Decision &&
		reflect.DeepEqual(d.Device, now.Device) && reflect.DeepEqual(d.Inode, now.Inode) &&
		reflect.DeepEqual(d.ParentDevice, now.ParentDevice) && reflect.DeepEqual(d.ParentInode, now.ParentInode) &&
		now.Access == AccessEvidenceKernelChecked
}

// marshalHelperRecord preserves encoding failures at the protocol boundary.
//
// Example: a response with an invalid observation state returns a contextual error.
func marshalHelperRecord(h HelperRecord) ([]byte, error) {
	data, err := json.Marshal(h)
	if err != nil {
		return nil, fmt.Errorf("encode helper record: %w", err)
	}
	if len(data)+1 > invocationByteLimit {
		return nil, fmt.Errorf("helper record exceeds protocol bound")
	}
	return data, nil
}

// resolveDirectoryIdentity checks directory identity and current kernel search access.
//
// Example: an inaccessible raw -C operand invalidates its dependent context.
func resolveDirectoryIdentity(physical string) (DirectoryIdentity, bool) {
	info, err := os.Stat(physical)
	if err != nil || !info.IsDir() || !boundedContextPath(physical) {
		return DirectoryIdentity{}, false
	}
	state, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !effectiveAccess(physical, 1) {
		return DirectoryIdentity{}, false
	}
	return DirectoryIdentity{Target: physical, Device: state.Dev, Inode: state.Ino}, true
}

// boundedContextPath limits raw and resolved directory pathname depth before resolution.
//
// Example: excessive dot components remain advisory even when they resolve to a short directory.
func boundedContextPath(path string) bool {
	return len(path) <= inspectionPathLimit && strings.Count(path, "/")+1 <= inspectionPathDepthLimit && strings.IndexByte(path, 0) < 0
}
