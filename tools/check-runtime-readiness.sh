#!/bin/bash
# tools/check-runtime-readiness.sh — runtimeとworkspaceのread-only preflight。
set -u

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"
require_codex=false
require_claude=false
probe_workspace_write=false
write_probe=''

cleanup() {
  [[ -z "$write_probe" ]] || rm -f -- "$write_probe" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
  printf 'Usage: %s [--require-codex] [--require-claude] [--probe-workspace-write]\n' "${0##*/}" >&2
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
    --probe-workspace-write) probe_workspace_write=true ;;
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
[[ -r "$repo_root/AGENTS.md" ]] || blocked 'filesystem-read-denied'

filesystem_write='not-probed'
if [[ "$probe_workspace_write" == true ]]; then
  write_probe="$(mktemp "$repo_root/.runtime-write-probe.XXXXXX" 2>/dev/null)" || \
    blocked 'filesystem-write-denied'
  rm -f -- "$write_probe" || blocked 'filesystem-write-cleanup-failed'
  write_probe=''
  filesystem_write='observed'
fi

codex_executable='unavailable'
codex_authentication='not-probed'
codex_version='unavailable'
if command -v codex >/dev/null 2>&1; then
  codex_executable='available'
  codex_version_raw="$(codex --version </dev/null 2>/dev/null || true)"
  codex_version="$(sanitize_version "${codex_version_raw%%$'\n'*}")"
  if [[ -n "$codex_version" ]]; then
    if codex login status </dev/null >/dev/null 2>&1; then
      codex_authentication='authenticated'
    else
      codex_authentication='unavailable'
    fi
  else
    codex_executable='startup-failure'
    codex_version='unavailable'
  fi
fi

claude_executable='unavailable'
claude_authentication='not-probed'
claude_version='unavailable'
if command -v claude >/dev/null 2>&1; then
  claude_executable='available'
  claude_version_raw="$(claude --version </dev/null 2>/dev/null || true)"
  claude_version="$(sanitize_version "${claude_version_raw%%$'\n'*}")"
  if [[ -n "$claude_version" ]]; then
    if claude auth status </dev/null >/dev/null 2>&1; then
      claude_authentication='authenticated'
    else
      claude_authentication='unavailable'
    fi
  else
    claude_executable='startup-failure'
    claude_version='unavailable'
  fi
fi

claude_oauth_env='absent'
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  claude_oauth_env='present'
fi
github_process_token='absent'
if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  github_process_token='present'
fi

printf 'RUNTIME_CAPABILITIES workspace_root=observed filesystem_read=observed filesystem_write=%s process_spawning=observed network_requirement=not-declared github_api_requirement=not-declared git_remote_requirement=not-declared localhost_requirement=not-declared codex_executable=%s codex_authentication=%s codex_version=%s claude_executable=%s claude_authentication=%s claude_version=%s claude_oauth_env=%s github_process_token=%s github_process_token_policy=explicit-ci-only\n' \
  "$filesystem_write" "$codex_executable" "$codex_authentication" "$codex_version" \
  "$claude_executable" "$claude_authentication" "$claude_version" "$claude_oauth_env" \
  "$github_process_token"

if [[ "$require_codex" == true && "$codex_authentication" != authenticated ]]; then
  if [[ "$codex_executable" == available ]]; then
    blocked 'codex-authentication-unavailable'
  fi
  blocked "codex-executable-$codex_executable"
fi
if [[ "$require_claude" == true && "$claude_authentication" != authenticated ]]; then
  if [[ "$claude_executable" == available ]]; then
    blocked 'claude-authentication-unavailable'
  fi
  blocked "claude-executable-$claude_executable"
fi
