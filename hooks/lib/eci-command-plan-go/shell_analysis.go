package main

import (
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// ShellAnalysis carries executable argv independently from lossless raw topology.
// Incomplete parsing is advisory; each retained record still names a command.
//
// Example: a quoted heredoc contributes its cat header and the following git.
type ShellAnalysis struct {
	Commands   []ShellCommandRecord `json:"commands"`
	Incomplete bool                 `json:"incomplete"`
}

// ShellCommandRecord binds literal arguments to incoming directory/reachability
// facts. It is analysis data, never a replacement command to execute.
//
// Example: a substitution's cd changes its own later records, not its parent.
type ShellCommandRecord struct {
	Argv          []string            `json:"argv"`
	CWD           string              `json:"cwd"`
	CWDKnown      bool                `json:"cwd_known"`
	CWDCandidates []string            `json:"cwd_candidates"`
	Reachability  SegmentReachability `json:"reachability"`
	Segment       int                 `json:"segment"`
}

// shellPayload describes a statically selected child program or argv/context.
//
// Example: env -S exposes its split argv without executing generated shell text.
type shellPayload struct {
	command        string
	argv           []string
	stdin          bool
	handled        bool
	incomplete     bool
	cwd            string
	cwdKnown       bool
	cwdSet         bool
	environment    []string
	contextUnknown bool
}

// inspectShellAnalysis reuses the ordinary segment classifier for executable
// heredoc children and publishes their argv for the provider's target checks.
//
// Example: an inert apostrophe is masked while $(git rebase topic) is inspected.
func inspectShellAnalysis(
	request Request,
	parsed plan,
	states []compoundSegmentState,
) (*ShellAnalysis, *Result) {
	if request.ShellDepth >= maxWrapperDepth {
		return nil, nil
	}
	analysis := &ShellAnalysis{Commands: []ShellCommandRecord{}, Incomplete: parsed.projectionIncomplete}
	needed := request.CollectShellCommands || parsed.projection != nil
	for index, current := range parsed.segments {
		state := states[index]
		if state.reachability == segmentUnreachable {
			continue
		}
		childRequest := shellChildRequest(request, state)
		if parsed.projection != nil {
			for _, child := range parsed.projection.Substitutions {
				if child.OwnerOffset < current.sourceStart || child.OwnerOffset >= current.sourceStart+len(current.command) {
					continue
				}
				childRequest.Command = child.Command
				result := Classify(childRequest)
				if result.Decision == DecisionDeny {
					return nil, &result
				}
				appendShellAnalysis(analysis, result.ShellAnalysis)
			}
		}
		effect, inspect := conditionalEffectSegment(current)
		if !inspect {
			continue
		}
		var payload shellPayload
		if needed || strings.Contains(effect.command, "<<") {
			payload = literalShellPayload(effect.argv, effect.command, state.cwd.cwd, state.cwd.known)
		}
		if payload.handled {
			needed = true
			if payload.incomplete {
				analysis.Incomplete = true
				continue
			}
			if payload.contextUnknown {
				// Environment uncertainty does not change the process CWD.
				// Retain inherited or explicitly resolved directory evidence.
				analysis.Incomplete = true
			}
			if payload.cwdSet {
				childRequest.SegmentCWD = payload.cwd
				known := payload.cwdKnown
				childRequest.SegmentCWDKnown = &known
				childRequest.SegmentCWDUnknown = nil
				childRequest.SegmentCWDCandidates = nil
				childRequest.SegmentCWDPhysical = ""
				childRequest.SegmentCWDPhysicalCandidates = nil
			}
			if len(payload.argv) > 0 {
				analysis.Commands = append(analysis.Commands, ShellCommandRecord{
					Argv: append(append([]string{}, payload.environment...), payload.argv...),
					CWD:  childRequest.SegmentCWD, CWDKnown: *childRequest.SegmentCWDKnown,
					CWDCandidates: append([]string{}, childRequest.SegmentCWDCandidates...),
					Reachability:  state.reachability, Segment: index + 1,
				})
				continue
			}
			if payload.stdin {
				input, found := matchingShellInput(parsed.projection, current)
				if !found {
					analysis.Incomplete = true
					continue
				}
				analysis.Incomplete = analysis.Incomplete || !input.Literal
				payload.command = input.Command
			}
			childRequest.Command = payload.command
			before := len(analysis.Commands)
			result := Classify(childRequest)
			if result.Decision == DecisionDeny {
				return nil, &result
			}
			appendShellAnalysis(analysis, result.ShellAnalysis)
			for record := before; record < len(analysis.Commands); record++ {
				analysis.Commands[record].Argv = append(append([]string{}, payload.environment...), analysis.Commands[record].Argv...)
			}
			continue
		}
		argv := make([]string, 0, len(effect.argv))
		for _, argument := range effect.argv {
			argv = append(argv, argument.value)
		}
		analysis.Commands = append(analysis.Commands, ShellCommandRecord{
			Argv: argv, CWD: state.cwd.cwd, CWDKnown: state.cwd.known,
			CWDCandidates: append([]string{}, state.cwd.candidates...),
			Reachability:  state.reachability, Segment: index + 1,
		})
	}
	if !needed {
		return nil, nil
	}
	return analysis, nil
}

func matchingShellInput(projection *shellProjection, current segment) (shellInput, bool) {
	if projection == nil {
		return shellInput{}, false
	}
	for _, input := range projection.Inputs {
		if input.OwnerOffset >= current.sourceStart && input.OwnerOffset < current.sourceStart+len(current.command) {
			return input, true
		}
	}
	return shellInput{}, false
}

// shellChildRequest isolates child directory transitions while inheriting the
// verified incoming context of the statement that expands the redirection.
//
// Example: cd other <<EOF expands its body before cd can change directories.
func shellChildRequest(request Request, state compoundSegmentState) Request {
	child := request
	child.ShellDepth++
	child.CollectShellCommands = true
	child.SegmentCWD = state.cwd.cwd
	child.SegmentCWDKnown = &state.cwd.known
	child.SegmentCWDUnknown = &state.cwd.unknown
	child.SegmentCWDCandidates = append([]string{}, state.cwd.candidates...)
	child.SegmentCWDPhysical = state.cwd.physical
	child.SegmentCWDPhysicalCandidates = append([]string{}, state.cwd.physicalCandidates...)
	child.TimeoutReplay = false
	child.TimeoutReplays = nil
	return child
}

// appendShellAnalysis combines independent child records without sharing their
// directory transitions with the parent or another substitution.
//
// Example: two substitutions retain two separate initial directory states.
func appendShellAnalysis(analysis *ShellAnalysis, child *ShellAnalysis) {
	if child == nil {
		analysis.Incomplete = true
		return
	}
	analysis.Commands = append(analysis.Commands, child.Commands...)
	analysis.Incomplete = analysis.Incomplete || child.Incomplete
}

// literalShellPayload finds source-backed command text that a known wrapper
// passes to a nested shell. Shell words are decoded from mvdan's syntax AST;
// dynamic words never become guessed argv or command context.
//
// Example: bash -c 'git status' selects the quoted command for recursion.
func literalShellPayload(argv []token, source, cwd string, cwdKnown bool) shellPayload {
	if len(argv) == 0 {
		return shellPayload{}
	}
	base := filepath.Base(argv[0].value)
	possible := base == "eval" || base == "env" || base == "command" || base == "builtin" || base == "exec" || isShellName(base)
	words, ok := sourceBackedShellArgv(source, argv)
	if !ok {
		if possible {
			return shellPayload{handled: true, incomplete: true}
		}
		return shellPayload{}
	}
	return literalShellPayloadWords(words, cwd, cwdKnown, 0)
}

func sourceBackedShellArgv(source string, argv []token) ([]string, bool) {
	parser := syntax.NewParser()
	file, err := parser.Parse(strings.NewReader(source), "")
	if err != nil || file == nil || len(file.Stmts) != 1 {
		return nil, false
	}
	call, ok := file.Stmts[0].Cmd.(*syntax.CallExpr)
	if !ok || call == nil {
		return nil, false
	}
	words := make([]string, 0, len(call.Assigns)+len(call.Args))
	for _, assignment := range call.Assigns {
		if assignment == nil || assignment.Name == nil || assignment.Value == nil {
			return nil, false
		}
		value, ok := literalSyntaxWord(source, assignment.Value)
		if !ok {
			return nil, false
		}
		words = append(words, assignment.Name.Value+"="+value)
	}
	for _, word := range call.Args {
		value, ok := literalSyntaxWord(source, word)
		if !ok {
			return nil, false
		}
		words = append(words, value)
	}
	if len(words) != len(argv) {
		return nil, false
	}
	return words, true
}

func literalSyntaxWord(source string, word *syntax.Word) (string, bool) {
	if word == nil {
		return "", false
	}
	for _, part := range word.Parts {
		_, ok := literalSyntaxPart(part, false)
		if !ok {
			return "", false
		}
	}
	value, _, err := shellHeredocDelimiter(source, word.Parts, false)
	return value, err == nil
}

func literalSyntaxPart(part syntax.WordPart, quoted bool) (string, bool) {
	switch part := part.(type) {
	case *syntax.Lit:
		if !quoted && strings.ContainsAny(part.Value, "*?[") {
			return "", false
		}
		if !quoted && strings.HasPrefix(part.Value, "~") {
			return "", false
		}
		return part.Value, true
	case *syntax.SglQuoted:
		if part.Dollar {
			return "", false
		}
		return part.Value, true
	case *syntax.DblQuoted:
		if part.Dollar {
			return "", false
		}
		var value strings.Builder
		for _, nested := range part.Parts {
			text, ok := literalSyntaxPart(nested, true)
			if !ok {
				return "", false
			}
			value.WriteString(text)
		}
		return value.String(), true
	default:
		return "", false
	}
}

func literalShellPayloadWords(argv []string, cwd string, cwdKnown bool, depth int) shellPayload {
	if len(argv) == 0 || depth >= maxWrapperDepth {
		return shellPayload{}
	}
	name := filepath.Base(argv[0])
	switch name {
	case "eval":
		if len(argv) < 2 {
			return shellPayload{handled: true, incomplete: true}
		}
		return shellPayload{command: strings.Join(argv[1:], " "), handled: true}
	case "command", "builtin", "exec":
		index := 1
		for index < len(argv) && strings.HasPrefix(argv[index], "-") {
			if argv[index] == "--" {
				index++
				break
			}
			if name == "exec" && argv[index] == "-a" {
				index += 2
				continue
			}
			index++
		}
		return literalShellPayloadWords(argv[index:], cwd, cwdKnown, depth+1)
	case "env":
		return literalEnvShellPayload(argv, cwd, cwdKnown, depth+1)
	case "bash", "sh", "dash", "zsh":
		return literalShellInvocation(argv, cwd, cwdKnown)
	default:
		return shellPayload{}
	}
}

func literalEnvShellPayload(argv []string, cwd string, cwdKnown bool, depth int) shellPayload {
	if depth >= maxWrapperDepth {
		return shellPayload{handled: true, incomplete: true}
	}
	values := append([]string(nil), argv...)
	hasSplit := false
	for index := 1; index < len(values); index++ {
		argument := values[index]
		var split string
		var consumed int
		switch {
		case argument == "-S" || argument == "--split-string":
			if index+1 >= len(values) {
				return shellPayload{handled: true, incomplete: true}
			}
			split, consumed = values[index+1], 1
		case strings.HasPrefix(argument, "--split-string="):
			split, consumed = strings.TrimPrefix(argument, "--split-string="), 0
		case strings.HasPrefix(argument, "-S") && len(argument) > 2:
			split, consumed = argument[2:], 0
		default:
			continue
		}
		parts, ok := splitEnvString(split)
		if !ok {
			return shellPayload{handled: true, incomplete: true}
		}
		values = append(append(append([]string{}, values[:index]...), parts...), values[index+1+consumed:]...)
		hasSplit = true
		break
	}
	if !hasSplit && len(values) < 2 {
		return shellPayload{}
	}
	index := 1
	var assignments []string
	contextUnknown := false
	for index < len(values) {
		value := values[index]
		switch {
		case value == "--":
			index++
			goto optionsDone
		case value == "-i" || value == "--ignore-environment" || value == "-":
			contextUnknown = true
			index++
		case value == "-v" || value == "--debug" || value == "-0" || value == "--null":
			index++
		case value == "-C" || value == "--chdir":
			if index+1 >= len(values) {
				return shellPayload{handled: hasSplit, incomplete: hasSplit}
			}
			cwd, cwdKnown = resolveShellCWD(cwd, cwdKnown, values[index+1])
			index += 2
		case strings.HasPrefix(value, "--chdir="):
			cwd, cwdKnown = resolveShellCWD(cwd, cwdKnown, strings.TrimPrefix(value, "--chdir="))
			index++
		case value == "-u" || value == "--unset":
			if index+1 >= len(values) {
				return shellPayload{handled: hasSplit, incomplete: hasSplit}
			}
			if isEnvironmentContextName(values[index+1]) {
				contextUnknown = true
			}
			index += 2
		case strings.HasPrefix(value, "--unset="):
			if isEnvironmentContextName(strings.TrimPrefix(value, "--unset=")) {
				contextUnknown = true
			}
			index++
		case strings.HasPrefix(value, "-"):
			if hasSplit {
				return shellPayload{handled: true, incomplete: true}
			}
			return shellPayload{}
		default:
			goto optionsDone
		}
	}

optionsDone:
	for index < len(values) {
		name, value, ok := strings.Cut(values[index], "=")
		if !ok {
			break
		}
		if isEnvironmentContextName(name) {
			if strings.HasPrefix(name, "GIT_") {
				assignments = append(assignments, values[index])
			} else {
				contextUnknown = true
			}
		}
		_ = value
		index++
	}
	if index >= len(values) {
		return shellPayload{handled: hasSplit, incomplete: hasSplit}
	}
	child := literalShellPayloadWords(values[index:], cwd, cwdKnown, depth+1)
	if !hasSplit && !child.handled {
		return shellPayload{}
	}
	if !child.handled {
		child.argv = append([]string{}, values[index:]...)
	}
	child.handled = true
	child.environment = append(assignments, child.environment...)
	child.contextUnknown = child.contextUnknown || contextUnknown
	child.cwd = cwd
	child.cwdKnown = cwdKnown
	child.cwdSet = true
	return child
}

func resolveShellCWD(base string, baseKnown bool, path string) (string, bool) {
	if !filepath.IsAbs(path) {
		if !baseKnown {
			return "", false
		}
		path = filepath.Join(base, path)
	}
	path = filepath.Clean(path)
	if !isVerifiedAbsoluteTimeoutCWD(path) {
		return "", false
	}
	return path, true
}

func splitEnvString(value string) ([]string, bool) {
	var words []string
	var word strings.Builder
	quote := byte(0)
	started := false
	flush := func() {
		if started {
			words = append(words, word.String())
			word.Reset()
			started = false
		}
	}
	for index := 0; index < len(value); index++ {
		character := value[index]
		if quote == '\'' {
			if character == '\'' {
				quote = 0
			} else if character == '\\' && index+1 < len(value) && (value[index+1] == '\\' || value[index+1] == '\'') {
				index++
				word.WriteByte(value[index])
			} else {
				word.WriteByte(character)
			}
			started = true
			continue
		}
		if character == '\\' {
			if index+1 >= len(value) {
				return nil, false
			}
			index++
			next := value[index]
			switch next {
			case 'c':
				if quote == '"' {
					return nil, false
				}
				flush()
				return words, true
			case 'f':
				word.WriteByte('\f')
			case 'n':
				word.WriteByte('\n')
			case 'r':
				word.WriteByte('\r')
			case 't':
				word.WriteByte('\t')
			case 'v':
				word.WriteByte('\v')
			case '_':
				if quote == '"' {
					word.WriteByte(' ')
				} else {
					flush()
				}
			case '#', '$', '\\', '"', '\'':
				word.WriteByte(next)
			default:
				return nil, false
			}
			started = true
			continue
		}
		if quote == '"' {
			if character == '"' {
				quote = 0
			} else if character == '$' {
				return nil, false
			} else {
				word.WriteByte(character)
			}
			started = true
			continue
		}
		if character == '\'' || character == '"' {
			quote = character
			started = true
			continue
		}
		if character == '$' {
			return nil, false
		}
		if isEnvSplitWhitespace(character) {
			flush()
			continue
		}
		if character == '#' && !started {
			break
		}
		word.WriteByte(character)
		started = true
	}
	if quote != 0 {
		return nil, false
	}
	flush()
	return words, true
}

func isEnvSplitWhitespace(value byte) bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\v' || value == '\f'
}

func isShellName(value string) bool {
	switch value {
	case "bash", "sh", "dash", "zsh":
		return true
	default:
		return false
	}
}

func literalShellInvocation(argv []string, cwd string, cwdKnown bool) shellPayload {
	for index := 1; index < len(argv); index++ {
		option := argv[index]
		if option == "--" {
			if index+1 < len(argv) && argv[index+1] == "-" {
				return shellPayload{stdin: true, handled: true, cwd: cwd, cwdKnown: cwdKnown, cwdSet: true}
			}
			return shellPayload{}
		}
		if option == "-c" || (strings.HasPrefix(option, "-") && !strings.HasPrefix(option, "--") && strings.Contains(option[1:], "c")) {
			if index+1 >= len(argv) {
				return shellPayload{handled: true, incomplete: true}
			}
			return shellPayload{command: argv[index+1], handled: true, cwd: cwd, cwdKnown: cwdKnown, cwdSet: true}
		}
		if option == "-s" || (strings.HasPrefix(option, "-") && !strings.HasPrefix(option, "--") && strings.Contains(option[1:], "s")) {
			return shellPayload{stdin: true, handled: true, cwd: cwd, cwdKnown: cwdKnown, cwdSet: true}
		}
		if !strings.HasPrefix(option, "-") {
			return shellPayload{}
		}
		if option == "-o" || option == "-O" || option == "--rcfile" || option == "--init-file" {
			index++
		}
	}
	return shellPayload{stdin: true, handled: true, cwd: cwd, cwdKnown: cwdKnown, cwdSet: true}
}
