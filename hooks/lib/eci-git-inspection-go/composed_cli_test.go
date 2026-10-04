package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestStageQueryPreservesOutputPrefix checks the production query.
//
// Example: unknown trailing options retain earlier callbacks.
func TestStageQueryPreservesOutputPrefix(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI(strings.NewReader(`{"query":"offline-program","arguments":["diff","--output=report","--unknown"]}`), &out); err != nil {
		t.Fatal(err)
	}
	var r struct {
		Outputs  []string `json:"outputs"`
		Complete bool     `json:"complete"`
	}
	if err := json.Unmarshal(out.Bytes(), &r); err != nil {
		t.Fatal(err)
	}
	if len(r.Outputs) != 1 || r.Outputs[0] != "report" || r.Complete {
		t.Fatalf("retained prefix missing: %s", out.Bytes())
	}
}

// TestComposedFreshnessPreservesHelper checks independent snapshot dependencies.
//
// Example: an advisory output retains a fresh helper until its null alias changes.
func TestComposedFreshnessPreservesHelper(t *testing.T) {
	base := t.TempDir()
	alias := filepath.Join(base, "null-alias")
	if err := os.Symlink("/dev/null", alias); err != nil {
		t.Fatal(err)
	}
	physical, ids, ok := originalContext(base, nil)
	if !ok {
		t.Fatal("context unresolved")
	}
	c := InspectionContext{Base: base, CWD: physical, DirectoryIdentities: ids, Certainty: SnapshotAvailabilitySnapshot}
	d := outputDestination("null-alias", c)
	if d.Decision != OutputIntentHarmlessEndpoint {
		t.Fatalf("null unresolved: %+v", d)
	}
	r := InspectionRecord{Query: "consume-inspection", Schema: "git-inspection-output-v1", Repository: base, Decision: InspectionDecisionAdvisory, Helper: &HelperRecord{Observation: Observation{Result: Helper, Target: "/bin/cat", Reason: "checked helper"}, Context: c, Destinations: []OutputDestination{d}, Remediation: "git diff --no-textconv"}}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if finding := consumeInspection(data); finding.Helper == nil || finding.Effect != "" {
		t.Fatalf("helper lost: %+v", finding)
	}
	if err := os.Remove(alias); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(base, alias); err != nil {
		t.Fatal(err)
	}
	if finding := consumeInspection(data); finding.Helper != nil {
		t.Fatalf("stale helper retained: %+v", finding)
	}
}

// TestClosedComposedQueries checks malformed transport and unknown typed states.
//
// Example: an unknown intent or field cannot promote an output finding.
func TestClosedComposedQueries(t *testing.T) {
	for _, input := range []string{`{"query":"consume-inspection","schema":"git-inspection-output-v1","decision":"OutputWrite"}`, `{"query":"consume-inspection","schema":"git-inspection-output-v1","extra":true}`, `{"query":"helper","known":true,"base":"/","directories":[],"outputs":[],"extra":true}`} {
		var out bytes.Buffer
		err := runCLI(strings.NewReader(input), &out)
		expectedError := strings.Contains(input, `"query":"helper"`)
		if (err != nil) != expectedError {
			t.Fatalf("closed query error: %v, want error=%v", err, expectedError)
		}
		if strings.Contains(out.String(), `"effect"`) || strings.Contains(out.String(), `"Helper"`) {
			t.Fatalf("malformed promoted: %s", out.String())
		}
	}
}

// TestComposedQueryNativePair verifies the existing observer and original endpoint together.
//
// Example: a null output retains textconv evidence without entering the helper.
func TestComposedQueryNativePair(t *testing.T) {
	in, _, marker := fixture(t)
	args := []string{"log", "--textconv", "-p", "-1", "--output=/dev/null"}
	q := DestinationQuery{Query: "helper", Base: in.CWD, Known: true, Environment: in.Environment, Arguments: args, Outputs: []string{"/dev/null"}, Spans: [][]int{{4, 0}}}
	data, err := json.Marshal(q)
	if err != nil {
		t.Fatal(err)
	}
	response, err := queryHelper(data)
	if err != nil {
		t.Fatal(err)
	}
	var h HelperRecord
	if err := json.Unmarshal(response, &h); err != nil {
		t.Fatal(err)
	}
	if h.Observation.Result != Helper {
		t.Fatalf("null helper lost: %s", response)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("observer entered helper: %v", err)
	}
	runFixture(t, in, args...)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("native helper absent: %v", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	q.Query = "destinations"
	q.Arguments = []string{"diff", "--output=report"}
	q.Outputs = []string{"report"}
	q.Spans = [][]int{{1, 0}}
	data, err = json.Marshal(q)
	if err != nil {
		t.Fatal(err)
	}
	response, err = queryDestinations(data)
	if err != nil {
		t.Fatal(err)
	}
	var mapped struct {
		Context      InspectionContext   `json:"context"`
		Destinations []OutputDestination `json:"destinations"`
	}
	if err := json.Unmarshal(response, &mapped); err != nil {
		t.Fatal(err)
	}
	if len(mapped.Destinations) != 1 || mapped.Destinations[0].Decision != OutputIntentAccessCheckedOutputIntent {
		t.Fatalf("new report not checked: %s", response)
	}
	mapped.Destinations[0].Reach = CallbackEvidenceSourceModeled
	r := InspectionRecord{Query: "consume-inspection", Schema: "git-inspection-output-v1", Reason: "complete modeled callback", Repository: in.CWD, Context: mapped.Context, Destinations: mapped.Destinations, Complete: true, Decision: InspectionDecisionDenyAccessCheckedOutputIntent, StdoutArgv: []string{"git", "--no-pager", "-C", mapped.Context.CWD, "-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv"}}
	data, err = json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := runCLI(bytes.NewReader(data), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "explicit-access-checked-git-output-intent") {
		t.Fatalf("query envelope lost callback: %s contextfresh=%v bounded=%v endpointfresh=%v record=%s", out.String(), contextFresh(mapped.Context), boundedInspectionContext(mapped.Context), endpointFresh(mapped.Destinations[0], mapped.Context), data)
	}
	if _, err := os.Stat(filepath.Join(in.CWD, "report")); !os.IsNotExist(err) {
		t.Fatalf("query wrote original: %v", err)
	}
	runFixture(t, in, "diff", "--no-textconv", "--output=report")
	if _, err := os.Stat(filepath.Join(in.CWD, "report")); err != nil {
		t.Fatalf("native report absent: %v", err)
	}
}

// TestOutputAccessAndEarlierDependency checks both failed access and stale prefix endpoints.
//
// Example: a nonwritable first report prevents a later output intent finding.
func TestOutputAccessAndEarlierDependency(t *testing.T) {
	base := t.TempDir()
	physical, ids, ok := originalContext(base, nil)
	if !ok {
		t.Fatal("context unresolved")
	}
	c := InspectionContext{Base: base, CWD: physical, DirectoryIdentities: ids, Certainty: SnapshotAvailabilitySnapshot}
	first := filepath.Join(physical, "first")
	if err := os.WriteFile(first, []byte("original"), 0400); err != nil {
		t.Fatal(err)
	}
	d := outputDestination("first", c)
	if d.Decision == OutputIntentAccessCheckedOutputIntent {
		t.Fatal("readonly regular promoted")
	}
	if err := os.Chmod(first, 0600); err != nil {
		t.Fatal(err)
	}
	d = outputDestination("first", c)
	if d.Decision != OutputIntentAccessCheckedOutputIntent {
		t.Fatalf("writable regular advisory: %+v", d)
	}
	if err := os.Chmod(first, 0400); err != nil {
		t.Fatal(err)
	}
	if endpointFresh(d, c) {
		t.Fatal("stale access accepted")
	}
	parent := filepath.Join(physical, "reports")
	if err := os.Mkdir(parent, 0500); err != nil {
		t.Fatal(err)
	}
	if d := outputDestination("reports/new", c); d.Decision == OutputIntentAccessCheckedOutputIntent {
		t.Fatal("nonwritable parent promoted")
	}
	if err := os.Chmod(parent, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(physical, "early")
	if err := os.Symlink("/dev/null", alias); err != nil {
		t.Fatal(err)
	}
	prefix := outputDestination("early", c)
	later := outputDestination("reports/new", c)
	later.Ordinal = 1
	later.Reach = CallbackEvidenceSourceModeled
	r := InspectionRecord{Schema: "git-inspection-output-v1", Context: c, Complete: true, Decision: InspectionDecisionDenyAccessCheckedOutputIntent, Destinations: []OutputDestination{prefix, later}, StdoutArgv: []string{"git", "--no-pager", "-C", physical, "-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv"}}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if got := consumeInspection(data); got.Target != later.Target {
		t.Fatalf("fresh prefix lost: %+v", got)
	}
	if err := os.Remove(alias); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(parent, alias); err != nil {
		t.Fatal(err)
	}
	if got := consumeInspection(data); got.Effect != "" {
		t.Fatalf("stale earlier endpoint accepted: %+v", got)
	}
}

// TestStageCountAndPathBounds retains the supported prefix without certifying an unknown tail.
//
// Example: a 65th callback keeps 64 earlier destinations and disables complete denial.
func TestStageCountAndPathBounds(t *testing.T) {
	args := []string{"diff"}
	for n := 0; n < inspectionDestinationLimit+1; n++ {
		args = append(args, "--output=/dev/null")
	}
	got := OfflineAnalyze(args)
	if got.Complete || len(got.Outputs) != inspectionDestinationLimit {
		t.Fatalf("count bound lost prefix: %+v", got)
	}
	got = OfflineAnalyze([]string{"diff", "--output=first", "--output=" + strings.Repeat("a", inspectionPathLimit+1)})
	if got.Complete || len(got.Outputs) != 1 || got.Outputs[0] != "first" {
		t.Fatalf("path bound lost prefix: %+v", got)
	}
}

// TestOriginalDirectoryAliasFreshness rechecks raw base and ordered directory operands.
//
// Example: retargeting a -C alias invalidates a record for the former physical directory.
func TestOriginalDirectoryAliasFreshness(t *testing.T) {
	base := t.TempDir()
	a := filepath.Join(base, "a")
	b := filepath.Join(base, "b")
	alias := filepath.Join(base, "alias")
	for _, path := range []string{a, b} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	sentinel := filepath.Join(a, "report")
	if err := os.WriteFile(sentinel, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, rawBase := range []bool{true, false} {
		if err := os.Symlink(a, alias); err != nil {
			t.Fatal(err)
		}
		origin := alias
		var dirs []*string
		if !rawBase {
			origin = base
			operand := "alias"
			dirs = []*string{&operand}
		}
		physical, ids, ok := originalContext(origin, dirs)
		if !ok {
			t.Fatal("fresh raw context unresolved")
		}
		c := InspectionContext{Base: origin, Directories: dirs, CWD: physical, DirectoryIdentities: ids, Certainty: SnapshotAvailabilitySnapshot}
		if !contextFresh(c) {
			t.Fatal("fresh original chain rejected")
		}
		d := outputDestination("report", c)
		if d.Decision != OutputIntentAccessCheckedOutputIntent {
			t.Fatal("fresh destination advisory")
		}
		if err := os.Remove(alias); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(b, alias); err != nil {
			t.Fatal(err)
		}
		if contextFresh(c) {
			t.Fatal("retargeted original chain accepted")
		}
		data, err := os.ReadFile(sentinel)
		if err != nil || string(data) != "preserved" {
			t.Fatalf("former destination changed: %q %v", data, err)
		}
		if err := os.Remove(alias); err != nil {
			t.Fatal(err)
		}
	}
}

// TestOriginalContextPathDepth bounds raw base and directory operands independently.
//
// Example: a long dot-component chain cannot enter the fresh intent domain.
func TestOriginalContextPathDepth(t *testing.T) {
	base := t.TempDir()
	raw := strings.Repeat("./", inspectionPathDepthLimit)
	if _, _, ok := originalContext(base+"/"+raw, nil); ok {
		t.Fatal("overdepth raw base accepted")
	}
	if _, _, ok := originalContext(base, []*string{&raw}); ok {
		t.Fatal("overdepth raw directory accepted")
	}
	if _, _, ok := originalContext(base, nil); !ok {
		t.Fatal("ordinary raw base rejected")
	}
}
