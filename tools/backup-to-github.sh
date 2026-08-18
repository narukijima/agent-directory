#!/usr/bin/env bash
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${AGENT_DIRECTORY_ROOT:-$tool_root/..}" 2>/dev/null && pwd -P)" || repo_root=''
. "$tool_root/lib/project-registry.sh"
. "$tool_root/lib/github-auth.sh"
cache_dir="${AGENT_CACHE_DIR:-$repo_root/.agent-cache}"
registry_path='projects/REPOSITORIES.md'
ignore_path='projects/.gitignore'
max_blob_bytes="${AGENT_BACKUP_MAX_BLOB_BYTES:-104857600}"
remote='backup'
branch='main'
dry_run=false
root_only=false
fixed_commit=''
fixed_snapshot_root=''
independent_verify_root=''
independent_index=0
verify_repo=''
# Local bare remotes are allowed only for isolated fixture verification. Never set this in normal operation.
allow_local_repository_url="${AGENT_ALLOW_LOCAL_REPOSITORY_URL:-false}"
expected_login="${AGENT_DIRECTORY_GITHUB_EXPECTED_LOGIN:-}"

# Parallel arrays for the registered Independent Projects. bash 3.2 has no associative arrays.
independent_names=()
independent_urls=()
independent_revisions=()
independent_roles=()

usage() {
  printf 'Usage: %s [--remote <name>] [--branch <name>] [--dry-run] [--root-only] [--fixed-commit <full-sha>]\n' "${0##*/}" >&2
}

blocked() {
  local reason="$1"
  local detail
  shift
  printf 'BACKUP_BLOCKED reason=%s\n' "$reason" >&2
  for detail in "$@"; do
    [[ -n "$detail" ]] || continue
    printf 'DETAIL: %s\n' "$detail" >&2
  done
  exit 1
}

note() {
  printf 'DETAIL: %s\n' "$1" >&2
}

ensure_github_remote_auth() {
  local workspace_root="$1" remote_name="$2" remote_url_value="$3" repository reason
  [[ "$(github_auth_remote_kind "$remote_url_value")" == 'github-https' ]] || return 0
  repository="$(github_auth_repository_from_url "$remote_url_value")" || \
    blocked github-remote-invalid
  if github_auth_probe_api "$expected_login" "$workspace_root" "$repository" && \
    github_auth_resolve "$workspace_root" "$repository" git-push && \
    github_auth_probe_git "$workspace_root" "$remote_url_value"; then
    return 0
  fi
  reason="${GITHUB_AUTH_REASON:-github-unknown-failure}"
  github_auth_diagnostic "${GITHUB_AUTH_OPERATION:-git-push}" "$repository" "$remote_name" github-https \
    "${GITHUB_AUTH_LAST_STATUS:-1}" >&2
  blocked "$reason" 'machine setup and normal tasks are separate; run the documented Operator setup/check without starting an interactive login or fallback'
}

backup_remote_failure_reason() {
  local output="$1" fallback="$2" remote_url_value="$3"
  if [[ "$(github_auth_remote_kind "$remote_url_value")" == 'github-https' ]]; then
    github_auth_classify_git_error "$output"
  else
    printf '%s' "$fallback"
  fi
}

# --- backup checkpoint (derived local state) ------------------------------------
# The checkpoint records the last remote-verified backup SHA in .agent-cache/ so the
# next run audits only the new objects since it. It is a deletable derivative, never
# canon: any missing, corrupt, or mismatching field (remote, URL, branch, SHA, local
# reachability, ancestry) falls back safely to the full-history object scan. It never
# substitutes for the push's own fast-forward guarantee or the post-push verification.
checkpoint_sha=''

checkpoint_path() {
  printf '%s/backup-checkpoint-%s-%s' "$cache_dir" "$remote" "$(printf '%s' "$branch" | tr '/' '_')"
}

# The checkpoint never stores the remote URL itself (it may carry userinfo); only a
# deterministic hash of the URL is stored and compared.
checkpoint_url_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$remote_url" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$remote_url" | cksum | awk '{print $1 "-" $2}'
  fi
}

load_backup_checkpoint() {
  local file sha stored
  file="$(checkpoint_path)"
  [[ -f "$file" ]] || return 0
  grep -Fqx 'schema_version=2' "$file" 2>/dev/null || return 0
  stored="$(sed -n 's/^remote=//p' "$file" | head -n 1)"
  [[ "$stored" == "$remote" ]] || return 0
  stored="$(sed -n 's/^url_hash=//p' "$file" | head -n 1)"
  [[ "$stored" == "$(checkpoint_url_hash)" ]] || return 0
  stored="$(sed -n 's/^branch=//p' "$file" | head -n 1)"
  [[ "$stored" == "$branch" ]] || return 0
  sha="$(sed -n 's/^sha=//p' "$file" | head -n 1)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  git -C "$repo_root" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
  git -C "$repo_root" merge-base --is-ancestor "$sha" "$local_head" 2>/dev/null || return 0
  checkpoint_sha="$sha"
}

write_backup_checkpoint() {
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  {
    printf 'schema_version=2\n'
    printf 'remote=%s\n' "$remote"
    printf 'url_hash=%s\n' "$(checkpoint_url_hash)"
    printf 'branch=%s\n' "$branch"
    printf 'sha=%s\n' "$local_head"
  } > "$(checkpoint_path)" 2>/dev/null || true
}

ensure_root_head_unchanged() {
  local current_ref current_sha
  current_ref="$(git -C "$repo_root" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  current_sha="$(git -C "$repo_root" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  if [[ "$current_ref" != "$head_ref" || "$current_sha" != "$local_head" ]]; then
    blocked 'head-moved-during-backup' \
      "audited=$local_head current=${current_sha:-none}" \
      'the root HEAD changed after the backup audit started; rerun against the new clean state'
  fi
}

ensure_no_unreachable_local_branches() {
  local local_branch unmerged=''
  while IFS= read -r local_branch; do
    [[ -n "$local_branch" && "$local_branch" != "$branch" ]] || continue
    if ! git -C "$repo_root" merge-base --is-ancestor "refs/heads/$local_branch" "$local_head" 2>/dev/null; then
      unmerged="$unmerged $local_branch"
    fi
  done < <(git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads/)
  if [[ -n "$unmerged" ]]; then
    blocked 'unreachable-local-branch' \
      "these local branches are not reachable from $branch and would not be backed up:$unmerged"
  fi
}

frontmatter_key_count() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 { count++ }
    END { print count + 0 }
  ' "$1"
}

# Emit each `/<name>/` entry registered in the projects/.gitignore managed block, one per line.
ignore_block_entries() {
  [[ -f "$1" ]] || return 0
  awk '
    $0 == "# BEGIN INDEPENDENT PROJECTS" { in_block = 1; next }
    $0 == "# END INDEPENDENT PROJECTS" { in_block = 0; next }
    in_block && $0 != "" { print }
  ' "$1"
}

# Registration already rejects these, but DETAIL lines still mask the password, query and
# fragment of `://user:pass@` and scp-style `user:pass@host`; a clone's actual origin URL has not passed registration validation.
redact_repository_url() {
  printf '%s' "$1" | \
    sed -E 's|(://[^/:@]+):[^/@]*@|\1:***@|; s|^([^/:@]+):[^/@]+@|\1:***@|; s|\?.*$|?***|; s|#.*$|#***|'
}

cleanup() {
  if [[ -n "$independent_verify_root" && -d "$independent_verify_root" ]]; then
    rm -rf -- "$independent_verify_root"
  fi
  if [[ -n "$fixed_snapshot_root" && -d "$fixed_snapshot_root" ]]; then
    rm -rf -- "$fixed_snapshot_root"
  fi
}
trap cleanup EXIT

# --- static checks on the registry and the ignore projection -------------------

load_independent_registry() {
  local record_kind field_a field_b field_c field_d field_e
  local ignore_entries ignore_entry ignore_name entry_index found

  [[ -f "$repo_root/$registry_path" ]] || blocked 'invalid-registry' \
    "$registry_path is required; an empty registry is valid but the file must exist"

  while IFS=$'\t' read -r record_kind field_a field_b field_c field_d field_e; do
    [[ -n "$record_kind" ]] || continue
    [[ "$record_kind" != 'E' ]] || blocked 'invalid-registry' "$registry_path: $field_a"
    case "$field_c" in
      automation|distribution|collaboration|access|identity|upstream|retention) ;;
      *) blocked 'invalid-registry' \
        "$registry_path entry \`$field_a\` has an invalid repository_reason: ${field_c:-<empty>}" ;;
    esac
    if agent_repository_url_is_rejected "$field_b" "$allow_local_repository_url"; then
      blocked 'invalid-registry' \
        "$registry_path entry \`$field_a\` repository_url must be a credential-free remote URL without query, fragment or local path: $(redact_repository_url "$field_b")"
    fi
    [[ "$field_d" =~ ^[0-9a-f]{40}$ ]] || blocked 'invalid-registry' \
      "$registry_path entry \`$field_a\` revision must be a 40-character lowercase commit SHA"
    case "$field_e" in
      project|public-foundation) ;;
      *) blocked 'invalid-registry' \
        "$registry_path entry \`$field_a\` has an invalid repository_role: ${field_e:-<empty>}" ;;
    esac
    independent_names+=("$field_a")
    independent_urls+=("$field_b")
    independent_revisions+=("$field_d")
    independent_roles+=("$field_e")
  done < <(agent_registry_records "$repo_root/$registry_path")

  ignore_entries="$(ignore_block_entries "$repo_root/$ignore_path")"
  entry_index=0
  while (( entry_index < ${#independent_names[@]} )); do
    printf '%s\n' "$ignore_entries" | grep -Fqx "/${independent_names[$entry_index]}/" || \
      blocked 'invalid-ignore-projection' \
        "$ignore_path managed block must contain the exact line: /${independent_names[$entry_index]}/"
    entry_index=$((entry_index + 1))
  done
  while IFS= read -r ignore_entry; do
    [[ -n "$ignore_entry" ]] || continue
    ignore_name="${ignore_entry#/}"
    ignore_name="${ignore_name%/}"
    entry_index=0
    found=false
    while (( entry_index < ${#independent_names[@]} )); do
      [[ "${independent_names[$entry_index]}" != "$ignore_name" ]] || found=true
      entry_index=$((entry_index + 1))
    done
    [[ "$found" == true ]] || blocked 'invalid-ignore-projection' \
      "$ignore_path managed block holds $ignore_entry, which is not registered in $registry_path"
  done < <(printf '%s\n' "$ignore_entries")
}

# Stop the retired `projects/<name>/repository/` layout and retired frontmatter by name, before nested-git and similar checks.
detect_deprecated_layout() {
  local project_md project_dir retired_key legacy_dir legacy_tracked

  legacy_tracked="$(git -C "$repo_root" ls-files -- \
    'projects/*/repository' 'projects/*/repository/*' | sed -n '1,5p')"
  [[ -z "$legacy_tracked" ]] || blocked 'deprecated-repository-layout' \
    'the retired projects/<name>/repository/ layout is still tracked; migrate it per tools/BACKUP.md' \
    "$legacy_tracked"
  legacy_dir="$(find "$repo_root/projects" -mindepth 3 -maxdepth 3 -type d \
    -path '*/repository/.git' -print 2>/dev/null | sed -n '1,5p')"
  [[ -z "$legacy_dir" ]] || blocked 'deprecated-repository-layout' \
    'a clone still lives at the retired projects/<name>/repository/ path; migrate it per tools/BACKUP.md' \
    "$legacy_dir"

  while IFS= read -r project_md; do
    [[ -n "$project_md" && -f "$repo_root/$project_md" ]] || continue
    project_dir="${project_md%/PROJECT.md}"
    for retired_key in repository_mode repository_url repository_reason repository_default_branch; do
      [[ "$(frontmatter_key_count "$repo_root/$project_md" "$retired_key")" == '0' ]] || \
        blocked 'deprecated-repository-layout' \
          "$project_md still declares the retired $retired_key field; attachment now lives in $registry_path"
    done
    if [[ -f "$repo_root/$project_dir/STATE.md" ]] && \
      grep -Fqx '## Repository State' "$repo_root/$project_dir/STATE.md"; then
      blocked 'deprecated-repository-layout' \
        "$project_dir/STATE.md still declares the retired ## Repository State section; the adopted revision lives in $registry_path"
    fi
  done < <(git -C "$repo_root" ls-files -- 'projects/*/PROJECT.md')
}

# --- attachment checks at the Project root -------------------------------------

validate_independent_attachment() {
  local project_name="$1"
  local repository_url="$2"
  local project_dir="projects/$project_name"
  local target="$repo_root/$project_dir"
  local child_top child_origin

  [[ ! -L "$target" ]] || blocked 'repository-path-symlink' \
    "$project_dir must be a real directory, not a symlink"
  [[ -d "$target" ]] || blocked 'missing-independent-repository' \
    "$project_dir is missing; run tools/materialize-project-repositories.sh --all"
  [[ ! -L "$target/.git" ]] || blocked 'repository-path-symlink' \
    "$project_dir/.git must be a real directory, not a symlink"
  if [[ ! -d "$target/.git" ]]; then
    blocked 'repository-gitfile-unsupported' \
      "$project_dir/.git must be a real directory; .git files and worktrees are unsupported"
  fi

  if ! child_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
    blocked 'repository-toplevel-mismatch' "$project_dir is not a Git working tree"
  fi
  child_top="$(cd "$child_top" && pwd -P)"
  [[ "$child_top" == "$target" ]] || blocked 'repository-toplevel-mismatch' \
    "$project_dir toplevel is $child_top, expected $target"

  child_origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
  [[ "$child_origin" == "$repository_url" ]] || blocked 'repository-origin-mismatch' \
    "$project_dir remote.origin.url is $(redact_repository_url "${child_origin:-<unset>}"), expected $(redact_repository_url "$repository_url")"
}

# --- local state audit of the Independent clone itself -------------------------

audit_independent_repository() {
  local project_name="$1"
  local repository_role="${2:-project}"
  local project_dir="projects/$project_name"
  local target="$repo_root/$project_dir"
  local child_untracked nested_child attributes_file contract_file

  # Detect structurally unsupported states first. They are stronger stop reasons than
  # cleanliness, and reporting them as untracked files would hide the real cause.
  if git -C "$target" ls-files --stage | awk '$1 == "160000" { found = 1 } END { exit !found }'; then
    blocked 'independent-submodule-unsupported' \
      "$project_dir contains submodules; their contents are not covered"
  fi
  [[ ! -e "$target/.gitmodules" ]] || blocked 'independent-submodule-unsupported' \
    "$project_dir declares .gitmodules; submodules are unsupported"

  nested_child="$(find "$target" -path "$target/.git" -prune -o \
    -mindepth 2 \( -type d -o -type f \) -name .git -print 2>/dev/null | sed -n '1,5p')"
  [[ -z "$nested_child" ]] || blocked 'independent-nested-repository' \
    "$project_dir contains a nested Git repository" "$nested_child"

  if [[ -f "$target/.gitattributes" ]] && grep -Fq 'filter=lfs' "$target/.gitattributes"; then
    blocked 'independent-git-lfs-unsupported' "$project_dir uses Git LFS: .gitattributes"
  fi
  while IFS= read -r attributes_file; do
    [[ -n "$attributes_file" && -f "$target/$attributes_file" ]] || continue
    if grep -Fq 'filter=lfs' "$target/$attributes_file"; then
      blocked 'independent-git-lfs-unsupported' "$project_dir uses Git LFS: $attributes_file"
    fi
  done < <(git -C "$target" ls-files -- '.gitattributes' '*/.gitattributes')

  if [[ "$repository_role" == 'project' ]]; then
    for contract_file in PROJECT.md STATE.md; do
      git -C "$target" cat-file -e "HEAD:$contract_file" 2>/dev/null || \
        blocked 'independent-contract-missing' \
          "$project_dir does not carry $contract_file at HEAD; the Project contract is owned by its own Git"
    done
  fi

  git -C "$target" diff --cached --quiet -- || blocked 'independent-staged-changes' \
    "$project_dir holds staged changes; commit or unstage them in an Independent session"
  git -C "$target" diff --quiet -- || blocked 'independent-dirty-working-tree' \
    "$project_dir holds uncommitted tracked changes; commit them in an Independent session"
  child_untracked="$(git -C "$target" ls-files --others --exclude-standard)"
  [[ -z "$child_untracked" ]] || blocked 'independent-untracked-files' \
    "$project_dir holds untracked non-ignored files" \
    "$(printf '%s\n' "$child_untracked" | head -n 10)"
  if git -C "$target" rev-parse --verify --quiet refs/stash >/dev/null; then
    blocked 'independent-stash-present' \
      "$project_dir holds stash entries; they are never sent to a remote"
  fi
}

# --- adopted revision and remote reachability ----------------------------------

# Judge reachability only through an isolated temporary bare repository, never by mutating the child clone.
verify_independent_revision() {
  local project_name="$1"
  local repository_url="$2"
  local state_revision="$3"
  local project_dir="projects/$project_name"
  local target="$repo_root/$project_dir"
  local head_sha fetch_output

  if [[ -z "$independent_verify_root" ]]; then
    independent_verify_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-independent-verify.XXXXXX")" || \
      blocked 'independent-remote-unreachable' \
        'could not create an isolated Independent verification directory'
  fi
  independent_index=$((independent_index + 1))
  verify_repo="$independent_verify_root/$independent_index.git"
  git init --bare -q "$verify_repo" || blocked 'independent-remote-unreachable' \
    "could not initialize the verification repository for $project_dir"

  ensure_github_remote_auth "$repo_root" "$repository_url" "$repository_url"
  if ! fetch_output="$(github_git_run "$repo_root" "$repository_url" git-read -C "$verify_repo" \
    fetch --quiet "$repository_url" \
    "+refs/heads/*:refs/remotes/upstream/*" "+refs/tags/*:refs/tags/*" 2>&1)"; then
    blocked "$(backup_remote_failure_reason "$fetch_output" independent-remote-unreachable "$repository_url")" \
      "$project_dir declared remote is unreachable: $(redact_repository_url "$repository_url")" \
      'the authenticated remote read failed'
  fi
  if ! fetch_output="$(github_git_run "$repo_root" "$repository_url" git-read -C "$verify_repo" \
    fetch --quiet --no-tags "$repository_url" "$state_revision" 2>&1)"; then
    blocked 'independent-revision-unavailable' \
      "$project_dir adopted revision is not fetchable from its declared remote: $state_revision" \
      'the authenticated revision read failed'
  fi
  git -C "$verify_repo" cat-file -e "${state_revision}^{commit}" 2>/dev/null || \
    blocked 'independent-revision-unavailable' \
      "$project_dir adopted revision did not resolve to a commit: $state_revision"

  # Confirm the adopted revision exists on the remote first, then check the clone is pinned to it.
  head_sha="$(git -C "$target" rev-parse --verify --quiet HEAD || true)"
  [[ "$head_sha" == "$state_revision" ]] || blocked 'independent-head-not-adopted' \
    "$project_dir HEAD is ${head_sha:-none}, but $registry_path adopts $state_revision"
}

verify_local_refs_backed_up() {
  local project_name="$1"
  local verify_repo="$2"
  local project_dir="projects/$project_name"
  local target="$repo_root/$project_dir"
  local fetch_output branch_ref branch_sha tag_ref tag_sha remote_tag_sha unpublished

  if ! fetch_output="$(github_git_run "$repo_root" "$target" git-read -C "$verify_repo" fetch --quiet --no-tags "$target" \
    "+refs/heads/*:refs/remotes/child/*" "+refs/tags/*:refs/childtags/*" "+HEAD:refs/childhead" 2>&1)"; then
    blocked 'independent-unreachable-local-branch' \
      "could not read local refs from $project_dir" "$fetch_output"
  fi

  # A failure of rev-list itself fails closed (treated as unpublished). Printing '0' would falsely claim recoverability.
  unpublished="$(git -C "$verify_repo" rev-list --count refs/childhead \
    --not --remotes=upstream --tags 2>/dev/null || printf '1')"
  [[ "$unpublished" == '0' ]] || blocked 'independent-unpushed-commit' \
    "$project_dir HEAD holds $unpublished commit(s) absent from its remote"

  while IFS=' ' read -r branch_ref branch_sha; do
    [[ -n "$branch_ref" && -n "$branch_sha" ]] || continue
    unpublished="$(git -C "$verify_repo" rev-list --count "$branch_sha" \
      --not --remotes=upstream --tags 2>/dev/null || printf '1')"
    [[ "$unpublished" == '0' ]] || blocked 'independent-unreachable-local-branch' \
      "$project_dir local branch ${branch_ref#child/} is not reachable from any remote head or tag"
  done < <(git -C "$verify_repo" for-each-ref --format='%(refname:short) %(objectname)' refs/remotes/child)

  while IFS=' ' read -r tag_ref tag_sha; do
    [[ -n "$tag_ref" && -n "$tag_sha" ]] || continue
    remote_tag_sha="$(git -C "$verify_repo" rev-parse --verify --quiet \
      "refs/tags/${tag_ref#childtags/}" || true)"
    [[ "$remote_tag_sha" == "$tag_sha" ]] || blocked 'independent-unpushed-tag' \
      "$project_dir tag ${tag_ref#childtags/} is missing or different on its remote"
  done < <(git -C "$verify_repo" for-each-ref --format='%(refname:short) %(objectname)' refs/childtags)
}

# --- ownership on the root side ------------------------------------------------

validate_root_repository_ownership() {
  local tracked_under_project gitlink_paths entry_index

  # Check gitlinks first, keeping their stop reason distinct from a plain-tracked file at the same path.
  gitlink_paths="$(git -C "$repo_root" ls-files --stage | awk '$1 == "160000" { print $4 }' | sed -n '1,10p')"
  [[ -z "$gitlink_paths" ]] || blocked 'unsupported-root-gitlink' \
    'the root index holds a gitlink; Independent repositories are plain clones, not submodules' \
    "$gitlink_paths"

  entry_index=0
  while (( entry_index < ${#independent_names[@]} )); do
    tracked_under_project="$(git -C "$repo_root" ls-files -- \
      "projects/${independent_names[$entry_index]}" | sed -n '1,10p')"
    [[ -z "$tracked_under_project" ]] || blocked 'root-tracks-independent-repository' \
      "the root repository must not track anything under projects/${independent_names[$entry_index]}/" \
      "$tracked_under_project"
    entry_index=$((entry_index + 1))
  done

  if git -C "$repo_root" ls-files --error-unmatch -- '.gitmodules' >/dev/null 2>&1; then
    blocked 'unsupported-submodule' 'submodule contents are not covered by this backup; resolve manually'
  fi
}

# --- 1. options ----------------------------------------------------------------

while (( $# > 0 )); do
  case "$1" in
    --remote|--branch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      case "$1" in
        --remote) remote="$2" ;;
        --branch) branch="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    --root-only) root_only=true; shift ;;
    --fixed-commit)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      fixed_commit="$2"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

if [[ ! "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'ERROR: --remote must be a simple remote name\n' >&2
  exit 2
fi
if [[ ! "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
  printf 'ERROR: --branch must be a simple branch name\n' >&2
  exit 2
fi
if [[ ! "$max_blob_bytes" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ERROR: AGENT_BACKUP_MAX_BLOB_BYTES must be a positive integer\n' >&2
  exit 2
fi
if [[ -n "$fixed_commit" ]]; then
  [[ "$root_only" == true ]] || {
    printf 'ERROR: --fixed-commit is restricted to --root-only\n' >&2
    exit 2
  }
  [[ "$fixed_commit" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'ERROR: --fixed-commit requires a full 40-character lowercase commit SHA\n' >&2
    exit 2
  }
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'ERROR: Git is required\n' >&2
  exit 2
fi

# --- 2. root detection ----------------------------------------------------------

[[ -n "$repo_root" ]] || blocked 'not-agent-directory-root' \
  "repository root does not exist: ${AGENT_DIRECTORY_ROOT:-$tool_root/..}"

git_top=''
if ! git_top="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
  blocked 'not-git-repository' "not inside a Git working tree: $repo_root"
fi
git_top="$(cd "$git_top" && pwd -P)"
if [[ "$git_top" != "$repo_root" ]]; then
  blocked 'not-agent-directory-root' "run from the repository root: $git_top != $repo_root"
fi
if [[ ! -f "$repo_root/AGENTS.md" || ! -f "$repo_root/tools/validate-agent-directory.sh" ]]; then
  blocked 'not-agent-directory-root' "AGENTS.md and tools/validate-agent-directory.sh are required at $repo_root"
fi

# --- 3. branch / remote ----------------------------------------------------------

head_ref=''
if ! head_ref="$(git -C "$repo_root" symbolic-ref --quiet HEAD 2>/dev/null)"; then
  blocked 'detached-head' 'HEAD is detached; check out the backup branch first'
fi
current_branch="${head_ref#refs/heads/}"
if [[ "$current_branch" != "$branch" ]]; then
  blocked 'branch-mismatch' "current branch is $current_branch, expected $branch"
fi

local_head=''
if ! local_head="$(git -C "$repo_root" rev-parse --verify --quiet HEAD)" || [[ -z "$local_head" ]]; then
  blocked 'empty-history' "$branch has no commit to back up"
fi

remote_url=''
if ! remote_url="$(git -C "$repo_root" config --get "remote.$remote.url" 2>/dev/null)"; then
  blocked 'missing-remote' "remote is not configured: $remote"
fi

# A normal raw backup continues to require a clean repository. The standard finish path
# may, however, have committed one verified target while another separable target remains
# dirty. In that narrow root-only case, audit and push an isolated clone of the exact HEAD
# commit. This excludes the caller's index, worktree, untracked files, and stash without
# mutating or hiding any of them, while reusing every ordinary backup check on committed bytes.
if [[ -n "$fixed_commit" ]]; then
  if [[ "$fixed_commit" != "$local_head" ]]; then
    blocked 'fixed-commit-mismatch' "requested=$fixed_commit head=$local_head" \
      'the finish-bound commit must still be the exact current branch HEAD'
  fi
  ensure_no_unreachable_local_branches
  fixed_snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-backup-fixed.XXXXXX")"
  if ! git -C "$fixed_snapshot_root" init -q 2>/dev/null || \
    ! git -C "$fixed_snapshot_root" fetch -q "$repo_root" \
      "refs/heads/$branch:refs/heads/$branch" 2>/dev/null || \
    ! git -C "$fixed_snapshot_root" symbolic-ref HEAD "refs/heads/$branch" 2>/dev/null || \
    ! git -C "$fixed_snapshot_root" read-tree "$fixed_commit" 2>/dev/null || \
    ! git -C "$repo_root" archive "$fixed_commit" | tar -x -C "$fixed_snapshot_root"; then
    blocked 'fixed-commit-snapshot-failed' \
      'could not create an isolated committed-tree snapshot for backup audit'
  fi
  if [[ "$(git -C "$fixed_snapshot_root" rev-parse HEAD 2>/dev/null || true)" != "$fixed_commit" ]]; then
    blocked 'fixed-commit-snapshot-mismatch' \
      'the isolated snapshot does not resolve to the finish-bound commit'
  fi
  git -C "$fixed_snapshot_root" config "remote.$remote.url" "$remote_url"

  original_checkpoint="$(checkpoint_path)"
  snapshot_cache="$fixed_snapshot_root/.agent-cache"
  snapshot_checkpoint="$snapshot_cache/${original_checkpoint##*/}"
  if [[ -f "$original_checkpoint" ]]; then
    mkdir -p "$snapshot_cache"
    cp "$original_checkpoint" "$snapshot_checkpoint"
  fi

  note "fixed commit audit: $fixed_commit (caller worktree state excluded and preserved)"
  fixed_args=( --remote "$remote" --branch "$branch" --root-only )
  [[ "$dry_run" != true ]] || fixed_args+=( --dry-run )
  set +e
  AGENT_DIRECTORY_ROOT="$fixed_snapshot_root" AGENT_CACHE_DIR="$snapshot_cache" \
    bash "$fixed_snapshot_root/tools/backup-to-github.sh" "${fixed_args[@]}"
  fixed_status=$?
  set -e
  if (( fixed_status == 0 )); then
    ensure_root_head_unchanged
  fi
  if (( fixed_status == 0 )) && [[ "$dry_run" != true && -f "$snapshot_checkpoint" ]]; then
    mkdir -p "${original_checkpoint%/*}"
    cp "$snapshot_checkpoint" "$original_checkpoint"
  fi
  exit "$fixed_status"
fi

# --- 4. registry and ignore projection --------------------------------------------

load_independent_registry
independent_count="${#independent_names[@]}"
detect_deprecated_layout

# --- 5. root cleanliness ---------------------------------------------------------

git -C "$repo_root" diff --cached --quiet -- || \
  blocked 'staged-changes' 'the index holds uncommitted changes; commit or unstage them first'
git -C "$repo_root" diff --quiet -- || \
  blocked 'dirty-working-tree' 'tracked files hold uncommitted changes; commit them first'

untracked="$(git -C "$repo_root" ls-files --others --exclude-standard)"
if [[ -n "$untracked" ]]; then
  blocked 'untracked-files' 'untracked non-ignored files would not be backed up' \
    "$(printf '%s\n' "$untracked" | head -n 10)"
fi

if git -C "$repo_root" rev-parse --verify --quiet refs/stash >/dev/null; then
  blocked 'stash-present' 'stash entries are never sent to a remote; apply or drop them first'
fi

ensure_no_unreachable_local_branches

# --- 6. forbidden content in root -------------------------------------------------

# The only nested Git repositories allowed are the Project roots of registered Independent
# Projects. The contract-defined derived areas .tmp/ and .agent-cache/ are outside every
# backup target, so they are pruned instead of being walked on every run.
nested_prune=( -path "$repo_root/.git" -o -name '.tmp' -o -name '.agent-cache' )
if (( independent_count > 0 )); then
  scan_index=0
  while (( scan_index < independent_count )); do
    nested_prune+=( -o -path "$repo_root/projects/${independent_names[$scan_index]}" )
    scan_index=$((scan_index + 1))
  done
fi
nested_git="$(find "$repo_root" \( "${nested_prune[@]}" \) -prune -o \
  -mindepth 2 \( -type d -o -type f \) -name .git -print | sed -n '1,10p')"
if [[ -n "$nested_git" ]]; then
  blocked 'nested-git-repository' \
    'nested .git entries are forbidden unless they are registered Independent Project clones' "$nested_git"
fi

forbidden=''
while IFS= read -r tracked; do
  [[ -n "$tracked" ]] || continue
  case "$tracked" in
    .env.example|*/.env.example) continue ;;
    .tmp/*|*/.tmp/*|.agent-cache/*|*/.agent-cache/*|.DS_Store|*/.DS_Store|.env|.env.*|*/.env|*/.env.*)
      forbidden="$forbidden $tracked"
      ;;
  esac
done < <(git -C "$repo_root" ls-files)
if [[ -n "$forbidden" ]]; then
  blocked 'forbidden-tracked-file' "secrets or disposable paths are tracked:$forbidden"
fi

while IFS= read -r attributes_file; do
  [[ -n "$attributes_file" && -f "$repo_root/$attributes_file" ]] || continue
  if grep -Fq 'filter=lfs' "$repo_root/$attributes_file"; then
    blocked 'unsupported-git-lfs' "Git LFS pointers are not covered by this backup: $attributes_file"
  fi
done < <(git -C "$repo_root" ls-files -- '.gitattributes' '*/.gitattributes')

# A verified checkpoint narrows the audit to the objects new since the last
# remote-confirmed backup; the induction chain back to the initial full scan keeps the
# guarantee that every object reachable from HEAD has been audited once.
load_backup_checkpoint
oversized_range="$local_head"
if [[ -n "$checkpoint_sha" ]]; then
  oversized_range="$checkpoint_sha..$local_head"
  note "incremental object audit since last verified backup: $checkpoint_sha"
fi
oversized="$(
  git -C "$repo_root" rev-list --objects "$oversized_range" |
    git -C "$repo_root" cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' |
    awk -v limit="$max_blob_bytes" '
      $2 == "blob" && $3 + 0 >= limit + 0 {
        path = $4
        for (i = 5; i <= NF; i++) path = path " " $i
        if (path == "") path = $1
        printf "%s (%s bytes)\n", path, $3
      }
    '
)"
if [[ -n "$oversized" ]]; then
  blocked 'oversized-git-object' "objects at or above ${max_blob_bytes}B exceed the GitHub hard limit" \
    "$(printf '%s\n' "$oversized" | head -n 10)"
fi

# --- 7. root ownership / gitlink --------------------------------------------------

validate_root_repository_ownership

# --- 8. audit Independent repositories when in workspace scope --------------------

ensure_github_remote_auth "$repo_root" "$remote" "$remote_url"

if [[ "$root_only" == true ]]; then
  note "root-only scope: $independent_count registered Independent repository(ies) were not audited"
else
  audit_index=0
  while (( audit_index < independent_count )); do
    audit_name="${independent_names[$audit_index]}"
    audit_url="${independent_urls[$audit_index]}"
    audit_revision="${independent_revisions[$audit_index]}"
    audit_role="${independent_roles[$audit_index]}"
    validate_independent_attachment "$audit_name" "$audit_url"
    audit_independent_repository "$audit_name" "$audit_role"
    # Calling this in a command substitution would keep the temp-directory state from reaching
    # the parent, so the cleanup trap would miss it. Call it directly; the result comes back through the global verify_repo.
    verify_independent_revision "$audit_name" "$audit_url" "$audit_revision"
    verify_local_refs_backed_up "$audit_name" "$verify_repo"
    note "independent repository verified: $(redact_repository_url "$audit_url")@$audit_revision at projects/$audit_name"
    audit_index=$((audit_index + 1))
  done
  note "registered Independent repositories: $independent_count (audited, never pushed by this tool)"
fi

# --- 9. dry-run diagnostic (the only unconditional pre-push remote query) ------------
# A dry run performs no push, so it reads the remote once to diagnose divergence.
# The real success path skips this query: a plain fast-forward push carries the ref
# advertisement and the non-fast-forward refusal in its own single exchange.

if [[ "$dry_run" == true ]]; then
  remote_listing=''
  if ! remote_listing="$(github_git_run "$repo_root" "$remote_url" git-read -C "$repo_root" \
    ls-remote --heads "$remote_url" "refs/heads/$branch" 2>&1)"; then
    blocked "$(github_auth_classify_git_error "$remote_listing")" \
      "cannot read refs/heads/$branch from $remote"
  fi
  remote_sha="$(printf '%s\n' "$remote_listing" | awk 'NF >= 2 && $1 ~ /^[0-9a-f]{40}$/ { print $1; exit }')"

  if [[ -z "$remote_sha" ]]; then
    note "remote branch does not exist yet; this is the initial backup of refs/heads/$branch"
  else
    if ! git -C "$repo_root" cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
      blocked 'remote-diverged' "remote=$remote_sha local=$local_head" \
        'the remote commit does not exist locally; resolve with the user before backing up'
    fi
    if ! git -C "$repo_root" merge-base --is-ancestor "$remote_sha" "$local_head"; then
      blocked 'remote-diverged' "remote=$remote_sha local=$local_head" \
        'the remote branch is ahead of or diverged from local HEAD; resolve with the user before backing up'
    fi
  fi
  note 'dry run performed no remote write'
  if [[ "$root_only" == true ]]; then
    printf 'ROOT_BACKUP_READY remote=%s branch=%s sha=%s scope=root-only\n' "$remote" "$branch" "$local_head"
  else
    printf 'WORKSPACE_BACKUP_READY remote=%s branch=%s sha=%s independent=%s\n' \
      "$remote" "$branch" "$local_head" "$independent_count"
  fi
  exit 0
fi

# --- 10. root push -------------------------------------------------------------------
# The push itself refuses a non-fast-forward update without writing anything, so a
# failure is classified afterwards with one remote read instead of querying up front.
# Recheck the moving root ref, then push the immutable commit captured before any audit.
# If HEAD moves after this check, the fixed refspec still prevents the new commit from
# being sent; the post-push check below reports the local race before checkpointing.

classify_push_failure() {
  local push_detail="$1"
  local failure_listing failure_sha
  if ! failure_listing="$(github_git_run "$repo_root" "$remote_url" git-read -C "$repo_root" \
    ls-remote --heads "$remote_url" "refs/heads/$branch" 2>&1)"; then
    blocked "$(github_auth_classify_git_error "$failure_listing")" \
      "cannot read refs/heads/$branch from $remote"
  fi
  failure_sha="$(printf '%s\n' "$failure_listing" | awk 'NF >= 2 && $1 ~ /^[0-9a-f]{40}$/ { print $1; exit }')"
  if [[ -n "$failure_sha" ]]; then
    if ! git -C "$repo_root" cat-file -e "${failure_sha}^{commit}" 2>/dev/null; then
      blocked 'remote-diverged' "remote=$failure_sha local=$local_head" \
        'the remote commit does not exist locally; resolve with the user before backing up' "$push_detail"
    fi
    if ! git -C "$repo_root" merge-base --is-ancestor "$failure_sha" "$local_head"; then
      blocked 'remote-diverged' "remote=$failure_sha local=$local_head" \
        'the remote branch is ahead of or diverged from local HEAD; resolve with the user before backing up' "$push_detail"
    fi
  fi
  blocked 'push-failed' "$push_detail"
}

push_output=''
ensure_root_head_unchanged
if ! push_output="$(github_git_run "$repo_root" "$remote_url" git-push -C "$repo_root" \
  push --porcelain "$remote_url" "$local_head:refs/heads/$branch" 2>&1)"; then
  classify_push_failure "$push_output"
fi
note "$(printf '%s\n' "$push_output" | tr '\n' ' ')"

# --- 11. re-verify the remote SHA -----------------------------------------------------

verify_listing=''
if ! verify_listing="$(github_git_run "$repo_root" "$remote_url" git-read -C "$repo_root" \
  ls-remote --heads "$remote_url" "refs/heads/$branch" 2>&1)"; then
  blocked "$(github_auth_classify_git_error "$verify_listing")" \
    "cannot re-read refs/heads/$branch from $remote"
fi
verified_sha="$(printf '%s\n' "$verify_listing" | awk 'NF >= 2 && $1 ~ /^[0-9a-f]{40}$/ { print $1; exit }')"
if [[ "$verified_sha" != "$local_head" ]]; then
  blocked 'remote-verification-mismatch' "remote=${verified_sha:-none} local=$local_head"
fi
ensure_root_head_unchanged
# Record the remote-verified SHA so the next run's object audit is incremental.
write_backup_checkpoint

# --- 12. per-scope stdout --------------------------------------------------------------

if [[ "$root_only" == true ]]; then
  printf 'ROOT_BACKUP_OK remote=%s branch=%s sha=%s scope=root-only\n' "$remote" "$branch" "$local_head"
else
  printf 'WORKSPACE_BACKUP_OK remote=%s branch=%s sha=%s independent=%s\n' \
    "$remote" "$branch" "$local_head" "$independent_count"
fi
