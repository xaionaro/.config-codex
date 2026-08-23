package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

const (
	maxCommandBytes         = 16 * 1024
	maxSegments             = 8
	maxArguments            = 128
	maxArgumentBytes        = 4 * 1024
	maxWrapperDepth         = 8
	maxProofAnchors         = 128
	maxActiveControlEntries = 128
)

// Provider identifies the provider adapter requesting command-plan admission.
type Provider string

const (
	// ProviderCodex selects the Codex adapter contract.
	ProviderCodex Provider = "codex"
	// ProviderKimi selects the Kimi adapter contract.
	ProviderKimi Provider = "kimi"
)

// Role identifies whether the callback belongs to the coordinator or a worker.
type Role string

const (
	// RoleCoordinator identifies the main/orchestrator owner.
	RoleCoordinator Role = "coordinator"
	// RoleWorker identifies a delegated worker callback.
	RoleWorker Role = "worker"
)

// Marker identifies whether the callback has a validated active ECI marker.
type Marker string

const (
	// MarkerActive indicates that ECI ownership checks are active.
	MarkerActive Marker = "active"
	// MarkerInactive indicates that no active ECI marker was discovered.
	MarkerInactive Marker = "inactive"
)

// DecisionKind is the compiled planner's admission disposition.
type DecisionKind string

const (
	// DecisionAllow admits the finite command plan.
	DecisionAllow DecisionKind = "allow"
	// DecisionDefer routes the capability to a provider-specific adapter.
	DecisionDefer DecisionKind = "defer"
	// DecisionDeny rejects the command plan with a structured diagnostic.
	DecisionDeny DecisionKind = "deny"
	// DecisionError reports an invalid planner request or internal failure.
	DecisionError DecisionKind = "error"
)

// Capability identifies a recognized protected command capability.
type Capability string

const (
	// CapabilityGateMode identifies command-gate mode operations.
	CapabilityGateMode Capability = "gate-mode"
	// CapabilityRepositoryDefaultGitArchive identifies one direct repository
	// archive plan with no caller-selected Git execution context.
	//
	// Example: git archive --format=tar --output=artifact.tar HEAD.
	CapabilityRepositoryDefaultGitArchive Capability = "repository-default-git-archive"
)

// DiagnosticCode is the stable machine-readable reason for a denial.
type DiagnosticCode string

const (
	// CodePlanSyntaxDenied reports unsupported shell-plan syntax.
	CodePlanSyntaxDenied DiagnosticCode = "ECI_PLAN_SYNTAX_DENIED"
	// CodePlanLimitDenied reports a bounded command-plan limit violation.
	CodePlanLimitDenied DiagnosticCode = "ECI_PLAN_LIMIT_DENIED"
	// CodePlanWrapperDenied reports an incomplete transparent wrapper.
	CodePlanWrapperDenied DiagnosticCode = "ECI_PLAN_WRAPPER_DENIED"
	// CodePlanDynamicLaunchDenied reports dynamic executable launching.
	CodePlanDynamicLaunchDenied DiagnosticCode = "ECI_PLAN_DYNAMIC_LAUNCH_DENIED"
	// CodeEnvironmentEnumerationDenied reports unbounded environment enumeration.
	CodeEnvironmentEnumerationDenied DiagnosticCode = "ECI_ENVIRONMENT_ENUMERATION_DENIED"
	// CodeEnvironmentNameDenied reports an unregistered environment name.
	CodeEnvironmentNameDenied DiagnosticCode = "ECI_ENVIRONMENT_NAME_DENIED"
	// CodeEnvironmentOptionDenied reports an unsupported environment option.
	CodeEnvironmentOptionDenied DiagnosticCode = "ECI_ENVIRONMENT_OPTION_DENIED"
	// CodeEnvironmentContextDenied reports unsafe environment execution context.
	CodeEnvironmentContextDenied DiagnosticCode = "ECI_ENVIRONMENT_CONTEXT_DENIED"
	// CodeWorkerGitOwnershipDenied reports worker-owned Git mutation.
	CodeWorkerGitOwnershipDenied DiagnosticCode = "ECI_WORKER_GIT_OWNERSHIP_DENIED"
	// CodeGitExecutionContextDenied reports unsafe Git execution context.
	CodeGitExecutionContextDenied DiagnosticCode = "ECI_GIT_EXECUTION_CONTEXT_DENIED"
	// CodeControlOwnerRequired reports a coordinator-owned control mutation.
	CodeControlOwnerRequired DiagnosticCode = "ECI_CONTROL_OWNER_REQUIRED"
	// CodeControlIdentityDenied reports an untrusted control executable identity.
	CodeControlIdentityDenied DiagnosticCode = "ECI_CONTROL_IDENTITY_DENIED"
	// CodeBroadDestructiveDenied reports a broad destructive operation.
	CodeBroadDestructiveDenied DiagnosticCode = "ECI_BROAD_DESTRUCTIVE_DENIED"
	// CodeLedgerAppendOnly reports a direct mutation of an append-only ledger.
	CodeLedgerAppendOnly DiagnosticCode = "ECI_LEDGER_APPEND_ONLY"
	// CodeProofPathEscapeDenied reports a proof-path ownership escape.
	CodeProofPathEscapeDenied DiagnosticCode = "ECI_PROOF_PATH_ESCAPE_DENIED"
	// CodePlanLiveControlDenied reports a live control-file ownership violation.
	CodePlanLiveControlDenied DiagnosticCode = "ECI_PLAN_LIVE_CONTROL_DENIED"
	// CodePlanInternalDenied reports malformed planner input or internal failure.
	CodePlanInternalDenied DiagnosticCode = "ECI_PLAN_INTERNAL_DENIED"
)

// Request is the bounded JSON request consumed by the compiled planner.
type Request struct {
	Provider      Provider `json:"provider"`
	Role          Role     `json:"role"`
	CWD           string   `json:"cwd"`
	Marker        Marker   `json:"marker"`
	ActiveSession string   `json:"active_session"`
	Command       string   `json:"command"`
	ActiveMarkers []string `json:"active_markers"`
	ApprovedRoots []string `json:"approved_roots"`
}

// Diagnostic describes one denied command-plan coordinate and remediation.
type Diagnostic struct {
	Code            DiagnosticCode `json:"code"`
	Operation       string         `json:"operation"`
	Segment         int            `json:"segment"`
	ArgvIndex       int            `json:"argv_index"`
	ByteOffset      int            `json:"byte_offset"`
	Token           string         `json:"token"`
	Path            string         `json:"path"`
	Predicate       string         `json:"predicate"`
	Reason          string         `json:"reason"`
	Remediation     string         `json:"remediation"`
	RejectedSegment string         `json:"rejected_segment"`
}

// HookSpecificOutput carries the provider-neutral PreToolUse denial payload.
type HookSpecificOutput struct {
	HookEventName            string `json:"hookEventName"`
	PermissionDecision       string `json:"permissionDecision"`
	PermissionDecisionReason string `json:"permissionDecisionReason"`
}

// Result is the compiled planner's structured admission response.
type Result struct {
	Decision           DecisionKind        `json:"decision"`
	Capabilities       []Capability        `json:"capabilities,omitempty"`
	Diagnostic         *Diagnostic         `json:"diagnostic,omitempty"`
	HookSpecificOutput *HookSpecificOutput `json:"hookSpecificOutput,omitempty"`
}

type token struct {
	value  string
	offset int
	quoted bool
}

type segment struct {
	argv   []token
	offset int
}

type plan struct {
	segments  []segment
	operators []string
}

type proofSession struct {
	lexical  string
	resolved string
}

type gateModeIdentity struct {
	canonicalPaths []string
	canonicalInfo  os.FileInfo
	size           int64
	digest         [sha256.Size]byte
	failure        string
}

var eciControlBasenames = [...]string{
	"eci_active", "goal_state", "eci_wait", "eci_user_owned_wait.md",
	"eci-required-critics.json", "eci-critic-identities.ledger",
	"eci-acceptance-anchor", "eci-acceptance-transaction",
	"eci-teardown-complete", "eci-baseline-binding", "baseline_head",
	"eci-commit-admitted", "eci-user-closed.ledger", "proof.md",
	"instructions.md", "stop_timestamps", "stop_loop_state",
	"disengage.md", "user-closed.md", "project-understanding.md",
	"high_level_log.md", "latest-status-report.md", "high_level_log.anchor",
}

type planError struct {
	diagnostic Diagnostic
}

func (err *planError) Error() string {
	return err.diagnostic.Reason
}

// Classify parses and admits one bounded command plan.
func Classify(request Request) Result {
	parsed, err := parsePlan(request.Command)
	if err != nil {
		if request.Marker == MarkerInactive && strings.HasPrefix(string(err.diagnostic.Code), "ECI_PLAN_") {
			// Inactive callbacks remain transparent to shell syntax, while
			// deferring dynamic expansion lets the provider adapter retain
			// ownership of protected children such as Git mutations.
			if err.diagnostic.Predicate == "dynamic-expansion" {
				return Result{Decision: DecisionDefer}
			}
			return Result{Decision: DecisionAllow}
		}
		err.diagnostic.RejectedSegment = shellEscape(request.Command)
		return deniedResult(request, err.diagnostic)
	}

	capabilities := capabilitiesForPlan(parsed)
	wholeSingleSegmentPlan := len(parsed.segments) == 1 && len(parsed.operators) == 0
	decision := DecisionAllow
	for index, current := range parsed.segments {
		segmentDecision, diagnostic := inspectSegment(request, current, index+1, wholeSingleSegmentPlan)
		if diagnostic != nil {
			diagnostic.RejectedSegment = rejectedSegment(current, diagnostic.Code)
			if suppressInactiveDiagnostic(request, diagnostic) {
				// Inactive syntax diagnostics can hide a protected child
				// capability behind shell context (assignments, wrappers,
				// or interpreter payloads). Defer the complete literal to
				// the provider adapter; ordinary inactive commands remain
				// admitted when that adapter finds no protected operation.
				decision = DecisionDefer
				continue
			}
			return deniedResult(request, *diagnostic)
		}
		if segmentDecision == DecisionDefer {
			decision = DecisionDefer
		}
	}
	if request.Marker == MarkerActive && request.Role == RoleWorker && len(parsed.operators) > 0 {
		// A finite semicolon batch whose every segment passed the capability
		// inspection above is still an ordinary worker plan. Keep control-flow
		// operators on the provider adapter route, and let any protected segment
		// retain the defer/deny decision it already selected.
		for _, operator := range parsed.operators {
			if operator != ";" {
				decision = DecisionDefer
				break
			}
		}
	}

	return Result{Decision: decision, Capabilities: capabilities}
}

// capabilitiesForPlan returns the one explicit capability represented by the
// raw parsed command plan, when any.
//
// Example: a direct git archive HEAD plan returns its repository-default
// archive capability before command inspection determines its final decision.
func capabilitiesForPlan(parsed plan) []Capability {
	if isRepositoryDefaultGitArchivePlan(parsed) {
		return []Capability{CapabilityRepositoryDefaultGitArchive}
	}
	for segmentIndex, current := range parsed.segments {
		argv, diagnostic := unwrap(current.argv, segmentIndex+1)
		if diagnostic == nil && isGateModeCapability(argv) {
			return []Capability{CapabilityGateMode}
		}
	}
	return nil
}

// isRepositoryDefaultGitArchivePlan reports whether parsed is exactly one
// unquoted repository-default git archive command with an optional tar output.
//
// Example: git archive HEAD is true, while git -C repo archive HEAD is false.
func isRepositoryDefaultGitArchivePlan(parsed plan) bool {
	if len(parsed.segments) != 1 || len(parsed.operators) != 0 {
		return false
	}

	argv := parsed.segments[0].argv
	if len(argv) != 3 && len(argv) != 5 {
		return false
	}
	for _, argument := range argv {
		if argument.quoted {
			return false
		}
	}
	if argv[0].value != "git" || argv[1].value != "archive" {
		return false
	}
	switch len(argv) {
	case 3:
		return argv[2].value == "HEAD"
	case 5:
		output := strings.TrimPrefix(argv[3].value, "--output=")
		return argv[2].value == "--format=tar" &&
			strings.HasPrefix(argv[3].value, "--output=") &&
			output != "" &&
			argv[4].value == "HEAD"
	default:
		return false
	}
}

func isGateModeCapability(argv []token) bool {
	_, _, ok := gateModeIndexes(argv)
	return ok
}

func rejectedSegment(current segment, code DiagnosticCode) string {
	if code == CodeEnvironmentContextDenied {
		return "<environment-context command; assignment value omitted>"
	}
	arguments := make([]string, 0, len(current.argv))
	for _, argument := range current.argv {
		arguments = append(arguments, shellEscape(argument.value))
	}
	return strings.Join(arguments, " ")
}

func canonicalLifecycleTildePrefix(command string, offset int) bool {
	for _, alias := range []string{"~/.codex/bin/eci-active", "~/.kimi-code/bin/eci-active"} {
		if !strings.HasPrefix(command[offset:], alias) {
			continue
		}
		end := offset + len(alias)
		return end == len(command) || strings.ContainsRune(" \t;|&<>", rune(command[end]))
	}
	return false
}

func parsePlan(command string) (plan, *planError) {
	if !utf8.ValidString(command) {
		return plan{}, newPlanError(
			CodePlanSyntaxDenied,
			"command is not valid UTF-8",
			0,
			1,
			0,
			"<command>",
			"replace invalid bytes with one literal UTF-8 argv plan",
			"invalid-utf8",
		)
	}
	if len(command) > maxCommandBytes {
		return plan{}, newPlanError(
			CodePlanLimitDenied,
			fmt.Sprintf("command is %d bytes; maximum is %d", len(command), maxCommandBytes),
			maxCommandBytes,
			1,
			0,
			"<command>",
			"split the command into smaller finite literal calls",
			"command-byte-limit",
		)
	}
	if index := strings.IndexAny(command, "\x00\r"); index >= 0 {
		return plan{}, newPlanError(
			CodePlanSyntaxDenied,
			"NUL and carriage-return bytes are not command-plan syntax",
			index,
			1,
			0,
			command[index:index+1],
			"remove the reported byte and retry one literal plan",
			"forbidden-byte",
		)
	}

	var parsed plan
	var current []token
	var value strings.Builder
	tokenOffset := 0
	tokenStarted := false
	tokenQuoted := false
	quote := byte(0)
	escaped := false

	flushToken := func() *planError {
		if !tokenStarted {
			return nil
		}
		argument := value.String()
		if len(argument) > maxArgumentBytes {
			return newPlanError(
				CodePlanLimitDenied,
				fmt.Sprintf("argv element is larger than %d bytes", maxArgumentBytes),
				tokenOffset,
				len(parsed.segments)+1,
				len(current),
				argument,
				"shorten the reported argv element and retry",
				"argv-byte-limit",
			)
		}
		current = append(current, token{value: argument, offset: tokenOffset, quoted: tokenQuoted})
		value.Reset()
		tokenStarted = false
		tokenQuoted = false
		return nil
	}

	flushSegment := func(operator string, offset int) *planError {
		if err := flushToken(); err != nil {
			return err
		}
		if len(current) == 0 {
			return newPlanError(
				CodePlanSyntaxDenied,
				"a command-plan operator has an empty adjacent segment",
				offset,
				len(parsed.segments)+1,
				0,
				operator,
				"supply one nonempty literal argv on each side of the operator",
				"empty-segment",
			)
		}
		if len(parsed.segments) >= maxSegments {
			return newPlanError(
				CodePlanLimitDenied,
				fmt.Sprintf("command plan exceeds %d segments", maxSegments),
				offset,
				len(parsed.segments)+1,
				0,
				operator,
				"split the plan into separately reviewed calls",
				"segment-limit",
			)
		}
		copied := append([]token(nil), current...)
		parsed.segments = append(parsed.segments, segment{argv: copied, offset: copied[0].offset})
		parsed.operators = append(parsed.operators, operator)
		current = current[:0]
		return nil
	}

	for index := 0; index < len(command); index++ {
		character := command[index]
		if escaped {
			value.WriteByte(character)
			tokenStarted = true
			tokenQuoted = true
			escaped = false
			continue
		}
		if quote == '\'' {
			if character == '\'' {
				quote = 0
				continue
			}
			value.WriteByte(character)
			tokenStarted = true
			tokenQuoted = true
			continue
		}
		if character == '\\' {
			if !tokenStarted {
				tokenOffset = index
			}
			tokenStarted = true
			tokenQuoted = true
			escaped = true
			continue
		}
		if character == '\'' {
			if !tokenStarted {
				tokenOffset = index
			}
			tokenStarted = true
			tokenQuoted = true
			quote = '\''
			continue
		}
		if character == '"' {
			if !tokenStarted {
				tokenOffset = index
			}
			tokenStarted = true
			tokenQuoted = true
			if quote == '"' {
				quote = 0
			} else {
				quote = '"'
			}
			continue
		}

		inDoubleQuote := quote == '"'
		if !inDoubleQuote && (character == ' ' || character == '\t') {
			if err := flushToken(); err != nil {
				return plan{}, err
			}
			continue
		}
		if !inDoubleQuote {
			operator := ""
			switch {
			case index+1 < len(command) && command[index:index+2] == "&&":
				operator = "&&"
			case index+1 < len(command) && command[index:index+2] == "||":
				operator = "||"
			case character == ';', character == '|', character == '\n':
				operator = string(character)
			}
			if operator != "" {
				if err := flushSegment(operator, index); err != nil {
					return plan{}, err
				}
				index += len(operator) - 1
				continue
			}
			if character == '&' {
				return plan{}, newPlanError(
					CodePlanSyntaxDenied,
					"background execution is not a finite command-plan operator",
					index,
					len(parsed.segments)+1,
					len(current),
					"&",
					"remove '&' or use a finite supported plan operator",
					"background-operator",
				)
			}
			if character == '<' || character == '>' {
				predicate := "redirection"
				tokenValue := string(character)
				if index+1 < len(command) && command[index+1] == '(' {
					predicate = "process-substitution"
					tokenValue = command[index : index+2]
				}
				return plan{}, newPlanError(
					CodePlanSyntaxDenied,
					strings.ReplaceAll(predicate, "-", " ")+" is not literal argv syntax",
					index,
					len(parsed.segments)+1,
					len(current),
					tokenValue,
					"pass paths as literal argv and let the invoked tool perform I/O",
					predicate,
				)
			}
			if character == '(' || character == ')' {
				return plan{}, newPlanError(
					CodePlanSyntaxDenied,
					"shell grouping and process substitution are not literal argv syntax",
					index,
					len(parsed.segments)+1,
					len(current),
					string(character),
					"invoke a finite direct argv without shell grouping",
					"grouping",
				)
			}
			if character == '#' && !tokenStarted {
				return plan{}, newPlanError(
					CodePlanSyntaxDenied,
					"unquoted shell comments are not part of a literal command plan",
					index,
					len(parsed.segments)+1,
					len(current),
					"#",
					"remove the comment or quote the literal hash character",
					"comment",
				)
			}
			if strings.ContainsRune("*?[{}", rune(character)) ||
				(character == '~' && !tokenStarted && !canonicalLifecycleTildePrefix(command, index)) {
				return plan{}, newPlanError(
					CodePlanSyntaxDenied,
					"unquoted expansion syntax makes argv filesystem- or shell-dependent",
					index,
					len(parsed.segments)+1,
					len(current),
					string(character),
					"quote or escape the literal metacharacter, or pass explicit argv",
					"shell-expansion",
				)
			}
		}
		if (character == '$' || character == '`') && quote != '\'' {
			return plan{}, newPlanError(
				CodePlanSyntaxDenied,
				"parameter, command, or arithmetic expansion makes argv dynamic",
				index,
				len(parsed.segments)+1,
				len(current),
				string(character),
				"replace expansion with explicit literal argv",
				"dynamic-expansion",
			)
		}
		if !tokenStarted {
			tokenOffset = index
		}
		value.WriteByte(character)
		tokenStarted = true
	}

	if escaped || quote != 0 {
		tokenValue := "\\"
		if quote != 0 {
			tokenValue = string(quote)
		}
		return plan{}, newPlanError(
			CodePlanSyntaxDenied,
			"shell quoting or escaping is unbalanced",
			len(command),
			len(parsed.segments)+1,
			len(current),
			tokenValue,
			"close the reported quote or remove the trailing escape",
			"unbalanced-quote",
		)
	}
	if err := flushToken(); err != nil {
		return plan{}, err
	}
	if len(current) == 0 {
		tokenValue := "<empty>"
		if len(parsed.operators) > 0 {
			tokenValue = parsed.operators[len(parsed.operators)-1]
		}
		return plan{}, newPlanError(
			CodePlanSyntaxDenied,
			"command plan has no final literal argv",
			len(command),
			len(parsed.segments)+1,
			0,
			tokenValue,
			"supply one nonempty literal argv after the operator",
			"empty-segment",
		)
	}
	parsed.segments = append(parsed.segments, segment{argv: append([]token(nil), current...), offset: current[0].offset})
	argumentCount := 0
	for _, currentSegment := range parsed.segments {
		argumentCount += len(currentSegment.argv)
	}
	if len(parsed.segments) > maxSegments || argumentCount > maxArguments {
		return plan{}, newPlanError(
			CodePlanLimitDenied,
			fmt.Sprintf(
				"command plan contains %d segments and %d argv elements; limits are %d and %d",
				len(parsed.segments),
				argumentCount,
				maxSegments,
				maxArguments,
			),
			len(command),
			len(parsed.segments),
			len(parsed.segments[len(parsed.segments)-1].argv)-1,
			"<plan>",
			"split the plan into smaller separately reviewed calls",
			"plan-limit",
		)
	}

	return parsed, nil
}

func inspectSegment(
	request Request,
	current segment,
	segmentIndex int,
	wholeSingleSegmentPlan bool,
) (DecisionKind, *Diagnostic) {
	if len(current.argv) == 0 {
		return DecisionDeny, diagnosticForToken(
			CodePlanSyntaxDenied,
			"command segment is empty",
			segmentIndex,
			0,
			token{value: "<empty>", offset: current.offset},
			"supply one finite literal argv",
			"empty-segment",
		)
	}
	if assignmentName(current.argv[0]) != "" {
		return DecisionDeny, diagnosticForToken(
			CodePlanSyntaxDenied,
			"assignments before the executable are shell context, not literal argv",
			segmentIndex,
			0,
			current.argv[0],
			"use env with a literal child argv, or remove the leading assignment",
			"leading-assignment",
		)
	}
	if isReservedControl(current.argv[0]) {
		return DecisionDeny, diagnosticForToken(
			CodePlanSyntaxDenied,
			"reserved shell control words are not literal executable argv",
			segmentIndex,
			0,
			current.argv[0],
			"invoke one direct finite executable argv",
			"reserved-shell-control",
		)
	}
	if request.Marker == MarkerActive {
		decision, diagnostic := inspectProofPathOwnership(request, current.argv, segmentIndex)
		if diagnostic != nil || decision == DecisionDefer {
			return decision, diagnostic
		}
	}
	argv, diagnostic := unwrap(current.argv, segmentIndex)
	if diagnostic != nil {
		return DecisionDeny, diagnostic
	}
	name := filepath.Base(argv[0].value)
	if request.Marker == MarkerActive && name == "mktemp" {
		// Temporary-directory setup is coordinator-owned capability. Defer
		// every active invocation to the provider route, which validates the
		// exact template and rejects workers, rather than encoding a template
		// allowlist in the planner.
		return DecisionDefer, nil
	}

	switch name {
	case "printenv":
		if diagnostic := inspectPrintenv(argv, segmentIndex); diagnostic != nil {
			return DecisionDeny, diagnostic
		}
	case "alias", "enable", "eval", "export", "hash", "set", "source", ".", "unset", "xargs":
		return DecisionDeny, diagnosticForToken(
			CodePlanDynamicLaunchDenied,
			fmt.Sprintf("%s constructs or loads executable argv dynamically", name),
			segmentIndex,
			0,
			argv[0],
			"invoke the resulting finite literal argv directly",
			"dynamic-launch",
		)
	}

	if isInterpreter(name) {
		if diagnostic := inspectInterpreter(name, argv, segmentIndex); diagnostic != nil {
			return DecisionDeny, diagnostic
		}
	}
	if isGateModeCapability(argv) {
		if diagnostic := inspectGateMode(request, current.argv, argv, segmentIndex); diagnostic != nil {
			return DecisionDeny, diagnostic
		}
		return DecisionAllow, nil
	}
	if request.Marker == MarkerActive && request.Role == RoleWorker {
		if diagnostic := inspectActiveWorkerLifecycleIdentity(request, current.argv, argv, segmentIndex); diagnostic != nil {
			return DecisionDeny, diagnostic
		}
	}
	if request.Marker == MarkerActive && isLifecycleScriptCapability(request.CWD, argv) {
		// The provider adapter owns canonical lifecycle-script identity,
		// arguments, and role authorization. Recognize only a visible script
		// position here so active fast admission cannot bypass that route.
		return DecisionDefer, nil
	}
	if request.Marker == MarkerActive && isCoordinatorHookRepair(argv) {
		// The legacy coordinator route performs the canonical script digest,
		// repository-root, and peer-identity checks. Defer this capability by
		// shape so those checks remain authoritative without embedding provider
		// paths or peer allowlists in the compiled planner.
		return DecisionDefer, nil
	}
	if request.Marker == MarkerActive && wholeSingleSegmentPlan {
		if target, ok := isPreCommitHookModeRepair(current.argv); ok {
			// Hook-mode repair is an Emergency Unblock exception for one complete
			// direct plan. A compound plan retains its ordinary segment policy.
			switch request.Role {
			case RoleWorker:
				return DecisionDeny, diagnosticForToken(
					CodeControlOwnerRequired,
					"worker argv selects coordinator-owned pre-commit hook mode repair",
					segmentIndex,
					originalTokenIndex(current.argv, target),
					target,
					"route the exact pre-commit hook mode repair through the coordinator",
					"hook-mode-repair",
				)
			case RoleCoordinator:
				return DecisionDefer, nil
			}
		}
	}
	if request.Marker == MarkerActive {
		if target, resolved, ok := protectedHookModeMutation(request.CWD, argv); ok {
			switch request.Role {
			case RoleCoordinator:
				return DecisionDefer, nil
			case RoleWorker:
				diagnostic := diagnosticForToken(
					CodeControlOwnerRequired,
					"worker argv selects coordinator-owned protected hook mode mutation",
					segmentIndex,
					originalTokenIndex(current.argv, target),
					target,
					"route the protected hook-mode mutation through the coordinator",
					"worker-hook-mode-ownership",
				)
				diagnostic.Path = resolved
				return DecisionDeny, diagnostic
			}
		}
	}
	if name == "find" {
		for index, argument := range argv[1:] {
			switch argument.value {
			case "-exec", "-execdir", "-ok", "-okdir", "-delete":
				return DecisionDeny, diagnosticForToken(
					CodePlanDynamicLaunchDenied,
					"find action constructs nested execution or deletes discovered paths",
					segmentIndex,
					index+1,
					argument,
					"separate discovery from one finite literal action",
					"dynamic-find-action",
				)
			}
		}
	}
	if name == "git" {
		decision, diagnostic := inspectGit(request, argv, segmentIndex)
		if diagnostic != nil {
			return DecisionDeny, diagnostic
		}
		if decision == DecisionDefer {
			return DecisionDefer, nil
		}
	}
	if isLifecycleScriptPath(request.CWD, argv[0].value) {
		return DecisionDefer, nil
	}
	if name == "eci-command-gate-mode" {
		return DecisionDefer, nil
	}
	if diagnostic := inspectBroadDestruction(argv, segmentIndex); diagnostic != nil {
		return DecisionDeny, diagnostic
	}
	if request.Marker == MarkerActive && request.Role == RoleWorker {
		if diagnostic := inspectLiveControl(request, argv, segmentIndex); diagnostic != nil {
			return DecisionDeny, diagnostic
		}
	}
	if request.Marker == MarkerActive && request.Role == RoleCoordinator && isSourceWriter(name, argv) && sourceWriterTargetsCWD(request.CWD, name, argv) {
		return DecisionDefer, nil
	}

	return DecisionAllow, nil
}

func inspectGateMode(request Request, original, argv []token, segmentIndex int) *Diagnostic {
	targetIndex, actionIndex, ok := gateModeIndexes(argv)
	if !ok {
		return nil
	}
	target := argv[targetIndex]
	interpreterScript := filepath.Base(argv[0].value) == "python" || filepath.Base(argv[0].value) == "python3"
	identity := gateModeIdentityForEnvironment()
	matched, identityFailure, candidate := candidateMatchesGateMode(target, request.CWD, identity, interpreterScript)
	if identityFailure != "" {
		diagnostic := diagnosticForToken(
			CodeControlIdentityDenied,
			"command-gate control executable identity validation failed: failure="+identityFailure,
			segmentIndex,
			originalTokenIndex(original, target),
			target,
			"restore the canonical owner-executable Codex/Kimi hardlink pair before retrying",
			"gate-mode-identity",
		)
		diagnostic.Path = candidate
		return diagnostic
	}
	if request.Role != RoleWorker || !matched || argv[actionIndex].value != "set" {
		return nil
	}
	return diagnosticForToken(
		CodeControlOwnerRequired,
		"worker argv selects coordinator-owned command-gate mode mutation",
		segmentIndex,
		originalTokenIndex(original, argv[actionIndex]),
		argv[actionIndex],
		"route the exact command-gate mode change through the coordinator",
		"gate-mode-mutation",
	)
}

func gateModeIndexes(argv []token) (int, int, bool) {
	if len(argv) < 2 {
		return 0, 0, false
	}
	targetIndex := 0
	if filepath.Base(argv[0].value) == "python" || filepath.Base(argv[0].value) == "python3" {
		targetIndex = 1
	}
	actionIndex := targetIndex + 1
	if actionIndex >= len(argv) || filepath.Base(argv[targetIndex].value) != "eci-command-gate-mode" {
		return 0, 0, false
	}
	if argv[actionIndex].value != "set" && argv[actionIndex].value != "get" {
		return 0, 0, false
	}
	return targetIndex, actionIndex, true
}

func originalTokenIndex(original []token, target token) int {
	for index, argument := range original {
		if argument.offset == target.offset && argument.value == target.value {
			return index
		}
	}
	return 0
}

func gateModeIdentityForEnvironment() gateModeIdentity {
	home := os.Getenv("HOME")
	roots := []string{
		firstNonEmpty(os.Getenv("CODEX_HOME"), filepath.Join(home, ".codex")),
		firstNonEmpty(os.Getenv("KIMI_CODE_HOME"), filepath.Join(home, ".kimi-code")),
	}
	paths := make([]string, 0, len(roots))
	for _, root := range roots {
		if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) != root {
			return gateModeIdentity{canonicalPaths: paths, failure: "canonical-path-invalid"}
		}
		paths = append(paths, filepath.Join(root, "bin", "eci-command-gate-mode"))
	}
	if len(paths) != 2 {
		return gateModeIdentity{canonicalPaths: paths, failure: "canonical-path-invalid"}
	}
	infos := make([]os.FileInfo, 0, len(paths))
	for _, path := range paths {
		info, err := os.Lstat(path)
		if err != nil {
			return gateModeIdentity{canonicalPaths: paths, failure: "canonical-path-missing"}
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
			!fileOwnedByCurrentUser(info) || info.Mode().Perm()&0111 == 0 {
			return gateModeIdentity{canonicalPaths: paths, failure: "canonical-metadata-invalid"}
		}
		infos = append(infos, info)
	}
	if !os.SameFile(infos[0], infos[1]) {
		return gateModeIdentity{canonicalPaths: paths, failure: "canonical-hardlink-split"}
	}
	digest, err := digestRegularFile(paths[0], infos[0])
	if err != nil {
		return gateModeIdentity{canonicalPaths: paths, failure: "canonical-read-race"}
	}
	return gateModeIdentity{
		canonicalPaths: paths,
		canonicalInfo:  infos[0],
		size:           infos[0].Size(),
		digest:         digest,
	}
}

func firstNonEmpty(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

func fileOwnedByCurrentUser(info os.FileInfo) bool {
	state, ok := info.Sys().(*syscall.Stat_t)
	return ok && state.Uid == uint32(os.Getuid())
}

func digestRegularFile(path string, expected os.FileInfo) ([sha256.Size]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	defer file.Close()
	observed, err := file.Stat()
	if err != nil || !os.SameFile(observed, expected) || observed.Size() != expected.Size() {
		if err == nil {
			err = errors.New("file changed while reading")
		}
		return [sha256.Size]byte{}, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return [sha256.Size]byte{}, err
	}
	var digest [sha256.Size]byte
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

func candidateMatchesGateMode(target token, cwd string, identity gateModeIdentity, interpreterScript bool) (bool, string, string) {
	candidate := resolveExecutable(target.value, cwd)
	reservedName := filepath.Base(target.value) == "eci-command-gate-mode"
	namesCanonical := false
	for _, path := range identity.canonicalPaths {
		if candidate == path {
			namesCanonical = true
			break
		}
	}
	if identity.failure != "" {
		if reservedName || namesCanonical {
			return false, identity.failure, candidate
		}
		return false, "", candidate
	}
	if candidate == "" {
		if reservedName {
			return false, "candidate-not-resolved", candidate
		}
		return false, "", candidate
	}
	info, err := os.Stat(candidate)
	if err != nil {
		if reservedName {
			return false, "candidate-not-readable", candidate
		}
		return false, "", candidate
	}
	if !info.Mode().IsRegular() || !fileOwnedByCurrentUser(info) {
		if reservedName {
			return false, "candidate-metadata-invalid", candidate
		}
		return false, "", candidate
	}
	if !interpreterScript && info.Mode().Perm()&0111 == 0 {
		if reservedName {
			return false, "candidate-not-executable", candidate
		}
		return false, "", candidate
	}
	if os.SameFile(info, identity.canonicalInfo) {
		return true, "", candidate
	}
	if info.Size() != identity.size {
		if reservedName {
			return false, "reserved-copy-size-mismatch", candidate
		}
		return false, "", candidate
	}
	digest, err := digestRegularFile(candidate, info)
	if err != nil {
		if reservedName {
			return false, "candidate-read-race", candidate
		}
		return false, "", candidate
	}
	if digest == identity.digest {
		return true, "", candidate
	}
	if reservedName {
		return false, "reserved-copy-digest-mismatch", candidate
	}
	return false, "", candidate
}

// inspectActiveWorkerLifecycleIdentity rejects an unwrapped executable that is
// a canonical lifecycle target or byte-identical copy of either provider's
// eci-active executable.
//
// Example: stdbuf -oL /tmp/eci-active-copy status is worker control.
func inspectActiveWorkerLifecycleIdentity(
	request Request,
	original []token,
	argv []token,
	segmentIndex int,
) *Diagnostic {
	if len(argv) == 0 {
		return nil
	}

	candidate := resolveExecutable(argv[0].value, request.CWD)
	if candidate == "" {
		return nil
	}
	resolvedCandidate, resolveErr := resolvePathWithMissingSuffix(candidate)
	if resolveErr != nil {
		// A transient filesystem resolution failure cannot prove lifecycle
		// identity. Keep the lexical candidate for exact canonical paths.
		resolvedCandidate = candidate
	}
	for _, root := range canonicalLifecycleRoots() {
		for _, alias := range [...]string{"eci-review-gate", "eci-stage"} {
			canonical := filepath.Join(root, "bin", alias)
			if candidate == canonical || resolvedCandidate == canonical {
				return workerLifecycleIdentityDiagnostic(original, argv[0], segmentIndex, canonical)
			}
		}
	}

	candidateInfo, err := os.Stat(candidate)
	if err != nil || !candidateInfo.Mode().IsRegular() || !fileOwnedByCurrentUser(candidateInfo) || candidateInfo.Mode().Perm()&0111 == 0 {
		return nil
	}

	var candidateDigest [sha256.Size]byte
	hasCandidateDigest := false
	for _, root := range canonicalLifecycleRoots() {
		canonical := filepath.Join(root, "bin", "eci-active")
		canonicalInfo, err := os.Lstat(canonical)
		if err != nil || canonicalInfo.Mode()&os.ModeSymlink != 0 || !canonicalInfo.Mode().IsRegular() ||
			!fileOwnedByCurrentUser(canonicalInfo) || canonicalInfo.Mode().Perm()&0111 == 0 {
			continue
		}
		if os.SameFile(candidateInfo, canonicalInfo) {
			return workerLifecycleIdentityDiagnostic(original, argv[0], segmentIndex, canonical)
		}
		if candidateInfo.Size() != canonicalInfo.Size() {
			continue
		}
		if !hasCandidateDigest {
			candidateDigest, err = digestRegularFile(candidate, candidateInfo)
			if err != nil {
				return nil
			}
			hasCandidateDigest = true
		}
		canonicalDigest, err := digestRegularFile(canonical, canonicalInfo)
		if err == nil && candidateDigest == canonicalDigest {
			return workerLifecycleIdentityDiagnostic(original, argv[0], segmentIndex, canonical)
		}
	}
	return nil
}

// canonicalLifecycleRoots returns existing, canonical provider homes that may
// own lifecycle executables.
//
// Example: a CODEX_HOME symlink contributes its resolved bin/eci-active.
func canonicalLifecycleRoots() []string {
	home := os.Getenv("HOME")
	values := []string{
		firstNonEmpty(os.Getenv("CODEX_HOME"), filepath.Join(home, ".codex")),
		firstNonEmpty(os.Getenv("KIMI_CODE_HOME"), filepath.Join(home, ".kimi-code")),
	}
	roots := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, root := range values {
		if root == "" || !filepath.IsAbs(root) {
			continue
		}
		resolved, err := filepath.EvalSymlinks(filepath.Clean(root))
		if err != nil || !filepath.IsAbs(resolved) {
			continue
		}
		resolved = filepath.Clean(resolved)
		info, err := os.Stat(resolved)
		if err != nil || !info.IsDir() {
			continue
		}
		if _, exists := seen[resolved]; exists {
			continue
		}
		seen[resolved] = struct{}{}
		roots = append(roots, resolved)
	}
	return roots
}

// workerLifecycleIdentityDiagnostic reports ownership of an unwrapped
// lifecycle executable while preserving the original command token position.
//
// Example: an env child is reported at its original child argv index.
func workerLifecycleIdentityDiagnostic(
	original []token,
	target token,
	segmentIndex int,
	canonical string,
) *Diagnostic {
	diagnostic := diagnosticForToken(
		CodeControlOwnerRequired,
		"worker argv selects coordinator-owned lifecycle executable: canonical_target="+canonical+" invocation=unwrapped",
		segmentIndex,
		originalTokenIndex(original, target),
		target,
		"route the exact lifecycle/control invocation through the coordinator",
		"worker-lifecycle-control",
	)
	diagnostic.Path = canonical
	return diagnostic
}

func resolveExecutable(value, cwd string) string {
	if filepath.IsAbs(value) {
		return filepath.Clean(value)
	}
	if strings.ContainsRune(value, filepath.Separator) {
		return filepath.Clean(filepath.Join(cwd, value))
	}
	resolved, err := exec.LookPath(value)
	if err != nil {
		return ""
	}
	return filepath.Clean(resolved)
}

func inspectProofPathOwnership(
	request Request,
	argv []token,
	segmentIndex int,
) (DecisionKind, *Diagnostic) {
	proofSessions := make([]proofSession, 0, len(request.ActiveMarkers))
	for _, marker := range request.ActiveMarkers {
		if !filepath.IsAbs(marker) {
			return DecisionDefer, nil
		}
		lexical := filepath.Clean(filepath.Dir(marker))
		resolved, err := resolvePathWithMissingSuffix(lexical)
		if err != nil {
			return DecisionDefer, nil
		}
		proofSessions = append(proofSessions, proofSession{lexical: lexical, resolved: resolved})
	}
	if len(proofSessions) == 0 {
		return DecisionAllow, nil
	}

	for argumentIndex, argument := range argv {
		pathArgument, pathLike := outputDestinationOperand(argv, argumentIndex)
		outputWriter := pathLike
		if !pathLike {
			pathArgument, pathLike = commandPathOperand(argv[0].value, argument)
		}
		if !pathLike {
			continue
		}
		lexical := pathArgument.value
		if !filepath.IsAbs(lexical) {
			lexical = filepath.Join(request.CWD, lexical)
		}
		lexical = filepath.Clean(lexical)

		resolved, resolveErr := resolvePathWithMissingSuffix(lexical)
		containingSession := ""
		contained := false
		anchorSearchComplete := true
		for _, proofSession := range proofSessions {
			if resolveErr == nil && pathWithin(resolved, proofSession.resolved) {
				contained = true
				break
			}
			if pathWithin(lexical, proofSession.lexical) {
				containingSession = proofSession.lexical
				continue
			}
			anchored, complete := pathHasResolvedProofAnchor(filepath.Dir(lexical), proofSession.resolved)
			if !complete {
				anchorSearchComplete = false
			}
			if anchored {
				containingSession = proofSession.lexical
			}
		}
		if contained {
			writer := outputWriter || isSourceWriter(filepath.Base(argv[0].value), argv)
			if request.Role == RoleCoordinator && writer &&
				isAppendOnlyLedgerPath(lexical, resolved, proofSessions) {
				diagnostic := diagnosticForToken(
					CodeLedgerAppendOnly,
					"active-session high-level ledger files are append-only coordinator artifacts",
					segmentIndex,
					argumentIndex,
					pathArgument,
					"use eci-active ledger-append",
					"append-only-ledger",
				)
				diagnostic.Path = lexical
				return DecisionDeny, diagnostic
			}
			if request.Role == RoleWorker && writer &&
				isReservedProofControlPath(lexical, resolved, proofSessions) {
				diagnostic := diagnosticForToken(
					CodePlanLiveControlDenied,
					"worker argv targets a reserved ECI control artifact inside the active proof session",
					segmentIndex,
					argumentIndex,
					pathArgument,
					"route the reserved ECI control operation through the coordinator",
					"worker-proof-control",
				)
				diagnostic.Path = lexical
				return DecisionDeny, diagnostic
			}
			if writer {
				return DecisionDefer, nil
			}
			if request.Role == RoleWorker && pathHasMissingComponent(lexical) &&
				isReservedProofControlPath(lexical, resolved, proofSessions) {
				return DecisionDefer, nil
			}
			continue
		}
		if request.Role == RoleWorker && pathHasMissingComponent(lexical) {
			for _, proofSession := range proofSessions {
				if pathWithin(lexical, proofSession.lexical) &&
					isReservedProofControlPath(lexical, resolved, proofSessions) {
					return DecisionDefer, nil
				}
			}
		}
		if containingSession == "" {
			if !anchorSearchComplete {
				return DecisionDefer, nil
			}
			continue
		}
		if resolveErr != nil {
			return DecisionDefer, nil
		}

		diagnostic := diagnosticForToken(
			CodeProofPathEscapeDenied,
			fmt.Sprintf("proof path resolves outside its active session aliases: resolved=%s proof_root=%s", resolved, containingSession),
			segmentIndex,
			argumentIndex,
			pathArgument,
			"replace the escaping symlink with a canonical path contained by the active proof session",
			"proof-symlink-escape",
		)
		diagnostic.Path = lexical
		return DecisionDeny, diagnostic
	}

	return DecisionAllow, nil
}

func pathHasMissingComponent(path string) bool {
	current := filepath.Clean(path)
	missing := false
	for {
		_, err := os.Lstat(current)
		switch {
		case err == nil:
			return missing
		case !errors.Is(err, fs.ErrNotExist):
			return true
		}
		missing = true
		parent := filepath.Dir(current)
		if parent == current {
			return true
		}
		current = parent
	}
}

func pathHasResolvedProofAnchor(path, resolvedProofRoot string) (bool, bool) {
	current := filepath.Clean(path)
	for range maxProofAnchors {
		resolved, err := resolvePathWithMissingSuffix(current)
		if err == nil && pathWithin(resolved, resolvedProofRoot) {
			return true, true
		}
		parent := filepath.Dir(current)
		if parent == current {
			return false, true
		}
		current = parent
	}
	return false, false
}

func pathOperand(argument token) (token, bool) {
	value := argument.value
	switch {
	case value == "":
		return token{}, false
	case value == "--":
		return token{}, false
	case strings.HasPrefix(value, "-"):
		separator := strings.IndexByte(value, '=')
		if separator < 0 || separator == len(value)-1 {
			return token{}, false
		}
		return token{
			value:  value[separator+1:],
			offset: argument.offset + separator + 1,
			quoted: argument.quoted,
		}, true
	default:
		return argument, true
	}
}

// commandPathOperand exposes command-specific key/value path operands to the
// shared ownership checks.  dd expresses its output destination as of=PATH,
// which is still a path operand even though it is not a positional argv path.
// Keep this normalization tied to the command shape rather than treating every
// arbitrary key/value argument as a filesystem path.
func commandPathOperand(command string, argument token) (token, bool) {
	if filepath.Base(command) == "dd" && strings.HasPrefix(argument.value, "of=") {
		value := strings.TrimPrefix(argument.value, "of=")
		if value == "" {
			return token{}, false
		}
		return token{
			value:  value,
			offset: argument.offset + len("of="),
			quoted: argument.quoted,
		}, true
	}
	return pathOperand(argument)
}

func outputDestinationOperand(argv []token, argumentIndex int) (token, bool) {
	if argumentIndex <= 0 || argumentIndex >= len(argv) || isGitArchiveCommand(argv) {
		return token{}, false
	}

	argument := argv[argumentIndex]
	value := argument.value
	for _, option := range [...]string{"--report-path", "--output", "--to-file"} {
		if strings.HasPrefix(value, option+"=") {
			path := strings.TrimPrefix(value, option+"=")
			if path == "" || strings.HasPrefix(path, "-") {
				return token{}, false
			}
			return token{value: path, offset: argument.offset + len(option) + 1, quoted: argument.quoted}, true
		}
		if value == option && argumentIndex+1 < len(argv) {
			path := argv[argumentIndex+1]
			if path.value == "" || strings.HasPrefix(path.value, "-") {
				return token{}, false
			}
			return path, true
		}
	}
	if value == "-o" && argumentIndex+1 < len(argv) {
		path := argv[argumentIndex+1]
		if path.value == "" || strings.HasPrefix(path.value, "-") {
			return token{}, false
		}
		return path, true
	}
	if strings.HasPrefix(value, "-o=") {
		path := strings.TrimPrefix(value, "-o=")
		if path == "" || strings.HasPrefix(path, "-") {
			return token{}, false
		}
		return token{value: path, offset: argument.offset + len("-o="), quoted: argument.quoted}, true
	}
	if strings.HasPrefix(value, "-o") && len(value) > len("-o") && !strings.HasPrefix(value, "--") {
		path := strings.TrimPrefix(value, "-o")
		if path == "" || strings.HasPrefix(path, "-") {
			return token{}, false
		}
		return token{value: path, offset: argument.offset + len("-o"), quoted: argument.quoted}, true
	}
	return token{}, false
}

func isGitArchiveCommand(argv []token) bool {
	if len(argv) == 0 || filepath.Base(argv[0].value) != "git" {
		return false
	}
	index := gitSubcommandIndex(argv)
	return index < len(argv) && argv[index].value == "archive"
}

func isReservedProofControlPath(lexical, resolved string, sessions []proofSession) bool {
	base := filepath.Base(lexical)
	reserved := false
	for _, name := range eciControlBasenames {
		if base == name || strings.HasPrefix(base, name+".") {
			reserved = true
			break
		}
	}
	if !reserved {
		return false
	}
	for _, session := range sessions {
		if pathWithin(lexical, session.lexical) ||
			(resolved != "" && pathWithin(resolved, session.resolved)) {
			return true
		}
	}
	return false
}

func isAppendOnlyLedgerPath(lexical, resolved string, sessions []proofSession) bool {
	base := filepath.Base(lexical)
	if base != "high_level_log.md" && base != "high_level_log.anchor" {
		return false
	}
	for _, session := range sessions {
		if pathWithin(lexical, session.lexical) ||
			(resolved != "" && pathWithin(resolved, session.resolved)) {
			return true
		}
	}
	return false
}

func resolvePathWithMissingSuffix(path string) (string, error) {
	current := filepath.Clean(path)
	missing := make([]string, 0)
	for {
		resolved, err := filepath.EvalSymlinks(current)
		switch {
		case err == nil:
			for index := len(missing) - 1; index >= 0; index-- {
				resolved = filepath.Join(resolved, missing[index])
			}
			return filepath.Clean(resolved), nil
		case !errors.Is(err, fs.ErrNotExist):
			return "", err
		}

		parent := filepath.Dir(current)
		if parent == current {
			return "", err
		}
		missing = append(missing, filepath.Base(current))
		current = parent
	}
}

func pathWithin(path, root string) bool {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func unwrap(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	current := argv
	for depth := 0; depth < maxWrapperDepth; depth++ {
		name := filepath.Base(current[0].value)
		switch name {
		case "env":
			child, diagnostic := unwrapEnv(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "command":
			child, diagnostic := unwrapSimpleOptions(current, segmentIndex, map[string]int{"-p": 0, "--": 0})
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "exec":
			child, diagnostic := unwrapSimpleOptions(current, segmentIndex, map[string]int{"-a": 1, "-c": 0, "-l": 0, "--": 0})
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "nice":
			child, diagnostic := unwrapNice(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "timeout":
			child, diagnostic := unwrapTimeout(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "time":
			child, diagnostic := unwrapTime(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "prlimit":
			child, diagnostic := unwrapPrlimit(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "chronic":
			child, diagnostic := unwrapSimpleOptions(current, segmentIndex, map[string]int{
				"-e": 0, "-f": 0, "-v": 0, "-d": 0, "-s": 0, "--": 0,
			})
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "nohup":
			child, diagnostic := unwrapSimpleOptions(current, segmentIndex, map[string]int{"--": 0})
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "setsid":
			child, diagnostic := unwrapSimpleOptions(current, segmentIndex, map[string]int{
				"-c": 0, "-f": 0, "-w": 0, "--wait": 0, "--fork": 0, "--ctty": 0, "--": 0,
			})
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "sudo":
			child, diagnostic := unwrapSudo(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "doas":
			child, diagnostic := unwrapDoas(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "systemd-run":
			child, diagnostic := unwrapSystemdRun(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "stdbuf":
			child, diagnostic := unwrapStdbuf(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		case "busybox":
			child, diagnostic := unwrapBusybox(current, segmentIndex)
			if diagnostic != nil {
				return nil, diagnostic
			}
			current = child
		default:
			return current, nil
		}
	}

	return nil, diagnosticForToken(
		CodePlanWrapperDenied,
		fmt.Sprintf("transparent wrapper depth exceeds %d", maxWrapperDepth),
		segmentIndex,
		0,
		current[0],
		"remove redundant wrappers and invoke one finite child argv",
		"wrapper-depth-limit",
	)
}

func unwrapSudo(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	return unwrapKnownOptions(argv, segmentIndex, map[string]int{
		"-u": 1, "--user": 1, "-g": 1, "--group": 1, "-h": 1, "--host": 1,
		"-p": 1, "--prompt": 1, "-r": 1, "--role": 1, "-t": 1, "--type": 1,
		"-T": 1, "--command-timeout": 1, "-C": 1, "--chdir": 1, "-D": 1,
		"--": 0,
	}, map[string]struct{}{
		"-A": {}, "--askpass": {}, "-b": {}, "--background": {}, "-E": {}, "--preserve-env": {},
		"-H": {}, "--set-home": {}, "-i": {}, "--login": {}, "-K": {}, "--remove-timestamp": {},
		"-k": {}, "--reset-timestamp": {}, "-n": {}, "--non-interactive": {}, "-P": {},
		"--preserve-groups": {}, "-S": {}, "--stdin": {}, "-V": {}, "--version": {},
	}, "sudo")
}

func unwrapDoas(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	return unwrapKnownOptions(argv, segmentIndex, map[string]int{
		"-a": 1, "--auth-type": 1, "-C": 1, "--config": 1, "-u": 1, "--user": 1, "--": 0,
	}, map[string]struct{}{
		"-n": {}, "--non-interactive": {},
	}, "doas")
}

func unwrapSystemdRun(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	return unwrapKnownOptions(argv, segmentIndex, map[string]int{
		"--unit": 1, "-p": 1, "--property": 1, "--working-directory": 1, "--service-type": 1,
		"--uid": 1, "--gid": 1, "--slice": 1, "--machine": 1, "--pipe": 0, "--pty": 0,
		"--quiet": 0, "--wait": 0, "--collect": 0, "--user": 0, "--system": 0, "--scope": 0,
		"--service": 0, "--remain-after-exit": 0, "--send-sighup": 0, "--same-dir": 0,
		"--working-directory=": 0, "--unit=": 0, "--property=": 0, "--": 0,
	}, nil, "systemd-run")
}

// unwrapStdbuf returns the finite child argv selected by the stdbuf launcher.
//
// Example: stdbuf -oL chmod 644 hooks/validate-bash.sh selects chmod as the child.
func unwrapStdbuf(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	index := 1
	for index < len(argv) {
		value := argv[index].value
		switch {
		case value == "--":
			index++
			if index >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index-1], segmentIndex, index-1)
			}
			return argv[index:], nil
		case value == "-i", value == "-o", value == "-e", value == "--input", value == "--output", value == "--error":
			if index+1 >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
			}
			index += 2
		case (strings.HasPrefix(value, "-i") || strings.HasPrefix(value, "-o") || strings.HasPrefix(value, "-e")) && len(value) > 2:
			index++
		case strings.HasPrefix(value, "--input="), strings.HasPrefix(value, "--output="), strings.HasPrefix(value, "--error="):
			index++
		case strings.HasPrefix(value, "-"):
			return nil, diagnosticForToken(
				CodePlanWrapperDenied,
				fmt.Sprintf("stdbuf has unsupported option %s before its child argv", value),
				segmentIndex,
				index,
				argv[index],
				"remove unsupported stdbuf option and provide one literal child argv",
				"unsupported-transparent-wrapper-option",
			)
		default:
			return argv[index:], nil
		}
	}
	return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
}

// unwrapBusybox returns the BusyBox applet argv after its optional separator.
//
// Example: busybox -- chmod 644 hooks/validate-bash.sh selects chmod as the applet.
func unwrapBusybox(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	index := 1
	if index < len(argv) && argv[index].value == "--" {
		index++
	}
	if index >= len(argv) {
		return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
	}
	return argv[index:], nil
}

func unwrapKnownOptions(
	argv []token,
	segmentIndex int,
	arguments map[string]int,
	flags map[string]struct{},
	name string,
) ([]token, *Diagnostic) {
	index := 1
	for index < len(argv) {
		value := argv[index].value
		if value == "--" {
			index++
			break
		}
		if count, ok := arguments[value]; ok {
			if index+count >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
			}
			index += count + 1
			continue
		}
		if _, ok := flags[value]; ok {
			index++
			continue
		}
		matchedAttached := false
		for option := range arguments {
			if strings.HasSuffix(option, "=") && strings.HasPrefix(value, option) && len(value) > len(option) {
				matchedAttached = true
				break
			}
		}
		if matchedAttached {
			index++
			continue
		}
		if strings.HasPrefix(value, "-") {
			return nil, diagnosticForToken(
				CodePlanWrapperDenied,
				fmt.Sprintf("%s has unsupported option %s before its child argv", name, value),
				segmentIndex,
				index,
				argv[index],
				fmt.Sprintf("remove unsupported %s option and provide one literal child argv", name),
				"unsupported-transparent-wrapper-option",
			)
		}
		break
	}
	if index >= len(argv) {
		return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
	}
	return argv[index:], nil
}

func unwrapEnv(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	index := 1
	optionsEnded := false
	for index < len(argv) && !optionsEnded {
		value := argv[index].value
		switch {
		case value == "--":
			optionsEnded = true
			index++
		case value == "-i", value == "--ignore-environment":
			index++
		case value == "-S", value == "--split-string", strings.HasPrefix(value, "--split-string="):
			return nil, diagnosticForToken(
				CodeEnvironmentOptionDenied,
				"env split-string constructs argv dynamically",
				segmentIndex,
				index,
				argv[index],
				"remove split-string and pass the child argv literally",
				"environment-split-string",
			)
		case value == "-u", value == "--unset", value == "-C", value == "--chdir":
			if index+1 >= len(argv) {
				return nil, diagnosticForToken(
					CodeEnvironmentOptionDenied,
					fmt.Sprintf("env option %s is missing its required argument", value),
					segmentIndex,
					index,
					argv[index],
					"supply the required literal option argument",
					"environment-missing-option-argument",
				)
			}
			index += 2
		case strings.HasPrefix(value, "--unset="):
			if !isIdentifier(strings.TrimPrefix(value, "--unset=")) {
				return nil, diagnosticForToken(
					CodeEnvironmentOptionDenied,
					fmt.Sprintf("env option %s argument is not a valid identifier", value),
					segmentIndex,
					index,
					argv[index],
					"supply --unset=NAME with one literal environment identifier",
					"environment-invalid-option-argument",
				)
			}
			index++
		case strings.HasPrefix(value, "--chdir="):
			index++
		case strings.HasPrefix(value, "-"):
			return nil, diagnosticForToken(
				CodeEnvironmentOptionDenied,
				fmt.Sprintf("unsupported env option %s", value),
				segmentIndex,
				index,
				argv[index],
				"use -i, -u NAME, -C DIR, assignments, --, and a literal child argv",
				"environment-unsupported-option",
			)
		default:
			optionsEnded = true
		}
	}

	for index < len(argv) {
		name := assignmentName(argv[index])
		if name == "" {
			break
		}
		if isEnvironmentContextName(name) {
			redacted := token{value: name, offset: argv[index].offset}
			contextKind := "registered interpreter"
			if strings.HasPrefix(name, "GIT_") {
				contextKind = "registered repository"
			}
			return nil, diagnosticForToken(
				CodeEnvironmentContextDenied,
				fmt.Sprintf("environment assignment name %s changes %s context", name, contextKind),
				segmentIndex,
				index,
				redacted,
				fmt.Sprintf("remove the %s context assignment and invoke the literal child directly", name),
				"environment-context-assignment",
			)
		}
		index++
	}
	if index >= len(argv) {
		return nil, diagnosticForToken(
			CodeEnvironmentEnumerationDenied,
			"env has no remaining child executable and would enumerate inherited environment state",
			segmentIndex,
			0,
			argv[0],
			"provide one finite literal child argv after env options and assignments",
			"environment-enumeration",
		)
	}

	return argv[index:], nil
}

func unwrapSimpleOptions(
	argv []token,
	segmentIndex int,
	options map[string]int,
) ([]token, *Diagnostic) {
	index := 1
	for index < len(argv) {
		argumentCount, exists := options[argv[index].value]
		if !exists {
			break
		}
		if index+argumentCount >= len(argv) {
			return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
		}
		index += argumentCount + 1
	}
	if index >= len(argv) {
		return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
	}
	return argv[index:], nil
}

func unwrapNice(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	index := 1
	for index < len(argv) {
		switch {
		case argv[index].value == "--":
			index++
			if index >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index-1], segmentIndex, index-1)
			}
			return argv[index:], nil
		case argv[index].value == "-n", argv[index].value == "--adjustment":
			if index+1 >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
			}
			index += 2
		case strings.HasPrefix(argv[index].value, "--adjustment="):
			index++
		default:
			return argv[index:], nil
		}
	}
	return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
}

func unwrapTimeout(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	index := 1
	for index < len(argv) {
		value := argv[index].value
		switch {
		case value == "--":
			index++
		case value == "-k", value == "--kill-after", value == "-s", value == "--signal":
			if index+1 >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
			}
			index += 2
		case strings.HasPrefix(value, "--kill-after="), strings.HasPrefix(value, "--signal="), value == "-v", value == "--verbose", value == "--foreground", value == "--preserve-status":
			index++
		default:
			if index+1 >= len(argv) {
				return nil, malformedWrapperDiagnostic(argv[index], segmentIndex, index)
			}
			return argv[index+1:], nil
		}
	}
	return nil, malformedWrapperDiagnostic(argv[0], segmentIndex, 0)
}

func unwrapTime(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	return unwrapKnownOptions(argv, segmentIndex, map[string]int{
		"-f": 1, "--format": 1, "-o": 1, "--output": 1, "--": 0,
	}, map[string]struct{}{
		"--append": {}, "--verbose": {},
	}, "time")
}

func unwrapPrlimit(argv []token, segmentIndex int) ([]token, *Diagnostic) {
	return unwrapKnownOptions(argv, segmentIndex, map[string]int{
		"--pid": 1, "--output": 1, "--": 0,
		"--as=": 0, "--core=": 0, "--cpu=": 0, "--data=": 0,
		"--fsize=": 0, "--locks=": 0, "--memlock=": 0, "--msgqueue=": 0,
		"--nice=": 0, "--nofile=": 0, "--nproc=": 0, "--rss=": 0,
		"--rtprio=": 0, "--rttime=": 0, "--sigpending=": 0, "--stack=": 0,
	}, map[string]struct{}{
		"--verbose": {}, "--noheadings": {}, "--raw": {},
	}, "prlimit")
}

func inspectPrintenv(argv []token, segmentIndex int) *Diagnostic {
	if len(argv) == 1 {
		return diagnosticForToken(
			CodeEnvironmentEnumerationDenied,
			"printenv has no queried names and would enumerate inherited environment state",
			segmentIndex,
			0,
			argv[0],
			"query one to sixteen registered environment names explicitly",
			"environment-enumeration",
		)
	}
	if len(argv) > 17 {
		return diagnosticForToken(
			CodeEnvironmentNameDenied,
			"printenv query exceeds sixteen unique registered names",
			segmentIndex,
			17,
			argv[17],
			"query at most sixteen unique registered names",
			"environment-name-limit",
		)
	}
	seen := make(map[string]struct{}, len(argv)-1)
	for index, argument := range argv[1:] {
		name := argument.value
		if strings.HasPrefix(name, "-") {
			return diagnosticForToken(
				CodeEnvironmentOptionDenied,
				fmt.Sprintf("printenv option %s is unsupported", name),
				segmentIndex,
				index+1,
				argument,
				"remove the reported option and query one to sixteen registered environment names explicitly",
				"environment-option-unsupported",
			)
		}
		if !isIdentifier(name) {
			return diagnosticForToken(
				CodeEnvironmentEnumerationDenied,
				fmt.Sprintf("printenv query token %s is not an identifier", name),
				segmentIndex,
				index+1,
				argument,
				"query one literal registered environment identifier",
				"environment-invalid-name",
			)
		}
		if _, exists := seen[name]; exists {
			return diagnosticForToken(
				CodeEnvironmentEnumerationDenied,
				fmt.Sprintf("printenv query name %s is duplicated", name),
				segmentIndex,
				index+1,
				argument,
				"query each registered environment name at most once",
				"environment-duplicate-name",
			)
		}
		if !isPublicEnvironmentName(name) {
			return diagnosticForToken(
				CodeEnvironmentNameDenied,
				fmt.Sprintf("printenv query name at argv index %d has status=unregistered", index+1),
				segmentIndex,
				index+1,
				argument,
				"query only unique names from the provider-parity public environment registry",
				"environment-name-unregistered",
			)
		}
		seen[name] = struct{}{}
	}
	return nil
}

func inspectInterpreter(name string, argv []token, segmentIndex int) *Diagnostic {
	runtime := namedRuntimeFamily(name)
	if runtime != "" {
		return inspectNamedRuntime(runtime, argv, segmentIndex)
	}
	for index, argument := range argv[1:] {
		if interpreterInlineCodeArgument("", argument.value) {
			return diagnosticForToken(
				CodePlanDynamicLaunchDenied,
				"inline or stdin interpreter code hides the executed argv",
				segmentIndex,
				index+1,
				argument,
				"invoke a literal script path or direct executable argv",
				"dynamic-interpreter-launch",
			)
		}
	}
	return nil
}

// inspectNamedRuntime accepts only a runtime selector followed by a visible
// literal target; every trailing argument belongs to that confirmed target.
//
// Example: python3 -m pytest -c is a module invocation with script argv.
func inspectNamedRuntime(
	runtime string,
	argv []token,
	segmentIndex int,
) *Diagnostic {
	arguments := argv[1:]
	if len(arguments) == 0 {
		return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 0, argv[0])
	}

	selector := arguments[0]
	if interpreterInlineCodeArgument(runtime, selector.value) {
		return diagnosticForToken(
			CodePlanDynamicLaunchDenied,
			"inline or stdin interpreter code hides the executed argv",
			segmentIndex,
			1,
			selector,
			"invoke a literal script path or direct executable argv",
			"dynamic-interpreter-launch",
		)
	}

	if runtime == "python" && selector.value == "-m" {
		if len(arguments) > 1 && isLiteralRuntimeTarget(arguments[1]) {
			return nil
		}
		if len(arguments) > 1 {
			return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 2, arguments[1])
		}
		return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 1, selector)
	}
	if runtime == "php" && (selector.value == "-f" || selector.value == "-F") {
		if len(arguments) > 1 && isLiteralRuntimeTarget(arguments[1]) {
			return nil
		}
		if len(arguments) > 1 {
			return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 2, arguments[1])
		}
		return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 1, selector)
	}
	if isLiteralRuntimeTarget(selector) {
		return nil
	}
	return literalRuntimeTargetDiagnostic(runtime, segmentIndex, 1, selector)
}

// literalRuntimeTargetDiagnostic reports a named runtime invocation that has
// no supported literal selector and target.
//
// Example: python3 -W ignore is not a direct source or module invocation.
func literalRuntimeTargetDiagnostic(
	runtime string,
	segmentIndex int,
	argvIndex int,
	argument token,
) *Diagnostic {
	return diagnosticForToken(
		CodePlanDynamicLaunchDenied,
		fmt.Sprintf("%s runtime argv has no supported literal source, module, or test target", runtime),
		segmentIndex,
		argvIndex,
		argument,
		"invoke a literal script or the runtime's supported literal selector before trailing argv",
		"dynamic-interpreter-launch",
	)
}

// interpreterInlineCodeArgument reports whether value makes a recognized
// interpreter execute inline or stdin-provided code.
//
// Example: Python -cprint and PHP -recho both execute code from argv.
func interpreterInlineCodeArgument(
	runtime string,
	value string,
) bool {
	if value == "-c" || value == "-s" || value == "-" || value == "--stdin" {
		return true
	}

	switch runtime {
	case "python":
		return strings.HasPrefix(value, "-c")
	case "node", "nodejs":
		return value == "-e" || value == "--eval" || value == "-p" || value == "--print" ||
			strings.HasPrefix(value, "-e=") || strings.HasPrefix(value, "--eval=") ||
			strings.HasPrefix(value, "-p=") || strings.HasPrefix(value, "--print=")
	case "perl":
		return value == "-e" || value == "-E" || strings.HasPrefix(value, "-e") || strings.HasPrefix(value, "-E")
	case "ruby":
		return value == "-e" || strings.HasPrefix(value, "-e")
	case "php":
		return value == "-a" || phpInlineCodeArgument(value, "-r", "--run") ||
			phpInlineCodeArgument(value, "-B", "--process-begin") ||
			phpInlineCodeArgument(value, "-R", "--process-code") ||
			phpInlineCodeArgument(value, "-E", "--process-end")
	default:
		return false
	}
}

// phpInlineCodeArgument reports whether value is a PHP code option. PHP
// accepts attached short-option payloads, while long options attach only with
// an equals sign.
//
// Example: -recho and --run=echo are both inline code forms.
func phpInlineCodeArgument(
	value string,
	shortOption string,
	longOption string,
) bool {
	return strings.HasPrefix(value, shortOption) || value == longOption || strings.HasPrefix(value, longOption+"=")
}

// isLiteralRuntimeTarget reports whether argument is a nonempty visible
// source, module, or test target rather than a runtime option.
//
// Example: pytest is a target, while -W is a runtime option.
func isLiteralRuntimeTarget(argument token) bool {
	return argument.value != "" && !strings.HasPrefix(argument.value, "-")
}

func inspectGit(
	request Request,
	argv []token,
	segmentIndex int,
) (DecisionKind, *Diagnostic) {
	repositoryContext := false
	approvedRepositoryContext := true
	repositoryContextCount := 0
	for index, argument := range argv[1:] {
		if argument.value == "-C" {
			repositoryContext = true
			repositoryContextCount++
			if index+2 >= len(argv) || !approvedGitRepositoryContext(request, argv[index+2].value) {
				approvedRepositoryContext = false
			}
		}
		if strings.HasPrefix(argument.value, "-C") && len(argument.value) > 2 {
			repositoryContext = true
			repositoryContextCount++
			if !approvedGitRepositoryContext(request, argument.value[2:]) {
				approvedRepositoryContext = false
			}
		}
		if isGitContextOption(argument.value) {
			return DecisionDeny, diagnosticForToken(
				CodeGitExecutionContextDenied,
				"Git execution or repository context is overridden by a visible option",
				segmentIndex,
				index+1,
				argument,
				"remove the reported Git context option and use the bounded coordinator Git route for repository-default inspection",
				"git-execution-context",
			)
		}
	}
	if repositoryContextCount > 1 {
		approvedRepositoryContext = false
	}
	subcommandIndex := gitSubcommandIndex(argv)
	if subcommandIndex >= len(argv) {
		return DecisionAllow, nil
	}
	mutationIndex, action := gitMutation(argv, subcommandIndex)
	if repositoryContext {
		// Repository selection is provider-owned capability: the adapter must
		// establish that the target is one approved canonical root before a
		// worker can use an otherwise read-only Git verb. Preserve the worker
		// ownership diagnostic for mutations even when a -C context is visible.
		if action != "" && request.Marker == MarkerActive && request.Role == RoleWorker {
			return DecisionDeny, diagnosticForToken(
				CodeWorkerGitOwnershipDenied,
				fmt.Sprintf("worker argv selects acceptance-sensitive Git operation %s", action),
				segmentIndex,
				mutationIndex,
				argv[mutationIndex],
				"route this exact Git mutation through the main/orchestrator coordinator acceptance path",
				"worker-git-ownership",
			)
		}
		if request.Role == RoleCoordinator && approvedRepositoryContext && action == "" {
			return DecisionAllow, nil
		}
		// In particular this prevents an active worker fast path from
		// admitting git -C /tmp/foreign status without approved-root proof.
		return DecisionDefer, nil
	}
	if action == "" {
		return DecisionAllow, nil
	}
	if request.Marker == MarkerActive && request.Role == RoleWorker {
		return DecisionDeny, diagnosticForToken(
			CodeWorkerGitOwnershipDenied,
			fmt.Sprintf("worker argv selects acceptance-sensitive Git operation %s", action),
			segmentIndex,
			mutationIndex,
			argv[mutationIndex],
			"route this exact Git mutation through the main/orchestrator coordinator acceptance path",
			"worker-git-ownership",
		)
	}
	return DecisionDefer, nil
}

// approvedGitRepositoryContext reports whether value exactly matches a canonical approved repository root.
//
// Example: /home/user/project matches the same entry in Request.ApprovedRoots.
func approvedGitRepositoryContext(request Request, value string) bool {
	if value == "" || !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return false
	}
	for _, root := range request.ApprovedRoots {
		if root != "" && filepath.IsAbs(root) && filepath.Clean(root) == root && root == value {
			return true
		}
	}
	return false
}

func inspectBroadDestruction(argv []token, segmentIndex int) *Diagnostic {
	name := filepath.Base(argv[0].value)
	if strings.HasPrefix(name, "mkfs") {
		return diagnosticForToken(
			CodeBroadDestructiveDenied,
			"filesystem formatting is a broad destructive operation",
			segmentIndex,
			0,
			argv[0],
			"remove the filesystem-format operation and use a scoped non-destructive command",
			"broad-destructive-filesystem",
		)
	}
	if name != "rm" {
		return nil
	}
	recursive := false
	force := false
	rootIndex := -1
	for index, argument := range argv[1:] {
		value := argument.value
		if value == "--recursive" || value == "-r" || value == "-R" ||
			strings.HasPrefix(value, "-") && (strings.Contains(value, "r") || strings.Contains(value, "R")) {
			recursive = true
		}
		if value == "--force" || value == "-f" || strings.HasPrefix(value, "-") && strings.Contains(value, "f") {
			force = true
		}
		if value == "/" || value == "~" {
			rootIndex = index + 1
		}
	}
	if recursive && force && rootIndex >= 0 {
		diagnostic := diagnosticForToken(
			CodeBroadDestructiveDenied,
			"recursive forced deletion selects a broad root",
			segmentIndex,
			rootIndex,
			argv[rootIndex],
			"replace the broad root with one explicit narrow recoverable target",
			"broad-destructive-root",
		)
		diagnostic.Path = argv[rootIndex].value
		return diagnostic
	}
	return nil
}

type activeControlFile struct {
	path string
	info os.FileInfo
}

type activeControlIndex struct {
	files    []activeControlFile
	overflow bool
}

func activeControlFileIndex(markers []string) activeControlIndex {
	index := activeControlIndex{
		files: make([]activeControlFile, 0, len(markers)*len(eciControlBasenames)),
	}
	seenSessionDirs := make(map[string]struct{}, len(markers))
	for _, marker := range markers {
		sessionDir := filepath.Clean(filepath.Dir(marker))
		if _, seen := seenSessionDirs[sessionDir]; seen {
			continue
		}
		seenSessionDirs[sessionDir] = struct{}{}
		directory, err := os.Open(sessionDir)
		if err != nil {
			continue
		}
		entries, err := directory.ReadDir(maxActiveControlEntries + 1)
		closeErr := directory.Close()
		if err != nil && !errors.Is(err, io.EOF) {
			continue
		}
		if closeErr != nil {
			continue
		}
		if len(entries) > maxActiveControlEntries {
			index.overflow = true
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if entry.Type()&os.ModeSymlink != 0 || !isECIControlBasename(name) {
				continue
			}
			info, err := entry.Info()
			if err != nil || !info.Mode().IsRegular() {
				continue
			}
			index.files = append(index.files, activeControlFile{
				path: filepath.Join(sessionDir, entry.Name()),
				info: info,
			})
		}
	}
	return index
}

func isECIControlBasename(value string) bool {
	for _, name := range eciControlBasenames {
		if value == name || strings.HasPrefix(value, name+".") {
			return true
		}
	}
	return false
}

func activeControlHardlinkPath(path string, index []activeControlFile) string {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	for _, control := range index {
		if os.SameFile(info, control.info) {
			return control.path
		}
	}
	return ""
}

func isCanonicalWorkerHandoffPath(path string, markers []string) bool {
	base := filepath.Base(path)
	switch base {
	case "instructions.md", "project-understanding.md", "high_level_log.md", "latest-status-report.md":
		for _, marker := range markers {
			if path == filepath.Join(filepath.Dir(marker), base) {
				return true
			}
		}
	}
	return false
}

// activeControlResolvedPath follows one candidate alias and compares its
// target inode with the bounded active-control index.  This catches both
// arbitrary hardlink names and symlink aliases before a worker fast path can
// treat the candidate as an ordinary executable/path operand.
func activeControlResolvedPath(path string, index []activeControlFile) string {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	for _, control := range index {
		if os.SameFile(info, control.info) {
			return control.path
		}
	}
	return ""
}

func inspectLiveControl(request Request, argv []token, segmentIndex int) *Diagnostic {
	controlIndex := activeControlFileIndex(request.ActiveMarkers)
	if controlIndex.overflow {
		return diagnosticForToken(
			CodePlanLiveControlDenied,
			"bounded active-control index overflowed before worker ownership could be established",
			segmentIndex,
			0,
			argv[0],
			"reduce the active session control-record count below the bounded index limit, then retry",
			"bounded-control-index",
		)
	}
	for argumentIndex, argument := range argv[1:] {
		pathArgument, pathLike := commandPathOperand(argv[0].value, argument)
		if !pathLike {
			continue
		}
		candidate := pathArgument.value
		if !filepath.IsAbs(candidate) {
			candidate = filepath.Join(request.CWD, candidate)
		}
		candidate = filepath.Clean(candidate)
		for _, markerPath := range request.ActiveMarkers {
			cleanMarker := filepath.Clean(markerPath)
			if candidate == cleanMarker {
				diagnostic := diagnosticForToken(
					CodePlanLiveControlDenied,
					"worker argv resolves to an exact active-session live-control artifact",
					segmentIndex,
					argumentIndex+1,
					pathArgument,
					"route this exact live-control operation through the coordinator",
					"worker-live-control",
				)
				diagnostic.Path = candidate
				return diagnostic
			}
		}
		if isCanonicalWorkerHandoffPath(candidate, request.ActiveMarkers) {
			continue
		}
		if controlPath := activeControlResolvedPath(candidate, controlIndex.files); controlPath != "" {
			diagnostic := diagnosticForToken(
				CodePlanLiveControlDenied,
				"worker argv inode matches an active-session live-control artifact",
				segmentIndex,
				argumentIndex+1,
				pathArgument,
				"route this exact live-control operation through the coordinator",
				"worker-live-control",
			)
			diagnostic.Path = controlPath
			return diagnostic
		}
	}
	return nil
}

func deniedResult(request Request, diagnostic Diagnostic) Result {
	marker := string(request.Marker)
	reason := fmt.Sprintf(
		"[%s] ECI gate denied (phase=PreToolUse, operation=%s, provider=%s, role=%s, marker=%s, segment=%d, argv_index=%d, byte_offset=%d, token=%s, path=%s, predicate=%s); reason: %s; rejected segment=%s; remediation: %s.",
		diagnostic.Code,
		diagnostic.Operation,
		request.Provider,
		request.Role,
		marker,
		diagnostic.Segment,
		diagnostic.ArgvIndex,
		diagnostic.ByteOffset,
		shellEscape(diagnostic.Token),
		shellEscape(diagnostic.Path),
		diagnostic.Predicate,
		diagnostic.Reason,
		diagnostic.RejectedSegment,
		diagnostic.Remediation,
	)
	return Result{
		Decision:   DecisionDeny,
		Diagnostic: &diagnostic,
		HookSpecificOutput: &HookSpecificOutput{
			HookEventName:            "PreToolUse",
			PermissionDecision:       "deny",
			PermissionDecisionReason: reason,
		},
	}
}

func suppressInactiveDiagnostic(request Request, diagnostic *Diagnostic) bool {
	if request.Marker != MarkerInactive {
		return false
	}
	if diagnostic.Operation == "worker-control" {
		return false
	}
	code := string(diagnostic.Code)
	return !strings.HasPrefix(code, "ECI_ENVIRONMENT_") &&
		!strings.HasPrefix(code, "ECI_GIT_")
}

func newPlanError(
	code DiagnosticCode,
	reason string,
	offset int,
	segmentIndex int,
	argvIndex int,
	tokenValue string,
	remediation string,
	predicate string,
) *planError {
	return &planError{diagnostic: Diagnostic{
		Code:        code,
		Operation:   operationForCode(code),
		Segment:     segmentIndex,
		ArgvIndex:   argvIndex,
		ByteOffset:  offset,
		Token:       tokenValue,
		Path:        "n/a",
		Predicate:   predicate,
		Reason:      reason,
		Remediation: remediation,
	}}
}

func diagnosticForToken(
	code DiagnosticCode,
	reason string,
	segmentIndex int,
	argvIndex int,
	argument token,
	remediation string,
	predicate string,
) *Diagnostic {
	return &Diagnostic{
		Code:        code,
		Operation:   operationForCode(code),
		Segment:     segmentIndex,
		ArgvIndex:   argvIndex,
		ByteOffset:  argument.offset,
		Token:       argument.value,
		Path:        "n/a",
		Predicate:   predicate,
		Reason:      reason,
		Remediation: remediation,
	}
}

func operationForCode(code DiagnosticCode) string {
	value := string(code)
	switch {
	case strings.HasPrefix(value, "ECI_PLAN_"):
		return "plan-segment"
	case strings.HasPrefix(value, "ECI_ENVIRONMENT_"):
		return "environment-boundary"
	case code == CodeWorkerGitOwnershipDenied:
		return "worker-git-ownership"
	case code == CodeGitExecutionContextDenied:
		return "git-execution-context"
	case code == CodeControlOwnerRequired, code == CodeControlIdentityDenied, code == CodePlanLiveControlDenied:
		return "worker-control"
	case code == CodeBroadDestructiveDenied:
		return "broad-destructive"
	case code == CodeLedgerAppendOnly:
		return "ledger-append-only"
	case code == CodeProofPathEscapeDenied:
		return "proof-path-ownership"
	default:
		return "plan-segment"
	}
}

func malformedWrapperDiagnostic(argument token, segmentIndex int, argvIndex int) *Diagnostic {
	return diagnosticForToken(
		CodePlanWrapperDenied,
		"transparent wrapper has no complete literal child argv",
		segmentIndex,
		argvIndex,
		argument,
		"supply the wrapper's required options and one literal child argv",
		"malformed-transparent-wrapper",
	)
}

func assignmentName(argument token) string {
	if argument.quoted {
		return ""
	}
	separator := strings.IndexByte(argument.value, '=')
	if separator <= 0 || !isIdentifier(argument.value[:separator]) {
		return ""
	}
	return argument.value[:separator]
}

func isIdentifier(value string) bool {
	if value == "" || !isIdentifierFirst(value[0]) {
		return false
	}
	for index := 1; index < len(value); index++ {
		if !isIdentifierRest(value[index]) {
			return false
		}
	}
	return true
}

func isIdentifierFirst(character byte) bool {
	return character == '_' || character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z'
}

func isIdentifierRest(character byte) bool {
	return isIdentifierFirst(character) || character >= '0' && character <= '9'
}

func isReservedControl(argument token) bool {
	if argument.quoted || argument.value == "time" {
		return false
	}
	switch argument.value {
	case "!", "[[", "]]", "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "until", "while":
		return true
	default:
		return false
	}
}

func isPublicEnvironmentName(name string) bool {
	switch name {
	case "CODEX_HOME", "CODEX_ROLE", "CODEX_SESSION_ID", "HOME", "KIMI_CODE_HOME", "KIMI_ROLE", "KIMI_SESSION_ID", "PATH", "PWD", "SESSION_ID", "TMPDIR":
		return true
	default:
		return false
	}
}

func isEnvironmentContextName(name string) bool {
	if strings.HasPrefix(name, "GIT_") {
		return true
	}
	switch name {
	case "BASH_ENV", "ENV", "PERL5OPT", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "RUBYOPT":
		return true
	default:
		return false
	}
}

func isInterpreter(name string) bool {
	if namedRuntimeFamily(name) != "" {
		return true
	}
	switch name {
	case "bash", "dash", "sh", "zsh":
		return true
	default:
		return false
	}
}

// namedRuntimeFamily recognizes only runtime basenames and numeric version
// suffixes. Arbitrary similarly named helper executables remain ordinary argv.
//
// Example: python3.11 is Python, while python-tool is not a runtime alias.
func namedRuntimeFamily(name string) string {
	for _, runtime := range [...]string{"python", "nodejs", "node", "perl", "ruby", "php"} {
		if name == runtime {
			if runtime == "nodejs" {
				return "node"
			}
			return runtime
		}
		if strings.HasPrefix(name, runtime) && isNumericVersionSuffix(strings.TrimPrefix(name, runtime)) {
			if runtime == "nodejs" {
				return "node"
			}
			return runtime
		}
	}
	return ""
}

// isNumericVersionSuffix reports whether value is a dot-separated numeric
// runtime version suffix.
//
// Example: 3.11 is valid, while -tool and 3..11 are not.
func isNumericVersionSuffix(value string) bool {
	if value == "" {
		return false
	}
	previousDot := true
	for _, character := range value {
		switch {
		case character >= '0' && character <= '9':
			previousDot = false
		case character == '.' && !previousDot:
			previousDot = true
		default:
			return false
		}
	}
	return !previousDot
}

func isLifecycleScriptCapability(cwd string, argv []token) bool {
	if isLifecycleScriptPath(cwd, argv[0].value) {
		return true
	}
	if !isShellInterpreter(filepath.Base(argv[0].value)) {
		return false
	}

	index := 1
	for index < len(argv) {
		value := argv[index].value
		switch value {
		case "--":
			index++
			if index >= len(argv) {
				return false
			}
			return isLifecycleScriptPath(cwd, argv[index].value)
		case "-e", "-n", "--noexec", "-x", "--trace", "--noprofile", "--norc", "--posix", "--restricted", "--verbose":
			index++
		case "-O":
			if index+1 >= len(argv) {
				return false
			}
			index += 2
		default:
			if strings.HasPrefix(value, "-") {
				return false
			}
			return isLifecycleScriptPath(cwd, value)
		}
	}

	return false
}

func isLifecycleScriptPath(cwd, value string) bool {
	if filepath.Base(value) == value {
		return isLifecycleName(value)
	}

	cleaned := filepath.Clean(value)
	if !filepath.IsAbs(cleaned) {
		cleaned = filepath.Join(cwd, cleaned)
	}
	resolved := resolvePathIdentity(cleaned)
	switch {
	case filepath.Base(filepath.Dir(resolved)) == "hooks":
		switch filepath.Base(resolved) {
		case "eci-review-gate.sh", "eci-active-gate.sh", "stop-gate.sh":
			return true
		default:
			return false
		}
	case filepath.Base(filepath.Dir(resolved)) == "bin":
		return filepath.Base(resolved) == "eci-active"
	default:
		return false
	}
}

func resolvePathIdentity(path string) string {
	resolved, err := resolvePathWithMissingSuffix(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return resolved
}

func isShellInterpreter(name string) bool {
	switch name {
	case "bash", "dash", "sh", "zsh":
		return true
	default:
		return false
	}
}

func isLifecycleName(name string) bool {
	switch name {
	case "eci-active", "eci-active-gate.sh", "eci-review-gate", "eci-review-gate.sh", "eci-stage", "stop-gate.sh":
		return true
	default:
		return false
	}
}

func isCoordinatorHookRepair(argv []token) bool {
	if len(argv) < 4 || !isInterpreter(filepath.Base(argv[0].value)) {
		return false
	}
	for index := 1; index+1 < len(argv); index++ {
		if filepath.Base(argv[index].value) == "install-pre-commit-go-mod.sh" &&
			argv[index+1].value == "--repair-hardlink" {
			return true
		}
	}
	return false
}

// isPreCommitHookModeRepair recognizes only the exact direct pre-commit hook mode repair argv.
//
// Example: chmod 755 hooks/pre-commit-go-mod.sh.
func isPreCommitHookModeRepair(argv []token) (token, bool) {
	if len(argv) != 3 || argv[0].quoted || argv[1].quoted || argv[2].quoted ||
		argv[0].value != "chmod" || argv[1].value != "755" || argv[2].value != "hooks/pre-commit-go-mod.sh" {
		return token{}, false
	}
	return argv[2], true
}

// protectedHookModeRelativePaths lists the hook files whose modes are owned by the active ECI coordinator.
//
// Example: hooks/validate-bash.sh cannot be mode-mutated by an active worker.
var protectedHookModeRelativePaths = [...]string{
	"hooks/validate-bash.sh",
	"hooks/pre-commit-go-mod.sh",
	"hooks/install-pre-commit-go-mod.sh",
	"hooks/tests/test-pre-commit-go-mod.sh",
}

// protectedHookModeMutation identifies a chmod target owned by the active ECI coordinator.
//
// Example: chmod 644 hooks/validate-bash.sh.
func protectedHookModeMutation(cwd string, argv []token) (token, string, bool) {
	if len(argv) < 3 || filepath.Base(argv[0].value) != "chmod" {
		return token{}, "", false
	}
	targets, recursive := chmodMutationTargets(argv)
	for _, target := range targets {
		if resolved, ok := protectedHookModeTargetPath(cwd, target.value); ok {
			return target, resolved, true
		}
		if recursive {
			if resolved, ok := protectedHookModeRecursiveTargetPath(cwd, target.value); ok {
				return target, resolved, true
			}
		}
	}
	return token{}, "", false
}

// chmodMutationTargets returns chmod mutation targets and whether parsed options enable recursion.
//
// Example: chmod hooks --ref=ordinary.txt returns hooks as a target with reference mode enabled.
func chmodMutationTargets(argv []token) ([]token, bool) {
	operands := make([]token, 0, len(argv)-2)
	index := 1
	recursive := false
	referenceMode := false
	options := true
	for index < len(argv) {
		value := argv[index].value
		switch {
		case options && value == "--":
			options = false
			index++
		case options && chmodOptionHasEmptyReferenceValue(value):
			return nil, recursive
		case options && chmodOptionIsReference(value):
			referenceMode = true
			if strings.Contains(value, "=") {
				index++
				continue
			}
			if index+1 >= len(argv) {
				return nil, recursive
			}
			index += 2
		case options && chmodOptionIsRecursive(value):
			recursive = true
			index++
		case options && strings.HasPrefix(value, "-"):
			index++
		default:
			operands = append(operands, argv[index])
			index++
		}
	}
	if referenceMode {
		return operands, recursive
	}
	if len(operands) < 2 {
		return nil, recursive
	}
	return operands[1:], recursive
}

// chmodOptionIsRecursive reports whether a chmod option enables recursive mutation.
//
// Example: -vR, --rec, and --recursive enable recursion.
func chmodOptionIsRecursive(value string) bool {
	if strings.HasPrefix(value, "--") {
		return len(value) >= len("--rec") && strings.HasPrefix("--recursive", value)
	}
	return strings.HasPrefix(value, "-") && !strings.HasPrefix(value, "--") && strings.Contains(value[1:], "R")
}

// chmodOptionIsReference reports whether a chmod option selects a nonempty reference source.
//
// Example: --ref=source and --reference source select a source operand.
func chmodOptionIsReference(value string) bool {
	option, reference, hasReference := strings.Cut(value, "=")
	return (!hasReference || reference != "") &&
		len(option) >= len("--ref") && strings.HasPrefix("--reference", option)
}

// chmodOptionHasEmptyReferenceValue reports an otherwise valid reference option with no source.
//
// Example: --ref= is invalid and cannot identify a mutation target.
func chmodOptionHasEmptyReferenceValue(value string) bool {
	option, reference, hasReference := strings.Cut(value, "=")
	return hasReference && reference == "" &&
		len(option) >= len("--ref") && strings.HasPrefix("--reference", option)
}

// protectedHookModeTargetPath resolves a protected tracked hook target below a trusted root.
//
// Example: ./hooks/validate-bash.sh resolves to the active provider's validate-bash.sh.
func protectedHookModeTargetPath(cwd, value string) (string, bool) {
	resolved, ok := resolveChmodTargetPath(cwd, value)
	if !ok {
		return "", false
	}
	for _, root := range protectedHookModeRoots() {
		relative, err := filepath.Rel(root, resolved)
		if err != nil {
			continue
		}
		for _, protectedPath := range protectedHookModeRelativePaths {
			if filepath.ToSlash(relative) != protectedPath {
				continue
			}
			return resolved, true
		}
	}
	return "", false
}

// protectedHookModeRecursiveTargetPath resolves a recursive chmod target that contains a protected hook.
//
// Example: chmod -R 644 hooks contains hooks/validate-bash.sh.
func protectedHookModeRecursiveTargetPath(cwd, value string) (string, bool) {
	resolved, ok := resolveChmodTargetPath(cwd, value)
	if !ok {
		return "", false
	}
	for _, root := range protectedHookModeRoots() {
		for _, protectedPath := range protectedHookModeRelativePaths {
			if pathWithin(filepath.Join(root, protectedPath), resolved) {
				return resolved, true
			}
		}
	}
	return "", false
}

// resolveChmodTargetPath canonicalizes a nonempty chmod target against the request working directory.
//
// Example: ./hooks resolves relative to the request working directory.
func resolveChmodTargetPath(cwd, value string) (string, bool) {
	if value == "" {
		return "", false
	}
	candidate := value
	if !filepath.IsAbs(candidate) {
		candidate = filepath.Join(cwd, candidate)
	}
	return resolvePathIdentity(filepath.Clean(candidate)), true
}

// protectedHookModeRoots returns canonical provider roots whose tracked hook modes are protected.
//
// Example: a Codex callback protects CODEX_HOME, KIMI_CODE_HOME, and the planner root.
func protectedHookModeRoots() []string {
	home := os.Getenv("HOME")
	candidates := []string{
		os.Getenv("CODEX_HOME"),
		os.Getenv("KIMI_CODE_HOME"),
		filepath.Join(home, ".codex"),
		filepath.Join(home, ".kimi-code"),
	}
	if executable, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(executable), "..", "..", ".."))
	}
	roots := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if candidate == "" || !filepath.IsAbs(candidate) {
			continue
		}
		resolved := resolvePathIdentity(filepath.Clean(candidate))
		if _, ok := seen[resolved]; ok {
			continue
		}
		seen[resolved] = struct{}{}
		roots = append(roots, resolved)
	}
	return roots
}

func isGitContextOption(value string) bool {
	switch value {
	case "-c", "--config-env", "--git-dir", "--work-tree", "--exec-path", "--namespace", "--super-prefix", "--textconv", "--ext-diff":
		return true
	default:
		return strings.HasPrefix(value, "--config-env=") ||
			strings.HasPrefix(value, "--git-dir=") ||
			strings.HasPrefix(value, "--work-tree=") ||
			strings.HasPrefix(value, "--exec-path=") ||
			strings.HasPrefix(value, "--namespace=") ||
			strings.HasPrefix(value, "--super-prefix=")
	}
}

func gitSubcommandIndex(argv []token) int {
	index := 1
	for index < len(argv) {
		value := argv[index].value
		switch {
		case value == "-C" && index+1 < len(argv):
			index += 2
		case value == "--literal-pathspecs", value == "--no-optional-locks", value == "--no-pager", strings.HasPrefix(value, "-"):
			index++
		default:
			return index
		}
	}
	return index
}

func gitMutation(argv []token, subcommandIndex int) (int, string) {
	subcommand := argv[subcommandIndex].value
	switch subcommand {
	case "add", "am", "apply", "cherry-pick", "checkout", "commit", "config", "gc", "merge", "mv", "push", "rebase", "rename", "replace", "reset", "restore", "revert", "rm", "tag", "update-index", "worktree":
		return subcommandIndex, subcommand
	case "submodule":
		if subcommandIndex+1 >= len(argv) || argv[subcommandIndex+1].value != "status" {
			return subcommandIndex, subcommand
		}
	case "remote":
		if subcommandIndex+1 < len(argv) {
			action := argv[subcommandIndex+1].value
			switch action {
			case "add", "prune", "remove", "rename", "set-head", "set-url", "update":
				return subcommandIndex + 1, "remote " + action
			}
		}
	case "branch":
		expectsValue := false
		for index, argument := range argv[subcommandIndex+1:] {
			value := argument.value
			if expectsValue {
				expectsValue = false
				continue
			}
			if isBranchMutationOption(value) {
				return subcommandIndex + index + 1, "branch " + value
			}
			if isBranchInspectionValueOption(value) {
				expectsValue = true
				continue
			}
			if isBranchInspectionAssignment(value) || strings.HasPrefix(value, "-") {
				continue
			}
			return subcommandIndex + index + 1, "branch update"
		}
	}
	return 0, ""
}

func isBranchInspectionValueOption(value string) bool {
	switch value {
	case "--contains", "--format", "--merged", "--no-contains", "--no-merged", "--points-at", "--sort":
		return true
	default:
		return false
	}
}

func isBranchInspectionAssignment(value string) bool {
	for _, option := range []string{"--contains=", "--format=", "--merged=", "--no-contains=", "--no-merged=", "--points-at=", "--sort="} {
		if strings.HasPrefix(value, option) {
			return true
		}
	}
	return false
}

func isBranchMutationOption(value string) bool {
	switch value {
	case "-c", "-C", "-d", "-D", "-m", "-M", "--copy", "--delete", "--edit-description", "--move", "--set-upstream-to", "--unset-upstream":
		return true
	default:
		return strings.HasPrefix(value, "--set-upstream-to=")
	}
}

func isSourceWriter(name string, argv []token) bool {
	switch name {
	case "chmod", "chown", "cp", "dd", "install", "ln", "mv", "patch", "rm", "rsync", "rmdir", "shred", "srm", "tee", "touch", "truncate", "unlink":
		return true
	case "sed":
		for _, argument := range argv[1:] {
			if argument.value == "-i" || argument.value == "--in-place" || strings.HasPrefix(argument.value, "-i") || strings.HasPrefix(argument.value, "--in-place=") {
				return true
			}
		}
	}
	return false
}

func sourceWriterTargetsCWD(cwd, name string, argv []token) bool {
	root := filepath.Clean(cwd)
	for _, argument := range argv[1:] {
		value := argument.value
		if name == "dd" && strings.HasPrefix(value, "of=") {
			value = strings.TrimPrefix(value, "of=")
		} else {
			pathArgument, pathLike := pathOperand(argument)
			if !pathLike {
				continue
			}
			value = pathArgument.value
		}
		if value == "" {
			continue
		}
		candidate := value
		if !filepath.IsAbs(candidate) {
			candidate = filepath.Join(root, candidate)
		}
		if pathWithin(filepath.Clean(candidate), root) {
			return true
		}
	}
	return false
}

func shellEscape(value string) string {
	if value == "" {
		return "''"
	}
	for index := 0; index < len(value); index++ {
		character := value[index]
		if !(isIdentifierRest(character) || strings.ContainsRune("_./:=+,-", rune(character))) {
			return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
		}
	}
	return value
}
