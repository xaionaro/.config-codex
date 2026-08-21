package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const (
	maxCommandBytes  = 16 * 1024
	maxSegments      = 8
	maxArguments     = 128
	maxArgumentBytes = 4 * 1024
	maxWrapperDepth  = 8
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
	CodeGitDynamicExecutionDenied    DiagnosticCode = "ECI_GIT_DYNAMIC_EXECUTION_DENIED"
	CodeControlOwnerRequired         DiagnosticCode = "ECI_CONTROL_OWNER_REQUIRED"
	CodeBroadDestructiveDenied       DiagnosticCode = "ECI_BROAD_DESTRUCTIVE_DENIED"
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
			return Result{Decision: DecisionAllow}
		}
		err.diagnostic.RejectedSegment = shellEscape(request.Command)
		return deniedResult(request, err.diagnostic)
	}

	decision := DecisionAllow
	for index, current := range parsed.segments {
		segmentDecision, diagnostic := inspectSegment(request, current, index+1)
		if diagnostic != nil {
			diagnostic.RejectedSegment = rejectedSegment(current, diagnostic.Code)
			if suppressInactiveDiagnostic(request, diagnostic) {
				continue
			}
			return deniedResult(request, *diagnostic)
		}
		if segmentDecision == DecisionDefer {
			decision = DecisionDefer
		}
	}

	return Result{Decision: decision}
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

	argv, diagnostic := unwrap(current.argv, segmentIndex)
	if diagnostic != nil {
		return DecisionDeny, diagnostic
	}
	name := filepath.Base(argv[0].value)

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
		if diagnostic != nil || decision == DecisionDefer {
			return decision, diagnostic
		}
	}
	if isLifecycleName(name) {
		if request.Marker == MarkerActive && request.Role == RoleWorker {
			return DecisionDeny, diagnosticForToken(
				CodeControlOwnerRequired,
				fmt.Sprintf("worker argv invokes coordinator-owned lifecycle target %s", name),
				segmentIndex,
				0,
				argv[0],
				"route this exact lifecycle operation through the coordinator",
				"worker-lifecycle-control",
			)
		}
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
	if request.Marker == MarkerActive && request.Role == RoleCoordinator && isSourceWriter(name, argv) {
		return DecisionDefer, nil
	}

	return DecisionAllow, nil
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
		case strings.HasPrefix(value, "--unset="), strings.HasPrefix(value, "--chdir="):
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
			return nil, diagnosticForToken(
				CodeEnvironmentContextDenied,
				fmt.Sprintf("environment assignment name %s changes registered execution context", name),
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
				CodeGitDynamicExecutionDenied,
				"Git execution or repository context is overridden by a visible option",
				segmentIndex,
				index+1,
				argument,
				"remove the reported Git context option and use repository-default inspection",
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
			"route this exact Git mutation through the coordinator acceptance path",
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
		return diagnosticForToken(
			CodeBroadDestructiveDenied,
			"recursive forced deletion selects a broad root",
			segmentIndex,
			rootIndex,
			argv[rootIndex],
			"replace the broad root with one explicit narrow recoverable target",
			"broad-destructive-root",
		)
	}
	return nil
}

func inspectLiveControl(request Request, argv []token, segmentIndex int) *Diagnostic {
	for argumentIndex, argument := range argv[1:] {
		candidate := filepath.Clean(argument.value)
		for _, markerPath := range request.ActiveMarkers {
			cleanMarker := filepath.Clean(markerPath)
			if candidate == cleanMarker {
				return diagnosticForToken(
					CodePlanLiveControlDenied,
					"worker argv resolves to an exact active-session live-control artifact",
					segmentIndex,
					argumentIndex+1,
					argument,
					"route this exact live-control operation through the coordinator",
					"worker-live-control",
				)
			}
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
	case code == CodeGitDynamicExecutionDenied:
		return "git-execution-context"
	case code == CodeControlOwnerRequired, code == CodePlanLiveControlDenied:
		return "worker-control"
	case code == CodeBroadDestructiveDenied:
		return "broad-destructive"
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

func isLifecycleName(name string) bool {
	switch name {
	case "eci-active", "eci-active-gate.sh", "eci-review-gate", "eci-review-gate.sh", "eci-stage", "stop-gate.sh":
		return true
	default:
		return false
	}
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
		for index, argument := range argv[subcommandIndex+1:] {
			value := argument.value
			if isBranchMutationOption(value) || !strings.HasPrefix(value, "-") {
				return subcommandIndex + index + 1, "branch " + value
			}
		}
	}
	return 0, ""
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
