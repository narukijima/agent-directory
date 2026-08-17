#!/usr/bin/env bash
set -euo pipefail
set +x

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-github-auth-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
failures=0
fixture_pat='github_''pat_fixture_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
ci_fixture='ci-fixture-value'
process_fixture='process-fixture-value'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

auth_env() {
  env -i PATH="$fixture/bin:$PATH" AGENT_DIRECTORY_GITHUB_TESTING=true \
    AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$fixture/account-home" \
    AGENT_DIRECTORY_ROOT="$fixture/workspace" TMPDIR="$fixture/tmp" "$@"
}

write_store() {
  local token="${1:-$fixture_pat}" repositories="${2:-fixture/repository}"
  local operations="${3:-metadata-read,git-read,git-push,issues-read,issues-write,pull-requests-read,pull-requests-write}"
  mkdir -p "$fixture/account-home/.config/agent-directory"
  chmod 700 "$fixture/account-home/.config/agent-directory"
  {
    printf 'AGENT_DIRECTORY_GITHUB_CREDENTIAL_V1\n'
    printf 'resource_owner=fixture\n'
    printf 'repositories=%s\n' "$repositories"
    printf 'operations=%s\n' "$operations"
    printf 'GH_TOKEN=%s\n' "$token"
  } > "$fixture/account-home/.config/agent-directory/github.env"
  chmod 600 "$fixture/account-home/.config/agent-directory/github.env"
}

resolve_result() {
  auth_env "$@" /bin/bash -c \
    '. "$1"; if github_auth_resolve "$2" fixture/repository git-read; then printf "OK:%s" "$GITHUB_AUTH_SOURCE"; else printf "BLOCKED:%s" "$GITHUB_AUTH_REASON"; fi' \
    auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace"
}

mkdir -p "$fixture/account-home" "$fixture/workspace" "$fixture/bin" "$fixture/tmp"
git -C "$fixture/workspace" init -q
git -C "$fixture/workspace" remote add backup https://github.com/fixture/repository.git

# Local resolution is machine-only. HOME/XDG differences cannot select different stores,
# and a process token cannot make one sibling Agent look machine-ready.
for process_case in one two; do
  output="$(resolve_result HOME="$fixture/home-$process_case" XDG_CONFIG_HOME="$fixture/xdg-$process_case" \
    GH_TOKEN="process-$process_case")"
  [[ "$output" == 'BLOCKED:machine-credential-not-installed' ]] || \
    fail "process-only local credential was accepted: $output"
done

write_store
for process_case in one two; do
  output="$(resolve_result HOME="$fixture/home-$process_case" XDG_CONFIG_HOME="$fixture/xdg-$process_case")"
  [[ "$output" == 'OK:machine-file' ]] || fail "processes did not converge on the OS-account store: $output"
done

# Stale or malformed machine state never falls through to a process token.
write_store 'not-a-fine-grained-token'
output="$(resolve_result GH_TOKEN="$fixture_pat")"
[[ "$output" == 'BLOCKED:machine-token-not-fine-grained' ]] || \
  fail "invalid machine credential silently fell back: $output"
write_store

# CI fallback is explicit, repository-bound, and operation-bound.
rm -f "$fixture/account-home/.config/agent-directory/github.env"
output="$(resolve_result CI=true AGENT_DIRECTORY_GITHUB_CI=true GITHUB_REPOSITORY=fixture/repository \
  AGENT_DIRECTORY_GITHUB_CI_OPERATIONS=git-read GH_TOKEN="$ci_fixture")"
[[ "$output" == 'OK:ci-process-token' ]] || fail "explicit CI token was not accepted: $output"
output="$(resolve_result CI=true AGENT_DIRECTORY_GITHUB_CI=true GITHUB_REPOSITORY=fixture/other \
  AGENT_DIRECTORY_GITHUB_CI_OPERATIONS=git-read GH_TOKEN="$ci_fixture")"
[[ "$output" == 'BLOCKED:github-destination-not-allowed' ]] || fail "CI destination allowlist failed: $output"
output="$(auth_env CI=true AGENT_DIRECTORY_GITHUB_CI=true GITHUB_REPOSITORY=fixture/repository \
  AGENT_DIRECTORY_GITHUB_CI_OPERATIONS=metadata-read GH_TOKEN="$ci_fixture" /bin/bash -c \
  '. "$1"; github_auth_resolve "$2" fixture/repository git-push || printf "%s" "$GITHUB_AUTH_REASON"' \
  auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace")"
[[ "$output" == github-operation-not-allowed ]] || fail "CI operation allowlist failed: $output"
write_store

# Permissions, links, and paths fail closed.
credential_file="$fixture/account-home/.config/agent-directory/github.env"
chmod 644 "$credential_file"
[[ "$(resolve_result)" == 'BLOCKED:auth-store-permissions' ]] || fail '0644 credential was accepted'
chmod 600 "$credential_file"
ln "$credential_file" "$fixture/hardlink"
[[ "$(resolve_result)" == 'BLOCKED:auth-store-hardlink' ]] || fail 'hardlinked credential was accepted'
rm -f "$fixture/hardlink"
mv "$credential_file" "$fixture/real-credential"
ln -s "$fixture/real-credential" "$credential_file"
[[ "$(resolve_result)" == 'BLOCKED:auth-store-missing' ]] || fail 'symlinked credential was accepted'
rm -f "$credential_file"
mv "$fixture/real-credential" "$credential_file"
mv "$fixture/account-home/.config/agent-directory" "$fixture/account-home/.config/real-agent-directory"
ln -s "$fixture/account-home/.config/real-agent-directory" "$fixture/account-home/.config/agent-directory"
[[ "$(resolve_result)" == 'BLOCKED:auth-store-missing' ]] || fail 'symlinked credential directory was accepted'
rm "$fixture/account-home/.config/agent-directory"
mv "$fixture/account-home/.config/real-agent-directory" "$fixture/account-home/.config/agent-directory"

# Exact five-line parsing rejects empty, whitespace, extra, duplicate, and classic-token inputs.
for malformed_case in empty blank extra duplicate classic; do
  write_store
  case "$malformed_case" in
    empty) sed -i.bak 's/^GH_TOKEN=.*/GH_TOKEN=/' "$credential_file" ;;
    blank) printf '\n' >> "$credential_file" ;;
    extra) printf 'EXTRA=value\n' >> "$credential_file" ;;
    duplicate) printf 'GH_TOKEN=%s\n' "$fixture_pat" >> "$credential_file" ;;
    classic) sed -i.bak 's/^GH_TOKEN=.*/GH_TOKEN=ghp_fixture_classic_token_1234567890/' "$credential_file" ;;
  esac
  rm -f "$credential_file.bak"
  output="$(resolve_result)"
  [[ "$output" == BLOCKED:* ]] || fail "$malformed_case credential input was accepted"
done
write_store

cat > "$fixture/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'api user')
    [[ -n "${GH_TOKEN:-}" ]] || exit 9
    printf '%s\n' "${FAKE_GH_LOGIN:-fixture-login}"
    ;;
  'auth token') printf '%s\n' "${FAKE_SAVED_TOKEN:?}" ;;
  'auth git-credential') exit 0 ;;
  'issue list') exit 0 ;;
  *) exit 0 ;;
esac
GHSTUB
chmod 700 "$fixture/bin/gh"

# Upstream API calls use the shared resolver and do not persist the token in drafts,
# cache files, temporary report bodies, or output.
mkdir -p "$fixture/report/.agent-cache" "$fixture/report-home/.config/agent-directory"
chmod 700 "$fixture/report-home/.config/agent-directory"
{
  printf 'AGENT_DIRECTORY_GITHUB_CREDENTIAL_V1\n'
  printf 'resource_owner=claudagt\n'
  printf 'repositories=claudagt/agent-directory,claudagt/agent-skills\n'
  printf 'operations=metadata-read,issues-read,issues-write\n'
  printf 'GH_TOKEN=%s\n' "$fixture_pat"
} > "$fixture/report-home/.config/agent-directory/github.env"
chmod 600 "$fixture/report-home/.config/agent-directory/github.env"
cat > "$fixture/report/AGENTS.md" <<'AGENTS'
# AGENTS.md

## 自己定義

- あなたは`fixture-agent`（役割:`fixture`）。
AGENTS
report_output="$(env -i PATH="$fixture/bin:$PATH" AGENT_DIRECTORY_GITHUB_TESTING=true \
  AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$fixture/report-home" AGENT_DIRECTORY_ROOT="$fixture/report" \
  AGENT_CACHE_DIR="$fixture/report/.agent-cache" TMPDIR="$fixture/tmp" \
  /bin/bash "$tool_root/report-upstream-issue.sh" --search 'credential resolver' 2>&1)" || \
  fail "machine-only upstream search failed: $report_output"
[[ "$report_output" == *'UPSTREAM_REPORT_SEARCH_OK count=0'* && "$report_output" != *"$fixture_pat"* ]] || \
  fail 'upstream search output was incorrect or leaked a token'
grep -R -Fq "$fixture_pat" "$fixture/report/.agent-cache" "$fixture/tmp" 2>/dev/null && \
  fail 'report/cache/temp artifact retained the token'

# Readiness is local-only; capability is a separate API + Git probe.
machine_output="$(auth_env /bin/bash "$tool_root/setup-github-auth.sh" --machine-ready --remote backup 2>&1)" || \
  fail "machine readiness rejected a valid store: $machine_output"
[[ "$machine_output" == 'GITHUB_MACHINE_READY source=machine-file repository=fixture/repository' ]] || \
  fail "unexpected readiness result: $machine_output"

# The normal task entrance checks the shared store before context resolution or writes.
mkdir -p "$fixture/task-workspace/tools/lib" "$fixture/task-home"
cp "$tool_root/task.sh" "$fixture/task-workspace/tools/task.sh"
cp "$tool_root/setup-github-auth.sh" "$fixture/task-workspace/tools/setup-github-auth.sh"
cp "$tool_root/lib/github-auth.sh" "$fixture/task-workspace/tools/lib/github-auth.sh"
cat > "$fixture/task-workspace/tools/prepare-context.sh" <<'PREPARE'
#!/usr/bin/env bash
printf 'called\n' > "${TASK_PREPARE_MARKER:?}"
printf 'route=project\ntarget=projects/demo\ngit_root=.\nrepository_owner=embedded\nREAD:\nAGENTS.md\n'
PREPARE
chmod 700 "$fixture/task-workspace/tools/"*.sh
git -C "$fixture/task-workspace" init -q
git -C "$fixture/task-workspace" remote add backup https://github.com/fixture/repository.git
set +e
task_output="$(env -i PATH="$PATH" AGENT_DIRECTORY_GITHUB_TESTING=true \
  AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$fixture/task-home" AGENT_DIRECTORY_ROOT="$fixture/task-workspace" \
  GH_TOKEN="$process_fixture" TASK_PREPARE_MARKER="$fixture/prepare.marker" \
  /bin/bash "$fixture/task-workspace/tools/task.sh" context --route project --target projects/demo 2>&1)"
task_status=$?
set -e
[[ "$task_status" != 0 && "$task_output" == *'reason=machine-credential-not-installed'* &&
  ! -e "$fixture/prepare.marker" ]] || fail "task entrance accepted process-only readiness: $task_output"

# Installation accepts exactly one stdin line, writes atomically under a lock, and never
# prints the candidate even when the caller enables xtrace.
cat > "$fixture/bin/git" <<'GITPROBE'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == ls-remote ]] && exit 0
done
exec /usr/bin/git "$@"
GITPROBE
chmod 700 "$fixture/bin/git"
install_home="$fixture/install-home"
mkdir -p "$install_home"
set +e
install_output="$(printf '%s\n%s\n' "$fixture_pat" extra | env -i PATH="$fixture/bin:$PATH" \
  AGENT_DIRECTORY_GITHUB_TESTING=true AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$install_home" \
  AGENT_DIRECTORY_ROOT="$fixture/workspace" /bin/bash "$tool_root/setup-github-auth.sh" \
  --install-token --remote backup 2>&1)"
install_status=$?
set -e
[[ "$install_status" != 0 && "$install_output" == 'GITHUB_AUTH_BLOCKED reason=token-input-invalid' ]] || \
  fail "multi-line token input was not rejected: $install_output"
[[ ! -e "$install_home/.config/agent-directory/github.env" ]] || fail 'rejected input created a credential file'

mkdir -p "$install_home/.config/agent-directory/.github-auth.lock"
chmod 700 "$install_home/.config/agent-directory" "$install_home/.config/agent-directory/.github-auth.lock"
set +e
install_output="$(printf '%s\n' "$fixture_pat" | env -i PATH="$fixture/bin:$PATH" \
  AGENT_DIRECTORY_GITHUB_TESTING=true AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$install_home" \
  AGENT_DIRECTORY_ROOT="$fixture/workspace" /bin/bash "$tool_root/setup-github-auth.sh" \
  --install-token --remote backup 2>&1)"
install_status=$?
set -e
[[ "$install_status" != 0 && "$install_output" == 'GITHUB_AUTH_BLOCKED reason=auth-store-busy' ]] || \
  fail "concurrent install lock was not enforced: $install_output"
rm -rf "$install_home/.config/agent-directory/.github-auth.lock"

xtrace_output="$(printf '%s\n' "$fixture_pat" | env -i PATH="$fixture/bin:$PATH" \
  FAKE_SAVED_TOKEN="$fixture_pat" AGENT_DIRECTORY_GITHUB_TESTING=true \
  AGENT_DIRECTORY_GITHUB_HOME_OVERRIDE="$install_home" AGENT_DIRECTORY_ROOT="$fixture/workspace" \
  /bin/bash -x "$tool_root/setup-github-auth.sh" --install-token --remote backup 2>&1)" || \
  fail "valid direct install failed: $xtrace_output"
[[ "$xtrace_output" != *"$fixture_pat"* ]] || fail 'xtrace output leaked the token'
installed_file="$install_home/.config/agent-directory/github.env"
[[ -f "$installed_file" && "$(stat -f '%Lp' "$installed_file" 2>/dev/null || stat -c '%a' "$installed_file")" == 600 ]] || \
  fail 'installed credential is absent or not 0600'
find "$install_home/.config/agent-directory" -name '.github.env.*' -print | grep -q . && \
  fail 'atomic install left a temporary credential file'

# The Git wrapper uses the exact URL, disables repository hooks/ambient helpers and
# redirects, and never puts the token in argv or Git config files.
mkdir -p "$fixture/git-bin"
cat > "$fixture/git-bin/git" <<'GITSTUB'
#!/usr/bin/env bash
{
  printf 'token_present=%s\n' "$([[ -n "${GH_TOKEN:-}" ]] && printf yes || printf no)"
  for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} > "${FAKE_GIT_LOG:?}"
exit 0
GITSTUB
chmod 700 "$fixture/git-bin/git"
git_log="$fixture/git.args"
auth_env PATH="$fixture/git-bin:$fixture/bin:$PATH" FAKE_GIT_LOG="$git_log" /bin/bash -c \
  '. "$1"; github_git_run "$2" https://github.com/fixture/repository.git git-read -C "$2" ls-remote --heads https://github.com/fixture/repository.git' \
  auth-test "$tool_root/lib/github-auth.sh" "$fixture/workspace" >/dev/null 2>&1 || fail 'Git wrapper failed'
grep -Fqx 'token_present=yes' "$git_log" || fail 'Git child did not receive the scoped token'
grep -Fqx 'arg=core.hooksPath=/dev/null' "$git_log" || fail 'Git hooks were not disabled'
grep -Fqx 'arg=credential.helper=' "$git_log" || fail 'ambient credential helpers were not cleared'
grep -Fqx 'arg=http.followRedirects=false' "$git_log" || fail 'Git redirects were not disabled'
grep -Fq "$fixture_pat" "$git_log" && fail 'token appeared in Git argv'
git -C "$fixture/workspace" config --get-regexp 'credential|url\..*insteadOf' > "$fixture/git-config.after" 2>/dev/null || true
grep -Fq "$fixture_pat" "$fixture/git-config.after" && fail 'token appeared in Git config'

for hostile_url in 'https://github.com/fixture/repository.git?x=1' \
  'https://user''@github.com/fixture/repository.git' 'https://github.example/fixture/repository.git'; do
  output="$(auth_env /bin/bash -c '. "$1"; github_auth_remote_kind "$2"' auth-test \
    "$tool_root/lib/github-auth.sh" "$hostile_url")"
  [[ "$output" != github-https ]] || fail "hostile URL received GitHub credentials: $hostile_url"
done

# No fixture credential may escape the isolated roots, reports, cache, or temp area.
if rg -l -F "$fixture_pat" "$fixture" | grep -Ev '/(github\.env|real-credential)$' >/dev/null; then
  fail 'fixture token escaped an expected credential file'
fi

if (( failures > 0 )); then
  printf 'GITHUB_AUTH_TEST_FAILED failures=%s\n' "$failures" >&2
  exit 1
fi
printf 'GITHUB_AUTH_TEST_OK\n'
