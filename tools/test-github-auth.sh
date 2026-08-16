#!/usr/bin/env bash
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_root/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-github-auth-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

expect_source() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$(env -i PATH="$PATH" HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/config" \
    TMPDIR="$fixture/tmp" AGENT_DIRECTORY_ROOT="$fixture/workspace" "$@" /bin/bash -c \
    '. "$1"; github_auth_resolve "$AGENT_DIRECTORY_ROOT"; printf "%s" "$GITHUB_AUTH_SOURCE"' \
    auth-test "$tool_root/lib/github-auth.sh" 2>&1)"
  status=$?
  set -e
  if (( status != 0 )) || [[ "$output" != "$expected" ]]; then
    fail "resolver expected source=$expected, got status=$status output=$output"
  fi
}

mkdir -p "$fixture/home" "$fixture/config" "$fixture/workspace" "$fixture/bin" "$fixture/tmp"
printf 'GH_TOKEN=workspace-token\n' > "$fixture/workspace/.env"
expect_source process-gh-token env GH_TOKEN=process-token
expect_source process-github-token env GITHUB_TOKEN=github-process-token
expect_source workspace-env env
rm -f "$fixture/workspace/.env"

mkdir -p "$fixture/config/agent-directory"
chmod 700 "$fixture/config/agent-directory"
printf 'GH_TOKEN=machine-token\n' > "$fixture/config/agent-directory/github.env"
chmod 600 "$fixture/config/agent-directory/github.env"
expect_source machine-env env

chmod 644 "$fixture/config/agent-directory/github.env"
set +e
permission_output="$(env -i PATH="$PATH" HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/config" \
  /bin/bash -c '. "$1"; github_auth_resolve "$2" || printf "%s" "$GITHUB_AUTH_REASON"' \
  auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace" 2>&1)"
permission_status=$?
set -e
[[ "$permission_status" == 0 && "$permission_output" == auth-store-permissions ]] || \
  fail 'group/world-readable machine credential did not fail closed'
chmod 600 "$fixture/config/agent-directory/github.env"

cat > "$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'api user')
    if [[ "${GH_TOKEN:-}" == stale-machine-token ]]; then
      printf 'HTTP 401: Bad credentials\n' >&2
      exit 1
    fi
    case "${FAKE_GH_MODE:-ok}" in
      ok) printf '%s\n' "${FAKE_GH_LOGIN:-fixture-login}" ;;
      401) printf 'HTTP 401: Bad credentials\n' >&2; exit 1 ;;
      403) printf 'HTTP 403: Resource not accessible\n' >&2; exit 1 ;;
      network) printf 'could not resolve api.github.com\n' >&2; exit 1 ;;
    esac
    ;;
  'issue list') exit 0 ;;
  'auth token')
    [[ "${FAKE_GH_TOKEN_MODE:-ok}" == ok ]] || exit 1
    printf 'fixture-bootstrap-token\n'
    ;;
  'auth git-credential') exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod 700 "$fixture/bin/gh"

# gh-stored is the final resolver fallback when no machine or process credential exists.
rm -f "$fixture/config/agent-directory/github.env"
expect_source gh-stored env PATH="$fixture/bin:$PATH"

# Actual API capability, account matching, and error classification.
for api_case in '401:github-auth-unavailable' '403:github-permission-denied' \
  'network:github-api-unreachable'; do
  fake_mode="${api_case%%:*}"
  expected_reason="${api_case#*:}"
  api_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" FAKE_GH_MODE="$fake_mode" \
    /bin/bash -c '. "$1"; github_auth_resolve "$2"; github_auth_probe_api fixture-login || printf "%s" "$GITHUB_AUTH_REASON"' \
    auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace" 2>&1)"
  [[ "$api_output" == "$expected_reason" ]] || fail "API $fake_mode classification was $api_output"
done
account_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" FAKE_GH_LOGIN=someone-else \
  /bin/bash -c '. "$1"; github_auth_resolve "$2"; github_auth_probe_api fixture-login || printf "%s" "$GITHUB_AUTH_REASON"' \
  auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace" 2>&1)"
[[ "$account_output" == account-mismatch ]] || fail 'account mismatch was not rejected'

# The doctor accepts an omitted expected login, resolves an adopted workspace's backup
# remote without origin, and distinguishes a missing remote from a credential failure.
mkdir -p "$fixture/setup-workspace" "$fixture/setup-empty" "$fixture/setup-config/agent-directory"
chmod 700 "$fixture/setup-config/agent-directory"
printf 'GH_TOKEN=setup-machine-token\n' > "$fixture/setup-config/agent-directory/github.env"
chmod 600 "$fixture/setup-config/agent-directory/github.env"
git -C "$fixture/setup-workspace" init -q
git -C "$fixture/setup-empty" init -q
git init -q --bare "$fixture/setup-backup.git"
git -C "$fixture/setup-workspace" remote add backup "$fixture/setup-backup.git"
set +e
setup_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/setup-config" AGENT_DIRECTORY_ROOT="$fixture/setup-workspace" \
  /bin/bash "$tool_root/setup-github-auth.sh" --check 2>&1)"
setup_status=$?
set -e
[[ "$setup_status" == 0 && "$setup_output" == \
  'GITHUB_AUTH_OK source=machine-env login=fixture-login api=ok git=ok' ]] || \
  fail "doctor did not resolve the adopted workspace backup remote: $setup_output"
set +e
setup_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/setup-config" AGENT_DIRECTORY_ROOT="$fixture/setup-empty" \
  /bin/bash "$tool_root/setup-github-auth.sh" --check 2>&1)"
setup_status=$?
set -e
[[ "$setup_status" != 0 && "$setup_output" == *'reason=remote-not-configured'* ]] || \
  fail "doctor did not distinguish a missing remote: $setup_output"

# Install and repair accept an omitted expected login. A stale machine credential must be
# replaced from a valid saved gh credential without starting an interactive login flow.
mkdir -p "$fixture/bootstrap-workspace" "$fixture/bootstrap-config/agent-directory"
git -C "$fixture/bootstrap-workspace" init -q
git init -q --bare "$fixture/bootstrap-backup.git"
git -C "$fixture/bootstrap-workspace" remote add backup "$fixture/bootstrap-backup.git"
set +e
bootstrap_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/bootstrap-config" AGENT_DIRECTORY_ROOT="$fixture/bootstrap-workspace" \
  /bin/bash "$tool_root/setup-github-auth.sh" --install-from-gh --remote backup 2>&1)"
bootstrap_status=$?
set -e
[[ "$bootstrap_status" == 0 && "$bootstrap_output" == \
  'GITHUB_AUTH_OK source=machine-env login=fixture-login api=ok git=ok' ]] || \
  fail "install with omitted expected login failed: $bootstrap_output"
bootstrap_mode="$(stat -f '%Lp' "$fixture/bootstrap-config/agent-directory/github.env" 2>/dev/null || \
  stat -c '%a' "$fixture/bootstrap-config/agent-directory/github.env" 2>/dev/null || true)"
[[ "$bootstrap_mode" == 600 ]] || \
  fail 'installed machine credential permissions were not 0600'

printf 'GH_TOKEN=stale-machine-token\n' > "$fixture/bootstrap-config/agent-directory/github.env"
chmod 600 "$fixture/bootstrap-config/agent-directory/github.env"
set +e
bootstrap_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/bootstrap-config" AGENT_DIRECTORY_ROOT="$fixture/bootstrap-workspace" \
  /bin/bash "$tool_root/setup-github-auth.sh" --repair-from-gh --remote backup 2>&1)"
bootstrap_status=$?
set -e
[[ "$bootstrap_status" == 0 && "$bootstrap_output" == \
  'GITHUB_AUTH_OK source=machine-env login=fixture-login api=ok git=ok' ]] || \
  fail "repair with omitted expected login failed: $bootstrap_output"
grep -Fqx 'GH_TOKEN=fixture-bootstrap-token' \
  "$fixture/bootstrap-config/agent-directory/github.env" || \
  fail 'repair did not replace the stale machine credential from saved gh auth'

rm -f "$fixture/bootstrap-config/agent-directory/github.env"
set +e
bootstrap_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/bootstrap-config" AGENT_DIRECTORY_ROOT="$fixture/bootstrap-workspace" \
  /bin/bash "$tool_root/setup-github-auth.sh" --install-from-gh \
  --expected-login different-login --remote backup 2>&1)"
bootstrap_status=$?
set -e
[[ "$bootstrap_status" != 0 && "$bootstrap_output" == \
  'GITHUB_AUTH_BLOCKED reason=account-mismatch' ]] || \
  fail "explicit expected login mismatch was not rejected: $bootstrap_output"
[[ ! -e "$fixture/bootstrap-config/agent-directory/github.env" ]] || \
  fail 'account mismatch wrote a machine credential'

set +e
bootstrap_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/bootstrap-config" AGENT_DIRECTORY_ROOT="$fixture/bootstrap-workspace" \
  FAKE_GH_TOKEN_MODE=missing /bin/bash "$tool_root/setup-github-auth.sh" \
  --repair-from-gh --remote backup 2>&1)"
bootstrap_status=$?
set -e
[[ "$bootstrap_status" != 0 && "$bootstrap_output" == \
  'GITHUB_AUTH_BLOCKED reason=interactive-setup-required' ]] || \
  fail "missing saved credential was not classified as interactive setup: $bootstrap_output"

# Report mode: machine credential works without process token; auth failure exits 3 and
# reuses the same content-addressed draft.
mkdir -p "$fixture/report/.agent-cache" "$fixture/report-config/agent-directory"
chmod 700 "$fixture/report-config/agent-directory"
printf 'GH_TOKEN=report-machine-token\n' > "$fixture/report-config/agent-directory/github.env"
chmod 600 "$fixture/report-config/agent-directory/github.env"
cat > "$fixture/report/AGENTS.md" <<'AGENTS'
# AGENTS.md

## 自己定義

- あなたは`fixture-auth-agent`（役割:`fixture`）。
AGENTS
printf 'privateなdownstream Workspaceで観測した。\n' > "$fixture/report/body.md"
set +e
report_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
  XDG_CONFIG_HOME="$fixture/report-config" AGENT_DIRECTORY_ROOT="$fixture/report" \
  TMPDIR="$fixture/tmp" AGENT_CACHE_DIR="$fixture/report/.agent-cache" FAKE_GH_MODE=ok \
  AGENT_GITHUB_AUTH_DISABLE_REPAIR=true /bin/bash "$tool_root/report-upstream-issue.sh" \
  --search 'bootloader auth capability' 2>&1)"
report_status=$?
set -e
[[ "$report_status" == 0 && "$report_output" == *'UPSTREAM_REPORT_SEARCH_OK count=0'* ]] || \
  fail "machine-only report search failed: $report_output"

first_path=''
for attempt in 1 2; do
  set +e
  report_output="$(env -i PATH="$fixture/bin:$PATH" HOME="$fixture/home" \
    XDG_CONFIG_HOME="$fixture/report-config" AGENT_DIRECTORY_ROOT="$fixture/report" \
    TMPDIR="$fixture/tmp" AGENT_CACHE_DIR="$fixture/report/.agent-cache" FAKE_GH_MODE=401 \
    AGENT_GITHUB_AUTH_DISABLE_REPAIR=true /bin/bash "$tool_root/report-upstream-issue.sh" \
    --title '[bug] headless credential unavailable' --body-file "$fixture/report/body.md" 2>&1)"
  report_status=$?
  set -e
  [[ "$report_status" == 3 && "$report_output" == *'UPSTREAM_REPORT_DRAFTED reason=github-auth-unavailable'* ]] || \
    fail "auth failure did not draft with exit 3: $report_output"
  current_path="$(printf '%s\n' "$report_output" | sed -n 's/^UPSTREAM_REPORT_DRAFTED reason=[^ ]* path=//p' | tail -n 1)"
  [[ -n "$current_path" ]] || fail 'auth draft path was not reported'
  if [[ -n "$first_path" && "$current_path" != "$first_path" ]]; then
    fail 'identical auth failure created a second draft path'
  fi
  first_path="$current_path"
done

if grep -R -Fq 'report-machine-token' "$fixture/report/.agent-cache" 2>/dev/null; then
  fail 'credential value leaked into a report draft'
fi

# Git wrapper applies the helper only to HTTPS github.com; SSH and other hosts remain untouched.
mkdir -p "$fixture/git-bin"
cat > "$fixture/git-bin/git" <<'GITSTUB'
#!/usr/bin/env bash
for arg in "$@"; do printf '%s\n' "$arg"; done > "${FAKE_GIT_LOG:?}"
exit 0
GITSTUB
chmod 700 "$fixture/git-bin/git"
for wrapper_case in github-https github-ssh other-host; do
  case "$wrapper_case" in
    github-https) wrapper_url='https://github.com/owner/repository.git' ;;
    github-ssh) wrapper_url='git@github.com:owner/repository.git' ;;
    other-host) wrapper_url='https://git.example.invalid/owner/repository.git' ;;
  esac
  wrapper_log="$fixture/$wrapper_case.args"
  env -i PATH="$fixture/git-bin:$fixture/bin:$PATH" HOME="$fixture/home" \
    GH_TOKEN=wrapper-secret-token FAKE_GIT_LOG="$wrapper_log" /bin/bash -c \
    '. "$1"; github_git_run "$2" "$3" -C "$2" ls-remote --heads origin' \
    auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace" "$wrapper_url" >/dev/null 2>&1 || \
    fail "Git wrapper failed for $wrapper_case"
  if [[ "$wrapper_case" == github-https ]]; then
    grep -Fqx 'credential.https://github.com.helper=!gh auth git-credential' "$wrapper_log" || \
      fail 'GitHub HTTPS did not receive the gh credential helper'
  elif grep -Fq 'credential.https://github.com.helper' "$wrapper_log"; then
    fail "$wrapper_case received GitHub credentials"
  fi
  if grep -Fq 'wrapper-secret-token' "$wrapper_log"; then
    fail "$wrapper_case leaked the token into Git argv"
  fi
done

if (( failures > 0 )); then
  printf 'GITHUB_AUTH_TEST_FAILED failures=%s\n' "$failures" >&2
  exit 1
fi
printf 'GITHUB_AUTH_TEST_OK\n'
