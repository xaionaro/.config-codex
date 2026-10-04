package main

import (
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"strings"
)

// rule is a source-defined consumption transition.
//
// Example: required author patterns consume output-looking values.
type rule struct {
	Arity     string `json:"arity"`
	Validator string `json:"validator"`
	Source    string `json:"source"`
}

// program is the canonical restricted stage program.
//
// Example: unknown native handlers take the advisory transition.
type program struct {
	Pipeline         map[string][]string `json:"pipeline"`
	Front            map[string]rule     `json:"front"`
	Revision         map[string]rule     `json:"revision"`
	Diff             map[string]rule     `json:"diff"`
	Short            map[string]rule     `json:"short"`
	UnsupportedFront []string            `json:"unsupported_front"`
}

// put inserts exact source-audited spellings.
//
// Example: source-defined negations are individually listed.
func put(
	table map[string]rule,
	names string,
	arity string,
	validator string,
	source string,
) {
	for _, name := range strings.Fields(names) {
		table[name] = rule{arity, validator, source}
	}
}

// main generates two embedded projections from one editable program.
//
// Example: runtime program.json absence changes neither projection.
func main() {
	p := program{Pipeline: map[string][]string{"log": {"log_front_scan", "revision_raw_delimiter", "role_scan"}, "show": {"log_front_scan", "revision_raw_delimiter", "role_scan"}, "diff": {"ordinary_diff_gate", "revision_raw_delimiter", "role_scan"}}, Front: map[string]rule{}, Revision: map[string]rule{}, Diff: map[string]rule{}, Short: map[string]rule{}, UnsupportedFront: []string{"--i-still-use-this", "--no-i-still-use-this"}}
	put(p.Front, "--quiet --no-quiet --source --no-source --use-mailmap --no-use-mailmap --mailmap --no-mailmap --clear-decorations", "none", "any", "log.c:275-298,parse-options exact KEEP_UNKNOWN")
	put(p.Front, "--decorate-refs --decorate-refs-exclude", "required", "any", "log.c:289-292 OPT_STRING_LIST")
	put(p.Front, "--no-decorate-refs --no-decorate-refs-exclude --no-decorate", "none", "any", "parse-options callback/string-list unset")
	put(p.Front, "--decorate", "optional", "decorations", "log.c:161-178")
	put(p.Revision, "--author --committer --grep --grep-reflog --encoding --since --after --until --before", "required", "any", "revision.c:2355-2371,2643-2675")
	put(p.Revision, "--max-count --skip", "required", "decimal", "revision.c:2332-2340")
	put(p.Revision, "--date", "required", "date", "revision.c:2633")
	put(p.Revision, "--graph --no-graph --oneline --no-merges --merges --full-history --show-pulls --reverse --topo-order --date-order --first-parent --all --root --full-diff --abbrev-commit --no-abbrev-commit --relative-date --always --no-commit-id --basic-regexp --extended-regexp --fixed-strings --perl-regexp --regexp-ignore-case --all-match --invert-grep", "none", "any", "revision.c explicit strcmp and pseudo handlers")
	put(p.Revision, "--pretty", "optional", "pretty", "revision.c pretty bare/attached")
	put(p.Revision, "--format", "attached", "pretty", "revision.c format equals")
	put(p.Diff, "--output", "required", "any", "git v2.51.0 diff.c:5120-5134 xfopen during parse")
	put(p.Diff, "--stat-width --stat-name-width --stat-graph-width --stat-count --inter-hunk-context", "required", "decimal", "diff.c stat/inter-hunk callbacks")
	put(p.Diff, "--src-prefix --dst-prefix --line-prefix --output-indicator-new --output-indicator-old --output-indicator-context", "required", "any", "diff.c string stores")
	put(p.Diff, "--output-indicator-new --output-indicator-old --output-indicator-context", "required", "character", "diff.c:5204 diff_opt_char")
	put(p.Diff, "--textconv --no-textconv --ext-diff --no-ext-diff --quiet --exit-code --check --name-only --name-status --numstat --shortstat --summary --raw --patch --no-patch --patch-with-stat --patch-with-raw --binary --full-index --no-color --no-prefix --default-prefix --no-renames --ignore-space-change --ignore-all-space --ignore-space-at-eol --ignore-blank-lines --follow", "none", "any", "diff.c no-argument declaration/callbacks")
	put(p.Diff, "--color", "optional", "color", "diff.c OPT__COLOR")
	put(p.Diff, "--stat --unified --find-renames --find-copies", "optional", "decimal", "diff.c optional callbacks restricted decimal subset")
	put(p.Short, "p u s w b z R a r", "none", "any", "diff.c short flags")
	put(p.Short, "O", "required", "any", "diff.c order filename")
	put(p.Short, "S G", "required", "nonempty", "git v2.51.0 diff.c:5175-5197 pickaxe callback rejects empty")
	put(p.Short, "U C M", "optional", "decimal", "diff.c optional attached short")
	put(p.Short, "n", "required", "decimal", "revision.c -n")
	data, err := json.Marshal(p)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile("program.json", data, 0600); err != nil {
		panic(err)
	}
	generated, err := format.Source([]byte("// Code generated from stagegen/main.go; DO NOT EDIT.\npackage main\n// offlineProgramJSON embeds the canonical source-audited stage transitions.\n//\n// Example: runtime analysis does not depend on a filesystem program file.\nconst offlineProgramJSON = " + fmt.Sprintf("%q", string(data)) + "\n"))
	if err != nil {
		panic(fmt.Errorf("format generated stage program: %w", err))
	}
	if err := os.WriteFile("../stage_program_generated.go", generated, 0600); err != nil {
		panic(err)
	}
	engine, err := compilePython("../stage_program.go")
	if err != nil {
		panic(err)
	}
	quoted, err := json.Marshal(string(data))
	if err != nil {
		panic(err)
	}
	result := append([]byte("# Generated from stagegen/main.go; DO NOT EDIT.\nimport json,re,sys\nPROGRAM=json.loads("+string(quoted)+")\n"), engine...)
	if err := os.WriteFile(os.Getenv("ECI_STAGE_PROJECTION"), result, 0600); err != nil {
		panic(err)
	}
}
