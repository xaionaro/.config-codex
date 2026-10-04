package main

// InspectionContext stores raw directory dependencies and their physical snapshot.
//
// Example: consumption rechecks the stored dependencies before reporting a finding.
type InspectionContext struct {
	Base                string               `json:"base"`
	Directories         []*string            `json:"directories"`
	DirectoryIdentities []DirectoryIdentity  `json:"directory_identities"`
	CWD                 string               `json:"cwd"`
	GitDir              string               `json:"git_dir"`
	Prefix              string               `json:"prefix"`
	Worktree            string               `json:"worktree"`
	Certainty           SnapshotAvailability `json:"certainty"`
}

// OutputDestination retains one source-modeled callback and current endpoint evidence.
//
// Example: consumption rechecks the stored dependencies before reporting a finding.
type OutputDestination struct {
	Access       AccessEvidence       `json:"access"`
	Ordinal      int                  `json:"ordinal"`
	OptionIndex  int                  `json:"option_index"`
	ValueIndex   int                  `json:"value_index"`
	Reach        CallbackEvidence     `json:"reach"`
	Spelling     string               `json:"spelling"`
	Target       string               `json:"target"`
	Identity     SnapshotAvailability `json:"identity"`
	Endpoint     EndpointKind         `json:"endpoint"`
	Decision     OutputIntent         `json:"decision"`
	Device       *uint64              `json:"device"`
	Inode        *uint64              `json:"inode"`
	ParentDevice *uint64              `json:"parent_device"`
	ParentInode  *uint64              `json:"parent_inode"`
}

// InspectionRecord composes repository identity, output snapshots and an independent helper.
//
// Example: consumption rechecks the stored dependencies before reporting a finding.
type InspectionRecord struct {
	Reason       string              `json:"reason,omitempty"`
	Query        string              `json:"query,omitempty"`
	Helper       *HelperRecord       `json:"helper,omitempty"`
	Schema       string              `json:"schema"`
	Repository   string              `json:"repository"`
	Context      InspectionContext   `json:"context"`
	Destinations []OutputDestination `json:"destinations"`
	Complete     bool                `json:"complete"`
	TailUnknown  bool                `json:"tail_unknown"`
	StdoutArgv   []string            `json:"stdout_argv"`
	Decision     InspectionDecision  `json:"decision"`
}

// HelperRecord stores helper observation with its own context and null endpoint dependencies.
//
// Example: consumption rechecks the stored dependencies before reporting a finding.
type HelperRecord struct {
	Query        string              `json:"query,omitempty"`
	Observation  Observation         `json:"observation"`
	Context      InspectionContext   `json:"context"`
	Destinations []OutputDestination `json:"destinations"`
	Remediation  string              `json:"remediation"`
}

// Inspection protocol bounds cap paths, retained callbacks and recovery command bytes.
//
// Example: a 65th callback retains the first 64 and marks its tail advisory.
const (
	inspectionNullDeviceNumber = 259
	inspectionDestinationLimit = stageDestinationLimit
	inspectionDirectoryLimit   = 64
	inspectionPathLimit        = stagePathLimit
	inspectionPathDepthLimit   = 128
	inspectionAlternativeLimit = 65536
)
