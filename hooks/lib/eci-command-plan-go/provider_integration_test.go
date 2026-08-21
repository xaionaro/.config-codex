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
