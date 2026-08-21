package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestClassifyFiniteCommandPlans(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name      string
		request   Request
		decision  DecisionKind
		code      DiagnosticCode
		segment   int
		predicate string
	}{
		{
			name:     "ordinary novel tool",
			request:  activeWorker("novel-tool --flag value"),
			decision: DecisionAllow,
		},
		{
			name:     "adb probe",
			request:  activeWorker("adb devices -l"),
			decision: DecisionAllow,
		},
		{
			name:     "quoted operator",
			request:  activeWorker("printf 'left && right'"),
			decision: DecisionAllow,
		},
		{
			name:     "literal environment wrapper",
			request:  activeWorker("env FOO=bar novel-tool --flag value"),
			decision: DecisionAllow,
		},
		{
			name:      "leading assignment",
			request:   activeWorker("FOO=bar novel-tool"),
			decision:  DecisionDeny,
			code:      CodePlanSyntaxDenied,
			segment:   1,
			predicate: "leading-assignment",
		},
		{
			name:      "redirection",
			request:   activeWorker("novel-tool > output.txt"),
			decision:  DecisionDeny,
			code:      CodePlanSyntaxDenied,
			segment:   1,
			predicate: "redirection",
		},
		{
			name:      "protected middle pipeline segment",
			request:   activeWorker("printf before | env | printf after"),
			decision:  DecisionDeny,
			code:      CodeEnvironmentEnumerationDenied,
			segment:   2,
			predicate: "environment-enumeration",
		},
		{
			name:      "wrapped git mutation",
			request:   activeWorker("timeout 5 git commit -m nope"),
			decision:  DecisionDeny,
			code:      CodeWorkerGitOwnershipDenied,
			segment:   1,
			predicate: "worker-git-ownership",
		},
		{
			name:     "git archive inspection",
			request:  activeWorker("git archive HEAD"),
			decision: DecisionAllow,
		},
		{
			name:      "environment name disclosure",
			request:   activeWorker("printenv OPENAI_API_KEY"),
			decision:  DecisionDeny,
			code:      CodeEnvironmentNameDenied,
			segment:   1,
			predicate: "environment-name-unregistered",
		},
		{
			name:      "worker lifecycle control",
			request:   activeWorker("eci-active status"),
			decision:  DecisionDeny,
			code:      CodeControlOwnerRequired,
			segment:   1,
			predicate: "worker-lifecycle-control",
		},
		{
			name:      "broad destruction",
			request:   activeWorker("rm -rf /"),
			decision:  DecisionDeny,
			code:      CodeBroadDestructiveDenied,
			segment:   1,
			predicate: "broad-destructive-root",
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			result := Classify(testCase.request)
			if result.Decision != testCase.decision {
				t.Fatalf("decision: got %q, want %q", result.Decision, testCase.decision)
			}
			if testCase.code == "" {
				if result.Diagnostic != nil {
					t.Fatalf("unexpected diagnostic: %#v", result.Diagnostic)
				}
				return
			}
			if result.Diagnostic == nil {
				t.Fatal("missing diagnostic")
			}
			if result.Diagnostic.Code != testCase.code {
				t.Errorf("code: got %q, want %q", result.Diagnostic.Code, testCase.code)
			}
			if result.Diagnostic.Segment != testCase.segment {
				t.Errorf("segment: got %d, want %d", result.Diagnostic.Segment, testCase.segment)
			}
			if result.Diagnostic.Predicate != testCase.predicate {
				t.Errorf("predicate: got %q, want %q", result.Diagnostic.Predicate, testCase.predicate)
			}
			if result.Diagnostic.Reason == "" || result.Diagnostic.Remediation == "" {
				t.Fatalf("incomplete diagnostic: %#v", result.Diagnostic)
			}
		})
	}
}

func TestInactiveSyntaxDenialIsAdmitted(t *testing.T) {
	t.Parallel()

	request := activeWorker("FOO=bar novel-tool")
	request.Marker = MarkerInactive
	result := Classify(request)
	if result.Decision != DecisionAllow {
		t.Fatalf("decision: got %q, want %q", result.Decision, DecisionAllow)
	}
}

func TestEightSegmentsAreBounded(t *testing.T) {
	t.Parallel()

	allowed := Classify(activeWorker("a;b;c;d;e;f;g;h"))
	if allowed.Decision != DecisionAllow {
		t.Fatalf("eight segments: got %#v", allowed)
	}

	denied := Classify(activeWorker("a;b;c;d;e;f;g;h;i"))
	if denied.Diagnostic == nil || denied.Diagnostic.Code != CodePlanLimitDenied {
		t.Fatalf("nine segments: got %#v", denied)
	}
}

func TestDeniedJSONCarriesCompilerFields(t *testing.T) {
	t.Parallel()

	result := Classify(activeWorker("printf before && env && printf after"))
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}

	for _, fragment := range []string{
		`"decision":"deny"`,
		`"code":"ECI_ENVIRONMENT_ENUMERATION_DENIED"`,
		`"operation":"environment-boundary"`,
		`"segment":2`,
		`"argv_index":0`,
		`"byte_offset":17`,
		`"token":"env"`,
		`"path":"n/a"`,
		`"predicate":"environment-enumeration"`,
		`"reason":`,
		`"remediation":`,
		`"permissionDecision":"deny"`,
		`"rejected_segment":"env"`,
		`rejected segment=env`,
	} {
		if !containsBytes(encoded, []byte(fragment)) {
			t.Errorf("encoded result missing %s: %s", fragment, encoded)
		}
	}
}

func TestRunReadsOneJSONRequestAndWritesOneJSONDecision(t *testing.T) {
	t.Parallel()

	request := activeWorker("adb devices -l")
	encodedRequest, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}

	var output bytes.Buffer
	status := Run(bytes.NewReader(encodedRequest), &output)
	if status != StatusAllow {
		t.Fatalf("status: got %d, want %d", status, StatusAllow)
	}
	if output.String() != "{\"decision\":\"allow\"}\n" {
		t.Fatalf("output: got %q", output.String())
	}
}

func TestRunRejectsTrailingJSON(t *testing.T) {
	t.Parallel()

	var output bytes.Buffer
	status := Run(strings.NewReader("{} {}"), &output)
	if status != StatusInternal {
		t.Fatalf("status: got %d, want %d", status, StatusInternal)
	}
	if !strings.Contains(output.String(), `"decision":"error"`) {
		t.Fatalf("output: got %q", output.String())
	}
}

func activeWorker(command string) Request {
	return Request{
		Provider:      ProviderCodex,
		Role:          RoleWorker,
		CWD:           "/tmp",
		Marker:        MarkerActive,
		ActiveSession: "test-session",
		Command:       command,
	}
}

func containsBytes(haystack []byte, needle []byte) bool {
	for index := 0; index+len(needle) <= len(haystack); index++ {
		if string(haystack[index:index+len(needle)]) == string(needle) {
			return true
		}
	}
	return false
}
