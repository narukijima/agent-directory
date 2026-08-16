#!/bin/bash
# tools/check-runtime-readiness.sh — runtimeとworkspaceのread-only preflight。
set -u

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"
require_codex=false
require_claude=false

usage() {
  printf 'Usage: %s [--require-codex] [--require-claude]\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  printf 'RUNTIME_READINESS_BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

sanitize_version() {
  printf '%s' "$1" | tr '[:space:]' '_' | tr -cd '[:alnum:]._+()-'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-codex) require_codex=true ;;
    --require-claude) require_claude=true ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || blocked 'git-executable-unavailable'
current_dir="$(pwd -P)"
current_git_root="$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$current_git_root" ]] || blocked 'not-git-repository'
current_git_root="$(CDPATH= cd -- "$current_git_root" && pwd -P)"
[[ "$current_dir" == "$repo_root" && "$current_git_root" == "$repo_root" ]] || \
  blocked 'workspace-root-mismatch'

codex_state='executable-unavailable'
codex_version='unavailable'
if command -v codex >/dev/null 2>&1; then
  codex_version_raw="$(codex --version </dev/null 2>/dev/null || true)"
  codex_version="$(sanitize_version "${codex_version_raw%%$'\n'*}")"
  if [[ -n "$codex_version" ]]; then
    if codex login status </dev/null >/dev/null 2>&1; then
      codex_state='ready'
    else
      codex_state='auth-unavailable'
    fi
  else
    codex_state='startup-failure'
    codex_version='unavailable'
  fi
fi

claude_state='executable-unavailable'
claude_version='unavailable'
if command -v claude >/dev/null 2>&1; then
  claude_version_raw="$(claude --version </dev/null 2>/dev/null || true)"
  claude_version="$(sanitize_version "${claude_version_raw%%$'\n'*}")"
  if [[ -n "$claude_version" ]]; then
    if claude auth status </dev/null >/dev/null 2>&1; then
      claude_state='ready'
    else
      claude_state='auth-unavailable'
    fi
  else
    claude_state='startup-failure'
    claude_version='unavailable'
  fi
fi

claude_oauth_env='absent'
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  claude_oauth_env='present'
fi

printf 'RUNTIME_READINESS workspace=ready codex=%s codex_version=%s claude=%s claude_version=%s claude_oauth_env=%s\n' \
  "$codex_state" "$codex_version" "$claude_state" "$claude_version" "$claude_oauth_env"

if [[ "$require_codex" == true && "$codex_state" != ready ]]; then
  blocked "codex-$codex_state"
fi
if [[ "$require_claude" == true && "$claude_state" != ready ]]; then
  blocked "claude-$claude_state"
fi
