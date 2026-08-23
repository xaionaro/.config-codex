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
