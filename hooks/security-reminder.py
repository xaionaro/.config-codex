#!/usr/bin/env python3
"""PreToolUse security reminders for risky edit patterns."""

import json
import os
import random
import sys
import time


PATTERNS = [
    {
        "rule": "github_actions_workflow",
        "path_contains": ".github/workflows/",
        "path_suffixes": (".yml", ".yaml"),
        "reminder": (
            "Security check: GitHub Actions workflow edits can introduce command injection. "
            "Do not place untrusted github.event values directly in run commands; pass them through env vars and quote shell expansions."
        ),
    },
    {
        "rule": "child_process_exec",
        "substrings": ["child_process.exec", "exec(", "execSync("],
        "reminder": "Security check: shell exec with dynamic input can create command injection. Prefer execFile/spawn with argv arrays.",
    },
    {
        "rule": "new_function",
        "substrings": ["new Function"],
        "reminder": "Security check: new Function with dynamic strings can execute arbitrary code. Use a non-eval design unless explicitly required.",
    },
    {
        "rule": "eval",
        "substrings": ["eval("],
        "reminder": "Security check: eval executes arbitrary code. Prefer JSON.parse or a structured parser.",
    },
    {
        "rule": "dangerously_set_html",
        "substrings": ["dangerouslySetInnerHTML"],
        "reminder": "Security check: dangerouslySetInnerHTML can create XSS. Sanitize trusted HTML with a proven sanitizer, or avoid raw HTML.",
    },
    {
        "rule": "document_write",
        "substrings": ["document.write"],
        "reminder": "Security check: document.write can create XSS and performance issues. Prefer safe DOM APIs.",
    },
    {
        "rule": "inner_html",
        "substrings": [".innerHTML =", ".innerHTML="],
        "reminder": "Security check: assigning innerHTML can create XSS. Prefer textContent or sanitized HTML.",
    },
    {
        "rule": "pickle",
        "substrings": ["pickle"],
        "reminder": "Security check: Python pickle can execute code when loading untrusted data. Prefer JSON or a safe serialization format.",
    },
    {
        "rule": "os_system",
        "substrings": ["os.system", "from os import system"],
        "reminder": "Security check: os.system should not receive user-controlled input. Prefer subprocess with argv arrays.",
    },
]


def proof_root() -> str:
    return os.environ.get("CODEX_PROOF_ROOT") or os.path.expanduser("~/.cache/codex-proof")


def state_file(session_id: str) -> str:
    safe = "".join(ch for ch in session_id if ch.isalnum() or ch in "_-") or "default"
    return os.path.join(proof_root(), f"security-warnings-{safe}.json")


def load_state(path: str) -> set[str]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return set(json.load(fh))
    except Exception:
        return set()


def save_state(path: str, state: set[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(sorted(state), fh)


def cleanup_old_state() -> None:
    root = proof_root()
    cutoff = time.time() - 30 * 24 * 60 * 60
    try:
        for name in os.listdir(root):
            if not name.startswith("security-warnings-"):
                continue
            path = os.path.join(root, name)
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
    except Exception:
        pass


def tool_content(tool_name: str, tool_input) -> tuple[str, str]:
    if isinstance(tool_input, str):
        return "", tool_input
    if not isinstance(tool_input, dict):
        return "", ""

    if tool_name == "apply_patch":
        patch = tool_input.get("command") or tool_input.get("patch") or tool_input.get("input") or ""
        return "", str(patch)
    if tool_name == "Write":
        return str(tool_input.get("file_path", "")), str(tool_input.get("content", ""))
    if tool_name == "Edit":
        return str(tool_input.get("file_path", "")), str(tool_input.get("new_string", ""))
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits") or []
        content = " ".join(str(edit.get("new_string", "")) for edit in edits if isinstance(edit, dict))
        return str(tool_input.get("file_path", "")), content
    if tool_name == "NotebookEdit":
        return str(tool_input.get("notebook_path", "")), ""
    return "", ""


def patch_paths(content: str) -> list[str]:
    paths: list[str] = []
    for line in content.splitlines():
        for prefix in ("*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "):
            if line.startswith(prefix):
                paths.append(line[len(prefix) :].strip())
    return paths


def main() -> int:
    if os.environ.get("ENABLE_SECURITY_REMINDER", "1") == "0":
        return 0
    if random.random() < 0.1:
        cleanup_old_state()

    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    tool_name = data.get("tool_name", "")
    if tool_name not in {"apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit"}:
        return 0

    file_path, content = tool_content(tool_name, data.get("tool_input", {}))
    paths = [file_path] if file_path else patch_paths(content)

    for pattern in PATTERNS:
        matched = False
        for path in paths:
            if (
                "path_contains" in pattern
                and pattern["path_contains"] in path
                and path.endswith(pattern.get("path_suffixes", ("",)))
            ):
                matched = True
        if not matched:
            for substring in pattern.get("substrings", []):
                if substring in content:
                    matched = True
                    break
        if not matched:
            continue

        session_id = str(data.get("session_id") or "default")
        state_path = state_file(session_id)
        state = load_state(state_path)
        key = f"{','.join(paths)}:{pattern['rule']}"
        if key in state:
            return 0
        state.add(key)
        save_state(state_path, state)
        print(json.dumps({"systemMessage": pattern["reminder"]}))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
