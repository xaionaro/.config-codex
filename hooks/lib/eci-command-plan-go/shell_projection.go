package main

import (
	"bytes"
	"errors"
	"fmt"
	"slices"
	"strings"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/syntax"
)

// shellProjection separates executable shell text from here-document data while
// preserving every retained byte's original offset.
//
// Example: a quoted here-document leaves its command and the following command.
type shellProjection struct {
	Command       string
	Substitutions []shellSubstitution
	Inputs        []shellInput
	Changed       bool
}

// shellSubstitution contains one here-document command substitution, prefixed
// with Offset spaces so its statements retain their original source offsets.
// OwnerOffset identifies the AST statement whose redirection expands the body.
//
// Example: $(cd repo; git status) is one child with independent directory state.
type shellSubstitution struct {
	Command     string
	OwnerOffset int
	Offset      int
}

// shellInput identifies the last here-document supplying a statement's stdin.
// Literal records whether its contents can be determined without shell expansion.
//
// Example: sh <<'EOF' consumes its literal document as a separate shell program.
type shellInput struct {
	Command     string
	OwnerOffset int
	Offset      int
	Literal     bool
}

// shellCommandSubstitution binds a normal expansion to its direct AST owner.
//
// Example: printf "$(git status)" expands in printf's incoming directory.
type shellCommandSubstitution struct {
	Node  *syntax.CmdSubst
	Owner *syntax.Stmt
}

// shellSourceSpan is a half-open byte interval in the original shell source.
//
// Example: a quoted argument protects its internal newlines from header scanning.
type shellSourceSpan struct {
	Start int
	End   int
}

// shellHeredoc binds one parsed redirection to its owning statement.
//
// Example: two redirects on one command have the same Owner statement.
type shellHeredoc struct {
	Redirect *syntax.Redirect
	Owner    *syntax.Stmt
}

// shellProjectionCollector records here-documents and ordinary lexical spans
// without descending into here-document bodies.
//
// Example: a multiline quoted argument stays distinct from the following body.
type shellProjectionCollector struct {
	Source               string
	Heredocs             []shellHeredoc
	Words                []shellSourceSpan
	Comments             []shellSourceSpan
	Substitutions        []shellCommandSubstitution
	AnalyzeSubstitutions bool
	Errors               []error
	ancestors            []syntax.Node
}

// projectShellHeredocs masks here-document syntax and inert text for the existing
// command planner. Parse errors accompany any useful projection from the partial
// AST; they never discard already recognized commands or body boundaries.
//
// Example: an apostrophe in a quoted body cannot swallow a following git command.
func projectShellHeredocs(command string) (shellProjection, error) {
	return projectShellCommands(command, false)
}

// projectShellCommands additionally isolates ordinary substitutions while
// analyzing an executable child, so nested expansions retain independent state.
//
// Example: a substitution inside a here-document substitution is inspected next.
func projectShellCommands(
	command string,
	substitutions bool,
) (shellProjection, error) {
	projection := shellProjection{Command: command}
	var parseErrors []error
	for {
		parser := syntax.NewParser(syntax.KeepComments(true))
		file, parseErr := parser.Parse(strings.NewReader(projection.Command), "")
		if parseErr != nil {
			parseErrors = append(parseErrors, parseErr)
		}
		if file == nil {
			break
		}

		collector := shellProjectionCollector{Source: command, AnalyzeSubstitutions: substitutions}
		syntax.Walk(file, collector.Collect)
		if !substitutions && len(collector.Heredocs) > 0 {
			// An ordinary substitution enclosing a document is its own shell
			// scope. Extract it before projecting documents within that child.
			collector = shellProjectionCollector{Source: command, AnalyzeSubstitutions: true}
			syntax.Walk(file, collector.Collect)
		}
		parseErrors = append(parseErrors, collector.Errors...)
		if len(collector.Heredocs) == 0 && len(collector.Substitutions) == 0 {
			if (projection.Changed || substitutions) && len(collector.Comments) > 0 {
				masked := []byte(projection.Command)
				for _, comment := range collector.Comments {
					maskShellSpan(masked, comment.Start, comment.End)
				}
				projection.Command = string(masked)
				projection.Changed = true
			}
			break
		}
		slices.SortFunc(collector.Heredocs, compareShellHeredocs)

		masked := []byte(projection.Command)
		bodyCursors := make(map[int]int)
		placeholders := make(map[*syntax.Stmt]int)
		var bodies []shellSourceSpan
		changed := false
		for _, heredoc := range collector.Heredocs {
			redirect := heredoc.Redirect
			if redirect.Word == nil {
				continue
			}
			headerStart := int(redirect.Pos().Offset())
			if shellOffsetInSpans(headerStart, bodies) {
				continue
			}
			headerEnd := int(redirect.Word.End().Offset())
			delimiter, quoted, delimiterErr := shellHeredocDelimiter(command, redirect.Word.Parts, false)
			if delimiterErr != nil {
				parseErrors = append(parseErrors, delimiterErr)
				continue
			}
			// The parser normalizes CRLF globally. Bash retains a CR adjoining
			// a delimiter word, including one following its closing quote.
			for headerEnd < len(command) && command[headerEnd] == '\r' {
				delimiter += "\r"
				headerEnd++
			}
			queueStart := collector.BodyStart(projection.Command, headerEnd)
			bodyStart := queueStart
			if cursor, ok := bodyCursors[queueStart]; ok {
				bodyStart = cursor
			}
			contentEnd, bodyEnd := shellHeredocEnd(command, bodyStart, redirect, delimiter, quoted)
			bodyCursors[queueStart] = bodyEnd
			bodies = append(bodies, shellSourceSpan{Start: bodyStart, End: bodyEnd})

			maskShellSpan(masked, headerStart, headerEnd)
			maskShellSpan(masked, bodyStart, bodyEnd)
			changed = true
			if shellStdinHeredoc(heredoc.Owner) == redirect {
				input, inputErr := shellHeredocInput(command, bodyStart, contentEnd, heredoc, quoted)
				projection.Inputs = append(projection.Inputs, input)
				if inputErr != nil {
					parseErrors = append(parseErrors, inputErr)
				}
			}
			if heredoc.Owner.Cmd == nil {
				if _, exists := placeholders[heredoc.Owner]; !exists {
					placeholders[heredoc.Owner] = headerStart
				}
			}
			if !quoted {
				body, bodyErr := syntax.NewParser().Document(strings.NewReader(
					strings.Repeat(" ", bodyStart) + command[bodyStart:contentEnd],
				))
				if bodyErr != nil {
					parseErrors = append(parseErrors, bodyErr)
				}
				extractor := shellSubstitutionCollector{
					Source: command, OwnerOffset: int(heredoc.Owner.Pos().Offset()),
				}
				if body != nil {
					syntax.Walk(body, extractor.Collect)
				}
				projection.Substitutions = append(projection.Substitutions, extractor.Substitutions...)
				parseErrors = append(parseErrors, extractor.Errors...)
			}
		}
		for _, substitution := range collector.Substitutions {
			if shellOffsetInSpans(int(substitution.Node.Pos().Offset()), bodies) {
				continue
			}
			extractor := shellSubstitutionCollector{
				Source: command, OwnerOffset: int(substitution.Owner.Pos().Offset()),
			}
			extractor.Collect(substitution.Node)
			projection.Substitutions = append(projection.Substitutions, extractor.Substitutions...)
			parseErrors = append(parseErrors, extractor.Errors...)
			start := int(substitution.Node.Pos().Offset())
			end := int(substitution.Node.End().Offset())
			if !substitution.Node.Right.IsValid() {
				end = len(masked)
			}
			maskShellSpan(masked, start, end)
			// Keep an explicitly dynamic word in the analysis command. An
			// empty replacement could invent a concrete command or target.
			copy(masked[start:end], "$?")
			changed = true
		}
		for _, offset := range placeholders {
			// A redirect-only statement still needs a segment whose incoming
			// context owns its substitutions. The colon exists only in analysis.
			masked[offset] = ':'
		}
		if !changed {
			break
		}
		for _, comment := range collector.Comments {
			maskShellSpan(masked, comment.Start, comment.End)
		}
		projection.Command = string(masked)
		projection.Changed = true
		// Reparse after masking to expose any later commands or documents
		// hidden by an upstream delimiter or body interpretation mismatch.
	}
	return projection, errors.Join(parseErrors...)
}

// Collect keeps statement ownership explicit and excludes body data from the
// ordinary word spans used to locate the command's terminating newline.
//
// Example: a here-document after a semicolon still belongs to its own statement.
func (c *shellProjectionCollector) Collect(node syntax.Node) bool {
	if node == nil {
		c.ancestors = c.ancestors[:len(c.ancestors)-1]
		return true
	}
	switch node := node.(type) {
	case *syntax.Stmt:
		if node == nil {
			return false
		}
		for _, redirect := range node.Redirs {
			if redirect.Op == syntax.Hdoc || redirect.Op == syntax.DashHdoc {
				if redirect.Word == nil {
					start := int(redirect.OpPos.Offset()) + len(redirect.Op.String())
					word, err := firstShellWord(c.Source, start)
					if err != nil {
						c.Errors = append(c.Errors, err)
					}
					redirect.Word = word
				}
				c.Heredocs = append(c.Heredocs, shellHeredoc{Redirect: redirect, Owner: node})
			}
			if redirect.Word == nil {
				// Walk asks Stmt.End for comment placement, which requires
				// mandatory redirection words absent from some partial ASTs.
				return false
			}
		}
	case *syntax.Redirect:
		if node == nil || node.Word == nil {
			return false
		}
		if node.Op == syntax.Hdoc || node.Op == syntax.DashHdoc {
			if len(node.Word.Parts) > 0 {
				c.Words = append(c.Words, shellSourceSpan{
					Start: int(node.Word.Pos().Offset()), End: int(node.Word.End().Offset()),
				})
			}
			return false
		}
	case *syntax.CmdSubst:
		if c.AnalyzeSubstitutions {
			for index := len(c.ancestors) - 1; index >= 0; index-- {
				if owner, ok := c.ancestors[index].(*syntax.Stmt); ok {
					c.Substitutions = append(c.Substitutions, shellCommandSubstitution{Node: node, Owner: owner})
					break
				}
			}
			return false
		}
	case *syntax.Word:
		if node == nil || len(node.Parts) == 0 {
			return false
		}
		c.Words = append(c.Words, shellSourceSpan{
			Start: int(node.Pos().Offset()), End: int(node.End().Offset()),
		})
	case *syntax.Comment:
		c.Comments = append(c.Comments, shellSourceSpan{
			Start: int(node.Pos().Offset()), End: int(node.End().Offset()),
		})
	}
	c.ancestors = append(c.ancestors, node)
	return true
}

// firstShellWord parses one ordinary word at an original source offset. This
// recovers delimiter syntax that the heredoc parser rejects before returning it.
//
// Example: <<$END has the literal delimiter $END, not a variable expansion.
func firstShellWord(
	command string,
	start int,
) (*syntax.Word, error) {
	for offset := start; offset < len(command); offset++ {
		switch command[offset] {
		case ' ', '\t':
			continue
		case '\\':
			if offset+1 < len(command) && command[offset+1] == '\n' {
				offset++
				continue
			}
		case '\n':
			return nil, fmt.Errorf("missing here-document delimiter at byte %d", offset)
		}
		break
	}
	parser := syntax.NewParser()
	source := strings.Repeat(" ", start) + command[start:]
	for word, err := range parser.WordsSeq(strings.NewReader(source)) {
		return word, err
	}
	return nil, nil
}

// shellOffsetInSpans reports whether an apparent node lies in an already
// identified document body rather than executable source.
//
// Example: parser CRLF normalization cannot promote an inert body line to code.
func shellOffsetInSpans(
	offset int,
	spans []shellSourceSpan,
) bool {
	for _, span := range spans {
		if span.Start <= offset && offset < span.End {
			return true
		}
	}
	return false
}

// compareShellHeredocs orders queued redirects by their original source position.
//
// Example: <<FIRST <<SECOND consumes FIRST's body before SECOND's body.
func compareShellHeredocs(
	left shellHeredoc,
	right shellHeredoc,
) int {
	return int(left.Redirect.Pos().Offset()) - int(right.Redirect.Pos().Offset())
}

// BodyStart finds the first unescaped newline outside later header words. Words
// containing the redirect itself do not hide its own body's starting newline.
//
// Example: a multiline command-substitution argument before the body is skipped.
func (c *shellProjectionCollector) BodyStart(
	command string,
	headerEnd int,
) int {
	for offset := headerEnd; offset < len(command); {
		next := strings.IndexByte(command[offset:], '\n')
		if next < 0 {
			return len(command)
		}
		newline := offset + next
		offset = newline + 1
		if c.NewlineInsideWord(headerEnd, newline) {
			continue
		}
		if !c.NewlineAfterComment(headerEnd, newline) && shellNewlineEscaped(command, newline) {
			continue
		}
		return offset
	}
	return len(command)
}

// NewlineInsideWord reports whether a later header word contains the newline.
//
// Example: a newline between single quotes cannot start a pending document.
func (c *shellProjectionCollector) NewlineInsideWord(
	headerEnd int,
	newline int,
) bool {
	for _, word := range c.Words {
		if word.Start >= headerEnd && word.Start <= newline && newline < word.End {
			return true
		}
	}
	return false
}

// NewlineAfterComment identifies comment endings, where a trailing backslash
// does not continue the shell command onto another physical line.
//
// Example: <<EOF # note\ followed by a newline begins the body immediately.
func (c *shellProjectionCollector) NewlineAfterComment(
	headerEnd int,
	newline int,
) bool {
	for _, comment := range c.Comments {
		if comment.Start >= headerEnd && comment.End == newline {
			return true
		}
	}
	return false
}

// shellNewlineEscaped reports an odd run of backslashes before a newline.
// A carriage return remains a literal byte and prevents line continuation.
//
// Example: one trailing backslash continues a command; two are a literal slash.
func shellNewlineEscaped(
	command string,
	newline int,
) bool {
	end := newline
	start := end
	for start > 0 && command[start-1] == '\\' {
		start--
	}
	return (end-start)%2 == 1
}

// shellHeredocEnd returns the body-content end and the following delimiter end.
// A complete AST body supplies its boundary when the original delimiter bytes
// agree; otherwise literal line matching recovers the partial document.
//
// Example: a space-indented delimiter does not terminate a <<- document.
func shellHeredocEnd(
	command string,
	start int,
	redirect *syntax.Redirect,
	delimiter string,
	quoted bool,
) (int, int) {
	if redirect.Hdoc != nil {
		end := int(redirect.Hdoc.End().Offset())
		if end >= start && end <= len(command) {
			lineStart := strings.LastIndexByte(command[:end], '\n') + 1
			line := command[lineStart:end]
			if redirect.Op == syntax.DashHdoc {
				line = strings.TrimLeft(line, "\t")
			}
			if lineStart >= start && line == delimiter {
				if end < len(command) && command[end] == '\n' {
					end++
				}
				return lineStart, end
			}
		}
	}
	var logicalLine strings.Builder
	logicalStart := start
	for offset := start; offset < len(command); {
		end := len(command)
		if newline := strings.IndexByte(command[offset:], '\n'); newline >= 0 {
			end = offset + newline
		}
		line := command[offset:end]
		if redirect.Op == syntax.DashHdoc {
			line = strings.TrimLeft(line, "\t")
		}
		next := end
		if next < len(command) {
			next++
		}
		if !quoted && end < len(command) && shellNewlineEscaped(command, end) {
			logicalLine.WriteString(line[:len(line)-1])
			offset = next
			continue
		}
		logicalLine.WriteString(line)
		if logicalLine.String() == delimiter {
			return logicalStart, next
		}
		offset = next
		logicalStart = offset
		logicalLine.Reset()
	}
	return len(command), len(command)
}

// shellHeredocDelimiter performs quote removal on the parser's delimiter parts
// and records quoting from any part, rather than only the final part.
//
// Example: E'O'F becomes EOF and makes the entire body literal.
func shellHeredocDelimiter(
	command string,
	parts []syntax.WordPart,
	insideQuotes bool,
) (string, bool, error) {
	var delimiter strings.Builder
	quoted := insideQuotes
	for _, part := range parts {
		switch part := part.(type) {
		case *syntax.Lit:
			start, end := int(part.Pos().Offset()), int(part.End().Offset())
			if start > end || end > len(command) {
				return "", false, fmt.Errorf("incomplete here-document literal at byte %d", start)
			}
			value := command[start:end]
			for offset := 0; offset < len(value); offset++ {
				if value[offset] == '\\' && offset+1 < len(value) {
					next := value[offset+1]
					if !insideQuotes || strings.IndexByte("\\\"$`\n", next) >= 0 {
						quoted = true
						offset++
						if next == '\n' {
							continue
						}
					}
				}
				delimiter.WriteByte(value[offset])
			}
		case *syntax.SglQuoted:
			start := int(part.Left.Offset()) + 1
			if part.Dollar {
				start++
			}
			end := int(part.Right.Offset())
			if !part.Right.IsValid() || start > end || end > len(command) {
				return "", false, fmt.Errorf("incomplete quoted here-document delimiter at byte %d", start)
			}
			value := command[start:end]
			if part.Dollar {
				// Only this literal quoted node reaches expansion: no variables,
				// tilde, command substitution, or filesystem lookup is possible.
				quotedPart := *part
				quotedPart.Value = value
				literal := &syntax.Word{Parts: []syntax.WordPart{&quotedPart}}
				decoded, err := expand.Literal(&expand.Config{}, literal)
				if err != nil {
					return "", false, err
				}
				value = decoded
			}
			delimiter.WriteString(value)
			quoted = true
		case *syntax.DblQuoted:
			value, _, err := shellHeredocDelimiter(command, part.Parts, true)
			if err != nil {
				return "", false, err
			}
			delimiter.WriteString(value)
			quoted = true
		case *syntax.ParamExp, *syntax.CmdSubst, *syntax.ArithmExp:
			// Expansions are literal syntax in heredoc delimiter words.
			start, end := int(part.Pos().Offset()), int(part.End().Offset())
			if start > end || end > len(command) {
				return "", false, fmt.Errorf("incomplete here-document delimiter at byte %d", start)
			}
			delimiter.WriteString(command[start:end])
		default:
			return "", false, fmt.Errorf("unsupported here-document delimiter part %T", part)
		}
	}
	return delimiter.String(), quoted, nil
}

// shellStdinHeredoc selects the last redirection affecting descriptor zero.
// Later file, duplicate-descriptor, or here-string inputs override earlier docs.
//
// Example: sh <<FIRST <<SECOND consumes SECOND as its script input.
func shellStdinHeredoc(statement *syntax.Stmt) *syntax.Redirect {
	var input *syntax.Redirect
	for _, redirect := range statement.Redirs {
		stdin := redirect.N != nil && redirect.N.Value == "0"
		if redirect.N == nil {
			switch redirect.Op {
			case syntax.RdrIn, syntax.RdrInOut, syntax.DplIn, syntax.Hdoc, syntax.DashHdoc, syntax.WordHdoc:
				stdin = true
			}
		}
		if !stdin {
			continue
		}
		input = nil
		if redirect.Op == syntax.Hdoc || redirect.Op == syntax.DashHdoc {
			input = redirect
		}
	}
	return input
}

// shellHeredocInput constructs a statically known stdin value. An unquoted body
// containing expansion remains unknown; its executable substitutions are still
// analyzed independently before the receiving command starts.
//
// Example: a literal quoted body is shell source only when its consumer is a shell.
func shellHeredocInput(
	command string,
	start int,
	end int,
	heredoc shellHeredoc,
	quoted bool,
) (shellInput, error) {
	input := shellInput{OwnerOffset: int(heredoc.Owner.Pos().Offset()), Offset: start}
	body := command[start:end]
	if heredoc.Redirect.Op == syntax.DashHdoc {
		var stripped strings.Builder
		for line := range strings.SplitAfterSeq(body, "\n") {
			stripped.WriteString(strings.TrimLeft(line, "\t"))
		}
		body = stripped.String()
	}
	if !quoted {
		word, err := syntax.NewParser().Document(strings.NewReader(body))
		if err != nil {
			return input, err
		}
		if word != nil {
			for _, part := range word.Parts {
				if _, literal := part.(*syntax.Lit); !literal {
					return input, nil
				}
			}
		}
		var decoded strings.Builder
		for offset := 0; offset < len(body); offset++ {
			character := body[offset]
			if character == '\\' && offset+1 < len(body) && strings.IndexByte("\\$`\n", body[offset+1]) >= 0 {
				offset++
				character = body[offset]
				if character == '\n' {
					continue
				}
			}
			decoded.WriteByte(character)
		}
		body = decoded.String()
	}
	input.Command = strings.Repeat(" ", start) + body
	input.Literal = true
	return input, nil
}

// maskShellSpan replaces all bytes, including body newlines, with spaces. The
// command-header newline remains the real separator before the next command.
//
// Example: masking a three-line body adds no empty command-plan segments.
func maskShellSpan(
	command []byte,
	start int,
	end int,
) {
	for offset := start; offset < end; offset++ {
		command[offset] = ' '
	}
}

// shellSubstitutionCollector extracts outermost executable substitutions from
// an expandable body; nested documents remain available for recursive analysis.
//
// Example: two independent substitutions produce two independently scoped children.
type shellSubstitutionCollector struct {
	Source        string
	OwnerOffset   int
	Substitutions []shellSubstitution
	Errors        []error
}

// Collect preserves each substitution's statement list as one child program,
// so directory changes and conditional execution remain local to that child.
//
// Example: $(cd repo && git status) keeps the && dependency inside one child.
func (c *shellSubstitutionCollector) Collect(node syntax.Node) bool {
	substitution, ok := node.(*syntax.CmdSubst)
	if !ok {
		return true
	}
	if len(substitution.Stmts) == 0 {
		return false
	}
	start := int(substitution.Stmts[0].Pos().Offset())
	end := len(c.Source)
	if substitution.Right.IsValid() {
		end = int(substitution.Right.Offset())
	}
	if start <= end && end <= len(c.Source) {
		command := c.Source[start:end]
		if substitution.Backquotes {
			// The parser has already removed legacy backquote escape levels.
			// Printing its statements preserves those executable semantics.
			var printed bytes.Buffer
			file := &syntax.File{Stmts: substitution.Stmts, Last: substitution.Last}
			if err := syntax.NewPrinter().Print(&printed, file); err != nil {
				c.Errors = append(c.Errors, err)
				return false
			}
			command = printed.String()
		}
		c.Substitutions = append(c.Substitutions, shellSubstitution{
			Command:     strings.Repeat(" ", start) + command,
			OwnerOffset: c.OwnerOffset,
			Offset:      start,
		})
	}
	return false
}
