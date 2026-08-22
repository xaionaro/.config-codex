package main

import (
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestPythonOracleParityForBoundedCore(t *testing.T) {
	t.Parallel()

	oracle, err := filepath.Abs(filepath.Join("..", "eci-command-plan.py"))
	if err != nil {
		t.Fatalf("resolve oracle: %v", err)
	}
	testCases := []struct {
		command string
	}{
		{command: "novel-tool --flag value"},
		{command: "adb devices -l"},
		{command: "printf 'left && right'"},
		{command: "env FOO=bar novel-tool --flag value"},
		{command: "FOO=bar novel-tool"},
		{command: "novel-tool > output.txt"},
		{command: "printf before | env | printf after"},
		{command: "timeout 5 git commit -m nope"},
		{command: "git archive HEAD"},
		{command: "printenv OPENAI_API_KEY"},
		{command: "rm -rf /"},
	}

	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.command, func(t *testing.T) {
			t.Parallel()

			request := activeWorker(testCase.command)
			goResult := Classify(request)
			goStatus := statusForDecision(goResult.Decision)
			pythonStatus, pythonOutput := runPythonOracle(t, oracle, request)
			if goStatus != pythonStatus {
				t.Fatalf(
					"status mismatch: Go=%d (%#v), Python=%d (%s)",
					goStatus,
					goResult,
					pythonStatus,
					pythonOutput,
				)
			}
			if goResult.Diagnostic != nil && !strings.Contains(pythonOutput, string(goResult.Diagnostic.Code)) {
				t.Fatalf(
					"diagnostic mismatch: Go=%s, Python=%s",
					goResult.Diagnostic.Code,
					pythonOutput,
				)
			}
		})
	}
}

func runPythonOracle(t *testing.T, oracle string, request Request) (int, string) {
	t.Helper()

	command := exec.Command(
		"python3",
		oracle,
		string(request.Provider),
		string(request.Role),
		request.CWD,
		string(request.Marker),
		request.ActiveSession,
		request.Command,
	)
	output, err := command.CombinedOutput()
	if err == nil {
		return StatusAllow, string(output)
	}
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) {
		t.Fatalf("run Python oracle: %v", err)
	}
	return exitError.ExitCode(), string(output)
}

func statusForDecision(decision DecisionKind) int {
	switch decision {
	case DecisionAllow:
		return StatusAllow
	case DecisionDeny:
		return StatusDeny
	case DecisionDefer:
		return StatusDefer
	default:
		return StatusInternal
	}
}
