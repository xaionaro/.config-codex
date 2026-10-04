package main

import (
	"encoding/json"
	"fmt"
)

// SnapshotAvailability is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type SnapshotAvailability int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	SnapshotAvailabilityUnknown SnapshotAvailability = iota
	SnapshotAvailabilityAdvisory
	SnapshotAvailabilitySnapshot
)

// MarshalJSON emits only documented SnapshotAvailability values.
//
// Example: the zero value emits an unavailable empty state.
func (v SnapshotAvailability) MarshalJSON() ([]byte, error) {
	switch v {
	case SnapshotAvailabilityUnknown:
		return json.Marshal("")
	case SnapshotAvailabilityAdvisory:
		return json.Marshal("Advisory")
	case SnapshotAvailabilitySnapshot:
		return json.Marshal("Snapshot")
	}
	return nil, fmt.Errorf("unknown SnapshotAvailability: %d", v)
}

// UnmarshalJSON rejects states outside SnapshotAvailability.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *SnapshotAvailability) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = SnapshotAvailabilityUnknown
		return nil
	case "Advisory":
		*v = SnapshotAvailabilityAdvisory
		return nil
	case "Snapshot":
		*v = SnapshotAvailabilitySnapshot
		return nil
	}
	return fmt.Errorf("unknown SnapshotAvailability: %q", s)
}

// EndpointKind is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type EndpointKind int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	EndpointKindUnknown EndpointKind = iota
	EndpointKindUnresolved
	EndpointKindRegular
	EndpointKindNull
	EndpointKindAbsentLeaf
)

// MarshalJSON emits only documented EndpointKind values.
//
// Example: the zero value emits an unavailable empty state.
func (v EndpointKind) MarshalJSON() ([]byte, error) {
	switch v {
	case EndpointKindUnknown:
		return json.Marshal("")
	case EndpointKindUnresolved:
		return json.Marshal("Unresolved")
	case EndpointKindRegular:
		return json.Marshal("Regular")
	case EndpointKindNull:
		return json.Marshal("Null")
	case EndpointKindAbsentLeaf:
		return json.Marshal("AbsentLeaf")
	}
	return nil, fmt.Errorf("unknown EndpointKind: %d", v)
}

// UnmarshalJSON rejects states outside EndpointKind.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *EndpointKind) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = EndpointKindUnknown
		return nil
	case "Unresolved":
		*v = EndpointKindUnresolved
		return nil
	case "Regular":
		*v = EndpointKindRegular
		return nil
	case "Null":
		*v = EndpointKindNull
		return nil
	case "AbsentLeaf":
		*v = EndpointKindAbsentLeaf
		return nil
	}
	return fmt.Errorf("unknown EndpointKind: %q", s)
}

// AccessEvidence is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type AccessEvidence int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	AccessEvidenceUnknown AccessEvidence = iota
	AccessEvidenceKernelChecked
)

// MarshalJSON emits only documented AccessEvidence values.
//
// Example: the zero value emits an unavailable empty state.
func (v AccessEvidence) MarshalJSON() ([]byte, error) {
	switch v {
	case AccessEvidenceUnknown:
		return json.Marshal("")
	case AccessEvidenceKernelChecked:
		return json.Marshal("KernelChecked")
	}
	return nil, fmt.Errorf("unknown AccessEvidence: %d", v)
}

// UnmarshalJSON rejects states outside AccessEvidence.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *AccessEvidence) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = AccessEvidenceUnknown
		return nil
	case "KernelChecked":
		*v = AccessEvidenceKernelChecked
		return nil
	}
	return fmt.Errorf("unknown AccessEvidence: %q", s)
}

// OutputIntent is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type OutputIntent int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	OutputIntentUnknown OutputIntent = iota
	OutputIntentAdvisory
	OutputIntentHarmlessEndpoint
	OutputIntentAccessCheckedOutputIntent
)

// MarshalJSON emits only documented OutputIntent values.
//
// Example: the zero value emits an unavailable empty state.
func (v OutputIntent) MarshalJSON() ([]byte, error) {
	switch v {
	case OutputIntentUnknown:
		return json.Marshal("")
	case OutputIntentAdvisory:
		return json.Marshal("Advisory")
	case OutputIntentHarmlessEndpoint:
		return json.Marshal("HarmlessEndpoint")
	case OutputIntentAccessCheckedOutputIntent:
		return json.Marshal("AccessCheckedOutputIntent")
	}
	return nil, fmt.Errorf("unknown OutputIntent: %d", v)
}

// UnmarshalJSON rejects states outside OutputIntent.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *OutputIntent) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = OutputIntentUnknown
		return nil
	case "Advisory":
		*v = OutputIntentAdvisory
		return nil
	case "HarmlessEndpoint":
		*v = OutputIntentHarmlessEndpoint
		return nil
	case "AccessCheckedOutputIntent":
		*v = OutputIntentAccessCheckedOutputIntent
		return nil
	}
	return fmt.Errorf("unknown OutputIntent: %q", s)
}

// CallbackEvidence is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type CallbackEvidence int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	CallbackEvidenceUnknown CallbackEvidence = iota
	CallbackEvidenceSourceModeled
	CallbackEvidenceAdvisory
)

// MarshalJSON emits only documented CallbackEvidence values.
//
// Example: the zero value emits an unavailable empty state.
func (v CallbackEvidence) MarshalJSON() ([]byte, error) {
	switch v {
	case CallbackEvidenceUnknown:
		return json.Marshal("")
	case CallbackEvidenceSourceModeled:
		return json.Marshal("SourceModeled")
	case CallbackEvidenceAdvisory:
		return json.Marshal("Advisory")
	}
	return nil, fmt.Errorf("unknown CallbackEvidence: %d", v)
}

// UnmarshalJSON rejects states outside CallbackEvidence.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *CallbackEvidence) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = CallbackEvidenceUnknown
		return nil
	case "SourceModeled":
		*v = CallbackEvidenceSourceModeled
		return nil
	case "Advisory":
		*v = CallbackEvidenceAdvisory
		return nil
	}
	return fmt.Errorf("unknown CallbackEvidence: %q", s)
}

// InspectionDecision is a closed snapshot protocol vocabulary.
//
// Example: unknown wire states cannot become certain findings.
type InspectionDecision int

// Closed protocol values preserve advisory evidence independently.
//
// Example: the zero value remains unavailable.
const (
	InspectionDecisionUnknown InspectionDecision = iota
	InspectionDecisionAdvisory
	InspectionDecisionDenyAccessCheckedOutputIntent
	InspectionDecisionHarmlessEndpoint
	InspectionDecisionNoOutput
)

// MarshalJSON emits only documented InspectionDecision values.
//
// Example: the zero value emits an unavailable empty state.
func (v InspectionDecision) MarshalJSON() ([]byte, error) {
	switch v {
	case InspectionDecisionUnknown:
		return json.Marshal("")
	case InspectionDecisionAdvisory:
		return json.Marshal("Advisory")
	case InspectionDecisionDenyAccessCheckedOutputIntent:
		return json.Marshal("DenyAccessCheckedOutputIntent")
	case InspectionDecisionHarmlessEndpoint:
		return json.Marshal("HarmlessEndpoint")
	case InspectionDecisionNoOutput:
		return json.Marshal("NoOutput")
	}
	return nil, fmt.Errorf("unknown InspectionDecision: %d", v)
}

// UnmarshalJSON rejects states outside InspectionDecision.
//
// Example: unsupported intent names cannot authorize a denial.
func (v *InspectionDecision) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	switch s {
	case "":
		*v = InspectionDecisionUnknown
		return nil
	case "Advisory":
		*v = InspectionDecisionAdvisory
		return nil
	case "DenyAccessCheckedOutputIntent":
		*v = InspectionDecisionDenyAccessCheckedOutputIntent
		return nil
	case "HarmlessEndpoint":
		*v = InspectionDecisionHarmlessEndpoint
		return nil
	case "NoOutput":
		*v = InspectionDecisionNoOutput
		return nil
	}
	return fmt.Errorf("unknown InspectionDecision: %q", s)
}
