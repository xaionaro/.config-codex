package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"strconv"
	"unicode/utf8"
)

// invocationByteLimit bounds a complete stdin request before any native execution.
//
// Example: oversized requests receive Advisory instead of a truncated replay.
const invocationByteLimit = 4 * 1024 * 1024

// main exchanges one explicit invocation and its closed observation result over JSON.
//
// Example: printf '%s' '{"cwd":"/repo","arguments":["diff"],"environment":{}}' | eci-git-inspection.
func main() {
	if err := runCLI(os.Stdin, os.Stdout); err != nil {
		os.Exit(1)
	}
}

// runCLI exchanges exactly one JSON request and response, propagating output errors.
//
// Example: runCLI(stdin,stdout) returns an error when the response pipe is closed.
func runCLI(
	input io.Reader,
	output io.Writer,
) error {
	data, err := io.ReadAll(io.LimitReader(input, invocationByteLimit+1))
	if err != nil || len(data) > invocationByteLimit {
		return json.NewEncoder(output).Encode(advisory("invalid or oversized invocation JSON"))
	}
	if !exactJSONUnicode(data) {
		return json.NewEncoder(output).Encode(advisory("unsupported lossy JSON Unicode input"))
	}
	var query struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(data, &query); err != nil {
		return json.NewEncoder(output).Encode(advisory("invalid invocation JSON"))
	}
	switch query.Query {
	case "destinations":
		response, err := queryDestinations(data)
		if err != nil {
			return err
		}
		return writeQueryResponse(output, response)
	case "helper":
		response, err := queryHelper(data)
		if err != nil {
			return err
		}
		return writeQueryResponse(output, response)
	case "consume-inspection":
		response, err := json.Marshal(consumeInspection(data))
		if err != nil {
			return err
		}
		return writeQueryResponse(output, response)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var in Invocation
	if err := decoder.Decode(&in); err != nil {
		return json.NewEncoder(output).Encode(advisory("invalid invocation JSON"))
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); err != io.EOF {
		return json.NewEncoder(output).Encode(advisory("expected exactly one invocation JSON"))
	}
	if in.Query == "offline-program" {
		return json.NewEncoder(output).Encode(OfflineAnalyze(in.Arguments))
	}
	if in.Query == "argument-roles" {
		return json.NewEncoder(output).Encode(AnalyzeArguments(in.Arguments))
	}
	if in.Query != "" {
		return json.NewEncoder(output).Encode(advisory("unknown invocation query"))
	}
	return json.NewEncoder(output).Encode(Inspect(in))
}

// exactJSONUnicode rejects JSON string encodings that decoding would replace rather than preserve.
//
// Example: unpaired UTF-16 surrogate escapes are unsupported before observation.
func exactJSONUnicode(data []byte) bool {
	if !utf8.Valid(data) {
		return false
	}
	inside := false
	for index := 0; index < len(data); index++ {
		if data[index] == '"' {
			inside = !inside
			continue
		}
		if !inside || data[index] != '\\' {
			continue
		}
		index++
		if index >= len(data) {
			return false
		}
		if data[index] != 'u' {
			continue
		}
		if index+4 >= len(data) {
			return false
		}
		value, err := strconv.ParseUint(string(data[index+1:index+5]), 16, 16)
		if err != nil {
			return false
		}
		index += 4
		if value >= 0xdc00 && value <= 0xdfff {
			return false
		}
		if value < 0xd800 || value > 0xdbff {
			continue
		}
		if index+6 >= len(data) || data[index+1] != '\\' || data[index+2] != 'u' {
			return false
		}
		low, err := strconv.ParseUint(string(data[index+3:index+7]), 16, 16)
		if err != nil || low < 0xdc00 || low > 0xdfff {
			return false
		}
		index += 6
	}
	return true
}

// writeQueryResponse writes a bounded structured response and propagates transport errors.
//
// Example: unavailable query evidence returns an empty advisory object.
func writeQueryResponse(output io.Writer, data []byte) error {
	if len(data) == 0 {
		data = []byte("{}")
	}
	if len(data)+1 > invocationByteLimit {
		return json.NewEncoder(output).Encode(advisory("query response exceeds bounded contract"))
	}
	_, err := output.Write(append(data, '\n'))
	return err
}
