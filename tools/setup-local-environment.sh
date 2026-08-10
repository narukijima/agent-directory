#!/bin/bash
# tools/setup-local-environment.sh — Codex / Claude Code共通の冪等なローカル初期化。
set -eu

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(CDPATH= cd -- "$tool_dir/.." && pwd -P)"

blocked() {
  printf 'LOCAL_ENVIRONMENT_BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

for command_name in bash git python3; do
  command -v "$command_name" >/dev/null 2>&1 || blocked "missing-$command_name"
done

actual_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$actual_root" ]] || blocked 'not-git-repository'
actual_root="$(CDPATH= cd -- "$actual_root" && pwd -P)"
[[ "$actual_root" == "$repo_root" ]] || blocked 'git-root-mismatch'
[[ -f "$repo_root/AGENTS.md" && -f "$repo_root/tools/validate-agent-directory.sh" ]] || \
  blocked 'not-agent-directory-root'

# worktreeごとにGit管理外の検索cacheを作る。既存cacheが新鮮なら本文を再読しない。
# 正本、秘密情報、Git設定、remoteには触れない。
if ! bash "$repo_root/tools/build-context-cache.sh" --check-routing >/dev/null 2>&1; then
  bash "$repo_root/tools/build-context-cache.sh" --routing-only >/dev/null
fi

printf 'LOCAL_ENVIRONMENT_READY cache=routing-current\n'
