package main

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/goccy/go-yaml/lexer"
	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// yamlByteOffset maps a one-based YAML line and rune column into UTF-8 bytes.
//
// Example: Map a column after a multibyte character.
func yamlByteOffset(data []byte, line, column int) (int, error) {
	if !utf8.Valid(data) {
		return 0, fmt.Errorf("unsupported UTF-8 layout")
	}
	lines := strings.Split(string(data), "\n")
	starts := make([]int, len(lines))
	for i := 1; i < len(lines); i++ {
		starts[i] = starts[i-1] + len(lines[i-1]) + 1
	}
	return yamlOffsetForLines(lines, starts, line, column)
}

// yamlOffsetForLines maps a YAML position using precomputed line starts.
//
// Example: Resolve a token position using cached line starts.
func yamlOffsetForLines(lines []string, starts []int, line, column int) (int, error) {
	if line < 1 || line > len(lines) || column < 1 {
		return 0, fmt.Errorf("invalid YAML position")
	}
	offset := starts[line-1]
	current := lines[line-1]
	for i := 1; i < column; i++ {
		if len(current) == 0 {
			return 0, fmt.Errorf("YAML column exceeds line")
		}
		_, size := utf8.DecodeRuneInString(current)
		offset += size
		current = current[size:]
	}
	return offset, nil
}

// flowPair records a matched pair of YAML flow delimiters.
//
// Example: Store the closing brace for an opening brace.
type flowPair struct {
	opening token.Type
	end     int
}

// flowDocument indexes flow delimiters in one report.
//
// Example: Cache delimiter pairs for a status report.
type flowDocument struct {
	data    []byte
	ready   bool
	pairs   map[int]flowPair
	scalars map[int]*token.Token
	err     error
}

// flowStart records an opening flow delimiter while pairing tokens.
//
// Example: Track an opening bracket while scanning nested collections.
type flowStart struct {
	opening token.Type
	offset  int
}

// flowEnd finds a matching lexer delimiter, excluding scalar and comment tokens.
//
// Example: Find the closing brace after a quoted delimiter.
func flowEnd(data []byte, start int, opening token.Type) (int, error) {
	return (&flowDocument{data: data}).end(start, opening)
}

// end returns the checked closing delimiter for a flow collection.
//
// Example: Resolve a previously indexed flow mapping.
func (d *flowDocument) end(start int, opening token.Type) (int, error) {
	if !d.ready {
		d.build()
	}
	if d.err != nil {
		return 0, d.err
	}
	pair, ok := d.pairs[start]
	if !ok || pair.opening != opening {
		return 0, fmt.Errorf("YAML delimiter position mismatch")
	}
	return pair.end, nil
}

// scalarSpan locates a proven single-line scalar using the cached lexer tokens.
//
// Example: Locate a block-style outcome containing a comma.
func (d *flowDocument) scalarSpan(node *yaml.Node) (int, int, error) {
	if !d.ready {
		d.build()
	}
	if d.err != nil {
		return 0, 0, d.err
	}
	start, err := yamlByteOffset(d.data, node.Line, node.Column)
	if err != nil {
		return 0, 0, err
	}
	tok, ok := d.scalars[start]
	if !ok || tok.Value != node.Value {
		return 0, 0, fmt.Errorf("YAML scalar token mismatch")
	}
	raw := strings.TrimSpace(tok.Origin)
	if raw == "" || strings.ContainsAny(raw, "\r\n") || start+len(raw) > len(d.data) || string(d.data[start:start+len(raw)]) != raw {
		return 0, 0, fmt.Errorf("unsupported YAML scalar span")
	}
	return start, start + len(raw), nil
}

// build indexes lexer delimiter pairs for a report.
//
// Example: Pair nested brackets and braces in a report.
func (d *flowDocument) build() {
	d.ready = true
	if !utf8.Valid(d.data) {
		d.err = fmt.Errorf("unsupported UTF-8 layout")
		return
	}
	if strings.ContainsRune(string(d.data), '\r') {
		d.err = fmt.Errorf("unsupported CRLF layout")
		return
	}
	tokens := lexer.Tokenize(string(d.data))
	if bad := tokens.InvalidToken(); bad != nil {
		d.err = fmt.Errorf("unsupported YAML token: %s", bad.Error)
		return
	}
	d.pairs = make(map[int]flowPair)
	d.scalars = make(map[int]*token.Token)
	lines := strings.Split(string(d.data), "\n")
	starts := make([]int, len(lines))
	for i := 1; i < len(lines); i++ {
		starts[i] = starts[i-1] + len(lines[i-1]) + 1
	}
	var stack []flowStart
	for _, tok := range tokens {
		if tok.Type == token.StringType || tok.Type == token.SingleQuoteType || tok.Type == token.DoubleQuoteType {
			if tok.Position == nil {
				d.err = fmt.Errorf("YAML token lacks position")
				return
			}
			if tok.Position.Column < 1 {
				continue
			}
			pos, err := yamlOffsetForLines(lines, starts, tok.Position.Line, tok.Position.Column)
			if err != nil {
				d.err = err
				return
			}
			d.scalars[pos] = tok
			continue
		}
		if tok.Type != token.MappingStartType && tok.Type != token.MappingEndType && tok.Type != token.SequenceStartType && tok.Type != token.SequenceEndType {
			continue
		}
		if tok.Position == nil {
			d.err = fmt.Errorf("YAML token lacks position")
			return
		}
		pos, err := yamlOffsetForLines(lines, starts, tok.Position.Line, tok.Position.Column)
		if err != nil {
			d.err = err
			return
		}
		expected := map[token.Type]byte{token.MappingStartType: '{', token.MappingEndType: '}', token.SequenceStartType: '[', token.SequenceEndType: ']'}[tok.Type]
		if pos >= len(d.data) || d.data[pos] != expected {
			d.err = fmt.Errorf("YAML delimiter byte mismatch")
			return
		}
		if tok.Type == token.MappingStartType || tok.Type == token.SequenceStartType {
			stack = append(stack, flowStart{tok.Type, pos})
			continue
		}
		if len(stack) == 0 {
			d.err = fmt.Errorf("unbalanced YAML flow delimiters")
			return
		}
		top := stack[len(stack)-1]
		if (top.opening == token.MappingStartType && tok.Type != token.MappingEndType) || (top.opening == token.SequenceStartType && tok.Type != token.SequenceEndType) {
			d.err = fmt.Errorf("unbalanced YAML flow delimiters")
			return
		}
		stack = stack[:len(stack)-1]
		d.pairs[top.offset] = flowPair{top.opening, pos}
	}
	if len(stack) > 0 {
		d.err = fmt.Errorf("unbalanced YAML flow delimiters")
	}
}
