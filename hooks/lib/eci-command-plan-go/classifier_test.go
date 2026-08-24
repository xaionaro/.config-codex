package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
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
			name:     "literal environment wrapper with module tool",
			request:  activeWorker("env FOO=bar python3 -m pytest tests"),
			decision: DecisionAllow,
		},
		{
			name:      "environment wrapper with interpreter eval",
			request:   activeWorker("env FOO=bar python3 -c 'print(1)'"),
			decision:  DecisionDeny,
			code:      CodePlanDynamicLaunchDenied,
			segment:   1,
			predicate: "dynamic-interpreter-launch",
		},
		{
			name:      "environment wrapper with malformed option assignment",
			request:   activeWorker("env --unset=9FOO novel-tool"),
			decision:  DecisionDeny,
			code:      CodeEnvironmentOptionDenied,
			segment:   1,
			predicate: "environment-invalid-option-argument",
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

// TestFiniteReadOnlyGitPlansKeepLegacyRouting verifies ordinary
// current-repository Git inspection remains an ordinary planner allow without
// creating a broad Git capability.
//
// Example: git status remains capability-free while git -C repo status stays
// deferred.
func TestFiniteReadOnlyGitPlansKeepLegacyRouting(t *testing.T) {
	t.Parallel()

	readOnly := []string{
		"git log --format=%H -- skills/go-coding-style/SKILL.md AGENTS.md",
		"git status",
		"git status --short --untracked-files=all",
		"git diff --check",
		"git show",
		"git ls-files",
		"git branch --all --contains HEAD",
		"git rev-parse HEAD",
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, role := range []Role{RoleCoordinator, RoleWorker} {
				for _, command := range readOnly {
					request := activeWorker(command)
					request.Provider = provider
					request.Role = role
					result := Classify(request)
					if result.Decision != DecisionAllow || result.Diagnostic != nil {
						t.Errorf("role=%q %q: decision=%q diagnostic=%#v, want allow without diagnostic", role, command, result.Decision, result.Diagnostic)
					}
					if len(result.Capabilities) != 0 {
						t.Errorf("role=%q %q: capabilities=%v, want none", role, command, result.Capabilities)
					}
				}
			}

			foreignContext := activeWorker("git -C /tmp/foreign status --short")
			foreignContext.Provider = provider
			if result := Classify(foreignContext); result.Decision != DecisionDefer || result.Diagnostic != nil {
				t.Errorf("foreign context: decision=%q diagnostic=%#v, want defer without diagnostic", result.Decision, result.Diagnostic)
			} else if len(result.Capabilities) != 0 {
				t.Errorf("foreign context: capabilities=%v, want none", result.Capabilities)
			}

			for _, testCase := range []struct {
				command string
				code    DiagnosticCode
			}{
				{command: "git --git-dir=.git status --short", code: CodeGitExecutionContextDenied},
				{command: "git commit -m forbidden", code: CodeWorkerGitOwnershipDenied},
				{command: "git reset --hard HEAD", code: CodeWorkerGitOwnershipDenied},
				{command: "git checkout -- hooks/validate-bash.sh", code: CodeWorkerGitOwnershipDenied},
				{command: "git branch feature", code: CodeWorkerGitOwnershipDenied},
			} {
				request := activeWorker(testCase.command)
				request.Provider = provider
				result := Classify(request)
				if result.Decision != DecisionDeny || result.Diagnostic == nil || result.Diagnostic.Code != testCase.code {
					t.Errorf("%q: decision=%q diagnostic=%#v, want deny/%q", testCase.command, result.Decision, result.Diagnostic, testCase.code)
				}
				if len(result.Capabilities) != 0 {
					t.Errorf("%q: capabilities=%v, want none", testCase.command, result.Capabilities)
				}
			}

			for _, command := range []string{"env git status", "git status && printf after"} {
				request := activeWorker(command)
				request.Provider = provider
				result := Classify(request)
				if len(result.Capabilities) != 0 {
					t.Errorf("%q: capabilities=%v, want none", command, result.Capabilities)
				}
			}
		})
	}
}

// TestNamedRuntimesRequireLiteralTargets keeps direct runtime invocations
// finite without turning arbitrary executable names into an allowlist.
//
// Example: node scripts/check.mjs is admitted, while node --eval=code is not.
func TestNamedRuntimesRequireLiteralTargets(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name    string
		command string
		deny    bool
	}{
		{name: "bare python", command: "python3", deny: true},
		{name: "python stdin dash", command: "python3 -", deny: true},
		{name: "python stdin switch", command: "python3 --stdin", deny: true},
		{name: "python inline code", command: "python3 -c print", deny: true},
		{name: "python inline code attached", command: "python3 -cprint", deny: true},
		{name: "versioned python bare", command: "python3.11", deny: true},
		{name: "versioned python inline code", command: "python3.11 -cprint", deny: true},
		{name: "python module", command: "python3 -m pytest"},
		{name: "python script", command: "python3 tools/check.py"},
		{name: "python script trailing argv", command: "python3 tools/check.py -c"},
		{name: "python warning option", command: "python3 -W ignore", deny: true},
		{name: "python implementation option", command: "python3 -X dev", deny: true},
		{name: "python interactive option", command: "python3 -i tools/check.py", deny: true},
		{name: "bare node", command: "node", deny: true},
		{name: "bare nodejs", command: "nodejs", deny: true},
		{name: "node eval", command: "node -e code", deny: true},
		{name: "node short eval attached", command: "node -e=code", deny: true},
		{name: "node long eval attached", command: "node --eval=code", deny: true},
		{name: "node print", command: "node -p code", deny: true},
		{name: "node short print attached", command: "node -p=code", deny: true},
		{name: "node long print attached", command: "node --print=code", deny: true},
		{name: "node script", command: "node scripts/check.mjs"},
		{name: "nodejs script", command: "nodejs scripts/check.mjs"},
		{name: "nodejs eval", command: "nodejs --eval=code", deny: true},
		{name: "node loader option", command: "node --loader loader.mjs", deny: true},
		{name: "bare perl", command: "perl", deny: true},
		{name: "perl eval", command: "perl -e code", deny: true},
		{name: "perl eval attached", command: "perl -ecode", deny: true},
		{name: "perl extended eval", command: "perl -E code", deny: true},
		{name: "perl extended eval attached", command: "perl -Ecode", deny: true},
		{name: "perl script", command: "perl tools/check.pl"},
		{name: "versioned perl eval", command: "perl5 -ecode", deny: true},
		{name: "perl include option", command: "perl -I /tmp", deny: true},
		{name: "bare ruby", command: "ruby", deny: true},
		{name: "ruby eval", command: "ruby -e code", deny: true},
		{name: "ruby eval attached", command: "ruby -ecode", deny: true},
		{name: "ruby script", command: "ruby tools/check.rb"},
		{name: "versioned ruby eval", command: "ruby3.3 -ecode", deny: true},
		{name: "ruby include option", command: "ruby -I lib", deny: true},
		{name: "bare php", command: "php", deny: true},
		{name: "php run", command: "php -r code", deny: true},
		{name: "php short run attached", command: "php -recho", deny: true},
		{name: "php run attached", command: "php --run=code", deny: true},
		{name: "php process begin", command: "php -B code", deny: true},
		{name: "php short process begin attached", command: "php -Becho", deny: true},
		{name: "php process begin attached", command: "php --process-begin=code", deny: true},
		{name: "php process code", command: "php -R code", deny: true},
		{name: "php short process code attached", command: "php -Recho", deny: true},
		{name: "php process code attached", command: "php --process-code=code", deny: true},
		{name: "php process end", command: "php -E code", deny: true},
		{name: "php short process end attached", command: "php -Eecho", deny: true},
		{name: "php process end attached", command: "php --process-end=code", deny: true},
		{name: "php interactive", command: "php -a", deny: true},
		{name: "php setting option", command: "php -d memory_limit=1G", deny: true},
		{name: "php script", command: "php tools/check.php"},
		{name: "php file", command: "php -f tools/check.php"},
		{name: "php file uppercase", command: "php -F tools/check.php"},
		{name: "versioned php run", command: "php8.2 -r=code", deny: true},
		{name: "ordinary unknown interpreter-like tool", command: "interpreter-tool --module test-suite --flag value"},
		{name: "ordinary python-prefixed helper", command: "python-tool --module test-suite --flag value"},
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		for _, testCase := range testCases {
			testCase := testCase
			t.Run(string(provider)+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()

				request := activeWorker(testCase.command)
				request.Provider = provider
				result := Classify(request)
				if testCase.deny {
					if result.Decision != DecisionDeny || result.Diagnostic == nil {
						t.Fatalf("%q: decision=%q diagnostic=%#v, want dynamic launch denial", testCase.command, result.Decision, result.Diagnostic)
					}
					if result.Diagnostic.Code != CodePlanDynamicLaunchDenied || result.Diagnostic.Predicate != "dynamic-interpreter-launch" {
						t.Fatalf("%q: diagnostic=%#v, want %q/dynamic-interpreter-launch", testCase.command, result.Diagnostic, CodePlanDynamicLaunchDenied)
					}
					return
				}
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: decision=%q diagnostic=%#v, want allow", testCase.command, result.Decision, result.Diagnostic)
				}
			})
		}
	}
}

func TestCoordinatorApprovedGitReadContextsAdmitLiteralPathspecs(t *testing.T) {
	t.Parallel()

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("resolve home directory: %v", err)
	}
	approvedRoot := filepath.Join(home, "tmp", "eci-approved-repository")
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			for _, command := range []string{
				"git -C " + approvedRoot + " status --short ../outside",
				"git -C " + approvedRoot + " diff --stat /etc/passwd",
				"git -C " + approvedRoot + " diff -- ../outside",
			} {
				request := Request{
					Provider:      provider,
					Role:          RoleCoordinator,
					CWD:           approvedRoot,
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
					ApprovedRoots: []string{approvedRoot},
				}
				result := Classify(request)
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Errorf("%q: decision=%q diagnostic=%#v, want allow", command, result.Decision, result.Diagnostic)
				}
			}

			foreign := Request{
				Provider:      provider,
				Role:          RoleCoordinator,
				CWD:           approvedRoot,
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       "git -C " + filepath.Join(home, "tmp", "foreign-repository") + " status --short ../outside",
				ApprovedRoots: []string{approvedRoot},
			}
			if result := Classify(foreign); result.Decision != DecisionDefer || result.Diagnostic != nil {
				t.Errorf("foreign repository context: decision=%q diagnostic=%#v, want defer", result.Decision, result.Diagnostic)
			}

			worker := Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           approvedRoot,
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       "git -C " + approvedRoot + " status --short ../outside",
				ApprovedRoots: []string{approvedRoot},
			}
			if result := Classify(worker); result.Decision != DecisionDefer || result.Diagnostic != nil {
				t.Errorf("worker read context: decision=%q diagnostic=%#v, want defer", result.Decision, result.Diagnostic)
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

// repositoryDefaultGitArchiveCapabilityCase defines one raw command grammar
// case shared by classifier and installed-binary capability tests.
type repositoryDefaultGitArchiveCapabilityCase struct {
	name                  string
	command               string
	wantArchiveCapability bool
	targetsActiveMarker   bool
	wantDecision          DecisionKind
	wantDiagnosticCode    DiagnosticCode
}

// repositoryDefaultGitArchiveCapabilityCases lists every accepted and
// rejected raw command shape for the repository-default archive capability.
var repositoryDefaultGitArchiveCapabilityCases = []repositoryDefaultGitArchiveCapabilityCase{
	{
		name:                  "direct HEAD",
		command:               "git archive HEAD",
		wantArchiveCapability: true,
	},
	{
		name:                  "exact tar output",
		command:               "git archive --format=tar --output=artifact.tar HEAD",
		wantArchiveCapability: true,
	},
	{
		name:                "active marker output",
		command:             "git archive --format=tar --output=<active-marker> HEAD",
		targetsActiveMarker: true,
		wantDecision:        DecisionDeny,
		wantDiagnosticCode:  CodePlanLiveControlDenied,
	},
	{
		name:    "quoted revision",
		command: "git archive 'HEAD'",
	},
	{
		name:    "quoted executable",
		command: "'git' archive HEAD",
	},
	{
		name:    "escaped executable",
		command: "g\\it archive HEAD",
	},
	{
		name:    "absolute executable path",
		command: "/usr/bin/git archive HEAD",
	},
	{
		name:    "relative executable path",
		command: "./git archive HEAD",
	},
	{
		name:    "environment wrapper",
		command: "env git archive HEAD",
	},
	{
		name:    "compound plan",
		command: "git archive HEAD && printf done",
	},
	{
		name:    "redirection",
		command: "git archive HEAD > artifact.tar",
	},
	{
		name:    "repository context",
		command: "git -C /tmp archive HEAD",
	},
	{
		name:    "configuration context",
		command: "git -c core.pager=cat archive HEAD",
	},
	{
		name:    "git directory context",
		command: "git --git-dir=.git archive HEAD",
	},
	{
		name:    "work tree context",
		command: "git --work-tree=. archive HEAD",
	},
	{
		name:    "configuration environment context",
		command: "git --config-env=core.foo=FOO archive HEAD",
	},
	{
		name:    "execution path context",
		command: "git --exec-path=/tmp archive HEAD",
	},
	{
		name:    "namespace context",
		command: "git --namespace=namespace archive HEAD",
	},
	{
		name:    "super prefix context",
		command: "git --super-prefix=prefix archive HEAD",
	},
	{
		name:    "text conversion context",
		command: "git --textconv archive HEAD",
	},
	{
		name:    "external diff context",
		command: "git --ext-diff archive HEAD",
	},
	{
		name:    "archive remote attached",
		command: "git archive --remote=origin HEAD",
	},
	{
		name:    "archive remote separate",
		command: "git archive --remote origin HEAD",
	},
	{
		name:    "archive exec attached",
		command: "git archive --exec=git-upload-archive HEAD",
	},
	{
		name:    "archive exec separate",
		command: "git archive --exec git-upload-archive HEAD",
	},
	{
		name:    "output inference",
		command: "git archive --output=artifact.tar HEAD",
	},
	{
		name:    "separate output argument",
		command: "git archive --format=tar --output artifact.tar HEAD",
	},
	{
		name:    "empty output value",
		command: "git archive --format=tar --output= HEAD",
	},
	{
		name:    "quoted output value",
		command: "git archive --format=tar --output='artifact.tar' HEAD",
	},
	{
		name:    "custom archive format",
		command: "git archive --format=zip --output=artifact.zip HEAD",
	},
	{
		name:    "additional file",
		command: "git archive --format=tar --output=artifact.tar --add-file=README HEAD",
	},
	{
		name:    "pathspec",
		command: "git archive --format=tar --output=artifact.tar HEAD README",
	},
	{
		name:    "extra archive option",
		command: "git archive --format=tar --output=artifact.tar HEAD --prefix=release/",
	},
	{
		name:    "output option before format",
		command: "git archive --output=artifact.tar --format=tar HEAD",
	},
}

// TestRepositoryDefaultGitArchiveCapabilityRequiresExactRawPlan verifies that
// only the two repository-default archive argv shapes carry the capability.
//
// Example: git archive --format=tar --output=artifact.tar HEAD is eligible,
// while a wrapper, quote, context option, or additional archive argument is not.
func TestRepositoryDefaultGitArchiveCapabilityRequiresExactRawPlan(t *testing.T) {
	t.Parallel()

	for _, testCase := range repositoryDefaultGitArchiveCapabilityCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			request := repositoryDefaultGitArchiveCapabilityRequest(t, testCase)
			result := Classify(request)
			if testCase.wantDecision != "" && result.Decision != testCase.wantDecision {
				t.Fatalf("%q: decision=%q, want %q; diagnostic=%#v", request.Command, result.Decision, testCase.wantDecision, result.Diagnostic)
			}
			if testCase.wantDiagnosticCode != "" && (result.Diagnostic == nil || result.Diagnostic.Code != testCase.wantDiagnosticCode) {
				t.Fatalf("%q: diagnostic=%#v, want code %q", request.Command, result.Diagnostic, testCase.wantDiagnosticCode)
			}
			if testCase.wantArchiveCapability {
				if len(result.Capabilities) != 1 || result.Capabilities[0] != CapabilityRepositoryDefaultGitArchive {
					t.Fatalf("%q: capabilities=%v, want [%q]", testCase.command, result.Capabilities, CapabilityRepositoryDefaultGitArchive)
				}
				return
			}
			if len(result.Capabilities) != 0 {
				t.Fatalf("%q: capabilities=%v, want none", testCase.command, result.Capabilities)
			}
		})
	}
}

// TestInstalledBinaryEmitsRepositoryDefaultGitArchiveCapability verifies the
// shipped planner applies the shared raw archive capability matrix exactly.
//
// Example: a hook can consume the binary response without re-tokenizing any
// accepted or rejected original shell command.
func TestInstalledBinaryEmitsRepositoryDefaultGitArchiveCapability(t *testing.T) {
	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}

	for _, testCase := range repositoryDefaultGitArchiveCapabilityCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			request := repositoryDefaultGitArchiveCapabilityRequest(t, testCase)
			input, err := json.Marshal(request)
			if err != nil {
				t.Fatalf("marshal %q request: %v", request.Command, err)
			}

			var stdout bytes.Buffer
			status := runBinary(t, binary, input, &stdout)
			var result Result
			if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
				t.Fatalf("decode %q response: %v; output=%s", request.Command, err, stdout.String())
			}
			if testCase.wantDecision != "" && result.Decision != testCase.wantDecision {
				t.Fatalf("%q: decision=%q, want %q; diagnostic=%#v", request.Command, result.Decision, testCase.wantDecision, result.Diagnostic)
			}
			if testCase.wantDiagnosticCode != "" && (result.Diagnostic == nil || result.Diagnostic.Code != testCase.wantDiagnosticCode) {
				t.Fatalf("%q: diagnostic=%#v, want code %q", request.Command, result.Diagnostic, testCase.wantDiagnosticCode)
			}
			if testCase.wantArchiveCapability {
				if status != StatusAllow {
					t.Fatalf("%q: status=%d output=%s, want %d", request.Command, status, stdout.String(), StatusAllow)
				}
				const want = "{\"decision\":\"allow\",\"capabilities\":[\"repository-default-git-archive\"]}\n"
				if stdout.String() != want {
					t.Fatalf("%q: JSON=%s, want %s", request.Command, stdout.String(), want)
				}
				return
			}
			if len(result.Capabilities) != 0 {
				t.Fatalf("%q: capabilities=%v, want none", request.Command, result.Capabilities)
			}
			if testCase.wantDecision == DecisionDeny && status != StatusDeny {
				t.Fatalf("%q: status=%d output=%s, want %d", request.Command, status, stdout.String(), StatusDeny)
			}
		})
	}
}

// repositoryDefaultGitArchiveCapabilityRequest materializes an active marker
// target when a shared grammar case needs to prove control inspection wins
// before the planner capability can be consumed.
func repositoryDefaultGitArchiveCapabilityRequest(t *testing.T, testCase repositoryDefaultGitArchiveCapabilityCase) Request {
	t.Helper()

	request := activeWorker(testCase.command)
	if !testCase.targetsActiveMarker {
		return request
	}

	marker := filepath.Join(t.TempDir(), "eci_active")
	if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
		t.Fatalf("write active marker %s: %v", marker, err)
	}
	request.ActiveMarkers = []string{marker}
	request.Command = "git archive --format=tar --output=" + marker + " HEAD"
	return request
}

// directPathGitStatusCapabilityCase defines one raw command grammar case for
// the one direct Git status capability without asserting executable identity.
//
// Example: /tmp/fake-bin/git status carries the direct-path capability.
type directPathGitStatusCapabilityCase struct {
	name               string
	command            string
	wantCapability     Capability
	wantDecision       DecisionKind
	wantDiagnosticCode DiagnosticCode
}

// directPathGitStatusCapabilityCases lists the closed direct-status grammar
// and every adjacent raw shape that must remain outside the capability.
//
// Example: a status flag or wrapper around /tmp/fake-bin/git stays uncategorized.
var directPathGitStatusCapabilityCases = []directPathGitStatusCapabilityCase{
	{
		name:           "direct status",
		command:        "/tmp/task/git status",
		wantCapability: CapabilityDirectPathGitStatus,
		wantDecision:   DecisionAllow,
	},
	{
		name:           "relative direct status",
		command:        "./tools/git status",
		wantCapability: CapabilityDirectPathGitStatus,
		wantDecision:   DecisionAllow,
	},
	{
		name:         "bare status keeps legacy route",
		command:      "git status",
		wantDecision: DecisionAllow,
	},
	{
		name:         "quoted executable",
		command:      "\"/tmp/task/git\" status",
		wantDecision: DecisionAllow,
	},
	{
		name:         "status short flag",
		command:      "/tmp/task/git status --short",
		wantDecision: DecisionAllow,
	},
	{
		name:         "status porcelain flag",
		command:      "/tmp/task/git status --porcelain=v1",
		wantDecision: DecisionAllow,
	},
	{
		name:         "no pager status",
		command:      "/tmp/task/git --no-pager status",
		wantDecision: DecisionAllow,
	},
	{
		name:         "direct archive",
		command:      "/tmp/task/git archive HEAD",
		wantDecision: DecisionAllow,
	},
	{
		name:         "direct no pager archive",
		command:      "/tmp/task/git --no-pager archive HEAD",
		wantDecision: DecisionAllow,
	},
	{
		name:         "environment wrapper",
		command:      "env /tmp/task/git status",
		wantDecision: DecisionAllow,
	},
	{
		name:         "compound",
		command:      "/tmp/task/git status && printf after",
		wantDecision: DecisionDefer,
	},
	{
		name:               "mutation",
		command:            "/tmp/task/git commit -m nope",
		wantDecision:       DecisionDeny,
		wantDiagnosticCode: CodeWorkerGitOwnershipDenied,
	},
	{
		name:         "direct notes mutation",
		command:      "/tmp/task/git notes add -m note",
		wantDecision: DecisionAllow,
	},
	{
		name:         "direct stash mutation",
		command:      "/tmp/task/git stash push",
		wantDecision: DecisionAllow,
	},
	{
		name:         "direct clean mutation",
		command:      "/tmp/task/git clean -f",
		wantDecision: DecisionAllow,
	},
	{
		name:         "direct reflog mutation",
		command:      "/tmp/task/git reflog expire",
		wantDecision: DecisionAllow,
	},
}

// TestDirectPathGitStatusCapabilityRequiresExactRawPlan verifies that only
// one direct, unquoted Git status argv exposes the planner capability.
//
// Example: /tmp/fake-bin/git status carries the direct-path capability while
// bare git status carries the repository-default read-only capability.
func TestDirectPathGitStatusCapabilityRequiresExactRawPlan(t *testing.T) {
	t.Parallel()

	for _, testCase := range directPathGitStatusCapabilityCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			result := Classify(activeWorker(testCase.command))
			if result.Decision != testCase.wantDecision {
				t.Fatalf("%q: decision=%q, want %q; diagnostic=%#v", testCase.command, result.Decision, testCase.wantDecision, result.Diagnostic)
			}
			if testCase.wantDiagnosticCode != "" && (result.Diagnostic == nil || result.Diagnostic.Code != testCase.wantDiagnosticCode) {
				t.Fatalf("%q: diagnostic=%#v, want code %q", testCase.command, result.Diagnostic, testCase.wantDiagnosticCode)
			}
			if testCase.wantCapability != "" {
				if len(result.Capabilities) != 1 || result.Capabilities[0] != testCase.wantCapability {
					t.Fatalf("%q: capabilities=%v, want [%s]", testCase.command, result.Capabilities, testCase.wantCapability)
				}
				return
			}
			if len(result.Capabilities) != 0 {
				t.Fatalf("%q: capabilities=%v, want none", testCase.command, result.Capabilities)
			}
		})
	}
}

// TestInstalledBinaryEmitsDirectPathGitStatusCapability verifies the shipped
// planner preserves the direct-path capability without a provider reparse.
//
// Example: /tmp/fake-bin/git status emits the exact singleton capability.
func TestInstalledBinaryEmitsDirectPathGitStatusCapability(t *testing.T) {
	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}

	for _, testCase := range directPathGitStatusCapabilityCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			input, err := json.Marshal(activeWorker(testCase.command))
			if err != nil {
				t.Fatalf("marshal %q request: %v", testCase.command, err)
			}

			var stdout bytes.Buffer
			status := runBinary(t, binary, input, &stdout)
			var result Result
			if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
				t.Fatalf("decode %q response: %v; output=%s", testCase.command, err, stdout.String())
			}
			if result.Decision != testCase.wantDecision {
				t.Fatalf("%q: decision=%q, want %q; diagnostic=%#v", testCase.command, result.Decision, testCase.wantDecision, result.Diagnostic)
			}
			if testCase.wantCapability != "" {
				if status != StatusAllow {
					t.Fatalf("%q: status=%d output=%s, want %d", testCase.command, status, stdout.String(), StatusAllow)
				}
				want := "{\"decision\":\"allow\",\"capabilities\":[\"" + string(testCase.wantCapability) + "\"]}\n"
				if stdout.String() != want {
					t.Fatalf("%q: JSON=%s, want %s", testCase.command, stdout.String(), want)
				}
				return
			}
			if len(result.Capabilities) != 0 {
				t.Fatalf("%q: capabilities=%v, want none", testCase.command, result.Capabilities)
			}
			if testCase.wantDecision == DecisionDeny && status != StatusDeny {
				t.Fatalf("%q: status=%d output=%s, want %d", testCase.command, status, stdout.String(), StatusDeny)
			}
			if testCase.wantDecision == DecisionDefer && status != StatusDefer {
				t.Fatalf("%q: status=%d output=%s, want %d", testCase.command, status, stdout.String(), StatusDefer)
			}
		})
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
		{name: "worker lifecycle control", role: RoleWorker, command: "eci-active status", decision: DecisionDeny, code: CodeControlOwnerRequired},
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

// TestActiveWorkerUnwrappedLifecycleIdentityDeniesCopies verifies that the
// planner applies lifecycle ownership after transparent wrapper unwrapping.
//
// Example: env FOO=bar /tmp/eci-active-copy status is worker control, not
// ordinary env work.
func TestActiveWorkerUnwrappedLifecycleIdentityDeniesCopies(t *testing.T) {
	if os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_SYMLINK_CASE") == "1" {
		runLifecycleIdentitySymlinkScenario(t)
		return
	}

	source := filepath.Join(providerHome(ProviderCodex), "bin", "eci-active")
	contents, err := os.ReadFile(source)
	if err != nil {
		t.Fatalf("read canonical lifecycle executable: %v", err)
	}
	info, err := os.Stat(source)
	if err != nil {
		t.Fatalf("stat canonical lifecycle executable: %v", err)
	}
	directory := t.TempDir()
	providerRoot := filepath.Join(directory, "provider-root")
	providerBin := filepath.Join(providerRoot, "bin")
	if err := os.MkdirAll(providerBin, 0o755); err != nil {
		t.Fatalf("create provider bin: %v", err)
	}
	canonicalActive := filepath.Join(providerBin, "eci-active")
	if err := os.WriteFile(canonicalActive, contents, info.Mode().Perm()); err != nil {
		t.Fatalf("write canonical lifecycle executable: %v", err)
	}
	for _, alias := range []string{"eci-review-gate", "eci-stage"} {
		path := filepath.Join(providerBin, alias)
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatalf("write canonical %s: %v", alias, err)
		}
	}
	providerAlias := filepath.Join(directory, "provider-home-alias")
	if err := os.Symlink(providerRoot, providerAlias); err != nil {
		t.Fatalf("create provider home alias: %v", err)
	}
	copyPath := filepath.Join(directory, "eci-active-copy")
	if err := os.WriteFile(copyPath, contents, info.Mode().Perm()); err != nil {
		t.Fatalf("write lifecycle copy: %v", err)
	}
	ordinaryPath := filepath.Join(directory, "ordinary-worker")
	if err := os.WriteFile(ordinaryPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write ordinary worker: %v", err)
	}
	arbitraryStage := filepath.Join(directory, "eci-stage")
	arbitraryReviewGate := filepath.Join(directory, "eci-review-gate")
	for _, path := range []string{arbitraryStage, arbitraryReviewGate} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatalf("write arbitrary basename control: %v", err)
		}
	}

	child := exec.Command(os.Args[0], "-test.run=^TestActiveWorkerUnwrappedLifecycleIdentityDeniesCopies$")
	child.Env = append(
		os.Environ(),
		"ECI_TEST_LIFECYCLE_IDENTITY_SYMLINK_CASE=1",
		"CODEX_HOME="+providerAlias+string(filepath.Separator),
		"ECI_TEST_LIFECYCLE_IDENTITY_DIRECTORY="+directory,
		"ECI_TEST_LIFECYCLE_IDENTITY_COPY="+copyPath,
		"ECI_TEST_LIFECYCLE_IDENTITY_ORDINARY="+ordinaryPath,
		"ECI_TEST_LIFECYCLE_IDENTITY_ARBITRARY_STAGE="+arbitraryStage,
		"ECI_TEST_LIFECYCLE_IDENTITY_ARBITRARY_REVIEW_GATE="+arbitraryReviewGate,
	)
	output, err := child.CombinedOutput()
	if err != nil {
		t.Fatalf("run symlink-home lifecycle identity scenario: %v\n%s", err, output)
	}
}

// runLifecycleIdentitySymlinkScenario verifies lifecycle identity after a
// child process configures CODEX_HOME as a symlink with a trailing separator.
//
// Example: env -- <symlink-home>/bin/eci-active status stays worker control.
func runLifecycleIdentitySymlinkScenario(t *testing.T) {
	directory := os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_DIRECTORY")
	copyPath := os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_COPY")
	ordinaryPath := os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_ORDINARY")
	arbitraryStage := os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_ARBITRARY_STAGE")
	arbitraryReviewGate := os.Getenv("ECI_TEST_LIFECYCLE_IDENTITY_ARBITRARY_REVIEW_GATE")
	for name, value := range map[string]string{
		"directory":             directory,
		"copy":                  copyPath,
		"ordinary":              ordinaryPath,
		"arbitrary stage":       arbitraryStage,
		"arbitrary review gate": arbitraryReviewGate,
	} {
		if value == "" {
			t.Fatalf("missing symlink lifecycle test %s", name)
		}
	}

	providerBin := filepath.Join(providerHome(ProviderCodex), "bin")
	protectedCommands := []struct {
		name    string
		command string
	}{
		{name: "copied env no args", command: "env " + copyPath},
		{name: "copied timeout no args", command: "timeout 5 " + copyPath},
		{name: "copied direct status", command: copyPath + " status"},
		{name: "copied direct nested exit", command: copyPath + " nested-exit"},
		{name: "copied env assignment", command: "env FOO=bar " + copyPath + " status"},
		{name: "copied env separator", command: "env -- " + copyPath + " status"},
		{name: "copied env isolated", command: "env -i " + copyPath + " nested-exit"},
		{name: "copied env unset", command: "env -u PATH " + copyPath + " status"},
		{name: "copied stdbuf", command: "stdbuf -oL " + copyPath + " status"},
		{name: "copied busybox", command: "busybox -- " + copyPath + " status"},
		{name: "copied prlimit", command: "prlimit --nofile=1024 " + copyPath + " status"},
		{name: "copied chronic", command: "chronic " + copyPath + " status"},
		{name: "canonical active env no args", command: "env " + filepath.Join(providerBin, "eci-active")},
		{name: "canonical active", command: filepath.Join(providerBin, "eci-active") + " status"},
		{name: "canonical active env", command: "env FOO=bar " + filepath.Join(providerBin, "eci-active") + " status"},
		{name: "canonical review gate", command: filepath.Join(providerBin, "eci-review-gate") + " status"},
		{name: "canonical stage", command: filepath.Join(providerBin, "eci-stage") + " status"},
	}
	ordinaryCommands := []struct {
		name    string
		command string
	}{
		{name: "ordinary direct", command: ordinaryPath},
		{name: "ordinary env assignment", command: "env FOO=bar " + ordinaryPath},
		{name: "ordinary env separator", command: "env -- " + ordinaryPath},
		{name: "ordinary env isolated", command: "env -i " + ordinaryPath},
		{name: "ordinary env unset", command: "env -u PATH " + ordinaryPath},
		{name: "ordinary stdbuf", command: "stdbuf -oL " + ordinaryPath},
		{name: "ordinary busybox", command: "busybox -- " + ordinaryPath},
		{name: "ordinary prlimit", command: "prlimit --nofile=1024 " + ordinaryPath},
		{name: "ordinary chronic", command: "chronic " + ordinaryPath},
		{name: "arbitrary eci stage basename", command: arbitraryStage + " status"},
		{name: "arbitrary eci review gate basename", command: arbitraryReviewGate + " status"},
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		for _, testCase := range protectedCommands {
			testCase := testCase
			t.Run(string(provider)+"/protected/"+testCase.name, func(t *testing.T) {
				request := activeWorker(testCase.command)
				request.Provider = provider
				request.CWD = directory
				result := Classify(request)
				if result.Decision != DecisionDeny || result.Diagnostic == nil {
					t.Fatalf("%q: decision=%q diagnostic=%#v, want worker lifecycle denial", testCase.command, result.Decision, result.Diagnostic)
				}
				if result.Diagnostic.Code != CodeControlOwnerRequired || result.Diagnostic.Operation != "worker-control" || result.Diagnostic.Predicate != "worker-lifecycle-control" {
					t.Fatalf("%q: diagnostic=%#v, want worker lifecycle control denial", testCase.command, result.Diagnostic)
				}
				if len(result.Capabilities) != 0 {
					t.Fatalf("%q: capabilities=%v, want none for protected lifecycle control", testCase.command, result.Capabilities)
				}
			})
		}
		for _, testCase := range ordinaryCommands {
			testCase := testCase
			t.Run(string(provider)+"/ordinary/"+testCase.name, func(t *testing.T) {
				request := activeWorker(testCase.command)
				request.Provider = provider
				request.CWD = directory
				result := Classify(request)
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: decision=%q diagnostic=%#v, want ordinary wrapped allow", testCase.command, result.Decision, result.Diagnostic)
				}
			})
		}
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

			lifecycleSemicolon := activeWorker("printf left; eci-active status")
			lifecycleSemicolon.Provider = provider
			lifecycleSemicolonResult := Classify(lifecycleSemicolon)
			if lifecycleSemicolonResult.Decision != DecisionDeny || lifecycleSemicolonResult.Diagnostic == nil {
				t.Fatalf("lifecycle semicolon plan: decision=%q diagnostic=%#v, want worker lifecycle denial", lifecycleSemicolonResult.Decision, lifecycleSemicolonResult.Diagnostic)
			}
			if lifecycleSemicolonResult.Diagnostic.Code != CodeControlOwnerRequired || lifecycleSemicolonResult.Diagnostic.Segment != 2 || lifecycleSemicolonResult.Diagnostic.Predicate != "worker-lifecycle-control" {
				t.Fatalf("lifecycle semicolon diagnostic: got %#v, want worker-lifecycle-control at segment 2", lifecycleSemicolonResult.Diagnostic)
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
		{name: "quoted executable", command: `ch"mod" 755 hooks/pre-commit-go-mod.sh`, marker: MarkerActive},
		{name: "quoted mode", command: `chmod "755" hooks/pre-commit-go-mod.sh`, marker: MarkerActive},
		{name: "quoted target", command: `chmod 755 "hooks/pre-commit-go-mod.sh"`, marker: MarkerActive},
		{name: "another target", command: "chmod 755 hooks/install-pre-commit-go-mod.sh", marker: MarkerActive},
		{name: "and compound", command: command + " && printf after", marker: MarkerActive},
		{name: "semicolon compound", command: "printf before; " + command, marker: MarkerActive},
		{name: "pipeline compound", command: command + " | printf after", marker: MarkerActive},
		{name: "pipeline preceding compound", command: "printf before | " + command, marker: MarkerActive},
		{name: "interpreter wrapper", command: "bash -c '" + command + "'", marker: MarkerActive},
		{name: "inactive exact", command: command, marker: MarkerInactive},
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			providerRoot := providerHome(provider)

			worker := Classify(Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           providerRoot,
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
				CWD:           providerRoot,
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
						CWD:           providerRoot,
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

func TestActiveWorkerProtectedHookModeMutationsUseGenericControlDenial(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			providerRoot := providerHome(provider)

			for _, command := range []string{
				"env chmod 755 hooks/pre-commit-go-mod.sh",
				"command chmod 755 hooks/pre-commit-go-mod.sh",
				`ch"mod" 755 hooks/pre-commit-go-mod.sh`,
				`ch"mod" 644 hooks/pre-commit-go-mod.sh`,
				`chmod "755" hooks/pre-commit-go-mod.sh`,
				`chmod 755 "hooks/pre-commit-go-mod.sh"`,
				"/bin/chmod 755 hooks/pre-commit-go-mod.sh",
				"chmod 755 ./hooks/pre-commit-go-mod.sh",
				"chmod 644 hooks/pre-commit-go-mod.sh",
				"chmod 755 hooks/install-pre-commit-go-mod.sh",
				"chmod 644 hooks/validate-bash.sh",
				"chmod 755 hooks/tests/test-pre-commit-go-mod.sh",
				"chmod 644 " + filepath.Join(providerRoot, "hooks", "validate-bash.sh"),
				"stdbuf -oL chmod 644 hooks/validate-bash.sh",
				"busybox chmod 644 hooks/validate-bash.sh",
				"busybox -- chmod 644 hooks/validate-bash.sh",
				"chmod -R 644 hooks",
				"chmod --recursive 644 hooks",
				"chmod -R 644 .",
				"chmod -R 644 ..",
				"chmod -vR 644 hooks",
				"chmod --rec 755 hooks",
				"chmod 755 -R hooks",
				"chmod 755 --rec hooks",
				"chmod 755 --recursive hooks",
				"chmod 755 -vR hooks",
				"chmod 755 hooks --rec",
				"chmod 755 hooks -R",
				"chmod --ref ordinary.txt hooks/validate-bash.sh",
				"chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"chmod hooks/validate-bash.sh --ref=ordinary.txt",
				"chmod --ref ordinary.txt -R hooks",
				"chmod -R --ref=ordinary.txt hooks",
				"env chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"stdbuf -oL chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"busybox -- chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"stdbuf -oL chmod --rec 755 hooks",
				"busybox -- chmod 755 hooks --rec",
				"stdbuf -oL chmod -R 644 hooks",
				"busybox -- chmod --recursive 644 hooks",
			} {
				command := command
				t.Run(command, func(t *testing.T) {
					t.Parallel()

					result := Classify(Request{
						Provider:      provider,
						Role:          RoleWorker,
						CWD:           providerRoot,
						Marker:        MarkerActive,
						ActiveSession: "test-session",
						Command:       command,
					})
					if result.Decision != DecisionDeny || result.Diagnostic == nil {
						t.Fatalf("decision: got %q diagnostic=%#v, want generic denial", result.Decision, result.Diagnostic)
					}
					if result.Diagnostic.Code != CodeControlOwnerRequired {
						t.Errorf("code: got %q, want %q", result.Diagnostic.Code, CodeControlOwnerRequired)
					}
					if result.Diagnostic.Operation != "worker-control" {
						t.Errorf("operation: got %q, want worker-control", result.Diagnostic.Operation)
					}
					if result.Diagnostic.Predicate != "worker-hook-mode-ownership" {
						t.Errorf("predicate: got %q, want worker-hook-mode-ownership", result.Diagnostic.Predicate)
					}
				})
			}
		})
	}
}

// TestChmodOptionIsRecursiveRecognizesOnlyGNUUnambiguousLongAbbreviations verifies that only
// the unique GNU prefixes of --recursive enable recursive protected-target detection.
//
// Example: --rec enables recursion while ambiguous --re does not.
func TestChmodOptionIsRecursiveRecognizesOnlyGNUUnambiguousLongAbbreviations(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"--rec",
		"--recu",
		"--recur",
		"--recurs",
		"--recursi",
		"--recursiv",
		"--recursive",
	} {
		if !chmodOptionIsRecursive(value) {
			t.Errorf("%q: got false, want true", value)
		}
	}
	for _, value := range []string{
		"--",
		"--r",
		"--re",
		"--reference",
		"--rec=ursive",
		"--recursion",
		"--recursive=value",
	} {
		if chmodOptionIsRecursive(value) {
			t.Errorf("%q: got true, want false", value)
		}
	}
}

// TestChmodOptionIsReferenceRecognizesOnlyGNUUnambiguousLongAbbreviations verifies that only
// the unique GNU prefixes of --reference select a reference source operand.
//
// Example: --ref=source selects a reference source while ambiguous --re=source does not.
func TestChmodOptionIsReferenceRecognizesOnlyGNUUnambiguousLongAbbreviations(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"--ref",
		"--refe",
		"--refer",
		"--refere",
		"--referen",
		"--referenc",
		"--reference",
		"--ref=source",
		"--reference=source",
	} {
		if !chmodOptionIsReference(value) {
			t.Errorf("%q: got false, want true", value)
		}
	}
	for _, value := range []string{
		"--",
		"--r",
		"--re",
		"--re=source",
		"--rec",
		"--referencee",
		"--referee=source",
		"--ref=",
		"--reference=",
	} {
		if chmodOptionIsReference(value) {
			t.Errorf("%q: got true, want false", value)
		}
	}
}

// TestChmodMutationTargetsSeparatesGNUReferenceSources verifies that GNU reference operands
// never appear in the mutation-target set, including when the option follows a target.
//
// Example: chmod hooks/validate-bash.sh --ref=ordinary.txt mutates the hook path.
func TestChmodMutationTargetsSeparatesGNUReferenceSources(t *testing.T) {
	t.Parallel()

	for _, testCase := range []struct {
		name      string
		argv      []token
		targets   []string
		recursive bool
	}{
		{
			name: "inline abbreviated reference",
			argv: []token{
				{value: "chmod"},
				{value: "--ref=hooks/validate-bash.sh"},
				{value: "ordinary.txt"},
			},
			targets: []string{"ordinary.txt"},
		},
		{
			name: "separate abbreviated reference",
			argv: []token{
				{value: "chmod"},
				{value: "--ref"},
				{value: "hooks/validate-bash.sh"},
				{value: "ordinary.txt"},
			},
			targets: []string{"ordinary.txt"},
		},
		{
			name: "reference after target",
			argv: []token{
				{value: "chmod"},
				{value: "hooks/validate-bash.sh"},
				{value: "--ref=ordinary.txt"},
			},
			targets: []string{"hooks/validate-bash.sh"},
		},
		{
			name: "recursive reference source",
			argv: []token{
				{value: "chmod"},
				{value: "-R"},
				{value: "--ref=hooks/validate-bash.sh"},
				{value: "ordinary-dir"},
			},
			targets:   []string{"ordinary-dir"},
			recursive: true,
		},
		{
			name: "end of options keeps abbreviation literal",
			argv: []token{
				{value: "chmod"},
				{value: "755"},
				{value: "--"},
				{value: "--ref"},
				{value: "hooks"},
			},
			targets: []string{"--ref", "hooks"},
		},
	} {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			targets, recursive := chmodMutationTargets(testCase.argv)
			if recursive != testCase.recursive {
				t.Fatalf("recursive: got %t, want %t", recursive, testCase.recursive)
			}
			if len(targets) != len(testCase.targets) {
				t.Fatalf("target count: got %d (%#v), want %d (%#v)", len(targets), targets, len(testCase.targets), testCase.targets)
			}
			for index, target := range targets {
				if target.value != testCase.targets[index] {
					t.Errorf("target %d: got %q, want %q", index, target.value, testCase.targets[index])
				}
			}
		})
	}
}

func TestActiveCoordinatorProtectedHookModeMutationsDefer(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			providerRoot := providerHome(provider)

			for _, command := range []string{
				"chmod 644 hooks/validate-bash.sh",
				`chmod "644" hooks/pre-commit-go-mod.sh`,
				"chmod 755 hooks/pre-commit-go-mod.sh && printf after",
				"env chmod 644 hooks/validate-bash.sh",
				"stdbuf -oL chmod 644 hooks/validate-bash.sh",
				"busybox -- chmod 644 hooks/validate-bash.sh",
				"chmod -R 644 hooks",
				"chmod --recursive 644 hooks",
				"chmod -R 644 .",
				"chmod -R 644 ..",
				"chmod -vR 644 hooks",
				"chmod --rec 755 hooks",
				"chmod 755 -R hooks",
				"chmod 755 --rec hooks",
				"chmod 755 --recursive hooks",
				"chmod 755 -vR hooks",
				"chmod 755 hooks --rec",
				"chmod 755 hooks -R",
				"chmod --ref ordinary.txt hooks/validate-bash.sh",
				"chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"chmod hooks/validate-bash.sh --ref=ordinary.txt",
				"chmod --ref ordinary.txt -R hooks",
				"chmod -R --ref=ordinary.txt hooks",
				"env chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"stdbuf -oL chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"busybox -- chmod --ref=ordinary.txt hooks/validate-bash.sh",
				"stdbuf -oL chmod --rec 755 hooks",
				"busybox -- chmod 755 hooks --rec",
				"stdbuf -oL chmod -R 644 hooks",
				"busybox -- chmod --recursive 644 hooks",
			} {
				command := command
				t.Run(command, func(t *testing.T) {
					t.Parallel()

					result := Classify(Request{
						Provider:      provider,
						Role:          RoleCoordinator,
						CWD:           providerRoot,
						Marker:        MarkerActive,
						ActiveSession: "test-session",
						Command:       command,
					})
					if result.Decision != DecisionDefer || result.Diagnostic != nil {
						t.Fatalf("decision: got %q diagnostic=%#v, want defer without diagnostic", result.Decision, result.Diagnostic)
					}
				})
			}
		})
	}
}

func TestActiveWorkerAllowsSameNamedHookPathOutsideProviderRoot(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range []string{
				"chmod 644 hooks/validate-bash.sh",
				"chmod -R 644 .",
			} {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/tmp",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: decision: got %q diagnostic=%#v, want allow without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}
		})
	}
}

func TestActiveWorkerOrdinaryChmodRemainsAllowed(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			providerRoot := providerHome(provider)

			for _, command := range []string{
				"chmod 644 ordinary.txt",
				"chmod -R 644 ordinary-dir",
				"chmod 644 -R ordinary-dir",
				"chmod 644 ordinary-dir -R",
				"chmod --rec 644 ordinary-dir",
				"chmod 755 -- -R hooks",
				"chmod 755 hooks -- -R",
				"chmod 755 hooks -- --rec",
				"chmod --ref=hooks/validate-bash.sh ordinary.txt",
				"chmod --ref hooks/validate-bash.sh ordinary.txt",
				"chmod ordinary.txt --ref=hooks/validate-bash.sh",
				"chmod -R --ref=hooks/validate-bash.sh ordinary-dir",
				"chmod --reference=hooks/validate-bash.sh ordinary.txt",
				"chmod -R --reference=hooks/validate-bash.sh ordinary-dir",
				"chmod --reference hooks/validate-bash.sh ordinary.txt",
				"chmod -R --reference hooks/validate-bash.sh ordinary-dir",
			} {
				result := Classify(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           providerRoot,
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: decision: got %q diagnostic=%#v, want allow without diagnostic", command, result.Decision, result.Diagnostic)
				}
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
