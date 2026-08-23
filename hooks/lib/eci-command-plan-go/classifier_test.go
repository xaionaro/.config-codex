package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func providerHome(provider Provider) string {
	envName := "CODEX_HOME"
	directory := ".codex"
	if provider == ProviderKimi {
		envName = "KIMI_CODE_HOME"
		directory = ".kimi-code"
	}
	if configured := os.Getenv(envName); configured != "" {
		return filepath.Clean(configured)
	}
	home := os.Getenv("HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	return filepath.Join(home, directory)
}

func gateModePath(provider Provider) string {
	return filepath.Join(providerHome(provider), "bin", "eci-command-gate-mode")
}

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
			name:      "transparent wrapped git mutations",
			request:   activeWorker("nohup git commit -m nope"),
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
			name:     "git branch contains inspection",
			request:  activeWorker("git branch --all --contains HEAD"),
			decision: DecisionAllow,
		},
		{
			name:      "git branch creation",
			request:   activeWorker("git branch feature"),
			decision:  DecisionDeny,
			code:      CodeWorkerGitOwnershipDenied,
			segment:   1,
			predicate: "worker-git-ownership",
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
			name:      "printenv option",
			request:   activeWorker("printenv -- PATH"),
			decision:  DecisionDeny,
			code:      CodeEnvironmentOptionDenied,
			segment:   1,
			predicate: "environment-option-unsupported",
		},
		{
			name:     "worker lifecycle control",
			request:  activeWorker("eci-active status"),
			decision: DecisionDefer,
		},
		{
			name:      "broad destruction",
			request:   activeWorker("rm -rf /"),
			decision:  DecisionDeny,
			code:      CodeBroadDestructiveDenied,
			segment:   1,
			predicate: "broad-destructive-root",
		},
		{
			name:      "wrapped broad destruction",
			request:   activeWorker("env FOO=bar rm -rf /"),
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

func TestActiveControlFileIndexBoundsSessionDirectory(t *testing.T) {
	t.Parallel()

	temporaryRoot := t.TempDir()
	sessionDir := filepath.Join(temporaryRoot, "proof", "session")
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		t.Fatalf("create session directory: %v", err)
	}
	marker := filepath.Join(sessionDir, "eci_active")
	if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
	for index := 0; index <= maxActiveControlEntries; index++ {
		path := filepath.Join(sessionDir, "ordinary-entry-"+strconv.Itoa(index))
		if err := os.WriteFile(path, []byte("ordinary\n"), 0o600); err != nil {
			t.Fatalf("write session entry %d: %v", index, err)
		}
	}

	index := activeControlFileIndex([]string{marker})
	if !index.overflow {
		t.Fatal("active control index did not report bounded directory overflow")
	}
	if len(index.files) != 0 {
		t.Fatalf("overflow index retained %d entries; want bounded empty index", len(index.files))
	}

	result := Classify(Request{
		Provider:      ProviderCodex,
		Role:          RoleWorker,
		CWD:           temporaryRoot,
		Marker:        MarkerActive,
		ActiveSession: "session",
		Command:       "cat ordinary-entry-0",
		ActiveMarkers: []string{marker},
	})
	if result.Decision != DecisionDeny || result.Diagnostic == nil {
		t.Fatalf("overflow classification: decision=%q diagnostic=%#v, want deny with diagnostic", result.Decision, result.Diagnostic)
	}
	if result.Diagnostic.Code != CodePlanLiveControlDenied || result.Diagnostic.Predicate != "bounded-control-index" {
		t.Fatalf("overflow diagnostic: code=%q predicate=%q, want %q/bounded-control-index", result.Diagnostic.Code, result.Diagnostic.Predicate, CodePlanLiveControlDenied)
	}
}

func TestGateModeCapabilityShapeIsReportedFromParsedPlans(t *testing.T) {
	t.Parallel()

	for _, command := range []string{
		gateModePath(ProviderCodex) + " set enforcing",
		"env FOO=bar " + gateModePath(ProviderCodex) + " set permissive",
		"python3 " + gateModePath(ProviderCodex) + " get",
		"printf before && " + gateModePath(ProviderCodex) + " set enforcing",
	} {
		result := Classify(Request{
			Provider:      ProviderCodex,
			Role:          RoleCoordinator,
			CWD:           "/tmp",
			Marker:        MarkerActive,
			ActiveSession: "test-session",
			Command:       command,
		})
		if len(result.Capabilities) != 1 || result.Capabilities[0] != CapabilityGateMode {
			t.Fatalf("%q: capabilities=%v, want [%q]", command, result.Capabilities, CapabilityGateMode)
		}
	}

	ordinary := Classify(Request{
		Provider:      ProviderCodex,
		Role:          RoleCoordinator,
		CWD:           "/tmp",
		Marker:        MarkerActive,
		ActiveSession: "test-session",
		Command:       "printf eci-command-gate-mode set enforcing",
	})
	if len(ordinary.Capabilities) != 0 {
		t.Fatalf("ordinary command capabilities=%v, want none", ordinary.Capabilities)
	}
}

func TestGateModeIdentityAndWorkerOwnershipAreCompiled(t *testing.T) {
	t.Parallel()

	canonical := gateModePath(ProviderCodex)
	coordinator := Classify(Request{
		Provider:      ProviderCodex,
		Role:          RoleCoordinator,
		CWD:           "/tmp",
		Marker:        MarkerActive,
		ActiveSession: "test-session",
		Command:       canonical + " set enforcing",
	})
	if coordinator.Decision != DecisionAllow || coordinator.Diagnostic != nil {
		t.Fatalf("canonical coordinator gate mode: decision=%q diagnostic=%#v, want allow", coordinator.Decision, coordinator.Diagnostic)
	}

	worker := coordinator
	workerRequest := Request{
		Provider:      ProviderCodex,
		Role:          RoleWorker,
		CWD:           "/tmp",
		Marker:        MarkerActive,
		ActiveSession: "test-session",
		Command:       canonical + " set enforcing",
	}
	worker = Classify(workerRequest)
	if worker.Decision != DecisionDeny || worker.Diagnostic == nil {
		t.Fatalf("canonical worker gate mode: decision=%q diagnostic=%#v, want deny", worker.Decision, worker.Diagnostic)
	}
	if worker.Diagnostic.Code != CodeControlOwnerRequired || worker.Diagnostic.Predicate != "gate-mode-mutation" {
		t.Fatalf("canonical worker diagnostic: code=%q predicate=%q, want %q/gate-mode-mutation", worker.Diagnostic.Code, worker.Diagnostic.Predicate, CodeControlOwnerRequired)
	}

	altered := filepath.Join(t.TempDir(), "eci-command-gate-mode")
	contents, err := os.ReadFile(canonical)
	if err != nil {
		t.Fatalf("read canonical gate-mode executable: %v", err)
	}
	if err := os.WriteFile(altered, append(contents, '\n'), 0o755); err != nil {
		t.Fatalf("write altered gate-mode executable: %v", err)
	}
	identity := Classify(Request{
		Provider:      ProviderCodex,
		Role:          RoleCoordinator,
		CWD:           "/tmp",
		Marker:        MarkerActive,
		ActiveSession: "test-session",
		Command:       altered + " set enforcing",
	})
	if identity.Decision != DecisionDeny || identity.Diagnostic == nil {
		t.Fatalf("altered coordinator gate mode: decision=%q diagnostic=%#v, want deny", identity.Decision, identity.Diagnostic)
	}
	if identity.Diagnostic.Code != CodeControlIdentityDenied || identity.Diagnostic.Predicate != "gate-mode-identity" {
		t.Fatalf("altered coordinator diagnostic: code=%q predicate=%q, want %q/gate-mode-identity", identity.Diagnostic.Code, identity.Diagnostic.Predicate, CodeControlIdentityDenied)
	}
}

func TestInactiveWorkerGateModeMutationIsDeniedForBothProviders(t *testing.T) {
	t.Parallel()

	for _, testCase := range []struct {
		provider Provider
		command  string
	}{
		{provider: ProviderCodex, command: gateModePath(ProviderCodex) + " set enforcing"},
		{provider: ProviderKimi, command: gateModePath(ProviderKimi) + " set permissive"},
	} {
		testCase := testCase
		t.Run(string(testCase.provider), func(t *testing.T) {
			t.Parallel()
			result := Classify(Request{
				Provider:      testCase.provider,
				Role:          RoleWorker,
				CWD:           "/tmp",
				Marker:        MarkerInactive,
				ActiveSession: "test-session",
				Command:       testCase.command,
			})
			if result.Decision != DecisionDeny || result.Diagnostic == nil {
				t.Fatalf("inactive worker gate mode command=%q: decision=%q diagnostic=%#v, want deny with diagnostic", testCase.command, result.Decision, result.Diagnostic)
			}
			if result.Diagnostic.Code != CodeControlOwnerRequired || result.Diagnostic.Predicate != "gate-mode-mutation" {
				t.Fatalf("inactive worker diagnostic: code=%q predicate=%q, want %q/gate-mode-mutation", result.Diagnostic.Code, result.Diagnostic.Predicate, CodeControlOwnerRequired)
			}
			if result.Diagnostic.Token != "set" || result.Diagnostic.ArgvIndex != 1 || result.Diagnostic.Segment != 1 {
				t.Fatalf("inactive worker location: token=%q argv_index=%d segment=%d, want set/1/1", result.Diagnostic.Token, result.Diagnostic.ArgvIndex, result.Diagnostic.Segment)
			}
		})
	}
}

func TestTransparentWrappersPreserveChildClassification(t *testing.T) {
	t.Parallel()

	commands := []string{
		"nohup novel-tool --flag value",
		"setsid --wait novel-tool --flag value",
		"sudo -n novel-tool --flag value",
		"doas -n novel-tool --flag value",
		"systemd-run --unit eci novel-tool --flag value",
		"time --format %E novel-tool --flag value",
		"prlimit --nofile=1024 novel-tool --flag value",
		"chronic -- novel-tool --flag value",
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			for _, command := range commands {
				result := Classify(Request{Provider: provider, Role: RoleCoordinator, CWD: "/tmp", Marker: MarkerActive, ActiveSession: "test", Command: command})
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Errorf("%s: got decision=%q diagnostic=%#v, want allow", command, result.Decision, result.Diagnostic)
				}
			}
			for _, command := range []string{
				"nohup git commit -m nope",
				"setsid --wait git commit -m nope",
				"sudo -n git commit -m nope",
				"doas -n git commit -m nope",
				"systemd-run --unit eci git commit -m nope",
				"time --format %E git commit -m nope",
				"prlimit --nofile=1024 git commit -m nope",
				"chronic -- git commit -m nope",
			} {
				result := Classify(Request{Provider: provider, Role: RoleWorker, CWD: "/tmp", Marker: MarkerActive, ActiveSession: "test", Command: command})
				if result.Decision != DecisionDeny || result.Diagnostic == nil {
					t.Errorf("%s: got decision=%q diagnostic=%#v, want denied Git ownership route", command, result.Decision, result.Diagnostic)
					continue
				}
				if result.Diagnostic.Code != CodeWorkerGitOwnershipDenied {
					t.Errorf("%s: code=%q, want %q", command, result.Diagnostic.Code, CodeWorkerGitOwnershipDenied)
				}
			}
		})
	}
}

func TestBroadDestructionIsProviderNeutral(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range []string{"rm -rf /", "env FOO=bar rm -rf /"} {
				result := Classify(Request{
					Provider: provider,
					Role:     RoleWorker,
					CWD:      "/tmp",
					Marker:   MarkerActive,
					Command:  command,
				})
				if result.Decision != DecisionDeny {
					t.Fatalf("%s: decision: got %q, want %q; diagnostic=%#v", command, result.Decision, DecisionDeny, result.Diagnostic)
				}
				if result.Diagnostic == nil {
					t.Fatalf("%s: missing diagnostic", command)
				}
				if result.Diagnostic.Code != CodeBroadDestructiveDenied {
					t.Errorf("%s: code: got %q, want %q", command, result.Diagnostic.Code, CodeBroadDestructiveDenied)
				}
				if result.Diagnostic.Operation != "broad-destructive" {
					t.Errorf("%s: operation: got %q, want broad-destructive", command, result.Diagnostic.Operation)
				}
				if result.Diagnostic.Segment != 1 || result.Diagnostic.ArgvIndex < 0 || result.Diagnostic.ByteOffset < 0 || result.Diagnostic.Token == "" || result.Diagnostic.Path == "n/a" || result.Diagnostic.Predicate == "" || result.Diagnostic.Reason == "" || result.Diagnostic.Remediation == "" {
					t.Errorf("%s: incomplete compiler-style diagnostic: %#v", command, result.Diagnostic)
				}
			}
		})
	}
}

func TestGitExecutionContextDiagnosticUsesStableCode(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			request := activeWorker("git -C /tmp -c user.name=test status --short")
			request.Provider = provider
			result := Classify(request)
			if result.Decision != DecisionDeny || result.Diagnostic == nil {
				t.Fatalf("decision=%q diagnostic=%#v, want deny with diagnostic", result.Decision, result.Diagnostic)
			}
			diagnostic := result.Diagnostic
			if diagnostic.Code != CodeGitExecutionContextDenied {
				t.Errorf("code=%q, want %q", diagnostic.Code, CodeGitExecutionContextDenied)
			}
			if diagnostic.Operation != "git-execution-context" {
				t.Errorf("operation=%q, want git-execution-context", diagnostic.Operation)
			}
			if diagnostic.Token != "-c" || diagnostic.ArgvIndex != 3 || diagnostic.Predicate != "git-execution-context" {
				t.Errorf("location=%#v, want token=-c argv_index=3 predicate=git-execution-context", diagnostic)
			}
			if !strings.Contains(diagnostic.Remediation, "bounded coordinator Git route") {
				t.Errorf("remediation=%q, want bounded coordinator Git route", diagnostic.Remediation)
			}

			foreign := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           "/tmp",
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       "git -C /tmp/foreign-repo status --short",
			})
			if foreign.Decision != DecisionDefer || foreign.Diagnostic != nil {
				t.Fatalf("foreign Git context: decision=%q diagnostic=%#v, want defer without diagnostic", foreign.Decision, foreign.Diagnostic)
			}
		})
	}
}

func TestProofPathOwnership(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			temporaryRoot := t.TempDir()
			proofSession := filepath.Join(temporaryRoot, "proof", "session")
			evidenceDirectory := filepath.Join(proofSession, "evidence")
			if err := os.MkdirAll(evidenceDirectory, 0o700); err != nil {
				t.Fatalf("create evidence directory: %v", err)
			}
			marker := filepath.Join(proofSession, "eci_active")
			inside := filepath.Join(evidenceDirectory, "inside.txt")
			missingInside := filepath.Join(evidenceDirectory, "missing", "instruction.md")
			outside := filepath.Join(temporaryRoot, "outside.txt")
			missingOutside := filepath.Join(temporaryRoot, "missing", "ordinary.txt")
			outsideLink := filepath.Join(evidenceDirectory, "outside-link")
			for path, content := range map[string][]byte{
				marker:  []byte("active\n"),
				inside:  []byte("inside\n"),
				outside: []byte("outside\n"),
			} {
				if err := os.WriteFile(path, content, 0o600); err != nil {
					t.Fatalf("write %s: %v", path, err)
				}
			}
			if err := os.Symlink(outside, outsideLink); err != nil {
				t.Fatalf("create outside link: %v", err)
			}
			liveControl := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "cat " + marker,
				ActiveMarkers: []string{marker},
			})
			if liveControl.Decision != DecisionDeny || liveControl.Diagnostic == nil {
				t.Fatalf("live control: decision=%q diagnostic=%#v, want deny with diagnostic", liveControl.Decision, liveControl.Diagnostic)
			}
			if liveControl.Diagnostic.Code != CodePlanLiveControlDenied {
				t.Fatalf("live control code=%q, want %q", liveControl.Diagnostic.Code, CodePlanLiveControlDenied)
			}
			if liveControl.Diagnostic.Path != marker {
				t.Fatalf("live control path=%q, want %q", liveControl.Diagnostic.Path, marker)
			}

			controlAlias := filepath.Join(temporaryRoot, "arbitrary-control-alias")
			if err := os.Link(marker, controlAlias); err != nil {
				t.Fatalf("create arbitrary control hardlink alias: %v", err)
			}
			controlAliasResult := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "cat " + controlAlias,
				ActiveMarkers: []string{marker},
			})
			if controlAliasResult.Decision != DecisionDeny || controlAliasResult.Diagnostic == nil {
				t.Fatalf("arbitrary control hardlink: decision=%q diagnostic=%#v, want deny with diagnostic", controlAliasResult.Decision, controlAliasResult.Diagnostic)
			}
			if controlAliasResult.Diagnostic.Code != CodePlanLiveControlDenied {
				t.Fatalf("arbitrary control hardlink code=%q, want %q", controlAliasResult.Diagnostic.Code, CodePlanLiveControlDenied)
			}

			ordinaryHelper := filepath.Join(temporaryRoot, "eci-environment-command.sh")
			ordinaryHelperAlias := filepath.Join(temporaryRoot, "arbitrary-helper-alias")
			if err := os.WriteFile(ordinaryHelper, []byte("#!/bin/sh\nexit 0\n"), 0o600); err != nil {
				t.Fatalf("write ordinary helper: %v", err)
			}
			if err := os.Link(ordinaryHelper, ordinaryHelperAlias); err != nil {
				t.Fatalf("create ordinary helper hardlink alias: %v", err)
			}
			ordinaryAliasResult := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "cat " + ordinaryHelperAlias,
				ActiveMarkers: []string{marker},
			})
			if ordinaryAliasResult.Decision != DecisionAllow || ordinaryAliasResult.Diagnostic != nil {
				t.Fatalf("ordinary helper hardlink: decision=%q diagnostic=%#v, want allow without diagnostic", ordinaryAliasResult.Decision, ordinaryAliasResult.Diagnostic)
			}
			proofAlias := filepath.Join(t.TempDir(), "proof-alias")
			if err := os.Symlink(filepath.Dir(proofSession), proofAlias); err != nil {
				t.Fatalf("create proof-root alias: %v", err)
			}
			aliasedInside := filepath.Join(proofAlias, "session", "evidence", "inside.txt")
			aliasedOutsideLink := filepath.Join(proofAlias, "session", "evidence", "outside-link")

			for _, testCase := range []struct {
				name     string
				path     string
				decision DecisionKind
			}{
				{name: "contained regular path", path: inside, decision: DecisionAllow},
				{name: "missing path in active proof tree", path: missingInside, decision: DecisionAllow},
				{name: "contained path through proof-root alias", path: aliasedInside, decision: DecisionAllow},
				{name: "ordinary outside path", path: outside, decision: DecisionAllow},
				{name: "missing ordinary outside path", path: missingOutside, decision: DecisionAllow},
				{name: "lexically contained symlink escape", path: outsideLink, decision: DecisionDeny},
				{name: "aliased proof-root symlink escape", path: aliasedOutsideLink, decision: DecisionDeny},
			} {
				t.Run(testCase.name, func(t *testing.T) {
					request := Request{
						Provider:      provider,
						Role:          RoleCoordinator,
						CWD:           temporaryRoot,
						Marker:        MarkerActive,
						ActiveSession: "session",
						Command:       "cat " + testCase.path,
						ActiveMarkers: []string{marker},
					}
					result := Classify(request)
					if result.Decision != testCase.decision {
						t.Fatalf("decision: got %q, want %q; diagnostic=%#v", result.Decision, testCase.decision, result.Diagnostic)
					}
					if testCase.decision != DecisionDeny {
						if result.Diagnostic != nil {
							t.Fatalf("unexpected diagnostic: %#v", result.Diagnostic)
						}
						return
					}
					if result.Diagnostic == nil {
						t.Fatal("missing proof escape diagnostic")
					}
					if result.Diagnostic.Code != DiagnosticCode("ECI_PROOF_PATH_ESCAPE_DENIED") {
						t.Errorf("code: got %q, want ECI_PROOF_PATH_ESCAPE_DENIED", result.Diagnostic.Code)
					}
					if result.Diagnostic.Operation != "proof-path-ownership" {
						t.Errorf("operation: got %q, want proof-path-ownership", result.Diagnostic.Operation)
					}
					if result.Diagnostic.Predicate != "proof-symlink-escape" {
						t.Errorf("predicate: got %q, want proof-symlink-escape", result.Diagnostic.Predicate)
					}
					if result.Diagnostic.Path != testCase.path {
						t.Errorf("path: got %q, want %q", result.Diagnostic.Path, testCase.path)
					}
				})
			}

			workerResult := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "find -P " + missingInside + " -maxdepth 1 -print",
				ActiveMarkers: []string{marker},
			})
			if workerResult.Decision != DecisionAllow || workerResult.Diagnostic != nil {
				t.Fatalf("missing worker proof path: decision=%q diagnostic=%#v, want allow without diagnostic", workerResult.Decision, workerResult.Diagnostic)
			}
		})
	}
}

func TestProtectedOperationsRouteByRole(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name     string
		role     Role
		cwd      string
		command  string
		decision DecisionKind
		code     DiagnosticCode
	}{
		{name: "worker Git mutation", role: RoleWorker, command: "git commit -m nope", decision: DecisionDeny, code: CodeWorkerGitOwnershipDenied},
		{name: "worker lifecycle control", role: RoleWorker, command: "eci-active status", decision: DecisionDefer},
		{name: "worker source write", role: RoleWorker, command: "touch source.txt", decision: DecisionAllow},
		{name: "coordinator source write", role: RoleCoordinator, command: "touch source.txt", decision: DecisionDefer},
		{name: "coordinator outside-CWD source write", role: RoleCoordinator, cwd: "/workspace", command: "touch /tmp/source.txt", decision: DecisionAllow},
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, testCase := range testCases {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					t.Parallel()

					cwd := testCase.cwd
					if cwd == "" {
						cwd = "/tmp"
					}
					request := Request{
						Provider:      provider,
						Role:          testCase.role,
						CWD:           cwd,
						Marker:        MarkerActive,
						ActiveSession: "test",
						Command:       testCase.command,
					}
					result := Classify(request)
					if result.Decision != testCase.decision {
						t.Fatalf("decision: got %q, want %q; diagnostic=%#v", result.Decision, testCase.decision, result.Diagnostic)
					}
					if testCase.code == "" {
						if result.Diagnostic != nil {
							t.Fatalf("unexpected diagnostic: %#v", result.Diagnostic)
						}
						return
					}
					if result.Diagnostic == nil {
						t.Fatal("missing Git ownership diagnostic")
					}
					if result.Diagnostic.Code != testCase.code {
						t.Fatalf("diagnostic code: got %q, want %q", result.Diagnostic.Code, testCase.code)
					}
				})
			}
		})
	}
}

func TestDDOutputDestinationsHonorControlOwnership(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			temporaryRoot := t.TempDir()
			sessionDir := filepath.Join(temporaryRoot, "proof", "session")
			if err := os.MkdirAll(sessionDir, 0o700); err != nil {
				t.Fatalf("create session directory: %v", err)
			}
			marker := filepath.Join(sessionDir, "eci_active")
			if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
				t.Fatalf("write active marker: %v", err)
			}

			protected := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "dd if=/dev/null of=" + marker,
				ActiveMarkers: []string{marker},
			})
			if protected.Decision != DecisionDeny || protected.Diagnostic == nil {
				t.Fatalf("protected dd output: decision=%q diagnostic=%#v, want deny with diagnostic", protected.Decision, protected.Diagnostic)
			}
			if protected.Diagnostic.Code != CodePlanLiveControlDenied {
				t.Fatalf("protected dd output code=%q, want %q", protected.Diagnostic.Code, CodePlanLiveControlDenied)
			}
			if protected.Diagnostic.Token != marker {
				t.Fatalf("protected dd output token=%q, want %q", protected.Diagnostic.Token, marker)
			}

			reservedState := filepath.Join(sessionDir, "eci_wait")
			reserved := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "dd if=/dev/null of=" + reservedState,
				ActiveMarkers: []string{marker},
			})
			if reserved.Decision != DecisionDeny || reserved.Diagnostic == nil {
				t.Fatalf("reserved dd output: decision=%q diagnostic=%#v, want deny with diagnostic", reserved.Decision, reserved.Diagnostic)
			}
			if reserved.Diagnostic.Code != CodePlanLiveControlDenied {
				t.Fatalf("reserved dd output code=%q, want %q", reserved.Diagnostic.Code, CodePlanLiveControlDenied)
			}
			if reserved.Diagnostic.Token != reservedState {
				t.Fatalf("reserved dd output token=%q, want %q", reserved.Diagnostic.Token, reservedState)
			}

			ordinaryPath := filepath.Join(t.TempDir(), "dd-output")
			ordinary := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "dd if=/dev/null of=" + ordinaryPath,
				ActiveMarkers: []string{marker},
			})
			if ordinary.Decision != DecisionAllow || ordinary.Diagnostic != nil {
				t.Fatalf("ordinary dd output: decision=%q diagnostic=%#v, want allow without diagnostic", ordinary.Decision, ordinary.Diagnostic)
			}
		})
	}
}

func TestGitArchiveOutputOwnership(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			temporaryRoot := t.TempDir()
			sessionDir := filepath.Join(temporaryRoot, "proof", "session")
			if err := os.MkdirAll(sessionDir, 0o700); err != nil {
				t.Fatalf("create session directory: %v", err)
			}
			marker := filepath.Join(sessionDir, "eci_active")
			if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
				t.Fatalf("write active marker: %v", err)
			}

			ordinaryPath := filepath.Join(sessionDir, "archive.tar")
			ordinary := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "git archive --output=" + ordinaryPath + " HEAD",
				ActiveMarkers: []string{marker},
			})
			if ordinary.Decision != DecisionAllow || ordinary.Diagnostic != nil {
				t.Fatalf("ordinary archive output: decision=%q diagnostic=%#v, want allow without diagnostic", ordinary.Decision, ordinary.Diagnostic)
			}

			control := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "git archive --output=" + marker + " HEAD",
				ActiveMarkers: []string{marker},
			})
			if control.Decision != DecisionDeny || control.Diagnostic == nil {
				t.Fatalf("control archive output: decision=%q diagnostic=%#v, want deny with diagnostic", control.Decision, control.Diagnostic)
			}
			if control.Diagnostic.Code != CodePlanLiveControlDenied {
				t.Fatalf("control archive output code=%q, want %q", control.Diagnostic.Code, CodePlanLiveControlDenied)
			}

			missingControlPath := filepath.Join(sessionDir, "missing", "eci_active")
			deferredControl := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "git archive --output=" + missingControlPath + " HEAD",
				ActiveMarkers: []string{marker},
			})
			if deferredControl.Decision != DecisionDefer || deferredControl.Diagnostic != nil {
				t.Fatalf("missing control archive output: decision=%q diagnostic=%#v, want defer without diagnostic", deferredControl.Decision, deferredControl.Diagnostic)
			}

			mutation := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           temporaryRoot,
				Marker:        MarkerActive,
				ActiveSession: "session",
				Command:       "git commit -m nope",
				ActiveMarkers: []string{marker},
			})
			if mutation.Decision != DecisionDeny || mutation.Diagnostic == nil {
				t.Fatalf("Git mutation: decision=%q diagnostic=%#v, want deny with diagnostic", mutation.Decision, mutation.Diagnostic)
			}
			if mutation.Diagnostic.Code != CodeWorkerGitOwnershipDenied {
				t.Fatalf("Git mutation code=%q, want %q", mutation.Diagnostic.Code, CodeWorkerGitOwnershipDenied)
			}
		})
	}
}

func TestGenericOutputWriterProofOwnership(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			temporaryRoot := t.TempDir()
			sessionDir := filepath.Join(temporaryRoot, "proof", "session")
			if err := os.MkdirAll(sessionDir, 0o700); err != nil {
				t.Fatalf("create session directory: %v", err)
			}
			marker := filepath.Join(sessionDir, "eci_active")
			if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
				t.Fatalf("write active marker: %v", err)
			}
			temporaryOutputRoot := t.TempDir()

			commands := []struct {
				name  string
				proof string
				other string
			}{
				{
					name:  "gitleaks report path",
					proof: "gitleaks --report-path=" + filepath.Join(sessionDir, "gitleaks-report.json"),
					other: "gitleaks --report-path=" + filepath.Join(temporaryOutputRoot, "gitleaks-report.json"),
				},
				{
					name:  "diff to-file",
					proof: "diff --to-file=" + filepath.Join(sessionDir, "diff.out") + " left.txt",
					other: "diff --to-file=" + filepath.Join(temporaryOutputRoot, "diff.out") + " left.txt",
				},
				{
					name:  "sort short output",
					proof: "sort -o " + filepath.Join(sessionDir, "sort.out") + " input.txt",
					other: "sort -o " + filepath.Join(temporaryOutputRoot, "sort.out") + " input.txt",
				},
			}

			for _, testCase := range commands {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					proofResult := Classify(Request{
						Provider:      provider,
						Role:          RoleWorker,
						CWD:           temporaryRoot,
						Marker:        MarkerActive,
						ActiveSession: "session",
						Command:       testCase.proof,
						ActiveMarkers: []string{marker},
					})
					if proofResult.Decision != DecisionDefer || proofResult.Diagnostic != nil {
						t.Fatalf("proof output: decision=%q diagnostic=%#v, want defer without diagnostic", proofResult.Decision, proofResult.Diagnostic)
					}

					otherResult := Classify(Request{
						Provider:      provider,
						Role:          RoleWorker,
						CWD:           temporaryRoot,
						Marker:        MarkerActive,
						ActiveSession: "session",
						Command:       testCase.other,
						ActiveMarkers: []string{marker},
					})
					if otherResult.Decision != DecisionAllow || otherResult.Diagnostic != nil {
						t.Fatalf("ordinary output: decision=%q diagnostic=%#v, want allow without diagnostic", otherResult.Decision, otherResult.Diagnostic)
					}
				})
			}
		})
	}
}

func TestReviewGateCapabilityDefersToProviderAdapters(t *testing.T) {
	t.Parallel()

	protectedCommands := []string{
		"eci-review-gate.sh commit test-session",
		"/opt/codex/hooks/eci-review-gate.sh commit test-session",
		"hooks/eci-review-gate.sh final test-session",
		"bash /opt/codex/hooks/eci-review-gate.sh commit test-session",
		"bash -e hooks/eci-review-gate.sh final test-session",
		"bash -x hooks/eci-review-gate.sh off test-session",
		"bash -O extglob hooks/eci-review-gate.sh prewrite test-session",
		"env FOO=bar bash -- hooks/eci-review-gate.sh prewrite test-session",
		"bash /opt/codex/hooks/eci-review-gate.sh unknown test-session",
		"bash /opt/codex/hooks/eci-review-gate.sh commit",
	}
	ordinaryCommands := []string{
		"./tools/eci-review-gate.sh verify",
		"bash ./tools/eci-review-gate.sh verify",
		"bash /provider/eci-review-gate.sh verify",
		"bash scripts/ordinary-review.sh",
		"printf hooks/eci-review-gate.sh",
		"bash -O eci-review-gate.sh commit test-session",
	}
	malformedInterpreterCommands := []string{
		"bash -c eci-review-gate.sh commit test-session",
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range protectedCommands {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/opt/codex",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionDefer || result.Diagnostic != nil {
					t.Fatalf("protected %q: decision=%q diagnostic=%#v, want deferred without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}

			for _, command := range ordinaryCommands {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/opt/codex",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("ordinary %q: decision=%q diagnostic=%#v, want allowed without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}

			for _, command := range malformedInterpreterCommands {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/opt/codex",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionDeny || result.Diagnostic == nil {
					t.Fatalf("malformed interpreter %q: decision=%q diagnostic=%#v, want deny with diagnostic", command, result.Decision, result.Diagnostic)
				}
				if result.Diagnostic.Code != CodePlanDynamicLaunchDenied {
					t.Fatalf("malformed interpreter %q: code=%q, want %q", command, result.Diagnostic.Code, CodePlanDynamicLaunchDenied)
				}
			}
		})
	}
}

func TestLifecycleScriptCapabilityDefersToProviderAdapters(t *testing.T) {
	t.Parallel()

	protectedCommands := []string{
		"bash -O extglob /opt/codex/hooks/stop-gate.sh",
		"bash --noprofile /opt/codex/hooks/stop-gate.sh",
		"bash -n hooks/stop-gate.sh",
		"sh -e /opt/codex/hooks/stop-gate.sh",
		"bash /opt/codex/hooks/eci-active-gate.sh",
		"env -u CODEX_ROLE bash /opt/codex/bin/eci-active status",
	}
	ordinaryCommands := []string{
		"bash scripts/stop-gate.sh",
		"bash scripts/eci-active status",
		"bash scripts/ordinary-control.sh",
		"printf hooks/stop-gate.sh",
		"printf /opt/codex/bin/eci-active",
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range protectedCommands {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/opt/codex",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionDefer || result.Diagnostic != nil {
					t.Fatalf("protected %q: decision=%q diagnostic=%#v, want deferred without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}

			for _, command := range ordinaryCommands {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/opt/codex",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("ordinary %q: decision=%q diagnostic=%#v, want allowed without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}
		})
	}
}

func TestWorkerCompoundPlansRouteByOperator(t *testing.T) {
	t.Parallel()

	commands := []struct {
		name     string
		command  string
		decision DecisionKind
	}{
		{name: "and", command: "printf left && printf right", decision: DecisionDefer},
		{name: "or", command: "printf left || printf right", decision: DecisionDefer},
		{name: "semicolon", command: "printf left ; printf right", decision: DecisionAllow},
		{name: "pipeline", command: "printf left | printf right", decision: DecisionDefer},
		{name: "bounded read-only pipeline", command: "git diff --binary -- hooks/validate-bash.sh | sha256sum", decision: DecisionDefer},
		{name: "newline", command: "printf left\nprintf right", decision: DecisionDefer},
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, testCase := range commands {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					t.Parallel()

					workerRequest := activeWorker(testCase.command)
					workerRequest.Provider = provider
					workerResult := Classify(workerRequest)
					if workerResult.Decision != testCase.decision || workerResult.Diagnostic != nil {
						t.Fatalf("worker compound plan: decision=%q diagnostic=%#v, want %q without diagnostic", workerResult.Decision, workerResult.Diagnostic, testCase.decision)
					}

					coordinatorRequest := workerRequest
					coordinatorRequest.Role = RoleCoordinator
					coordinatorResult := Classify(coordinatorRequest)
					if coordinatorResult.Decision != DecisionAllow || coordinatorResult.Diagnostic != nil {
						t.Fatalf("coordinator compound plan: decision=%q diagnostic=%#v, want allowed without diagnostic", coordinatorResult.Decision, coordinatorResult.Diagnostic)
					}

					inactiveWorkerRequest := workerRequest
					inactiveWorkerRequest.Marker = MarkerInactive
					inactiveWorkerResult := Classify(inactiveWorkerRequest)
					if inactiveWorkerResult.Decision != DecisionAllow || inactiveWorkerResult.Diagnostic != nil {
						t.Fatalf("inactive worker compound plan: decision=%q diagnostic=%#v, want allowed without diagnostic", inactiveWorkerResult.Decision, inactiveWorkerResult.Diagnostic)
					}
				})
			}

			protectedRequest := activeWorker("printf left | env")
			protectedRequest.Provider = provider
			protectedResult := Classify(protectedRequest)
			if protectedResult.Decision != DecisionDeny || protectedResult.Diagnostic == nil {
				t.Fatalf("protected compound plan: decision=%q diagnostic=%#v, want denied with diagnostic", protectedResult.Decision, protectedResult.Diagnostic)
			}
			if protectedResult.Diagnostic.Code != CodeEnvironmentEnumerationDenied || protectedResult.Diagnostic.Segment != 2 {
				t.Fatalf("protected compound diagnostic: got code=%q segment=%d, want code=%q segment=2", protectedResult.Diagnostic.Code, protectedResult.Diagnostic.Segment, CodeEnvironmentEnumerationDenied)
			}

			protectedSemicolon := activeWorker("printf left; env")
			protectedSemicolon.Provider = provider
			protectedSemicolonResult := Classify(protectedSemicolon)
			if protectedSemicolonResult.Decision != DecisionDeny || protectedSemicolonResult.Diagnostic == nil {
				t.Fatalf("protected semicolon plan: decision=%q diagnostic=%#v, want denied with diagnostic", protectedSemicolonResult.Decision, protectedSemicolonResult.Diagnostic)
			}
			if protectedSemicolonResult.Diagnostic.Code != CodeEnvironmentEnumerationDenied || protectedSemicolonResult.Diagnostic.Segment != 2 {
				t.Fatalf("protected semicolon diagnostic: got code=%q segment=%d, want code=%q segment=2", protectedSemicolonResult.Diagnostic.Code, protectedSemicolonResult.Diagnostic.Segment, CodeEnvironmentEnumerationDenied)
			}

			deferredSemicolon := activeWorker("printf left; eci-active status")
			deferredSemicolon.Provider = provider
			deferredSemicolonResult := Classify(deferredSemicolon)
			if deferredSemicolonResult.Decision != DecisionDefer || deferredSemicolonResult.Diagnostic != nil {
				t.Fatalf("deferred semicolon plan: decision=%q diagnostic=%#v, want deferred without diagnostic", deferredSemicolonResult.Decision, deferredSemicolonResult.Diagnostic)
			}
		})
	}
}

func TestCoordinatorHookRepairDefersToProviderAdapters(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			result := Classify(Request{
				Provider:      provider,
				Role:          RoleCoordinator,
				CWD:           "/tmp",
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       "bash hooks/install-pre-commit-go-mod.sh --repair-hardlink /tmp/peer",
			})
			if result.Decision != DecisionDefer || result.Diagnostic != nil {
				t.Fatalf("decision: got %q diagnostic=%#v", result.Decision, result.Diagnostic)
			}
		})
	}
}

func TestActivePreCommitHookModeRepairRoutesByRole(t *testing.T) {
	t.Parallel()

	const command = "chmod 755 hooks/pre-commit-go-mod.sh"
	negativeCases := []struct {
		name    string
		command string
		marker  Marker
	}{
		{name: "wrapper", command: "env chmod 755 hooks/pre-commit-go-mod.sh", marker: MarkerActive},
		{name: "executable alias", command: "/bin/chmod 755 hooks/pre-commit-go-mod.sh", marker: MarkerActive},
		{name: "alternate target spelling", command: "chmod 755 ./hooks/pre-commit-go-mod.sh", marker: MarkerActive},
		{name: "another target", command: "chmod 755 hooks/install-pre-commit-go-mod.sh", marker: MarkerActive},
		{name: "inactive exact", command: command, marker: MarkerInactive},
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			worker := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           "/workspace",
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       command,
			})
			if worker.Decision != DecisionDeny || worker.Diagnostic == nil {
				t.Fatalf("worker decision: got %q diagnostic=%#v, want deny with diagnostic", worker.Decision, worker.Diagnostic)
			}
			diagnostic := worker.Diagnostic
			if diagnostic.Code != CodeControlOwnerRequired {
				t.Errorf("worker code: got %q, want %q", diagnostic.Code, CodeControlOwnerRequired)
			}
			if diagnostic.Operation != "worker-control" {
				t.Errorf("worker operation: got %q, want worker-control", diagnostic.Operation)
			}
			if diagnostic.Predicate != "hook-mode-repair" {
				t.Errorf("worker predicate: got %q, want hook-mode-repair", diagnostic.Predicate)
			}
			if diagnostic.Token != "hooks/pre-commit-go-mod.sh" {
				t.Errorf("worker token: got %q, want hooks/pre-commit-go-mod.sh", diagnostic.Token)
			}
			if diagnostic.ArgvIndex != 2 {
				t.Errorf("worker argv index: got %d, want 2", diagnostic.ArgvIndex)
			}

			coordinatorRequest := Request{
				Provider:      provider,
				Role:          RoleCoordinator,
				CWD:           "/workspace",
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       command,
			}
			coordinator := Classify(coordinatorRequest)
			if coordinator.Decision != DecisionDefer || coordinator.Diagnostic != nil {
				t.Fatalf("coordinator decision: got %q diagnostic=%#v, want defer without diagnostic", coordinator.Decision, coordinator.Diagnostic)
			}

			for _, testCase := range negativeCases {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					result := Classify(Request{
						Provider:      provider,
						Role:          RoleWorker,
						CWD:           "/workspace",
						Marker:        testCase.marker,
						ActiveSession: "test-session",
						Command:       testCase.command,
					})
					if result.Diagnostic != nil && result.Diagnostic.Predicate == "hook-mode-repair" {
						t.Fatalf("%s selected hook-mode-repair: decision=%q diagnostic=%#v", testCase.command, result.Decision, result.Diagnostic)
					}
					if testCase.marker == MarkerInactive && (result.Decision != DecisionAllow || result.Diagnostic != nil) {
						t.Fatalf("inactive exact command: decision=%q diagnostic=%#v, want allow without diagnostic", result.Decision, result.Diagnostic)
					}
				})
			}
		})
	}
}

func TestActiveMktempDefersToProviderAdapters(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range []string{
				"mktemp -d /tmp/eci-probe.XXXXXX",
				"mktemp -d /tmp/eci-probe.XXXXXX extra",
			} {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleCoordinator,
					CWD:           "/tmp",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionDefer || result.Diagnostic != nil {
					t.Fatalf("%s: decision: got %q diagnostic=%#v", command, result.Decision, result.Diagnostic)
				}
			}
		})
	}
}

func TestInactiveLeadingAssignmentDefersToLegacy(t *testing.T) {
	t.Parallel()

	request := activeWorker("FOO=bar novel-tool")
	request.Marker = MarkerInactive
	result := Classify(request)
	if result.Decision != DecisionDefer {
		t.Fatalf("decision: got %q, want %q", result.Decision, DecisionDefer)
	}
}

func TestQuotedCommandSubstitutionFollowsMarkerBoundary(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			inactive := activeWorker(`printf "%s\\n" "$(printf nested)"`)
			inactive.Provider = provider
			inactive.Marker = MarkerInactive
			inactiveResult := Classify(inactive)
			if inactiveResult.Decision != DecisionDefer || inactiveResult.Diagnostic != nil {
				t.Fatalf("inactive decision=%q diagnostic=%#v, want transparent defer without diagnostic", inactiveResult.Decision, inactiveResult.Diagnostic)
			}

			active := activeWorker(inactive.Command)
			active.Provider = provider
			activeResult := Classify(active)
			if activeResult.Decision != DecisionDeny {
				t.Fatalf("active decision=%q diagnostic=%#v, want %q", activeResult.Decision, activeResult.Diagnostic, DecisionDeny)
			}
			if activeResult.Diagnostic == nil {
				t.Fatal("missing active command-substitution diagnostic")
			}
			if activeResult.Diagnostic.Code != CodePlanSyntaxDenied {
				t.Fatalf("code: got %q, want %q", activeResult.Diagnostic.Code, CodePlanSyntaxDenied)
			}
			if activeResult.Diagnostic.Predicate != "dynamic-expansion" {
				t.Fatalf("predicate: got %q, want dynamic-expansion", activeResult.Diagnostic.Predicate)
			}
		})
	}
}

func TestInactiveOpaqueShellContextDefersToLegacy(t *testing.T) {
	t.Parallel()

	for _, command := range []string{
		"PATH=/tmp git commit",
		"env git commit",
		"bash -c 'git commit'",
	} {
		result := Classify(Request{
			Provider: ProviderCodex,
			Role:     RoleCoordinator,
			CWD:      "/tmp",
			Marker:   MarkerInactive,
			Command:  command,
		})
		if result.Decision != DecisionDefer || result.Diagnostic != nil {
			t.Errorf("%s: decision=%q diagnostic=%#v, want deferred without diagnostic", command, result.Decision, result.Diagnostic)
		}
	}
}

func TestInactiveOrdinaryLiteralRemainsAllowed(t *testing.T) {
	t.Parallel()

	result := Classify(Request{
		Provider: ProviderCodex,
		Role:     RoleCoordinator,
		CWD:      "/tmp",
		Marker:   MarkerInactive,
		Command:  "novel-tool --flag value",
	})
	if result.Decision != DecisionAllow || result.Diagnostic != nil {
		t.Fatalf("decision=%q diagnostic=%#v, want allow without diagnostic", result.Decision, result.Diagnostic)
	}
}

func TestEightSegmentsAreBounded(t *testing.T) {
	t.Parallel()

	coordinatorRequest := activeWorker("a;b;c;d;e;f;g;h")
	coordinatorRequest.Role = RoleCoordinator
	allowed := Classify(coordinatorRequest)
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

func TestEnvironmentUnsetOptions(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name        string
		command     string
		decision    DecisionKind
		token       string
		argvIndex   int
		predicate   string
		reason      string
		remediation string
	}{
		{
			name:     "attached valid identifier",
			command:  "env --unset=FOO novel-tool",
			decision: DecisionAllow,
		},
		{
			name:        "attached empty identifier",
			command:     "env --unset= novel-tool",
			decision:    DecisionDeny,
			token:       "--unset=",
			argvIndex:   1,
			predicate:   "environment-invalid-option-argument",
			reason:      "not a valid identifier",
			remediation: "supply --unset=NAME",
		},
		{
			name:        "attached invalid identifier",
			command:     "env --unset=9FOO novel-tool",
			decision:    DecisionDeny,
			token:       "--unset=9FOO",
			argvIndex:   1,
			predicate:   "environment-invalid-option-argument",
			reason:      "not a valid identifier",
			remediation: "supply --unset=NAME",
		},
		{
			name:     "attached chdir remains structural",
			command:  "env --chdir=/tmp novel-tool",
			decision: DecisionAllow,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			result := Classify(activeWorker(testCase.command))
			if result.Decision != testCase.decision {
				t.Fatalf("decision: got %q, want %q; diagnostic=%#v", result.Decision, testCase.decision, result.Diagnostic)
			}
			if testCase.decision == DecisionAllow {
				if result.Diagnostic != nil {
					t.Fatalf("unexpected diagnostic: %#v", result.Diagnostic)
				}
				return
			}
			if result.Diagnostic == nil {
				t.Fatal("missing diagnostic")
			}
			if result.Diagnostic.Code != CodeEnvironmentOptionDenied {
				t.Errorf("code: got %q, want %q", result.Diagnostic.Code, CodeEnvironmentOptionDenied)
			}
			if result.Diagnostic.Token != testCase.token {
				t.Errorf("token: got %q, want %q", result.Diagnostic.Token, testCase.token)
			}
			if result.Diagnostic.ArgvIndex != testCase.argvIndex {
				t.Errorf("argv index: got %d, want %d", result.Diagnostic.ArgvIndex, testCase.argvIndex)
			}
			if result.Diagnostic.Predicate != testCase.predicate {
				t.Errorf("predicate: got %q, want %q", result.Diagnostic.Predicate, testCase.predicate)
			}
			if !strings.Contains(result.Diagnostic.Reason, testCase.reason) {
				t.Errorf("reason %q does not contain %q", result.Diagnostic.Reason, testCase.reason)
			}
			if !strings.Contains(result.Diagnostic.Remediation, testCase.remediation) {
				t.Errorf("remediation %q does not contain %q", result.Diagnostic.Remediation, testCase.remediation)
			}
		})
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
