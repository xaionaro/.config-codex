package main

import (
	"bytes"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// nativeLaunchSource identifies the source-matched Git 2.51 Trace1 call site.
//
// Example: a record from another source cannot establish external-diff preparation.
const nativeLaunchSource = "run-command.c:673"

// externalChildEnvironment reconstructs the source-selected external-diff environment at its first native child.
//
// Example: equal inherited counter values survive native Trace1 suppression.
func externalChildEnvironment(
	data []byte,
	first traceEvent,
	base map[string]string,
) (map[string]string, error) {
	record, err := firstLaunchRecord(data)
	if err != nil {
		return nil, err
	}
	tokens, err := parseLaunchTokens(record)
	if err != nil {
		return nil, err
	}
	index := 0
	if first.CWD != "" {
		if len(tokens) < 2 || tokens[0] != "cd" || tokens[1] != first.CWD {
			return nil, fmt.Errorf("first native launch cwd mismatch")
		}
		index = 2
		if index >= len(tokens) || tokens[index] != ";" {
			return nil, fmt.Errorf("incomplete native launch cwd")
		}
		index++
	} else if len(tokens) > 0 && tokens[0] == "cd" {
		return nil, fmt.Errorf("unexpected first native launch cwd")
	}
	env := make(map[string]string, len(base)+2)
	for key, value := range base {
		env[key] = value
	}
	seen := map[string]bool{}
	argvStart := len(tokens) - len(first.Argv)
	if argvStart < index || !slices.Equal(tokens[argvStart:], first.Argv) {
		return nil, fmt.Errorf("first native launch argv mismatch")
	}
	for index < argvStart {
		token := tokens[index]
		key, value, assignment := strings.Cut(token, "=")
		if !assignment || key != "GIT_DIFF_PATH_COUNTER" && key != "GIT_DIFF_PATH_TOTAL" {
			return nil, fmt.Errorf("unmodeled native external-diff environment prefix")
		}
		if seen[key] {
			return nil, fmt.Errorf("duplicate native external-diff environment assignment")
		}
		seen[key] = true
		env[key] = value
		index++
	}
	for _, key := range []string{"GIT_DIFF_PATH_COUNTER", "GIT_DIFF_PATH_TOTAL"} {
		value := env[key]
		number, err := strconv.ParseInt(value, 10, 32)
		if err != nil || number <= 0 || strconv.FormatInt(number, 10) != value {
			return nil, fmt.Errorf("noncanonical native external-diff numeric preparation")
		}
	}
	return env, nil
}

// firstLaunchRecord frames quoted Trace1 payloads before selecting the first source run_command record.
//
// Example: an embedded newline containing trace-like argument text cannot become a launch record.
func firstLaunchRecord(data []byte) ([]byte, error) {
	for len(data) > 0 {
		quoted := false
		escaped := false
		end := -1
		for index, char := range data {
			if escaped {
				escaped = false
				continue
			}
			if char == '\\' && !quoted {
				escaped = true
				continue
			}
			if char == '\'' {
				quoted = !quoted
				continue
			}
			if char == '\n' && !quoted {
				end = index
				break
			}
		}
		if end == -1 {
			return nil, fmt.Errorf("incomplete native launch trace record")
		}
		record := data[:end]
		data = data[end+1:]
		header, payload, ok := bytes.Cut(record, []byte(" trace: "))
		if !ok {
			return nil, fmt.Errorf("unmodeled native launch trace framing")
		}
		fields := strings.Fields(string(header))
		if len(fields) != 2 {
			return nil, fmt.Errorf("ambiguous native launch trace header")
		}
		if _, err := time.Parse("15:04:05.000000", fields[0]); err != nil {
			return nil, fmt.Errorf("unmodeled native trace timestamp")
		}
		if !bytes.HasPrefix(payload, []byte("run_command:")) {
			continue
		}
		if fields[1] != nativeLaunchSource {
			return nil, fmt.Errorf("unmatched native run_command source")
		}
		return bytes.TrimPrefix(payload, []byte("run_command:")), nil
	}
	return nil, fmt.Errorf("first native run_command capture absent")
}

// parseLaunchTokens decodes Git 2.51 pretty shell quoting without interpreting any shell text.
//
// Example: close-escape-reopen apostrophes and exclamation marks become literal token bytes.
func parseLaunchTokens(data []byte) ([]string, error) {
	tokens := []string{}
	for index := 0; index < len(data); {
		if data[index] == ' ' {
			index++
			continue
		}
		if data[index] == ';' {
			tokens = append(tokens, ";")
			index++
			continue
		}
		var token strings.Builder
		quoted := false
		started := false
		for index < len(data) {
			char := data[index]
			if !quoted && (char == ' ' || char == ';') {
				break
			}
			started = true
			switch {
			case char == '\'':
				quoted = !quoted
				index++
			case char == '\\' && !quoted:
				if index+1 >= len(data) || data[index+1] != '\'' && data[index+1] != '!' {
					return nil, fmt.Errorf("unmodeled native quote escape")
				}
				token.WriteByte(data[index+1])
				index += 2
			case quoted:
				token.WriteByte(char)
				index++
			case char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || strings.ContainsRune("+,-./:=@_^", rune(char)):
				token.WriteByte(char)
				index++
			default:
				return nil, fmt.Errorf("unmodeled native unquoted token")
			}
		}
		if quoted || !started {
			return nil, fmt.Errorf("incomplete native launch quoted token")
		}
		tokens = append(tokens, token.String())
	}
	return tokens, nil
}
