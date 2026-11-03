package main

import (
	"encoding/json"
	"reflect"
)

// pendingRootCorrectionPrior checks an explicit correction against an unapplied record.
//
// Example: A later completion refers to the exact earlier pending completion.
func pendingRootCorrectionPrior(
	event syncEvent,
	addition syncAddition,
	pending syncPendingAddition,
	applied bool,
) bool {
	if event.Event != "correction" || addition.Target != syncTargetRootCompletion || applied || len(addition.ExpectedPrior) == 0 || pending.Target != syncTargetRootCompletion {
		return false
	}
	var line int
	if json.Unmarshal(event.Details.Corrects, &line) != nil || line != pending.Line {
		return false
	}
	var supplied, original any
	if json.Unmarshal(addition.ExpectedPrior, &supplied) != nil || json.Unmarshal([]byte(pending.Record), &original) != nil {
		return false
	}
	return reflect.DeepEqual(supplied, original)
}
