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
operations=()
credential_file=''
lock_dir=''
temp_file=''
remote_url=''
diagnostic_repository='unknown'
diagnostic_operation='git-read'

usage() {
  printf 'Usage: %s (--install-token|--install-from-gh|--workspace-ready|--check) [--expected-login <login>] [--remote <name>] [--operation <operation>]...\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  local diagnostic_status
  GITHUB_AUTH_REASON="$1"
  diagnostic_status="${GITHUB_AUTH_LAST_STATUS:-1}"
  [[ "$diagnostic_status" != 0 ]] || diagnostic_status=1
  if [[ "$mode" == workspace-ready || "$mode" == check ]]; then
    github_auth_diagnostic "$diagnostic_operation" "$diagnostic_repository"       "${remote_name:-none}" "$(github_auth_remote_kind "${remote_url:-}")" "$diagnostic_status" >&2
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
    --install-token|--install-from-gh|--workspace-ready|--check)
      [[ -z "$mode" ]] || usage
      mode="${1#--}"
      shift
      ;;
    --expected-login) [[ $# -ge 2 ]] || usage; expected_login="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote_name="$2"; remote_explicit=true; shift 2 ;;
    --operation) [[ $# -ge 2 ]] || usage; operations+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$mode" ]] || usage
[[ -z "$expected_login" || "$expected_login" =~ ^[A-Za-z0-9-]+$ ]] || blocked account-mismatch
[[ -n "$repo_root" ]] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || blocked not-git-repository
credential_file="$(github_auth_workspace_file "$repo_root")" || blocked "${GITHUB_AUTH_REASON:-agent-env-root-invalid}"

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
  diagnostic_repository="$(github_auth_repository_from_url "$remote_url")" || blocked github-remote-invalid
  GITHUB_AUTH_REMOTE_RESOLVED='yes'
}

prepare_workspace_env() {
  [[ -d "$repo_root" && ! -L "$repo_root" ]] || blocked agent-env-root-invalid
  if [[ -e "$credential_file" || -L "$credential_file" ]]; then
    agent_env_permissions "$repo_root" "$credential_file" || blocked "$AGENT_ENV_REASON"
  fi
  lock_dir="$repo_root/.agent-env.lock"
  mkdir -- "$lock_dir" 2>/dev/null || blocked agent-env-busy
}

write_workspace_token() {
  local candidate="$1" line
  prepare_workspace_env
  umask 077
  temp_file="$(mktemp "$repo_root/.env.XXXXXX")" || blocked agent-env-permissions
  chmod 600 "$temp_file" || blocked agent-env-permissions
  if [[ -f "$credential_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        GH_TOKEN=*|GITHUB_TOKEN=*) ;;
        *) printf '%s\n' "$line" >> "$temp_file" ;;
      esac
    done < "$credential_file"
  fi
  printf 'GH_TOKEN=%s\n' "$candidate" >> "$temp_file"
  mv -f -- "$temp_file" "$credential_file" || blocked agent-env-permissions
  temp_file=''
  chmod 600 "$credential_file" || blocked agent-env-permissions
  github_auth_read_workspace_file "$repo_root" || blocked "${GITHUB_AUTH_REASON:-agent-env-invalid}"
  GITHUB_AUTH_TOKEN=''
}

install_token() {
  local candidate='' extra=''
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
  github_auth_pat_valid "$candidate" || { candidate=''; blocked token-not-fine-grained; }
  write_workspace_token "$candidate"
  candidate=''
  printf 'GITHUB_WORKSPACE_CREDENTIAL_INSTALLED source=workspace-env workspace_scoped=yes\n'
}

install_from_gh() {
  local candidate=''
  command -v gh >/dev/null 2>&1 || blocked interactive-setup-required
  candidate="$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh auth token --hostname github.com 2>/dev/null)" ||     blocked interactive-setup-required
  github_auth_pat_valid "$candidate" || { candidate=''; blocked token-not-fine-grained; }
  write_workspace_token "$candidate"
  candidate=''
  printf 'GITHUB_WORKSPACE_CREDENTIAL_INSTALLED source=workspace-env workspace_scoped=yes\n'
}

workspace_ready() {
  local operation
  resolve_remote
  (( ${#operations[@]} > 0 )) || operations=(git-read)
  for operation in "${operations[@]}"; do
    diagnostic_operation="$operation"
    github_auth_resolve "$repo_root" "$diagnostic_repository" "$operation" ||       blocked "${GITHUB_AUTH_REASON:-agent-env-invalid}"
  done
  GITHUB_AUTH_TOKEN=''
  printf 'GITHUB_WORKSPACE_READY source=workspace-env credential_file_present=yes credential_file_valid=yes workspace_scoped=yes remote_resolved=yes api_probe_attempted=no git_probe_attempted=no repository=%s operation=%s\n'     "$diagnostic_repository" "$(IFS=,; printf '%s' "${operations[*]}")"
}

case "$mode" in
  install-token) install_token; exit 0 ;;
  install-from-gh) install_from_gh; exit 0 ;;
  workspace-ready) workspace_ready; exit 0 ;;
  check) resolve_remote ;;
  *) usage ;;
esac

if (( ${#operations[@]} > 0 )); then
  for operation in "${operations[@]}"; do
    diagnostic_operation="$operation"
    github_auth_resolve "$repo_root" "$diagnostic_repository" "$operation" ||       blocked "${GITHUB_AUTH_REASON:-agent-env-invalid}"
  done
fi
diagnostic_operation='metadata-read'
github_auth_probe_api "$expected_login" "$repo_root" "$diagnostic_repository" ||   blocked "${GITHUB_AUTH_REASON:-github-unknown-failure}"
diagnostic_operation='git-read'
github_auth_probe_git "$repo_root" "$remote_url" ||   blocked "${GITHUB_AUTH_REASON:-github-unknown-failure}"
GITHUB_AUTH_TOKEN=''
printf 'GITHUB_AUTH_OK source=%s login=%s api=ok git=ok repository=%s remote=%s transport=%s workspace_scoped=yes network_attempted=yes api_attempted=yes git_attempted=yes\n'   "$GITHUB_AUTH_SOURCE" "$GITHUB_AUTH_LOGIN" "$diagnostic_repository" "$remote_name" "$(github_auth_remote_kind "$remote_url")"
