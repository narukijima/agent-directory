#!/usr/bin/env bash
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_root="$(cd "$tool_root/.." && pwd -P)"
workspace=''
check_only=false

usage() {
  printf 'Usage: %s --workspace <absolute-path> [--check]\n' "${0##*/}" >&2
  exit 2
}

blocked() {
  printf 'GITHUB_AUTH_MIGRATION_BLOCKED reason=%s workspace=%s\n' "$1" "${workspace:-unknown}" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) [[ $# -ge 2 ]] || usage; workspace="$2"; shift 2 ;;
    --check) check_only=true; shift ;;
    *) usage ;;
  esac
done

[[ "$workspace" == /* ]] || blocked workspace-path-invalid
workspace="$(cd "$workspace" 2>/dev/null && pwd -P)" || blocked workspace-path-invalid
for signature in AGENTS.md tools/backup-to-github.sh tools/report-upstream-issue.sh \
  tools/validate-agent-directory.sh; do
  [[ -f "$workspace/$signature" ]] || blocked signature-mismatch
done
git_root="$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" ]] || blocked not-git-repository
git_root="$(cd "$git_root" && pwd -P)"
[[ "$git_root" == "$workspace" ]] || blocked git-root-mismatch

scripts_current=false
validator_current=false
if grep -Fq 'GITHUB_AUTH_IMPLEMENTATION_VERSION=2' "$workspace/tools/lib/github-auth.sh" 2>/dev/null && \
  grep -Fq 'tools/lib/github-auth.sh' "$workspace/tools/report-upstream-issue.sh" && \
  grep -Fq 'github_git_run' "$workspace/tools/backup-to-github.sh"; then
  scripts_current=true
fi
if grep -Fq 'shared-wrapper push invocation' "$workspace/tools/validate-agent-directory.sh"; then
  validator_current=true
fi
if [[ "$scripts_current" == true && "$validator_current" == true ]]; then
  printf 'GITHUB_AUTH_MIGRATION_OK workspace=%s status=already-current\n' "$workspace"
  exit 0
fi

targets_to_check=(tools/validate-agent-directory.sh)
if [[ "$scripts_current" != true ]]; then
  targets_to_check+=(tools/backup-to-github.sh tools/report-upstream-issue.sh)
fi
for target in "${targets_to_check[@]}"; do
  git -C "$workspace" diff --quiet -- "$target" || blocked dirty-auth-files
  git -C "$workspace" diff --cached --quiet -- "$target" || blocked dirty-auth-files
done
if [[ "$scripts_current" != true ]]; then
  for target in tools/lib/github-auth.sh tools/setup-github-auth.sh; do
    if [[ -e "$workspace/$target" ]] && ! git -C "$workspace" ls-files --error-unmatch "$target" >/dev/null 2>&1; then
      blocked unowned-auth-file
    fi
    git -C "$workspace" diff --quiet -- "$target" || blocked dirty-auth-files
    git -C "$workspace" diff --cached --quiet -- "$target" || blocked dirty-auth-files
  done
fi

patch_file="$source_root/tools/migrations/github-auth-v2-backup.patch"
validator_patch="$source_root/tools/migrations/github-auth-v2-validator.patch"
if [[ "$scripts_current" != true ]]; then
  report_blob="$(git -C "$workspace" hash-object tools/report-upstream-issue.sh)"
  backup_blob="$(git -C "$workspace" hash-object tools/backup-to-github.sh)"
  case "$report_blob" in
    0b8e2d8e5bba49814ad207f61ac5f59e6beeafd5) ;;
    *) blocked unsupported-report-version ;;
  esac
  case "$backup_blob" in
    1b56c1aaaf9f2ab0f154f017e1a07dc43ebd2ccd|44598d387ac1c62e136ad5cdf465471833a6b99f) ;;
    *) blocked unsupported-backup-version ;;
  esac
  git -C "$workspace" apply --check --unidiff-zero "$patch_file" || blocked patch-conflict
fi
if [[ "$validator_current" != true ]]; then
  validator_blob="$(git -C "$workspace" hash-object tools/validate-agent-directory.sh)"
  case "$validator_blob" in
    a377aeeaff1cb2444b11074111fbe245de9e2e7a|1907113d04a4138125ebf588ba4d0a953fc73d09) ;;
    *) blocked unsupported-validator-version ;;
  esac
  git -C "$workspace" apply --check "$validator_patch" || blocked validator-patch-conflict
fi
if [[ "$check_only" == true ]]; then
  printf 'GITHUB_AUTH_MIGRATION_READY workspace=%s version=2\n' "$workspace"
  exit 0
fi

if [[ "$scripts_current" != true ]]; then
  mkdir -p "$workspace/tools/lib"
  cp "$source_root/tools/lib/github-auth.sh" "$workspace/tools/lib/github-auth.sh"
  cp "$source_root/tools/setup-github-auth.sh" "$workspace/tools/setup-github-auth.sh"
  cp "$source_root/tools/report-upstream-issue.sh" "$workspace/tools/report-upstream-issue.sh"
  chmod 755 "$workspace/tools/lib/github-auth.sh" "$workspace/tools/setup-github-auth.sh" \
    "$workspace/tools/report-upstream-issue.sh"
  git -C "$workspace" apply --unidiff-zero "$patch_file"
fi
if [[ "$validator_current" != true ]]; then
  git -C "$workspace" apply "$validator_patch"
fi

printf 'GITHUB_AUTH_MIGRATION_OK workspace=%s status=migrated version=2\n' "$workspace"
