package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestProviderInstallUsesOneHardLinkedImplementation(t *testing.T) {
	t.Parallel()

	codexRoot := providerHome(ProviderCodex)
	kimiRoot := providerHome(ProviderKimi)
	for _, name := range []string{
		"go.mod",
		"classifier.go",
		"main.go",
		"classifier_test.go",
		"oracle_parity_test.go",
		"provider_integration_test.go",
		"eci-command-plan",
	} {
		codexPath := filepath.Join(codexRoot, "hooks", "lib", "eci-command-plan-go", name)
		kimiPath := filepath.Join(kimiRoot, "hooks", "lib", "eci-command-plan-go", name)
		assertSameFile(t, codexPath, kimiPath)
		if name == "eci-command-plan" {
			info, err := os.Stat(codexPath)
			if err != nil {
				t.Fatalf("stat installed binary: %v", err)
			}
			if permission := info.Mode().Perm(); permission != 0o755 {
				t.Errorf("installed binary mode: got %04o, want 0755", permission)
			}
		}
	}
}

func TestProviderValidatorsUseCompiledJSONInterface(t *testing.T) {
	t.Parallel()

	for _, validator := range []string{
		filepath.Join(providerHome(ProviderCodex), "hooks", "validate-bash.sh"),
		filepath.Join(providerHome(ProviderKimi), "hooks", "validate-bash.sh"),
	} {
		source, err := os.ReadFile(validator)
		if err != nil {
			t.Fatalf("read %s: %v", validator, err)
		}
		text := string(source)
		if !strings.Contains(text, `lib/eci-command-plan-go/eci-command-plan`) {
			t.Errorf("%s does not invoke the compiled classifier", validator)
		}
		if strings.Contains(text, `python3 "$HOOK_DIR/lib/eci-command-plan.py"`) {
			t.Errorf("%s still invokes the Python classifier at runtime", validator)
		}
		for _, field := range []string{
			`provider:$provider`,
			`role:$role`,
			`active_markers:$ARGS.positional`,
		} {
			if !strings.Contains(text, field) {
				t.Errorf("%s JSON request is missing %s", validator, field)
			}
		}
	}
}

// TestProviderValidatorsRouteRepositoryDefaultGitArchiveThroughPlannerCapability
// verifies that each provider's archive-routing region trusts only the compiled
// planner's exact capability and does not locally re-parse archive commands.
//
// Example: `git archive HEAD` reaches the worker fast path only when the
// planner reports the repository-default archive capability.
func TestProviderValidatorsRouteRepositoryDefaultGitArchiveThroughPlannerCapability(t *testing.T) {
	t.Parallel()

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			validator := filepath.Join(providerHome(provider), "hooks", "validate-bash.sh")
			source, err := os.ReadFile(validator)
			if err != nil {
				t.Fatalf("read %s: %v", validator, err)
			}

			region := archiveRoutingRegion(t, string(source))
			if strings.Contains(region, "python3") {
				t.Errorf("%s archive-routing region still launches python3", validator)
			}
			if !strings.Contains(region, "repository_default_git_archive_capability()") {
				t.Errorf("%s archive-routing region has no repository-default archive capability helper", validator)
			}
			if !strings.Contains(region, "if repository_default_git_archive_capability; then") {
				t.Errorf("%s archive-routing region does not call the archive capability helper", validator)
			}
			if !strings.Contains(region, `.["decision"]`) && !strings.Contains(region, `.decision == "allow"`) {
				t.Errorf("%s archive capability helper does not inspect the planner decision", validator)
			}
			if !strings.Contains(region, `.capabilities == ["repository-default-git-archive"]`) {
				t.Errorf("%s archive capability helper does not require the exact singleton capability", validator)
			}
			if !strings.Contains(region, "trusted_executable_on_path git") {
				t.Errorf("%s archive capability helper does not require the trusted git executable", validator)
			}

			contextSafe := "CODEX_GIT_STATUS_CONTEXT_SAFE"
			if provider == ProviderKimi {
				contextSafe = "KIMI_GIT_STATUS_CONTEXT_SAFE"
			}
			if !strings.Contains(region, contextSafe) {
				t.Errorf("%s archive capability helper does not require %s", validator, contextSafe)
			}
		})
	}
}

// TestInstalledProviderValidatorsUseRepositoryDefaultGitArchiveCapability
// verifies the installed validators admit only the exact planner capability.
// Exact positives take the traced capability-helper fast path; near misses
// retain a protected route and never become fast-path candidates.
//
// Example: `git archive --format=tar --output=artifact.tar HEAD` emits no hook
// output and reaches the worker fast path, unlike
// `git archive --remote=origin HEAD`.
func TestInstalledProviderValidatorsUseRepositoryDefaultGitArchiveCapability(t *testing.T) {
	stracePath, err := exec.LookPath("strace")
	if err != nil {
		t.Fatalf("find strace for installed validator archive-route tracing: %v", err)
	}
	bashPath, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("find bash: %v", err)
	}

	testCases := []struct {
		name                  string
		command               string
		wantFastPath          bool
		wantLegacyGitRoute    bool
		targetsActiveMarker   bool
		wantLiveControlDenial bool
		fakeFirstGitOnPath    bool
		inheritedGitDirectory bool
	}{
		{
			name:         "direct HEAD",
			command:      "git archive HEAD",
			wantFastPath: true,
		},
		{
			name:                  "active marker output",
			command:               "git archive --format=tar --output=<active-marker> HEAD",
			targetsActiveMarker:   true,
			wantLiveControlDenial: true,
		},
		{
			name:         "exact tar output",
			command:      "git archive --format=tar --output=artifact.tar HEAD",
			wantFastPath: true,
		},
		{
			name:    "environment wrapper",
			command: "env git archive HEAD",
		},
		{
			name:    "compound",
			command: "git archive HEAD && printf after",
		},
		{
			name:    "repository context",
			command: "git -C /tmp archive HEAD",
		},
		{
			name:               "remote attached",
			command:            "git archive --remote=origin HEAD",
			wantLegacyGitRoute: true,
		},
		{
			name:               "remote split",
			command:            "git archive --remote origin HEAD",
			wantLegacyGitRoute: true,
		},
		{
			name:               "exec attached",
			command:            "git archive --exec=git-upload-archive HEAD",
			wantLegacyGitRoute: true,
		},
		{
			name:               "exec split",
			command:            "git archive --exec git-upload-archive HEAD",
			wantLegacyGitRoute: true,
		},
		{
			name:               "output inference",
			command:            "git archive --output=artifact.tar HEAD",
			wantLegacyGitRoute: true,
		},
		{
			name:               "fake first git on original PATH",
			command:            "git archive HEAD",
			wantLegacyGitRoute: true,
			fakeFirstGitOnPath: true,
		},
		{
			name:                  "inherited GIT_DIR",
			command:               "git archive HEAD",
			wantLegacyGitRoute:    true,
			inheritedGitDirectory: true,
		},
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		for _, testCase := range testCases {
			testCase := testCase
			t.Run(string(provider)+"/"+testCase.name, func(t *testing.T) {
				stdout, trace, shellTrace := runInstalledProviderArchiveValidator(
					t,
					stracePath,
					bashPath,
					provider,
					testCase.command,
					testCase.targetsActiveMarker,
					testCase.fakeFirstGitOnPath,
					testCase.inheritedGitDirectory,
				)

				if processTraceExecutesGit(trace) {
					t.Errorf("%s %q executed Git while validating only:\n%s", provider, testCase.command, gitExecutionTrace(trace))
				}

				if testCase.wantFastPath {
					if stdout != "" {
						t.Errorf("%s %q emitted hook output for an exact archive capability: %s", provider, testCase.command, stdout)
					}
					if !archiveCapabilityFastPathTrace(shellTrace) {
						t.Errorf("%s %q did not reach the capability-helper fast path:\n%s", provider, testCase.command, archiveRoutingShellTrace(shellTrace))
					}
					return
				}

				if xtraceContainsCommand(parseBashXTrace(shellTrace), "worker_fast_path_candidate=true") {
					t.Errorf("%s %q unexpectedly became a capability fast-path candidate:\n%s", provider, testCase.command, archiveRoutingShellTrace(shellTrace))
				}
				if testCase.wantLiveControlDenial && !strings.Contains(stdout, string(CodePlanLiveControlDenied)) {
					t.Errorf("%s %q did not report the required live-control denial: %s", provider, testCase.command, stdout)
				}
				if testCase.wantLegacyGitRoute && !archiveCapabilityLegacyGitRouteTrace(shellTrace) {
					t.Errorf("%s %q did not retain the legacy Git route after capability rejection:\n%s", provider, testCase.command, archiveRoutingShellTrace(shellTrace))
				}
			})
		}
	}
}

func TestInstalledBinaryProviderParity(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		request := activeWorker("printf before | env | printf after")
		request.Provider = provider
		input, err := json.Marshal(request)
		if err != nil {
			t.Fatalf("marshal %s request: %v", provider, err)
		}

		var stdout bytes.Buffer
		status := runBinary(t, binary, input, &stdout)
		if status != StatusDeny {
			t.Fatalf("%s status: got %d, want %d; output=%s", provider, status, StatusDeny, stdout.String())
		}
		var result Result
		if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
			t.Fatalf("decode %s result: %v", provider, err)
		}
		if result.Diagnostic == nil || result.Diagnostic.Code != CodeEnvironmentEnumerationDenied {
			t.Fatalf("%s diagnostic: %#v", provider, result.Diagnostic)
		}
	}
}

func TestInstalledBinaryRoutesActivePreCommitHookModeRepairByRole(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
	const command = "chmod 755 hooks/pre-commit-go-mod.sh"
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			providerRoot := providerHome(provider)

			workerRequest := Request{
				Provider:      provider,
				Role:          RoleWorker,
				CWD:           providerRoot,
				Marker:        MarkerActive,
				ActiveSession: "test-session",
				Command:       command,
			}
			workerInput, err := json.Marshal(workerRequest)
			if err != nil {
				t.Fatalf("marshal worker request: %v", err)
			}
			var workerOutput bytes.Buffer
			workerStatus := runBinary(t, binary, workerInput, &workerOutput)
			if workerStatus != StatusDeny {
				t.Fatalf("worker status: got %d, want %d; output=%s", workerStatus, StatusDeny, workerOutput.String())
			}
			var workerResult Result
			if err := json.Unmarshal(workerOutput.Bytes(), &workerResult); err != nil {
				t.Fatalf("decode worker result: %v", err)
			}
			if workerResult.Decision != DecisionDeny || workerResult.Diagnostic == nil {
				t.Fatalf("worker result: decision=%q diagnostic=%#v, want deny with diagnostic", workerResult.Decision, workerResult.Diagnostic)
			}
			diagnostic := workerResult.Diagnostic
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

			coordinatorRequest := workerRequest
			coordinatorRequest.Role = RoleCoordinator
			coordinatorInput, err := json.Marshal(coordinatorRequest)
			if err != nil {
				t.Fatalf("marshal coordinator request: %v", err)
			}
			var coordinatorOutput bytes.Buffer
			coordinatorStatus := runBinary(t, binary, coordinatorInput, &coordinatorOutput)
			if coordinatorStatus != StatusDefer {
				t.Fatalf("coordinator status: got %d, want %d; output=%s", coordinatorStatus, StatusDefer, coordinatorOutput.String())
			}
			var coordinatorResult Result
			if err := json.Unmarshal(coordinatorOutput.Bytes(), &coordinatorResult); err != nil {
				t.Fatalf("decode coordinator result: %v", err)
			}
			if coordinatorResult.Decision != DecisionDefer || coordinatorResult.Diagnostic != nil {
				t.Fatalf("coordinator result: decision=%q diagnostic=%#v, want defer without diagnostic", coordinatorResult.Decision, coordinatorResult.Diagnostic)
			}

			for _, testCase := range []struct {
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
			} {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					request := workerRequest
					request.Marker = testCase.marker
					request.Command = testCase.command
					input, err := json.Marshal(request)
					if err != nil {
						t.Fatalf("marshal request: %v", err)
					}
					var output bytes.Buffer
					status := runBinary(t, binary, input, &output)
					if status == StatusInternal {
						t.Fatalf("status: got internal error; output=%s", output.String())
					}
					var result Result
					if err := json.Unmarshal(output.Bytes(), &result); err != nil {
						t.Fatalf("decode result: %v", err)
					}
					if result.Diagnostic != nil && result.Diagnostic.Predicate == "hook-mode-repair" {
						t.Fatalf("%s selected hook-mode-repair: status=%d result=%#v", testCase.command, status, result)
					}
					if testCase.marker == MarkerInactive && (status != StatusAllow || result.Decision != DecisionAllow || result.Diagnostic != nil) {
						t.Fatalf("inactive exact command: status=%d result=%#v, want allow without diagnostic", status, result)
					}
				})
			}
		})
	}
}

func TestInstalledBinaryDeniesActiveWorkerProtectedHookModeMutations(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
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

					input, err := json.Marshal(Request{
						Provider:      provider,
						Role:          RoleWorker,
						CWD:           providerRoot,
						Marker:        MarkerActive,
						ActiveSession: "test-session",
						Command:       command,
					})
					if err != nil {
						t.Fatalf("marshal request: %v", err)
					}
					var output bytes.Buffer
					status := runBinary(t, binary, input, &output)
					if status != StatusDeny {
						t.Fatalf("status: got %d, want %d; output=%s", status, StatusDeny, output.String())
					}
					var result Result
					if err := json.Unmarshal(output.Bytes(), &result); err != nil {
						t.Fatalf("decode result: %v", err)
					}
					if result.Diagnostic == nil {
						t.Fatal("diagnostic: got nil, want generic control denial")
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

func TestInstalledBinaryDefersActiveCoordinatorProtectedHookModeMutations(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
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

					input, err := json.Marshal(Request{
						Provider:      provider,
						Role:          RoleCoordinator,
						CWD:           providerRoot,
						Marker:        MarkerActive,
						ActiveSession: "test-session",
						Command:       command,
					})
					if err != nil {
						t.Fatalf("marshal request: %v", err)
					}
					var output bytes.Buffer
					status := runBinary(t, binary, input, &output)
					if status != StatusDefer {
						t.Fatalf("status: got %d, want %d; output=%s", status, StatusDefer, output.String())
					}
					var result Result
					if err := json.Unmarshal(output.Bytes(), &result); err != nil {
						t.Fatalf("decode result: %v", err)
					}
					if result.Decision != DecisionDefer || result.Diagnostic != nil {
						t.Fatalf("result: decision=%q diagnostic=%#v, want defer without diagnostic", result.Decision, result.Diagnostic)
					}
				})
			}
		})
	}
}

func TestInstalledBinaryAllowsSameNamedHookPathOutsideProviderRoot(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, command := range []string{
				"chmod 644 hooks/validate-bash.sh",
				"chmod -R 644 .",
			} {
				input, err := json.Marshal(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           "/tmp",
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if err != nil {
					t.Fatalf("marshal request: %v", err)
				}
				var output bytes.Buffer
				status := runBinary(t, binary, input, &output)
				if status != StatusAllow {
					t.Fatalf("%q: status: got %d, want %d; output=%s", command, status, StatusAllow, output.String())
				}
				var result Result
				if err := json.Unmarshal(output.Bytes(), &result); err != nil {
					t.Fatalf("decode result: %v", err)
				}
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: result: decision=%q diagnostic=%#v, want allow without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}
		})
	}
}

func TestInstalledBinaryAllowsActiveWorkerOrdinaryChmod(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
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
				input, err := json.Marshal(Request{
					Provider:      provider,
					Role:          RoleWorker,
					CWD:           providerRoot,
					Marker:        MarkerActive,
					ActiveSession: "test-session",
					Command:       command,
				})
				if err != nil {
					t.Fatalf("marshal request: %v", err)
				}
				var output bytes.Buffer
				status := runBinary(t, binary, input, &output)
				if status != StatusAllow {
					t.Fatalf("%q: status: got %d, want %d; output=%s", command, status, StatusAllow, output.String())
				}
				var result Result
				if err := json.Unmarshal(output.Bytes(), &result); err != nil {
					t.Fatalf("decode result: %v", err)
				}
				if result.Decision != DecisionAllow || result.Diagnostic != nil {
					t.Fatalf("%q: result: decision=%q diagnostic=%#v, want allow without diagnostic", command, result.Decision, result.Diagnostic)
				}
			}
		})
	}
}

func TestInstalledBinaryDeniesActiveLedgerWritersForBothProviders(t *testing.T) {
	t.Parallel()

	binary, err := filepath.Abs("eci-command-plan")
	if err != nil {
		t.Fatalf("resolve installed binary: %v", err)
	}
	proofRoot := t.TempDir()
	sessionDir := filepath.Join(proofRoot, "proof", "session")
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		t.Fatalf("create active session: %v", err)
	}
	marker := filepath.Join(sessionDir, "eci_active")
	if err := os.WriteFile(marker, []byte("active\n"), 0o600); err != nil {
		t.Fatalf("write active marker: %v", err)
	}
	ordinaryRoot := t.TempDir()
	ordinaryPath := filepath.Join(ordinaryRoot, "ordinary.md")
	if err := os.WriteFile(ordinaryPath, []byte("ordinary\n"), 0o600); err != nil {
		t.Fatalf("write ordinary file: %v", err)
	}

	for _, provider := range []Provider{ProviderCodex, ProviderKimi} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()

			for _, name := range []string{"high_level_log.md", "high_level_log.anchor"} {
				name := name
				t.Run(name, func(t *testing.T) {
					path := filepath.Join(sessionDir, name)
					if err := os.WriteFile(path, []byte("ledger\n"), 0o600); err != nil {
						t.Fatalf("write %s: %v", name, err)
					}

					request := Request{
						Provider:      provider,
						Role:          RoleCoordinator,
						CWD:           proofRoot,
						Marker:        MarkerActive,
						ActiveSession: "session",
						Command:       "sed -i '1p' " + path,
						ActiveMarkers: []string{marker},
					}
					input, err := json.Marshal(request)
					if err != nil {
						t.Fatalf("marshal %s request: %v", name, err)
					}
					var stdout bytes.Buffer
					status := runBinary(t, binary, input, &stdout)
					if status != StatusDeny {
						t.Fatalf("%s status: got %d, want %d; output=%s", name, status, StatusDeny, stdout.String())
					}
					var result Result
					if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
						t.Fatalf("decode %s result: %v", name, err)
					}
					if result.Diagnostic == nil {
						t.Fatalf("%s diagnostic: missing diagnostic in %#v", name, result)
					}
					diagnostic := result.Diagnostic
					if diagnostic.Code != DiagnosticCode("ECI_LEDGER_APPEND_ONLY") {
						t.Errorf("%s code: got %q, want ECI_LEDGER_APPEND_ONLY", name, diagnostic.Code)
					}
					if diagnostic.Operation != "ledger-append-only" {
						t.Errorf("%s operation: got %q, want ledger-append-only", name, diagnostic.Operation)
					}
					if diagnostic.Path != path {
						t.Errorf("%s path: got %q, want %q", name, diagnostic.Path, path)
					}
					if diagnostic.Predicate != "append-only-ledger" {
						t.Errorf("%s predicate: got %q, want append-only-ledger", name, diagnostic.Predicate)
					}
					if diagnostic.Remediation != "use eci-active ledger-append" {
						t.Errorf("%s remediation: got %q, want use eci-active ledger-append", name, diagnostic.Remediation)
					}
				})
			}

			for _, testCase := range []struct {
				name    string
				command string
			}{
				{name: "ledger read", command: "sed -n '1p' " + filepath.Join(sessionDir, "high_level_log.md")},
				{name: "ordinary write", command: "touch " + ordinaryPath},
			} {
				testCase := testCase
				t.Run(testCase.name, func(t *testing.T) {
					request := Request{
						Provider:      provider,
						Role:          RoleCoordinator,
						CWD:           filepath.Join(proofRoot, "unrelated-cwd"),
						Marker:        MarkerActive,
						ActiveSession: "session",
						Command:       testCase.command,
						ActiveMarkers: []string{marker},
					}
					input, err := json.Marshal(request)
					if err != nil {
						t.Fatalf("marshal %s request: %v", testCase.name, err)
					}
					var stdout bytes.Buffer
					status := runBinary(t, binary, input, &stdout)
					if status != StatusAllow {
						t.Fatalf("%s status: got %d, want %d; output=%s", testCase.name, status, StatusAllow, stdout.String())
					}
				})
			}
		})
	}
}

// archiveRoutingRegion returns the capability helper and deferred Git route
// without including unrelated Python-based legacy routes elsewhere in a
// validator.
//
// Example: the returned region spans repository_default_git_archive_capability
// through deferred_route_git_shape.
func archiveRoutingRegion(t *testing.T, source string) string {
	t.Helper()

	const (
		helperDefinition = "repository_default_git_archive_capability() {"
		routeDefinition  = "deferred_route_git_shape() {"
	)
	if count := strings.Count(source, helperDefinition); count != 1 {
		t.Errorf("validator has %d repository-default archive capability helper definitions, want exactly one", count)
	}
	if count := strings.Count(source, routeDefinition); count != 1 {
		t.Errorf("validator has %d deferred Git route definitions, want exactly one", count)
	}

	gitRouteStart := strings.Index(source, routeDefinition)
	if gitRouteStart < 0 {
		t.Fatal("validator has no deferred_route_git_shape")
	}
	regionStart := strings.LastIndex(source[:gitRouteStart], helperDefinition)
	if regionStart < 0 {
		regionStart = gitRouteStart
	}
	regionEndOffset := strings.Index(source[gitRouteStart:], "\nliteral_git_mutation_shape() {")
	if regionEndOffset < 0 {
		t.Fatal("validator archive-routing region has no literal_git_mutation_shape boundary")
	}
	return source[regionStart : gitRouteStart+regionEndOffset]
}

// runInstalledProviderArchiveValidator runs one installed validator with an
// isolated active marker and a sanitized command environment, never executing
// the submitted Git command.
//
// Example: a test can observe whether `git archive HEAD` reaches the worker
// fast path by inspecting the hook output and process trace.
func runInstalledProviderArchiveValidator(
	t *testing.T,
	stracePath string,
	bashPath string,
	provider Provider,
	submittedCommand string,
	targetsActiveMarker bool,
	fakeFirstGitOnPath bool,
	inheritedGitDirectory bool,
) (string, string, string) {
	t.Helper()

	fixtureRoot := t.TempDir()
	workingDirectory := filepath.Join(fixtureRoot, "work")
	proofRoot := filepath.Join(fixtureRoot, "proof")
	homeDirectory := filepath.Join(fixtureRoot, "home")
	const sessionID = "archive-session"
	for _, directory := range []string{workingDirectory, homeDirectory, filepath.Join(proofRoot, sessionID)} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatalf("create fixture directory %s: %v", directory, err)
		}
	}
	marker := filepath.Join(proofRoot, sessionID, "eci_active")
	markerContents := strings.Join([]string{
		"scope: installed provider archive capability test",
		"cwd: " + workingDirectory,
		"session_id: " + sessionID,
		"created_utc: 2026-08-23T00:00:00Z",
		"",
	}, "\n")
	if err := os.WriteFile(marker, []byte(markerContents), 0o600); err != nil {
		t.Fatalf("write active marker: %v", err)
	}
	if targetsActiveMarker {
		submittedCommand = "git archive --format=tar --output=" + marker + " HEAD"
	}

	gitPath, err := exec.LookPath("git")
	if err != nil {
		t.Fatalf("find git: %v", err)
	}
	gitPath, err = filepath.EvalSymlinks(gitPath)
	if err != nil {
		t.Fatalf("resolve git path %s: %v", gitPath, err)
	}

	const systemPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	originalPath := systemPath
	if fakeFirstGitOnPath {
		fakeBin := filepath.Join(fixtureRoot, "fake-bin")
		if err := os.MkdirAll(fakeBin, 0o700); err != nil {
			t.Fatalf("create fake git directory: %v", err)
		}
		fakeGit := filepath.Join(fakeBin, "git")
		if err := os.WriteFile(fakeGit, []byte("#!/bin/sh\nexit 99\n"), 0o700); err != nil {
			t.Fatalf("write fake git: %v", err)
		}
		originalPath = fakeBin + ":" + systemPath
	}

	request := struct {
		SessionID string `json:"session_id"`
		CWD       string `json:"cwd"`
		ToolInput struct {
			Command string `json:"command"`
		} `json:"tool_input"`
	}{
		SessionID: sessionID,
		CWD:       workingDirectory,
	}
	request.ToolInput.Command = submittedCommand
	input, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal validator input: %v", err)
	}

	environment := []string{
		"HOME=" + homeDirectory,
		"PATH=" + originalPath,
		"TMPDIR=" + fixtureRoot,
		"LC_ALL=C",
		"CODEX_HOME=" + providerHome(ProviderCodex),
		"KIMI_CODE_HOME=" + providerHome(ProviderKimi),
		"CODEX_PROOF_ROOT=" + proofRoot,
		"KIMI_PROOF_ROOT=" + proofRoot,
		"codex_git_executable=" + gitPath,
		"PS4=+${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]-}: ",
	}
	if provider == ProviderCodex {
		environment = append(environment, "CODEX_ROLE=worker")
	} else {
		environment = append(environment, "KIMI_ROLE=worker")
	}
	if inheritedGitDirectory {
		environment = append(environment, "GIT_DIR="+filepath.Join(fixtureRoot, "inherited.git"))
	}

	tracePath := filepath.Join(fixtureRoot, "process.trace")
	validator := filepath.Join(providerHome(provider), "hooks", "validate-bash.sh")
	command := exec.Command(stracePath, "-f", "-e", "trace=process", "-o", tracePath, "--", bashPath, "-x", validator)
	command.Dir = workingDirectory
	command.Env = environment
	command.Stdin = bytes.NewReader(input)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		t.Fatalf("run %s for %q: %v; stderr=%s; stdout=%s", validator, submittedCommand, err, stderr.String(), stdout.String())
	}
	trace, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatalf("read process trace: %v", err)
	}
	return stdout.String(), string(trace), stderr.String()
}

// bashXTraceEvent records one function-scoped Bash xtrace event. The test
// fixture sets PS4 so route decisions can be asserted without relying on
// unrelated validator output.
type bashXTraceEvent struct {
	function string
	command  string
}

// parseBashXTrace parses the PS4 format used by the installed validator test.
//
// Example: `+validate-bash.sh:700:deferred_route_git_shape: return 1` records
// a return from the deferred Git route.
func parseBashXTrace(trace string) []bashXTraceEvent {
	var events []bashXTraceEvent
	for _, line := range strings.Split(trace, "\n") {
		if !strings.HasPrefix(line, "+") {
			continue
		}
		fields := strings.SplitN(strings.TrimPrefix(line, "+"), ":", 4)
		if len(fields) != 4 {
			continue
		}
		events = append(events, bashXTraceEvent{
			function: fields[2],
			command:  strings.TrimSpace(fields[3]),
		})
	}
	return events
}

// archiveCapabilityFastPathTrace verifies the exact positive route in order:
// capability helper, deferred-route return 1, worker fast candidate, marker
// validation, then the status-0 exit.
func archiveCapabilityFastPathTrace(trace string) bool {
	return xtraceContainsOrderedSteps(parseBashXTrace(trace), []bashXTraceEvent{
		{function: "deferred_route_git_shape", command: "repository_default_git_archive_capability"},
		{function: "deferred_route_git_shape", command: "return 1"},
		{command: "worker_fast_path_candidate=true"},
		{command: "validate_active_marker_binding"},
		{command: "exit 0"},
	})
}

// archiveCapabilityLegacyGitRouteTrace verifies that a direct Git near-miss
// reaches the helper, then returns to the legacy Git route without a fast-path
// candidate.
func archiveCapabilityLegacyGitRouteTrace(trace string) bool {
	events := parseBashXTrace(trace)
	return !xtraceContainsCommand(events, "worker_fast_path_candidate=true") &&
		xtraceContainsOrderedSteps(events, []bashXTraceEvent{
			{function: "deferred_route_git_shape", command: "repository_default_git_archive_capability"},
			{function: "deferred_route_git_shape", command: "return 0"},
		})
}

// xtraceContainsOrderedSteps reports whether every expected function/command
// event appears in sequence. An empty expected function matches any scope.
func xtraceContainsOrderedSteps(events []bashXTraceEvent, expected []bashXTraceEvent) bool {
	next := 0
	for _, event := range events {
		want := expected[next]
		if (want.function == "" || event.function == want.function) && event.command == want.command {
			next++
			if next == len(expected) {
				return true
			}
		}
	}
	return false
}

// xtraceContainsCommand reports whether any function scope emitted command.
func xtraceContainsCommand(events []bashXTraceEvent, command string) bool {
	for _, event := range events {
		if event.command == command {
			return true
		}
	}
	return false
}

// processTraceExecutesGit reports whether validator execution launched git.
// Validators must classify the submitted archive command without executing it.
func processTraceExecutesGit(trace string) bool {
	return gitExecutionTrace(trace) != ""
}

// gitExecutionTrace returns execve entries whose executable basename is git.
func gitExecutionTrace(trace string) string {
	var executions []string
	for _, line := range strings.Split(trace, "\n") {
		start := strings.Index(line, "execve(\"")
		if start < 0 {
			continue
		}
		quotedPath := line[start+len("execve(\""):]
		end := strings.Index(quotedPath, "\"")
		if end < 0 {
			continue
		}
		if filepath.Base(quotedPath[:end]) == "git" {
			executions = append(executions, line)
		}
	}
	return strings.Join(executions, "\n")
}

// archiveRoutingShellTrace returns only the function-scoped xtrace events
// relevant to archive admission, for readable failures.
func archiveRoutingShellTrace(trace string) string {
	var lines []string
	for _, event := range parseBashXTrace(trace) {
		if event.function == "deferred_route_git_shape" ||
			event.function == "repository_default_git_archive_capability" ||
			event.command == "worker_fast_path_candidate=true" ||
			event.command == "worker_fast_path_candidate=false" ||
			event.command == "validate_active_marker_binding" ||
			event.command == "exit 0" {
			lines = append(lines, event.function+": "+event.command)
		}
	}
	return strings.Join(lines, "\n")
}

func assertSameFile(t *testing.T, left, right string) {
	t.Helper()

	leftInfo, err := os.Stat(left)
	if err != nil {
		t.Fatalf("stat %s: %v", left, err)
	}
	rightInfo, err := os.Stat(right)
	if err != nil {
		t.Fatalf("stat %s: %v", right, err)
	}
	leftStat, leftOK := leftInfo.Sys().(*syscall.Stat_t)
	rightStat, rightOK := rightInfo.Sys().(*syscall.Stat_t)
	if !leftOK || !rightOK {
		t.Fatalf("stat identity unavailable for %s and %s", left, right)
	}
	if leftStat.Dev != rightStat.Dev || leftStat.Ino != rightStat.Ino {
		t.Errorf("provider files are not hard-linked: %s (%d:%d), %s (%d:%d)",
			left, leftStat.Dev, leftStat.Ino, right, rightStat.Dev, rightStat.Ino)
	}
}

func runBinary(t *testing.T, path string, input []byte, stdout *bytes.Buffer) int {
	t.Helper()

	command := exec.Command(path)
	command.Stdin = bytes.NewReader(input)
	command.Stdout = stdout
	var stderr bytes.Buffer
	command.Stderr = &stderr
	err := command.Run()
	if err == nil {
		return StatusAllow
	}
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) {
		t.Fatalf("run %s: %v; stderr=%s", path, err, stderr.String())
	}
	return exitError.ExitCode()
}
