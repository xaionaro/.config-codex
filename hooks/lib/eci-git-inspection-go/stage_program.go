package main

import (
	"encoding/json"
	"strings"
)

// Stage bounds limit retained callback values in both generated runtimes.
//
// Example: the bounded prefix survives an unknown 65th callback.
const (
	stageDestinationLimit = 64
	stagePathLimit        = 4096
)

// OfflineRule is the canonical source-defined restricted option transition.
//
// Example: output consumes a following token and records that original value.
type OfflineRule struct {
	Arity     string `json:"arity"`
	Validator string `json:"validator"`
	Source    string `json:"source"`
}

// OfflineProgram describes ordered log-front and ordinary revision/diff stages.
//
// Example: no-index is an executable advisory boundary rather than a prose-only exclusion.
type OfflineProgram struct {
	Pipeline         map[string][]string    `json:"pipeline"`
	Front            map[string]OfflineRule `json:"front"`
	Revision         map[string]OfflineRule `json:"revision"`
	Diff             map[string]OfflineRule `json:"diff"`
	Short            map[string]OfflineRule `json:"short"`
	UnsupportedFront []string               `json:"unsupported_front"`
}

// OfflineResult preserves certain earlier output values independently of completeness.
//
// Example: output before an unknown option survives its advisory boundary.
type OfflineResult struct {
	Outputs     []string `json:"outputs"`
	OutputSpans [][]int  `json:"output_spans"`
	Complete    bool     `json:"complete"`
	Reason      string   `json:"reason"`
	Boundary    int      `json:"boundary"`
}

// offlineValid accepts only proved callback-value subsets.
//
// Example: an unknown date mode stops inference before a later output.
func offlineValid(
	value string,
	validator string,
) bool {
	switch validator {
	case "any":
		return true
	case "nonempty":
		return value != ""
	case "character":
		return len([]byte(value)) == 1
	case "decimal":
		if len(value) == 0 || len(value) > 9 {
			return false
		}
		for _, digit := range value {
			if digit < '0' || digit > '9' {
				return false
			}
		}
		return true
	case "decorations":
		for _, allowed := range strings.Split("short|full|auto|true|false|yes|no|on|off|0|1", "|") {
			if value == allowed {
				return true
			}
		}
		return false
	case "color":
		for _, allowed := range strings.Split("always|auto|never|true|false|0|1", "|") {
			if value == allowed {
				return true
			}
		}
		return false
	case "date":
		for _, allowed := range strings.Split("iso|iso-strict|rfc|short|raw|unix|default", "|") {
			if value == allowed {
				return true
			}
		}
		return false
	case "pretty":
		for _, allowed := range strings.Split("oneline|short|medium|full|fuller|raw|%s|%H|format:%s|tformat:%s", "|") {
			if value == allowed {
				return true
			}
		}
		return false
	}
	return false
}

// offlineStop adds an advisory reason without removing prior proven effects.
//
// Example: unknown later callback validation cannot erase a prior output callback.
func offlineStop(
	r OfflineResult,
	reason string,
) OfflineResult {
	r.Reason = reason
	return r
}

// OfflineAnalyze executes the embedded restricted program for an already resolved ordinary repository.
//
// Example: log's front cluster is transformed before revision's raw-delimiter pre-scan.
func OfflineAnalyze(args []string) OfflineResult {
	var p OfflineProgram
	if err := json.Unmarshal([]byte(offlineProgramJSON), &p); err != nil {
		return offlineStop(OfflineResult{Outputs: []string{}}, "malformed embedded program")
	}
	return analyzeStages(args, p)
}

// analyzeStages is the authoritative executable stage contract for both embedded projections.
//
// Example: a later destination remains relevant after an earlier harmless endpoint.
func analyzeStages(
	args []string,
	p OfflineProgram,
) OfflineResult {
	r := OfflineResult{Outputs: []string{}, OutputSpans: [][]int{}, Boundary: len(args)}
	if len(args) == 0 || (args[0] != "diff" && args[0] != "log" && args[0] != "show") {
		return offlineStop(r, "outside built-in domain")
	}
	verb := args[0]
	for _, arg := range args {
		if strings.Contains(arg, "\x00") {
			return offlineStop(r, "unrepresentable native argument")
		}
	}
	original := args[1:]
	residual := append([]string{}, original...)
	positions := []int{}
	for i := range original {
		positions = append(positions, i+1)
	}
	for _, stage := range p.Pipeline[verb] {
		switch stage {
		case "ordinary_diff_gate":
			// Native mode selection stops at the first operand, before option-value consumption.
			for i, token := range original {
				start := i
				if token == "--no-index" {
					return offlineStop(r, "no-index requires native sensor")
				}
				if token == "--" {
					start++
				} else {
					if strings.HasPrefix(token, "-") {
						continue
					}
				}
				if len(original[start:]) == 2 {
					for _, operand := range original[start:] {
						if strings.HasPrefix(operand, "/") || strings.Contains(operand, "..") {
							return offlineStop(r, "implicit no-index requires native sensor")
						}
					}
				}
				break
			}
		case "log_front_scan":
			residual = []string{}
			positions = []int{}
			for i := 0; i < len(original); i++ {
				token := original[i]
				if token == "--" || token == "--end-of-options" {
					r.Boundary = i + 1
					residual = append(residual, original[i:]...)
					for j := i; j < len(original); j++ {
						positions = append(positions, j+1)
					}
					break
				}
				name, value, attached := strings.Cut(token, "=")
				for _, unsupported := range p.UnsupportedFront {
					if name == unsupported {
						return offlineStop(r, "conditional front declaration")
					}
				}
				if token == "--help" || token == "--help-all" || token == "-h" {
					r.Complete = true
					return r
				}
				if rule, known := p.Front[name]; known {
					if rule.Arity == "none" && attached {
						return offlineStop(r, "invalid front value")
					}
					if rule.Arity == "required" && !attached {
						i++
						if i == len(original) {
							return offlineStop(r, "missing front value")
						}
						value = original[i]
					}
					if (attached || rule.Arity == "required") && !offlineValid(value, rule.Validator) {
						return offlineStop(r, "unproved front callback")
					}
					continue
				}
				if strings.HasPrefix(token, "-") && !strings.HasPrefix(token, "--") && token != "-" {
					suffix := token[1:]
					for len(suffix) > 0 {
						switch suffix[0] {
						case 'h':
							r.Complete = true
							return r
						case 'q':
							suffix = suffix[1:]
							continue
						case 'L':
							if len(suffix) == 1 {
								i++
								if i == len(original) {
									return offlineStop(r, "missing line range")
								}
							}
							suffix = ""
						default:
							if suffix == "-" || suffix == "-end-of-options" {
								return offlineStop(r, "virtual delimiter requires native sensor")
							}
							residual = append(residual, "-"+suffix)
							positions = append(positions, i+1)
							suffix = ""
						}
					}
					continue
				}
				residual = append(residual, token)
				positions = append(positions, i+1)
			}
		case "revision_raw_delimiter":
			for i, token := range residual {
				if token == "--" {
					if verb == "diff" && len(residual[i+1:]) == 2 {
						for _, path := range residual[i+1:] {
							if strings.HasPrefix(path, "/") || strings.Contains(path, "..") {
								return offlineStop(r, "implicit no-index requires native sensor")
							}
						}
					}
					if verb == "diff" {
						r.Boundary = i + 1
					}
					residual = residual[:i]
					positions = positions[:i]
					break
				}
			}
		case "role_scan":
			for i := 0; i < len(residual); i++ {
				token := residual[i]
				if token == "--end-of-options" {
					if verb == "diff" {
						r.Boundary = i + 1
					}
					r.Complete = true
					return r
				}
				if !strings.HasPrefix(token, "-") || token == "-" {
					return offlineStop(r, "unverified revision/path operand")
				}
				if strings.HasPrefix(token, "--") {
					name, value, attached := strings.Cut(token, "=")
					optionPosition := positions[i]
					valuePosition := 0
					rule, known := p.Revision[name]
					if verb == "diff" {
						known = false
					}
					if !known {
						rule, known = p.Diff[name]
					}
					if !known {
						return offlineStop(r, "unknown revision/diff role")
					}
					if rule.Arity == "none" && attached {
						return offlineStop(r, "unexpected value")
					}
					if rule.Arity == "attached" && !attached {
						return offlineStop(r, "missing attached value")
					}
					if rule.Arity == "required" && !attached {
						i++
						if i == len(residual) {
							return offlineStop(r, "missing required value")
						}
						value = residual[i]
						valuePosition = positions[i]
					}
					if (attached || rule.Arity == "required") && !offlineValid(value, rule.Validator) {
						return offlineStop(r, "unproved callback")
					}
					if name == "--output" {
						if len([]byte(value)) > stagePathLimit {
							return offlineStop(r, "output value beyond bounded domain")
						}
						if len(r.Outputs) >= stageDestinationLimit {
							return offlineStop(r, "output count beyond bounded domain")
						}
						r.Outputs = append(r.Outputs, value)
						r.OutputSpans = append(r.OutputSpans, []int{optionPosition, valuePosition})
					}
					continue
				}
				suffix := token[1:]
				digits := offlineValid(suffix, "decimal")
				if digits && verb != "diff" {
					if !offlineValid(suffix, "decimal") {
						return offlineStop(r, "unproved numeric count")
					}
					continue
				}
				for len(suffix) > 0 {
					letter := suffix[:1]
					suffix = suffix[1:]
					rule, known := p.Short[letter]
					if !known || (letter == "n" && verb == "diff") {
						return offlineStop(r, "unknown short role")
					}
					if rule.Arity == "none" {
						continue
					}
					value := suffix
					if rule.Arity == "required" && suffix == "" {
						i++
						if i == len(residual) {
							return offlineStop(r, "missing short value")
						}
						value = residual[i]
					}
					if (value != "" || rule.Arity == "required") && !offlineValid(value, rule.Validator) {
						return offlineStop(r, "unproved short callback")
					}
					suffix = ""
				}
			}
		default:
			return offlineStop(r, "unknown stage opcode")
		}
	}
	r.Complete = true
	return r
}
