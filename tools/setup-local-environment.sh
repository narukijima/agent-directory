#!/bin/bash
# tools/setup-local-environment.sh — Codex / Claude Code共通の冪等なローカル初期化。
set -eu

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"
git_author_name="${AGENT_DIRECTORY_GIT_AUTHOR_NAME:-}"
git_author_email="${AGENT_DIRECTORY_GIT_AUTHOR_EMAIL:-}"
git_author_explicit=false
git_author_email_explicit=false
if [ "${AGENT_DIRECTORY_GIT_AUTHOR_NAME+x}" = x ]; then
  git_author_explicit=true
fi
if [ "${AGENT_DIRECTORY_GIT_AUTHOR_EMAIL+x}" = x ]; then
  git_author_email_explicit=true
fi

usage() {
  printf 'Usage: %s [--git-author-name <name>] [--git-author-email <address>]\n' "${0##*/}" >&2
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
    --git-author-email)
      [ "$#" -ge 2 ] || usage
      git_author_email="$2"
      git_author_email_explicit=true
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
if [ "$git_author_email_explicit" = true ]; then
  [ -n "$git_author_email" ] || blocked 'git-author-email-invalid'
  case "$git_author_email" in
    *$'\n'*|*$'\r'*|*'<'*|*'>'*) blocked 'git-author-email-invalid' ;;
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
# Email is never inferred. An explicit address is repository-local, and the effective
# identity must be privacy-safe before setup succeeds.
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

if [ "$git_author_email_explicit" = true ]; then
  effective_git_email="$git_author_email"
else
  effective_git_email="$(git -C "$repo_root" config user.email 2>/dev/null || true)"
fi
email_public_safe=false
case "$effective_git_email" in
  *@users.noreply.github.com|*@example.invalid) email_public_safe=true ;;
esac
if [ "$email_public_safe" = false ] && [ -n "$effective_git_email" ]; then
  while IFS= read -r allowed_public_email; do
    [ -n "$allowed_public_email" ] || continue
    if [ "$effective_git_email" = "$allowed_public_email" ]; then
      email_public_safe=true
      break
    fi
  done < <(git -C "$repo_root" config --get-all agent-directory.allowed-public-email 2>/dev/null || true)
fi
if [ "$email_public_safe" = false ]; then
  blocked 'unsafe-git-email'
fi
if [ "$git_author_email_explicit" = true ]; then
  git -C "$repo_root" config --local user.email "$git_author_email" || \
    blocked 'git-author-email-config-failed'
fi

# worktreeごとにGit管理外の検索cacheを作る。既存cacheが新鮮なら本文を再読しない。
# 正本、秘密情報、Git設定、remoteには触れない。
if ! bash "$repo_root/tools/build-context-cache.sh" --check-routing >/dev/null 2>&1; then
  bash "$repo_root/tools/build-context-cache.sh" --routing-only >/dev/null
fi

printf 'LOCAL_ENVIRONMENT_READY cache=routing-current git-author=%s git-email=privacy-safe\n' \
  "$git_author_state"
