package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
)

// consumeInspection rechecks independent output and helper snapshot findings.
//
// Example: an advisory output retains a fresh helper finding.
func consumeInspection(data []byte) InspectionFinding {
	result := InspectionFinding{}
	var r InspectionRecord
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&r) != nil || r.Schema != "git-inspection-output-v1" || len(r.Destinations) > inspectionDestinationLimit {
		return result
	}
	var extra json.RawMessage
	if decoder.Decode(&extra) != io.EOF || len(r.Repository) > inspectionPathLimit || len(r.Reason) > inspectionPathLimit || !boundedInspectionContext(r.Context) {
		return result
	}
	for _, d := range r.Destinations {
		if !boundedOutputDestination(d) {
			return result
		}
	}
	if h := r.Helper; h != nil && h.Observation.Result == Helper && h.Remediation != "" && len(h.Remediation) < inspectionAlternativeLimit && boundedInspectionContext(h.Context) && len(h.Observation.Target) <= inspectionPathLimit && len(h.Observation.Reason) <= inspectionPathLimit && contextFresh(h.Context) && len(h.Destinations) <= inspectionDestinationLimit {
		fresh := true
		for _, d := range h.Destinations {
			if !boundedOutputDestination(d) || d.Decision != OutputIntentHarmlessEndpoint || !endpointFresh(d, h.Context) {
				fresh = false
			}
		}
		if fresh {
			result.Helper = &HelperFinding{Target: h.Observation.Target, Reason: h.Observation.Reason, Remediation: h.Remediation, Repository: r.Repository}
		}
	}

	if !r.Complete || r.TailUnknown || r.Decision != InspectionDecisionDenyAccessCheckedOutputIntent || len(r.StdoutArgv) < 6 || r.StdoutArgv[0] != "git" || !contextFresh(r.Context) {
		return result
	}
	size := 0
	for _, arg := range r.StdoutArgv {
		size += len(arg)
		if strings.IndexByte(arg, 0) >= 0 {
			return result
		}
	}
	if size > inspectionAlternativeLimit {
		return result
	}
	if r.StdoutArgv[1] != "--no-pager" || r.StdoutArgv[2] != "-C" || r.StdoutArgv[3] != r.Context.CWD {
		return result
	}
	position := 4
	safe := map[string]bool{"--no-pager": true, "--literal-pathspecs": true, "--glob-pathspecs": true, "--noglob-pathspecs": true, "--icase-pathspecs": true}
	for position < len(r.StdoutArgv) && safe[r.StdoutArgv[position]] {
		position++
	}
	if position+2 >= len(r.StdoutArgv) || r.StdoutArgv[position] != "-c" || r.StdoutArgv[position+1] != "core.fsmonitor=false" {
		return result
	}
	position += 2
	proof := OfflineAnalyze(r.StdoutArgv[position:])
	if !proof.Complete || len(proof.Outputs) > 0 {
		return result
	}
	for _, d := range r.Destinations {
		if !endpointFresh(d, r.Context) {
			return result
		}
		if d.Decision == OutputIntentAccessCheckedOutputIntent && d.Reach == CallbackEvidenceSourceModeled {
			result.Effect = "explicit-access-checked-git-output-intent"
			result.Target = d.Target
			result.Endpoint = d.Endpoint
			result.Repository = r.Repository
			result.StdoutArgv = r.StdoutArgv
			return result
		}
		if !boundedOutputDestination(d) || d.Decision != OutputIntentHarmlessEndpoint {
			return result
		}
	}
	return result
}

// InspectionFinding contains independently fresh helper and explicit output intent findings.
//
// Example: an advisory output still carries a checked helper result.
type InspectionFinding struct {
	Effect     string         `json:"effect,omitempty"`
	Target     string         `json:"target,omitempty"`
	Endpoint   EndpointKind   `json:"endpoint,omitempty"`
	Repository string         `json:"repository,omitempty"`
	StdoutArgv []string       `json:"stdout_argv,omitempty"`
	Helper     *HelperFinding `json:"helper,omitempty"`
}

// HelperFinding names a reached helper and its documented recovery command.
//
// Example: text conversion can be disabled for a raw inspection.
type HelperFinding struct {
	Target      string `json:"target"`
	Reason      string `json:"reason"`
	Remediation string `json:"remediation"`
	Repository  string `json:"repository"`
}

// boundedInspectionContext checks retained dependency sizes before filesystem resolution.
//
// Example: oversized raw directory chains stay advisory.
func boundedInspectionContext(c InspectionContext) bool {
	if len(c.Directories) > inspectionDirectoryLimit || len(c.DirectoryIdentities) > inspectionDirectoryLimit+1 {
		return false
	}
	for _, path := range []string{c.Base, c.CWD, c.GitDir, c.Prefix, c.Worktree} {
		if len(path) > inspectionPathLimit || strings.IndexByte(path, 0) >= 0 {
			return false
		}
	}
	for _, path := range c.Directories {
		if path == nil || len(*path) > inspectionPathLimit || strings.IndexByte(*path, 0) >= 0 {
			return false
		}
	}
	for _, identity := range c.DirectoryIdentities {
		if len(identity.Target) > inspectionPathLimit || strings.IndexByte(identity.Target, 0) >= 0 {
			return false
		}
	}
	return true
}

// boundedOutputDestination checks retained callback path and span metadata.
//
// Example: malformed source offsets cannot become certain callback evidence.
func boundedOutputDestination(d OutputDestination) bool {
	return d.Ordinal >= 0 && d.Ordinal < inspectionDestinationLimit && d.OptionIndex >= 0 && d.ValueIndex >= 0 && len(d.Spelling) <= inspectionPathLimit && len(d.Target) <= inspectionPathLimit && strings.IndexByte(d.Spelling, 0) < 0 && strings.IndexByte(d.Target, 0) < 0
}
