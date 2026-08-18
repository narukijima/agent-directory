#!/usr/bin/env bash

# Shared GitHub authentication resolver for agent-directory Tools.
# Credential values are kept in shell variables and are passed only to the exact
# GitHub child process that needs them. Never source the machine credential file.
set +x

GITHUB_AUTH_IMPLEMENTATION_VERSION=4
GITHUB_AUTH_SOURCE='none'
GITHUB_AUTH_REASON=''
GITHUB_AUTH_LOGIN=''
GITHUB_AUTH_MACHINE_FILE=''
GITHUB_AUTH_GIT_REASON=''
GITHUB_AUTH_TOKEN=''
GITHUB_AUTH_RESOURCE_OWNER=''
GITHUB_AUTH_REPOSITORIES=''
GITHUB_AUTH_OPERATIONS=''
GITHUB_AUTH_PARSED_VALUE=''
GITHUB_AUTH_MACHINE_FILE_PRESENT='no'
GITHUB_AUTH_MACHINE_FILE_VALID='no'
GITHUB_AUTH_REPOSITORY_ENROLLED='no'
GITHUB_AUTH_OPERATION_ENROLLED='no'
GITHUB_AUTH_REMOTE_RESOLVED='no'
GITHUB_AUTH_NETWORK_ATTEMPTED='no'
GITHUB_AUTH_API_ATTEMPTED='no'
GITHUB_AUTH_GIT_ATTEMPTED='no'
GITHUB_AUTH_LAST_STATUS='0'
GITHUB_AUTH_OPERATION='unknown'
GITHUB_AUTH_REPOSITORY='unknown'

github_auth_current_uid() { id -u; }

github_auth_account_home() {
  local account_home=''
  if [[ "${AGENT_DIRECTORY_GITHUB_TESTING:-false}" == true &&
    -n "${AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE:-}" ]]; then
    account_home="$AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE"
  elif command -v python3 >/dev/null 2>&1; then
    account_home="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)"
  elif command -v getent >/dev/null 2>&1; then
    account_home="$(getent passwd "$(github_auth_current_uid)" 2>/dev/null | awk -F: 'NR == 1 { print $6 }')"
  fi
  [[ -n "$account_home" && "$account_home" == /* ]] || {
    GITHUB_AUTH_REASON='auth-home-unavailable'
    return 1
  }
  printf '%s' "$account_home"
}

github_auth_machine_file() {
  local account_home
  account_home="$(github_auth_account_home)" || return 1
  printf '%s/.config/agent-directory/github.env' "$account_home"
}

github_auth_stat_field() {
  local target="$1" bsd_format="$2" gnu_format="$3" value=''
  value="$(stat -f "$bsd_format" "$target" 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(stat -c "$gnu_format" "$target" 2>/dev/null || true)"
  printf '%s' "$value"
}

github_auth_stat_mode() { github_auth_stat_field "$1" '%Lp' '%a'; }
github_auth_stat_uid() { github_auth_stat_field "$1" '%u' '%u'; }
github_auth_stat_links() { github_auth_stat_field "$1" '%l' '%h'; }
github_auth_stat_identity() { github_auth_stat_field "$1" '%d:%i' '%d:%i'; }

github_auth_value_valid() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*|*[[:space:]]*) return 1 ;;
  esac
}

github_auth_machine_pat_valid() {
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

github_auth_csv_valid() {
  local csv="$1" kind="$2" item old_ifs="$IFS"
  [[ -n "$csv" ]] || return 1
  IFS=','
  for item in $csv; do
    [[ -n "$item" ]] || { IFS="$old_ifs"; return 1; }
    case "$kind" in
      repository) github_auth_repository_valid "$item" || { IFS="$old_ifs"; return 1; } ;;
      operation) github_auth_operation_valid "$item" || { IFS="$old_ifs"; return 1; } ;;
      *) IFS="$old_ifs"; return 1 ;;
    esac
  done
  IFS="$old_ifs"
}

github_auth_repositories_match_owner() {
  local csv="$1" owner="$2" item old_ifs="$IFS" normalized_owner normalized_item_owner
  normalized_owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
  IFS=','
  for item in $csv; do
    normalized_item_owner="$(printf '%s' "${item%%/*}" | tr '[:upper:]' '[:lower:]')"
    [[ "$normalized_item_owner" == "$normalized_owner" ]] || { IFS="$old_ifs"; return 1; }
  done
  IFS="$old_ifs"
}

github_auth_machine_permissions() {
  local file="$1" dir config_dir account_home mode uid links current_uid
  account_home="$(github_auth_account_home)" || return 1
  config_dir="$account_home/.config"
  dir="$(dirname "$file")"
  current_uid="$(github_auth_current_uid)"
  [[ -d "$account_home" && ! -L "$account_home" ]] || { GITHUB_AUTH_REASON='auth-store-path'; return 1; }
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || { GITHUB_AUTH_REASON='auth-store-missing'; return 1; }
  [[ -d "$dir" && ! -L "$dir" ]] || { GITHUB_AUTH_REASON='auth-store-missing'; return 1; }
  [[ -f "$file" && ! -L "$file" ]] || { GITHUB_AUTH_REASON='auth-store-missing'; return 1; }
  uid="$(github_auth_stat_uid "$dir")"
  [[ "$uid" == "$current_uid" ]] || { GITHUB_AUTH_REASON='auth-store-owner'; return 1; }
  uid="$(github_auth_stat_uid "$file")"
  [[ "$uid" == "$current_uid" ]] || { GITHUB_AUTH_REASON='auth-store-owner'; return 1; }
  mode="$(github_auth_stat_mode "$dir")"
  [[ "$mode" == 700 ]] || { GITHUB_AUTH_REASON='auth-store-permissions'; return 1; }
  mode="$(github_auth_stat_mode "$file")"
  [[ "$mode" == 600 ]] || { GITHUB_AUTH_REASON='auth-store-permissions'; return 1; }
  links="$(github_auth_stat_links "$file")"
  [[ "$links" == 1 ]] || { GITHUB_AUTH_REASON='auth-store-hardlink'; return 1; }
}

# Strict v1 format. Any blank, comment, duplicate, unknown, or reordered line is rejected.
github_auth_read_machine_file() {
  local file="$1" identity_before identity_after line line_number=0
  local format='' owner='' repositories='' operations='' token=''
  GITHUB_AUTH_TOKEN=''
  GITHUB_AUTH_RESOURCE_OWNER=''
  GITHUB_AUTH_REPOSITORIES=''
  GITHUB_AUTH_OPERATIONS=''
  github_auth_machine_permissions "$file" || return 1
  identity_before="$(github_auth_stat_identity "$file")"
  [[ -n "$identity_before" ]] || { GITHUB_AUTH_REASON='auth-store-race'; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    case "$line_number:$line" in
      '1:AGENT_DIRECTORY_GITHUB_CREDENTIAL_V1') format=1 ;;
      2:resource_owner=*) owner="${line#resource_owner=}" ;;
      3:repositories=*) repositories="${line#repositories=}" ;;
      4:operations=*) operations="${line#operations=}" ;;
      5:GH_TOKEN=*) token="${line#GH_TOKEN=}" ;;
      *) GITHUB_AUTH_REASON='machine-credential-invalid'; return 1 ;;
    esac
  done < "$file"
  identity_after="$(github_auth_stat_identity "$file")"
  [[ "$identity_before" == "$identity_after" ]] || { GITHUB_AUTH_REASON='auth-store-race'; return 1; }
  [[ "$line_number" == 5 && "$format" == 1 ]] || { GITHUB_AUTH_REASON='machine-credential-invalid'; return 1; }
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { GITHUB_AUTH_REASON='machine-credential-invalid'; return 1; }
  github_auth_csv_valid "$repositories" repository || { GITHUB_AUTH_REASON='machine-credential-invalid'; return 1; }
  github_auth_csv_valid "$operations" operation || { GITHUB_AUTH_REASON='machine-credential-invalid'; return 1; }
  github_auth_machine_pat_valid "$token" || { GITHUB_AUTH_REASON='machine-token-not-fine-grained'; return 1; }
  github_auth_repositories_match_owner "$repositories" "$owner" || {
    GITHUB_AUTH_REASON='machine-credential-invalid'; return 1;
  }
  GITHUB_AUTH_RESOURCE_OWNER="$owner"
  GITHUB_AUTH_REPOSITORIES="$repositories"
  GITHUB_AUTH_OPERATIONS="$operations"
  GITHUB_AUTH_TOKEN="$token"
  GITHUB_AUTH_REASON=''
}

github_auth_list_has() {
  local csv="$1" expected="$2" item old_ifs="$IFS" normalized_item normalized_expected
  normalized_expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  IFS=','
  for item in $csv; do
    normalized_item="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
    if [[ "$normalized_item" == "$normalized_expected" ]]; then
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

github_auth_require_capability() {
  local repository="$1" operation="$2"
  GITHUB_AUTH_REPOSITORY_ENROLLED='no'
  GITHUB_AUTH_OPERATION_ENROLLED='no'
  github_auth_repository_valid "$repository" || { GITHUB_AUTH_REASON='github-destination-invalid'; return 1; }
  github_auth_operation_valid "$operation" || { GITHUB_AUTH_REASON='github-operation-invalid'; return 1; }
  github_auth_list_has "$GITHUB_AUTH_REPOSITORIES" "$repository" || {
    GITHUB_AUTH_REASON='github-repository-not-enrolled'; return 1;
  }
  GITHUB_AUTH_REPOSITORY_ENROLLED='yes'
  github_auth_list_has "$GITHUB_AUTH_OPERATIONS" "$operation" || {
    GITHUB_AUTH_REASON='github-operation-not-enrolled'; return 1;
  }
  GITHUB_AUTH_OPERATION_ENROLLED='yes'
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

github_auth_ci_resolve() {
  local repository="$1" operation="$2" token=''
  [[ "${CI:-false}" == true && "${AGENT_DIRECTORY_GITHUB_CI:-false}" == true ]] || {
    GITHUB_AUTH_REASON='machine-credential-not-installed'; return 1;
  }
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  github_auth_value_valid "$token" || { GITHUB_AUTH_REASON='github-authentication-failed'; return 1; }
  [[ -n "${GITHUB_REPOSITORY:-}" && "$repository" == "$GITHUB_REPOSITORY" ]] || {
    GITHUB_AUTH_REASON='github-repository-not-enrolled'; return 1;
  }
  github_auth_list_has "${AGENT_DIRECTORY_GITHUB_CI_OPERATIONS:-metadata-read,git-read}" "$operation" || {
    GITHUB_AUTH_REASON='github-operation-not-enrolled'; return 1;
  }
  GITHUB_AUTH_TOKEN="$token"
  unset GH_TOKEN GITHUB_TOKEN
  GITHUB_AUTH_SOURCE='ci-process-token'
  GITHUB_AUTH_REPOSITORY_ENROLLED='yes'
  GITHUB_AUTH_OPERATION_ENROLLED='yes'
  GITHUB_AUTH_REASON=''
}

# Local resolution is machine-only. Process credentials are accepted solely in an
# explicitly declared CI context with an exact repository and operation allowlist.
github_auth_resolve() {
  local workspace_root="${1:-}" repository="${2:-}" operation="${3:-metadata-read}" machine_file
  GITHUB_AUTH_SOURCE='none'
  GITHUB_AUTH_REASON=''
  GITHUB_AUTH_TOKEN=''
  GITHUB_AUTH_OPERATION="$operation"
  GITHUB_AUTH_REPOSITORY="$repository"
  GITHUB_AUTH_MACHINE_FILE_PRESENT='no'
  GITHUB_AUTH_MACHINE_FILE_VALID='no'
  GITHUB_AUTH_REPOSITORY_ENROLLED='no'
  GITHUB_AUTH_OPERATION_ENROLLED='no'
  export GH_HOST='github.com'
  export GH_PROMPT_DISABLED=1
  export GH_NO_UPDATE_NOTIFIER=1
  machine_file="$(github_auth_machine_file)" || return 1
  GITHUB_AUTH_MACHINE_FILE="$machine_file"
  if [[ -e "$machine_file" || -L "$machine_file" ]]; then
    GITHUB_AUTH_MACHINE_FILE_PRESENT='yes'
    github_auth_read_machine_file "$machine_file" || return 1
    GITHUB_AUTH_MACHINE_FILE_VALID='yes'
    github_auth_require_capability "$repository" "$operation" || return 1
    GITHUB_AUTH_SOURCE='machine-file'
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
    runtime-denied|executable-missing|credential-helper-missing|github-dns-failure|github-network-failure|github-timeout|auth-home-unavailable) printf 'runtime' ;;
    auth-store-*|machine-*|github-repository-not-enrolled|github-operation-not-enrolled|github-operation-invalid|github-destination-invalid|github-remote-invalid) printf 'agent-directory-local-policy' ;;
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
  printf 'GITHUB_AUTH_DIAGNOSTIC layer=%s operation=%s repository=%s remote=%s transport=%s credential_source=%s machine_file_present=%s machine_file_valid=%s process_token=%s repository_enrolled=%s operation_enrolled=%s network_attempted=%s api_attempted=%s git_attempted=%s request_reached=%s reason=%s exit_status=%s evidence=%s\n' \
    "$(github_auth_reason_layer "$reason")" "$operation" "$repository" "$remote_name" "$transport" \
    "$GITHUB_AUTH_SOURCE" "$GITHUB_AUTH_MACHINE_FILE_PRESENT" "$GITHUB_AUTH_MACHINE_FILE_VALID" \
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
