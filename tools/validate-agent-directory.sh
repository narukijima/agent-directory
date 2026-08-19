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
tool_fixture_root=''

cleanup() {
  [[ -z "$tool_fixture_root" ]] || rm -rf -- "$tool_fixture_root"
}
trap cleanup EXIT

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

validate_tool_behaviors() {
  local fixture_root append_root append_output
  local control_root control_output hook_output head_sha zero_sha push_output
  local materialize_root upstream_work upstream_bare adopted_sha materialize_output

  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-directory-tool-test.XXXXXX")"
  tool_fixture_root="$fixture_root"

  # Knowledge LOG: the 1,000th record must rotate to a closed quarterly log and leave
  # only the current header in LOG.md.
  append_root="$fixture_root/append"
  mkdir -p "$append_root/knowledge/wiki"
  printf '# Knowledge Log\n\n---\n' > "$append_root/knowledge/wiki/LOG.md"
  awk 'BEGIN { for (i = 1; i <= 999; i++) print "2026-08-01  ingest      knowledge/wiki/topics/example.md  fixture" }' \
    >> "$append_root/knowledge/wiki/LOG.md"
  append_output="$(AGENT_DIRECTORY_ROOT="$append_root" bash "$repo_root/tools/append-knowledge-log.sh" \
    --date 2026-08-19 --type ingest --target knowledge/wiki/topics/final.md --summary fixture 2>&1)" || \
    fail "append-knowledge-log.sh self-check failed: $append_output"
  printf '%s\n' "$append_output" | grep -Fq 'ROTATED: knowledge/wiki/logs/2026-Q3.md' || \
    fail 'append-knowledge-log.sh did not rotate at the documented threshold'
  grep -Fq 'knowledge/wiki/topics/final.md' "$append_root/knowledge/wiki/logs/2026-Q3.md" 2>/dev/null || \
    fail 'append-knowledge-log.sh rotation lost the appended record'
  [[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$append_root/knowledge/wiki/LOG.md" || true)" == '0' ]] || \
    fail 'append-knowledge-log.sh did not reset the current log after rotation'

  # Git boundary: install only committed snapshots, allow an ordinary commit, reject a
  # forbidden path, and exercise both managed hook entrypoints.
  control_root="$fixture_root/control"
  mkdir -p "$control_root/tools/hooks" "$control_root/projects"
  cp "$repo_root/tools/install-git-hooks.sh" "$control_root/tools/install-git-hooks.sh"
  cp "$repo_root/tools/check-boundary.sh" "$control_root/tools/check-boundary.sh"
  cp "$repo_root/tools/control-policy.tsv" "$control_root/tools/control-policy.tsv"
  cp "$repo_root/tools/hooks/pre-commit" "$control_root/tools/hooks/pre-commit"
  cp "$repo_root/tools/hooks/pre-push" "$control_root/tools/hooks/pre-push"
  git -C "$control_root" init -q
  git -C "$control_root" config user.name 'Agent Directory Fixture'
  git -C "$control_root" config user.email 'fixture@example.invalid'
  git -C "$control_root" add tools
  git -C "$control_root" commit -qm 'Create control fixture'
  hook_output="$(AGENT_DIRECTORY_ROOT="$control_root" bash "$control_root/tools/install-git-hooks.sh" --install 2>&1)" || \
    fail "install-git-hooks.sh install self-check failed: $hook_output"
  printf '%s\n' "$hook_output" | grep -Fqx 'HOOKS_INSTALLED hooks=2 independent=0' || \
    fail 'install-git-hooks.sh did not install both managed hooks'
  hook_output="$(AGENT_DIRECTORY_ROOT="$control_root" bash "$control_root/tools/install-git-hooks.sh" --status 2>&1)" || \
    fail "install-git-hooks.sh status self-check failed: $hook_output"
  printf '%s\n' "$hook_output" | grep -Fq 'pre-commit=managed pre-push=managed' || \
    fail 'install-git-hooks.sh did not report managed hooks'

  printf 'ordinary\n' > "$control_root/ordinary.txt"
  git -C "$control_root" add ordinary.txt
  control_output="$(cd "$control_root" && AGENT_DIRECTORY_ROOT="$control_root" \
    /bin/bash tools/check-boundary.sh --staged --policy tools/control-policy.tsv 2>&1)" || \
    fail "check-boundary.sh ordinary self-check failed: $control_output"
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail 'check-boundary.sh did not allow an ordinary staged path'
  control_output="$(git -C "$control_root" commit -qm 'Add ordinary fixture' 2>&1)" || \
    fail "managed pre-commit ordinary self-check failed: $control_output"

  head_sha="$(git -C "$control_root" rev-parse HEAD)"
  zero_sha='0000000000000000000000000000000000000000'
  push_output="$(cd "$control_root" && \
    printf 'refs/heads/main %s refs/heads/main %s\n' "$head_sha" "$zero_sha" | \
    .git/hooks/pre-push origin 2>&1)" || \
    fail "managed pre-push self-check failed: $push_output"

  printf 'fixture-secret-value-1234567890\n' > "$control_root/.env"
  git -C "$control_root" add -f .env
  if control_output="$(cd "$control_root" && AGENT_DIRECTORY_ROOT="$control_root" \
      /bin/bash tools/check-boundary.sh --staged --policy tools/control-policy.tsv 2>&1)"; then
    fail 'check-boundary.sh allowed the forbidden .env path'
  elif ! printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_BLOCKED'; then
    fail "check-boundary.sh returned an unexpected forbidden-path result: $control_output"
  fi
  if git -C "$control_root" commit -qm 'Must be rejected' >/dev/null 2>&1; then
    fail 'managed pre-commit allowed the forbidden .env path'
  fi

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
  'evals/EVALS.md'
  'evals/TRACE.md'
  'evals/profiles/core.txt'
  'tools/CONTROL.md'
  'tools/SAFETY.md'
  'tools/TOOLS.md'
  'tools/append-knowledge-log.sh'
  'tools/check-boundary.sh'
  'tools/control-policy.tsv'
  'tools/hooks/pre-commit'
  'tools/hooks/pre-push'
  'tools/install-git-hooks.sh'
  'tools/lib/project-registry.sh'
  'tools/materialize-project-repositories.sh'
  'tools/run-evals.py'
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
tools/check-boundary.sh
tools/control-policy.tsv
tools/hooks/pre-commit
tools/hooks/pre-push
tools/install-git-hooks.sh
tools/lib/project-registry.sh
tools/materialize-project-repositories.sh
tools/run-evals.py
tools/validate-agent-directory.sh
tools/validator/check-markdown-references.sh
TOOLS
)"
actual_tools="$(
  cd "$repo_root"
  find tools -type f -not -name '.DS_Store' -not -path '*/__pycache__/*' -print | LC_ALL=C sort
)"
if [[ "$actual_tools" != "$expected_tools" ]]; then
  fail 'tools/ differs from the 14-file owner-approved allowlist'
  diff -u <(printf '%s\n' "$expected_tools") <(printf '%s\n' "$actual_tools") >&2 || true
fi

expected_evals="$(cat <<'EVALS'
evals/EVALS.md
evals/TRACE.md
evals/cases/context-budget-stop.yaml
evals/cases/independent-root-content-boundary.yaml
evals/cases/owner-gated-permanent-addition.yaml
evals/cases/project-goal-change-protection.yaml
evals/cases/protect-immutable-records.yaml
evals/cases/protect-paused-project.yaml
evals/cases/route-to-knowledge.yaml
evals/cases/route-to-project.yaml
evals/cases/route-to-skill.yaml
evals/fixtures/active-project/projects/market-scan/AGENTS.md
evals/fixtures/active-project/projects/market-scan/PROJECT.md
evals/fixtures/active-project/projects/market-scan/STATE.md
evals/fixtures/active-project/projects/market-scan/inputs/quarter.csv
evals/fixtures/active-project/projects/market-scan/outputs/quarterly-report.md
evals/fixtures/active-project/projects/market-scan/scripts/verify-report.sh
evals/fixtures/active-skill/skills/literature-review/SKILL.md
evals/fixtures/eval-runtime/case.yaml
evals/fixtures/eval-runtime/pass.jsonl
evals/fixtures/independent-project/projects/.gitignore
evals/fixtures/independent-project/projects/REPOSITORIES.md
evals/fixtures/independent-project/projects/data-pipeline/AGENTS.md
evals/fixtures/independent-project/projects/data-pipeline/PROJECT.md
evals/fixtures/independent-project/projects/data-pipeline/STATE.md
evals/fixtures/protect-paused-project/projects/market-scan/PROJECT.md
evals/fixtures/protect-paused-project/projects/market-scan/STATE.md
evals/profiles/core.txt
EVALS
)"
actual_evals="$(
  cd "$repo_root"
  find evals -type f -print | LC_ALL=C sort
)"
if [[ "$actual_evals" != "$expected_evals" ]]; then
  fail 'evals/ differs from the owner-approved 9-case Core suite'
  diff -u <(printf '%s\n' "$expected_evals") <(printf '%s\n' "$actual_evals") >&2 || true
fi

profile_cases="$(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/evals/profiles/core.txt" | LC_ALL=C sort)"
actual_cases="$(find "$repo_root/evals/cases" -type f -name '*.yaml' -exec basename {} .yaml \; | LC_ALL=C sort)"
[[ "$profile_cases" == "$actual_cases" ]] || fail 'evals/profiles/core.txt must list every Core case exactly once'

for heading in '## 自己定義' '## 共通判断原則' '## Route' '## Context Loading' '## 自律実行' '## 差分判定' '## 人間へ上げる例外' '## 禁止事項' '## 参照順序'; do
  grep -Fqx "$heading" "$repo_root/AGENTS.md" || fail "AGENTS.md is missing heading: $heading"
done
grep -Fq '新しいTool、Skill、恒久的な仕組み、抽象化、依存は原則追加しない' "$repo_root/AGENTS.md" || fail 'AGENTS.md lost the owner gate for permanent additions'
grep -Fq 'Skillの新設は既存Skillの更新・統合で目的を満たせない場合だけ候補' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md lost the owner gate'
grep -Fq '新しいToolは原則追加しない' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md lost the Tool owner gate'
grep -Fq 'validatorはそれらを' "$repo_root/README.md" || fail 'README.md must allow downstream Runtime adapters'
grep -Fq 'これはRuntimeが一時的なsession isolationや並列作業にGit worktreeを使うことを' "$repo_root/README.md" || fail 'README.md must allow Runtime worktrees'
grep -Fq 'Skill discovery、選択、起動、subagent実行を行わない' "$repo_root/skills/SKILLS.md" || fail 'skills/SKILLS.md must remain a source contract, not a Skill runtime'
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
  pins=('forbidden:.env*' 'frozen:knowledge/raw/*' 'frozen:knowledge/wiki/logs/*' 'guarded:AGENTS.md' 'guarded:skills/SKILLS.md' 'guarded:tools/SAFETY.md' 'guarded:tools/CONTROL.md' 'guarded:tools/TOOLS.md' 'guarded:tools/control-policy.tsv' 'guarded:tools/check-boundary.sh' 'guarded:tools/install-git-hooks.sh' 'guarded:tools/validate-agent-directory.sh' 'guarded:tools/run-evals.py' 'guarded:evals/*' 'contract:projects/*/PROJECT.md')
  for pin in "${pins[@]}"; do
    tier="${pin%%:*}"
    pattern="${pin#*:}"
    awk -F '\t' -v tier="$tier" -v pattern="$pattern" '$1 == tier && $2 == pattern { found = 1 } END { exit !found }' "$repo_root/tools/control-policy.tsv" || fail "control policy lost: $pin"
  done
fi

while IFS= read -r script; do
  /bin/bash -n "$repo_root/$script" || fail "$script fails bash -n"
done < <(cd "$repo_root" && find tools -type f -name '*.sh' -print | LC_ALL=C sort)

python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$repo_root/tools/run-evals.py" || fail 'tools/run-evals.py has invalid Python syntax'

executables=(tools/append-knowledge-log.sh tools/check-boundary.sh tools/install-git-hooks.sh tools/materialize-project-repositories.sh tools/validate-agent-directory.sh)
executables+=(tools/run-evals.py)
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
    materialize_output="$(bash "$repo_root/tools/materialize-project-repositories.sh" --all --check 2>&1)" || fail "Independent Project check failed: $materialize_output"
  fi
  if (( failures == 0 )); then
    eval_schema_output="$(cd "$repo_root" && python3 tools/run-evals.py validate 2>&1)" || fail "Core eval case validation failed: $eval_schema_output"
    printf '%s\n' "$eval_schema_output" | grep -Fqx 'EVAL_CASES_VALID count=9' || fail 'Core eval case validation did not cover the 9-case suite'
  fi
  if (( failures == 0 )); then
    eval_output="$(cd "$repo_root" && python3 tools/run-evals.py score --case evals/fixtures/eval-runtime/case.yaml --trace evals/fixtures/eval-runtime/pass.jsonl 2>&1)" || fail "Core eval runner self-check failed: $eval_output"
    printf '%s\n' "$eval_output" | grep -Fq 'status=PASS' || fail 'Core eval runner self-check did not report PASS'
  fi
  if (( failures == 0 )); then
    validate_tool_behaviors
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
