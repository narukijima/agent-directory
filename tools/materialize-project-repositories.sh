#!/usr/bin/env bash
set -euo pipefail

# Reproduce a normal clone into the Project root projects/<name>/ from the
# projects/REPOSITORIES.md registration and its adopted revision. Existing clones are
# only verified, never reshaped with reset/clean/stash/merge/rebase.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${AGENT_DIRECTORY_ROOT:-$tool_root/..}" 2>/dev/null && pwd -P)" || repo_root=''
. "$tool_root/lib/project-registry.sh"
. "$tool_root/lib/github-auth.sh"
registry_path='projects/REPOSITORIES.md'
ignore_path='projects/.gitignore'
select_all=false
only_project=''
check_only=false
pending_target=''
# Local bare remotes are allowed only for isolated fixture verification; never set in normal operation.
allow_local_repository_url="${AGENT_ALLOW_LOCAL_REPOSITORY_URL:-false}"

usage() {
  printf 'Usage: %s (--all | --project <name>) [--check]\n' "${0##*/}" >&2
}

blocked() {
  local reason="$1"
  local project="$2"
  local detail
  shift 2
  printf 'MATERIALIZATION_BLOCKED reason=%s project=%s\n' "$reason" "$project" >&2
  for detail in "$@"; do
    [[ -n "$detail" ]] || continue
    printf 'DETAIL: %s\n' "$detail" >&2
  done
  exit 1
}

# Clean up only a fresh clone that failed midway. Never delete anything other than the Project root.
cleanup() {
  local status=$?
  if (( status != 0 )) && [[ -n "$pending_target" && -d "$pending_target" ]]; then
    case "$pending_target" in
      */*/*) ;;
      *) return 0 ;;
    esac
    case "${pending_target#"$repo_root"/projects/}" in
      */*|'') return 0 ;;
    esac
    case "$pending_target" in
      "$repo_root"/projects/*) rm -rf -- "$pending_target" ;;
    esac
  fi
}
trap cleanup EXIT

# Emit each `/<name>/` line registered in the managed block of projects/.gitignore.
ignore_block_entries() {
  [[ -f "$1" ]] || return 0
  awk '
    $0 == "# BEGIN INDEPENDENT PROJECTS" { in_block = 1; next }
    $0 == "# END INDEPENDENT PROJECTS" { in_block = 0; next }
    in_block && $0 != "" { print }
  ' "$1"
}

# Registration already rejects these, but on reporting paths still redact the password in
# `://user:pass@` and scp-style `user:pass@host`, plus query and fragment. A clone's actual
# origin URL has not passed registration validation.
redact_repository_url() {
  printf '%s' "$1" | \
    sed -E 's|(://[^/:@]+):[^/@]*@|\1:***@|; s|^([^/:@]+):[^/@]+@|\1:***@|; s|\?.*$|?***|; s|#.*$|#***|'
}

# Classify the cause from failure output so we never hang on an authentication prompt.
classify_remote_failure() {
  local output="$1" status="${2:-1}" repository_url="${3:-}"
  if [[ "$(github_auth_remote_kind "$repository_url")" == github-https ]]; then
    github_auth_classify_git_error "$output" "$status"
  elif printf '%s\n' "$output" | grep -Eqi \
    'authentication|could not read Username|could not read Password|terminal prompts disabled|invalid username or password|access denied'; then
    printf 'authentication-required'
  elif printf '%s\n' "$output" | grep -Eqi 'permission denied \(publickey\)'; then
    printf 'git-transport-mismatch'
  else
    printf 'remote-unreachable'
  fi
}

require_github_materialization() {
  local repository_url="$1" project_name="$2" repository
  [[ "$(github_auth_remote_kind "$repository_url")" == github-https ]] || return 0
  repository="$(github_auth_repository_from_url "$repository_url")" || \
    blocked 'github-remote-invalid' "$project_name" 'registered GitHub remote is not a credential-free HTTPS repository URL'
  GITHUB_AUTH_REMOTE_RESOLVED='yes'
  if ! github_auth_resolve "$repo_root" "$repository" git-read; then
    github_auth_diagnostic git-read "$repository" origin github-https 90 >&2
    blocked "${GITHUB_AUTH_REASON:-github-unknown-failure}" "$project_name" \
      'GitHub materialization requires the current Agent root .env credential immediately before clone/fetch'
  fi
}

run_remote_git() {
  local repository_url="$1"
  shift
  if [[ "$(github_auth_remote_kind "$repository_url")" == github-https ]]; then
    github_git_run "$repo_root" "$repository_url" git-read "$@"
  else
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GCM_INTERACTIVE=never git "$@"
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --all) select_all=true; shift ;;
    --project)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      only_project="$2"
      shift 2
      ;;
    --check) check_only=true; shift ;;
    *) usage; exit 2 ;;
  esac
done

if [[ "$select_all" == true && -n "$only_project" ]]; then
  usage
  exit 2
fi
if [[ "$select_all" != true && -z "$only_project" ]]; then
  usage
  exit 2
fi
if [[ -n "$only_project" ]] && { [[ ! "$only_project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
  [[ "$only_project" == '.' || "$only_project" == '..' ]]; }; then
  printf 'ERROR: --project must be a plain Project directory name\n' >&2
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'ERROR: Git is required\n' >&2
  exit 2
fi

[[ -n "$repo_root" ]] || blocked 'not-agent-directory-root' '-' \
  "repository root does not exist: ${AGENT_DIRECTORY_ROOT:-$tool_root/..}"

git_top=''
if ! git_top="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
  blocked 'not-agent-directory-root' '-' "not inside a Git working tree: $repo_root"
fi
git_top="$(cd "$git_top" && pwd -P)"
if [[ "$git_top" != "$repo_root" ]]; then
  blocked 'not-agent-directory-root' '-' "run from the repository root: $git_top != $repo_root"
fi
if [[ ! -f "$repo_root/AGENTS.md" || ! -f "$repo_root/tools/validate-agent-directory.sh" ]]; then
  blocked 'not-agent-directory-root' '-' \
    "AGENTS.md and tools/validate-agent-directory.sh are required at $repo_root"
fi
[[ -f "$repo_root/$registry_path" ]] || blocked 'invalid-registry' '-' \
  "$registry_path is required; an empty registry is valid but the file must exist"

# --- Load the registry and run static checks -------------------------------------

registry_names=()
registry_urls=()
registry_reasons=()
registry_revisions=()
registry_roles=()

while IFS=$'\t' read -r record_kind field_a field_b field_c field_d field_e; do
  [[ -n "$record_kind" ]] || continue
  if [[ "$record_kind" == 'E' ]]; then
    blocked 'invalid-registry' '-' "$registry_path: $field_a"
  fi
  registry_names+=("$field_a")
  registry_urls+=("$field_b")
  registry_reasons+=("$field_c")
  registry_revisions+=("$field_d")
  registry_roles+=("$field_e")
done < <(agent_registry_records "$repo_root/$registry_path")

registry_count="${#registry_names[@]}"

ignore_entries=''
if (( registry_count > 0 )) || [[ -f "$repo_root/$ignore_path" ]]; then
  ignore_entries="$(ignore_block_entries "$repo_root/$ignore_path")"
fi

entry_index=0
while (( entry_index < registry_count )); do
  entry_name="${registry_names[$entry_index]}"
  entry_url="${registry_urls[$entry_index]}"
  entry_reason="${registry_reasons[$entry_index]}"
  entry_revision="${registry_revisions[$entry_index]}"
  entry_role="${registry_roles[$entry_index]}"

  case "$entry_reason" in
    automation|distribution|collaboration|access|identity|upstream|retention) ;;
    *) blocked 'invalid-registry' "$entry_name" \
      "$registry_path has an invalid repository_reason: ${entry_reason:-<empty>}" ;;
  esac
  if agent_repository_url_is_rejected "$entry_url" "$allow_local_repository_url"; then
    blocked 'invalid-registry' "$entry_name" \
      "$registry_path repository_url must be a credential-free remote URL without query, fragment or local path: $(redact_repository_url "$entry_url")"
  fi
  [[ "$entry_revision" =~ ^[0-9a-f]{40}$ ]] || blocked 'invalid-registry' "$entry_name" \
    "$registry_path revision must be a 40-character lowercase commit SHA"
  case "$entry_role" in
    project|public-foundation) ;;
    *) blocked 'invalid-registry' "$entry_name" \
      "$registry_path has an invalid repository_role: ${entry_role:-<empty>}" ;;
  esac
  printf '%s\n' "$ignore_entries" | grep -Fqx "/$entry_name/" || \
    blocked 'invalid-ignore-projection' "$entry_name" \
      "$ignore_path managed block must contain the exact line: /$entry_name/"
  entry_index=$((entry_index + 1))
done

while IFS= read -r ignore_entry; do
  [[ -n "$ignore_entry" ]] || continue
  ignore_name="${ignore_entry#/}"
  ignore_name="${ignore_name%/}"
  entry_index=0
  found_ignore=false
  while (( entry_index < registry_count )); do
    [[ "${registry_names[$entry_index]}" != "$ignore_name" ]] || found_ignore=true
    entry_index=$((entry_index + 1))
  done
  [[ "$found_ignore" == true ]] || blocked 'invalid-ignore-projection' "$ignore_name" \
    "$ignore_path managed block holds $ignore_entry, which is not registered in $registry_path"
done < <(printf '%s\n' "$ignore_entries")

if [[ -n "$only_project" ]]; then
  entry_index=0
  found_project=false
  while (( entry_index < registry_count )); do
    [[ "${registry_names[$entry_index]}" != "$only_project" ]] || found_project=true
    entry_index=$((entry_index + 1))
  done
  [[ "$found_project" == true ]] || blocked 'invalid-project' "$only_project" \
    "projects/$only_project is not registered in $registry_path"
fi

# --- Materialization and verification of existing targets ------------------------

total=0
cloned=0
verified=0
entry_index=0

while (( entry_index < registry_count )); do
  project_name="${registry_names[$entry_index]}"
  repository_url="${registry_urls[$entry_index]}"
  state_revision="${registry_revisions[$entry_index]}"
  repository_role="${registry_roles[$entry_index]}"
  entry_index=$((entry_index + 1))
  [[ -z "$only_project" || "$project_name" == "$only_project" ]] || continue

  total=$((total + 1))
  project_dir="projects/$project_name"
  target="$repo_root/$project_dir"
  [[ ! -L "$repo_root/projects" ]] || blocked 'target-path-symlink' "$project_name" \
    'projects/ must be a real directory, not a symlink'
  [[ ! -L "$target" ]] || blocked 'target-path-symlink' "$project_name" \
    "$project_dir must be a real directory, not a symlink"

  if [[ -e "$target" ]]; then
    [[ -d "$target" ]] || blocked 'target-not-empty' "$project_name" \
      "$project_dir exists but is not a directory"
    [[ ! -L "$target/.git" ]] || blocked 'target-path-symlink' "$project_name" \
      "$project_dir/.git must be a real directory, not a symlink"
    if [[ -e "$target/.git" && ! -d "$target/.git" ]]; then
      blocked 'repository-gitfile-unsupported' "$project_name" \
        "$project_dir/.git must be a real directory; .git files and worktrees are unsupported"
    fi
    if [[ ! -d "$target/.git" ]]; then
      if [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        blocked 'target-not-empty' "$project_name" \
          "$project_dir is not empty and is not a Git repository"
      fi
    fi
  fi

  if [[ -d "$target/.git" ]]; then
    child_top=''
    if ! child_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
      blocked 'repository-gitfile-unsupported' "$project_name" \
        "$project_dir does not resolve to a Git working tree"
    fi
    child_top="$(cd "$child_top" && pwd -P)"
    [[ "$child_top" == "$target" ]] || blocked 'repository-toplevel-mismatch' "$project_name" \
      "$project_dir toplevel is $child_top, expected $target"

    child_origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
    [[ "$child_origin" == "$repository_url" ]] || blocked 'repository-origin-mismatch' "$project_name" \
      "remote.origin.url is $(redact_repository_url "${child_origin:-<unset>}"), expected $(redact_repository_url "$repository_url")"

    git -C "$target" diff --cached --quiet -- || blocked 'repository-staged' "$project_name" \
      "$project_dir holds staged changes; resolve them in an Independent session"
    git -C "$target" diff --quiet -- || blocked 'repository-dirty' "$project_name" \
      "$project_dir holds uncommitted tracked changes; resolve them in an Independent session"
    child_untracked="$(git -C "$target" ls-files --others --exclude-standard)"
    [[ -z "$child_untracked" ]] || blocked 'repository-untracked' "$project_name" \
      "$project_dir holds untracked files" "$(printf '%s\n' "$child_untracked" | head -n 10)"
    if git -C "$target" rev-parse --verify --quiet refs/stash >/dev/null; then
      blocked 'repository-stash-present' "$project_name" \
        "$project_dir holds stash entries; resolve them in an Independent session"
    fi
    git -C "$target" cat-file -e "${state_revision}^{commit}" 2>/dev/null || \
      blocked 'revision-unavailable' "$project_name" \
        "the adopted revision is missing from the existing clone: $state_revision"
    # The adopted revision merely existing in the clone is not enough; verify that HEAD is
    # pinned to it. Working on a branch and adopting its tip is a valid workflow, so a
    # detached HEAD is not required.
    child_head="$(git -C "$target" rev-parse --verify --quiet HEAD || true)"
    [[ "$child_head" == "$state_revision" ]] || \
      blocked 'repository-head-not-adopted' "$project_name" \
        "$project_dir HEAD is ${child_head:-none}, but $registry_path adopts $state_revision"
    if [[ "$repository_role" == 'project' ]]; then
      for contract_file in PROJECT.md STATE.md; do
        git -C "$target" cat-file -e "${state_revision}:${contract_file}" 2>/dev/null || \
          blocked 'repository-contract-missing' "$project_name" \
            "$project_dir does not carry $contract_file at the adopted revision $state_revision"
      done
    fi

    verified=$((verified + 1))
    continue
  fi

  if [[ "$check_only" == true ]]; then
    blocked 'missing-independent-repository' "$project_name" \
      "$project_dir is missing; run without --check to materialize it"
  fi

  pending_target="$target"
  require_github_materialization "$repository_url" "$project_name"
  clone_output=''
  clone_status=0
  clone_output="$(run_remote_git "$repository_url" clone --quiet --no-checkout -- "$repository_url" "$target" 2>&1)" || clone_status=$?
  if (( clone_status != 0 )); then
    blocked "$(classify_remote_failure "$clone_output" "$clone_status" "$repository_url")" "$project_name" \
      "could not clone $(redact_repository_url "$repository_url") into $project_dir" "$clone_output"
  fi

  [[ -d "$target/.git" && ! -L "$target/.git" ]] || blocked 'repository-gitfile-unsupported' \
    "$project_name" "$project_dir/.git must be a real directory after cloning"
  cloned_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$cloned_top" ]] && cloned_top="$(cd "$cloned_top" && pwd -P)"
  [[ "$cloned_top" == "$target" ]] || blocked 'repository-toplevel-mismatch' "$project_name" \
    "$project_dir toplevel is ${cloned_top:-<unset>}, expected $target"
  cloned_origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
  [[ "$cloned_origin" == "$repository_url" ]] || blocked 'repository-origin-mismatch' "$project_name" \
    "remote.origin.url is $(redact_repository_url "${cloned_origin:-<unset>}"), expected $(redact_repository_url "$repository_url")"

  if ! git -C "$target" cat-file -e "${state_revision}^{commit}" 2>/dev/null; then
    require_github_materialization "$repository_url" "$project_name"
    fetch_output=''
    fetch_status=0
    fetch_output="$(run_remote_git "$repository_url" -C "$target" fetch --quiet --no-tags origin "$state_revision" 2>&1)" || fetch_status=$?
    if (( fetch_status != 0 )); then
      blocked "$(classify_remote_failure "$fetch_output" "$fetch_status" "$repository_url")" "$project_name" \
        "the adopted revision is not fetchable from $(redact_repository_url "$repository_url"): $state_revision" \
        "$fetch_output"
    fi
    git -C "$target" cat-file -e "${state_revision}^{commit}" 2>/dev/null || \
      blocked 'revision-unavailable' "$project_name" \
        "the adopted revision did not resolve to a commit: $state_revision"
  fi

  # Reproduce only the adopted revision, detached, not the branch's current tip.
  checkout_output=''
  if ! checkout_output="$(git -C "$target" checkout --quiet --detach "$state_revision" 2>&1)"; then
    blocked 'revision-unavailable' "$project_name" \
      "could not check out the adopted revision: $state_revision" "$checkout_output"
  fi
  cloned_head="$(git -C "$target" rev-parse --verify --quiet HEAD || true)"
  [[ "$cloned_head" == "$state_revision" ]] || blocked 'repository-head-not-adopted' "$project_name" \
    "$project_dir HEAD is ${cloned_head:-none}, but $registry_path adopts $state_revision"
  if [[ "$repository_role" == 'project' ]]; then
    for contract_file in PROJECT.md STATE.md; do
      [[ -f "$target/$contract_file" ]] || blocked 'repository-contract-missing' "$project_name" \
        "$project_dir does not carry $contract_file at the adopted revision $state_revision"
    done
  fi

  pending_target=''
  cloned=$((cloned + 1))
  printf 'DETAIL: materialized %s at %s\n' "$project_dir" "$state_revision" >&2
done

printf 'MATERIALIZATION_OK total=%s cloned=%s verified=%s\n' "$total" "$cloned" "$verified"
