#!/bin/bash
# tools/check-runtime-readiness.sh — runtimeとworkspaceのread-only preflight。
set -u

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"
require_codex=false
require_claude=false
probe_workspace_write=false
write_probe=''
runtime_profile="${AGENT_DIRECTORY_RUNTIME_PROFILE:-}"
runtime_profile_source='environment'
required_capabilities=''
filesystem_read='not-probed'
filesystem_write='not-probed'
network='not-probed'
localhost='not-probed'
process_spawn='not-probed'
git_capability='not-probed'
github='not-probed'
browser='not-probed'
api='not-probed'

cleanup() {
  [[ -z "$write_probe" ]] || rm -f -- "$write_probe" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} [--profile ask|auto|full] [--require-codex] [--require-claude]" \
    '       [--require-capability <name>] [--capability-state <name>=declared|unavailable]' \
    '       [--probe-workspace-write]' >&2
  exit 2
}

blocked() {
  printf 'RUNTIME_READINESS_BLOCKED reason=%s layer=%s' "$2" "$1" >&2
  [[ -z "${3:-}" ]] || printf ' capability=%s' "$3" >&2
  printf '\n' >&2
  exit 1
}

sanitize_version() {
  printf '%s' "$1" | tr '[:space:]' '_' | tr -cd '[:alnum:]._+()-'
}

normalize_capability() {
  case "$(printf '%s' "$1" | tr '-' '_')" in
    filesystem_read|filesystem_write|network|localhost|process_spawn|git|github|browser|api)
      printf '%s' "$(printf '%s' "$1" | tr '-' '_')"
      ;;
    *) return 1 ;;
  esac
}

capability_state() {
  case "$1" in
    filesystem_read) printf '%s' "$filesystem_read" ;;
    filesystem_write) printf '%s' "$filesystem_write" ;;
    network) printf '%s' "$network" ;;
    localhost) printf '%s' "$localhost" ;;
    process_spawn) printf '%s' "$process_spawn" ;;
    git) printf '%s' "$git_capability" ;;
    github) printf '%s' "$github" ;;
    browser) printf '%s' "$browser" ;;
    api) printf '%s' "$api" ;;
  esac
}

set_capability_state() {
  case "$1" in
    filesystem_read) filesystem_read="$2" ;;
    filesystem_write) filesystem_write="$2" ;;
    network) network="$2" ;;
    localhost) localhost="$2" ;;
    process_spawn) process_spawn="$2" ;;
    git) git_capability="$2" ;;
    github) github="$2" ;;
    browser) browser="$2" ;;
    api) api="$2" ;;
  esac
}

require_capability() {
  local capability="$1"
  printf '%s\n' "$required_capabilities" | grep -Fqx -- "$capability" || \
    required_capabilities="${required_capabilities}${capability}
"
}

capability_is_required() {
  printf '%s\n' "$required_capabilities" | grep -Fqx -- "$1"
}

requirements_csv() {
  local result
  result="$(printf '%s' "$required_capabilities" | sed '/^$/d' | paste -sd, -)"
  printf '%s' "${result:-none}"
}

require_value() {
  [[ "$#" -ge 2 && -n "$2" ]] || usage
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      require_value "$@"
      runtime_profile="$2"
      runtime_profile_source='explicit'
      shift
      ;;
    --require-codex) require_codex=true ;;
    --require-claude) require_claude=true ;;
    --require-capability)
      require_value "$@"
      capability="$(normalize_capability "$2")" || usage
      require_capability "$capability"
      shift
      ;;
    --capability-state)
      require_value "$@"
      capability="$(normalize_capability "${2%%=*}")" || usage
      declared_state="${2#*=}"
      [[ "$2" == *=* && "$declared_state" != "$2" ]] || usage
      case "$declared_state" in declared|unavailable) ;; *) usage ;; esac
      set_capability_state "$capability" "$declared_state"
      shift
      ;;
    --probe-workspace-write)
      probe_workspace_write=true
      require_capability filesystem_write
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

if [[ -z "$runtime_profile" ]]; then
  runtime_profile='auto'
  runtime_profile_source='recommended-default'
fi
case "$runtime_profile" in ask|auto|full) ;; *) usage ;; esac

if capability_is_required filesystem_write && [[ "$filesystem_write" != unavailable ]]; then
  probe_workspace_write=true
fi

command -v git >/dev/null 2>&1 || blocked runtime 'git-executable-unavailable' git
git_capability='observed'
process_spawn='observed'
current_dir="$(pwd -P)"
current_git_root="$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$current_git_root" ]] || blocked repository-integrity 'not-git-repository'
current_git_root="$(CDPATH= cd -- "$current_git_root" && pwd -P)"
[[ "$current_dir" == "$repo_root" && "$current_git_root" == "$repo_root" ]] || \
  blocked repository-integrity 'workspace-root-mismatch'
[[ -r "$repo_root/AGENTS.md" ]] || blocked runtime 'filesystem-read-denied' filesystem_read
filesystem_read='observed'

if [[ "$probe_workspace_write" == true ]]; then
  if write_probe="$(mktemp "$repo_root/.runtime-write-probe.XXXXXX" 2>/dev/null)"; then
    if rm -f -- "$write_probe"; then
      write_probe=''
      filesystem_write='observed'
    else
      filesystem_write='unavailable'
    fi
  else
    filesystem_write='unavailable'
  fi
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

network_requirement='not-declared'
github_api_requirement='not-declared'
git_remote_requirement='not-declared'
localhost_requirement='not-declared'
capability_is_required network && network_requirement='required'
capability_is_required api && network_requirement='required'
capability_is_required github && github_api_requirement='required'
capability_is_required github && git_remote_requirement='required'
capability_is_required localhost && localhost_requirement='required'

printf 'RUNTIME_CAPABILITIES runtime_profile=%s runtime_profile_source=%s required_capabilities=%s workspace_root=observed filesystem_read=%s filesystem_write=%s network=%s localhost=%s process_spawn=%s process_spawning=%s git=%s github=%s browser=%s api=%s network_requirement=%s github_api_requirement=%s git_remote_requirement=%s localhost_requirement=%s codex_executable=%s codex_authentication=%s codex_version=%s claude_executable=%s claude_authentication=%s claude_version=%s claude_oauth_env=%s github_process_token=%s github_process_token_policy=explicit-ci-only\n' \
  "$runtime_profile" "$runtime_profile_source" "$(requirements_csv)" \
  "$filesystem_read" "$filesystem_write" "$network" "$localhost" "$process_spawn" "$process_spawn" \
  "$git_capability" "$github" "$browser" "$api" "$network_requirement" \
  "$github_api_requirement" "$git_remote_requirement" "$localhost_requirement" \
  "$codex_executable" "$codex_authentication" "$codex_version" \
  "$claude_executable" "$claude_authentication" "$claude_version" "$claude_oauth_env" \
  "$github_process_token"

unverified_capabilities=''
while IFS= read -r required_capability; do
  [[ -n "$required_capability" ]] || continue
  required_state="$(capability_state "$required_capability")"
  if [[ "$required_state" == unavailable ]]; then
    blocked runtime 'capability-unavailable' "$required_capability"
  fi
  if [[ "$required_state" == not-probed ]]; then
    unverified_capabilities="${unverified_capabilities}${required_capability},"
  fi
done <<< "$required_capabilities"
if [[ -n "$unverified_capabilities" ]]; then
  printf 'RUNTIME_READINESS_UNVERIFIED capabilities=%s\n' "${unverified_capabilities%,}"
fi

if [[ "$require_codex" == true && "$codex_authentication" != authenticated ]]; then
  if [[ "$codex_executable" == available ]]; then
    blocked external-provider 'codex-authentication-unavailable'
  fi
  blocked runtime "codex-executable-$codex_executable"
fi
if [[ "$require_claude" == true && "$claude_authentication" != authenticated ]]; then
  if [[ "$claude_executable" == available ]]; then
    blocked external-provider 'claude-authentication-unavailable'
  fi
  blocked runtime "claude-executable-$claude_executable"
fi
