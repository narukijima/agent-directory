#!/usr/bin/env bash
set -euo pipefail

# Thin local task entrypoint. Runtime, Provider, commit, push, and publication
# workflows belong to each Agent / Operator, not to Agent Directory.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_root/.." && pwd -P)"

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/task.sh context --route knowledge|skill|project|meta [--target <repository-relative-path>]
  tools/task.sh verify
  tools/task.sh status
USAGE
}

blocked() {
  printf 'TASK_BLOCKED action=%s reason=%s\n' "$1" "$2"
  exit "${3:-1}"
}

command_name="${1:-}"
[[ -n "$command_name" ]] || { usage; exit 2; }
shift

route=''
target=''
while (( $# > 0 )); do
  case "$1" in
    --route)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      route="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      target="${2#./}"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

emit_target() {
  local path="$1"
  if [[ -f "$repo_root/$path" ]]; then
    printf 'READ: %s\n' "$path"
  elif [[ -d "$repo_root/$path" ]]; then
    printf 'READ: %s\n' "$path"
  else
    printf 'MISSING: %s\n' "$path"
  fi
}

case "$command_name" in
  context)
    case "$route" in knowledge|skill|project|meta) ;; *) usage; exit 2 ;; esac
    case "$target" in
      /*|..|../*|*/../*|*/..) blocked context target-outside-repository ;;
    esac

    git_root="$repo_root"
    repository_owner='root'
    if [[ -n "$target" && -e "$repo_root/$target" ]]; then
      probe="$repo_root/$target"
      [[ -d "$probe" ]] || probe="$(dirname "$probe")"
      resolved_root="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "$resolved_root" ]]; then
        resolved_root="$(cd "$resolved_root" && pwd -P)"
        case "$resolved_root" in
          "$repo_root") ;;
          "$repo_root"/projects/*)
            git_root="$resolved_root"
            repository_owner='independent'
            ;;
          *) blocked context target-owned-by-another-root ;;
        esac
      fi
    fi

    printf 'TASK_CONTEXT v3\n'
    printf 'route=%s\n' "$route"
    printf 'target=%s\n' "${target:-none}"
    printf 'git_root=%s\n' "$git_root"
    printf 'repository_owner=%s\n' "$repository_owner"
    printf 'READ: AGENTS.md\n'
    case "$route" in
      knowledge)
        printf 'READ: knowledge/KNOWLEDGE.md\n'
        [[ -z "$target" ]] || emit_target "$target"
        ;;
      skill)
        printf 'READ: skills/SKILLS.md\n'
        if [[ -n "$target" ]]; then
          if [[ -d "$repo_root/$target" ]]; then
            emit_target "$target/SKILL.md"
          else
            emit_target "$target"
          fi
        fi
        ;;
      project)
        printf 'READ: projects/AGENTS.md\n'
        if [[ -n "$target" ]]; then
          if [[ -d "$repo_root/$target" ]]; then
            [[ ! -f "$repo_root/$target/AGENTS.md" ]] || emit_target "$target/AGENTS.md"
            emit_target "$target/PROJECT.md"
            emit_target "$target/STATE.md"
          else
            emit_target "$target"
          fi
        fi
        ;;
      meta)
        [[ -z "$target" ]] || emit_target "$target"
        ;;
    esac
    ;;
  verify)
    [[ -z "$route$target" ]] || { usage; exit 2; }
    if output="$(cd "$repo_root" && bash tools/validate-agent-directory.sh --changed 2>&1)"; then
      printf '%s\n' "$output" >&2
      printf 'TASK_OK action=verify\n'
    else
      rc=$?
      printf '%s\n' "$output" >&2
      printf 'TASK_FAILED action=verify reason=validation-failed\n'
      exit "$rc"
    fi
    ;;
  status)
    [[ -z "$route$target" ]] || { usage; exit 2; }
    printf 'TASK_STATUS git_root=%s changed=%s\n' "$repo_root" "$(git -C "$repo_root" status --porcelain | wc -l | tr -d ' ')"
    ;;
  *) usage; exit 2 ;;
esac
