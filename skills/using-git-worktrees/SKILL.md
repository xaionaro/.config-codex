---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from current workspace or before executing implementation plans - creates isolated git worktrees with smart directory selection and safety verification
---

# Using Git Worktrees

## Overview

Git worktrees create isolated workspaces that share one repository, allowing work on multiple branches without switching the current checkout.

**Core principle:** Use the Codex global worktree directory by default; honor explicit project instructions only when `CODEX.md` or the user specifies them.

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Directory Selection

### 1. Check CODEX.md

```bash
grep -i "worktree.*director" CODEX.md 2>/dev/null
```

If `CODEX.md` explicitly specifies a worktree directory, use that path. If it is inside the repository, verify it is ignored before creating the worktree.

### 2. Default To Codex Global Storage

If `CODEX.md` has no explicit worktree directory, use:

```text
$HOME/.codex/worktrees/<project-name>/<branch-name>
```

Human-readable form: `~/.codex/worktrees/<project-name>/<branch-name>`.

Do not prompt for project-local paths unless the user asks for one or `CODEX.md` explicitly requires one.

## Safety Verification

### Default Global Directory

No repository ignore verification is needed for `$HOME/.codex/worktrees/<project-name>/` because it is outside the project checkout.

### Explicit Project-Local Directory

If `CODEX.md` or the user explicitly chooses a directory inside the repository, verify the directory is ignored before creating a worktree:

```bash
git check-ignore -q "$WORKTREE_PARENT"
```

If it is not ignored, fix isolation before proceeding:

1. Add the appropriate ignore rule.
2. Commit the ignore-rule change.
3. Create the worktree.

**Why critical:** This prevents committing worktree contents to the repository.

## Creation Steps

### 1. Detect Project Name

```bash
project=$(basename "$(git rev-parse --show-toplevel)")
```

### 2. Create Worktree

```bash
# Default when CODEX.md does not specify WORKTREE_PARENT.
WORKTREE_PARENT="${WORKTREE_PARENT:-$HOME/.codex/worktrees/$project}"
path="$WORKTREE_PARENT/$BRANCH_NAME"

mkdir -p "$WORKTREE_PARENT"
git worktree add "$path" -b "$BRANCH_NAME"
cd "$path"
```

### 3. Run Project Setup

Auto-detect and run the matching setup:

```bash
# Node.js
if [ -f package.json ]; then npm install; fi

# Rust
if [ -f Cargo.toml ]; then cargo build; fi

# Python
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi

# Go
if [ -f go.mod ]; then go mod download; fi
```

### 4. Verify Clean Baseline

Run project tests before changing code:

```bash
# Examples - use the project-appropriate command.
npm test
cargo test
pytest
go test ./...
```

If tests fail, report the failures and ask whether to proceed or investigate. If tests pass, report ready.

### 5. Report Location

```text
Worktree ready at <full-path>
Tests passing (<N> tests, 0 failures)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| `CODEX.md` specifies a worktree directory | Use it; if inside repo, verify ignored |
| No explicit directory preference | Use `$HOME/.codex/worktrees/<project-name>/` |
| User asks for a project-local directory | Use it; verify ignored |
| Explicit project-local directory is not ignored | Add ignore rule, commit it, then create worktree |
| Tests fail during baseline | Report failures and ask |
| No package.json/Cargo.toml/pyproject.toml/go.mod | Skip dependency setup |

## Common Mistakes

### Skipping Ignore Verification

- **Problem:** Project-local worktree contents get tracked and pollute git status.
- **Fix:** Verify the chosen project-local parent with `git check-ignore` before creating the worktree.

### Defaulting To Project-Local Storage

- **Problem:** Creates inconsistent locations and can expose generated worktree contents to the repository.
- **Fix:** Use `$HOME/.codex/worktrees/<project-name>/` unless `CODEX.md` or the user explicitly chooses another path.

### Proceeding With Failing Tests

- **Problem:** New failures cannot be separated from pre-existing failures.
- **Fix:** Report baseline failures and get explicit permission to proceed.

### Hardcoding Setup Commands

- **Problem:** Breaks on projects using different tools.
- **Fix:** Auto-detect from project files.

## Example Workflow

```text
You: I'm using the using-git-worktrees skill to set up an isolated workspace.

[Check CODEX.md - no explicit worktree directory]
[Create worktree: git worktree add "$HOME/.codex/worktrees/myproject/auth" -b feature/auth]
[Run npm install]
[Run npm test - 47 passing]

Worktree ready at ~/.codex/worktrees/myproject/auth
Tests passing (47 tests, 0 failures)
Ready to implement auth feature
```

## Red Flags

**Never:**
- Default to project-local worktree storage.
- Create a project-local worktree without verifying it is ignored.
- Skip baseline test verification.
- Proceed with failing tests without asking.
- Skip the `CODEX.md` check.

**Always:**
- Check `CODEX.md` for an explicit directory preference.
- Use `$HOME/.codex/worktrees/<project-name>/` as the fallback.
- Verify project-local directories are ignored.
- Auto-detect and run project setup.
- Verify the clean test baseline.

## Integration

**Called by:**
- **brainstorming** (Phase 4) - REQUIRED when design is approved and implementation follows
- **subagent-driven-development** - REQUIRED before executing any tasks
- **executing-plans** - REQUIRED before executing any tasks
- Any skill needing isolated workspace

**Pairs with:**
- **finishing-a-development-branch** - REQUIRED for cleanup after work complete
