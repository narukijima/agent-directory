#!/usr/bin/env bash
set -euo pipefail
set +x

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
auth_lib="$tool_root/lib/github-auth.sh"
env_lib="$tool_root/lib/agent-env.sh"
failures=0
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
fixture_pat_a="$(printf '%s%s' 'github_' 'pat_')$(printf 'A%.0s' {1..76})"
fixture_pat_b="$(printf '%s%s' 'github_' 'pat_')$(printf 'B%.0s' {1..76})"
fixture_pat_a_updated="$(printf '%s%s' 'github_' 'pat_')$(printf 'C%.0s' {1..76})"
fixture_pat_b_updated="$(printf '%s%s' 'github_' 'pat_')$(printf 'D%.0s' {1..76})"

make_workspace() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" remote add backup https://github.com/fixture/repository.git
}

write_env() {
  local root="$1" token="$2"
  printf 'AGENT_LABEL=fixture\nGH_TOKEN=%s\n' "$token" > "$root/.env"
  chmod 600 "$root/.env"
}

resolve_expected() {
  local root="$1" expected="$2"
  EXPECTED_TOKEN="$expected" /bin/bash -c '
    . "$1"
    github_auth_resolve "$2" fixture/repository git-read || exit 10
    [[ "$GITHUB_AUTH_SOURCE" == workspace-env ]] || exit 11
    [[ "$GITHUB_AUTH_TOKEN" == "$EXPECTED_TOKEN" ]] || exit 12
    [[ "$GITHUB_AUTH_CREDENTIAL_FILE" == "$2/.env" ]] || exit 13
  ' _ "$auth_lib" "$root"
}

workspace_a="$fixture/agent-a"
workspace_b="$fixture/agent-b"
make_workspace "$workspace_a"
make_workspace "$workspace_b"
write_env "$workspace_a" "$fixture_pat_a"
write_env "$workspace_b" "$fixture_pat_b"
resolve_expected "$workspace_a" "$fixture_pat_a" || fail 'Agent A did not select its own .env token'
resolve_expected "$workspace_b" "$fixture_pat_b" || fail 'Agent B did not select its own .env token'

# A registered Independent Project owns its Git root, while the enclosing Agent
# Workspace remains the credential owner. Exact registry and repository matching
# prevents this from becoming arbitrary parent or sibling fallback.
owner_workspace="$fixture/owner-agent"
registered_child="$owner_workspace/projects/registered-child"
mkdir -p "$owner_workspace/projects" "$registered_child"
git -C "$owner_workspace" init -q
git -C "$registered_child" init -q
owner_workspace_physical="$(cd "$owner_workspace" && pwd -P)"
git -C "$registered_child" remote add origin https://github.com/fixture/registered.git
write_env "$owner_workspace" "$fixture_pat_a"
write_env "$registered_child" "$fixture_pat_b"
cat > "$owner_workspace/projects/REPOSITORIES.md" <<'REGISTERED_PROJECT'
# REPOSITORIES — Independent Repository Registry

## `registered-child`

- repository_url: `https://github.com/fixture/registered.git`
- repository_role: `public-foundation`
- repository_reason: `distribution`
- revision: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
REGISTERED_PROJECT

registered_resolve_status=0
EXPECTED_TOKEN="$fixture_pat_a" /bin/bash -c '
  . "$1"
  github_auth_resolve "$2" fixture/registered git-push || exit 20
  [[ "$GITHUB_AUTH_TOKEN" == "$EXPECTED_TOKEN" ]] || exit 21
  [[ "$GITHUB_AUTH_CREDENTIAL_FILE" == "$3/.env" ]] || exit 22
  [[ "$GITHUB_AUTH_CREDENTIAL_ROOT" == "$3" ]] || exit 23
  [[ "$GITHUB_AUTH_CREDENTIAL_OWNER" == registered-agent-root ]] || exit 24
' _ "$auth_lib" "$registered_child" "$owner_workspace_physical" || registered_resolve_status=$?
(( registered_resolve_status == 0 )) || \
  fail "registered Independent Project did not select its Agent root credential (status=$registered_resolve_status)"

registered_ready_output="$(AGENT_DIRECTORY_ROOT="$registered_child" /bin/bash \
  "$tool_root/setup-github-auth.sh" --workspace-ready --remote origin --operation git-push 2>&1)" || \
  fail "registered Independent workspace-ready failed: $registered_ready_output"
[[ "$registered_ready_output" == *'credential_owner=registered-agent-root'* ]] || \
  fail "registered Independent workspace-ready hid its credential owner: $registered_ready_output"

set +e
registered_install_output="$(printf '%s\n' "$fixture_pat_b_updated" | AGENT_DIRECTORY_ROOT="$registered_child" \
  /bin/bash "$tool_root/setup-github-auth.sh" --install-token 2>&1)"
registered_install_status=$?
set -e
if (( registered_install_status == 0 )) || \
  [[ "$registered_install_output" != *'GITHUB_AUTH_BLOCKED reason=credential-owned-by-agent-root'* ]]; then
  fail "registered Independent Project requested or installed a duplicate token: $registered_install_output"
fi

EXPECTED_TOKEN="$fixture_pat_b" /bin/bash -c '
  . "$1"
  github_auth_resolve "$2" fixture/unregistered git-read || exit 25
  [[ "$GITHUB_AUTH_TOKEN" == "$EXPECTED_TOKEN" ]] || exit 26
  [[ "$GITHUB_AUTH_CREDENTIAL_OWNER" == workspace-root ]] || exit 27
' _ "$auth_lib" "$registered_child" || \
  fail 'repository mismatch consumed the parent Agent credential'

cp "$workspace_b/.env" "$fixture/agent-b-before-agent-a-update.env"
printf '%s\n' "$fixture_pat_a_updated" | AGENT_DIRECTORY_ROOT="$workspace_a" \
  /bin/bash "$tool_root/setup-github-auth.sh" --install-token >/dev/null || \
  fail 'Agent A token update failed'
resolve_expected "$workspace_a" "$fixture_pat_a_updated" || \
  fail 'Agent A did not select its updated .env token'
resolve_expected "$workspace_b" "$fixture_pat_b" || \
  fail 'Agent A update changed Agent B token selection'
cmp -s "$fixture/agent-b-before-agent-a-update.env" "$workspace_b/.env" || \
  fail 'Agent A update changed Agent B .env'

cp "$workspace_a/.env" "$fixture/agent-a-before-agent-b-update.env"
printf '%s\n' "$fixture_pat_b_updated" | AGENT_DIRECTORY_ROOT="$workspace_b" \
  /bin/bash "$tool_root/setup-github-auth.sh" --install-token >/dev/null || \
  fail 'Agent B token update failed'
resolve_expected "$workspace_b" "$fixture_pat_b_updated" || \
  fail 'Agent B did not select its updated .env token'
resolve_expected "$workspace_a" "$fixture_pat_a_updated" || \
  fail 'Agent B update changed Agent A token selection'
cmp -s "$fixture/agent-a-before-agent-b-update.env" "$workspace_a/.env" || \
  fail 'Agent B update changed Agent A .env'

mv "$workspace_a/.env" "$fixture/agent-a-owned.env"
missing_with_sibling_output="$(/bin/bash -c '
  . "$1"
  github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_a")"
[[ "$missing_with_sibling_output" == agent-env-missing ]] || \
  fail "Agent A fell back when only Agent B had an .env: $missing_with_sibling_output"
resolve_expected "$workspace_b" "$fixture_pat_b_updated" || \
  fail 'Agent B stopped selecting its own token while Agent A .env was absent'
mv "$fixture/agent-a-owned.env" "$workspace_a/.env"

GH_TOKEN="$fixture_pat_b" resolve_expected "$workspace_a" "$fixture_pat_a_updated" || \
  fail 'ambient process token overrode the Agent-owned .env'

mkdir -p "$fixture/account-home/.config/agent-directory"
printf 'GH_TOKEN=%s\n' "$fixture_pat_b" > "$fixture/account-home/.config/agent-directory/github.env"
chmod 600 "$fixture/account-home/.config/agent-directory/github.env"
workspace_missing="$fixture/agent-missing"
make_workspace "$workspace_missing"
missing_output="$(HOME="$fixture/account-home" /bin/bash -c '
  . "$1"
  github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_missing")"
[[ "$missing_output" == agent-env-missing ]] ||   fail "OS-home credential was consumed or misclassified: $missing_output"

chmod 644 "$workspace_a/.env"
permission_output="$(/bin/bash -c '
  . "$1"; github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_a")"
[[ "$permission_output" == agent-env-permissions ]] || fail "0644 .env was accepted: $permission_output"
chmod 600 "$workspace_a/.env"

mv "$workspace_a/.env" "$workspace_a/.env.real"
ln -s .env.real "$workspace_a/.env"
symlink_output="$(/bin/bash -c '
  . "$1"; github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_a")"
[[ "$symlink_output" == agent-env-missing ]] || fail "symlinked .env was accepted: $symlink_output"
rm "$workspace_a/.env"
mv "$workspace_a/.env.real" "$workspace_a/.env"

ln "$workspace_a/.env" "$workspace_a/.env.link"
hardlink_output="$(/bin/bash -c '
  . "$1"; github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_a")"
[[ "$hardlink_output" == agent-env-hardlink ]] || fail "hardlinked .env was accepted: $hardlink_output"
rm "$workspace_a/.env.link"

printf 'GH_TOKEN=%s\nGH_TOKEN=%s\n' "$fixture_pat_a" "$fixture_pat_b" > "$workspace_a/.env"
chmod 600 "$workspace_a/.env"
duplicate_output="$(/bin/bash -c '
  . "$1"; github_auth_resolve "$2" fixture/repository git-read || printf "%s" "$GITHUB_AUTH_REASON"
' _ "$auth_lib" "$workspace_a")"
[[ "$duplicate_output" == agent-env-key-duplicate ]] || fail "duplicate GH_TOKEN was accepted: $duplicate_output"
write_env "$workspace_a" "$fixture_pat_a"

ci_output="$(CI=true AGENT_DIRECTORY_GITHUB_CI=true GITHUB_REPOSITORY=fixture/repository   AGENT_DIRECTORY_GITHUB_CI_OPERATIONS=git-read GH_TOKEN="$fixture_pat_b" /bin/bash -c '
    . "$1"; github_auth_resolve "$2" fixture/repository git-read
    printf "%s" "$GITHUB_AUTH_SOURCE"
  ' _ "$auth_lib" "$workspace_missing")"
[[ "$ci_output" == ci-process-token ]] || fail "explicit CI token was not selected: $ci_output"

install_workspace="$fixture/install-agent"
make_workspace "$install_workspace"
printf 'OTHER_API_TOKEN=preserve-me\n' > "$install_workspace/.env"
chmod 600 "$install_workspace/.env"
printf '%s\n' "$fixture_pat_a" | AGENT_DIRECTORY_ROOT="$install_workspace"   /bin/bash "$tool_root/setup-github-auth.sh" --install-token >/dev/null ||   fail 'workspace token install failed'
grep -Fqx 'OTHER_API_TOKEN=preserve-me' "$install_workspace/.env" ||   fail 'workspace token install did not preserve another Agent variable'
grep -q '^GH_TOKEN=' "$install_workspace/.env" || fail 'workspace token install omitted GH_TOKEN'
[[ "$(stat -f '%Lp' "$install_workspace/.env" 2>/dev/null || stat -c '%a' "$install_workspace/.env")" == 600 ]] ||   fail 'workspace token install did not enforce mode 600'

ready_output="$(AGENT_DIRECTORY_ROOT="$install_workspace" /bin/bash   "$tool_root/setup-github-auth.sh" --workspace-ready --remote backup --operation git-push 2>&1)" ||   fail "workspace-ready failed: $ready_output"
[[ "$ready_output" == *'GITHUB_WORKSPACE_READY source=workspace-env'* &&
  "$ready_output" == *'workspace_scoped=yes'* ]] || fail "workspace-ready output drifted: $ready_output"

for scenario in   'api|HTTP 401: Bad credentials|github-authentication-failed'   'api|HTTP 403: Resource not accessible by personal access token|github-authorization-failed'   'git|Write access to repository not granted|github-authorization-failed'   'git|Operation not permitted|runtime-denied'   'git|Failed to connect to github.com port 443|github-network-failure'; do
  kind="${scenario%%|*}"
  rest="${scenario#*|}"
  message="${rest%|*}"
  expected="${scenario##*|}"
  if [[ "$kind" == api ]]; then
    actual="$(/bin/bash -c '. "$1"; github_auth_classify_api_error "$2"' _ "$auth_lib" "$message")"
  else
    actual="$(/bin/bash -c '. "$1"; github_auth_classify_git_error "$2" 1' _ "$auth_lib" "$message")"
  fi
  [[ "$actual" == "$expected" ]] || fail "classification drifted: expected=$expected actual=$actual"
done

if (( failures > 0 )); then
  exit "$failures"
fi
printf 'GITHUB_AUTH_TEST_OK source=workspace-env workspace_isolation=ok registered_owner=ok dotenv=ok setup=ok diagnostics=ok\n'
