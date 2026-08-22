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

	codexRoot := filepath.Clean(filepath.Join("..", "..", ".."))
	kimiRoot := "/home/pheona/.kimi-code"
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
		filepath.Clean(filepath.Join("..", "..", "validate-bash.sh")),
		"/home/pheona/.kimi-code/hooks/validate-bash.sh",
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
