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
	maxCommandBytes  = 16 * 1024
	maxSegments      = 8
	maxArguments     = 128
	maxArgumentBytes = 4 * 1024
	maxWrapperDepth  = 8
	maxProofAnchors  = 128
	maxActiveControlEntries = 128
)

type Provider string

const (
	ProviderCodex Provider = "codex"
	ProviderKimi  Provider = "kimi"
)

type Role string

const (
	RoleCoordinator Role = "coordinator"
	RoleWorker      Role = "worker"
)

type Marker string

const (
	MarkerActive   Marker = "active"
	MarkerInactive Marker = "inactive"
)

type DecisionKind string

const (
	DecisionAllow DecisionKind = "allow"
	DecisionDefer DecisionKind = "defer"
	DecisionDeny  DecisionKind = "deny"
	DecisionError DecisionKind = "error"
)

type Capability string

const (
	CapabilityGateMode Capability = "gate-mode"
)

type DiagnosticCode string

const (
	CodePlanSyntaxDenied             DiagnosticCode = "ECI_PLAN_SYNTAX_DENIED"
	CodePlanLimitDenied              DiagnosticCode = "ECI_PLAN_LIMIT_DENIED"
	CodePlanWrapperDenied            DiagnosticCode = "ECI_PLAN_WRAPPER_DENIED"
	CodePlanDynamicLaunchDenied      DiagnosticCode = "ECI_PLAN_DYNAMIC_LAUNCH_DENIED"
	CodeEnvironmentEnumerationDenied DiagnosticCode = "ECI_ENVIRONMENT_ENUMERATION_DENIED"
	CodeEnvironmentNameDenied        DiagnosticCode = "ECI_ENVIRONMENT_NAME_DENIED"
	CodeEnvironmentOptionDenied      DiagnosticCode = "ECI_ENVIRONMENT_OPTION_DENIED"
	CodeEnvironmentContextDenied     DiagnosticCode = "ECI_ENVIRONMENT_CONTEXT_DENIED"
	CodeWorkerGitOwnershipDenied     DiagnosticCode = "ECI_WORKER_GIT_OWNERSHIP_DENIED"
	CodeGitExecutionContextDenied    DiagnosticCode = "ECI_GIT_EXECUTION_CONTEXT_DENIED"
	CodeControlOwnerRequired         DiagnosticCode = "ECI_CONTROL_OWNER_REQUIRED"
	CodeControlIdentityDenied        DiagnosticCode = "ECI_CONTROL_IDENTITY_DENIED"
	CodeBroadDestructiveDenied       DiagnosticCode = "ECI_BROAD_DESTRUCTIVE_DENIED"
	CodeLedgerAppendOnly             DiagnosticCode = "ECI_LEDGER_APPEND_ONLY"
	CodeProofPathEscapeDenied        DiagnosticCode = "ECI_PROOF_PATH_ESCAPE_DENIED"
	CodePlanLiveControlDenied        DiagnosticCode = "ECI_PLAN_LIVE_CONTROL_DENIED"
	CodePlanInternalDenied           DiagnosticCode = "ECI_PLAN_INTERNAL_DENIED"
)

type Request struct {
	Provider      Provider `json:"provider"`
	Role          Role     `json:"role"`
	CWD           string   `json:"cwd"`
	Marker        Marker   `json:"marker"`
	ActiveSession string   `json:"active_session"`
	Command       string   `json:"command"`
	ActiveMarkers []string `json:"active_markers"`
}

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

type HookSpecificOutput struct {
	HookEventName            string `json:"hookEventName"`
	PermissionDecision       string `json:"permissionDecision"`
	PermissionDecisionReason string `json:"permissionDecisionReason"`
}

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
	decision := DecisionAllow
	for index, current := range parsed.segments {
		segmentDecision, diagnostic := inspectSegment(request, current, index+1)
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

func capabilitiesForPlan(parsed plan) []Capability {
	for segmentIndex, current := range parsed.segments {
		argv, diagnostic := unwrap(current.argv, segmentIndex+1)
		if diagnostic == nil && isGateModeCapability(argv) {
			return []Capability{CapabilityGateMode}
		}
	}
	return nil
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
			if strings.ContainsRune("*?[{}", rune(character)) || (character == '~' && !tokenStarted) {
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
	if request.Marker != MarkerActive || request.Role != RoleWorker || !matched || argv[actionIndex].value != "set" {
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
	for index, argument := range argv[1:] {
		value := argument.value
		dynamic := value == "-c" || value == "-s" || value == "-" || value == "--stdin"
		if name == "node" {
			dynamic = dynamic || value == "-e" || value == "--eval" || strings.HasPrefix(value, "-e=") || strings.HasPrefix(value, "--eval=")
		}
		if dynamic {
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

func inspectGit(
	request Request,
	argv []token,
	segmentIndex int,
) (DecisionKind, *Diagnostic) {
	for index, argument := range argv[1:] {
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
	subcommandIndex := gitSubcommandIndex(argv)
	if subcommandIndex >= len(argv) {
		return DecisionAllow, nil
	}
	mutationIndex, action := gitMutation(argv, subcommandIndex)
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
		entries, err := directory.Readdir(maxActiveControlEntries + 1)
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
			if entry.Mode()&os.ModeSymlink != 0 || !isECIControlBasename(name) {
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
	switch name {
	case "bash", "dash", "sh", "zsh", "python", "python2", "python3", "perl", "ruby", "node", "php":
		return true
	default:
		return false
	}
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
	case "add", "am", "apply", "cherry-pick", "commit", "config", "gc", "merge", "mv", "push", "rebase", "rename", "replace", "reset", "restore", "revert", "rm", "tag", "update-index", "worktree":
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
