package main

import (
	"bytes"
	"encoding/csv"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestRunFourObservationRootOneReportsDivergence verifies the live four-point
// root-1 shape is summarized from its remaining horizons, not raw deadlines.
//
// Example: the fourth target update keeps root 1 divergent at low consistency.
func TestRunFourObservationRootOneReportsDivergence(t *testing.T) {
	t.Parallel()

	path := writeHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T07:44:42Z\t1\t2026-09-01T11:15Z\tfirst extension\n"+
		"2026-09-01T09:20:54Z\t1\t2026-09-01T12:30Z\treview needs more time\n"+
		"2026-09-01T09:48:12Z\t1\t2026-09-01T14:00Z\ttimeout repair\n"+
		"2026-09-01T10:33:49Z\t1\t2026-09-01T17:30Z\tfourth extension\n")

	var stdout bytes.Buffer
	if err := run([]string{path}, &stdout); err != nil {
		t.Fatalf("run() error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if got, want := len(lines), 2; got != want {
		t.Fatalf("output line count = %d, want %d: %q", got, want, stdout.String())
	}
	if got, want := lines[0], outputHeader; got != want {
		t.Fatalf("header = %q, want %q", got, want)
	}

	fields := strings.Split(lines[1], "\t")
	if got, want := len(fields), 11; got != want {
		t.Fatalf("field count = %d, want %d: %q", got, want, lines[1])
	}
	wantFields := []string{"1", "4", "4", "divergent", "low", "12618", "24971", "12353"}
	for index, want := range wantFields {
		if got := fields[index]; got != want {
			t.Fatalf("field %d = %q, want %q", index, got, want)
		}
	}

	slope, err := strconv.ParseFloat(fields[8], 64)
	if err != nil {
		t.Fatalf("slope %q is not numeric: %v", fields[8], err)
	}
	if slope <= 0 {
		t.Fatalf("slope = %v, want positive", slope)
	}

	rSquared, err := strconv.ParseFloat(fields[9], 64)
	if err != nil {
		t.Fatalf("R² %q is not numeric: %v", fields[9], err)
	}
	if math.IsNaN(rSquared) || rSquared < 0 || rSquared > 1 {
		t.Fatalf("R² = %v, want [0, 1]", rSquared)
	}
	agreement, err := strconv.ParseFloat(fields[10], 64)
	if err != nil {
		t.Fatalf("directional agreement %q is not numeric: %v", fields[10], err)
	}
	if agreement <= 0 || agreement >= 100 {
		t.Fatalf("directional agreement = %v, want partial positive agreement", agreement)
	}
}

// TestRunAcceptsQuotedReasonWithTab verifies a tab in a quoted reason stays
// in the fourth TSV field rather than being mistaken for another column.
//
// Example: a human-readable reason can quote a tab-separated phrase.
func TestRunAcceptsQuotedReasonWithTab(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T07:44Z\tquoted\t2026-09-01T11:15Z\t\"review\tneeds more time\"\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	if got, want := rows[0][0:5], []string{"quoted", "1", "1", "indeterminate", "insufficient"}; !sameFields(got, want) {
		t.Fatalf("quoted-reason row prefix = %q, want %q", got, want)
	}
}

// TestRunKeepsQuotedTabBearingRootMachineReadable verifies accepted root IDs
// remain one output field when they contain a quoted tab character.
//
// Example: a TSV consumer reads a tab-bearing root ID without extra columns.
func TestRunKeepsQuotedTabBearingRootMachineReadable(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T07:44Z\t\"root\twith tab\"\t2026-09-01T11:15Z\treason\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	if got, want := rows[0][0], "root\twith tab"; got != want {
		t.Fatalf("root task ID = %q, want %q", got, want)
	}
}

// TestRunReportsLineSpecificInputDiagnostics verifies malformed TSV data is
// identified at the source line without accepting a partial analysis.
//
// Example: a non-UTC timestamp identifies its data line and field.
func TestRunReportsLineSpecificInputDiagnostics(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name    string
		content string
		want    string
	}{
		{
			name:    "header",
			content: "added_utc\troot_task_id\tnew_target_utc\n",
			want:    "line 1: expected header \"added_utc\\troot_task_id\\tnew_target_utc\\treason\"",
		},
		{
			name: "field count",
			content: "added_utc\troot_task_id\tnew_target_utc\treason\n" +
				"2026-09-01T07:44Z\t1\t2026-09-01T11:15Z\n",
			want: "line 2: expected 4 tab-separated fields, got 3",
		},
		{
			name: "blank root",
			content: "added_utc\troot_task_id\tnew_target_utc\treason\n" +
				"2026-09-01T07:44Z\t\t2026-09-01T11:15Z\treason\n",
			want: "line 2: root_task_id must not be blank",
		},
		{
			name: "blank reason",
			content: "added_utc\troot_task_id\tnew_target_utc\treason\n" +
				"2026-09-01T07:44Z\t1\t2026-09-01T11:15Z\t\n",
			want: "line 2: reason must not be blank",
		},
		{
			name: "non UTC timestamp",
			content: "added_utc\troot_task_id\tnew_target_utc\treason\n" +
				"2026-09-01T07:44:00+01:00\t1\t2026-09-01T11:15Z\treason\n",
			want: "line 2: added_utc must be a UTC Z timestamp",
		},
		{
			name: "malformed quoted reason",
			content: "added_utc\troot_task_id\tnew_target_utc\treason\n" +
				"2026-09-01T07:44Z\t1\t2026-09-01T11:15Z\t\"unterminated\n",
			want: "line 2: malformed TSV:",
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name,
			// Isolate each malformed source form and its expected line diagnostic.
			func(t *testing.T) {
				path := writeHistory(t, testCase.content)
				var stdout bytes.Buffer
				err := run([]string{path}, &stdout)
				if err == nil {
					t.Fatal("run() error = nil, want malformed input error")
				}
				if !strings.Contains(err.Error(), testCase.want) {
					t.Fatalf("run() error = %q, want substring %q", err, testCase.want)
				}
				if got := stdout.String(); got != "" {
					t.Fatalf("stdout = %q, want no partial analysis", got)
				}
			},
		)
	}
}

// TestRunReportsIndeterminateForOneObservationTime verifies repeated source
// timestamps do not invent a slope or a confidence level.
//
// Example: two observations recorded at one instant are indeterminate.
func TestRunReportsIndeterminateForOneObservationTime(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T07:44Z\troot\t2026-09-01T11:15Z\tfirst\n"+
		"2026-09-01T07:44Z\troot\t2026-09-01T12:15Z\tsecond\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	want := []string{"root", "2", "1", "indeterminate", "insufficient", "12660", "16260", "3600", "NA", "NA", "NA"}
	if got := rows[0]; !sameFields(got, want) {
		t.Fatalf("row = %q, want %q", got, want)
	}
}

// TestRunReportsStableConstantHorizons verifies constant remaining horizons
// are stable and receive complete directional agreement.
//
// Example: each observation keeps two hours remaining.
func TestRunReportsStableConstantHorizons(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T00:00Z\tstable\t2026-09-01T02:00Z\tfirst\n"+
		"2026-09-01T01:00Z\tstable\t2026-09-01T03:00Z\tsecond\n"+
		"2026-09-01T02:00Z\tstable\t2026-09-01T04:00Z\tthird\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	want := []string{"stable", "3", "3", "stable", "low", "7200", "7200", "0", "0", "1", "100"}
	if got := rows[0]; !sameFields(got, want) {
		t.Fatalf("row = %q, want %q", got, want)
	}
}

// TestRunReportsHighConsistencyConvergence verifies six linear horizon
// reductions receive the high descriptive-consistency label.
//
// Example: every elapsed hour reduces the remaining horizon by ten minutes.
func TestRunReportsHighConsistencyConvergence(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T00:00Z\tconvergent\t2026-09-01T02:00Z\tfirst\n"+
		"2026-09-01T01:00Z\tconvergent\t2026-09-01T02:50Z\tsecond\n"+
		"2026-09-01T02:00Z\tconvergent\t2026-09-01T03:40Z\tthird\n"+
		"2026-09-01T03:00Z\tconvergent\t2026-09-01T04:30Z\tfourth\n"+
		"2026-09-01T04:00Z\tconvergent\t2026-09-01T05:20Z\tfifth\n"+
		"2026-09-01T05:00Z\tconvergent\t2026-09-01T06:10Z\tsixth\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	want := []string{"convergent", "6", "6", "convergent", "high", "7200", "4200", "-3000", "-600", "1", "100"}
	if got := rows[0]; !sameFields(got, want) {
		t.Fatalf("row = %q, want %q", got, want)
	}
}

// TestRunSortsRootsAndObservations verifies output has lexical roots and each
// root's first/last values use chronological rather than input order.
//
// Example: an out-of-order root observation is sorted before analysis.
func TestRunSortsRootsAndObservations(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T02:00Z\ta\t2026-09-01T04:00Z\tlater\n"+
		"2026-09-01T00:00Z\tz\t2026-09-01T01:00Z\tonly\n"+
		"2026-09-01T00:00Z\ta\t2026-09-01T01:00Z\tearly\n"+
		"2026-09-01T01:00Z\ta\t2026-09-01T02:30Z\tmiddle\n"))
	if got, want := len(rows), 2; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	if got, want := rows[0][0], "a"; got != want {
		t.Fatalf("first root = %q, want %q", got, want)
	}
	if got, want := rows[0][5:8], []string{"3600", "7200", "3600"}; !sameFields(got, want) {
		t.Fatalf("root a horizons = %q, want %q", got, want)
	}
	if got, want := rows[1][0], "z"; got != want {
		t.Fatalf("second root = %q, want %q", got, want)
	}
	if got, want := rows[1][3:5], []string{"indeterminate", "insufficient"}; !sameFields(got, want) {
		t.Fatalf("root z classification = %q, want %q", got, want)
	}
}

// TestRunAcceptsRFC3339UTCForms verifies second and fractional-second UTC Z
// timestamps are accepted alongside minute precision.
//
// Example: a history may record a precise target revision time.
func TestRunAcceptsRFC3339UTCForms(t *testing.T) {
	t.Parallel()

	rows := outputDataRows(t, runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n"+
		"2026-09-01T00:00:00Z\trfc\t2026-09-01T01:00:00Z\tseconds\n"+
		"2026-09-01T01:00:00.123456789Z\trfc\t2026-09-01T02:00:00.123456789Z\tnanoseconds\n"))
	if got, want := len(rows), 1; got != want {
		t.Fatalf("row count = %d, want %d", got, want)
	}
	if got, want := rows[0][0:5], []string{"rfc", "2", "2", "stable", "insufficient"}; !sameFields(got, want) {
		t.Fatalf("RFC row prefix = %q, want %q", got, want)
	}
}

// TestRunPrintsHeaderOnlyForEmptyHistory verifies an empty body remains a
// valid strictly TSV report containing only its schema header.
//
// Example: a newly created history has only its schema header.
func TestRunPrintsHeaderOnlyForEmptyHistory(t *testing.T) {
	t.Parallel()

	output := runHistory(t, "added_utc\troot_task_id\tnew_target_utc\treason\n")
	want := outputHeader + "\n"
	if output != want {
		t.Fatalf("output = %q, want %q", output, want)
	}
}

// TestRunHelpDescribesAnalysis verifies the CLI help names its positional
// input and warns that the result is not a completion prediction.
//
// Example: a user can run forecast-target-trend --help before supplying TSV.
func TestRunHelpDescribesAnalysis(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	if err := run([]string{"--help"}, &stdout); err != nil {
		t.Fatalf("run(--help) error = %v", err)
	}
	if got := stdout.String(); !strings.Contains(got, "forecast-target-trend <path>") || !strings.Contains(got, "not a completion prediction") {
		t.Fatalf("help = %q, want usage and descriptive warning", got)
	}
}

// writeHistory writes one temporary history fixture and returns its path.
//
// Example: a test passes a TSV string to create an isolated CLI input.
func writeHistory(t *testing.T, content string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "forecast-target-history.tsv")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	return path
}

// runHistory executes the CLI against one fixture and returns its stdout.
//
// Example: a table-driven test passes a complete TSV body for analysis.
func runHistory(t *testing.T, content string) string {
	t.Helper()

	path := writeHistory(t, content)
	var stdout bytes.Buffer
	if err := run([]string{path}, &stdout); err != nil {
		t.Fatalf("run() error = %v", err)
	}

	return stdout.String()
}

// outputDataRows validates the TSV schema header and returns parsed data rows.
//
// Example: tests compare each root row as a fixed slice of TSV output fields.
func outputDataRows(t *testing.T, output string) [][]string {
	t.Helper()

	reader := csv.NewReader(strings.NewReader(output))
	reader.Comma = '\t'
	reader.FieldsPerRecord = 11

	header, err := reader.Read()
	if err != nil {
		t.Fatalf("read output header: %v; output = %q", err, output)
	}
	if got, want := strings.Join(header, "\t"), outputHeader; got != want {
		t.Fatalf("header = %q, want %q", got, want)
	}

	rows := make([][]string, 0)
	for {
		row, readErr := reader.Read()
		switch {
		case readErr == io.EOF:
			return rows
		case readErr != nil:
			t.Fatalf("read output row: %v; output = %q", readErr, output)
		default:
			rows = append(rows, row)
		}
	}
}

// sameFields reports whether two ordered field sequences contain identical
// values at every position.
//
// Example: a test compares one complete TSV row with its expected fields.
func sameFields(got []string, want []string) bool {
	if len(got) != len(want) {
		return false
	}

	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}

	return true
}
