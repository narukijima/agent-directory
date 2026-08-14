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
    return 0 if hooks.get("SessionStart") == EXPECTED_SESSION_START else 1


if __name__ == "__main__":
    raise SystemExit(main())
