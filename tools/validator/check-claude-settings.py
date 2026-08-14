#!/usr/bin/env python3
"""Validate the agent-directory-owned Claude Code SessionStart subtree."""

import json
import sys


EXPECTED_SESSION_START = [
    {
        "matcher": "startup",
        "hooks": [
            {
                "type": "command",
                "command": 'bash "$CLAUDE_PROJECT_DIR/tools/setup-local-environment.sh"',
            }
        ],
    }
]
FORBIDDEN_SETTING_TEXT = (".env", "GH_TOKEN", "GITHUB_TOKEN", "API_KEY")


def contains_forbidden_text(value: object) -> bool:
    if isinstance(value, str):
        return any(forbidden in value for forbidden in FORBIDDEN_SETTING_TEXT)
    if isinstance(value, list):
        return any(contains_forbidden_text(item) for item in value)
    if isinstance(value, dict):
        return any(
            contains_forbidden_text(key) or contains_forbidden_text(item)
            for key, item in value.items()
        )
    return False


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as handle:
            settings = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return 1
    if not isinstance(settings, dict):
        return 1
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return 1
    if hooks.get("SessionStart") != EXPECTED_SESSION_START:
        return 1
    return 1 if contains_forbidden_text(settings) else 0


if __name__ == "__main__":
    raise SystemExit(main())
