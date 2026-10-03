package main

import (
	"strings"
	"unicode/utf8"
)

// roleReasonByteLimit bounds pure-query diagnostics independently of argv size.
//
// Example: an unknown four-megabyte token cannot produce a four-megabyte response.
const roleReasonByteLimit = 1024

// optionArity is the closed set of source-defined option consumption rules.
//
// Example: optionalValue consumes only attached text, never the next argv token.
type optionArity int

const (
	// unknownOption leaves the remaining token roles unresolved.
	unknownOption optionArity = iota
	// noValue consumes only the option itself.
	noValue
	// requiredValue consumes attached text or exactly one following token.
	requiredValue
	// optionalValue consumes attached text when present.
	optionalValue
	// attachedValue requires an equals-form value and never consumes a separate token.
	attachedValue
)

// argumentOption records independent effect and eligibility facts for a known option.
//
// Example: --output has required arity, concrete output and unsupported replay.
type argumentOption struct {
	arity     optionArity
	auxiliary bool
	output    bool
}

// ArgumentRoles reports pure argv facts independently of native observation eligibility.
//
// Example: Output remains true when a later unknown option makes Complete false.
type ArgumentRoles struct {
	Query     string `json:"query"`
	Output    bool   `json:"output"`
	Complete  bool   `json:"complete"`
	Eligible  bool   `json:"eligible"`
	VerbIndex int    `json:"verb_index"`
	Boundary  int    `json:"boundary"`
	Reason    string `json:"reason"`
}

// AnalyzeArguments walks original argv bytes without filesystem or subprocess work.
//
// Example: a -- token consumed by -e never becomes the real delimiter.
func AnalyzeArguments(args []string) ArgumentRoles {
	result := ArgumentRoles{Query: "argument-roles", Complete: true, Eligible: true, VerbIndex: -1, Boundary: len(args)}
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "diff", "log", "show", "grep", "status":
			result.VerbIndex = index
		case "--no-pager", "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs":
			continue
		case "-c":
			index++
			if index == len(args) {
				return unresolvedRoles(result, "unresolved global config override")
			}
			if !strings.Contains(args[index], "=") {
				result.reject("unsupported bare global config override")
			}
			if strings.HasPrefix(strings.ToLower(strings.SplitN(args[index], "=", 2)[0]), "trace") {
				result.reject("unmodeled trace configuration")
			}
			continue
		case "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source":
			result.reject("unsupported native global context: " + arg)
			index++
			if index == len(args) {
				return unresolvedRoles(result, "missing global option value")
			}
			continue
		case "--paginate", "-p":
			result.reject("unsupported native pager context")
			continue
		case "--bare", "--no-optional-locks", "--no-advice", "--no-replace-objects", "--no-lazy-fetch", "-P":
			result.reject("unsupported native global context: " + arg)
			continue
		case "--exec-path":
			return unresolvedRoles(result, "terminal native exec-path query")
		default:
			if strings.HasPrefix(arg, "--exec-path=") || strings.HasPrefix(arg, "--git-dir=") || strings.HasPrefix(arg, "--work-tree=") || strings.HasPrefix(arg, "--namespace=") || strings.HasPrefix(arg, "--config-env=") || strings.HasPrefix(arg, "--attr-source=") || strings.HasPrefix(arg, "-C") && len(arg) > 2 {
				result.reject("unsupported native global context: " + arg)
				continue
			}
			return unresolvedRoles(result, "unresolved built-in or global option: "+arg)
		}
		break
	}
	if result.VerbIndex < 0 {
		return unresolvedRoles(result, "no positively identified inspection built-in")
	}
	verb := args[result.VerbIndex]
	options, delimited := true, false
	for index := result.VerbIndex + 1; index < len(args); index++ {
		arg := args[index]
		if !delimited && arg == "--" {
			if result.Boundary == len(args) {
				result.Boundary = index
			}
			options, delimited = false, true
			continue
		}
		if options && verb == "grep" && (arg == "(" || arg == ")") {
			continue
		}
		if !options || !strings.HasPrefix(arg, "-") || arg == "-" {
			if strings.Contains(arg, "/dev/fd/") || strings.Contains(arg, "/proc/self/fd/") || arg == "-" && !delimited {
				result.reject("unavailable stream input")
			}
			if options && verb == "grep" {
				options = false
				result.Boundary = index
			}
			continue
		}
		if strings.HasPrefix(arg, "--") {
			name, _, attached := strings.Cut(arg, "=")
			role := longArgumentOption(verb, name)
			if role.arity == unknownOption {
				return unresolvedRoles(result, "unresolved native option role: "+arg)
			}
			if role.auxiliary {
				result.reject("unsupported input/output or auxiliary option: " + arg)
			}
			if attached && role.arity == noValue {
				return unresolvedRoles(result, "unexpected native option value: "+arg)
			}
			if !attached && role.arity == attachedValue {
				return unresolvedRoles(result, "missing attached native option value: "+arg)
			}
			if role.arity == requiredValue && !attached {
				index++
				if index == len(args) {
					return unresolvedRoles(result, "missing native option value: "+arg)
				}
			}
			if role.output {
				result.Output = true
			}
			continue
		}
		for offset := 1; offset < len(arg); offset++ {
			role := shortArgumentOption(verb, arg[offset])
			if role.arity == unknownOption {
				return unresolvedRoles(result, "unresolved native option role: "+arg)
			}
			if role.auxiliary {
				result.reject("unsupported input/output or auxiliary option: " + arg)
			}
			if role.arity == requiredValue {
				if offset+1 == len(arg) {
					index++
					if index == len(args) {
						return unresolvedRoles(result, "missing native option value: "+arg)
					}
				}
				break
			}
			if role.arity == optionalValue {
				break
			}
		}
	}
	return result
}

// reject preserves the first eligibility explanation without erasing orthogonal facts.
//
// Example: an earlier output fact survives later auxiliary options.
func (result *ArgumentRoles) reject(reason string) {
	result.Eligible = false
	if result.Reason == "" {
		if len(reason) > roleReasonByteLimit {
			reason = reason[:roleReasonByteLimit]
			for !utf8.ValidString(reason) {
				reason = reason[:len(reason)-1]
			}
		}
		result.Reason = reason
	}
}

// unresolvedRoles stops interpretation at unknown arity while preserving earlier output.
//
// Example: --output=file before an unknown option remains a concrete write request.
func unresolvedRoles(
	result ArgumentRoles,
	reason string,
) ArgumentRoles {
	result.Complete = false
	result.reject(reason)
	return result
}

// shortArgumentOption maps source-defined short cluster letters to their exact consumption.
//
// Example: grep -ne-- consumes the attached pattern through the cluster's -e.
func shortArgumentOption(
	verb string,
	letter byte,
) argumentOption {
	values, flags, optional := "", "", ""
	switch verb {
	case "grep":
		if letter == 'f' {
			return argumentOption{arity: requiredValue, auxiliary: true}
		}
		if letter == 'O' {
			return argumentOption{arity: optionalValue, auxiliary: true}
		}
		values, flags = "eABCm", "viwaIEGFPnhHlLzocpqWr()"
	case "diff", "log", "show":
		if letter == 'O' {
			return argumentOption{arity: requiredValue, auxiliary: true}
		}
		values, flags, optional = "SGIl", "psuWRawbrzD", "UCMB"
		if verb != "diff" {
			values += "n"
			flags += "iEF"
		}
	case "status":
		flags, optional = "sbzv", "u"
	}
	if letter >= '0' && letter <= '9' && verb != "status" {
		return argumentOption{arity: noValue}
	}
	if strings.ContainsRune(values, rune(letter)) {
		return argumentOption{arity: requiredValue}
	}
	if strings.ContainsRune(flags, rune(letter)) {
		return argumentOption{arity: noValue}
	}
	if strings.ContainsRune(optional, rune(letter)) {
		return argumentOption{arity: optionalValue}
	}
	return argumentOption{}
}

// longArgumentOption supplies effect facts and arity from Git 2.51 option definitions.
//
// Example: stat-width is required, while bare --stat never consumes a following option.
func longArgumentOption(
	verb string,
	name string,
) argumentOption {
	if verb == "diff" || verb == "log" || verb == "show" {
		switch name {
		case "--output":
			return argumentOption{arity: requiredValue, auxiliary: true, output: true}
		case "--stat-width", "--stat-name-width", "--stat-graph-width", "--stat-count", "--ws-error-highlight":
			return argumentOption{arity: requiredValue}
		case "--break-rewrites", "--dirstat", "--dirstat-by-file", "--color-moved":
			return argumentOption{arity: optionalValue}
		case "--irreversible-delete", "--cumulative", "--text", "--default-prefix":
			return argumentOption{arity: noValue}
		case "--no-index":
			return argumentOption{arity: noValue, auxiliary: true}
		}
		if verb != "diff" {
			if name == "--stdin" {
				return argumentOption{arity: noValue, auxiliary: true}
			}
			if name == "--filter" {
				return argumentOption{arity: attachedValue, auxiliary: true}
			}
			if name == "--format" {
				return argumentOption{arity: attachedValue}
			}
		}
	}
	if verb == "grep" {
		switch name {
		case "--open-files-in-pager":
			return argumentOption{arity: optionalValue, auxiliary: true}
		case "--no-index", "--recurse-submodules":
			return argumentOption{arity: noValue, auxiliary: true}
		}
	}
	value, known := supportedLongOption(verb, name)
	if !known {
		return argumentOption{}
	}
	if value {
		return argumentOption{arity: requiredValue}
	}
	switch name {
	case "--stat", "--color", "--word-diff", "--unified", "--find-renames", "--find-copies", "--relative", "--submodule", "--ignore-submodules", "--abbrev", "--format", "--pretty", "--no-walk", "--decorate", "--porcelain", "--untracked-files", "--ignored":
		return argumentOption{arity: optionalValue}
	}
	return argumentOption{arity: noValue}
}

// supportedLongOption records the existing source-matched long-option domain.
//
// Example: --author consumes one value for log and show.
func supportedLongOption(
	verb string,
	name string,
) (bool, bool) {
	if verb == "grep" {
		switch name {
		case "--context", "--after-context", "--before-context", "--max-count", "--threads", "--max-depth":
			return true, true
		case "--textconv", "--no-textconv", "--cached", "--no-index", "--untracked", "--exclude-standard", "--no-exclude-standard", "--invert-match", "--ignore-case", "--word-regexp", "--text", "--recursive", "--extended-regexp", "--basic-regexp", "--fixed-strings", "--perl-regexp", "--line-number", "--column", "--full-name", "--files-with-matches", "--name-only", "--files-without-match", "--null", "--only-matching", "--count", "--color", "--no-color", "--break", "--heading", "--show-function", "--function-context", "--and", "--or", "--not", "--all-match", "--quiet":
			return false, true
		}
		return false, false
	}
	if verb == "status" {
		switch name {
		case "--short", "--branch", "--porcelain", "--untracked-files", "--ignored", "--ignore-submodules", "--renames", "--no-renames", "--null", "--verbose", "--ahead-behind", "--no-ahead-behind":
			return false, true
		}
		return false, false
	}
	if verb == "log" || verb == "show" {
		switch name {
		case "--author", "--committer", "--grep", "--grep-reflog", "--since", "--after", "--until", "--before", "--max-count", "--skip", "--date", "--encoding":
			return true, true
		case "--format", "--pretty", "--all", "--first-parent", "--reverse", "--topo-order", "--date-order", "--no-walk", "--oneline", "--decorate", "--no-decorate", "--abbrev-commit", "--no-abbrev-commit":
			return false, true
		}
	}
	switch name {
	case "--inter-hunk-context", "--output-indicator-new", "--output-indicator-old", "--output-indicator-context", "--diff-filter", "--src-prefix", "--dst-prefix", "--line-prefix", "--word-diff-regex", "--ignore-matching-lines", "--anchored", "--rotate-to", "--skip-to", "--diff-algorithm":
		return true, true
	case "--textconv", "--no-textconv", "--ext-diff", "--no-ext-diff", "--cached", "--staged", "--quiet", "--exit-code", "--check", "--name-only", "--name-status", "--patch", "--no-patch", "--raw", "--patch-with-stat", "--patch-with-raw", "--stat", "--numstat", "--shortstat", "--summary", "--binary", "--full-index", "--color", "--no-color", "--word-diff", "--unified", "--find-renames", "--find-copies", "--no-renames", "--find-copies-harder", "--minimal", "--patience", "--histogram", "--ignore-all-space", "--ignore-space-change", "--ignore-space-at-eol", "--ignore-cr-at-eol", "--ignore-blank-lines", "--no-prefix", "--relative", "--submodule", "--ignore-submodules", "--abbrev", "--pickaxe-all", "--pickaxe-regex", "--ita-visible-in-index", "--ita-invisible-in-index":
		return false, true
	}
	return false, false
}
