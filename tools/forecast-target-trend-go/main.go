// Command forecast-target-trend describes how the remaining target horizon
// changed across recorded target-date observations.
//
// Example: forecast-target-trend forecast-target-history.tsv
package main

import (
	"bytes"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math/big"
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

	// rSquaredRoundingEpsilon bounds only floating-point overshoot while
	// normalizing R² to its mathematical interval from zero through one.
	//
	// Example: an R² of 1+1e-12 rounds back to 1.
	rSquaredRoundingEpsilon = 1e-9

	// secondsPerHour converts regression elapsed-hour units to horizon seconds.
	//
	// Example: one hour is 3600 horizon seconds.
	secondsPerHour = 60 * 60

	// nanosecondsPerSecond preserves the accepted RFC3339Nano precision in
	// exact horizon spans.
	//
	// Example: a two-nanosecond target extension has nanoseconds equal to 2.
	nanosecondsPerSecond = int64(time.Second)
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
	sourceLine int
	addedUTC   time.Time
	rootTaskID string
	horizon    exactSpan
}

// exactSpan stores a signed duration as whole seconds and a same-sign
// fractional nanosecond component without time.Duration's range limit.
//
// Example: negative two nanoseconds is seconds 0 and nanoseconds -2.
type exactSpan struct {
	seconds     int64
	nanoseconds int32
}

// regressionSample is one root-local point whose x coordinate is elapsed
// hours since the root's first observation and y is its horizon offset in
// seconds from that first observation.
//
// Example: a one-hour-later record has x equal to 1.
type regressionSample struct {
	elapsedHours   float64
	horizonSeconds float64
}

// exactRegressionSample retains the same x/y sample in exact nanosecond
// spans for direction classification independent of float64 precision.
//
// Example: a two-nanosecond horizon increase remains positive at any date.
type exactRegressionSample struct {
	elapsedSpan exactSpan
	horizonSpan exactSpan
}

// linearFit is the ordinary least-squares intercept model for one root's
// remaining-horizon-offset history.
//
// Example: a constant horizon has slope 0 and R² 1.
type linearFit struct {
	defined   bool
	slope     float64
	slopeSign int
	rSquared  float64
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
	firstHorizon             exactSpan
	lastHorizon              exactSpan
	changeHorizon            exactSpan
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

// readHistory validates physical blank records, then reads the exact TSV
// schema with a CSV parser so quoted fields retain their content.
//
// Example: a valid header with zero body rows returns an empty observation list.
func readHistory(path string) (observations []historyObservation, err error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("open history %q: %w", path, err)
	}
	if err := validateNoBlankPhysicalRecords(contents); err != nil {
		return nil, err
	}

	reader := csv.NewReader(bytes.NewReader(contents))
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

// validateNoBlankPhysicalRecords rejects empty source lines that csv.Reader
// intentionally skips, without interpreting the TSV fields itself.
//
// Example: a blank line between two records is rejected, while one inside a
// quoted multiline reason remains valid content for csv.Reader to parse.
func validateNoBlankPhysicalRecords(contents []byte) error {
	lineNumber := 1
	lineHasContent := false
	inQuotedField := false
	fieldStart := true

	for index := 0; index < len(contents); {
		current := contents[index]
		switch {
		case current == '\r' && index+1 < len(contents) && contents[index+1] == '\n':
			if !inQuotedField && !lineHasContent {
				return fmt.Errorf("line %d: blank TSV record is not permitted", lineNumber)
			}
			lineNumber++
			lineHasContent = false
			if !inQuotedField {
				fieldStart = true
			}
			index += 2
		case current == '\n':
			if !inQuotedField && !lineHasContent {
				return fmt.Errorf("line %d: blank TSV record is not permitted", lineNumber)
			}
			lineNumber++
			lineHasContent = false
			if !inQuotedField {
				fieldStart = true
			}
			index++
		case inQuotedField:
			lineHasContent = true
			if current == '"' {
				if index+1 < len(contents) && contents[index+1] == '"' {
					index += 2
					continue
				}
				inQuotedField = false
			}
			index++
		case current == '\t':
			lineHasContent = true
			fieldStart = true
			index++
		case current == '"' && fieldStart:
			lineHasContent = true
			fieldStart = false
			inQuotedField = true
			index++
		default:
			lineHasContent = true
			fieldStart = false
			index++
		}
	}

	return nil
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
		sourceLine: lineNumber,
		addedUTC:   addedUTC,
		rootTaskID: fields[1],
		horizon:    spanBetween(newTargetUTC, addedUTC),
	}, nil
}

// spanBetween calculates a UTC timestamp difference without converting it to
// time.Duration, whose representable range is much shorter than RFC3339.
//
// Example: year 9999 minus year 0001 remains roughly ten thousand years.
func spanBetween(later time.Time, earlier time.Time) exactSpan {
	seconds := later.Unix() - earlier.Unix()
	nanoseconds := int64(later.Nanosecond() - earlier.Nanosecond())

	return newExactSpan(seconds, nanoseconds)
}

// newExactSpan normalizes a signed seconds-plus-nanoseconds duration so both
// nonzero components carry the same sign.
//
// Example: one second minus 800 million nanoseconds becomes 0.2 seconds.
func newExactSpan(seconds int64, nanoseconds int64) exactSpan {
	seconds += nanoseconds / nanosecondsPerSecond
	nanoseconds %= nanosecondsPerSecond
	switch {
	case seconds > 0 && nanoseconds < 0:
		seconds--
		nanoseconds += nanosecondsPerSecond
	case seconds < 0 && nanoseconds > 0:
		seconds++
		nanoseconds -= nanosecondsPerSecond
	}

	return exactSpan{seconds: seconds, nanoseconds: int32(nanoseconds)}
}

// subtract returns the exact signed difference between two spans.
//
// Example: 2 nanoseconds minus 1 nanosecond returns 1 nanosecond.
func (span exactSpan) subtract(other exactSpan) exactSpan {
	return newExactSpan(span.seconds-other.seconds, int64(span.nanoseconds)-int64(other.nanoseconds))
}

// sign reports whether a span is negative, zero, or positive.
//
// Example: a two-nanosecond extension has a positive sign.
func (span exactSpan) sign() int {
	switch {
	case span.seconds > 0 || span.nanoseconds > 0:
		return 1
	case span.seconds < 0 || span.nanoseconds < 0:
		return -1
	default:
		return 0
	}
}

// float64Seconds converts a span to a floating approximation only after
// callers have first reduced it relative to a nearby exact baseline.
//
// Example: a two-nanosecond offset converts to 0.000000002.
func (span exactSpan) float64Seconds() float64 {
	return float64(span.seconds) + float64(span.nanoseconds)/float64(nanosecondsPerSecond)
}

// nanosecondsBig returns the exact signed span as a multi-precision count of
// nanoseconds for OLS direction calculations.
//
// Example: one whole second becomes 1000000000.
func (span exactSpan) nanosecondsBig() *big.Int {
	seconds := big.NewInt(span.seconds)
	seconds.Mul(seconds, big.NewInt(nanosecondsPerSecond))

	return seconds.Add(seconds, big.NewInt(int64(span.nanoseconds)))
}

// String renders a span in canonical decimal seconds without losing accepted
// RFC3339Nano precision.
//
// Example: negative two nanoseconds renders as -0.000000002.
func (span exactSpan) String() string {
	if span.nanoseconds == 0 {
		return strconv.FormatInt(span.seconds, 10)
	}

	negative := span.sign() < 0
	seconds := span.seconds
	nanoseconds := span.nanoseconds
	if negative {
		seconds = -seconds
		nanoseconds = -nanoseconds
	}
	fraction := strings.TrimRight(fmt.Sprintf("%09d", nanoseconds), "0")
	value := strconv.FormatInt(seconds, 10) + "." + fraction
	if negative {
		return "-" + value
	}

	return value
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
	exactSamples := make([]exactRegressionSample, 0, len(observations))
	for _, observation := range observations {
		elapsedSpan := spanBetween(observation.addedUTC, firstObservation.addedUTC)
		horizonSpan := observation.horizon.subtract(firstObservation.horizon)
		samples = append(samples, regressionSample{
			elapsedHours:   elapsedSpan.float64Seconds() / secondsPerHour,
			horizonSeconds: horizonSpan.float64Seconds(),
		})
		exactSamples = append(exactSamples, exactRegressionSample{
			elapsedSpan: elapsedSpan,
			horizonSpan: horizonSpan,
		})
	}

	distinctObservationTimes := countDistinctObservationTimes(observations)
	fit := calculateLinearFit(samples, distinctObservationTimes)
	if slope, slopeSign, defined := calculateExactSlope(exactSamples, distinctObservationTimes); defined {
		fit.defined = true
		fit.slope = slope
		fit.slopeSign = slopeSign
	}
	trend := classifyTrend(fit)
	agreement, agreementDefined := calculateDirectionalAgreement(observations, trend)

	return rootReport{
		rootTaskID:               firstObservation.rootTaskID,
		samples:                  len(observations),
		distinctObservationTimes: distinctObservationTimes,
		trend:                    trend,
		consistency:              classifyConsistency(distinctObservationTimes, trend, fit, agreement, agreementDefined),
		firstHorizon:             firstObservation.horizon,
		lastHorizon:              observations[len(observations)-1].horizon,
		changeHorizon:            observations[len(observations)-1].horizon.subtract(firstObservation.horizon),
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
	if sumXX == 0 {
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
	if sumSquaredTotal != 0 {
		rSquared = 1 - sumSquaredError/sumSquaredTotal
	}
	switch {
	case rSquared < 0 && rSquared > -rSquaredRoundingEpsilon:
		rSquared = 0
	case rSquared > 1 && rSquared < 1+rSquaredRoundingEpsilon:
		rSquared = 1
	}

	return linearFit{defined: true, slope: slope, slopeSign: floatSign(slope), rSquared: rSquared}
}

// calculateExactSlope returns the exact OLS slope direction and its floating
// presentation value by evaluating covariance and variance in nanoseconds
// with multi-precision integers.
//
// Example: a two-nanosecond later horizon over a later observation is positive.
func calculateExactSlope(samples []exactRegressionSample, distinctObservationTimes int) (float64, int, bool) {
	if distinctObservationTimes < 2 {
		return 0, 0, false
	}

	count := big.NewInt(int64(len(samples)))
	sumX := new(big.Int)
	sumY := new(big.Int)
	sumXY := new(big.Int)
	sumXX := new(big.Int)
	for _, sample := range samples {
		x := sample.elapsedSpan.nanosecondsBig()
		y := sample.horizonSpan.nanosecondsBig()
		sumX.Add(sumX, x)
		sumY.Add(sumY, y)
		sumXY.Add(sumXY, new(big.Int).Mul(x, y))
		sumXX.Add(sumXX, new(big.Int).Mul(x, x))
	}

	numerator := new(big.Int).Mul(count, sumXY)
	numerator.Sub(numerator, new(big.Int).Mul(sumX, sumY))
	denominator := new(big.Int).Mul(count, sumXX)
	denominator.Sub(denominator, new(big.Int).Mul(sumX, sumX))
	if denominator.Sign() == 0 {
		return 0, 0, false
	}

	slope := new(big.Rat).SetFrac(numerator, denominator)
	slope.Mul(slope, big.NewRat(secondsPerHour, 1))
	slopeValue, _ := slope.Float64()

	return slopeValue, numerator.Sign(), true
}

// floatSign returns the sign of a finite floating-point measurement.
//
// Example: a positive slope has sign 1.
func floatSign(value float64) int {
	switch {
	case value > 0:
		return 1
	case value < 0:
		return -1
	default:
		return 0
	}
}

// classifyTrend maps the exact regression-slope sign to its remaining-horizon
// direction without discarding an observed nonzero nanosecond-scale change.
//
// Example: a positive slope means divergence even when dates themselves move forward.
func classifyTrend(fit linearFit) trendName {
	if !fit.defined {
		return trendIndeterminate
	}

	switch fit.slopeSign {
	case 1:
		return trendDivergent
	case -1:
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
		deltaHorizonSign := current.horizon.subtract(previous.horizon).sign()
		switch trend {
		case trendDivergent:
			if deltaHorizonSign > 0 {
				agreeingPairs++
			}
		case trendConvergent:
			if deltaHorizonSign < 0 {
				agreeingPairs++
			}
		case trendStable:
			if deltaHorizonSign == 0 {
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
		report.firstHorizon.String(),
		report.lastHorizon.String(),
		report.changeHorizon.String(),
		slope,
		rSquared,
		agreement,
	}
}

// formatNumber produces compact, deterministic non-exponent decimal output
// and normalizes only signed-zero artifacts to zero.
//
// Example: 7200.0 renders as 7200, -0.0 renders as 0, and 1e-9 is retained.
func formatNumber(value float64) string {
	if value == 0 {
		value = 0
	}

	return strconv.FormatFloat(value, 'f', -1, 64)
}
