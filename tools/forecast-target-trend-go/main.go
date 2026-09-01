// Command forecast-target-trend describes how the remaining target horizon
// changed across recorded target-date observations.
//
// Example: forecast-target-trend forecast-target-history.tsv
package main

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// commandName is the human-facing executable name shown in usage text.
	//
	// Example: commandName appears in the --help usage line.
	commandName = "forecast-target-trend"

	// inputHeader is the exact four-column TSV schema accepted by the tool.
	//
	// Example: the first line is added_utc, root_task_id, new_target_utc, reason.
	inputHeader = "added_utc\troot_task_id\tnew_target_utc\treason"

	// outputHeader names the TSV columns emitted for every root task.
	//
	// Example: root_task_id is followed by sample and trend measurements.
	outputHeader = "root_task_id\tsamples\tdistinct_observation_times\ttrend\tdescriptive_consistency\tfirst_horizon_seconds\tlast_horizon_seconds\tchange_horizon_seconds\tslope_horizon_seconds_per_elapsed_hour\tintercept_model_r_squared\tdirectional_agreement_percent"

	// minuteUTCLayout parses the minute-precision UTC Z timestamps used by
	// existing target-history records.
	//
	// Example: 2026-09-01T07:44Z uses this layout.
	minuteUTCLayout = "2006-01-02T15:04Z"

	// trendEpsilon classifies only numerically negligible regression slopes or
	// horizon changes as stable.
	//
	// Example: a slope whose absolute value is at most trendEpsilon is stable.
	trendEpsilon = 1e-9

	// secondsPerHour converts regression elapsed-hour units to horizon seconds.
	//
	// Example: one hour is 3600 horizon seconds.
	secondsPerHour = 60 * 60
)

// trendName is the direction of the observed remaining-horizon regression.
//
// Example: trendDivergent means remaining time grows as observations advance.
type trendName string

const (
	// trendIndeterminate denotes fewer than two distinct observation times.
	//
	// Example: duplicate timestamps cannot define a regression slope.
	trendIndeterminate trendName = "indeterminate"

	// trendDivergent denotes a positive remaining-horizon regression slope.
	//
	// Example: later observations leave more time until their targets.
	trendDivergent trendName = "divergent"

	// trendConvergent denotes a negative remaining-horizon regression slope.
	//
	// Example: later observations leave less time until their targets.
	trendConvergent trendName = "convergent"

	// trendStable denotes a negligible remaining-horizon regression slope.
	//
	// Example: every observation keeps roughly the same time remaining.
	trendStable trendName = "stable"
)

// consistencyName qualifies how consistently this history supports its
// descriptive direction; it is never a future-completion prediction.
//
// Example: consistencyHigh needs enough observations, fit, and agreement.
type consistencyName string

const (
	// consistencyInsufficient denotes too little time variation for a useful
	// descriptive consistency classification.
	//
	// Example: two distinct observations remain insufficient.
	consistencyInsufficient consistencyName = "insufficient"

	// consistencyLow denotes a defined direction without stronger consistency.
	//
	// Example: three observations with a positive slope are low consistency.
	consistencyLow consistencyName = "low"

	// consistencyModerate denotes a reasonably fitted, mostly agreeing history.
	//
	// Example: four observations with R² at least 0.50 can be moderate.
	consistencyModerate consistencyName = "moderate"

	// consistencyHigh denotes a strongly fitted and directionally consistent
	// descriptive history.
	//
	// Example: six observations with R² at least 0.80 can be high.
	consistencyHigh consistencyName = "high"
)

// historyObservation is one validated source row paired with its computed
// remaining horizon at the observation instant.
//
// Example: target 14:00 observed at 09:48 has a 15120-second horizon.
type historyObservation struct {
	sourceLine     int
	addedUTC       time.Time
	rootTaskID     string
	horizonSeconds float64
}

// regressionSample is one root-local point whose x coordinate is elapsed
// hours since the root's first observation and y is remaining horizon seconds.
//
// Example: a one-hour-later record has x equal to 1.
type regressionSample struct {
	elapsedHours   float64
	horizonSeconds float64
}

// linearFit is the ordinary least-squares intercept model for one root's
// remaining-horizon history.
//
// Example: a constant horizon has slope 0 and R² 1.
type linearFit struct {
	defined  bool
	slope    float64
	rSquared float64
}

// rootReport is the complete descriptive summary emitted for one root task.
//
// Example: a report can be divergent with low descriptive consistency.
type rootReport struct {
	rootTaskID               string
	samples                  int
	distinctObservationTimes int
	trend                    trendName
	consistency              consistencyName
	firstHorizonSeconds      float64
	lastHorizonSeconds       float64
	changeHorizonSeconds     float64
	fit                      linearFit
	directionalAgreement     float64
	agreementDefined         bool
}

// main executes the CLI and renders user-facing errors to standard error.
//
// Example: invoking the compiled binary with one TSV path returns a report.
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		if _, writeErr := fmt.Fprintln(os.Stderr, err); writeErr != nil {
			return
		}
		os.Exit(2)
	}
}

// run validates CLI arguments, reads one history TSV, and writes the
// descriptive report to stdout.
//
// Example: run([]string{"history.tsv"}, os.Stdout) analyzes one input file.
func run(args []string, stdout io.Writer) error {
	switch len(args) {
	case 0:
		return fmt.Errorf("usage: %s <path>; use --help for details", commandName)
	case 1:
		switch args[0] {
		case "--help", "-h":
			return writeHelp(stdout)
		default:
			observations, err := readHistory(args[0])
			if err != nil {
				return err
			}

			return writeReport(stdout, analyzeHistory(observations))
		}
	default:
		return fmt.Errorf("usage: %s <path>; expected exactly one history path", commandName)
	}
}

// writeHelp explains the single-file input and the strictly descriptive
// meaning of the result.
//
// Example: forecast-target-trend --help prints this text without reading TSV.
func writeHelp(stdout io.Writer) error {
	_, err := fmt.Fprintf(stdout, "Usage: %s <path>\n\nReads %s and summarizes remaining target horizons by root task.\nThe result is descriptive history, not a completion prediction.\n", commandName, inputHeader)
	if err != nil {
		return fmt.Errorf("write help: %w", err)
	}

	return nil
}

// readHistory reads the exact TSV schema with a CSV parser so quoted fields
// retain their content before any report is emitted.
//
// Example: a valid header with zero body rows returns an empty observation list.
func readHistory(path string) (observations []historyObservation, err error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open history %q: %w", path, err)
	}
	// Preserve a close failure only after all parsing otherwise succeeds.
	defer func() {
		if closeErr := file.Close(); err == nil && closeErr != nil {
			err = fmt.Errorf("close history %q: %w", path, closeErr)
		}
	}()

	reader := csv.NewReader(file)
	reader.Comma = '\t'
	reader.FieldsPerRecord = 4

	header, readErr := reader.Read()
	if readErr != nil {
		return nil, fmt.Errorf("line 1: expected header %q", inputHeader)
	}
	if strings.Join(header, "\t") != inputHeader {
		return nil, fmt.Errorf("line 1: expected header %q", inputHeader)
	}

	observations = make([]historyObservation, 0)
	for {
		fields, readErr := reader.Read()
		switch {
		case errors.Is(readErr, io.EOF):
			return observations, nil
		case readErr != nil:
			return nil, formatHistoryReadError(reader, fields, readErr)
		default:
			lineNumber := csvRecordLine(reader, fields, readErr, 1)
			observation, parseErr := parseHistoryRecord(lineNumber, fields)
			if parseErr != nil {
				return nil, parseErr
			}
			observations = append(observations, observation)
		}
	}
}

// formatHistoryReadError adds the source record line to a CSV reader failure
// while retaining a precise four-field diagnostic where possible.
//
// Example: an unquoted extra tab reports its source line and field count.
func formatHistoryReadError(reader *csv.Reader, fields []string, readErr error) error {
	lineNumber := csvRecordLine(reader, fields, readErr, 1)
	if errors.Is(readErr, csv.ErrFieldCount) {
		return fmt.Errorf("line %d: expected 4 tab-separated fields, got %d", lineNumber, len(fields))
	}

	var parseError *csv.ParseError
	if errors.As(readErr, &parseError) {
		return fmt.Errorf("line %d: malformed TSV: %v", csvParseErrorLine(parseError, lineNumber), parseError.Err)
	}

	return fmt.Errorf("line %d: read TSV: %w", lineNumber, readErr)
}

// csvRecordLine returns the source line for the most recently read record,
// preferring a parser's line data and then the first decoded field position.
//
// Example: a quoted multi-line reason still reports the record's first line.
func csvRecordLine(reader *csv.Reader, fields []string, readErr error, fallback int) int {
	var parseError *csv.ParseError
	if errors.As(readErr, &parseError) {
		return csvParseErrorLine(parseError, fallback)
	}
	if len(fields) > 0 {
		lineNumber, _ := reader.FieldPos(0)
		return lineNumber
	}

	return fallback
}

// csvParseErrorLine selects the record-start line when available, falling
// back to the parser's precise failure line and then a caller-provided line.
//
// Example: an unterminated quote reports where its logical record began.
func csvParseErrorLine(parseError *csv.ParseError, fallback int) int {
	switch {
	case parseError.StartLine > 0:
		return parseError.StartLine
	case parseError.Line > 0:
		return parseError.Line
	default:
		return fallback
	}
}

// parseHistoryRecord validates one four-field TSV record and derives its
// remaining horizon from target minus observation time.
//
// Example: a 14:00 target observed at 09:48 yields 15120 seconds.
func parseHistoryRecord(lineNumber int, fields []string) (historyObservation, error) {
	if strings.TrimSpace(fields[1]) == "" {
		return historyObservation{}, fmt.Errorf("line %d: root_task_id must not be blank", lineNumber)
	}
	if strings.TrimSpace(fields[3]) == "" {
		return historyObservation{}, fmt.Errorf("line %d: reason must not be blank", lineNumber)
	}

	addedUTC, err := parseUTCTimestamp(fields[0])
	if err != nil {
		return historyObservation{}, fmt.Errorf("line %d: added_utc must be a UTC Z timestamp: %q", lineNumber, fields[0])
	}
	newTargetUTC, err := parseUTCTimestamp(fields[2])
	if err != nil {
		return historyObservation{}, fmt.Errorf("line %d: new_target_utc must be a UTC Z timestamp: %q", lineNumber, fields[2])
	}

	return historyObservation{
		sourceLine:     lineNumber,
		addedUTC:       addedUTC,
		rootTaskID:     fields[1],
		horizonSeconds: newTargetUTC.Sub(addedUTC).Seconds(),
	}, nil
}

// parseUTCTimestamp accepts the documented minute, RFC3339, and RFC3339Nano
// forms only when they use the literal UTC Z suffix.
//
// Example: 2026-09-01T09:48Z and 2026-09-01T09:48:00.1Z are accepted.
func parseUTCTimestamp(value string) (time.Time, error) {
	if !strings.HasSuffix(value, "Z") {
		return time.Time{}, fmt.Errorf("timestamp lacks UTC Z suffix")
	}

	layouts := []string{minuteUTCLayout, time.RFC3339, time.RFC3339Nano}
	for _, layout := range layouts {
		parsed, err := time.Parse(layout, value)
		if err == nil && parsed.Location() == time.UTC {
			return parsed, nil
		}
	}

	return time.Time{}, fmt.Errorf("timestamp does not match an accepted UTC layout")
}

// analyzeHistory groups observations by root task, orders each root by source
// observation time, and emits roots in lexical order.
//
// Example: root a is reported before root z regardless of input row order.
func analyzeHistory(observations []historyObservation) []rootReport {
	byRoot := make(map[string][]historyObservation)
	for _, observation := range observations {
		byRoot[observation.rootTaskID] = append(byRoot[observation.rootTaskID], observation)
	}

	rootTaskIDs := make([]string, 0, len(byRoot))
	for rootTaskID := range byRoot {
		rootTaskIDs = append(rootTaskIDs, rootTaskID)
	}
	sort.Strings(rootTaskIDs)

	reports := make([]rootReport, 0, len(rootTaskIDs))
	for _, rootTaskID := range rootTaskIDs {
		rootObservations := byRoot[rootTaskID]
		sortHistoryObservations(rootObservations)
		reports = append(reports, analyzeRoot(rootObservations))
	}

	return reports
}

// sortHistoryObservations orders one root's records by added_utc and then by
// original source line to make tied timestamps deterministic.
//
// Example: two equal observation times retain their input-line ordering.
func sortHistoryObservations(observations []historyObservation) {
	sort.SliceStable(observations,
		// Compare timestamps before source lines because the regression x axis is time.
		func(leftIndex int, rightIndex int) bool {
			left := observations[leftIndex]
			right := observations[rightIndex]
			switch {
			case left.addedUTC.Before(right.addedUTC):
				return true
			case right.addedUTC.Before(left.addedUTC):
				return false
			default:
				return left.sourceLine < right.sourceLine
			}
		},
	)
}

// analyzeRoot calculates descriptive horizon measurements for one sorted root
// history without interpreting absolute target-date movement as the trend.
//
// Example: a later target can still converge when its remaining horizon shrinks.
func analyzeRoot(observations []historyObservation) rootReport {
	firstObservation := observations[0]
	samples := make([]regressionSample, 0, len(observations))
	for _, observation := range observations {
		elapsedHours := observation.addedUTC.Sub(firstObservation.addedUTC).Seconds() / secondsPerHour
		samples = append(samples, regressionSample{
			elapsedHours:   elapsedHours,
			horizonSeconds: observation.horizonSeconds,
		})
	}

	distinctObservationTimes := countDistinctObservationTimes(observations)
	fit := calculateLinearFit(samples, distinctObservationTimes)
	trend := classifyTrend(fit)
	agreement, agreementDefined := calculateDirectionalAgreement(observations, trend)

	return rootReport{
		rootTaskID:               firstObservation.rootTaskID,
		samples:                  len(observations),
		distinctObservationTimes: distinctObservationTimes,
		trend:                    trend,
		consistency:              classifyConsistency(distinctObservationTimes, trend, fit, agreement, agreementDefined),
		firstHorizonSeconds:      firstObservation.horizonSeconds,
		lastHorizonSeconds:       observations[len(observations)-1].horizonSeconds,
		changeHorizonSeconds:     observations[len(observations)-1].horizonSeconds - firstObservation.horizonSeconds,
		fit:                      fit,
		directionalAgreement:     agreement,
		agreementDefined:         agreementDefined,
	}
}

// countDistinctObservationTimes counts sorted unique added_utc instants for a
// root, rather than treating same-time source rows as regression x variation.
//
// Example: two tied rows and one later row have two distinct times.
func countDistinctObservationTimes(observations []historyObservation) int {
	if len(observations) == 0 {
		return 0
	}

	distinctTimes := 1
	previous := observations[0].addedUTC
	for _, observation := range observations[1:] {
		if observation.addedUTC.Equal(previous) {
			continue
		}
		distinctTimes++
		previous = observation.addedUTC
	}

	return distinctTimes
}

// calculateLinearFit calculates ordinary least squares with an intercept,
// defining R² as 1 for a constant horizon because the intercept model fits it.
//
// Example: six horizons falling by 600 seconds per hour yield slope -600.
func calculateLinearFit(samples []regressionSample, distinctObservationTimes int) linearFit {
	if distinctObservationTimes < 2 {
		return linearFit{}
	}

	var meanX float64
	var meanY float64
	for _, sample := range samples {
		meanX += sample.elapsedHours
		meanY += sample.horizonSeconds
	}
	meanX /= float64(len(samples))
	meanY /= float64(len(samples))

	var sumXX float64
	var sumXY float64
	for _, sample := range samples {
		deltaX := sample.elapsedHours - meanX
		deltaY := sample.horizonSeconds - meanY
		sumXX += deltaX * deltaX
		sumXY += deltaX * deltaY
	}
	if math.Abs(sumXX) <= trendEpsilon {
		return linearFit{}
	}

	slope := sumXY / sumXX
	intercept := meanY - slope*meanX
	var sumSquaredError float64
	var sumSquaredTotal float64
	for _, sample := range samples {
		residual := sample.horizonSeconds - (intercept + slope*sample.elapsedHours)
		deltaY := sample.horizonSeconds - meanY
		sumSquaredError += residual * residual
		sumSquaredTotal += deltaY * deltaY
	}

	rSquared := 1.0
	if sumSquaredTotal > trendEpsilon {
		rSquared = 1 - sumSquaredError/sumSquaredTotal
	}
	switch {
	case rSquared < 0 && rSquared > -trendEpsilon:
		rSquared = 0
	case rSquared > 1 && rSquared < 1+trendEpsilon:
		rSquared = 1
	}

	return linearFit{
		defined:  true,
		slope:    slope,
		rSquared: rSquared,
	}
}

// classifyTrend maps a defined regression slope to its remaining-horizon
// direction using a small numerical-stability threshold.
//
// Example: a positive slope means divergence even when dates themselves move forward.
func classifyTrend(fit linearFit) trendName {
	if !fit.defined {
		return trendIndeterminate
	}

	switch {
	case fit.slope > trendEpsilon:
		return trendDivergent
	case fit.slope < -trendEpsilon:
		return trendConvergent
	default:
		return trendStable
	}
}

// calculateDirectionalAgreement measures how adjacent positive-elapsed pairs
// match the root trend while ignoring tied observation times.
//
// Example: one positive and one negative horizon change agrees 50% with divergence.
func calculateDirectionalAgreement(observations []historyObservation, trend trendName) (float64, bool) {
	if trend == trendIndeterminate {
		return 0, false
	}

	consideredPairs := 0
	agreeingPairs := 0
	for index := 1; index < len(observations); index++ {
		previous := observations[index-1]
		current := observations[index]
		if !current.addedUTC.After(previous.addedUTC) {
			continue
		}

		consideredPairs++
		deltaHorizon := current.horizonSeconds - previous.horizonSeconds
		switch trend {
		case trendDivergent:
			if deltaHorizon > trendEpsilon {
				agreeingPairs++
			}
		case trendConvergent:
			if deltaHorizon < -trendEpsilon {
				agreeingPairs++
			}
		case trendStable:
			if math.Abs(deltaHorizon) <= trendEpsilon {
				agreeingPairs++
			}
		}
	}
	if consideredPairs == 0 {
		return 0, false
	}

	return 100 * float64(agreeingPairs) / float64(consideredPairs), true
}

// classifyConsistency labels only observed fit and directional agreement; it
// never estimates the chance that a task will complete by its target.
//
// Example: six well-fitted, agreeing observations are high consistency.
func classifyConsistency(
	distinctObservationTimes int,
	trend trendName,
	fit linearFit,
	directionalAgreement float64,
	agreementDefined bool,
) consistencyName {
	if distinctObservationTimes < 3 || trend == trendIndeterminate || !fit.defined || !agreementDefined {
		return consistencyInsufficient
	}

	switch {
	case distinctObservationTimes >= 6 && fit.rSquared >= 0.80 && directionalAgreement >= 90:
		return consistencyHigh
	case distinctObservationTimes >= 4 && fit.rSquared >= 0.50 && directionalAgreement >= 75:
		return consistencyModerate
	default:
		return consistencyLow
	}
}

// writeReport writes the strictly machine-readable TSV schema and one stable
// root row per calculated report.
//
// Example: an empty history writes only the schema header.
func writeReport(stdout io.Writer, reports []rootReport) error {
	writer := csv.NewWriter(stdout)
	writer.Comma = '\t'
	if err := writer.Write(strings.Split(outputHeader, "\t")); err != nil {
		return fmt.Errorf("write report header: %w", err)
	}

	for _, report := range reports {
		if err := writer.Write(report.outputFields()); err != nil {
			return fmt.Errorf("write report for root %q: %w", report.rootTaskID, err)
		}
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		return fmt.Errorf("flush report: %w", err)
	}

	return nil
}

// outputFields renders one report using the fixed TSV field order named by
// outputHeader.
//
// Example: an indeterminate report renders NA for undefined fit quantities.
func (report rootReport) outputFields() []string {
	slope := "NA"
	rSquared := "NA"
	if report.fit.defined {
		slope = formatNumber(report.fit.slope)
		rSquared = formatNumber(report.fit.rSquared)
	}

	agreement := "NA"
	if report.agreementDefined {
		agreement = formatNumber(report.directionalAgreement)
	}

	return []string{
		report.rootTaskID,
		strconv.Itoa(report.samples),
		strconv.Itoa(report.distinctObservationTimes),
		string(report.trend),
		string(report.consistency),
		formatNumber(report.firstHorizonSeconds),
		formatNumber(report.lastHorizonSeconds),
		formatNumber(report.changeHorizonSeconds),
		slope,
		rSquared,
		agreement,
	}
}

// formatNumber produces compact, deterministic non-exponent decimal output
// and normalizes tiny signed-zero artifacts to zero.
//
// Example: 7200.0 renders as 7200 and -0.0 renders as 0.
func formatNumber(value float64) string {
	if math.Abs(value) <= trendEpsilon {
		value = 0
	}

	return strconv.FormatFloat(value, 'f', -1, 64)
}
