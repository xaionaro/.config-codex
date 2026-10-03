package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Invocation describes the native Git context without an executable or shell syntax.
//
// Example: Invocation{CWD: "/repo", Arguments: []string{"diff"}} observes a diff.
type Invocation struct {
	CWD         string            `json:"cwd"`
	Arguments   []string          `json:"arguments"`
	Environment map[string]string `json:"environment"`
}

// Result is the closed set of observation outcomes.
//
// Example: Advisory permits independently checked harmless inspection.
type Result int

const (
	// Helper reports a source-attributed first child with a successful initial exec certificate.
	//
	// Example: a reached executable textconv is a Helper.
	Helper Result = iota + 1
	// NoHelper reports native completion without a reached child.
	//
	// Example: a clean cached diff is NoHelper.
	NoHelper
	// Advisory reports unsupported or insufficient observation evidence.
	//
	// Example: an unavailable namespace tool is Advisory.
	Advisory
)

// MarshalJSON translates closed domain values to the public string protocol.
//
// Example: Helper encodes as "Helper".
func (result Result) MarshalJSON() ([]byte, error) {
	switch result {
	case Helper:
		return json.Marshal("Helper")
	case NoHelper:
		return json.Marshal("NoHelper")
	case Advisory:
		return json.Marshal("Advisory")
	default:
		return nil, fmt.Errorf("unknown observation result")
	}
}

// Observation reports the bounded finding and native raw-inspection alternative.
//
// Example: a textconv result contains a hatch with --no-textconv.
type Observation struct {
	Result   Result   `json:"result"`
	Category string   `json:"category,omitempty"`
	Target   string   `json:"target,omitempty"`
	Reason   string   `json:"reason"`
	Hatch    []string `json:"hatch,omitempty"`
}

// Inspect observes an eligible native invocation without running a reached helper.
//
// Example: Inspect(in) returns Advisory when isolation is unavailable.
func Inspect(in Invocation) (observation Observation) {
	verb, reason := admission(in)
	if reason != "" {
		return advisory(reason)
	}
	if err := inheritedDescriptorAdmission(); err != nil {
		return advisory(err.Error())
	}
	s, err := newSandbox(in)
	if err != nil {
		return advisory(err.Error())
	}
	// A finding is insufficient if owned temporary state could not be cleaned up.
	//
	// Example: an unlink failure turns the finding into Advisory.
	defer func() {
		if err := os.RemoveAll(s.dir); err != nil {
			observation = advisory("remove owned observer state: " + err.Error())
		}
	}()
	globals := append([]string{}, in.Arguments[:verb]...)
	configArgs := append(append([]string{}, globals...), "config", "--null", "--list")
	data, _, status, err := s.run(configArgs, metadataOutput)
	if err != nil {
		return advisory(err.Error())
	}
	if status != 0 {
		return advisory("effective config could not be read safely")
	}
	config, err := readConfig(data)
	if err != nil {
		return advisory(err.Error())
	}
	for key, value := range config {
		if (key == "core.worktree" && value != "") || (key == "core.bare" && value != "false") {
			return advisory("unsupported effective worktree administration")
		}
		if strings.HasPrefix(key, "trace") && value != "" && value != "0" && value != "false" {
			return advisory("unmodeled original trace configuration")
		}
		if (key == "core.sparsecheckout" || key == "index.sparse" || key == "core.splitindex" || key == "extensions.worktreeconfig" || key == "extensions.partialclone" || key == "extensions.objectformat" && value != "sha1" || strings.HasSuffix(key, ".promisor")) && value != "" && value != "false" {
			return advisory("unsupported repository/index/object configuration: " + key)
		}
	}
	data, _, status, err = s.run([]string{"--version"}, metadataOutput)
	if err != nil {
		return advisory(err.Error())
	}
	if status != 0 || string(data) != "git version 2.51.0\n" {
		return advisory("unsupported native Git version; requires 2.51.0")
	}
	monitorConfigured := false
	if _, exists := config["core.fsmonitor"]; exists {
		monitorArgs := append(append([]string{}, globals...), "config", "--type=bool", "--get", "core.fsmonitor")
		var monitorEvents []traceEvent
		data, monitorEvents, status, err = s.run(monitorArgs, metadataOutput)
		if err != nil {
			return advisory(err.Error())
		}
		switch {
		case status == 0 && string(data) == "true\n":
			return advisory("unsupported daemon fsmonitor before native replay")
		case status == 0 && string(data) == "false\n":
		case status == 128:
			for _, event := range monitorEvents {
				if event.Event == "error" && strings.HasPrefix(event.Message, "bad boolean config value ") && strings.HasSuffix(event.Message, " for 'core.fsmonitor'") {
					monitorConfigured = true
					break
				}
			}
			if !monitorConfigured {
				return advisory("effective fsmonitor boolean/path preparation unresolved")
			}
		default:
			return advisory("effective fsmonitor boolean/path preparation unresolved")
		}
	}
	_, events, status, err := s.run(in.Arguments, replayOutput)
	if err != nil {
		return advisory(err.Error())
	}
	var first *traceEvent
	blocked := false
	terminated := false
	for i := range events {
		event := events[i]
		if event.Event == "child_start" && first == nil {
			first = &events[i]
		}
		if first != nil && len(first.Argv) > 0 && event.Thread == first.Thread && event.Event == "error" && strings.HasPrefix(event.Message, "cannot fork() for "+first.Argv[0]+":") && strings.HasSuffix(event.Message, "Resource temporarily unavailable") {
			blocked = true
		}
		if first != nil && event.Event == "child_exit" && event.ChildID == first.ChildID && event.PID == -1 && event.Code == -1 {
			terminated = true
			break
		}
	}
	if first == nil {
		if status == 0 || status == 1 && (in.Arguments[verb] == "grep" || in.Arguments[verb] == "diff") {
			return Observation{Result: NoHelper, Reason: "supported native observation completed without a child attempt"}
		}
		return advisory("native inspection failed without sufficient helper evidence")
	}
	if !blocked || !terminated {
		return advisory("first child lacks blocked-fork evidence")
	}
	category, target := classify(*first, config, in.Environment)
	if category == "" {
		return advisory("first child has unknown preparation or auxiliary identity")
	}
	childEnvironment, err := capturedGitEnvironment(in.Environment, events, in.Arguments[verb], s.cwd)
	if err != nil {
		return advisory(err.Error())
	}
	if category == "external-diff" {
		childEnvironment, err = externalChildEnvironment(s.launchTrace, *first, childEnvironment)
		if err != nil {
			return advisory(err.Error())
		}
	}
	childCWD := filepath.Dir(s.gitdir)
	if err := certifyInitialExec(*first, childCWD, childEnvironment); err != nil {
		return advisory(err.Error())
	}
	if strings.ContainsAny(target, "|&;<>()$`\\\"' \t\n*?[#~=%") {
		target = "/bin/sh"
	} else {
		cwd := childCWD
		if first.CWD != "" {
			cwd = first.CWD
		}
		target, err = resolveProgram(target, cwd, childEnvironment)
		if err != nil {
			return advisory(err.Error())
		}
	}
	return Observation{Result: Helper, Category: category, Target: target, Reason: "first configured helper reached blocked process creation and successful kernel initial exec; raw hatch disables relevant conversion, including converted pickaxe semantics, and configured fsmonitor", Hatch: rawHatch(in.Arguments, verb, monitorConfigured)}
}

// environmentList converts explicit invocation environment to child environment entries.
//
// Example: environmentList(map[string]string{"PATH":"/bin"}) returns PATH=/bin.
func environmentList(env map[string]string) []string {
	out := make([]string, 0, len(env))
	for key, value := range env {
		out = append(out, key+"="+value)
	}
	return out
}
