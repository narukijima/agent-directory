#!/bin/bash
# tools/setup-local-environment.sh — Codex / Claude Code共通の冪等なローカル初期化。
set -eu

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"
git_author_name="${AGENT_DIRECTORY_GIT_AUTHOR_NAME:-}"
git_author_explicit=false
if [ "${AGENT_DIRECTORY_GIT_AUTHOR_NAME+x}" = x ]; then
  git_author_explicit=true
fi

usage() {
  printf 'Usage: %s [--git-author-name <name>]\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  printf 'LOCAL_ENVIRONMENT_BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --git-author-name)
      [ "$#" -ge 2 ] || usage
      git_author_name="$2"
      git_author_explicit=true
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ "$git_author_explicit" = true ]; then
  [ -n "$git_author_name" ] || blocked 'git-author-name-invalid'
  case "$git_author_name" in
    *$'\n'*|*$'\r'*) blocked 'git-author-name-invalid' ;;
  esac
fi

for command_name in bash git python3; do
  command -v "$command_name" >/dev/null 2>&1 || blocked "missing-$command_name"
done

actual_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$actual_root" ]] || blocked 'not-git-repository'
actual_root="$(CDPATH= cd -- "$actual_root" && pwd -P)"
[[ "$actual_root" == "$repo_root" ]] || blocked 'git-root-mismatch'
[[ -f "$repo_root/AGENTS.md" && -f "$repo_root/tools/validate-agent-directory.sh" ]] || \
  blocked 'not-agent-directory-root'

# Explicit setup override > existing repository-local value > recommended Agent name.
# A normal repeated setup never rewrites a user's repository-local override. Email and
# existing commits are intentionally untouched.
git_author_state='unchanged'
if [ "$git_author_explicit" = true ]; then
  git -C "$repo_root" config --local user.name "$git_author_name" || blocked 'git-author-config-failed'
  git_author_state='explicit'
elif git -C "$repo_root" config --local --get user.name >/dev/null 2>&1; then
  git_author_state='existing'
else
  recommended_agent_name="$(awk '
    /^#+[[:space:]]*自己定義[[:space:]]*$/ {
      in_section = 1
      match($0, /^#+/)
      depth = RLENGTH
      next
    }
    in_section && /^#/ {
      match($0, /^#+/)
      if (RLENGTH <= depth) exit
    }
    in_section && /^[[:space:]]*-[[:space:]]*あなたは/ {
      line = $0
      if (sub(/^[^`]*`/, "", line)) {
        sub(/`.*/, "", line)
        print line
      }
      exit
    }
  ' "$repo_root/AGENTS.md")"
  case "$recommended_agent_name" in
    ''|'<'*'>') git_author_state='template-unset' ;;
    *)
      git -C "$repo_root" config --local user.name "$recommended_agent_name" || \
        blocked 'git-author-config-failed'
      git_author_state='recommended'
      ;;
  esac
fi

# worktreeごとにGit管理外の検索cacheを作る。既存cacheが新鮮なら本文を再読しない。
# 正本、秘密情報、Git設定、remoteには触れない。
if ! bash "$repo_root/tools/build-context-cache.sh" --check-routing >/dev/null 2>&1; then
  bash "$repo_root/tools/build-context-cache.sh" --routing-only >/dev/null
fi

printf 'LOCAL_ENVIRONMENT_READY cache=routing-current git-author=%s\n' "$git_author_state"
