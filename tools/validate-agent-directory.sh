#!/usr/bin/env bash
set -euo pipefail

# Small, provider-independent validator for the public Agent Workspace contract.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_root/.." && pwd -P)"
strict=false
full=false
changed=false
bootstrap_status=false
failures=0
warnings=0
tool_fixture_root=''

cleanup() {
  [[ -z "$tool_fixture_root" ]] || rm -rf -- "$tool_fixture_root"
}
trap cleanup EXIT

usage() {
  printf 'Usage: %s [--strict] [--full] [--changed] [--bootstrap-status]\n' "${0##*/}" >&2
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
    --bootstrap-status) bootstrap_status=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ "$bootstrap_status" == true ]]; then
  [[ "$strict" == false && "$full" == false && "$changed" == false ]] || {
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

frontmatter_metadata_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && $0 == "metadata:" { in_metadata = 1; next }
    in_metadata && /^[^[:space:]]/ { in_metadata = 0 }
    in_metadata && /^[[:space:]]/ {
      value = $0
      sub(/^[[:space:]]+/, "", value)
      if (index(value, key ":") != 1) next
      value = substr(value, length(key) + 2)
      sub(/^[[:space:]]*/, "", value)
      gsub(/^['\''\"]|['\''\"]$/, "", value)
      print value
      exit
    }
  ' "$file"
}

frontmatter_has_key() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && index($0, key ":") == 1 { found = 1; exit }
    END { exit !found }
  ' "$file"
}

frontmatter_metadata_has_key() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && $0 == "metadata:" { in_metadata = 1; next }
    in_metadata && /^[^[:space:]]/ { in_metadata = 0 }
    in_metadata && /^[[:space:]]/ {
      value = $0
      sub(/^[[:space:]]+/, "", value)
      if (index(value, key ":") == 1) { found = 1; exit }
    }
    END { exit !found }
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

validate_skill_frontmatter() {
  local file="$1" status legacy_status aliases legacy_aliases key name description compatibility
  [[ -f "$file" ]] || return 0
  [[ "$(sed -n '1p' "$file")" == '---' ]] || {
    fail "${file#"$repo_root"/} must start with YAML frontmatter"
    return 0
  }
  status="$(frontmatter_metadata_value "$file" agent-directory.status)"
  legacy_status="$(frontmatter_value "$file" status)"
  if [[ -n "$status" && -n "$legacy_status" && "$status" != "$legacy_status" ]]; then
    fail "${file#"$repo_root"/} has conflicting standard and legacy status metadata"
    return 0
  fi
  if frontmatter_has_key "$file" status || frontmatter_has_key "$file" aliases || \
    frontmatter_has_key "$file" replaced_by; then
    if [[ "$strict" == true ]]; then
      fail "${file#"$repo_root"/} uses legacy top-level Skill lifecycle fields"
    else
      warn "${file#"$repo_root"/} uses legacy top-level Skill lifecycle fields"
    fi
  fi
  [[ -n "$status" ]] || status="$legacy_status"
  case "$status" in
    active|deprecated|retired) ;;
    '') fail "${file#"$repo_root"/} is missing metadata agent-directory.status" ;;
    *) fail "${file#"$repo_root"/} has invalid Skill status: $status" ;;
  esac

  aliases="$(frontmatter_metadata_value "$file" agent-directory.aliases)"
  legacy_aliases="$(frontmatter_value "$file" aliases)"
  if ! frontmatter_metadata_has_key "$file" agent-directory.aliases; then
    if frontmatter_has_key "$file" aliases && [[ "$strict" != true ]]; then
      aliases="$legacy_aliases"
    else
      fail "${file#"$repo_root"/} is missing metadata agent-directory.aliases"
    fi
  fi
  if [[ "$aliases" == ,* || "$aliases" == *, || "$aliases" == *,,* ]]; then
    fail "${file#"$repo_root"/} has invalid comma-separated Skill aliases"
  fi

  while IFS= read -r key; do
    case "$key" in
      name|description|license|compatibility|metadata|allowed-tools) ;;
      status|aliases|replaced_by) ;; # Legacy consumer compatibility; do not emit these in new Skills.
      *) fail "${file#"$repo_root"/} has non-standard top-level Skill field: $key" ;;
    esac
  done < <(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && match($0, /^[a-z][a-z0-9_-]*:/) { print substr($0, 1, RLENGTH - 1) }
  ' "$file")

  name="$(frontmatter_value "$file" name)"
  description="$(frontmatter_value "$file" description)"
  compatibility="$(frontmatter_value "$file" compatibility)"
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#name} -le 64 ]] || \
    fail "${file#"$repo_root"/} name does not follow the Agent Skills standard"
  (( ${#description} >= 1 && ${#description} <= 1024 )) || \
    fail "${file#"$repo_root"/} description must be 1-1024 characters"
  (( ${#description} <= 200 )) || \
    warn "${file#"$repo_root"/} description exceeds the 200-character discovery recommendation"
  [[ -z "$compatibility" || ${#compatibility} -le 500 ]] || \
    fail "${file#"$repo_root"/} compatibility must be at most 500 characters"
}

validate_skill_adapter() {
  local skill_name="$1" adapter="$2" expected
  expected="../../skills/$skill_name"
  if [[ -L "$repo_root/$adapter/$skill_name" ]]; then
    [[ "$(readlink "$repo_root/$adapter/$skill_name")" == "$expected" ]] || \
      fail "$adapter/$skill_name must link to $expected"
  elif [[ -e "$repo_root/$adapter/$skill_name" ]]; then
    fail "$adapter/$skill_name must be a symlink, not a second Skill copy"
  else
    if [[ "$strict" == true ]]; then
      fail "$adapter/$skill_name is missing; import or bridge the Skill through the native Runtime adapter"
    else
      warn "$adapter/$skill_name is missing; import or bridge the Skill through the native Runtime adapter"
    fi
  fi
}

validate_tool_behaviors() {
  local fixture_root
  local materialize_root upstream_work upstream_bare adopted_sha materialize_output
  local skill_source_root skill_target_root skill_import_output second_import_output

  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-directory-tool-test.XXXXXX")"
  tool_fixture_root="$fixture_root"

  # Skill import: preserve provenance, normalize portable frontmatter, and create
  # exactly one native symlink adapter for each supported Runtime.
  skill_source_root="$fixture_root/skill-source"
  skill_target_root="$fixture_root/skill-target"
  mkdir -p "$skill_source_root/tools" "$skill_target_root/tools"
  cp "$repo_root/AGENTS.md" "$skill_target_root/AGENTS.md"
  cp "$repo_root/tools/validate-agent-directory.sh" "$skill_target_root/tools/validate-agent-directory.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'skill_name="$1"' \
    'shift' \
    '[[ "$1" == "--target" && $# -eq 2 ]]' \
    'target_root="$2"' \
    'mkdir -p "$target_root/skills/$skill_name/agents"' \
    'printf '\''%s\n'\'' '\''---'\'' '\''name: sample-skill'\'' '\''description: Portable fixture Skill'\'' '\''status: active'\'' '\''aliases: ["sample", "fixture"]'\'' '\''metadata:'\'' '\''  claudagt.version: "1.0.0"'\'' '\''  claudagt.status: "active"'\'' '\''  claudagt.aliases: "sample,fixture"'\'' '\''---'\'' '\'''\'' '\''# Sample'\'' > "$target_root/skills/$skill_name/SKILL.md"' \
    'printf '\''%s\n'\'' '\''source_commit: "0123456789abcdef"'\'' > "$target_root/skills/$skill_name/agents/upstream.yaml"' \
    > "$skill_source_root/tools/import-skill.sh"
  chmod 755 "$skill_source_root/tools/import-skill.sh"
  skill_import_output="$(AGENT_DIRECTORY_ROOT="$skill_target_root" \
    bash "$repo_root/tools/import-skill.sh" sample-skill --source "$skill_source_root" 2>&1)" || \
    fail "import-skill.sh self-check failed: $skill_import_output"
  printf '%s\n' "$skill_import_output" | grep -Fq \
    'SKILL_IMPORT_OK skill=sample-skill source_commit=0123456789abcdef adapters=2' || \
    fail 'import-skill.sh did not emit its deterministic success receipt'
  grep -Fq 'agent-directory.status: "active"' "$skill_target_root/skills/sample-skill/SKILL.md" || \
    fail 'import-skill.sh did not normalize lifecycle metadata'
  grep -Fq 'agent-directory.aliases: "sample,fixture"' "$skill_target_root/skills/sample-skill/SKILL.md" || \
    fail 'import-skill.sh did not normalize aliases metadata'
  ! grep -Eq '^(status|aliases|replaced_by):' "$skill_target_root/skills/sample-skill/SKILL.md" || \
    fail 'import-skill.sh retained non-standard top-level lifecycle fields'
  [[ "$(readlink "$skill_target_root/.agents/skills/sample-skill")" == '../../skills/sample-skill' ]] || \
    fail 'import-skill.sh did not create the Codex Skill adapter'
  [[ "$(readlink "$skill_target_root/.claude/skills/sample-skill")" == '../../skills/sample-skill' ]] || \
    fail 'import-skill.sh did not create the Claude Code Skill adapter'
  if second_import_output="$(AGENT_DIRECTORY_ROOT="$skill_target_root" \
      bash "$repo_root/tools/import-skill.sh" sample-skill --source "$skill_source_root" 2>&1)"; then
    fail 'import-skill.sh overwrote an existing Skill'
  fi
  [[ -f "$skill_target_root/skills/sample-skill/SKILL.md" && \
     -L "$skill_target_root/.agents/skills/sample-skill" && \
     -L "$skill_target_root/.claude/skills/sample-skill" ]] || \
    fail 'import-skill.sh damaged existing canon or adapters after a rejected reimport'

  # Independent Project: clone one local fixture at the exact registered revision,
  # then verify that a second --check observes the same clean attachment.
  materialize_root="$fixture_root/materialize"
  upstream_work="$fixture_root/upstream-work"
  upstream_bare="$fixture_root/upstream.git"
  mkdir -p "$upstream_work"
  git -C "$upstream_work" init -q
  git -C "$upstream_work" config user.name 'Agent Directory Fixture'
  git -C "$upstream_work" config user.email 'fixture@example.invalid'
  printf '%s\n' '---' 'name: sample' 'status: active' '---' '# Sample' > "$upstream_work/PROJECT.md"
  printf '%s\n' '---' 'status: active' '---' '# State' > "$upstream_work/STATE.md"
  git -C "$upstream_work" add PROJECT.md STATE.md
  git -C "$upstream_work" commit -qm 'Create independent fixture'
  adopted_sha="$(git -C "$upstream_work" rev-parse HEAD)"
  git clone -q --bare "$upstream_work" "$upstream_bare"

  mkdir -p "$materialize_root/projects" "$materialize_root/tools"
  printf '# Fixture Agent\n' > "$materialize_root/AGENTS.md"
  printf '#!/bin/sh\nexit 0\n' > "$materialize_root/tools/validate-agent-directory.sh"
  chmod 755 "$materialize_root/tools/validate-agent-directory.sh"
  printf '%s\n' '# Independent repositories' '' '## `sample`' \
    "- repository_url: \`$upstream_bare\`" '- repository_reason: `distribution`' \
    "- revision: \`$adopted_sha\`" > "$materialize_root/projects/REPOSITORIES.md"
  printf '%s\n' '# BEGIN INDEPENDENT PROJECTS' '/sample/' '# END INDEPENDENT PROJECTS' \
    > "$materialize_root/projects/.gitignore"
  git -C "$materialize_root" init -q
  git -C "$materialize_root" config user.name 'Agent Directory Fixture'
  git -C "$materialize_root" config user.email 'fixture@example.invalid'
  git -C "$materialize_root" add AGENTS.md projects tools
  git -C "$materialize_root" commit -qm 'Create materialization fixture'
  materialize_output="$(AGENT_DIRECTORY_ROOT="$materialize_root" AGENT_ALLOW_LOCAL_REPOSITORY_URL=true \
    bash "$repo_root/tools/materialize-project-repositories.sh" --all 2>&1)" || \
    fail "materialize-project-repositories.sh clone self-check failed: $materialize_output"
  printf '%s\n' "$materialize_output" | grep -Fq 'MATERIALIZATION_OK total=1 cloned=1 verified=0' || \
    fail 'materialize-project-repositories.sh did not clone the registered revision'
  materialize_output="$(AGENT_DIRECTORY_ROOT="$materialize_root" AGENT_ALLOW_LOCAL_REPOSITORY_URL=true \
    bash "$repo_root/tools/materialize-project-repositories.sh" --all --check 2>&1)" || \
    fail "materialize-project-repositories.sh verify self-check failed: $materialize_output"
  printf '%s\n' "$materialize_output" | grep -Fq 'MATERIALIZATION_OK total=1 cloned=0 verified=1' || \
    fail 'materialize-project-repositories.sh did not verify the adopted revision'

  rm -rf "$fixture_root"
  tool_fixture_root=''
}

required_files=(
  '.gitignore'
  '.agents/skills/.gitkeep'
  '.claude/skills/.gitkeep'
  'AGENTS.md'
  'CLAUDE.md'
  'LICENSE'
  'README.md'
  'knowledge/KNOWLEDGE.md'
  'knowledge/wiki/INDEX.md'
  'knowledge/wiki/_template/SOURCE.md'
  'knowledge/wiki/_template/TOPIC.md'
  'skills/SKILLS.md'
  'skills/_template/SKILL.md'
  'projects/AGENTS.md'
  'projects/LIFECYCLE.md'
  'projects/PROJECTS.md'
  'projects/REPOSITORIES.md'
  'projects/.gitignore'
  'projects/_template/PROJECT.md'
  'projects/_template/STATE.md'
  'tools/SAFETY.md'
  'tools/TOOLS.md'
  'tools/import-skill.sh'
  'tools/lib/project-registry.sh'
  'tools/materialize-project-repositories.sh'
  'tools/validate-agent-directory.sh'
  'tools/validator/check-markdown-references.sh'
)
for path in "${required_files[@]}"; do
  require_file "$path"
done

expected_tools="$(cat <<'TOOLS'
tools/SAFETY.md
tools/TOOLS.md
tools/import-skill.sh
tools/lib/project-registry.sh
tools/materialize-project-repositories.sh
tools/validate-agent-directory.sh
tools/validator/check-markdown-references.sh
TOOLS
)"
actual_tools="$(
  cd "$repo_root"
  find tools -type f -not -name '.DS_Store' -not -path '*/__pycache__/*' -print | LC_ALL=C sort
)"
if [[ "$actual_tools" != "$expected_tools" ]]; then
  fail 'tools/ differs from the 7-file owner-approved allowlist'
  diff -u <(printf '%s\n' "$expected_tools") <(printf '%s\n' "$actual_tools") >&2 || true
fi

for heading in '## 自己定義' '## 共通判断原則' '## Route' '## Context Loading' '## 自律実行' '## 差分判定' '## 人間へ上げる例外' '## 禁止事項' '## 参照順序'; do
  grep -Fqx "$heading" "$repo_root/AGENTS.md" || fail "AGENTS.md is missing heading: $heading"
done
grep -Fq '新しいTool、Skill、恒久的な仕組み、抽象化、依存は原則追加しない' "$repo_root/AGENTS.md" || fail 'AGENTS.md lost the owner gate for permanent additions'
[[ "$(cat "$repo_root/CLAUDE.md")" == '@AGENTS.md' ]] || fail 'CLAUDE.md must only import the AGENTS.md canon'
grep -Fq 'Skillの新設は既存Skillの更新・統合で目的を満たせない場合だけ候補' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md lost the owner gate'
grep -Fq 'Agent Skills公開標準に従うProvider間共有source' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md lost the Agent Skills standard boundary'
grep -Fq 'agent-directory.status: "active"' "$repo_root/skills/_template/SKILL.md" || fail 'Skill template must use namespaced standard metadata'
grep -Fq '新しいToolは原則追加しない' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md lost the Tool owner gate'
grep -Fq 'validatorはそれらを' "$repo_root/README.md" || fail 'README.md must allow downstream Runtime adapters'
grep -Fq 'これはRuntimeが一時的なsession isolationや並列作業にGit worktreeを使うことを' "$repo_root/README.md" || fail 'README.md must allow Runtime worktrees'
grep -Fq 'Skill discovery、選択、起動、subagent実行を行わない' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md must remain a source contract, not a Skill runtime'

if [[ "$strict" == true ]] && grep -Eq '<agent-name>|<agent-role>|<agent-mission>|<agent-vision>|<operator-language>' "$repo_root/AGENTS.md"; then
  fail 'AGENTS.md contains unresolved deployment placeholders'
fi

check_size 'AGENTS.md' 8192 'root AGENTS.md'
check_size 'projects/AGENTS.md' 2048 'projects/AGENTS.md'
check_size 'knowledge/KNOWLEDGE.md' 20480 'knowledge/KNOWLEDGE.md'
check_size 'skills/SKILLS.md' 20480 'skills/SKILLS.md'
check_size 'projects/PROJECTS.md' 24576 'projects/PROJECTS.md'
check_size 'tools/TOOLS.md' 20480 'tools/TOOLS.md'
check_size 'tools/SAFETY.md' 20480 'tools/SAFETY.md'
check_size 'knowledge/wiki/INDEX.md' 8192 'knowledge/wiki/INDEX.md'

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
  validate_skill_frontmatter "$skill_file"
  skill_name="$(frontmatter_value "$skill_file" name)"
  [[ "$skill_name" == "${skill_dir##*/}" ]] || fail "${skill_file#"$repo_root"/} name must match its directory"
  [[ -n "$(frontmatter_value "$skill_file" description)" ]] || fail "${skill_file#"$repo_root"/} is missing description"
  validate_skill_adapter "$skill_name" '.agents/skills'
  validate_skill_adapter "$skill_name" '.claude/skills'
  skill_status="$(frontmatter_metadata_value "$skill_file" agent-directory.status)"
  [[ -n "$skill_status" ]] || skill_status="$(frontmatter_value "$skill_file" status)"
  if [[ "$skill_status" == 'deprecated' ]]; then
    replacement="$(frontmatter_metadata_value "$skill_file" agent-directory.replaced-by)"
    [[ -n "$replacement" ]] || replacement="$(frontmatter_value "$skill_file" replaced_by)"
    if [[ ! "$replacement" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
      fail "${skill_file#"$repo_root"/} deprecated Skill is missing a valid metadata agent-directory.replaced-by"
    elif [[ ! -f "$repo_root/skills/$replacement/SKILL.md" ]]; then
      fail "${skill_file#"$repo_root"/} replacement Skill does not exist: $replacement"
    else
      replacement_status="$(frontmatter_metadata_value "$repo_root/skills/$replacement/SKILL.md" agent-directory.status)"
      [[ "$replacement_status" == 'active' ]] || \
        fail "${skill_file#"$repo_root"/} replacement Skill is not active: $replacement"
    fi
  fi
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
    [[ ! -f "$project_dir/AGENTS.md" ]] || check_size "projects/$project_name/AGENTS.md" 2048 "projects/$project_name/AGENTS.md"
  fi
done

while IFS= read -r script; do
  /bin/bash -n "$repo_root/$script" || fail "$script fails bash -n"
done < <(cd "$repo_root" && find tools -type f -name '*.sh' -print | LC_ALL=C sort)

executables=(tools/import-skill.sh tools/materialize-project-repositories.sh tools/validate-agent-directory.sh)
for executable in "${executables[@]}"; do
  [[ -x "$repo_root/$executable" ]] || fail "$executable is not executable"
done

if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  tracked_forbidden=''
  while IFS= read -r tracked_path; do
    [[ -n "$tracked_path" && -e "$repo_root/$tracked_path" ]] || continue
    tracked_forbidden="${tracked_forbidden}${tracked_path}\n"
  done < <(git -C "$repo_root" ls-files | grep -E '(^|/)(\.env($|\.)|\.DS_Store$|\.tmp/|__pycache__/)' || true)
  [[ -z "$tracked_forbidden" ]] || fail "forbidden generated or secret-bearing paths are tracked"
fi

if [[ "$full" == true ]]; then
  reference_output="$(bash "$repo_root/tools/validator/check-markdown-references.sh" "$repo_root" 2>&1)" || {
    fail "Markdown reference validation failed"
    [[ -z "$reference_output" ]] || printf '%s\n' "$reference_output" >&2
  }
  if (( failures == 0 )); then
    materialize_output="$(bash "$repo_root/tools/materialize-project-repositories.sh" --all --check 2>&1)" || fail "Independent Project check failed: $materialize_output"
  fi
  if (( failures == 0 )); then
    validate_tool_behaviors
  fi
fi

if (( failures > 0 )); then
  printf 'FAILED: %s structural issue(s), %s warning(s)\n' "$failures" "$warnings" >&2
  exit 1
fi

[[ "$changed" != true ]] || printf 'NOTE: --changed uses the complete static contract\n' >&2
printf 'PASS: agent-directory structure is valid (%s warning(s))\n' "$warnings"
