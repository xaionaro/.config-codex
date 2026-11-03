package main

import (
	"encoding/json"
	"strings"
)

// syncAdditionSourceValid checks supplied lane and root identities against their sources.
func syncAdditionSourceValid(
	addition syncAddition,
	ledger ledgerSource,
	forecasts forecastSource,
) bool {
	if addition.Target != syncTargetLane && addition.Target != syncTargetRootCompletion && addition.Target != syncTargetRootForecast {
		return true
	}
	var record struct {
		WorkRef     string `json:"work_ref"`
		ForecastRef string `json:"forecast_ref"`
		Outcome     string `json:"outcome"`
		CompletedAt string `json:"completed_at"`
		Lifecycle   string `json:"lifecycle"`
		Forecast    *struct {
			ForecastRef string `json:"forecast_ref"`
		} `json:"forecast"`
	}
	if json.Unmarshal(addition.Record, &record) != nil {
		return false
	}
	if addition.Target == syncTargetRootForecast {
		if !validRef(record.ForecastRef, "forecasts.yaml") {
			return false
		}
		src := forecasts.Records[sourceID(record.ForecastRef, "forecasts.yaml")]
		if textField(src, "status") != "active" || textField(src, "kind") != "root" {
			return false
		}
		found := false
		for _, work := range ledger.Records {
			if work.Type == "work" && hasRole(work.Data.Roles, reportingRoleRoot) && openWork(work.Data.State) && string(work.Data.ForecastRef) == record.ForecastRef {
				if !outcomeCorresponds(work, ledger.Records, record.Outcome) {
					return false
				}
				found = true
			}
		}
		return found
	}
	if !validRef(record.WorkRef, "project-understanding.yaml") {
		return false
	}
	work, ok := ledger.Records[sourceID(record.WorkRef, "project-understanding.yaml")]
	if !ok || work.Type != "work" || !outcomeCorresponds(work, ledger.Records, record.Outcome) {
		return false
	}
	if addition.Target == syncTargetRootCompletion {
		if strings.TrimSpace(addition.Evidence) == "" {
			return false
		}
		if !hasRole(work.Data.Roles, reportingRoleRoot) || work.Data.State != workStateCompleted || !sameValue(work.Data.CompletedAt, record.CompletedAt) {
			return false
		}
		if work.Data.ForecastRef == "" {
			return true
		}
		ref := string(work.Data.ForecastRef)
		if !validRef(ref, "forecasts.yaml") {
			return false
		}
		src := forecasts.Records[sourceID(ref, "forecasts.yaml")]
		return textField(src, "status") == "inactive" && textField(src, "kind") == "root"
	}
	if !hasRole(work.Data.Roles, reportingRoleLane) {
		return false
	}
	if openWork(work.Data.State) {
		if record.Forecast == nil || string(work.Data.ForecastRef) != record.Forecast.ForecastRef || !validRef(record.Forecast.ForecastRef, "forecasts.yaml") {
			return false
		}
		src := forecasts.Records[sourceID(record.Forecast.ForecastRef, "forecasts.yaml")]
		return textField(src, "status") == "active" && textField(src, "kind") == "lane"
	}
	if record.Forecast != nil {
		return false
	}
	if strings.TrimSpace(addition.Evidence) == "" {
		return false
	}
	if work.Data.ForecastRef != "" {
		ref := string(work.Data.ForecastRef)
		if !validRef(ref, "forecasts.yaml") {
			return false
		}
		src := forecasts.Records[sourceID(ref, "forecasts.yaml")]
		if textField(src, "status") != "inactive" || textField(src, "kind") != "lane" {
			return false
		}
	}
	if work.Data.State == workStateCompleted {
		return sameValue(work.Data.CompletedAt, record.CompletedAt)
	}
	return work.Data.State == workStateCancelled && record.Lifecycle == "cancelled"
}
