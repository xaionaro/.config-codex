package main

import "time"

// futureEstimateIssues checks time anchors even when canonical sources are unavailable.
//
// Example: A future as_of remains incomplete without a session directory.
func futureEstimateIssues(
	r report,
	evaluation time.Time,
) []string {
	reportTime, _ := parseUTC(r.Timestamp)
	estimates := append([]completionEstimate{}, r.PriorityEstimates...)
	if r.CompletionEstimate != nil {
		estimates = append(estimates, *r.CompletionEstimate)
	}
	var issues []string
	for _, e := range estimates {
		base, err := parseUTC(e.AsOf)
		if err == nil && (base.After(reportTime) || base.After(evaluation)) {
			issues = append(issues, "completion estimate as_of "+e.AsOf+" is in the future")
		}
	}
	return issues
}
