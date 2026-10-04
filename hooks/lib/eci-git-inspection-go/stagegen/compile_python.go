package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
)

// pythonCompiler generates Python control flow directly from the authoritative Go stage AST.
//
// Example: changing a native-mode boundary changes both generated projections.
type pythonCompiler struct {
	Output    strings.Builder
	Fields    map[string]string
	Defaults  map[string][]string
	MapFields map[string]bool
	LoopPosts []ast.Stmt
}

// compilePython translates only the closed supported AST used by the parser contract.
//
// Example: an unrecognized Go construct fails generation instead of copying a divergent interpreter.
func compilePython(path string) ([]byte, error) {
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	if err != nil {
		return nil, err
	}
	c := pythonCompiler{Fields: map[string]string{}, Defaults: map[string][]string{}, MapFields: map[string]bool{}}
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gen.Specs {
			typ, ok := spec.(*ast.TypeSpec)
			if !ok {
				continue
			}
			body, ok := typ.Type.(*ast.StructType)
			if !ok {
				continue
			}
			for _, field := range body.Fields.List {
				if len(field.Names) != 1 {
					continue
				}
				name := field.Names[0].Name
				key := strings.ToLower(name)
				if field.Tag != nil {
					tag, err := strconv.Unquote(field.Tag.Value)
					if err != nil {
						return nil, err
					}
					head, _, found := strings.Cut(tag, `json:"`)
					_ = head
					if found {
						value, _, _ := strings.Cut(tag[strings.Index(tag, `json:"`)+6:], `"`)
						key = strings.Split(value, ",")[0]
					}
				}
				c.Fields[name] = key
				if _, ok := field.Type.(*ast.MapType); ok {
					c.MapFields[name] = true
				}
				value := "None"
				switch fieldType := field.Type.(type) {
				case *ast.ArrayType:
					value = "[]"
				case *ast.MapType:
					value = "{}"
				case *ast.Ident:
					switch fieldType.Name {
					case "string":
						value = `""`
					case "bool":
						value = "False"
					case "int":
						value = "0"
					}
				}
				c.Defaults[typ.Name.Name] = append(c.Defaults[typ.Name.Name], strconv.Quote(key)+":"+value)
			}
		}
	}
	// Generate scalar bounds from the same authoritative source declarations.
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		for _, spec := range gen.Specs {
			value, ok := spec.(*ast.ValueSpec)
			if !ok || len(value.Names) != 1 || len(value.Values) != 1 {
				return nil, fmt.Errorf("unsupported stage constant declaration")
			}
			text, err := c.expression(value.Values[0])
			if err != nil {
				return nil, fmt.Errorf("compile stage constant: %w", err)
			}
			c.line(0, value.Names[0].Name+" = "+text)
		}
	}
	c.Output.WriteString(`
def _cut(value, separator):
    head, found, tail = value.partition(separator)
    return head, tail, bool(found)

def _match(pattern, value):
    try:
        return re.search(pattern, value) is not None, None
    except re.error as error:
        return False, error

`)
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}
		if fn.Name.Name != "offlineValid" && fn.Name.Name != "offlineStop" && fn.Name.Name != "analyzeStages" {
			continue
		}
		names := []string{}
		for _, field := range fn.Type.Params.List {
			for _, name := range field.Names {
				names = append(names, name.Name)
			}
		}
		c.line(0, "def "+fn.Name.Name+"("+strings.Join(names, ", ")+"):")
		if err := c.block(fn.Body, 1); err != nil {
			return nil, err
		}
		c.Output.WriteString("\n")
	}
	c.Output.WriteString(`
def analyze(args):
    if not isinstance(args, list) or not all(isinstance(value, str) for value in args):
        return {"outputs": [], "complete": False, "reason": "malformed argument types", "boundary": 0}
    return analyzeStages(args, PROGRAM)

if __name__ == "__main__":
    raw = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
    result = {"outputs": [], "complete": False, "reason": "malformed request", "boundary": 0}
    if len(raw) > 4 * 1024 * 1024:
        result["reason"] = "input overflow"
    else:
        try:
            result = analyze(json.loads(raw)["arguments"])
        except (UnicodeError, ValueError, KeyError, TypeError):
            pass
    print(json.dumps(result, ensure_ascii=False))
`)
	return []byte(c.Output.String()), nil
}

// line emits one properly indented generated statement.
//
// Example: nested native loops retain their control scope.
func (c *pythonCompiler) line(
	depth int,
	text string,
) {
	c.Output.WriteString(strings.Repeat("    ", depth) + text + "\n")
}

// expression translates the bounded expression vocabulary without parser-domain decisions.
//
// Example: map lookup remains map lookup in the generated consumer.
func (c *pythonCompiler) expression(node ast.Expr) (string, error) {
	switch x := node.(type) {
	case *ast.Ident:
		switch x.Name {
		case "true":
			return "True", nil
		case "false":
			return "False", nil
		case "nil":
			return "None", nil
		}
		return x.Name, nil
	case *ast.BasicLit:
		if x.Kind == token.STRING || x.Kind == token.CHAR {
			value, err := strconv.Unquote(x.Value)
			if err != nil {
				return "", err
			}
			return strconv.Quote(value), nil
		}
		return x.Value, nil
	case *ast.ParenExpr:
		value, err := c.expression(x.X)
		return "(" + value + ")", err
	case *ast.UnaryExpr:
		value, err := c.expression(x.X)
		if err != nil {
			return "", err
		}
		if x.Op == token.NOT {
			return "(not " + value + ")", nil
		}
		return "", fmt.Errorf("unsupported unary %s", x.Op)
	case *ast.BinaryExpr:
		left, err := c.expression(x.X)
		if err != nil {
			return "", err
		}
		right, err := c.expression(x.Y)
		if err != nil {
			return "", err
		}
		op := x.Op.String()
		switch x.Op {
		case token.LAND:
			op = "and"
		case token.LOR:
			op = "or"
		}
		return "(" + left + " " + op + " " + right + ")", nil
	case *ast.SelectorExpr:
		value, err := c.expression(x.X)
		if err != nil {
			return "", err
		}
		key, ok := c.Fields[x.Sel.Name]
		if !ok {
			return "", fmt.Errorf("unknown field %s", x.Sel.Name)
		}
		return value + "[" + strconv.Quote(key) + "]", nil
	case *ast.IndexExpr:
		value, err := c.expression(x.X)
		if err != nil {
			return "", err
		}
		index, err := c.expression(x.Index)
		return value + "[" + index + "]", err
	case *ast.SliceExpr:
		value, err := c.expression(x.X)
		if err != nil {
			return "", err
		}
		low, high := "", ""
		if x.Low != nil {
			low, err = c.expression(x.Low)
			if err != nil {
				return "", err
			}
		}
		if x.High != nil {
			high, err = c.expression(x.High)
			if err != nil {
				return "", err
			}
		}
		return value + "[" + low + ":" + high + "]", nil
	case *ast.CompositeLit:
		if _, ok := x.Type.(*ast.ArrayType); ok {
			values := []string{}
			for _, element := range x.Elts {
				value, err := c.expression(element)
				if err != nil {
					return "", err
				}
				values = append(values, value)
			}
			return "[" + strings.Join(values, ",") + "]", nil
		}
		name, ok := x.Type.(*ast.Ident)
		if !ok {
			return "", fmt.Errorf("unsupported literal type")
		}
		values := append([]string{}, c.Defaults[name.Name]...)
		for _, element := range x.Elts {
			kv, ok := element.(*ast.KeyValueExpr)
			if !ok {
				return "", fmt.Errorf("unsupported unkeyed struct")
			}
			field, ok := kv.Key.(*ast.Ident)
			if !ok {
				return "", fmt.Errorf("unsupported struct key")
			}
			value, err := c.expression(kv.Value)
			if err != nil {
				return "", err
			}
			values = append(values, strconv.Quote(c.Fields[field.Name])+":"+value)
		}
		return "{" + strings.Join(values, ",") + "}", nil
	case *ast.CallExpr:
		values := []string{}
		for _, arg := range x.Args {
			value, err := c.expression(arg)
			if err != nil {
				return "", err
			}
			values = append(values, value)
		}
		if array, ok := x.Fun.(*ast.ArrayType); ok {
			typ, ok := array.Elt.(*ast.Ident)
			if ok && typ.Name == "byte" && len(values) == 1 {
				return values[0] + ".encode('utf-8')", nil
			}
			return "", fmt.Errorf("unsupported conversion")
		}
		if sel, ok := x.Fun.(*ast.SelectorExpr); ok {
			pkg, ok := sel.X.(*ast.Ident)
			if !ok {
				return "", fmt.Errorf("unsupported call selector")
			}
			switch pkg.Name + "." + sel.Sel.Name {
			case "strings.HasPrefix":
				return values[0] + ".startswith(" + values[1] + ")", nil
			case "strings.Contains":
				return "(" + values[1] + " in " + values[0] + ")", nil
			case "strings.Split":
				return values[0] + ".split(" + values[1] + ")", nil
			case "strings.Cut":
				return "_cut(" + strings.Join(values, ",") + ")", nil
			case "regexp.MatchString":
				return "_match(" + strings.Join(values, ",") + ")", nil
			}
			return "", fmt.Errorf("unsupported vendor call %s.%s", pkg.Name, sel.Sel.Name)
		}
		name, ok := x.Fun.(*ast.Ident)
		if !ok {
			return "", fmt.Errorf("unsupported call")
		}
		if name.Name == "append" {
			if len(values) < 2 {
				return "", fmt.Errorf("unsupported append")
			}
			tail := "[" + strings.Join(values[1:], ",") + "]"
			if x.Ellipsis.IsValid() {
				tail = "list(" + values[1] + ")"
			}
			return "(" + values[0] + " + " + tail + ")", nil
		}
		return name.Name + "(" + strings.Join(values, ",") + ")", nil
	}
	return "", fmt.Errorf("unsupported expression %T", node)
}

// block emits a statement block and rejects every unsupported construct.
//
// Example: generation cannot silently change an unsupported parser transition.
func (c *pythonCompiler) block(
	block *ast.BlockStmt,
	depth int,
) error {
	if len(block.List) == 0 {
		c.line(depth, "pass")
	}
	for _, stmt := range block.List {
		if err := c.statement(stmt, depth); err != nil {
			return err
		}
	}
	return nil
}

// statement translates control flow, including Go loop post operations on continue.
//
// Example: a consumed following value advances the same residual index in both runtimes.
func (c *pythonCompiler) statement(
	node ast.Stmt,
	depth int,
) error {
	switch x := node.(type) {
	case *ast.AssignStmt:
		left := []string{}
		for _, value := range x.Lhs {
			text, err := c.expression(value)
			if err != nil {
				return err
			}
			left = append(left, text)
		}
		right := []string{}
		for _, value := range x.Rhs {
			text, err := c.expression(value)
			if err != nil {
				return err
			}
			right = append(right, text)
		}
		if len(left) == 2 && len(x.Rhs) == 1 {
			if index, ok := x.Rhs[0].(*ast.IndexExpr); ok {
				owner, err := c.expression(index.X)
				if err != nil {
					return err
				}
				key, err := c.expression(index.Index)
				if err != nil {
					return err
				}
				right = []string{owner + ".get(" + key + ")", key + " in " + owner}
			}
		}
		op := "="
		if x.Tok != token.DEFINE && x.Tok != token.ASSIGN {
			op = x.Tok.String()
		}
		c.line(depth, strings.Join(left, ", ")+" "+op+" "+strings.Join(right, ", "))
		return nil
	case *ast.IfStmt:
		if x.Init != nil {
			if err := c.statement(x.Init, depth); err != nil {
				return err
			}
		}
		cond, err := c.expression(x.Cond)
		if err != nil {
			return err
		}
		c.line(depth, "if "+cond+":")
		if err := c.block(x.Body, depth+1); err != nil {
			return err
		}
		if x.Else != nil {
			c.line(depth, "else:")
			if block, ok := x.Else.(*ast.BlockStmt); ok {
				return c.block(block, depth+1)
			}
			return c.statement(x.Else, depth+1)
		}
		return nil
	case *ast.ReturnStmt:
		values := []string{}
		for _, value := range x.Results {
			text, err := c.expression(value)
			if err != nil {
				return err
			}
			values = append(values, text)
		}
		c.line(depth, "return "+strings.Join(values, ", "))
		return nil
	case *ast.IncDecStmt:
		value, err := c.expression(x.X)
		if err != nil {
			return err
		}
		op := "+="
		if x.Tok == token.DEC {
			op = "-="
		}
		c.line(depth, value+" "+op+" 1")
		return nil
	case *ast.ForStmt:
		if x.Init != nil {
			if err := c.statement(x.Init, depth); err != nil {
				return err
			}
		}
		cond := "True"
		var err error
		if x.Cond != nil {
			cond, err = c.expression(x.Cond)
			if err != nil {
				return err
			}
		}
		c.line(depth, "while "+cond+":")
		c.LoopPosts = append(c.LoopPosts, x.Post)
		if err := c.block(x.Body, depth+1); err != nil {
			return err
		}
		c.LoopPosts = c.LoopPosts[:len(c.LoopPosts)-1]
		if x.Post != nil {
			return c.statement(x.Post, depth+1)
		}
		return nil
	case *ast.RangeStmt:
		value, err := c.expression(x.X)
		if err != nil {
			return err
		}
		key, err := c.expression(x.Key)
		if err != nil {
			return err
		}
		names := key
		iterator := "range(len(" + value + "))"
		if x.Value != nil {
			item, err := c.expression(x.Value)
			if err != nil {
				return err
			}
			names = key + ", " + item
			iterator = "enumerate(" + value + ")"
		}
		c.line(depth, "for "+names+" in "+iterator+":")
		c.LoopPosts = append(c.LoopPosts, nil)
		if err := c.block(x.Body, depth+1); err != nil {
			return err
		}
		c.LoopPosts = c.LoopPosts[:len(c.LoopPosts)-1]
		return nil
	case *ast.SwitchStmt:
		if x.Init != nil {
			return fmt.Errorf("unsupported initialized switch")
		}
		tag, err := c.expression(x.Tag)
		if err != nil {
			return err
		}
		for n, element := range x.Body.List {
			clause, ok := element.(*ast.CaseClause)
			if !ok {
				return fmt.Errorf("unsupported switch element")
			}
			if clause.List == nil {
				c.line(depth, "else:")
			} else {
				conditions := []string{}
				for _, option := range clause.List {
					value, err := c.expression(option)
					if err != nil {
						return err
					}
					conditions = append(conditions, tag+" == "+value)
				}
				prefix := "elif"
				if n == 0 {
					prefix = "if"
				}
				c.line(depth, prefix+" "+strings.Join(conditions, " or ")+":")
			}
			if len(clause.Body) == 0 {
				c.line(depth+1, "pass")
			}
			for _, stmt := range clause.Body {
				if err := c.statement(stmt, depth+1); err != nil {
					return err
				}
			}
		}
		return nil
	case *ast.BranchStmt:
		if x.Label != nil {
			return fmt.Errorf("unsupported labeled control")
		}
		switch x.Tok {
		case token.CONTINUE:
			if len(c.LoopPosts) > 0 {
				post := c.LoopPosts[len(c.LoopPosts)-1]
				if post != nil {
					if err := c.statement(post, depth); err != nil {
						return err
					}
				}
			}
			c.line(depth, "continue")
			return nil
		case token.BREAK:
			c.line(depth, "break")
			return nil
		}
		return fmt.Errorf("unsupported branch %s", x.Tok)
	case *ast.ExprStmt:
		value, err := c.expression(x.X)
		if err != nil {
			return err
		}
		c.line(depth, value)
		return nil
	}
	return fmt.Errorf("unsupported statement %T", node)
}
