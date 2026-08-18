#!/usr/bin/env bash
set -euo pipefail
set +x

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${AGENT_DIRECTORY_ROOT:-$tool_root/..}" 2>/dev/null && pwd -P)" || repo_root=''
. "$tool_root/lib/github-auth.sh"

mode=''
expected_login=''
remote_name=''
remote_explicit=false
repositories=()
operations=()
machine_file=''
lock_dir=''
temp_file=''
remote_url=''
install_resource_owner=''
install_repositories=''
install_operations=''
diagnostic_repository='unknown'
diagnostic_operation='git-read'

usage() {
  printf 'Usage: %s (--install-token|--install-from-gh|--enroll-existing|--machine-ready|--check) [--expected-login <login>] [--remote <name>] [--repository <owner/repo>]... [--operation <operation>]...\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  local diagnostic_status
  GITHUB_AUTH_REASON="$1"
  diagnostic_status="${GITHUB_AUTH_LAST_STATUS:-1}"
  [[ "$diagnostic_status" != 0 ]] || diagnostic_status=1
  if [[ "$mode" == enroll-existing || "$mode" == machine-ready || "$mode" == check ]]; then
    github_auth_diagnostic "$diagnostic_operation" "$diagnostic_repository" \
      "${remote_name:-none}" "$(github_auth_remote_kind "${remote_url:-}")" "$diagnostic_status" >&2
  fi
  printf 'GITHUB_AUTH_BLOCKED reason=%s\n' "$GITHUB_AUTH_REASON" >&2
  exit 1
}

cleanup() {
  [[ -z "$temp_file" ]] || rm -f -- "$temp_file"
  [[ -z "$lock_dir" ]] || rmdir -- "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-token|--install-from-gh|--enroll-existing|--machine-ready|--check)
      [[ -z "$mode" ]] || usage
      mode="${1#--}"
      shift
      ;;
    --expected-login) [[ $# -ge 2 ]] || usage; expected_login="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote_name="$2"; remote_explicit=true; shift 2 ;;
    --repository) [[ $# -ge 2 ]] || usage; repositories+=("$2"); shift 2 ;;
    --operation) [[ $# -ge 2 ]] || usage; operations+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$mode" ]] || usage
[[ -z "$expected_login" || "$expected_login" =~ ^[A-Za-z0-9-]+$ ]] || blocked account-mismatch
[[ -n "$repo_root" ]] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || blocked not-git-repository
machine_file="$(github_auth_machine_file)" || blocked "${GITHUB_AUTH_REASON:-auth-home-unavailable}"

resolve_remote() {
  local configured_push_default='' remote_candidate
  if [[ "$remote_explicit" != true ]]; then
    configured_push_default="$(git -C "$repo_root" config --local remote.pushDefault 2>/dev/null || true)"
    for remote_candidate in "$configured_push_default" backup origin; do
      [[ -n "$remote_candidate" ]] || continue
      if git -C "$repo_root" remote get-url "$remote_candidate" >/dev/null 2>&1; then
        remote_name="$remote_candidate"
        break
      fi
    done
  fi
  [[ -n "$remote_name" ]] || blocked remote-not-configured
  remote_url="$(git -C "$repo_root" remote get-url "$remote_name" 2>/dev/null || true)"
  [[ -n "$remote_url" ]] || blocked remote-not-configured
  GITHUB_AUTH_REMOTE_RESOLVED='yes'
}

prepare_install_policy() {
  local repository resource_owner='' item joined_repositories='' joined_operations=''
  local normalized_owner normalized_item_owner
  local requested_operations=()
  if (( ${#operations[@]} > 0 )); then
    requested_operations=("${operations[@]}")
  fi
  resolve_remote
  if (( ${#repositories[@]} == 0 )); then
    repository="$(github_auth_repository_from_url "$remote_url")" || blocked github-remote-invalid
    repositories+=("$repository")
  fi
  operations=(metadata-read git-read git-push)
  if (( ${#requested_operations[@]} > 0 )); then
    operations+=("${requested_operations[@]}")
  fi
  for item in "${repositories[@]}"; do
    github_auth_repository_valid "$item" || blocked github-destination-invalid
    if [[ -z "$resource_owner" ]]; then
      resource_owner="${item%%/*}"
    else
      normalized_owner="$(printf '%s' "$resource_owner" | tr '[:upper:]' '[:lower:]')"
      normalized_item_owner="$(printf '%s' "${item%%/*}" | tr '[:upper:]' '[:lower:]')"
      [[ "$normalized_owner" == "$normalized_item_owner" ]] || blocked multiple-resource-owners
    fi
    github_auth_list_has "$joined_repositories" "$item" 2>/dev/null || \
      joined_repositories="${joined_repositories:+$joined_repositories,}$item"
  done
  for item in "${operations[@]}"; do
    github_auth_operation_valid "$item" || blocked github-operation-invalid
    github_auth_list_has "$joined_operations" "$item" 2>/dev/null || \
      joined_operations="${joined_operations:+$joined_operations,}$item"
  done
  install_resource_owner="$resource_owner"
  install_repositories="$joined_repositories"
  install_operations="$joined_operations"
}

prepare_store_directory() {
  local account_home config_dir auth_dir current_uid
  account_home="$(github_auth_account_home)" || blocked "${GITHUB_AUTH_REASON:-auth-home-unavailable}"
  config_dir="$account_home/.config"
  auth_dir="$(dirname "$machine_file")"
  current_uid="$(github_auth_current_uid)"
  [[ -d "$account_home" && ! -L "$account_home" &&
    "$(github_auth_stat_uid "$account_home")" == "$current_uid" ]] || blocked auth-store-path
  if [[ -e "$config_dir" || -L "$config_dir" ]]; then
    [[ -d "$config_dir" && ! -L "$config_dir" &&
      "$(github_auth_stat_uid "$config_dir")" == "$current_uid" ]] || blocked auth-store-path
  else
    mkdir -- "$config_dir" || blocked auth-store-permissions
  fi
  if [[ -e "$auth_dir" || -L "$auth_dir" ]]; then
    [[ -d "$auth_dir" && ! -L "$auth_dir" &&
      "$(github_auth_stat_uid "$auth_dir")" == "$current_uid" ]] || blocked auth-store-path
  else
    mkdir -- "$auth_dir" || blocked auth-store-permissions
  fi
  chmod 700 "$auth_dir" || blocked auth-store-permissions
  if [[ -e "$machine_file" || -L "$machine_file" ]]; then
    github_auth_machine_permissions "$machine_file" || blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  fi
  lock_dir="$auth_dir/.github-auth.lock"
  mkdir -- "$lock_dir" 2>/dev/null || blocked auth-store-busy
  chmod 700 "$lock_dir" || blocked auth-store-permissions
}

write_machine_token() {
  local candidate="$1" auth_dir
  auth_dir="$(dirname "$machine_file")"
  prepare_store_directory
  umask 077
  temp_file="$(mktemp "$auth_dir/.github.env.XXXXXX")" || blocked auth-store-permissions
  [[ ! -L "$temp_file" && "$(github_auth_stat_uid "$temp_file")" == "$(github_auth_current_uid)" &&
    "$(github_auth_stat_links "$temp_file")" == 1 ]] || blocked auth-store-path
  chmod 600 "$temp_file" || blocked auth-store-permissions
  {
    printf 'AGENT_DIRECTORY_GITHUB_CREDENTIAL_V1\n'
    printf 'resource_owner=%s\n' "$install_resource_owner"
    printf 'repositories=%s\n' "$install_repositories"
    printf 'operations=%s\n' "$install_operations"
    printf 'GH_TOKEN=%s\n' "$candidate"
  } > "$temp_file"
  [[ "$(github_auth_stat_mode "$temp_file")" == 600 ]] || blocked auth-store-permissions
  mv -f -- "$temp_file" "$machine_file" || blocked auth-store-permissions
  temp_file=''
  github_auth_read_machine_file "$machine_file" || blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  GITHUB_AUTH_TOKEN=''
}

install_token() {
  local candidate='' extra=''
  prepare_install_policy
  if [[ -t 0 ]]; then
    printf 'GitHub fine-grained PAT: ' >&2
    IFS= read -r -s candidate || blocked token-input-missing
    printf '\n' >&2
  else
    IFS= read -r candidate || blocked token-input-missing
    if IFS= read -r extra || [[ -n "$extra" ]]; then
      candidate=''
      blocked token-input-invalid
    fi
  fi
  github_auth_machine_pat_valid "$candidate" || { candidate=''; blocked token-not-fine-grained; }
  write_machine_token "$candidate"
  candidate=''
}

install_from_gh() {
  local candidate=''
  prepare_install_policy
  command -v gh >/dev/null 2>&1 || blocked interactive-setup-required
  candidate="$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh auth token --hostname github.com 2>/dev/null)" || \
    blocked interactive-setup-required
  github_auth_machine_pat_valid "$candidate" || { candidate=''; blocked token-not-fine-grained; }
  write_machine_token "$candidate"
  candidate=''
}

enroll_existing() {
  local repository item joined_repositories joined_operations normalized_owner normalized_repository_owner
  resolve_remote
  repository="$(github_auth_repository_from_url "$remote_url")" || blocked github-remote-invalid
  diagnostic_repository="$repository"
  GITHUB_AUTH_MACHINE_FILE_PRESENT='no'
  [[ ! -e "$machine_file" && ! -L "$machine_file" ]] || GITHUB_AUTH_MACHINE_FILE_PRESENT='yes'
  github_auth_read_machine_file "$machine_file" || {
    [[ "$GITHUB_AUTH_REASON" == auth-store-missing ]] && blocked machine-credential-not-installed
    blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  }
  GITHUB_AUTH_MACHINE_FILE_VALID='yes'
  GITHUB_AUTH_SOURCE='machine-file'
  normalized_owner="$(printf '%s' "$GITHUB_AUTH_RESOURCE_OWNER" | tr '[:upper:]' '[:lower:]')"
  normalized_repository_owner="$(printf '%s' "${repository%%/*}" | tr '[:upper:]' '[:lower:]')"
  [[ "$normalized_owner" == "$normalized_repository_owner" ]] || blocked multiple-resource-owners

  joined_repositories="$GITHUB_AUTH_REPOSITORIES"
  github_auth_list_has "$joined_repositories" "$repository" || \
    joined_repositories="$joined_repositories,$repository"
  joined_operations="$GITHUB_AUTH_OPERATIONS"
  if (( ${#operations[@]} == 0 )); then
    operations=(metadata-read git-read git-push)
  fi
  for item in "${operations[@]}"; do
    diagnostic_operation="$item"
    github_auth_operation_valid "$item" || blocked github-operation-invalid
    github_auth_list_has "$joined_operations" "$item" || joined_operations="$joined_operations,$item"
  done
  install_resource_owner="$GITHUB_AUTH_RESOURCE_OWNER"
  install_repositories="$joined_repositories"
  install_operations="$joined_operations"
  write_machine_token "$GITHUB_AUTH_TOKEN"
  printf 'GITHUB_MACHINE_ENROLLED source=machine-file repository=%s operations=%s atomic=yes token_reused=yes\n' \
    "$repository" "$(IFS=,; printf '%s' "${operations[*]}")"
}

machine_ready() {
  local repository operation
  resolve_remote
  repository="$(github_auth_repository_from_url "$remote_url")" || blocked github-remote-invalid
  diagnostic_repository="$repository"
  if (( ${#operations[@]} == 0 )); then
    operations=(git-read)
  fi
  GITHUB_AUTH_MACHINE_FILE_PRESENT='no'
  [[ ! -e "$machine_file" && ! -L "$machine_file" ]] || GITHUB_AUTH_MACHINE_FILE_PRESENT='yes'
  github_auth_read_machine_file "$machine_file" || {
    [[ "$GITHUB_AUTH_REASON" == auth-store-missing ]] && blocked machine-credential-not-installed
    blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  }
  GITHUB_AUTH_MACHINE_FILE_VALID='yes'
  GITHUB_AUTH_SOURCE='machine-file'
  for operation in "${operations[@]}"; do
    diagnostic_operation="$operation"
    github_auth_require_capability "$repository" "$operation" || blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  done
  GITHUB_AUTH_TOKEN=''
  printf 'GITHUB_MACHINE_READY source=machine-file machine_file_present=yes machine_file_valid=yes process_token=%s repository_enrolled=yes operation_enrolled=yes remote_resolved=yes api_probe_attempted=no git_probe_attempted=no repository=%s operation=%s\n' \
    "$(github_auth_process_token_state)" "$repository" "$(IFS=,; printf '%s' "${operations[*]}")"
}

case "$mode" in
  install-token) install_token ;;
  install-from-gh) install_from_gh ;;
  enroll-existing) enroll_existing; exit 0 ;;
  machine-ready) machine_ready; exit 0 ;;
  check) resolve_remote ;;
  *) usage ;;
esac

repository="$(github_auth_repository_from_url "$remote_url")" || blocked github-remote-invalid
diagnostic_repository="$repository"
if (( ${#operations[@]} > 0 )); then
  for operation in "${operations[@]}"; do
    diagnostic_operation="$operation"
    github_auth_resolve "$repo_root" "$repository" "$operation" || \
      blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  done
fi
diagnostic_operation='metadata-read'
if ! github_auth_probe_api "$expected_login" "$repo_root" "$repository"; then
  blocked "${GITHUB_AUTH_REASON:-github-unknown-failure}"
fi
diagnostic_operation='git-read'
if ! github_auth_probe_git "$repo_root" "$remote_url"; then
  blocked "${GITHUB_AUTH_REASON:-github-unknown-failure}"
fi
GITHUB_AUTH_TOKEN=''
printf 'GITHUB_AUTH_OK source=%s login=%s api=ok git=ok repository=%s remote=%s transport=%s remote_resolved=yes network_attempted=yes api_attempted=yes git_attempted=yes\n' \
  "$GITHUB_AUTH_SOURCE" "$GITHUB_AUTH_LOGIN" "$repository" "$remote_name" "$(github_auth_remote_kind "$remote_url")"
