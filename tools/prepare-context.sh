#!/usr/bin/env bash
set -euo pipefail

# Emit a Context Packet that bundles the initial reads after Route determination into a
# single Tool call. The Tool performs only deterministic enumeration (Git root,
# Required/Conditional references, read order, profile candidates); the agent decides
# whether Conditionals apply and designs the deliverable. File bodies are not emitted.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${AGENT_DIRECTORY_ROOT:-$(cd "$tool_root/.." && pwd)}"
. "$tool_root/lib/project-registry.sh"
route=''
target=''
task_class=''

usage() {
  printf 'Usage: %s --route knowledge|skill|project|meta --class read|work|state|boundary [--target <repo-relative-path>]\n' \
    "${0##*/}" >&2
}

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
    --class)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      task_class="$2"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

case "$route" in knowledge|skill|project|meta) ;; *) usage; exit 2 ;; esac
# --class is mandatory: an unspecified class is never treated as an implicit work.
case "$task_class" in read|work|state|boundary) ;; *) usage; exit 2 ;; esac
target="${target%/}"
if [[ "$target" == /* || "$target" == *..* ]]; then
  printf 'ERROR: --target must be a repository-relative path without ..\n' >&2
  exit 2
fi

read_list=''
missing_list=''
conditional_list=''

queue_read() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if printf '%s\n' "$read_list" | grep -Fqx -- "$path"; then
    return 0
  fi
  if [[ -f "$repo_root/$path" ]]; then
    read_list="${read_list}${path}
"
  else
    printf '%s\n' "$missing_list" | grep -Fqx -- "$path" || missing_list="${missing_list}${path}
"
  fi
}

queue_conditional() {
  # One "<condition> -> <path>" line. Only exact duplicate lines are dropped; the agent decides whether the condition holds.
  local line="$1"
  printf '%s\n' "$conditional_list" | grep -Fqx -- "$line" || conditional_list="${conditional_list}${line}
"
}

# Extract backtick references under `### Required` from list lines outside code fences.
required_refs() {
  LC_ALL=C awk '
    /^```/ { fence = 1 - fence; next }
    fence { next }
    /^## /  { h2 = $0; h3 = "" }
    /^### / { h3 = $0 }
    h2 ~ /^## 使用する/ && h3 == "### Required" && /^- / {
      line = $0
      while (match(line, /`[^`]+`/)) {
        ref = substr(line, RSTART + 1, RLENGTH - 2)
        print ref
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# Emit each "- 条件: … 参照: `path`" pair under `### Conditional` as "<condition> -> path".
conditional_refs() {
  LC_ALL=C awk '
    /^```/ { fence = 1 - fence; next }
    fence { next }
    /^## /  { h2 = $0; h3 = ""; cond = "" }
    /^### / { h3 = $0; cond = "" }
    h2 ~ /^## 使用する/ && h3 == "### Conditional" {
      if ($0 ~ /^- 条件:/) {
        cond = $0
        sub(/^- 条件:[[:space:]]*/, "", cond)
      } else if (cond != "" && /参照:/ && match($0, /`[^`]+`/)) {
        print cond " -> " substr($0, RSTART + 1, RLENGTH - 2)
        cond = ""
      }
    }
  ' "$1"
}

# Emit each row of a per-Project AGENTS.md `## Project Docs Route` table as "<condition> -> path".
docs_route_refs() {
  LC_ALL=C awk -F '|' '
    /^```/ { fence = 1 - fence; next }
    fence { next }
    /^## / { in_route = ($0 == "## Project Docs Route") }
    in_route && NF >= 4 && $2 !~ /^[[:space:]]*-+[[:space:]]*$/ && $2 !~ /条件/ {
      cond = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cond)
      ref = $3
      if (match(ref, /`[^`]+`/)) {
        print cond " -> " substr(ref, RSTART + 1, RLENGTH - 2)
      }
    }
  ' "$1"
}

repository_role_for() {
  local wanted="$1"
  local kind name url reason revision role
  [[ -f "$repo_root/projects/REPOSITORIES.md" ]] || return 1
  while IFS=$'\t' read -r kind name url reason revision role; do
    [[ "$kind" == 'R' && "$name" == "$wanted" ]] || continue
    printf '%s\n' "$role"
    return 0
  done < <(agent_registry_records "$repo_root/projects/REPOSITORIES.md")
  return 1
}

git_root='.'
repository_owner='root'
repository_role='workspace'

queue_read 'AGENTS.md'

case "$route" in
  project)
    if [[ -z "$target" || "$target" != projects/* ]]; then
      printf 'ERROR: project route requires --target projects/<name>\n' >&2
      exit 2
    fi
    project_name="${target#projects/}"
    project_name="${project_name%%/*}"
    project_dir="projects/$project_name"
    project_role="$(repository_role_for "$project_name" || true)"
    if [[ "$project_role" == 'public-foundation' ]]; then
      printf 'ERROR: public foundation repositories use --route meta: %s\n' "$project_dir" >&2
      exit 2
    fi
    if [[ ! -d "$repo_root/$project_dir" ]]; then
      printf 'ERROR: project does not exist: %s\n' "$project_dir" >&2
      exit 2
    fi
    queue_read 'projects/AGENTS.md'
    queue_read "$project_dir/AGENTS.md"
    queue_read "$project_dir/PROJECT.md"
    queue_read "$project_dir/STATE.md"
    if toplevel="$(git -C "$repo_root/$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
      if [[ "$(cd "$toplevel" && pwd -P)" == "$(cd "$repo_root/$project_dir" && pwd -P)" ]]; then
        repository_owner='independent'
        repository_role='project'
        git_root="$project_dir"
      fi
    else
      repository_owner='unresolved'
    fi
    contract="$repo_root/$project_dir/PROJECT.md"
    if [[ -f "$contract" ]]; then
      while IFS= read -r ref; do
        queue_read "$ref"
      done < <(required_refs "$contract")
      while IFS= read -r pair; do
        [[ -n "$pair" ]] && queue_conditional "$pair"
      done < <(conditional_refs "$contract")
    fi
    if [[ -f "$repo_root/$project_dir/AGENTS.md" ]]; then
      # Docs Route table paths are Project-relative; normalize every path in the packet to repo-relative.
      while IFS= read -r pair; do
        [[ -n "$pair" ]] || continue
        ref="${pair##* -> }"
        cond="${pair% -> *}"
        case "$ref" in
          projects/*|knowledge/*|skills/*|tools/*|evals/*) ;;
          *) ref="$project_dir/$ref" ;;
        esac
        queue_conditional "$cond -> $ref"
      done < <(docs_route_refs "$repo_root/$project_dir/AGENTS.md")
    fi
    ;;
  knowledge)
    queue_read 'knowledge/KNOWLEDGE.md'
    [[ -z "$target" || -d "$repo_root/$target" ]] || queue_read "$target"
    ;;
  skill)
    queue_read 'skills/SKILLS.md'
    if [[ -n "$target" ]]; then
      case "$target" in
        skills/*/*) queue_read "$target" ;;
        skills/*) queue_read "${target}/SKILL.md" ;;
        *) queue_read "$target" ;;
      esac
    fi
    ;;
  meta)
    case "$target" in
      tools/*) queue_read 'tools/TOOLS.md' ;;
      evals/*) queue_read 'evals/EVALS.md' ;;
      projects/*)
        queue_read 'projects/PROJECTS.md'
        foundation_name="${target#projects/}"
        foundation_name="${foundation_name%%/*}"
        foundation_role="$(repository_role_for "$foundation_name" || true)"
        if [[ "$foundation_role" == 'public-foundation' ]]; then
          foundation_dir="projects/$foundation_name"
          queue_read 'STATE.md'
          queue_read 'projects/REPOSITORIES.md'
          queue_read "$foundation_dir/AGENTS.md"
          queue_read "$foundation_dir/README.md"
          repository_role='public-foundation'
          if toplevel="$(git -C "$repo_root/$foundation_dir" rev-parse --show-toplevel 2>/dev/null)" && \
            [[ "$(cd "$toplevel" && pwd -P)" == "$(cd "$repo_root/$foundation_dir" && pwd -P)" ]]; then
            repository_owner='independent'
            git_root="$foundation_dir"
          else
            repository_owner='unresolved'
          fi
        fi
        ;;
      knowledge/*) queue_read 'knowledge/KNOWLEDGE.md' ;;
    esac
    [[ -n "$target" ]] && queue_read "$target"
    ;;
esac

# The agent decides the task class by canon; this tool only maps the decided class to a
# deterministic profile. `read` never triggers validation, commit, or backup. Only meta
# work/state and every boundary escalate to the full validator; normal work/state use the
# scoped (--changed) validator.
validation_profile='scoped'
backup_profile='root-only'
case "$task_class" in
  read)
    validation_profile='none'
    backup_profile='none'
    ;;
  work|state)
    [[ "$route" != 'meta' ]] || validation_profile='full'
    # finalize-task.sh と同じ語彙: Independent はここから push せず Push Policy に委ねる。
    [[ "$repository_owner" != 'independent' ]] || backup_profile='push-policy'
    ;;
  boundary)
    validation_profile='full'
    backup_profile='workspace'
    ;;
esac

printf 'TASK_CONTEXT v1\n'
printf 'route=%s\n' "$route"
[[ -n "$target" ]] && printf 'target=%s\n' "$target"
printf 'task_class=%s\n' "$task_class"
printf 'git_root=%s\n' "$git_root"
printf 'repository_owner=%s\n' "$repository_owner"
printf 'repository_role=%s\n' "$repository_role"
printf 'validation_profile=%s\n' "$validation_profile"
printf 'backup_profile=%s\n' "$backup_profile"
printf 'READ:\n'
printf '%s' "$read_list"
if [[ -n "$conditional_list" ]]; then
  printf 'CONDITIONAL:\n'
  printf '%s' "$conditional_list"
fi
if [[ -n "$missing_list" ]]; then
  printf 'MISSING:\n'
  printf '%s' "$missing_list"
fi
