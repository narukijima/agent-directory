#!/usr/bin/env bash
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${AGENT_DIRECTORY_ROOT:-$tool_root/..}" 2>/dev/null && pwd -P)" || repo_root=''
. "$tool_root/lib/github-auth.sh"

mode=''
expected_login=''
remote_name=''
remote_explicit=false

usage() {
  printf 'Usage: %s (--install-from-gh|--machine-ready|--check|--repair-from-gh) [--expected-login <login>] [--remote <name>]\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  printf 'GITHUB_AUTH_BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-from-gh|--machine-ready|--check|--repair-from-gh)
      [[ -z "$mode" ]] || usage
      mode="${1#--}"
      shift
      ;;
    --expected-login) [[ $# -ge 2 ]] || usage; expected_login="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote_name="$2"; remote_explicit=true; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$mode" ]] || usage
[[ -z "$expected_login" || "$expected_login" =~ ^[A-Za-z0-9-]+$ ]] || blocked account-mismatch
[[ -n "$repo_root" ]] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || \
  blocked not-git-repository

machine_file="$(github_auth_machine_file)"

machine_ready() {
  if ! github_auth_machine_permissions "$machine_file"; then
    [[ "$GITHUB_AUTH_REASON" == auth-store-missing ]] && blocked machine-credential-not-installed
    blocked "${GITHUB_AUTH_REASON:-machine-credential-invalid}"
  fi
  if ! github_auth_read_known_key "$machine_file" GH_TOKEN true; then
    blocked machine-credential-invalid
  fi
  GITHUB_AUTH_PARSED_VALUE=''
  printf 'GITHUB_MACHINE_READY source=machine-env\n'
}

machine_is_healthy() {
  local saved_gh="${GH_TOKEN-}" saved_github="${GITHUB_TOKEN-}" had_gh=false had_github=false
  [[ ${GH_TOKEN+x} ]] && had_gh=true
  [[ ${GITHUB_TOKEN+x} ]] && had_github=true
  unset GH_TOKEN GITHUB_TOKEN
  if ! github_auth_machine_permissions "$machine_file" || \
    ! github_auth_read_known_key "$machine_file" GH_TOKEN true; then
    [[ "$had_gh" == true ]] && GH_TOKEN="$saved_gh" && export GH_TOKEN
    [[ "$had_github" == true ]] && GITHUB_TOKEN="$saved_github" && export GITHUB_TOKEN
    return 1
  fi
  GH_TOKEN="$GITHUB_AUTH_PARSED_VALUE"; export GH_TOKEN
  GITHUB_AUTH_SOURCE='machine-env'
  GITHUB_AUTH_PARSED_VALUE=''
  if ! github_auth_probe_api "$expected_login"; then
    [[ "$had_gh" == true ]] && GH_TOKEN="$saved_gh" && export GH_TOKEN || unset GH_TOKEN
    [[ "$had_github" == true ]] && GITHUB_TOKEN="$saved_github" && export GITHUB_TOKEN
    return 1
  fi
  [[ "$had_gh" == true ]] && GH_TOKEN="$saved_gh" && export GH_TOKEN || unset GH_TOKEN
  [[ "$had_github" == true ]] && GITHUB_TOKEN="$saved_github" && export GITHUB_TOKEN
  return 0
}

install_from_gh() {
  local candidate='' login_output='' failure_reason='' auth_dir temp_file=''
  if machine_is_healthy; then
    return 0
  fi
  command -v gh >/dev/null 2>&1 || blocked interactive-setup-required
  candidate="$(gh auth token --hostname github.com 2>/dev/null)" || blocked interactive-setup-required
  github_auth_value_valid "$candidate" || blocked interactive-setup-required
  if ! login_output="$(GH_TOKEN="$candidate" GH_HOST=github.com GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1 gh api user --jq .login 2>&1)"; then
    failure_reason="$(github_auth_classify_api_error "$login_output")"
    candidate=''
    [[ "$failure_reason" == github-auth-unavailable ]] && blocked interactive-setup-required
    blocked "$failure_reason"
  fi
  login_output="$(printf '%s\n' "$login_output" | tail -n 1 | tr -d '\r')"
  [[ -n "$login_output" && "$login_output" != *[[:space:]]* ]] || {
    candidate=''
    blocked interactive-setup-required
  }
  if [[ -n "$expected_login" && "$login_output" != "$expected_login" ]]; then
    candidate=''
    blocked account-mismatch
  fi
  auth_dir="$(dirname "$machine_file")"
  umask 077
  mkdir -p "$auth_dir" || blocked auth-store-permissions
  chmod 700 "$auth_dir" || blocked auth-store-permissions
  temp_file="$(mktemp "$auth_dir/.github.env.XXXXXX")" || blocked auth-store-permissions
  trap '[[ -z "${temp_file:-}" ]] || rm -f "$temp_file"' EXIT
  printf 'GH_TOKEN=%s\n' "$candidate" > "$temp_file"
  candidate=''
  chmod 600 "$temp_file" || blocked auth-store-permissions
  mv -f "$temp_file" "$machine_file" || blocked auth-store-permissions
  temp_file=''
}

configure_git_helper() {
  unset GH_TOKEN GITHUB_TOKEN
  github_auth_resolve "$repo_root" || blocked "${GITHUB_AUTH_REASON:-github-auth-unavailable}"
  gh auth setup-git --hostname github.com >/dev/null 2>&1 || blocked git-credential-unavailable
}

case "$mode" in
  install-from-gh|repair-from-gh) install_from_gh; configure_git_helper ;;
  machine-ready) machine_ready; exit 0 ;;
  check) ;;
  *) usage ;;
esac

unset GH_TOKEN GITHUB_TOKEN
if ! github_auth_resolve "$repo_root"; then
  blocked "${GITHUB_AUTH_REASON:-auth-store-missing}"
fi
if ! github_auth_probe_api "$expected_login"; then
  blocked "${GITHUB_AUTH_REASON:-github-auth-unavailable}"
fi

# Adopted workspaces normally use `backup` and may not have `origin`. An explicit
# --remote is never replaced; otherwise prefer the configured push default, then the
# documented workspace backup name, and finally the public-skeleton development remote.
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
if ! github_auth_probe_git "$repo_root" "$remote_name" "$remote_url"; then
  blocked "${GITHUB_AUTH_REASON:-git-credential-unavailable}"
fi
printf 'GITHUB_AUTH_OK source=%s login=%s api=ok git=ok\n' "$GITHUB_AUTH_SOURCE" "$GITHUB_AUTH_LOGIN"
