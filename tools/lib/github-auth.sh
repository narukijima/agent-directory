#!/usr/bin/env bash

# Shared GitHub authentication resolver for agent-directory Tools.
# This file is sourced by callers and intentionally never prints credential values.

GITHUB_AUTH_IMPLEMENTATION_VERSION=2
GITHUB_AUTH_SOURCE='none'
GITHUB_AUTH_REASON=''
GITHUB_AUTH_LOGIN=''
GITHUB_AUTH_MACHINE_FILE=''
GITHUB_AUTH_GIT_REASON=''

github_auth_machine_file() {
  printf '%s/agent-directory/github.env' "${XDG_CONFIG_HOME:-${HOME:-}/.config}"
}

github_auth_stat_mode() {
  local target="$1" mode=''
  mode="$(stat -f '%Lp' "$target" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    mode="$(stat -c '%a' "$target" 2>/dev/null || true)"
  fi
  printf '%s' "$mode"
}

github_auth_value_valid() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*|*[[:space:]]*) return 1 ;;
  esac
  return 0
}

# Reads one known dotenv key without sourcing or evaluating the file. The value is
# returned only through GITHUB_AUTH_PARSED_VALUE in the current shell.
github_auth_read_known_key() {
  local file="$1" key="$2" strict_single_key="$3"
  local line count=0 value=''
  GITHUB_AUTH_PARSED_VALUE=''
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "$key="*)
        count=$((count + 1))
        value="${line#"$key="}"
        ;;
      ''|'#'*)
        [[ "$strict_single_key" != true ]] || return 1
        ;;
      *)
        [[ "$strict_single_key" != true ]] || return 1
        ;;
    esac
  done < "$file"
  [[ "$count" == 1 ]] || return 1
  if [[ "$strict_single_key" != true ]]; then
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
  fi
  github_auth_value_valid "$value" || return 1
  GITHUB_AUTH_PARSED_VALUE="$value"
}

github_auth_machine_permissions() {
  local file="$1" dir mode
  dir="$(dirname "$file")"
  [[ -d "$dir" && ! -L "$dir" ]] || { GITHUB_AUTH_REASON='auth-store-missing'; return 1; }
  [[ -f "$file" && ! -L "$file" ]] || { GITHUB_AUTH_REASON='auth-store-missing'; return 1; }
  mode="$(github_auth_stat_mode "$dir")"
  [[ "$mode" == 700 ]] || { GITHUB_AUTH_REASON='auth-store-permissions'; return 1; }
  mode="$(github_auth_stat_mode "$file")"
  [[ "$mode" == 600 ]] || { GITHUB_AUTH_REASON='auth-store-permissions'; return 1; }
  return 0
}

github_auth_select_token() {
  local value="$1" source="$2"
  github_auth_value_valid "$value" || { GITHUB_AUTH_REASON='github-auth-unavailable'; return 1; }
  GH_TOKEN="$value"
  export GH_TOKEN
  export GH_HOST='github.com'
  export GH_PROMPT_DISABLED=1
  export GH_NO_UPDATE_NOTIFIER=1
  GITHUB_AUTH_SOURCE="$source"
  GITHUB_AUTH_REASON=''
}

# Resolution is capability-independent. Call github_auth_probe_api after resolution.
github_auth_resolve() {
  local workspace_root="${1:-}" machine_file machine_state='missing'
  GITHUB_AUTH_SOURCE='none'
  GITHUB_AUTH_REASON=''
  GITHUB_AUTH_LOGIN=''
  export GH_HOST='github.com'
  export GH_PROMPT_DISABLED=1
  export GH_NO_UPDATE_NOTIFIER=1

  if [[ -n "${GH_TOKEN:-}" ]]; then
    github_auth_select_token "$GH_TOKEN" 'process-gh-token'
    return $?
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    github_auth_select_token "$GITHUB_TOKEN" 'process-github-token'
    return $?
  fi
  if [[ -n "$workspace_root" && -f "$workspace_root/.env" ]]; then
    if github_auth_read_known_key "$workspace_root/.env" GH_TOKEN false; then
      github_auth_select_token "$GITHUB_AUTH_PARSED_VALUE" 'workspace-env'
      GITHUB_AUTH_PARSED_VALUE=''
      return 0
    fi
    GITHUB_AUTH_PARSED_VALUE=''
  fi

  machine_file="$(github_auth_machine_file)"
  GITHUB_AUTH_MACHINE_FILE="$machine_file"
  if [[ -e "$machine_file" ]]; then
    if ! github_auth_machine_permissions "$machine_file"; then
      GITHUB_AUTH_SOURCE='none'
      return 1
    fi
    if github_auth_read_known_key "$machine_file" GH_TOKEN true; then
      github_auth_select_token "$GITHUB_AUTH_PARSED_VALUE" 'machine-env'
      GITHUB_AUTH_PARSED_VALUE=''
      return 0
    fi
    GITHUB_AUTH_REASON='github-auth-unavailable'
    GITHUB_AUTH_PARSED_VALUE=''
    GITHUB_AUTH_SOURCE='none'
    return 1
  fi

  if command -v gh >/dev/null 2>&1; then
    GITHUB_AUTH_SOURCE='gh-stored'
    GITHUB_AUTH_REASON=''
    return 0
  fi
  GITHUB_AUTH_SOURCE='none'
  GITHUB_AUTH_REASON='auth-store-missing'
  return 1
}

github_auth_classify_api_error() {
  local output="$1"
  case "$output" in
    *'HTTP 401'*|*'Bad credentials'*|*'authentication token'*|*'gh auth login'*|*'not logged in'*)
      printf 'github-auth-unavailable' ;;
    *'HTTP 403'*|*'Resource not accessible'*|*'permission denied'*|*'Permission denied'*)
      printf 'github-permission-denied' ;;
    *'could not resolve'*|*'Could not resolve'*|*'connection'*|*'Connection'*|*'timed out'*|*'network'*|*'Network'*)
      printf 'github-api-unreachable' ;;
    *) printf 'github-api-unreachable' ;;
  esac
}

github_auth_probe_api() {
  local expected_login="${1:-}" output login
  GITHUB_AUTH_LOGIN=''
  if ! command -v gh >/dev/null 2>&1; then
    GITHUB_AUTH_REASON='github-auth-unavailable'
    return 1
  fi
  if ! output="$(GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh api user --jq .login 2>&1)"; then
    GITHUB_AUTH_REASON="$(github_auth_classify_api_error "$output")"
    return 1
  fi
  login="$(printf '%s\n' "$output" | tail -n 1 | tr -d '\r')"
  [[ -n "$login" && "$login" != *[[:space:]]* ]] || {
    GITHUB_AUTH_REASON='github-auth-unavailable'
    return 1
  }
  GITHUB_AUTH_LOGIN="$login"
  if [[ -n "$expected_login" && "$login" != "$expected_login" ]]; then
    GITHUB_AUTH_REASON='account-mismatch'
    return 1
  fi
  GITHUB_AUTH_REASON=''
  return 0
}

github_auth_remote_kind() {
  case "$1" in
    https://github.com/*) printf 'github-https' ;;
    git@github.com:*|ssh://git@github.com/*|ssh://github.com/*) printf 'github-ssh' ;;
    *) printf 'other' ;;
  esac
}

# Runs Git with the resolved credential only for HTTPS github.com. Token values are
# passed via the child environment, never via argv, Git config, or the remote URL.
github_git_run() {
  local workspace_root="$1" remote_url="$2"
  shift 2
  case "$(github_auth_remote_kind "$remote_url")" in
    github-https)
      github_auth_resolve "$workspace_root" || return 90
      command -v gh >/dev/null 2>&1 || return 91
      GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
        git -c credential.https://github.com.helper= \
        -c credential.https://github.com.helper='!gh auth git-credential' "$@"
      ;;
    *)
      GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git "$@"
      ;;
  esac
}

github_auth_classify_git_error() {
  local output="$1" status="${2:-1}"
  if [[ "$status" == 90 ]]; then
    printf '%s' "${GITHUB_AUTH_REASON:-github-auth-unavailable}"
    return
  fi
  if [[ "$status" == 91 ]]; then
    printf 'git-credential-unavailable'
    return
  fi
  case "$output" in
    *'could not read Username'*|*'Authentication failed'*|*'HTTP 401'*|*'Bad credentials'*)
      printf 'github-auth-unavailable' ;;
    *'HTTP 403'*|*'Permission denied'*|*'permission denied'*|*'Write access to repository not granted'*)
      printf 'github-permission-denied' ;;
    *'gh: command not found'*|*'auth git-credential'*'not found'*)
      printf 'git-credential-unavailable' ;;
    *'Could not resolve host'*|*'Failed to connect'*|*'Connection timed out'*)
      printf 'github-api-unreachable' ;;
    *) printf 'remote-unreachable' ;;
  esac
}

github_auth_probe_git() {
  local workspace_root="$1" remote_name="$2" remote_url="$3" output status
  set +e
  output="$(github_git_run "$workspace_root" "$remote_url" -C "$workspace_root" \
    ls-remote --heads "$remote_name" 2>&1)"
  status=$?
  set -e
  if (( status != 0 )); then
    GITHUB_AUTH_GIT_REASON="$(github_auth_classify_git_error "$output" "$status")"
    GITHUB_AUTH_REASON="$GITHUB_AUTH_GIT_REASON"
    return 1
  fi
  GITHUB_AUTH_GIT_REASON=''
  return 0
}
