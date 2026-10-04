package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

const (
	// hookCodeCommitProducerRequired identifies a coordinator-owned commit attempt.
	//
	// Example: git commit during active coordinator work selects this gate.
	hookCodeCommitProducerRequired DiagnosticCode = "ECI_GIT_COMMIT_PRODUCER_REQUIRED"
	// hookCodeGitCrossScopeDenied identifies another undeclared repository target.
	//
	// Example: git -C /dependency add file needs the same owner's declaration.
	hookCodeGitCrossScopeDenied DiagnosticCode = "ECI_GIT_CROSS_SCOPE_DENIED"
	// hookCodeCoordinatorEditRouting identifies a physical protected-hook mutation.
	//
	// Example: git checkout -- hooks/validate-bash.sh selects this gate.
	hookCodeCoordinatorEditRouting DiagnosticCode = "ECI_COORDINATOR_EDIT_ROUTING_REQUIRED"
	// hookCodeWorkerHookInstallerDenied identifies provider installation ownership.
	//
	// Example: a Worker executing the canonical installer uses the Supervisor route.
	hookCodeWorkerHookInstallerDenied DiagnosticCode = "ECI_WORKER_HOOK_INSTALLER_DENIED"
	// hookCodeWorkerScriptTargetDenied identifies an undeclared Worker script root.
	//
	// Example: bash /dependency/check.sh requires the owner-bound dependency route.
	hookCodeWorkerScriptTargetDenied DiagnosticCode = "ECI_WORKER_SCRIPT_TARGET_DENIED"
	// hookCodeCoordinatorScriptTargetDenied identifies an undeclared coordinator script.
	//
	// Example: an existing foreign test script needs its repository declaration.
	hookCodeCoordinatorScriptTargetDenied DiagnosticCode = "ECI_COORDINATOR_SCRIPT_TARGET_DENIED"
	// hookCodeCrossSessionActiveMarkerDenied identifies foreign live-session writes.
	//
	// Example: tee targeting another owner's eci_active selects this gate.
	hookCodeCrossSessionActiveMarkerDenied DiagnosticCode = "ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED"
)

// inspectHookEffects completes callback-owned checks on every reachable command.
// Unknown shell values remain advisory unless a concrete effect is established.
//
// Example: a native git diff followed by git add still routes the second child.
func inspectHookEffects(
	request Request,
	result Result,
) *Diagnostic {
	if request.Marker != MarkerActive || result.ShellAnalysis == nil {
		return nil
	}
	for _, record := range result.ShellAnalysis.Commands {
		if record.Reachability == segmentUnreachable || len(record.Argv) == 0 {
			continue
		}
		argv := make([]token, len(record.Argv))
		for index, value := range record.Argv {
			argv[index] = token{value: value, offset: index}
		}
		child := hookCommandChild(record, argv)
		if len(child) == 0 || !hookArgumentKnown(record, child[0].offset) {
			continue
		}
		if diagnostic := inspectHookGit(request, record, child); diagnostic != nil {
			return diagnostic
		}
		if diagnostic := inspectHookLifecycle(request, record, child); diagnostic != nil {
			return diagnostic
		}
		if diagnostic := inspectHookScript(request, record, child); diagnostic != nil {
			return diagnostic
		}
		if diagnostic := inspectHookCleanup(record, child); diagnostic != nil {
			return diagnostic
		}
		childRequest := request
		childRequest.CWD = record.CWD
		childRequest.CWDKnown = record.CWDKnown
		for index := 1; index < len(child); index++ {
			if !hookArgumentKnown(record, child[index].offset) {
				child[index].value = ""
			}
		}
		if diagnostic := inspectHookControlWriter(childRequest, child, record.Segment); diagnostic != nil {
			return diagnostic
		}
	}
	return nil
}

// hookCommandChild retains the concrete child of transparent shell launches.
// Prefix environment records are context data rather than executable argv.
//
// Example: CODEX_SESSION_ID=owner timeout 5 git add file selects git.
func hookCommandChild(
	record ShellCommandRecord,
	argv []token,
) []token {
	for len(argv) > 0 {
		name, _, assignment := strings.Cut(argv[0].value, "=")
		if !assignment || !isIdentifier(name) {
			break
		}
		argv = argv[1:]
	}
	if len(argv) == 0 {
		return nil
	}
	child, uncertainty := unwrap(argv, record.Segment)
	if uncertainty != nil || len(child) == 0 {
		return nil
	}
	if filepath.Base(child[0].value) != "timeout" {
		return child
	}
	index := 1
	for index < len(child) && strings.HasPrefix(child[index].value, "-") {
		if !hookArgumentKnown(record, child[index].offset) {
			return nil
		}
		switch child[index].value {
		case "--":
			index++
			goto duration
		case "-k", "--kill-after", "-s", "--signal":
			index++
			if index >= len(child) || !hookArgumentKnown(record, child[index].offset) {
				return nil
			}
		default:
			if !strings.HasPrefix(child[index].value, "--kill-after=") && !strings.HasPrefix(child[index].value, "--signal=") && child[index].value != "--preserve-status" && child[index].value != "--foreground" && child[index].value != "--verbose" {
				return nil
			}
		}
		index++
	}
duration:
	if index+1 >= len(child) || !hookArgumentKnown(record, child[index].offset) {
		return nil
	}
	child, uncertainty = unwrap(child[index+1:], record.Segment)
	if uncertainty != nil {
		return nil
	}
	return child
}

// hookArgumentKnown reports one concrete word with stable argv cardinality.
//
// Example: an unknown quoted commit message does not obscure the Git verb.
func hookArgumentKnown(
	record ShellCommandRecord,
	index int,
) bool {
	return !slices.Contains(record.UnknownArguments, index) &&
		!slices.Contains(record.MayDisappearArguments, index) &&
		!slices.Contains(record.MayMultiplyArguments, index) &&
		!slices.Contains(record.UnknownCardinalityArguments, index)
}

// hookGitFamily identifies the native Worker operations routed to the typed CLI.
// Membership depends on the default verb family, never its selected options.
//
// Example: worktree list stays native while worktree add uses the typed route.
func hookGitFamily(
	argv []token,
	verbIndex int,
) bool {
	switch argv[verbIndex].value {
	case "add", "rm", "mv", "reset", "checkout", "switch", "commit", "update-index", "read-tree", "merge", "rebase", "cherry-pick", "revert", "am", "stash", "pull":
		return true
	case "worktree":
		if verbIndex+1 >= len(argv) {
			return false
		}
		switch argv[verbIndex+1].value {
		case "add":
			return true
		}
	}
	return false
}

// hookGitDirectory resolves explicit Git directory selection in original order.
// It never substitutes the callback directory for an unknown child directory.
//
// Example: git -C /project -C subdir add file selects /project/subdir.
func hookGitDirectory(
	record ShellCommandRecord,
	argv []token,
	verbIndex int,
) string {
	directory := ""
	if record.CWDKnown {
		directory = record.CWD
	}
	for index := 1; index < verbIndex; index++ {
		value := argv[index].value
		target := ""
		switch {
		case value == "-c" || value == "--config-env" || value == "--exec-path" || value == "--namespace" || value == "--super-prefix":
			index++
			continue
		case value == "-C":
			index++
			if index >= verbIndex || !hookArgumentKnown(record, argv[index].offset) {
				return ""
			}
			target = argv[index].value
		case strings.HasPrefix(value, "-C"):
			if !hookArgumentKnown(record, argv[index].offset) {
				return ""
			}
			target = strings.TrimPrefix(value, "-C")
		case value == "--work-tree" || value == "--git-dir":
			index++
			if index >= verbIndex || !hookArgumentKnown(record, argv[index].offset) {
				return ""
			}
			target = argv[index].value
		case strings.HasPrefix(value, "--work-tree=") || strings.HasPrefix(value, "--git-dir="):
			if !hookArgumentKnown(record, argv[index].offset) {
				return ""
			}
			_, target, _ = strings.Cut(value, "=")
		}
		if target == "" {
			continue
		}
		if filepath.IsAbs(target) {
			directory = resolvePathIdentity(target)
			continue
		}
		if directory == "" {
			return ""
		}
		directory = resolvePathIdentity(filepath.Join(directory, target))
	}
	return directory
}

// inspectHookGit routes selected Worker families and resolves coordinator scope.
// Native show, diff, log and bisect retain every option and repository context.
//
// Example: an owned Worker add is redirected to stage-content with its target.
func inspectHookGit(
	request Request,
	record ShellCommandRecord,
	argv []token,
) *Diagnostic {
	if filepath.Base(argv[0].value) != "git" {
		return nil
	}
	verbIndex := gitSubcommandIndex(argv)
	if verbIndex >= len(argv) || !hookArgumentKnown(record, argv[verbIndex].offset) {
		return nil
	}
	for _, index := range record.MayDisappearArguments {
		if index < argv[verbIndex].offset {
			return nil
		}
	}
	for _, index := range record.MayMultiplyArguments {
		if index < argv[verbIndex].offset {
			return nil
		}
	}
	for _, index := range record.UnknownCardinalityArguments {
		if index < argv[verbIndex].offset {
			return nil
		}
	}
	if argv[verbIndex].value == "worktree" && verbIndex+1 < len(argv) && !hookArgumentKnown(record, argv[verbIndex+1].offset) {
		return nil
	}
	if request.Role == RoleWorker && !hookGitFamily(argv, verbIndex) {
		return nil
	}
	if request.Role == RoleCoordinator && !hookGitCoordinatorMutation(argv, verbIndex) {
		return nil
	}
	directory := hookGitDirectory(record, argv, verbIndex)
	if request.Role == RoleWorker {
		if repository := hookGitRepository(record, argv, verbIndex); repository != "" {
			directory = repository
		}
		diagnostic := diagnosticForToken(CodeWorkerGitOwnershipDenied,
			fmt.Sprintf("native Worker Git family %s selects repository context %s", argv[verbIndex].value, firstNonEmpty(directory, "<unresolved>")),
			record.Segment, argv[verbIndex].offset, argv[verbIndex],
			"use \"$HOME/.codex/bin/eci-worker-git\" --repo <repository> stage-content|stage-removals|stage-hunks|unstage|restore|remove|move|commit with exact literal paths and explicit source/destination modes; preserve the original repository context, scope agreement, fresh same-index lookup and complete staged-result review; only with explicit user authorization for the exact command and environment use --repo <repository> run-once --reason <reason> --user-authorized -- <native Git args>",
			"worker-git-ownership")
		diagnostic.Path = directory
		return diagnostic
	}
	if argv[verbIndex].value == "commit" {
		for _, argument := range argv[verbIndex+1:] {
			if argument.value == "--dry-run" || argument.value == "--help" || argument.value == "-h" {
				return nil
			}
		}
		diagnostic := diagnosticForToken(hookCodeCommitProducerRequired, "active coordinator selects a Producer-owned commit in "+directory,
			record.Segment, argv[verbIndex].offset, argv[verbIndex], "hand the exact prepared-index checkpoint to its assigned Producer; inspect the complete staged result and preserve other contributions", "producer-checkpoint")
		diagnostic.Path = directory
		return diagnostic
	}
	if diagnostic := inspectHookGitBroad(record, argv, verbIndex, directory); diagnostic != nil {
		return diagnostic
	}
	repository := hookGitRepository(record, argv, verbIndex)
	if repository == "" {
		return nil
	}
	approved := false
	for _, root := range request.ApprovedRoots {
		if repository == resolvePathIdentity(root) {
			approved = true
			break
		}
	}
	if !approved && len(request.ApprovedRoots) > 0 {
		diagnostic := diagnosticForToken(hookCodeGitCrossScopeDenied, "Git mutation selects another repository: "+repository,
			record.Segment, argv[verbIndex].offset, argv[verbIndex], "the legitimate session owner declares this exact repository with \"$HOME/.codex/bin/eci-active\" repository-allow-on <canonical-repository> \"<reason>\", then performs the same scoped work", "git-cross-scope")
		diagnostic.Path = repository
		return diagnostic
	}
	return inspectHookGitProtectedTarget(record, argv, verbIndex, repository)
}

// hookGitCoordinatorMutation recognizes concrete native coordinator effects.
// Read-only native verbs retain their original options without a legacy denylist.
// Preview flags are exempt only for verbs that define them as a dry run.
//
// Example: branch --list is inspection while branch feature changes a ref.
func hookGitCoordinatorMutation(
	argv []token,
	verbIndex int,
) bool {
	for _, argument := range argv[verbIndex+1:] {
		if argument.value == "--help" || argument.value == "-h" {
			return false
		}
		if argument.value == "-n" {
			switch argv[verbIndex].value {
			case "add", "rm", "mv", "clean", "push":
				return false
			}
		}
		if argument.value == "--dry-run" {
			switch argv[verbIndex].value {
			case "add", "rm", "mv", "clean", "push", "fetch", "commit":
				return false
			}
		}
	}
	if hookGitFamily(argv, verbIndex) {
		return true
	}
	switch argv[verbIndex].value {
	case "branch", "tag":
		if verbIndex+1 >= len(argv) {
			return false
		}
		for _, argument := range argv[verbIndex+1:] {
			switch argument.value {
			case "--list", "-l", "--show-current", "--contains", "--merged", "--no-merged", "--points-at", "-v", "-vv":
				return false
			}
		}
		return true
	case "config":
		for _, argument := range argv[verbIndex+1:] {
			switch argument.value {
			case "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "--show-origin", "--show-scope", "get", "list":
				return false
			}
		}
		return verbIndex+2 < len(argv)
	case "clean", "push", "fetch", "pull", "gc", "prune", "repack":
		return true
	case "update-ref", "replace", "reflog":
		return verbIndex+1 < len(argv)
	case "symbolic-ref":
		return verbIndex+2 < len(argv)
	case "remote":
		if verbIndex+1 >= len(argv) {
			return false
		}
		switch argv[verbIndex+1].value {
		case "add", "prune", "remove", "rename", "set-head", "set-url", "update":
			return true
		}
	}
	return false
}

// hookGitRepository asks native Git to resolve only the selected repository.
// Unavailable repository observations remain advisory and never invent a target.
//
// Example: -C and core.worktree configuration are interpreted by Git itself.
func hookGitRepository(
	record ShellCommandRecord,
	argv []token,
	verbIndex int,
) string {
	directory := record.CWD
	if !record.CWDKnown {
		directory = ""
		for index := 1; index < verbIndex; index++ {
			value := argv[index].value
			target := ""
			switch {
			case value == "-C":
				index++
				if index >= verbIndex || !hookArgumentKnown(record, argv[index].offset) {
					return ""
				}
				target = argv[index].value
			case strings.HasPrefix(value, "-C"):
				if !hookArgumentKnown(record, argv[index].offset) {
					return ""
				}
				target = strings.TrimPrefix(value, "-C")
			case isGitSplitContextOption(value):
				index++
			}
			if target == "" {
				continue
			}
			if !filepath.IsAbs(target) {
				return ""
			}
			// The first concrete absolute -C makes native Git's selected
			// repository independent of its otherwise unknown incoming CWD.
			directory = string(filepath.Separator)
			break
		}
		if directory == "" {
			return ""
		}
	}
	arguments := make([]string, 0, verbIndex+1)
	for _, argument := range argv[1:verbIndex] {
		if !hookArgumentKnown(record, argument.offset) {
			return ""
		}
		arguments = append(arguments, argument.value)
	}
	arguments = append(arguments, "rev-parse", "--show-toplevel")
	command := exec.Command("/usr/bin/git", arguments...)
	command.Dir = directory
	command.Env = os.Environ()
	for index, argument := range record.Argv {
		if index >= argv[0].offset {
			break
		}
		name, _, assignment := strings.Cut(argument, "=")
		if !assignment || !isIdentifier(name) {
			continue
		}
		if !hookArgumentKnown(record, index) {
			return ""
		}
		command.Env = append(command.Env, argument)
	}
	output, err := command.Output()
	if err != nil {
		// Git owns nonrepository, unsupported-option and unavailable-path
		// errors. None of them establishes another concrete repository.
		return ""
	}
	root := strings.TrimSuffix(string(output), "\n")
	if !filepath.IsAbs(root) {
		return ""
	}
	return resolvePathIdentity(root)
}

// inspectHookGitBroad identifies explicit whole-index or whole-worktree effects.
// Unknown option and scalar identity remains advisory; previews stay native.
//
// Example: git add -A -- file is narrow, whereas git add -A is whole-worktree.
func inspectHookGitBroad(
	record ShellCommandRecord,
	argv []token,
	verbIndex int,
	directory string,
) *Diagnostic {
	verb := argv[verbIndex].value
	if verb != "add" && verb != "reset" && verb != "clean" {
		return nil
	}
	whole := verb == "reset" && verbIndex+1 == len(argv)
	paths := 0
	options := true
	revision := false
	for _, argument := range argv[verbIndex+1:] {
		if !hookArgumentKnown(record, argument.offset) {
			if !options && whole && slices.Contains(record.MayDisappearArguments, argument.offset) {
				continue
			}
			return nil
		}
		value := argument.value
		if options && value == "--" {
			options = false
			if verb == "reset" {
				whole = true
			}
			continue
		}
		if options && strings.HasPrefix(value, "-") {
			switch value {
			case "--dry-run", "-n", "--help", "-h":
				return nil
			case "-A", "--all", "-u", "--update":
				whole = verb == "add"
			case "--hard", "--mixed", "--merge", "--keep":
				whole = verb == "reset"
			case "--soft":
				return nil
			case "-f", "-d", "-x", "-X", "-fd", "-fdx", "-df", "-ff", "-ffdx":
				whole = verb == "clean"
			case "-q", "--quiet", "-v", "--verbose":
			default:
				return nil
			}
			continue
		}
		if verb == "reset" && options && !revision {
			if !whole {
				// Without an explicit reset mode or --, this literal may be
				// a path rather than a revision. That identity stays advisory.
				return nil
			}
			revision = true
			continue
		}
		if value != "." && value != ":/" && value != directory {
			paths++
		}
	}
	if !whole || paths > 0 {
		return nil
	}
	diagnostic := diagnosticForToken(CodeBroadDestructiveDenied, "Git "+verb+" selects the whole repository index or worktree: "+directory,
		record.Segment, argv[verbIndex].offset, argv[verbIndex], "name the exact owned repository-relative paths or use the bounded typed Worker operation; preserve unrelated work", "git-broad-effect")
	diagnostic.Path = directory
	return diagnostic
}

// inspectHookGitProtectedTarget checks explicit physical writes to live hooks.
// Index-only staging or removal leaves the physical hook entry intact.
//
// Example: git checkout -- hooks/validate-bash.sh names a live hook.
func inspectHookGitProtectedTarget(
	record ShellCommandRecord,
	argv []token,
	verbIndex int,
	repository string,
) *Diagnostic {
	verb := argv[verbIndex].value
	if verb != "checkout" && verb != "rm" && verb != "mv" {
		return nil
	}
	physical := true
	paths := verb == "rm" || verb == "mv"
	for _, argument := range argv[verbIndex+1:] {
		if argument.value == "--cached" || argument.value == "--staged" || argument.value == "-S" {
			physical = false
		}
		if argument.value == "--worktree" || argument.value == "-W" {
			physical = true
		}
	}
	if !physical {
		return nil
	}
	for _, argument := range argv[verbIndex+1:] {
		if argument.value == "--" {
			paths = true
			continue
		}
		if !paths || !hookArgumentKnown(record, argument.offset) || strings.HasPrefix(argument.value, "-") {
			continue
		}
		if target, protected := protectedHookModeTargetPath(repository, argument.value); protected {
			diagnostic := diagnosticForToken(hookCodeCoordinatorEditRouting, "Git "+verb+" physically overwrites, removes or relocates protected live hook "+target,
				record.Segment, argument.offset, argument, "the responsible Producer edits this tracked hook source in place and stages exact owned paths with eci-worker-git; use index-only unstage for index correction; do not reroute the same destructive operation", "coordinator-protected-target")
			diagnostic.Path = target
			return diagnostic
		}
	}
	return nil
}

// hookResolvedExecutable resolves a concrete command against its proven CWD
// and visible PATH assignments. Unavailable filesystem observations remain advisory.
//
// Example: an existing ./bin/eci-active alias resolves to its canonical target.
func hookResolvedExecutable(
	record ShellCommandRecord,
	value string,
) string {
	if !record.CWDKnown && !filepath.IsAbs(value) && strings.ContainsRune(value, '/') {
		return ""
	}
	directory := ""
	if record.CWDKnown {
		directory = record.CWD
	}
	resolved := resolveExecutable(value, directory)
	if !strings.ContainsRune(value, '/') {
		for index, argument := range record.Argv {
			if argument == value {
				break
			}
			name, path, assignment := strings.Cut(argument, "=")
			if !assignment || name != "PATH" {
				continue
			}
			if !hookArgumentKnown(record, index) {
				return ""
			}
			resolved = ""
			for _, entry := range filepath.SplitList(path) {
				if !filepath.IsAbs(entry) {
					if !record.CWDKnown {
						continue
					}
					entry = filepath.Join(directory, entry)
				}
				candidate := filepath.Join(entry, value)
				if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
					resolved = candidate
					break
				}
			}
		}
	}
	if resolved == "" {
		return ""
	}
	return resolvePathIdentity(resolved)
}

// inspectHookLifecycle binds resolved lifecycle mutations to their owner/session.
// Read-only help and status remain available even for an unrelated PATH collision.
//
// Example: Worker repository-allow-on stays available in the current session.
func inspectHookLifecycle(
	request Request,
	record ShellCommandRecord,
	argv []token,
) *Diagnostic {
	if len(argv) < 2 || !hookArgumentKnown(record, argv[1].offset) || isLifecycleReadOnlyInvocation(argv) {
		return nil
	}
	resolved := hookResolvedExecutable(record, argv[0].value)
	canonical := resolvePathIdentity(filepath.Join(os.Getenv("HOME"), ".codex", "bin", "eci-active"))
	if resolved == "" {
		return nil
	}
	if resolved != canonical {
		if !strings.HasPrefix(filepath.Base(argv[0].value), "eci-active") {
			return nil
		}
		if info, err := os.Stat(resolved); err != nil || !info.Mode().IsRegular() {
			return nil
		}
		diagnostic := diagnosticForToken(CodeControlIdentityDenied, "lifecycle mutation selects a different executable target: "+resolved,
			record.Segment, argv[0].offset, argv[0], "invoke the current session's canonical \"$HOME/.codex/bin/eci-active\" through its legitimate owner", "lifecycle-target")
		diagnostic.Path = resolved
		return diagnostic
	}
	for index, argument := range record.Argv {
		name, value, assignment := strings.Cut(argument, "=")
		if index >= argv[0].offset || !assignment || name != "CODEX_SESSION_ID" || !hookArgumentKnown(record, index) || value == request.ActiveSession {
			continue
		}
		diagnostic := diagnosticForToken(CodeControlIdentityDenied, "lifecycle mutation environment selects another session: "+value,
			record.Segment, index, token{value: argument}, "preserve the callback owner session "+request.ActiveSession+" when using its canonical lifecycle route", "lifecycle-session")
		diagnostic.Path = canonical
		return diagnostic
	}
	if request.Role == RoleWorker && !isWorkerRepositoryAllowInvocation(argv) {
		return workerLifecycleIdentityDiagnostic(argv, argv[0], record.Segment, canonical)
	}
	for index := 1; index+1 < len(argv); index++ {
		if argv[index].value != "--session" && argv[index].value != "--session-id" {
			continue
		}
		if !hookArgumentKnown(record, argv[index+1].offset) || argv[index+1].value == request.ActiveSession {
			continue
		}
		diagnostic := diagnosticForToken(CodeControlIdentityDenied, "lifecycle mutation selects another session: "+argv[index+1].value,
			record.Segment, argv[index+1].offset, argv[index+1], "invoke the canonical lifecycle route with the current owner session "+request.ActiveSession, "lifecycle-session")
		diagnostic.Path = canonical
		return diagnostic
	}
	return nil
}

// inspectHookScript checks actual existing script targets against session roots.
// Syntax checking and missing script operands have no execution effect. File
// inspection is an external observation: failed stat/open/read/close observations
// cannot establish a concrete execution target and therefore remain advisory.
//
// Example: bash -n /dependency/check.sh is inspection; bash runs its target.
func inspectHookScript(
	request Request,
	record ShellCommandRecord,
	argv []token,
) *Diagnostic {
	name := filepath.Base(argv[0].value)
	index := 0
	if isShellInterpreter(name) || name == "python" || name == "python3" || name == "node" || name == "perl" || name == "ruby" || name == "source" || name == "." {
		index = 1
		for index < len(argv) {
			value := argv[index].value
			if value == "--noexec" || value == "-c" || value == "-" || (value == "-m" || value == "-e") && !isShellInterpreter(name) {
				return nil
			}
			if isShellInterpreter(name) && strings.HasPrefix(value, "-") && !strings.HasPrefix(value, "--") && strings.ContainsAny(value[1:], "ncs") {
				return nil
			}
			if isShellInterpreter(name) && (value == "-O" || value == "-o") {
				if index+1 >= len(argv) || !hookArgumentKnown(record, argv[index+1].offset) {
					return nil
				}
				index += 2
				continue
			}
			if value == "--" {
				index++
				break
			}
			if !strings.HasPrefix(value, "-") {
				break
			}
			if isShellInterpreter(name) && strings.HasPrefix(value, "--") {
				switch value {
				case "--noprofile", "--norc", "--posix", "--restricted", "--verbose", "--trace":
				default:
					return nil
				}
			}
			if isShellInterpreter(name) && !strings.HasPrefix(value, "--") && strings.Trim(value[1:], "abefhkmpruvxBCEHPT") != "" {
				return nil
			}
			index++
		}
	}
	if index >= len(argv) || !hookArgumentKnown(record, argv[index].offset) {
		return nil
	}
	if index == 0 && !strings.ContainsRune(argv[index].value, '/') {
		return nil
	}
	target := hookResolvedExecutable(record, argv[index].value)
	if index > 0 && record.CWDKnown && !filepath.IsAbs(argv[index].value) {
		target = resolvePathIdentity(filepath.Join(record.CWD, argv[index].value))
	}
	info, err := os.Stat(target)
	if err != nil || !info.Mode().IsRegular() {
		return nil
	}
	if index == 0 {
		// Direct binaries are ordinary executables; only script files have a
		// repository execution ownership boundary.
		file, openErr := os.Open(target)
		if openErr != nil {
			return nil
		}
		var prefix [2]byte
		count, readErr := file.Read(prefix[:])
		closeErr := file.Close()
		if readErr != nil || closeErr != nil || count != len(prefix) || string(prefix[:]) != "#!" {
			return nil
		}
	}
	providerRoot := resolvePathIdentity(filepath.Join(os.Getenv("HOME"), ".codex"))
	if target == filepath.Join(providerRoot, "bin", "eci-active") {
		return inspectHookLifecycle(request, record, argv[index:])
	}
	for _, root := range canonicalLifecycleRoots() {
		relative, relativeErr := filepath.Rel(root, target)
		if relativeErr != nil {
			continue
		}
		code := CodeControlOwnerRequired
		protected := false
		switch filepath.ToSlash(relative) {
		case "hooks/install-pre-commit-go-mod.sh":
			code = hookCodeWorkerHookInstallerDenied
			protected = true
		case "hooks/eci-review-gate.sh", "hooks/stop-gate.sh", "hooks/eci-active-gate.sh", "hooks/ate-orchestrator-gate.sh", "bin/eci-active", "bin/eci-review-gate", "bin/eci-stage":
			protected = true
		}
		if protected && request.Role == RoleWorker {
			diagnostic := diagnosticForToken(code, "Worker execution selects Supervisor-owned provider control: "+target,
				record.Segment, argv[index].offset, argv[index], "route this exact provider control invocation through the Supervisor in the same session", "worker-control-script")
			diagnostic.Path = target
			return diagnostic
		}
		if relative == filepath.Join("hooks", "eci-review-gate.sh") && len(argv) > index+2 && hookArgumentKnown(record, argv[index+2].offset) && argv[index+2].value != request.ActiveSession {
			diagnostic := diagnosticForToken(CodeControlIdentityDenied, "review gate selects another session: "+argv[index+2].value,
				record.Segment, argv[index+2].offset, argv[index+2], "invoke this canonical review gate for the current owner session "+request.ActiveSession, "review-session")
			diagnostic.Path = target
			return diagnostic
		}
	}
	if pathWithin(target, providerRoot) {
		return nil
	}
	if request.Role == RoleCoordinator {
		for _, root := range canonicalLifecycleRoots() {
			if target == filepath.Join(root, "hooks", "install-pre-commit-go-mod.sh") || pathWithin(target, filepath.Join(root, "hooks", "tests")) {
				return nil
			}
		}
	}
	for _, root := range request.ApprovedRoots {
		if pathWithin(target, resolvePathIdentity(root)) {
			return nil
		}
	}
	code := hookCodeWorkerScriptTargetDenied
	if request.Role == RoleCoordinator {
		code = hookCodeCoordinatorScriptTargetDenied
	}
	diagnostic := diagnosticForToken(code, "script execution selects target outside its assigned roots: "+target,
		record.Segment, argv[index].offset, argv[index], "the legitimate session owner declares the exact dependency repository from this session with \"$HOME/.codex/bin/eci-active\" repository-allow-on <canonical-repository> \"<reason>\", then executes the same script", "script-target")
	diagnostic.Path = target
	return diagnostic
}

// inspectHookControlWriter protects validated live sessions and their namespaces.
// It is shared with the planner's redirect pass to retain exact nested CWD facts.
//
// Example: tee to a sibling eci_active or rm of its ancestor names that target.
func inspectHookControlWriter(
	request Request,
	argv []token,
	segmentIndex int,
) *Diagnostic {
	if request.Marker != MarkerActive || request.Role != RoleWorker || len(argv) == 0 {
		return nil
	}
	name := filepath.Base(argv[0].value)
	if !isSourceWriter(name, argv) && name != "find" {
		return nil
	}
	for index := 1; index < len(argv); index++ {
		argument := argv[index]
		if argument.value == "" || strings.HasPrefix(argument.value, "-") || !isSourceWriterOperand(argv, index) && name != "find" {
			continue
		}
		if name == "find" {
			action, found := findDynamicAction(argv)
			if !found || action.value != "-delete" || index != 1 {
				continue
			}
		}
		pathArgument, pathLike := commandPathOperand(argv[0].value, argument)
		if name == "cp" || name == "find" {
			pathArgument, pathLike = argument, true
		}
		if !pathLike {
			continue
		}
		lexical := pathArgument.value
		if !filepath.IsAbs(lexical) {
			if !request.CWDKnown {
				continue
			}
			lexical = filepath.Join(request.CWD, lexical)
		}
		lexical = filepath.Clean(lexical)
		resolved := resolvePathIdentity(lexical)
		if hookUnlinksDirectoryEntry(argv) {
			entry, err := resolvePathEntryWithMissingSuffix(lexical)
			if err != nil {
				// An unavailable external filesystem observation cannot
				// establish which directory entry would be unlinked.
				continue
			}
			resolved = entry
		}
		for _, marker := range request.ActiveMarkers {
			marker = resolvePathIdentity(marker)
			session := filepath.Dir(marker)
			current := filepath.Base(session) == request.ActiveSession
			if current && isCanonicalWorkerHandoffPath(resolved, []string{marker}) {
				continue
			}
			reserved := pathWithin(resolved, session) && isECIControlBasename(filepath.Base(resolved)) ||
				pathWithin(lexical, session) && isECIControlBasename(filepath.Base(lexical))
			ancestor := (name == "rm" || name == "mv" || name == "rmdir" || name == "find") && pathWithin(marker, resolved)
			if !reserved && !ancestor {
				continue
			}
			code := CodeControlOwnerRequired
			if !current {
				code = hookCodeCrossSessionActiveMarkerDenied
			}
			diagnostic := diagnosticForToken(code, "resolved write selects live session control target "+resolved+" (owner="+filepath.Base(session)+")",
				segmentIndex, index, pathArgument, "use the current session's owned task path; route the named live-control operation through its owning Supervisor without changing owner or session", "worker-live-control")
			diagnostic.Path = resolved
			return diagnostic
		}
	}
	return nil
}

// inspectHookCleanup protects existing live hooks from removal or relocation.
// Generated and ordinary task-owned leaves remain available for scoped cleanup.
//
// Example: rm of a live validate-bash.sh or its ancestor names the affected hook.
func inspectHookCleanup(
	record ShellCommandRecord,
	argv []token,
) *Diagnostic {
	name := filepath.Base(argv[0].value)
	if name != "rm" && name != "mv" && name != "rmdir" && name != "unlink" && name != "shred" && name != "srm" {
		return nil
	}
	for _, argument := range argv[1:] {
		if argument.value == "" || strings.HasPrefix(argument.value, "-") || !hookArgumentKnown(record, argument.offset) {
			continue
		}
		if !filepath.IsAbs(argument.value) && !record.CWDKnown {
			continue
		}
		target := argument.value
		if !filepath.IsAbs(target) {
			target = filepath.Join(record.CWD, target)
		}
		if hookUnlinksDirectoryEntry(argv) {
			entry, err := resolvePathEntryWithMissingSuffix(target)
			if err != nil {
				// The cleanup target remains advisory when its parent entry
				// cannot be observed; do not invent a live-hook relationship.
				continue
			}
			target = entry
		}
		if !hookUnlinksDirectoryEntry(argv) {
			target = resolvePathIdentity(target)
		}
		for _, root := range protectedHookModeRoots() {
			for _, relative := range protectedHookModeRelativePaths {
				hook := filepath.Join(root, relative)
				if !pathWithin(hook, target) {
					continue
				}
				if info, err := os.Stat(hook); err != nil || !info.Mode().IsRegular() {
					// Missing or unavailable hook entries do not prove a live
					// target. Keep ordinary cleanup available in that case.
					continue
				}
				diagnostic := diagnosticForToken(CodeBroadDestructiveDenied, "cleanup "+name+" removes or relocates live provider hook "+hook+" through target "+target,
					record.Segment, argument.offset, argument, "remove only the exact owned generated artifact; preserve this live hook entry and edit tracked source in place through its responsible Producer", "live-hook-cleanup")
				diagnostic.Path = target
				return diagnostic
			}
		}
	}
	return nil
}
