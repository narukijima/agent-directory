#!/usr/bin/env bash
set -euo pipefail

# Thin task facade. It keeps task class and validation/backup profiles inside the
# compatibility tools so an agent normally supplies only Route and Target.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${AGENT_DIRECTORY_ROOT:-$(cd "$tool_root/.." && pwd)}"

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/task.sh context --route knowledge|skill|project|meta [--target <path>]
  tools/task.sh verify
  tools/task.sh finish --route knowledge|skill|project|meta [--target <path>] --message <text> [--current-work]
  tools/task.sh status
USAGE
}

blocked() {
  printf 'TASK_BLOCKED action=%s reason=%s\n' "$1" "$2"
  exit "${3:-1}"
}

require_backup_machine_ready() {
  local backup_url output rc
  backup_url="$(git -C "$repo_root" remote get-url backup 2>/dev/null || true)"
  case "$backup_url" in
    https://github.com/*)
      set +e
      output="$(bash "$tool_root/setup-github-auth.sh" --machine-ready --remote backup 2>&1)"
      rc=$?
      set -e
      if (( rc != 0 )); then
        printf '%s\n' "$output" >&2
        blocked context github-machine-not-ready "$rc"
      fi
      printf '%s\n' "$output" >&2
      ;;
  esac
}

command_name="${1:-}"
[[ -n "$command_name" ]] || { usage; exit 2; }
shift

route=''
target=''
message=''
current_work=false
while (( $# > 0 )); do
  case "$1" in
    --route)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      route="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      target="$2"
      shift 2
      ;;
    --message)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      message="$2"
      shift 2
      ;;
    --current-work)
      current_work=true
      shift
      ;;
    *) usage; exit 2 ;;
  esac
done

case "$command_name" in
  context)
    [[ "$current_work" == false ]] || { usage; exit 2; }
    case "$route" in knowledge|skill|project|meta) ;; *) usage; exit 2 ;; esac
    require_backup_machine_ready
    args=(--route "$route" --class work)
    [[ -z "$target" ]] || args+=(--target "$target")
    packet="$(bash "$tool_root/prepare-context.sh" "${args[@]}")" || \
      blocked context context-resolution-failed
    printf 'TASK_CONTEXT v2\n'
    printf '%s\n' "$packet" | awk '
      /^route=/ || /^target=/ || /^git_root=/ || /^repository_owner=/ || /^repository_role=/ { print }
      /^READ:/ || /^CONDITIONAL:/ || /^MISSING:/ { emit=1; print; next }
      emit && !/^(task_class|validation_profile|backup_profile)=/ { print }
    '
    ;;
  verify)
    [[ -z "$route$target$message" && "$current_work" == false ]] || { usage; exit 2; }
    if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
      blocked verify not-a-git-repository
    fi
    [[ -f "$repo_root/tools/validate-agent-directory.sh" ]] || blocked verify validator-not-found
    if output="$( (cd "$repo_root" && bash tools/validate-agent-directory.sh --changed) 2>&1 )"; then
      printf '%s\n' "$output" >&2
      scope='changed'
      case "$output" in
        *'running the full static validation'*) scope='full' ;;
      esac
      printf 'TASK_OK action=verify scope=%s\n' "$scope"
    else
      rc=$?
      printf '%s\n' "$output" >&2
      printf 'TASK_FAILED action=verify reason=validation-failed\n'
      exit "$rc"
    fi
    ;;
  finish)
    case "$route" in knowledge|skill|project|meta) ;; *) usage; exit 2 ;; esac
    [[ -n "$message" ]] || { usage; exit 2; }
    args=(--route "$route" --class work --message "$message")
    [[ -z "$target" ]] || args+=(--target "$target")
    if [[ "$current_work" == true ]]; then
      [[ -n "$target" ]] || { usage; exit 2; }
      args+=(--current-work)
    fi
    if output="$(bash "$tool_root/finalize-task.sh" "${args[@]}" 2>&1)"; then
      printf '%s\n' "$output" >&2
      printf 'TASK_OK action=finish\n'
    else
      rc=$?
      printf '%s\n' "$output" >&2
      case "$output" in
        *'FINALIZE_BLOCKED reason=boundary'*|*'FINALIZE_BLOCKED reason=ack-env-set'*)
          blocked finish protected-change "$rc"
          ;;
        *)
          printf 'TASK_FAILED action=finish reason=finalize-failed\n'
          exit "$rc"
          ;;
      esac
    fi
    ;;
  status)
    [[ -z "$route$target$message" && "$current_work" == false ]] || { usage; exit 2; }
    git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" || \
      blocked status not-a-git-repository
    changed_count="$({ git -C "$repo_root" status --porcelain --untracked-files=normal || true; } | wc -l | tr -d ' ')"
    printf 'TASK_OK action=status git_root=%s changed=%s\n' "$git_root" "$changed_count"
    ;;
  *) usage; exit 2 ;;
esac
