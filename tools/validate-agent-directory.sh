#!/usr/bin/env bash
set -euo pipefail

# Small, provider-independent validator for the public Agent Workspace contract.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_root/.." && pwd -P)"
strict=false
full=false
changed=false
bootstrap_status=false
base_ref=''
failures=0
warnings=0

usage() {
  printf 'Usage: %s [--strict] [--full] [--changed] [--base <ref>] [--bootstrap-status]\n' "${0##*/}" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

while (( $# > 0 )); do
  case "$1" in
    --strict) strict=true; shift ;;
    --full) full=true; shift ;;
    --changed) changed=true; shift ;;
    --base)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --bootstrap-status) bootstrap_status=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ "$bootstrap_status" == true ]]; then
  [[ "$strict" == false && "$full" == false && "$changed" == false && -z "$base_ref" ]] || {
    usage
    exit 2
  }
  if grep -Eq '<agent-name>|<agent-role>|<agent-mission>|<agent-vision>|<operator-language>' "$repo_root/AGENTS.md" 2>/dev/null; then
    printf 'bootstrap-status=template\n'
  else
    printf 'bootstrap-status=deployed\n'
  fi
  exit 0
fi

if [[ "$strict" == true && "$changed" == true ]]; then
  usage
  exit 2
fi

require_file() {
  [[ -f "$repo_root/$1" ]] || fail "missing required file: $1"
}

check_size() {
  local path="$1" limit="$2" label="$3" bytes
  [[ -f "$repo_root/$path" ]] || return 0
  bytes="$(wc -c < "$repo_root/$path" | tr -d ' ')"
  (( bytes <= limit )) || fail "$label exceeds ${limit}B: $path (${bytes}B)"
}

frontmatter_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]*/, "", value)
      gsub(/^["'\''"]|["'\''"]$/, "", value)
      print value
      exit
    }
  ' "$file"
}

validate_status_file() {
  local file="$1" status
  [[ -f "$file" ]] || return 0
  [[ "$(sed -n '1p' "$file")" == '---' ]] || {
    fail "${file#"$repo_root"/} must start with YAML frontmatter"
    return 0
  }
  status="$(frontmatter_value "$file" status)"
  case "$status" in
    active|paused|completed|deprecated|retired|superseded|archived) ;;
    '') fail "${file#"$repo_root"/} is missing frontmatter status" ;;
    *) fail "${file#"$repo_root"/} has invalid status: $status" ;;
  esac
}

required_files=(
  '.gitignore'
  'AGENTS.md'
  'LICENSE'
  'README.md'
  'knowledge/KNOWLEDGE.md'
  'knowledge/wiki/INDEX.md'
  'knowledge/wiki/LOG.md'
  'knowledge/wiki/_template/SOURCE.md'
  'knowledge/wiki/_template/TOPIC.md'
  'skills/SKILLS.md'
  'skills/_template/SKILL.md'
  'projects/AGENTS.md'
  'projects/DOCS.md'
  'projects/LIFECYCLE.md'
  'projects/PROJECTS.md'
  'projects/RECOVERY.md'
  'projects/REPOSITORIES.md'
  'projects/.gitignore'
  'projects/_template/PROJECT.md'
  'projects/_template/STATE.md'
  'tools/CONTROL.md'
  'tools/SAFETY.md'
  'tools/TOOLS.md'
  'tools/append-knowledge-log.sh'
  'tools/build-context-cache.sh'
  'tools/check-boundary.sh'
  'tools/control-policy.tsv'
  'tools/find-context.sh'
  'tools/hooks/pre-commit'
  'tools/hooks/pre-push'
  'tools/install-git-hooks.sh'
  'tools/lib/project-registry.sh'
  'tools/materialize-project-repositories.sh'
  'tools/task.sh'
  'tools/validate-agent-directory.sh'
  'tools/validator/check-markdown-references.sh'
)
for path in "${required_files[@]}"; do
  require_file "$path"
done

expected_tools="$(cat <<'TOOLS'
tools/CONTROL.md
tools/SAFETY.md
tools/TOOLS.md
tools/append-knowledge-log.sh
tools/build-context-cache.sh
tools/check-boundary.sh
tools/control-policy.tsv
tools/find-context.sh
tools/hooks/pre-commit
tools/hooks/pre-push
tools/install-git-hooks.sh
tools/lib/project-registry.sh
tools/materialize-project-repositories.sh
tools/task.sh
tools/validate-agent-directory.sh
tools/validator/check-markdown-references.sh
TOOLS
)"
actual_tools="$(
  cd "$repo_root"
  find tools -type f -not -name '.DS_Store' -print | LC_ALL=C sort
)"
if [[ "$actual_tools" != "$expected_tools" ]]; then
  fail 'tools/ differs from the 16-file owner-approved allowlist'
  diff -u <(printf '%s\n' "$expected_tools") <(printf '%s\n' "$actual_tools") >&2 || true
fi

for retired in OPERATING_PROFILE.md SETUP.md CLAUDE.md .env.example evals tools/BACKUP.md tools/REFERENCE.md tools/UPSTREAM.md tools/THREAT_MODEL.md; do
  [[ ! -e "$repo_root/$retired" ]] || fail "retired path exists: $retired"
done
if git -C "$repo_root" ls-files | grep -E '(^|/)CLAUDE\.md$|(^|/)\.codex/|(^|/)\.claude/' | grep -q .; then
  fail 'Provider-specific bridge or adapter exists in the public template'
fi

for heading in '## 自己定義' '## 共通判断原則' '## Route' '## Context Loading' '## 自律実行' '## 差分判定' '## 人間へ上げる例外' '## 禁止事項' '## 参照順序'; do
  grep -Fqx "$heading" "$repo_root/AGENTS.md" || fail "AGENTS.md is missing heading: $heading"
done
grep -Fq '新しいTool、Skill、恒久的な仕組み、抽象化、依存は原則追加しない' "$repo_root/AGENTS.md" || fail 'AGENTS.md lost the owner gate for permanent additions'
grep -Fq 'Skillの新設は既存Skillの更新・統合で目的を満たせない場合だけ候補' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md lost the owner gate'
grep -Fq '新しいToolは原則追加しない' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md lost the Tool owner gate'
grep -Fq 'if [[ "$op" == '\''delete'\'' ]]' "$repo_root/tools/check-boundary.sh" || fail 'check-boundary.sh must permit cleanup deletion of forbidden paths'

if [[ "$strict" == true ]] && grep -Eq '<agent-name>|<agent-role>|<agent-mission>|<agent-vision>|<operator-language>' "$repo_root/AGENTS.md"; then
  fail 'AGENTS.md contains unresolved deployment placeholders'
fi

check_size 'AGENTS.md' 8192 'root AGENTS.md'
check_size 'projects/AGENTS.md' 2048 'projects/AGENTS.md'
check_size 'knowledge/KNOWLEDGE.md' 20480 'knowledge/KNOWLEDGE.md'
check_size 'skills/SKILLS.md' 20480 'skills/SKILLS.md'
check_size 'projects/PROJECTS.md' 24576 'projects/PROJECTS.md'
check_size 'projects/DOCS.md' 24576 'projects/DOCS.md'
check_size 'tools/TOOLS.md' 20480 'tools/TOOLS.md'
check_size 'tools/SAFETY.md' 20480 'tools/SAFETY.md'
check_size 'tools/CONTROL.md' 20480 'tools/CONTROL.md'
check_size 'knowledge/wiki/INDEX.md' 8192 'knowledge/wiki/INDEX.md'
check_size 'knowledge/wiki/LOG.md' 131072 'knowledge/wiki/LOG.md'

while IFS= read -r -d '' page; do
  validate_status_file "$page"
  bytes="$(wc -c < "$page" | tr -d ' ')"
  if (( bytes > 24576 )); then
    grep -Fqx '## Retrieval Map' "$page" || fail "${page#"$repo_root"/} exceeds 24KiB without a Retrieval Map"
  fi
  (( bytes <= 65536 )) || fail "${page#"$repo_root"/} exceeds 64KiB"
done < <(find "$repo_root/knowledge/wiki/sources" "$repo_root/knowledge/wiki/topics" -type f -name '*.md' -print0)

for skill_dir in "$repo_root"/skills/*; do
  [[ -d "$skill_dir" ]] || continue
  [[ "${skill_dir##*/}" != '_template' ]] || continue
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || { fail "Skill directory is missing SKILL.md: ${skill_dir##*/}"; continue; }
  validate_status_file "$skill_file"
  skill_name="$(frontmatter_value "$skill_file" name)"
  [[ "$skill_name" == "${skill_dir##*/}" ]] || fail "${skill_file#"$repo_root"/} name must match its directory"
  [[ -n "$(frontmatter_value "$skill_file" description)" ]] || fail "${skill_file#"$repo_root"/} is missing description"
  bytes="$(wc -c < "$skill_file" | tr -d ' ')"
  (( bytes <= 20480 )) || fail "${skill_file#"$repo_root"/} exceeds 20KiB"
done

for project_dir in "$repo_root"/projects/*; do
  [[ -d "$project_dir" ]] || continue
  project_name="${project_dir##*/}"
  [[ "$project_name" != '_template' ]] || continue
  [[ ! -d "$project_dir/.git" ]] || continue
  if [[ -f "$project_dir/PROJECT.md" || -f "$project_dir/STATE.md" ]]; then
    [[ -f "$project_dir/PROJECT.md" ]] || fail "projects/$project_name is missing PROJECT.md"
    [[ -f "$project_dir/STATE.md" ]] || fail "projects/$project_name is missing STATE.md"
    validate_status_file "$project_dir/PROJECT.md"
    if [[ -d "$project_dir/docs" || -f "$project_dir/ARCHITECTURE.md" ]]; then
      [[ -f "$project_dir/AGENTS.md" ]] || fail "projects/$project_name needs AGENTS.md to route optional docs"
    fi
    [[ ! -f "$project_dir/AGENTS.md" ]] || check_size "projects/$project_name/AGENTS.md" 2048 "projects/$project_name/AGENTS.md"
  fi
done

if [[ -f "$repo_root/tools/control-policy.tsv" ]]; then
  awk -F '\t' '
    /^($|#)/ { next }
    $1 !~ /^(exempt|forbidden|frozen|guarded|contract)$/ || $2 == "" || NF > 3 { bad = 1 }
    END { exit bad }
  ' "$repo_root/tools/control-policy.tsv" || fail 'tools/control-policy.tsv has an invalid row'
  pins=('forbidden:.env*' 'frozen:knowledge/raw/*' 'frozen:knowledge/wiki/logs/*' 'guarded:AGENTS.md' 'guarded:skills/SKILLS.md' 'guarded:tools/SAFETY.md' 'guarded:tools/CONTROL.md' 'guarded:tools/TOOLS.md' 'guarded:tools/control-policy.tsv' 'guarded:tools/check-boundary.sh' 'guarded:tools/install-git-hooks.sh' 'guarded:tools/validate-agent-directory.sh' 'guarded:tools/task.sh' 'contract:projects/*/PROJECT.md')
  for pin in "${pins[@]}"; do
    tier="${pin%%:*}"
    pattern="${pin#*:}"
    awk -F '\t' -v tier="$tier" -v pattern="$pattern" '$1 == tier && $2 == pattern { found = 1 } END { exit !found }' "$repo_root/tools/control-policy.tsv" || fail "control policy lost: $pin"
  done
fi

while IFS= read -r script; do
  /bin/bash -n "$repo_root/$script" || fail "$script fails bash -n"
done < <(cd "$repo_root" && find tools -type f -name '*.sh' -print | LC_ALL=C sort)

executables=(tools/append-knowledge-log.sh tools/build-context-cache.sh tools/check-boundary.sh tools/find-context.sh tools/install-git-hooks.sh tools/materialize-project-repositories.sh tools/task.sh tools/validate-agent-directory.sh)
for executable in "${executables[@]}"; do
  [[ -x "$repo_root/$executable" ]] || fail "$executable is not executable"
done

if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  tracked_forbidden=''
  while IFS= read -r tracked_path; do
    [[ -n "$tracked_path" && -e "$repo_root/$tracked_path" ]] || continue
    tracked_forbidden="${tracked_forbidden}${tracked_path}\n"
  done < <(git -C "$repo_root" ls-files | grep -E '(^|/)(\.env($|\.)|\.DS_Store$|\.agent-cache/|\.tmp/)' || true)
  [[ -z "$tracked_forbidden" ]] || fail "forbidden generated or secret-bearing paths are tracked"
fi

if [[ -n "$base_ref" ]]; then
  git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 || fail "base ref does not resolve: $base_ref"
  if (( failures == 0 )); then
    boundary_output="$(cd "$repo_root" && bash tools/check-boundary.sh --base "$base_ref" 2>&1)" || {
      fail "boundary check failed from $base_ref: $boundary_output"
    }
  fi
fi

if [[ "$full" == true ]]; then
  reference_output="$(bash "$repo_root/tools/validator/check-markdown-references.sh" "$repo_root" 2>&1)" || {
    fail "Markdown reference validation failed"
    [[ -z "$reference_output" ]] || printf '%s\n' "$reference_output" >&2
  }
  if (( failures == 0 )); then
    bash "$repo_root/tools/build-context-cache.sh" >/dev/null || fail 'context cache generation failed'
    bash "$repo_root/tools/build-context-cache.sh" --check >/dev/null || fail 'context cache check failed'
  fi
  if (( failures == 0 )); then
    materialize_output="$(bash "$repo_root/tools/materialize-project-repositories.sh" --all --check 2>&1)" || fail "Independent Project check failed: $materialize_output"
  fi
fi

if (( failures > 0 )); then
  printf 'FAILED: %s structural issue(s), %s warning(s)\n' "$failures" "$warnings" >&2
  exit 1
fi

if [[ "$full" == true ]] && git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  staged_count="$(git -C "$repo_root" diff --cached --name-only | wc -l | tr -d ' ')"
  if (( staged_count > 0 )); then
    receipt_tree="$(git -C "$repo_root" write-tree 2>/dev/null)" || {
      printf 'FAILED: cannot bind full-validation receipt to the staged index\n' >&2
      exit 1
    }
    receipt_root="$(git -C "$repo_root" rev-parse --git-path agent-control)"
    case "$receipt_root" in /*) ;; *) receipt_root="$repo_root/$receipt_root" ;; esac
    mkdir -p "$receipt_root/receipts"
    rm -f "$receipt_root/receipts/"* 2>/dev/null || true
    printf 'tree=%s\n' "$receipt_tree" > "$receipt_root/receipts/$receipt_tree"
    printf 'RECEIPT: full-validation receipt issued for index tree %s\n' "$receipt_tree"
  fi
fi

[[ "$changed" != true ]] || printf 'NOTE: --changed uses the complete static contract\n' >&2
printf 'PASS: agent-directory structure is valid (%s warning(s))\n' "$warnings"
