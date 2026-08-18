#!/usr/bin/env bash

# Shared GitHub authentication resolver for agent-directory Tools.
# Each Agent Workspace owns its credential in <workspace-root>/.env. The file is
# parsed without sourcing, and the token is passed only to the exact GitHub child.
set +x

github_auth_lib_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$github_auth_lib_root/agent-env.sh"
. "$github_auth_lib_root/project-registry.sh"

GITHUB_AUTH_IMPLEMENTATION_VERSION=6
GITHUB_AUTH_SOURCE='none'
GITHUB_AUTH_REASON=''
GITHUB_AUTH_LOGIN=''
GITHUB_AUTH_CREDENTIAL_FILE=''
GITHUB_AUTH_CREDENTIAL_ROOT=''
GITHUB_AUTH_CREDENTIAL_OWNER='workspace-root'
GITHUB_AUTH_GIT_REASON=''
GITHUB_AUTH_TOKEN=''
GITHUB_AUTH_PARSED_VALUE=''
GITHUB_AUTH_CREDENTIAL_FILE_PRESENT='no'
GITHUB_AUTH_CREDENTIAL_FILE_VALID='no'
GITHUB_AUTH_REPOSITORY_ENROLLED='no'
GITHUB_AUTH_OPERATION_ENROLLED='no'
GITHUB_AUTH_REMOTE_RESOLVED='no'
GITHUB_AUTH_NETWORK_ATTEMPTED='no'
GITHUB_AUTH_API_ATTEMPTED='no'
GITHUB_AUTH_GIT_ATTEMPTED='no'
GITHUB_AUTH_LAST_STATUS='0'
GITHUB_AUTH_OPERATION='unknown'
GITHUB_AUTH_REPOSITORY='unknown'

github_auth_workspace_file() {
  agent_env_file "$1" || { GITHUB_AUTH_REASON="$AGENT_ENV_REASON"; return 1; }
}

github_auth_value_valid() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*|*[[:space:]]*) return 1 ;;
  esac
}

github_auth_pat_valid() {
  local value="$1"
  github_auth_value_valid "$value" || return 1
  [[ "$value" =~ ^github_pat_[A-Za-z0-9_]{20,}$ ]]
}

github_auth_repository_valid() {
  local repository="$1"
  [[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
  [[ "$repository" != *'..'* && "$repository" != *'//'* ]]
}

github_auth_operation_valid() {
  case "$1" in
    metadata-read|git-read|git-push|issues-read|issues-write|pull-requests-read|pull-requests-write) return 0 ;;
    *) return 1 ;;
  esac
}

# Read only GH_TOKEN through the shared Agent-scoped dotenv parser.
github_auth_read_workspace_file() {
  local workspace_root="$1"
  GITHUB_AUTH_TOKEN=''
  agent_env_get "$workspace_root" GH_TOKEN || {
    GITHUB_AUTH_REASON="$AGENT_ENV_REASON"; return 1;
  }
  github_auth_pat_valid "$AGENT_ENV_VALUE" || {
    GITHUB_AUTH_REASON='workspace-token-not-fine-grained'; return 1;
  }
  GITHUB_AUTH_TOKEN="$AGENT_ENV_VALUE"
  AGENT_ENV_VALUE=''
  GITHUB_AUTH_REASON=''
}

github_auth_repository_from_url() {
  local url="$1" path
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  [[ "$path" != *'?'* && "$path" != *'#'* && "$path" != *'@'* ]] || return 1
  path="${path%.git}"
  github_auth_repository_valid "$path" || return 1
  printf '%s' "$path"
}

github_auth_registry_repository_from_url() {
  local url="$1" path
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    ssh://github.com/*) path="${url#ssh://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  github_auth_repository_valid "$path" || return 1
  printf '%s' "$path"
}

# A registered Independent Project keeps its own Git root but belongs to the
# enclosing Agent Workspace. Resolve only that exact <agent-root>/projects/<name>
# attachment; never scan arbitrary parents, siblings, OS stores, or another Agent.
github_auth_registered_agent_root() {
  local workspace_root="$1" repository="$2"
  local canonical_workspace projects_root owner_root workspace_top owner_top
  local project_name registry record_kind entry_name entry_url entry_reason
  local entry_revision entry_role registered_repository matches=0

  canonical_workspace="$(cd "$workspace_root" 2>/dev/null && pwd -P)" || return 1
  project_name="${canonical_workspace##*/}"
  projects_root="${canonical_workspace%/*}"
  [[ "${projects_root##*/}" == 'projects' ]] || return 1
  owner_root="${projects_root%/*}"
  [[ -d "$owner_root" && ! -L "$owner_root" ]] || return 1
  workspace_top="$(git -C "$canonical_workspace" rev-parse --show-toplevel 2>/dev/null || true)"
  owner_top="$(git -C "$owner_root" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ "$workspace_top" == "$canonical_workspace" && "$owner_top" == "$owner_root" ]] || return 1
  [[ "$(cd "$owner_root/projects/$project_name" 2>/dev/null && pwd -P)" == "$canonical_workspace" ]] || return 1
  registry="$owner_root/projects/REPOSITORIES.md"
  [[ -f "$registry" && ! -L "$registry" ]] || return 1

  while IFS=$'\t' read -r record_kind entry_name entry_url entry_reason entry_revision entry_role; do
    [[ "$record_kind" == 'R' ]] || return 1
    [[ "$entry_name" == "$project_name" ]] || continue
    registered_repository="$(github_auth_registry_repository_from_url "$entry_url" 2>/dev/null || true)"
    [[ "$registered_repository" == "$repository" ]] || continue
    matches=$((matches + 1))
  done < <(agent_registry_records "$registry")
  (( matches == 1 )) || return 1
  printf '%s' "$owner_root"
}

github_auth_select_credential_root() {
  local workspace_root="$1" repository="$2" registered_root=''
  GITHUB_AUTH_CREDENTIAL_ROOT="$workspace_root"
  GITHUB_AUTH_CREDENTIAL_OWNER='workspace-root'
  registered_root="$(github_auth_registered_agent_root "$workspace_root" "$repository" 2>/dev/null || true)"
  if [[ -n "$registered_root" ]]; then
    GITHUB_AUTH_CREDENTIAL_ROOT="$registered_root"
    GITHUB_AUTH_CREDENTIAL_OWNER='registered-agent-root'
  fi
}

github_auth_ci_resolve() {
  local repository="$1" operation="$2" token=''
  [[ "${CI:-false}" == true && "${AGENT_DIRECTORY_GITHUB_CI:-false}" == true ]] || {
    GITHUB_AUTH_REASON='agent-env-missing'; return 1;
  }
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  github_auth_value_valid "$token" || {
    GITHUB_AUTH_REASON='github-authentication-failed'; return 1;
  }
  [[ -n "${GITHUB_REPOSITORY:-}" && "$repository" == "$GITHUB_REPOSITORY" ]] || {
    GITHUB_AUTH_REASON='github-repository-not-enrolled'; return 1;
  }
  case ",${AGENT_DIRECTORY_GITHUB_CI_OPERATIONS:-metadata-read,git-read}," in
    *,"$operation",*) ;;
    *) GITHUB_AUTH_REASON='github-operation-not-enrolled'; return 1 ;;
  esac
  GITHUB_AUTH_TOKEN="$token"
  unset GH_TOKEN GITHUB_TOKEN
  GITHUB_AUTH_SOURCE='ci-process-token'
  GITHUB_AUTH_REPOSITORY_ENROLLED='yes'
  GITHUB_AUTH_OPERATION_ENROLLED='yes'
  GITHUB_AUTH_REASON=''
}

# Normal local resolution is Agent Workspace-only. Ambient process credentials and
# credentials owned by sibling Workspaces or the OS account are never consumed.
github_auth_resolve() {
  local workspace_root="${1:-}" repository="${2:-}" operation="${3:-metadata-read}" credential_file
  GITHUB_AUTH_SOURCE='none'
  GITHUB_AUTH_REASON=''
  GITHUB_AUTH_TOKEN=''
  GITHUB_AUTH_OPERATION="$operation"
  GITHUB_AUTH_REPOSITORY="$repository"
  GITHUB_AUTH_CREDENTIAL_ROOT="$workspace_root"
  GITHUB_AUTH_CREDENTIAL_OWNER='workspace-root'
  GITHUB_AUTH_CREDENTIAL_FILE_PRESENT='no'
  GITHUB_AUTH_CREDENTIAL_FILE_VALID='no'
  GITHUB_AUTH_REPOSITORY_ENROLLED='no'
  GITHUB_AUTH_OPERATION_ENROLLED='no'
  export GH_HOST='github.com'
  export GH_PROMPT_DISABLED=1
  export GH_NO_UPDATE_NOTIFIER=1
  github_auth_repository_valid "$repository" || {
    GITHUB_AUTH_REASON='github-destination-invalid'; return 1;
  }
  github_auth_operation_valid "$operation" || {
    GITHUB_AUTH_REASON='github-operation-invalid'; return 1;
  }
  github_auth_select_credential_root "$workspace_root" "$repository"
  credential_file="$(github_auth_workspace_file "$GITHUB_AUTH_CREDENTIAL_ROOT")" || return 1
  GITHUB_AUTH_CREDENTIAL_FILE="$credential_file"
  if [[ -e "$credential_file" || -L "$credential_file" ]]; then
    GITHUB_AUTH_CREDENTIAL_FILE_PRESENT='yes'
    github_auth_read_workspace_file "$GITHUB_AUTH_CREDENTIAL_ROOT" || return 1
    GITHUB_AUTH_CREDENTIAL_FILE_VALID='yes'
    GITHUB_AUTH_SOURCE='workspace-env'
    GITHUB_AUTH_REPOSITORY_ENROLLED='yes'
    GITHUB_AUTH_OPERATION_ENROLLED='yes'
    return 0
  fi
  github_auth_ci_resolve "$repository" "$operation"
}

github_auth_classify_api_error() {
  local output="$1"
  case "$output" in
    *'HTTP 401'*|*'Bad credentials'*|*'authentication token'*|*'gh auth login'*|*'not logged in'*) printf 'github-authentication-failed' ;;
    *'HTTP 403'*|*'Resource not accessible'*) printf 'github-authorization-failed' ;;
    *'Could not resolve host'*|*'could not resolve host'*|*'Could not resolve'*|*'could not resolve'*) printf 'github-dns-failure' ;;
    *'timed out'*|*'Timed out'*|*'timeout'*|*'Timeout'*) printf 'github-timeout' ;;
    *'Failed to connect'*|*'failed to connect'*|*'error connecting to'*|*'Error connecting to'*|*'Connection refused'*|*'connection refused'*|*'network is unreachable'*|*'Network is unreachable'*) printf 'github-network-failure' ;;
    *'Operation not permitted'*|*'operation not permitted'*|*'Permission denied'*|*'permission denied'*|*'sandbox'*|*'Sandbox'*) printf 'runtime-denied' ;;
    *'command not found'*|*'No such file or directory'*) printf 'executable-missing' ;;
    *) printf 'github-unknown-failure' ;;
  esac
}

github_auth_reason_layer() {
  case "$1" in
    runtime-denied|executable-missing|credential-helper-missing|github-dns-failure|github-network-failure|github-timeout) printf 'runtime' ;;
    agent-env-*|workspace-token-not-fine-grained|credential-owned-by-agent-root|github-repository-not-enrolled|github-operation-not-enrolled|github-operation-invalid|github-destination-invalid|github-remote-invalid) printf 'agent-directory-local-policy' ;;
    github-authentication-failed|github-authorization-failed|git-transport-mismatch) printf 'external-provider' ;;
    *) printf 'unclassified' ;;
  esac
}

github_auth_evidence_category() {
  case "$1" in
    github-authentication-failed) printf 'http-authentication-response' ;;
    github-authorization-failed) printf 'http-authorization-response' ;;
    github-dns-failure) printf 'dns-resolution-error' ;;
    github-network-failure) printf 'network-connection-error' ;;
    github-timeout) printf 'timeout-error' ;;
    runtime-denied) printf 'runtime-denial' ;;
    executable-missing|credential-helper-missing) printf 'missing-executable' ;;
    git-transport-mismatch) printf 'transport-error' ;;
    github-unknown-failure) printf 'unclassified-redacted-output' ;;
    *) printf 'local-policy-check' ;;
  esac
}

github_auth_request_reached() {
  case "$1" in
    github-authentication-failed|github-authorization-failed) printf 'yes' ;;
    github-dns-failure|github-network-failure|runtime-denied|executable-missing|credential-helper-missing) printf 'no' ;;
    *) printf 'unknown' ;;
  esac
}

github_auth_process_token_state() {
  if [[ "$GITHUB_AUTH_SOURCE" == 'ci-process-token' ]]; then
    printf 'selected-for-explicit-ci'
  elif [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    printf 'present-not-consumed'
  else
    printf 'absent'
  fi
}

# Emit only categorical evidence. Credential values, command output, URLs, and headers
# never enter the diagnostic line.
github_auth_diagnostic() {
  local operation="${1:-unknown}" repository="${2:-unknown}" remote_name="${3:-none}"
  local transport="${4:-unknown}" status="${5:-$GITHUB_AUTH_LAST_STATUS}"
  local reason="${GITHUB_AUTH_REASON:-github-unknown-failure}"
  printf 'GITHUB_AUTH_DIAGNOSTIC layer=%s operation=%s repository=%s remote=%s transport=%s credential_source=%s credential_owner=%s credential_file_present=%s credential_file_valid=%s workspace_scoped=yes process_token=%s repository_enrolled=%s operation_enrolled=%s network_attempted=%s api_attempted=%s git_attempted=%s request_reached=%s reason=%s exit_status=%s evidence=%s\n' \
    "$(github_auth_reason_layer "$reason")" "$operation" "$repository" "$remote_name" "$transport" \
    "$GITHUB_AUTH_SOURCE" "$GITHUB_AUTH_CREDENTIAL_OWNER" "$GITHUB_AUTH_CREDENTIAL_FILE_PRESENT" "$GITHUB_AUTH_CREDENTIAL_FILE_VALID" \
    "$(github_auth_process_token_state)" "$GITHUB_AUTH_REPOSITORY_ENROLLED" "$GITHUB_AUTH_OPERATION_ENROLLED" \
    "$GITHUB_AUTH_NETWORK_ATTEMPTED" "$GITHUB_AUTH_API_ATTEMPTED" "$GITHUB_AUTH_GIT_ATTEMPTED" \
    "$(github_auth_request_reached "$reason")" "$reason" "$status" "$(github_auth_evidence_category "$reason")"
}

github_auth_gh_run() {
  local workspace_root="$1" repository="$2" operation="$3"
  shift 3
  github_auth_resolve "$workspace_root" "$repository" "$operation" || return 90
  command -v gh >/dev/null 2>&1 || return 91
  GH_TOKEN="$GITHUB_AUTH_TOKEN" GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    command gh "$@"
}

github_auth_probe_api() {
  local expected_login="${1:-}" workspace_root="$2" repository="$3" output login status
  GITHUB_AUTH_LOGIN=''
  GITHUB_AUTH_API_ATTEMPTED='no'
  github_auth_resolve "$workspace_root" "$repository" metadata-read || return 1
  command -v gh >/dev/null 2>&1 || { GITHUB_AUTH_REASON='executable-missing'; GITHUB_AUTH_LAST_STATUS=91; return 1; }
  GITHUB_AUTH_NETWORK_ATTEMPTED='yes'
  GITHUB_AUTH_API_ATTEMPTED='yes'
  set +e
  output="$(GH_TOKEN="$GITHUB_AUTH_TOKEN" GH_HOST=github.com GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1 command gh api user --jq .login 2>&1)"
  status=$?
  set -e
  if (( status != 0 )); then
    GITHUB_AUTH_LAST_STATUS="$status"
    GITHUB_AUTH_REASON="$(github_auth_classify_api_error "$output")"
    return 1
  fi
  login="$(printf '%s\n' "$output" | tail -n 1 | tr -d '\r')"
  [[ -n "$login" && "$login" != *[[:space:]]* ]] || { GITHUB_AUTH_REASON='github-authentication-failed'; return 1; }
  GITHUB_AUTH_LOGIN="$login"
  if [[ -n "$expected_login" && "$login" != "$expected_login" ]]; then
    GITHUB_AUTH_REASON='account-mismatch'
    return 1
  fi
  GITHUB_AUTH_REASON=''
  GITHUB_AUTH_LAST_STATUS='0'
}

github_auth_remote_kind() {
  case "$1" in
    https://github.com/*) github_auth_repository_from_url "$1" >/dev/null 2>&1 && printf 'github-https' || printf 'invalid-github-url' ;;
    git@github.com:*|ssh://git@github.com/*|ssh://github.com/*) printf 'github-ssh' ;;
    *) printf 'other' ;;
  esac
}

# The token reaches only this Git process and gh's fixed credential helper. Repository
# hooks, ambient helpers/config, cross-host redirects, and non-HTTPS protocols are disabled.
github_git_run() {
  local workspace_root="$1" remote_url="$2" operation="$3" repository
  shift 3
  case "$(github_auth_remote_kind "$remote_url")" in
    github-https)
      repository="$(github_auth_repository_from_url "$remote_url")" || return 92
      github_auth_resolve "$workspace_root" "$repository" "$operation" || return 90
      command -v gh >/dev/null 2>&1 || return 91
      GH_TOKEN="$GITHUB_AUTH_TOKEN" GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -c core.hooksPath=/dev/null -c credential.helper= \
        -c credential.https://github.com.helper= \
        -c credential.https://github.com.helper='!gh auth git-credential' \
        -c http.followRedirects=false -c protocol.allow=never -c protocol.https.allow=always "$@"
      ;;
    invalid-github-url) GITHUB_AUTH_REASON='github-remote-invalid'; return 92 ;;
    *) GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git -c core.hooksPath=/dev/null "$@" ;;
  esac
}

github_auth_classify_git_error() {
  local output="$1" status="${2:-1}"
  case "$status" in
    90) printf '%s' "${GITHUB_AUTH_REASON:-github-authentication-failed}"; return ;;
    91) printf 'credential-helper-missing'; return ;;
    92) printf 'github-remote-invalid'; return ;;
  esac
  case "$output" in
    *'could not read Username'*|*'Authentication failed'*|*'HTTP 401'*|*'Bad credentials'*) printf 'github-authentication-failed' ;;
    *'HTTP 403'*|*'Write access to repository not granted'*|*'Resource not accessible'*) printf 'github-authorization-failed' ;;
    *'Permission denied (publickey)'*|*'unsupported protocol'*|*'transport'*'not allowed'*) printf 'git-transport-mismatch' ;;
    *'Permission denied'*|*'permission denied'*|*'Operation not permitted'*|*'operation not permitted'*|*'sandbox'*|*'Sandbox'*) printf 'runtime-denied' ;;
    *'gh: command not found'*|*'auth git-credential'*'not found'*) printf 'credential-helper-missing' ;;
    *'Could not resolve host'*|*'could not resolve host'*) printf 'github-dns-failure' ;;
    *'Connection timed out'*|*'connection timed out'*|*'timed out'*|*'Timed out'*) printf 'github-timeout' ;;
    *'Failed to connect'*|*'failed to connect'*|*'Connection refused'*|*'connection refused'*) printf 'github-network-failure' ;;
    *) printf 'github-unknown-failure' ;;
  esac
}

github_auth_probe_git() {
  local workspace_root="$1" remote_url="$2" output status repository=''
  GITHUB_AUTH_GIT_ATTEMPTED='no'
  if [[ "$(github_auth_remote_kind "$remote_url")" == github-https ]]; then
    repository="$(github_auth_repository_from_url "$remote_url")" || {
      GITHUB_AUTH_REASON='github-remote-invalid'; return 1;
    }
    github_auth_resolve "$workspace_root" "$repository" git-read || return 1
  fi
  GITHUB_AUTH_NETWORK_ATTEMPTED='yes'
  GITHUB_AUTH_GIT_ATTEMPTED='yes'
  set +e
  output="$(github_git_run "$workspace_root" "$remote_url" git-read -C "$workspace_root" \
    ls-remote --heads "$remote_url" 2>&1)"
  status=$?
  set -e
  if (( status != 0 )); then
    GITHUB_AUTH_LAST_STATUS="$status"
    GITHUB_AUTH_GIT_REASON="$(github_auth_classify_git_error "$output" "$status")"
    GITHUB_AUTH_REASON="$GITHUB_AUTH_GIT_REASON"
    return 1
  fi
  GITHUB_AUTH_GIT_REASON=''
  GITHUB_AUTH_LAST_STATUS='0'
}
