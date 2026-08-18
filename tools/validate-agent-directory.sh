#!/usr/bin/env bash
set -euo pipefail

# Normalize to the physical path. A logical pwd does not match git rev-parse --show-toplevel, so checks would be skipped.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo_root/tools/lib/project-registry.sh"
failures=0
warnings=0
strict=false
full=false
changed=false
base_ref=''
validator_metrics_enabled="${AGENT_VALIDATOR_METRICS:-false}"
if [[ -n "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  validator_metrics_enabled=false
fi
validator_metrics_file=''
validator_metrics_started_ms=''
validator_metrics_last_ms=''

# Syntax-check against bash 3.2 as the compatibility floor. Fall back to the PATH bash where /bin/bash is absent.
syntax_bash='bash'
if [[ -x /bin/bash ]]; then
  syntax_bash='/bin/bash'
fi

# Reclaim temp files and resident fixture processes in one place, even when set -e aborts the run.
cleanup_paths=()
cleanup_pids=()
cleanup_tmp_paths() {
  local cleanup_path cleanup_pid
  if (( ${#cleanup_pids[@]} > 0 )); then
    for cleanup_pid in "${cleanup_pids[@]}"; do
      kill "$cleanup_pid" 2>/dev/null || true
      wait "$cleanup_pid" 2>/dev/null || true
    done
  fi
  (( ${#cleanup_paths[@]} > 0 )) || return 0
  for cleanup_path in "${cleanup_paths[@]}"; do
    rm -rf "$cleanup_path"
  done
}
trap cleanup_tmp_paths EXIT

validator_now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(round(time.time() * 1000))'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

validator_metric_checkpoint() {
  local phase="$1"
  local now duration
  [[ "$validator_metrics_enabled" == 'true' && -n "$validator_metrics_file" ]] || return 0
  now="$(validator_now_ms)"
  duration=$((now - validator_metrics_last_ms))
  printf '{"event":"phase","name":"%s","duration_ms":%s}\n' "$phase" "$duration" \
    >> "$validator_metrics_file"
  validator_metrics_last_ms="$now"
}

validator_metric_finish() {
  local now total
  [[ "$validator_metrics_enabled" == 'true' && -n "$validator_metrics_file" ]] || return 0
  now="$(validator_now_ms)"
  total=$((now - validator_metrics_started_ms))
  printf '{"event":"summary","wall_time_ms":%s}\n' "$total" >> "$validator_metrics_file"
  printf 'METRICS: %s\n' "$validator_metrics_file"
}

# Fixed Wiki Markdown files use uppercase names as canon. User-created sources/topics pages are exempt.
knowledge_index_path='knowledge/wiki/INDEX.md'
knowledge_log_path='knowledge/wiki/LOG.md'
knowledge_source_template_path='knowledge/wiki/_template/SOURCE.md'
knowledge_topic_template_path='knowledge/wiki/_template/TOPIC.md'
knowledge_index_file="$repo_root/$knowledge_index_path"
knowledge_log_file="$repo_root/$knowledge_log_path"
knowledge_source_template="$repo_root/$knowledge_source_template_path"
knowledge_topic_template="$repo_root/$knowledge_topic_template_path"

# Bootstrap placeholder set: single owner of the "is this tree deployed" predicate.
# Consumers (the strict check below and external adapters) query --bootstrap-status
# instead of carrying their own copy, so adding a field cannot desynchronize the predicates.
agent_definition_placeholders='<agent-name>|<agent-role>|<agent-mission>|<agent-vision>|<operator-language>|<project-dir>'

usage() {
  printf 'Usage: %s [--strict] [--full] [--changed] [--base <git-ref>] [--bootstrap-status]\n' "${0##*/}" >&2
}

bootstrap_status_mode=false
while (( $# > 0 )); do
  case "$1" in
    --strict) strict=true; shift ;;
    --full) full=true; shift ;;
    --changed) changed=true; shift ;;
    --bootstrap-status) bootstrap_status_mode=true; shift ;;
    --base)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

# --strict の placeholder 検査は full 静的経路にしか存在しない。--changed と組み合わせると
# scoped 経路では黙って素通りし、fallback 時だけ実行される（データ依存）ため、明示的に拒否する。
if [[ "$strict" == true && "$changed" == true && "$full" != true ]]; then
  printf 'ERROR: --strict needs the full static run; use --strict --full or drop --changed\n' >&2
  usage
  exit 2
fi

if [[ "$bootstrap_status_mode" == true ]]; then
  validator_metrics_enabled=false
fi
if [[ "$validator_metrics_enabled" == 'true' ]]; then
  validator_metrics_dir="${AGENT_CACHE_DIR:-$repo_root/.agent-cache}/metrics"
  mkdir -p "$validator_metrics_dir"
  validator_metrics_file="$validator_metrics_dir/validator-$(date -u '+%Y%m%dT%H%M%SZ')-$$.jsonl"
  validator_metrics_started_ms="$(validator_now_ms)"
  validator_metrics_last_ms="$validator_metrics_started_ms"
  printf '{"event":"trace","source":"harness","tool":"validate-agent-directory.sh","mode":"%s"}\n' \
    "$([[ "$full" == true ]] && printf full || ([[ "$changed" == true ]] && printf changed || printf standard))" \
    > "$validator_metrics_file"
fi

# Status query, not a check: prints the deployment state of this tree and exits 0.
# template = every core placeholder still present, deployed = none present, partial = otherwise.
if [[ "$bootstrap_status_mode" == true ]]; then
  bootstrap_present=0
  bootstrap_total=0
  bootstrap_ifs="$IFS"
  IFS='|'
  for bootstrap_placeholder in $agent_definition_placeholders; do
    case "$bootstrap_placeholder" in
      '<project-dir>') continue ;; # 任意箇所の残置検査用で、AGENTS.mdの必須置換フィールドではない
    esac
    bootstrap_total=$((bootstrap_total + 1))
    if grep -Fq "$bootstrap_placeholder" "$repo_root/AGENTS.md" 2>/dev/null; then
      bootstrap_present=$((bootstrap_present + 1))
    fi
  done
  IFS="$bootstrap_ifs"
  if (( bootstrap_present == 0 )) && \
    ! grep -Eq "$agent_definition_placeholders" "$repo_root/AGENTS.md" 2>/dev/null; then
    bootstrap_status='deployed'
  elif (( bootstrap_present == bootstrap_total )); then
    bootstrap_status='template'
  else
    bootstrap_status='partial'
  fi
  printf 'BOOTSTRAP_STATUS status=%s\n' "$bootstrap_status"
  exit 0
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

relative_path() {
  printf '%s' "${1#"$repo_root"/}"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "missing file: $(relative_path "$1")"
  fi
}

require_fixed_line() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]] && ! grep -Fqx -- "$line" "$file"; then
    fail "$(relative_path "$file") is missing: $line"
  fi
}

has_closed_frontmatter() {
  awk '
    NR == 1 && $0 != "---" { exit 1 }
    NR > 1 && $0 == "---" { found = 1; exit }
    END { exit !found }
  ' "$1"
}

frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub(/^[^:]+:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

frontmatter_key_count() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 { count++ }
    END { print count + 0 }
  ' "$1"
}

# Validate the managed block structure of projects/.gitignore and emit entries one per line.
ignore_block_records() {
  [[ -f "$1" ]] || { printf 'E\tmissing file\n'; return 0; }
  awk '
    $0 == "# BEGIN INDEPENDENT PROJECTS" {
      if (begin_count > 0) print "E\tduplicate BEGIN INDEPENDENT PROJECTS marker"
      begin_count++
      in_block = 1
      next
    }
    $0 == "# END INDEPENDENT PROJECTS" {
      if (!in_block) print "E\tEND INDEPENDENT PROJECTS without a matching BEGIN"
      end_count++
      in_block = 0
      next
    }
    in_block && $0 != "" { print "R\t" $0 }
    END {
      if (in_block) print "E\tunterminated managed block"
      if (begin_count != 1) print "E\tthe managed block must open exactly once"
      if (end_count != 1) print "E\tthe managed block must close exactly once"
    }
  ' "$1"
}

value_character_count() {
  printf '%s' "$1" | od -An -tu1 | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i < 128 || $i >= 192) count++
      }
    }
    END { print count + 0 }
  '
}

check_size() {
  local file="$1"
  local hard_limit="$2"
  local label="$3"
  local bytes
  [[ -f "$file" ]] || return 0
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes > hard_limit )); then
    fail "$(relative_path "$file") exceeds $label hard limit: ${bytes}B > ${hard_limit}B"
  elif (( bytes * 10 > hard_limit * 9 )); then
    # Hysteresis: the warning fires at 90% but the standard procedure metabolizes down to 80%,
    # so canon files do not hover at the boundary and re-trigger every session.
    warn "$(relative_path "$file") is above 90% of the $label hard limit: ${bytes}B / ${hard_limit}B; run tools/TOOLS.md#超過時の標準処理 now, without asking or reporting it as an open issue, until the file is at or below $(( hard_limit * 8 / 10 ))B (80%)"
  fi
}

check_heading_warning() {
  local file="$1"
  local warning_limit="$2"
  local count
  [[ -f "$file" ]] || return
  count="$(grep -Ec '^#{1,6} ' "$file" || true)"
  if (( count > warning_limit )); then
    warn "$(relative_path "$file") has $count headings; consider delegating details"
  fi
}

contains_template_placeholder() {
  local file="$1"
  grep -Fqf <(
    grep -Eho '<[^>]+>' \
      "$repo_root/projects/_template/PROJECT.md" \
      "$repo_root/projects/_template/STATE.md"
  ) "$file"
}

has_valid_project_criteria() {
  awk -v heading="$2" '
    /^## / { in_section = ($0 == heading); next }
    in_section && /^- / {
      has_item = 1
      if ($0 !~ /^- \*\*PC-(0[1-9]|[1-9][0-9])\*\* .+/) { invalid = 1; next }
      id = substr($0, 5, 5)
      if (seen[id]++) invalid = 1
    }
    /^- \*\*PC-/ && !in_section { invalid = 1 }
    END { exit !(has_item && !invalid) }
  ' "$1"
}

state_section_targets() {
  awk -v heading="$2" -v prefix="$3" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && index($0, prefix) == 1 {
      target = $0
      sub(/^.*PROJECT\.md#/, "", target)
      sub(/`.*$/, "", target)
      if (target ~ /^(PC-(0[1-9]|[1-9][0-9])|status)$/) print target
    }
  ' "$1"
}

section_contains() {
  awk -v heading="$2" -v value="$3" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && index($0, value) > 0 { found = 1 }
    END { exit !found }
  ' "$1"
}

required_reference_count() {
  local file="$1"
  local section="$2"
  awk -v section="$section" '
    /^## / { in_section = ($0 == section); in_required = 0; next }
    in_section && /^### / { in_required = ($0 == "### Required"); next }
    in_section && in_required && /^- / && $0 != "- なし" { count++ }
    END { print count + 0 }
  ' "$file"
}

required_references() {
  awk '
    /^## / {
      in_reference_section = ($0 == "## 使用するKnowledge" || $0 == "## 使用するSkill")
      in_required = 0
      next
    }
    in_reference_section && /^### / {
      in_required = ($0 == "### Required")
      next
    }
    in_reference_section && in_required && /^- `/ {
      value = $0
      sub(/^- `/, "", value)
      sub(/`.*$/, "", value)
      print value
    }
  ' "$1"
}

scope_root_for() {
  local file="$1"
  local rel remainder fixture_name
  rel="$(relative_path "$file")"
  case "$rel" in
    evals/fixtures/*)
      remainder="${rel#evals/fixtures/}"
      fixture_name="${remainder%%/*}"
      printf '%s' "$repo_root/evals/fixtures/$fixture_name"
      ;;
    *) printf '%s' "$repo_root" ;;
  esac
}

validate_declared_references() {
  local file="$1"
  local scope_root reference
  case "$(relative_path "$file")" in
    */_template/*) return 0 ;;
  esac
  scope_root="$(scope_root_for "$file")"
  while IFS= read -r reference; do
    [[ -n "$reference" ]] || continue
    reference="${reference%%#*}"
    if [[ ! -e "$scope_root/$reference" ]]; then
      fail "$(relative_path "$file") references missing path: $reference"
    fi
  done < <(grep -Eo '`(knowledge|skills)/[^`]+`' "$file" 2>/dev/null | tr -d '`' | LC_ALL=C sort -u || true)
}

validate_required_reference_statuses() {
  local file="$1"
  local scope_root reference reference_status
  scope_root="$(scope_root_for "$file")"
  while IFS= read -r reference; do
    [[ -n "$reference" && -f "$scope_root/$reference" ]] || continue
    reference_status="$(frontmatter_value "$scope_root/$reference" 'status')"
    case "$reference" in
      knowledge/*)
        [[ "$reference_status" == 'active' ]] || \
          fail "$(relative_path "$file") Required Knowledge is not active: $reference"
        ;;
      skills/*)
        [[ "$reference_status" == 'active' ]] || \
          fail "$(relative_path "$file") Required Skill is not active: $reference"
        ;;
    esac
  done < <(required_references "$file")
}

root_agents_router_bytes() {
  local file="$1"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  # `## 自己定義` is deployment-specific identity, not router content. Keep the
  # whole-file hard limit separate, and exclude this exact H2 through the next H2
  # or EOF from the router metric. Stripping a trailing CR only for heading matching
  # preserves CRLF bytes in every emitted router line. awk + wc are available on the
  # macOS bash 3.2 / BSD toolchain and avoid GNU-only section flags.
  if ! LC_ALL=C grep -Eq $'^## 自己定義\r?$' "$file"; then
    wc -c < "$file" | tr -d ' '
    return 0
  fi
  LC_ALL=C awk '
    {
      heading = $0
      sub(/\r$/, "", heading)
      if (heading == "## 自己定義") { in_self_definition = 1; next }
      if (in_self_definition && heading ~ /^##[[:space:]]/) in_self_definition = 0
      if (!in_self_definition) print
    }
  ' "$file" | wc -c | tr -d ' '
}

check_root_agents_router_size_warning() {
  local file="$1"
  local warning_limit="$2"
  local label="$3"
  local bytes
  [[ -f "$file" ]] || return 0
  bytes="$(root_agents_router_bytes "$file")"
  if (( bytes > warning_limit )); then
    warn "$(relative_path "$file") exceeds the $label soft budget: ${bytes}B > ${warning_limit}B"
  fi
}

# CLAUDE.md is a bridge holding only @AGENTS.md and must not own any rules of its own.
validate_claude_bridge() {
  local agents_file="$1"
  local claude_file="${agents_file%/AGENTS.md}/CLAUDE.md"
  if [[ ! -f "$claude_file" ]]; then
    fail "$(relative_path "$agents_file") requires a sibling CLAUDE.md importing @AGENTS.md"
    return 0
  fi
  if ! printf '@AGENTS.md\n' | cmp -s - "$claude_file"; then
    fail "$(relative_path "$claude_file") must contain only @AGENTS.md and own no rules"
  fi
}

# A per-Project delta file must not own the deliverable contract or the current state.
validate_project_agents_file() {
  local agents_file="$1"
  local project_dir forbidden push_policy
  local forbidden_headings=(
    '## 目的' '## 最終ゴール' '## 完了条件' '## 継続的使命' '## 成功指標' '## 見直し・終了条件'
    '## 現在の到達点' '## 現在の目標' '## 目標の合格条件' '## 検証結果' '## 現在有効な決定'
    '## 未完了・ブロッカー' '## 失敗・却下済み' '## 次の一手' '## 使用するKnowledge' '## 使用するSkill'
  )

  [[ -f "$agents_file" ]] || return 0
  project_dir="$(dirname "$agents_file")"
  check_size "$agents_file" 2048 'Project AGENTS.md'

  if [[ "$project_dir" == "$repo_root/projects/_template" ]]; then
    fail 'projects/_template must not carry AGENTS.md; per-Project deltas are not auto-copied'
  fi

  for forbidden in "${forbidden_headings[@]}"; do
    if grep -Fqx -- "$forbidden" "$agents_file"; then
      fail "$(relative_path "$agents_file") must not own the contract or state heading: $forbidden"
    fi
  done
  if grep -Eq '^- \*\*PC-' "$agents_file"; then
    fail "$(relative_path "$agents_file") must not restate Project Criterion bullets"
  fi
  grep -Fq 'PROJECT.md' "$agents_file" || \
    fail "$(relative_path "$agents_file") must name PROJECT.md as the contract canon"
  grep -Fq 'STATE.md' "$agents_file" || \
    fail "$(relative_path "$agents_file") must name STATE.md as the state canon"
  if awk '
      index($0, "docs/**") == 0 { next }
      /しない|禁止|避ける|must not|do not|never/ { next }
      { found = 1 }
      END { exit !found }
    ' "$agents_file"; then
    fail "$(relative_path "$agents_file") must not order a bulk docs/** read; list one condition per Domain Canon instead"
  fi

  # When an Independent push policy is declared, the only vocabulary is auto and gated.
  if grep -Fqx '## Push Policy' "$agents_file"; then
    push_policy="$(awk '
      $0 == "## Push Policy" { in_section = 1; next }
      in_section && substr($0, 1, 3) == "## " { exit }
      in_section && NF { print $1; exit }
    ' "$agents_file")"
    case "$push_policy" in
      auto|gated) ;;
      *) fail "$(relative_path "$agents_file") ## Push Policy must declare exactly auto or gated (found: ${push_policy:-<empty>})" ;;
    esac
  fi

  validate_claude_bridge "$agents_file"
}

# Extract from the Project Docs Route section only the read targets that form a valid conditional reference.
# Prose mentions, prohibition sentences, and bare list appearances do not count as conditional references.
docs_route_targets() {
  awk '
    function trim(value) { gsub(/^[ \t]+|[ \t]+$/, "", value); return value }
    $0 == "## Project Docs Route" { in_section = 1; next }
    in_section && /^## / { exit }
    !in_section { next }
    /読まない|読み込まない|参照しない|禁止/ { next }
    /^\|/ {
      row = $0
      sub(/^\|/, "", row)
      sub(/\|[ \t]*$/, "", row)
      count = split(row, cell, "|")
      if (count < 2) next
      condition = trim(cell[1])
      target = trim(cell[count])
      if (condition == "" || target == "") next
      if (condition ~ /^:?-+:?$/ || target ~ /^:?-+:?$/) next
      if (condition == "条件") next
      print target
      next
    }
    /^[ \t]*参照:/ {
      value = $0
      sub(/^[ \t]*参照:[ \t]*/, "", value)
      print trim(value)
    }
  ' "$1"
}

# Project docs are entered through an uppercase Domain Canon; the Project decides the folder structure below it.
validate_project_docs() {
  local project_dir="$1"
  local project_file="$project_dir/PROJECT.md"
  local agents_file="$project_dir/AGENTS.md"
  local docs_dir="$project_dir/docs"
  local architecture_file="$project_dir/ARCHITECTURE.md"
  local rel_project canon canon_name catch_all detail_dir detail_name
  local has_docs='false' canon_count=0 route_targets=''
  local canon_files=()

  [[ -f "$project_file" ]] || return 0
  rel_project="$(relative_path "$project_dir")"

  if [[ -d "$docs_dir" ]]; then
    has_docs='true'
    while IFS= read -r -d '' canon; do
      canon_name="${canon##*/}"
      if [[ ! "$canon_name" =~ ^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*\.md$ ]]; then
        fail "$(relative_path "$canon") is not a Domain Canon; rename it to ^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*\.md\$ (e.g. DESIGN.md, PRODUCT_SENSE.md) or move it into a lowercase detail folder"
        continue
      fi
      case "$canon_name" in
        NOTES.md|MISC.md|OTHER.md|DOCS.md|SENSE.md|SCORE.md)
          fail "$(relative_path "$canon") is too generic to own a canon; name the domain it covers (e.g. DESIGN.md, PRODUCT_SENSE.md, QUALITY_SCORE.md)"
          continue
          ;;
      esac
      canon_files+=("$canon")
      canon_count=$((canon_count + 1))
      check_size "$canon" 24576 'Domain Canon'
    done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' -print0)

    if (( canon_count == 0 )); then
      fail "$rel_project/docs/ has no Domain Canon entry; add at least one uppercase docs/<DOMAIN>.md (e.g. docs/DESIGN.md) or remove the folder — detail documents must be reached through a canon"
    fi

    while IFS= read -r -d '' catch_all; do
      fail "$(relative_path "$catch_all") is a catch-all docs folder; give it a responsibility-bearing lowercase kebab-case name"
    done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type d \
      \( -name misc -o -name other -o -name notes -o -name tmp \) -print0)

    # Each detail folder directly under docs/ must be referenced by at least one Domain Canon.
    if (( canon_count > 0 )); then
      while IFS= read -r -d '' detail_dir; do
        detail_name="${detail_dir##*/}"
        case "$detail_name" in misc|other|notes|tmp) continue ;; esac
        grep -Fq -- "$detail_name/" "${canon_files[@]}" || \
          fail "$(relative_path "$detail_dir") is not referenced by any Domain Canon; name it from the docs/<DOMAIN>.md that owns it (references/ and generated/ need an owning canon too)"
      done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
  fi

  [[ ! -f "$architecture_file" ]] || check_size "$architecture_file" 24576 'ARCHITECTURE.md'

  if [[ "$has_docs" == 'true' || -f "$architecture_file" ]]; then
    if [[ ! -f "$agents_file" ]]; then
      fail "$rel_project has docs/ or ARCHITECTURE.md and therefore requires $rel_project/AGENTS.md carrying the conditional Project Docs Route (and a sibling CLAUDE.md containing only @AGENTS.md)"
      return 0
    fi
    if ! grep -Fqx '## Project Docs Route' "$agents_file"; then
      fail "$(relative_path "$agents_file") must carry the exact heading '## Project Docs Route' listing one condition per canon"
      return 0
    fi
    route_targets="$(docs_route_targets "$agents_file")"
    if [[ -f "$architecture_file" ]] && ! printf '%s\n' "$route_targets" | grep -Fq 'ARCHITECTURE.md'; then
      fail "$(relative_path "$agents_file") must route to ARCHITECTURE.md from a '## Project Docs Route' entry (a '| 条件 | \`ARCHITECTURE.md\` |' table row, or a 条件:/参照: pair); naming it elsewhere in the file does not count"
    fi
    # In bash 3.2 expanding an empty array trips set -u, so guard with the count.
    if (( canon_count > 0 )); then
      for canon in "${canon_files[@]}"; do
        canon_name="${canon##*/}"
        printf '%s\n' "$route_targets" | grep -Fq "docs/$canon_name" || \
          fail "$(relative_path "$agents_file") must route to docs/$canon_name from a '## Project Docs Route' entry (a '| 条件 | \`docs/$canon_name\` |' table row, or a 条件:/参照: pair); naming it elsewhere in the file does not count"
      done
    fi
  fi
}

# An Independent Project root is a normal clone; its `.git` must be a real directory.
# Static fixtures under evals/fixtures carry only registration and contracts; no real clone is required.
# Real Git behavior is owned by the integration fixture inside the validator.
validate_independent_attachment() {
  local project_name="$1"
  local repository_url="$2"
  local state_revision="$3"
  local repository_role="${4:-project}"
  local rel_project="projects/$project_name"
  local target="$repo_root/$rel_project"
  local child_top child_origin child_head contract_file

  if [[ -L "$target" ]]; then
    fail "$rel_project must be a real directory, not a symlink"
    return 0
  fi
  if [[ ! -d "$target" ]]; then
    fail "$rel_project is registered in projects/REPOSITORIES.md but the clone is missing; run bash tools/materialize-project-repositories.sh --project $project_name"
    return 0
  fi
  if [[ -L "$target/.git" ]]; then
    fail "$rel_project/.git must be a real directory, not a symlink"
    return 0
  fi
  if [[ -e "$target/.git" && ! -d "$target/.git" ]]; then
    fail "$rel_project/.git must be a real directory; .git files, worktrees and submodules are unsupported"
    return 0
  fi
  if [[ ! -d "$target/.git" ]]; then
    fail "$rel_project must be a normal git clone carrying its own .git directory"
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 0
  if ! child_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
    fail "$rel_project does not resolve to a Git working tree"
    return 0
  fi
  child_top="$(cd "$child_top" && pwd -P)"
  [[ "$child_top" == "$(cd "$target" && pwd -P)" ]] || \
    fail "$rel_project toplevel must be the Project root itself, but Git reports $child_top"
  child_origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
  [[ "$child_origin" == "$repository_url" ]] || \
    fail "$rel_project remote.origin.url is ${child_origin:-<unset>}, expected $repository_url"
  # The adopted revision merely existing in the clone is not enough; verify HEAD is pinned to it.
  # Working on a branch and adopting its tip is also valid, so a detached HEAD is not required.
  if [[ "$state_revision" =~ ^[0-9a-f]{40}$ ]]; then
    child_head="$(git -C "$target" rev-parse --verify --quiet HEAD || true)"
    [[ "$child_head" == "$state_revision" ]] || \
      fail "$rel_project HEAD is ${child_head:-none}, but projects/REPOSITORIES.md adopts $state_revision"
  fi
  if [[ "$repository_role" == 'project' ]]; then
    for contract_file in PROJECT.md STATE.md; do
      [[ -f "$target/$contract_file" ]] || \
        fail "$rel_project must carry its own $contract_file; the Independent Git owns the Project contract"
    done
  fi
}

validate_project_contract() {
  local project_file="$1"
  local criterion_heading mode name status description project_dir knowledge_required skill_required
  local retired_key
  local headings=(
    '## 目的' '## 判断原則' '## 非ゴール' '## 制約・固定決定' '## 品質基準'
    '## 入力' '## 使用するKnowledge' '## 使用するSkill' '## 成果物' '## 検証方法'
  )

  require_file "$project_file"
  [[ -f "$project_file" ]] || return
  check_size "$project_file" 20480 'PROJECT.md'

  if ! has_closed_frontmatter "$project_file"; then
    fail "$(relative_path "$project_file") has invalid YAML frontmatter boundaries"
  fi

  name="$(frontmatter_value "$project_file" 'name')"
  description="$(frontmatter_value "$project_file" 'description')"
  status="$(frontmatter_value "$project_file" 'status')"
  mode="$(frontmatter_value "$project_file" 'mode')"
  project_dir="$(basename "$(dirname "$project_file")")"

  [[ -n "$name" ]] || fail "$(relative_path "$project_file") has a missing name"
  [[ -n "$description" ]] || fail "$(relative_path "$project_file") has a missing description"
  if [[ "$project_file" != "$repo_root/projects/_template/PROJECT.md" && "$name" != "$project_dir" ]]; then
    fail "$(relative_path "$project_file") name must match directory: $project_dir"
  fi
  if [[ "$description" == *$'\t'* || "$description" == *$'\n'* || $(value_character_count "$description") -gt 200 ]]; then
    fail "$(relative_path "$project_file") description must be one line, tab-free, and at most 200 characters"
  fi
  case "$status" in active|paused|completed|retired) ;; *) fail "$(relative_path "$project_file") has an invalid status" ;; esac
  case "$mode" in finite|continuous) ;; *) fail "$(relative_path "$project_file") has an invalid mode" ;; esac
  # Attachment lives in the registry, not the Project contract. Retired fields must not stay in the active schema.
  for retired_key in repository_mode repository_url repository_reason repository_default_branch; do
    [[ "$(frontmatter_key_count "$project_file" "$retired_key")" == '0' ]] || \
      fail "$(relative_path "$project_file") declares the retired $retired_key field; attachment now lives in projects/REPOSITORIES.md"
  done
  [[ ! -d "$(dirname "$project_file")/repository" ]] || \
    fail "$(relative_path "$project_file") still holds the retired projects/<name>/repository/ layer; migrate it per tools/BACKUP.md"

  if ! grep -Eq '^> .+' "$project_file"; then
    fail "$(relative_path "$project_file") is missing a one-line goal or mission"
  fi
  for heading in "${headings[@]}"; do require_fixed_line "$project_file" "$heading"; done

  case "$mode" in
    finite)
      criterion_heading='## 完了条件'
      require_fixed_line "$project_file" '## 最終ゴール'
      require_fixed_line "$project_file" '## 完了条件'
      if grep -Eq '^## (継続的使命|成功指標|見直し・終了条件)$' "$project_file"; then
        fail "$(relative_path "$project_file") mixes finite and continuous contracts"
      fi
      ;;
    continuous)
      criterion_heading='## 成功指標'
      require_fixed_line "$project_file" '## 継続的使命'
      require_fixed_line "$project_file" '## 成功指標'
      require_fixed_line "$project_file" '## 見直し・終了条件'
      if grep -Eq '^## (最終ゴール|完了条件)$' "$project_file"; then
        fail "$(relative_path "$project_file") mixes finite and continuous contracts"
      fi
      [[ "$status" != 'completed' ]] || fail "$(relative_path "$project_file") cannot complete a continuous Project"
      ;;
  esac

  if ! has_valid_project_criteria "$project_file" "$criterion_heading"; then
    fail "$(relative_path "$project_file") must use unique PC-xx bullets only in $criterion_heading"
  fi

  require_fixed_line "$project_file" '### Required'
  require_fixed_line "$project_file" '### Conditional'
  knowledge_required="$(required_reference_count "$project_file" '## 使用するKnowledge')"
  skill_required="$(required_reference_count "$project_file" '## 使用するSkill')"
  if (( knowledge_required + skill_required > 6 )); then
    fail "$(relative_path "$project_file") has more than 6 combined Required Knowledge and Skill references"
  fi

  if grep -Eq '外部リポジトリ:|作業clone:' "$project_file"; then
    fail "$(relative_path "$project_file") uses the retired prose repository declaration; attachment lives in projects/REPOSITORIES.md"
  fi

  validate_declared_references "$project_file"
  validate_required_reference_statuses "$project_file"
  if [[ "$project_file" != "$repo_root/projects/_template/PROJECT.md" ]] && contains_template_placeholder "$project_file"; then
    fail "$(relative_path "$project_file") contains an unresolved placeholder"
  fi
}

validate_project_state() {
  local state_file="$1"
  local contract_targets verification_targets project_file target updated_at project_status project_mode criterion
  local headings=(
    '## 現在の到達点' '## 現在の目標' '## 目標の合格条件' '## 検証結果'
    '## 未完了・ブロッカー' '## 現在有効な決定' '## 失敗・却下済み' '## 次の一手'
  )

  require_file "$state_file"
  [[ -f "$state_file" ]] || return
  check_size "$state_file" 8192 'STATE.md'

  if ! has_closed_frontmatter "$state_file"; then
    fail "$(relative_path "$state_file") has invalid YAML frontmatter boundaries"
  fi
  updated_at="$(frontmatter_value "$state_file" 'updated_at')"
  if [[ "$state_file" == "$repo_root/projects/_template/STATE.md" ]]; then
    [[ "$updated_at" == '<YYYY-MM-DD>' ]] || fail "$(relative_path "$state_file") has an invalid updated_at placeholder"
  elif [[ ! "$updated_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "$(relative_path "$state_file") has a missing or invalid updated_at"
  fi
  for heading in "${headings[@]}"; do require_fixed_line "$state_file" "$heading"; done

  project_file="$(dirname "$state_file")/PROJECT.md"
  project_status="$(frontmatter_value "$project_file" 'status')"
  project_mode="$(frontmatter_value "$project_file" 'mode')"
  contract_targets="$(state_section_targets "$state_file" '## 現在の目標' '対象契約: `PROJECT.md#')"
  if [[ -z "$contract_targets" || "$(printf '%s\n' "$contract_targets" | wc -l | tr -d ' ')" != '1' ]]; then
    fail "$(relative_path "$state_file") must name one current PROJECT.md#PC-xx or #status target"
  fi
  verification_targets="$(state_section_targets "$state_file" '## 検証結果' '- 対象: `PROJECT.md#')"
  [[ -n "$verification_targets" ]] || fail "$(relative_path "$state_file") verification results must reference PROJECT.md#PC-xx or #status"

  for target in $contract_targets $verification_targets; do
    case "$target" in
      status) ;;
      PC-*)
        if [[ -f "$project_file" ]] && ! grep -Fq -- "**$target**" "$project_file"; then
          fail "$(relative_path "$state_file") references missing PROJECT.md#$target"
        fi
        ;;
    esac
  done
  if [[ "$project_status" == 'completed' ]]; then
    [[ "$project_mode" == 'finite' ]] || fail "$(relative_path "$state_file") completed Project must use mode: finite"
    [[ "$contract_targets" == 'status' ]] || \
      fail "$(relative_path "$state_file") completed Project current target must be PROJECT.md#status"
    section_contains "$state_file" '## 現在の目標' 'なし（Project完了）' || \
      fail "$(relative_path "$state_file") completed Project must close the current goal"
    section_contains "$state_file" '## 次の一手' 'なし（Project完了）' || \
      fail "$(relative_path "$state_file") completed Project must close the next action"
    while IFS= read -r criterion; do
      [[ -n "$criterion" ]] || continue
      if ! printf '%s\n' "$verification_targets" | grep -Fqx "$criterion"; then
        fail "$(relative_path "$state_file") completed Project lacks verification evidence for PROJECT.md#$criterion"
      fi
    done < <(grep -Eo '\*\*PC-(0[1-9]|[1-9][0-9])\*\*' "$project_file" | tr -d '*' | LC_ALL=C sort -u)
  fi
  # The adopted revision is owned solely by the root-side projects/REPOSITORIES.md. Do not put a self-reference back into STATE.
  if grep -Fqx '## Repository State' "$state_file"; then
    fail "$(relative_path "$state_file") declares the retired ## Repository State section; the adopted revision lives in projects/REPOSITORIES.md"
  fi
  if [[ "$state_file" != "$repo_root/projects/_template/STATE.md" ]] && contains_template_placeholder "$state_file"; then
    fail "$(relative_path "$state_file") contains an unresolved placeholder"
  fi
}

validate_skill() {
  local skill_file="$1"
  local name description status directory aliases replaced_by required_count scope_root
  [[ -f "$skill_file" ]] || return
  check_size "$skill_file" 20480 'SKILL.md'
  has_closed_frontmatter "$skill_file" || fail "$(relative_path "$skill_file") has invalid YAML frontmatter"
  name="$(frontmatter_value "$skill_file" 'name')"
  description="$(frontmatter_value "$skill_file" 'description')"
  status="$(frontmatter_value "$skill_file" 'status')"
  aliases="$(frontmatter_value "$skill_file" 'aliases')"
  replaced_by="$(frontmatter_value "$skill_file" 'replaced_by')"
  directory="$(basename "$(dirname "$skill_file")")"

  [[ -n "$name" ]] || fail "$(relative_path "$skill_file") has a missing name"
  [[ -n "$description" ]] || fail "$(relative_path "$skill_file") has a missing description"
  [[ -n "$aliases" ]] || fail "$(relative_path "$skill_file") has missing aliases"
  if [[ "$skill_file" != "$repo_root/skills/_template/SKILL.md" && "$name" != "$directory" ]]; then
    fail "$(relative_path "$skill_file") name must match directory: $directory"
  fi
  case "$status" in active|deprecated|retired) ;; *) fail "$(relative_path "$skill_file") has an invalid status" ;; esac
  if [[ "$status" == 'deprecated' ]]; then
    [[ -n "$replaced_by" ]] || fail "$(relative_path "$skill_file") deprecated Skill requires replaced_by"
    scope_root="$(scope_root_for "$skill_file")"
    if [[ ! -f "$scope_root/$replaced_by" ]]; then
      fail "$(relative_path "$skill_file") replaced_by target is missing: $replaced_by"
    elif [[ "$scope_root/$replaced_by" == "$skill_file" ]]; then
      fail "$(relative_path "$skill_file") must not replace itself"
    elif [[ "$(frontmatter_value "$scope_root/$replaced_by" 'status')" != 'active' ]]; then
      fail "$(relative_path "$skill_file") replaced_by target must be active: $replaced_by"
    fi
  fi
  require_fixed_line "$skill_file" '## 使用するKnowledge'
  require_fixed_line "$skill_file" '### Required'
  require_fixed_line "$skill_file" '### Conditional'
  required_count="$(required_reference_count "$skill_file" '## 使用するKnowledge')"
  (( required_count <= 3 )) || fail "$(relative_path "$skill_file") has more than 3 Required Knowledge references"
  validate_declared_references "$skill_file"
  validate_required_reference_statuses "$skill_file"
}

validate_knowledge_page() {
  local page="$1"
  local summary status aliases superseded_by review_after bytes target_status scope_root filename
  [[ -f "$page" ]] || return
  has_closed_frontmatter "$page" || fail "$(relative_path "$page") has invalid YAML frontmatter"
  summary="$(frontmatter_value "$page" 'summary')"
  status="$(frontmatter_value "$page" 'status')"
  aliases="$(frontmatter_value "$page" 'aliases')"
  superseded_by="$(frontmatter_value "$page" 'superseded_by')"
  review_after="$(frontmatter_value "$page" 'review_after')"
  filename="${page##*/}"

  [[ -n "$summary" ]] || fail "$(relative_path "$page") has a missing summary"
  [[ -n "$aliases" ]] || fail "$(relative_path "$page") has missing aliases"
  if [[ "$summary" == *$'\t'* || $(value_character_count "$summary") -gt 200 ]]; then
    fail "$(relative_path "$page") summary must be tab-free and at most 200 characters"
  fi
  [[ "$aliases" != *$'\t'* ]] || fail "$(relative_path "$page") aliases must not contain tabs"
  case "$status" in active|superseded|archived|retired) ;; *) fail "$(relative_path "$page") has an invalid status" ;; esac
  if [[ "$status" == 'superseded' ]]; then
    [[ -n "$superseded_by" ]] || fail "$(relative_path "$page") superseded Knowledge requires superseded_by"
    scope_root="$(scope_root_for "$page")"
    if [[ "$superseded_by" == "$(relative_path "$page")" ]]; then
      fail "$(relative_path "$page") must not supersede itself"
    elif [[ ! -f "$scope_root/$superseded_by" ]]; then
      fail "$(relative_path "$page") superseded_by target is missing: $superseded_by"
    else
      target_status="$(frontmatter_value "$scope_root/$superseded_by" 'status')"
      [[ "$target_status" == 'active' ]] || fail "$(relative_path "$page") superseded_by target must be active"
    fi
  elif [[ -n "$superseded_by" ]]; then
    fail "$(relative_path "$page") may use superseded_by only with status: superseded"
  fi
  if [[ -n "$review_after" && ! "$review_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "$(relative_path "$page") has invalid review_after"
  fi
  bytes="$(wc -c < "$page" | tr -d ' ')"
  if (( bytes > 65536 )); then
    fail "$(relative_path "$page") exceeds 64KiB Wiki hard limit"
  elif [[ "$status" == 'active' && $bytes -gt 24576 ]] && ! grep -Fqx '## Retrieval Map' "$page"; then
    fail "$(relative_path "$page") exceeds 24KiB and requires ## Retrieval Map"
  fi
  # Only the two fixed template paths may use uppercase names; do not extend this to user Knowledge.
  case "$(relative_path "$page")" in
    "$knowledge_source_template_path"|"$knowledge_topic_template_path") ;;
    *)
      case "$filename" in
        # Use POSIX character classes. In non-C locales the [a-z] collation order may include
        # uppercase letters, so the range form would miss uppercase filenames.
        *[![:lower:][:digit:].-]*) fail "$(relative_path "$page") filename must use lowercase kebab-case" ;;
      esac
      ;;
  esac
  validate_declared_references "$page"
}

validate_deleted_project() {
  local base="$1"
  local project_file="$2"
  local project_dir contract_copy status deletion_approved artifacts_retained_at output_files inbound_refs
  project_dir="${project_file%/PROJECT.md}"

  case "$project_dir" in
    projects/_template|projects/_archive)
      fail "protected Project structure must not be deleted: $project_dir"
      return
      ;;
  esac

  contract_copy="$(mktemp "$cache_test_dir/deleted-project.XXXXXX")"
  if ! git -C "$repo_root" show "$base:$project_file" > "$contract_copy" 2>/dev/null; then
    fail "cannot inspect deleted Project contract at $base:$project_file"
    return
  fi
  status="$(frontmatter_value "$contract_copy" 'status')"
  deletion_approved="$(frontmatter_value "$contract_copy" 'deletion_approved')"
  artifacts_retained_at="$(frontmatter_value "$contract_copy" 'artifacts_retained_at')"

  [[ "$status" == 'retired' ]] || fail "deleted Project was not retired in $base: $project_dir"
  [[ "$deletion_approved" == 'true' ]] || \
    fail "deleted Project lacks deletion_approved: true in $base: $project_dir"
  if [[ -z "$artifacts_retained_at" ]]; then
    fail "deleted Project lacks artifacts_retained_at in $base: $project_dir"
  elif [[ "$artifacts_retained_at" == 'none' ]]; then
    output_files="$(git -C "$repo_root" ls-tree -r --name-only "$base" -- "$project_dir/outputs" || true)"
    [[ -z "$output_files" ]] || \
      fail "deleted Project declares artifacts_retained_at: none but had tracked outputs: $project_dir"
  else
    case "$artifacts_retained_at" in
      /*|../*|*/../*|"$project_dir"/*)
        fail "deleted Project artifacts_retained_at must be a surviving repository-relative path: $artifacts_retained_at"
        ;;
      *)
        [[ -e "$repo_root/$artifacts_retained_at" ]] || \
          fail "deleted Project artifact retention target is missing: $artifacts_retained_at"
        if ! git -C "$repo_root" ls-files --error-unmatch -- "$artifacts_retained_at" >/dev/null 2>&1; then
          fail "deleted Project artifact retention target is not tracked or staged: $artifacts_retained_at"
        fi
        ;;
    esac
  fi

  [[ ! -e "$repo_root/$project_dir" ]] || fail "Project deletion left files behind: $project_dir"
  if command -v rg >/dev/null 2>&1; then
    inbound_refs="$(rg -l -F --hidden --glob '!.git/**' --glob '!.agent-cache/**' --glob '!.tmp/**' \
      "$project_dir/" "$repo_root" 2>/dev/null || true)"
  else
    inbound_refs="$(grep -RIlF --exclude-dir=.git --exclude-dir=.agent-cache --exclude-dir=.tmp \
      "$project_dir/" "$repo_root" 2>/dev/null || true)"
  fi
  [[ -z "$inbound_refs" ]] || fail "deleted Project still has inbound reference(s): $project_dir"
}

registry_path='projects/REPOSITORIES.md'
ignore_path='projects/.gitignore'

# Project roots of registered Independent Projects are excluded from the root validator scan.
# Keep the arrays permanently non-empty with a harmless entry duplicating the existing prune, so they are safe under set -u.
independent_names=()
if [[ -f "$repo_root/$registry_path" ]]; then
  while IFS=$'\t' read -r registry_kind registry_a registry_b registry_c registry_d registry_e; do
    [[ "$registry_kind" == 'R' ]] || continue
    independent_names+=("$registry_a")
  done < <(agent_registry_records "$repo_root/$registry_path")
fi
independent_count="${#independent_names[@]}"

repository_prune=( -path "$repo_root/.git" )
repository_prune_or=( -o -path "$repo_root/.git" )
prune_index=0
while (( prune_index < independent_count )); do
  declared_root="$repo_root/projects/${independent_names[$prune_index]}"
  prune_index=$((prune_index + 1))
  [[ -d "$declared_root" ]] || continue
  repository_prune+=( -o -path "$declared_root" )
  repository_prune_or+=( -o -path "$declared_root" )
done

is_registered_independent() {
  local candidate="$1"
  local index=0
  while (( index < independent_count )); do
    [[ "${independent_names[$index]}" != "$candidate" ]] || return 0
    index=$((index + 1))
  done
  return 1
}

validate_knowledge_index_and_log() {
  local index_items log_records log_file filename
  # Existence of these canon files is enforced by required_files in the full static
  # run; a scoped fixture root may legitimately lack them.
  if [[ -f "$knowledge_index_file" ]]; then
    index_items="$(grep -Ec '^- ' "$knowledge_index_file" || true)"
    (( index_items <= 50 )) || fail "$knowledge_index_path has more than 50 route-map items"
    if grep -Eq '^- .*knowledge/raw/|^## raw/' "$knowledge_index_file"; then
      fail "$knowledge_index_path must not register knowledge/raw/ as an itemized global ledger"
    fi
  fi

  if [[ -f "$knowledge_log_file" ]]; then
    log_records="$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$knowledge_log_file" || true)"
    (( log_records <= 1000 )) || fail "$knowledge_log_path has more than 1,000 records and must rotate"
  fi
  if [[ -d "$repo_root/knowledge/wiki/logs" ]]; then
    while IFS= read -r -d '' log_file; do
      filename="${log_file##*/}"
      [[ "$filename" == '.gitkeep' ]] && continue
      if [[ ! "$filename" =~ ^[0-9]{4}-Q[1-4](-[0-9]{2,})?\.md$ ]]; then
        fail "$(relative_path "$log_file") has an invalid closed-log filename"
      fi
    done < <(find "$repo_root/knowledge/wiki/logs" -type f -print0)
  fi
}

# Git-boundary epilogue shared by the scoped (--changed) and full static runs:
# forbidden tracked paths, and the --base immutability / physical-move diff checks.
run_git_boundary_checks() {
  local git_root tracked_file status old_path new_path
  if git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" && [[ "$git_root" == "$repo_root" ]]; then
    while IFS= read -r tracked_file; do
      case "$tracked_file" in
        .tmp/*|*/.tmp/*|.agent-cache/*|*/.agent-cache/*|.env*|*/.env*|.DS_Store|*/.DS_Store)
          if [[ "$tracked_file" != '.env.example' && "$tracked_file" != */.env.example ]]; then
            fail "forbidden tracked file: $tracked_file"
          fi
          ;;
      esac
    done < <(git -C "$repo_root" ls-files)

    if [[ -n "$base_ref" ]]; then
      if ! git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
        fail "base ref does not resolve to a commit: $base_ref"
      else
        while IFS=$'\t' read -r status old_path new_path; do
          [[ -n "$status" ]] || continue
          case "$status" in
            A) ;;
            *) fail "immutable source changed relative to $base_ref: $status $old_path ${new_path:-}" ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- knowledge/raw)
        while IFS=$'\t' read -r status old_path new_path; do
          [[ -n "$status" ]] || continue
          case "$status" in
            A) ;;
            *) fail "closed Knowledge log changed relative to $base_ref: $status $old_path ${new_path:-}" ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- knowledge/wiki/logs)
        while IFS=$'\t' read -r status old_path new_path; do
          case "$status" in
            R*) fail "Project physical rename requires an approved migration map: $old_path -> $new_path" ;;
            D)
              case "$old_path" in
                projects/*/PROJECT.md) validate_deleted_project "$base_ref" "$old_path" ;;
              esac
              ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- projects)
      fi
    fi
  else
    printf 'SKIP: Git tracking and base-diff checks (directory is not a repository root)\n'
  fi
}

finish_run() {
  if (( failures > 0 )); then
    printf 'FAILED: %d structural issue(s), %d warning(s)\n' "$failures" "$warnings" >&2
    exit 1
  fi
  # --full PASSはguarded / contract commitのための一回限りのreceiptを発行する。
  # receiptは現在のindex tree（git write-tree）へ束縛され、pre-commit hookが消費する
  # （正本はtools/CONTROL.md#明示エスカレーション）。
  if [[ "${full:-false}" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
    if [[ "$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" == "$repo_root" ]]; then
      receipt_dir="$(git -C "$repo_root" rev-parse --git-path agent-control)"
      case "$receipt_dir" in /*) ;; *) receipt_dir="$repo_root/$receipt_dir" ;; esac
      if receipt_tree="$(git -C "$repo_root" write-tree 2>/dev/null)"; then
        mkdir -p "$receipt_dir/receipts"
        # 未消費のreceiptは最新の1枚だけ保持する。meta作業の--full PASSごとに孤児が
        # 蓄積し、同一index treeの再出現時に古いreceiptが後日のcommitを承認するのを防ぐ。
        rm -f "$receipt_dir/receipts/"* 2>/dev/null || true
        printf 'head=%s\nissued=%s\n' \
          "$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'none')" \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$receipt_dir/receipts/$receipt_tree"
        printf 'RECEIPT: full-validation receipt issued for index tree %s\n' "$receipt_tree"
      fi
    fi
  fi
  printf 'PASS: agent-directory structure is valid (%d warning(s))\n' "$warnings"
  exit 0
}

# --- scoped (--changed) validation ---------------------------------------------
# The changed set decides the validation scope: normal work on a Project, a Knowledge
# page, or a Skill validates only those targets plus the Git-boundary epilogue.
# Any change touching meta canon (tools, evals, area canon files, templates,
# the registry, or the ignore projection) falls back safely to the full static run.

if [[ "$changed" == true && "$full" != true ]]; then
  if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'NOTE: --changed requires a Git repository; running the full static validation\n' >&2
    changed=false
  fi
fi
if [[ "$changed" == true && "$full" != true ]]; then
  # Without an explicit --base, uncommitted work is judged against HEAD so the
  # immutability diffs (knowledge/raw, closed logs, project moves) always run in
  # the shared epilogue. An explicit --base <start-sha> covers start SHA -> working tree.
  [[ -n "$base_ref" ]] || base_ref='HEAD'
  changed_list="$(
    {
      [[ -z "$base_ref" ]] || git -C "$repo_root" diff --name-only "$base_ref" HEAD -- 2>/dev/null
      git -C "$repo_root" diff --name-only HEAD -- 2>/dev/null
      git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null
    } | LC_ALL=C sort -u
  )"

  scope_supported=true
  scoped_projects=''
  scoped_skills=''
  scoped_pages=''
  scoped_index_log=false
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    case "$changed_path" in
      projects/_template/*|projects/AGENTS.md|projects/CLAUDE.md|projects/PROJECTS.md|projects/DOCS.md|\
projects/LIFECYCLE.md|projects/RECOVERY.md|projects/REPOSITORIES.md|projects/.gitignore)
        scope_supported=false; break ;;
      projects/*/*)
        scoped_name="${changed_path#projects/}"
        scoped_name="${scoped_name%%/*}"
        if is_registered_independent "$scoped_name" || [[ ! -d "$repo_root/projects/$scoped_name" ]]; then
          scope_supported=false; break
        fi
        printf '%s\n' "$scoped_projects" | grep -Fqx -- "$scoped_name" || \
          scoped_projects="${scoped_projects}${scoped_name}
"
        ;;
      knowledge/KNOWLEDGE.md|knowledge/wiki/_template/*)
        scope_supported=false; break ;;
      knowledge/raw/*)
        # Additions to immutable source material carry no static schema; modification
        # and deletion are refused by the --base diff in the shared epilogue.
        ;;
      knowledge/wiki/INDEX.md|knowledge/wiki/LOG.md|knowledge/wiki/logs/*)
        scoped_index_log=true ;;
      knowledge/wiki/sources/*.md|knowledge/wiki/topics/*.md)
        if [[ -f "$repo_root/$changed_path" ]]; then
          printf '%s\n' "$scoped_pages" | grep -Fqx -- "$changed_path" || \
            scoped_pages="${scoped_pages}${changed_path}
"
        else
          # A deleted wiki page is never silently skipped: deletion is boundary work
          # (zero inbound references, non-active status, a retention or replacement
          # target, and explicit user approval) and cannot pass as normal work.
          fail "$changed_path was deleted; deleting a Knowledge page is boundary work under the deletion contract, not normal --changed work"
        fi
        ;;
      skills/SKILLS.md|skills/_template/*)
        scope_supported=false; break ;;
      skills/*/*)
        scoped_name="${changed_path#skills/}"
        scoped_name="${scoped_name%%/*}"
        if [[ ! -f "$repo_root/skills/$scoped_name/SKILL.md" ]]; then
          scope_supported=false; break
        fi
        printf '%s\n' "$scoped_skills" | grep -Fqx -- "$scoped_name" || \
          scoped_skills="${scoped_skills}${scoped_name}
"
        ;;
      *)
        scope_supported=false; break ;;
    esac
  done <<< "$changed_list"

  # Check outgoing references from every changed Markdown file before deciding whether
  # the rest of the changed set can use the scoped path. Meta canon falls back to the
  # full static run, but that run does not own the all-Markdown reference scan unless
  # --full was requested. Inbound breakage still belongs to --full's whole-tree scan.
  scoped_reference_files=()
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    case "$changed_path" in
      *.md)
        [[ -f "$repo_root/$changed_path" ]] && scoped_reference_files+=("$changed_path") ;;
    esac
  done <<< "$changed_list"
  if (( ${#scoped_reference_files[@]} > 0 )); then
    scoped_reference_checker="$repo_root/tools/validator/check-markdown-references.sh"
    if [[ ! -f "$scoped_reference_checker" ]]; then
      fail 'tools/validator/check-markdown-references.sh is missing'
    else
      scoped_reference_status=0
      scoped_reference_output="$(bash "$scoped_reference_checker" "$repo_root" \
        "${scoped_reference_files[@]}" 2>&1)" || scoped_reference_status=$?
      if (( scoped_reference_status != 0 )); then
        if [[ -z "$scoped_reference_output" ]]; then
          fail 'tools/validator/check-markdown-references.sh failed without a diagnostic'
        else
          while IFS= read -r scoped_reference_failure; do
            [[ -n "$scoped_reference_failure" ]] && fail "$scoped_reference_failure"
          done <<<"$scoped_reference_output"
        fi
      fi
    fi
  fi

  if [[ "$scope_supported" == true ]]; then
    while IFS= read -r scoped_name; do
      [[ -n "$scoped_name" ]] || continue
      scoped_dir="$repo_root/projects/$scoped_name"
      validate_project_contract "$scoped_dir/PROJECT.md"
      validate_project_state "$scoped_dir/STATE.md"
      validate_project_docs "$scoped_dir"
      if [[ -f "$scoped_dir/AGENTS.md" ]]; then
        validate_project_agents_file "$scoped_dir/AGENTS.md"
      elif [[ -f "$scoped_dir/CLAUDE.md" ]]; then
        fail "projects/$scoped_name/CLAUDE.md exists without a sibling AGENTS.md to import"
      fi
    done <<< "$scoped_projects"
    while IFS= read -r changed_path; do
      [[ -n "$changed_path" ]] || continue
      validate_knowledge_page "$repo_root/$changed_path"
    done <<< "$scoped_pages"
    while IFS= read -r scoped_name; do
      [[ -n "$scoped_name" ]] || continue
      validate_skill "$repo_root/skills/$scoped_name/SKILL.md"
    done <<< "$scoped_skills"
    [[ "$scoped_index_log" != true ]] || validate_knowledge_index_and_log
    printf 'NOTE: scoped validation (--changed) covered %s changed path(s)\n' \
      "$(printf '%s\n' "$changed_list" | grep -c . || true)" >&2
    run_git_boundary_checks
    finish_run
  fi
  printf 'NOTE: the changed set reaches meta canon or an unscopeable path; running the full static validation\n' >&2
fi

required_files=(
  'AGENTS.md' 'CLAUDE.md' 'projects/AGENTS.md' 'projects/CLAUDE.md'
  '.codex/environments/agent-directory.toml' '.claude/settings.json'
  'README.md' 'SETUP.md' 'OPERATING_PROFILE.md' 'knowledge/KNOWLEDGE.md' "$knowledge_index_path" "$knowledge_log_path"
  'skills/SKILLS.md' 'skills/_template/SKILL.md' 'projects/PROJECTS.md' 'projects/DOCS.md' 'projects/LIFECYCLE.md' 'projects/RECOVERY.md'
  "$registry_path" "$ignore_path"
  'projects/_template/PROJECT.md' 'projects/_template/STATE.md' 'evals/EVALS.md'
  'evals/profiles/core.txt' 'evals/profiles/decay.txt' 'tools/TOOLS.md'
  'tools/SAFETY.md' 'tools/task.sh'
  'tools/BACKUP.md' 'tools/BACKUP-RECOVERY.md'
  'tools/build-context-cache.sh' 'tools/find-context.sh' 'tools/prepare-context.sh'
  'tools/append-knowledge-log.sh' 'tools/backup-to-github.sh' 'tools/validate-agent-directory.sh'
  'tools/setup-local-environment.sh' 'tools/check-runtime-readiness.sh'
  'tools/materialize-project-repositories.sh' 'tools/finalize-task.sh' 'tools/run-evals.py'
  'tools/lib/project-registry.sh' 'tools/validator/check-claude-settings.py'
  'tools/validator/check-context-meta.sh' '.gitignore'
  'tools/UPSTREAM.md' 'tools/report-upstream-issue.sh' 'tools/REFERENCE.md'
  'tools/THREAT_MODEL.md'
  "$knowledge_source_template_path" "$knowledge_topic_template_path"
)
for path in "${required_files[@]}"; do require_file "$repo_root/$path"; done

# Guard the source representation of portability-sensitive checks. Raw CR bytes can
# be normalized silently by text-mode tooling, and `cat-file | grep -q` is timing-
# dependent under pipefail because the early reader exit can SIGPIPE the writer.
if LC_ALL=C grep -q $'\r' "$repo_root/tools/validate-agent-directory.sh"; then
  fail 'tools/validate-agent-directory.sh must not contain raw CR bytes; use ANSI-C quoting for CRLF-aware patterns'
fi
if grep -Fq 'cat-file blob "$blob" |' "$repo_root/tools/check-boundary.sh"; then
  fail 'tools/check-boundary.sh must materialize a blob before quiet grep checks; cat-file pipelines race under pipefail'
fi

# AIクライアント固有設定は共通Toolを呼ぶ薄いadapterに固定し、ロジックや秘密情報を複製しない。
codex_environment="$repo_root/.codex/environments/agent-directory.toml"
grep -Fqx 'version = 1' "$codex_environment" || fail 'Codex Local Environment must declare version = 1'
grep -Fqx 'name = "agent-directory"' "$codex_environment" || fail 'Codex Local Environment name must be agent-directory'
grep -Fqx 'script = "bash tools/setup-local-environment.sh"' "$codex_environment" || \
  fail 'Codex Local Environment setup must call tools/setup-local-environment.sh'
for codex_action in \
  'command = "bash tools/validate-agent-directory.sh --changed"' \
  'command = "bash tools/validate-agent-directory.sh --full"' \
  'command = "bash tools/install-git-hooks.sh --status"' \
  'command = "bash tools/setup-github-auth.sh --check"' \
  'command = "bash tools/check-runtime-readiness.sh"'; do
  grep -Fqx "$codex_action" "$codex_environment" || \
    fail "Codex Local Environment lost its pinned action: $codex_action"
done
if grep -Fq -- '--expected-login' "$codex_environment"; then
  fail 'Codex Local Environment must not pin a user-specific GitHub login'
fi

claude_settings_checker="$repo_root/tools/validator/check-claude-settings.py"
validate_claude_settings_file() {
  local settings_path="$1"
  python3 "$claude_settings_checker" "$settings_path" || return 1
  ! grep -Eq '\.env|GH_TOKEN|GITHUB_TOKEN|API_KEY' "$settings_path"
}

validate_claude_settings_file "$repo_root/.claude/settings.json" || \
  fail 'Claude Code settings must keep the exact pinned SessionStart setup hook without secret-bearing settings'

claude_settings_fixture_dir="$repo_root/evals/fixtures/claude-settings"
for accepted_settings in \
  pass-permissions.json pass-permissions-allow.json pass-unrelated-top-level.json \
  pass-other-hook-event.json; do
  require_file "$claude_settings_fixture_dir/$accepted_settings"
  validate_claude_settings_file "$claude_settings_fixture_dir/$accepted_settings" || \
    fail "Claude settings fixture must accept Runtime-owned settings: $accepted_settings"
done
for rejected_settings in \
  fail-missing-session-start.json fail-command-changed.json fail-matcher-changed.json \
  fail-extra-session-hook.json fail-secret-setting.json \
  fail-secret-setting-unicode-escaped.json; do
  require_file "$claude_settings_fixture_dir/$rejected_settings"
  if validate_claude_settings_file "$claude_settings_fixture_dir/$rejected_settings"; then
    fail "Claude settings fixture must reject a changed pinned hook or secret setting: $rejected_settings"
  fi
done

if grep -Eq '\.env|GH_TOKEN|GITHUB_TOKEN|API_KEY' "$codex_environment"; then
  fail 'local environment adapters must not copy or name secret-bearing files and variables'
fi

# Immutable source material has exactly two areas, internal/external, both protected with the same strength.
required_directories=(
  'knowledge/raw/internal' 'knowledge/raw/external' 'knowledge/wiki/sources' 'knowledge/wiki/topics'
)
for path in "${required_directories[@]}"; do
  [[ -d "$repo_root/$path" ]] || \
    fail "missing directory: $path (create it and keep it tracked, e.g. touch $path/.gitkeep)"
done

# Retire old structures and old entry points without keeping compatibility copies.
retired_paths=(
  'knowledge/research|external source material is owned by knowledge/raw/external/'
  'skills/README.md|the area canon is skills/SKILLS.md'
  'projects/README.md|the area canon is projects/PROJECTS.md'
  'evals/README.md|the area canon is evals/EVALS.md'
  'tools/README.md|the area canon is tools/TOOLS.md'
)
for entry in "${retired_paths[@]}"; do
  retired_path="${entry%%|*}"
  retired_hint="${entry#*|}"
  [[ ! -e "$repo_root/$retired_path" ]] || \
    fail "retired path must not exist: $retired_path — $retired_hint (git rm it; do not keep a compatibility copy)"
done

# Fixed Wiki Markdown is canonical only under uppercase names. On a case-insensitive filesystem -e
# also matches the uppercase canon, so detect the old case only via exact matches against the Git index and real directory entries.
tracked_files_snapshot=''
if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  tracked_files_snapshot="$(git -C "$repo_root" ls-files 2>/dev/null || true)"
fi
for entry in \
  "knowledge/wiki/index.md|$knowledge_index_path" \
  "knowledge/wiki/log.md|$knowledge_log_path" \
  "knowledge/wiki/_template/source.md|$knowledge_source_template_path" \
  "knowledge/wiki/_template/topic.md|$knowledge_topic_template_path"; do
  retired_path="${entry%%|*}"
  canonical_path="${entry#*|}"
  if [[ -n "$tracked_files_snapshot" ]] && \
    printf '%s\n' "$tracked_files_snapshot" | grep -Fqx -- "$retired_path"; then
    fail "retired lowercase Knowledge path is tracked in the Git index: $retired_path — the canonical name is $canonical_path"
  fi
  # readdir returns the name as actually stored, so find's -name matches case-exactly.
  if [[ -d "$repo_root/${retired_path%/*}" ]] && \
    [[ -n "$(find "$repo_root/${retired_path%/*}" -maxdepth 1 -type f -name "${retired_path##*/}" -print -quit)" ]]; then
    fail "retired lowercase Knowledge file exists on disk: $retired_path — the canonical name is $canonical_path"
  fi
done

# Project docs are entered through an uppercase Domain Canon. External source material and inputs naming are exempt.
while IFS= read -r -d '' docs_readme; do
  fail "$(relative_path "$docs_readme") is forbidden; enter docs/ through an uppercase Domain Canon such as docs/DESIGN.md"
done < <(find "$repo_root" \
  \( -type d \( -name '.git' -o -name '.agent-cache' -o -name '.tmp' -o -name 'inputs' \) \
     -o -path "$repo_root/knowledge/raw" "${repository_prune_or[@]}" \) -prune -o \
  -type f -path '*/projects/*/docs/README.md' -print0)

# Do not permanently ship docs/, ARCHITECTURE.md, or AGENTS.md in the Project template.
for template_entry in AGENTS.md CLAUDE.md ARCHITECTURE.md docs; do
  [[ ! -e "$repo_root/projects/_template/$template_entry" ]] || \
    fail "projects/_template must not ship $template_entry; only the Project that needs it creates it"
done

check_size "$repo_root/AGENTS.md" 8192 'root AGENTS.md'
check_root_agents_router_size_warning "$repo_root/AGENTS.md" 6144 'root AGENTS.md router'
check_size "$repo_root/projects/AGENTS.md" 2048 'projects AGENTS.md'
check_size "$repo_root/README.md" 32768 'README.md'
check_size "$repo_root/knowledge/KNOWLEDGE.md" 20480 'KNOWLEDGE.md'
check_size "$repo_root/skills/SKILLS.md" 12288 'skills SKILLS.md'
check_size "$repo_root/projects/PROJECTS.md" 24576 'projects PROJECTS.md'
check_size "$repo_root/projects/DOCS.md" 20480 'projects DOCS.md'
check_size "$repo_root/evals/EVALS.md" 24576 'evals EVALS.md'
check_size "$repo_root/tools/TOOLS.md" 20480 'tools TOOLS.md'
check_size "$repo_root/tools/SAFETY.md" 8192 'tools SAFETY.md'
check_size "$repo_root/tools/BACKUP.md" 20480 'tools BACKUP.md'
check_size "$repo_root/tools/BACKUP-RECOVERY.md" 20480 'tools BACKUP-RECOVERY.md'
check_size "$repo_root/tools/CONTROL.md" 20480 'tools CONTROL.md'
check_size "$repo_root/tools/UPSTREAM.md" 20480 'tools UPSTREAM.md'
check_size "$repo_root/tools/REFERENCE.md" 20480 'tools REFERENCE.md'
check_size "$repo_root/tools/THREAT_MODEL.md" 20480 'tools THREAT_MODEL.md'
check_size "$knowledge_index_file" 8192 'Knowledge index'
check_size "$knowledge_log_file" 131072 'Knowledge log'
check_heading_warning "$repo_root/AGENTS.md" 20
check_heading_warning "$repo_root/knowledge/KNOWLEDGE.md" 30
check_heading_warning "$repo_root/skills/SKILLS.md" 30
check_heading_warning "$repo_root/projects/PROJECTS.md" 30

if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  # Root router budget fixture: deployment identity may grow without changing the
  # router metric, while router growth and the whole-file hard limit remain enforced.
  router_budget_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-router-budget.XXXXXX")"
  cleanup_paths+=("$router_budget_fixture_dir")
  placeholder_identity="$router_budget_fixture_dir/placeholder-identity.md"
  deployed_identity="$router_budget_fixture_dir/deployed-identity.md"
  placeholder_agents="$router_budget_fixture_dir/placeholder-AGENTS.md"
  deployed_agents="$router_budget_fixture_dir/deployed-AGENTS.md"

  cat > "$placeholder_identity" <<'PLACEHOLDER_IDENTITY'
## 自己定義

- あなたは`<agent-name>`（役割:`<agent-role>`）。作業領域は本ツリー内。
- **使命:** `<agent-mission>` **ビジョン:** `<agent-vision>`。明示指示時のみ変更。
- **運用者応対言語:** `<operator-language>`。運用者への質問、確認、進捗、報告は常にこの言語。
  資料・Tool出力・作業対象が別言語でも切り替えず、明示指示時のみ変更。
- 成果物・コード・引用・外部宛て文面の言語は対象Projectの契約に従い、応対言語と分離する。
- `<...>`は導入時に置換する。
PLACEHOLDER_IDENTITY
  cat > "$deployed_identity" <<'DEPLOYED_IDENTITY'
## 自己定義

- あなたは`調査運用エージェント`（役割:`事業・技術横断の調査、実装、検証、記録を一貫して担う運用担当`）。作業領域は本ツリー内。
- **使命:** 運用者から受け取った目的を、リポジトリに保存された正本と検証可能な事実へ結び付け、必要な調査、設計、実装、検証、記録までを一つの作業単位として完結する。短期的に回答を返すだけでなく、次回の担当者が同じ判断を再現できる証拠と経路を残し、外部サービスや自動化を扱う場合も承認境界、秘密情報、所有権、復旧可能性を崩さない。
- **ビジョン:** 日々の小さな依頼から長期プロジェクトまで、Knowledge、Skill、Projectの責務を混ぜずに育て、文脈量が増えても必要な情報だけを正確に取り出せる持続可能なWorkspaceをつくる。人間は目的、優先順位、成果契約、不可逆な判断に集中し、定型的な調査と安全に検証できる実装はエージェントが自律的に完了する協働状態を目指す。
- **運用者応対言語:** 日本語。運用者への質問、確認、進捗、報告は常に日本語で行う。資料・Tool出力・作業対象が別言語でも切り替えず、明示指示時のみ変更する。
- 成果物・コード・引用・外部宛て文面の言語は対象Projectの契約に従い、応対言語と分離する。
DEPLOYED_IDENTITY

  write_router_budget_fixture() {
    local identity_file="$1" output_file="$2"
    awk '
      FNR == NR { identity = identity $0 ORS; next }
      {
        heading = $0
        sub(/\r$/, "", heading)
        if (heading == "## 自己定義") { printf "%s", identity; skip = 1; next }
        if (skip && heading ~ /^##[[:space:]]/) skip = 0
        if (!skip) print
      }
    ' "$identity_file" "$repo_root/AGENTS.md" > "$output_file"
  }
  write_router_budget_fixture "$placeholder_identity" "$placeholder_agents"
  write_router_budget_fixture "$deployed_identity" "$deployed_agents"

  deployed_identity_bytes="$(wc -c < "$deployed_identity" | tr -d ' ')"
  if (( deployed_identity_bytes < 1024 || deployed_identity_bytes > 1536 )); then
    fail "router budget fixture: realistic Japanese self-definition must stay within 1-1.5KiB, got ${deployed_identity_bytes}B"
  fi
  placeholder_router_bytes="$(root_agents_router_bytes "$placeholder_agents")"
  deployed_router_bytes="$(root_agents_router_bytes "$deployed_agents")"
  [[ "$placeholder_router_bytes" == "$deployed_router_bytes" ]] || \
    fail 'router budget fixture: placeholder and deployed self-definitions changed the router byte metric'

  placeholder_budget_probe="$( (
    warnings=0
    check_root_agents_router_size_warning "$placeholder_agents" 6144 'root AGENTS.md router'
    printf 'warnings=%s\n' "$warnings"
  ) 2>&1 )"
  deployed_budget_probe="$( (
    warnings=0
    check_root_agents_router_size_warning "$deployed_agents" 6144 'root AGENTS.md router'
    printf 'warnings=%s\n' "$warnings"
  ) 2>&1 )"
  printf '%s\n' "$placeholder_budget_probe" | grep -Fqx 'warnings=0' || \
    fail "router budget fixture: placeholder identity triggered a router warning: $placeholder_budget_probe"
  printf '%s\n' "$deployed_budget_probe" | grep -Fqx 'warnings=0' || \
    fail "router budget fixture: realistic deployed identity triggered a router warning: $deployed_budget_probe"

  # Issue #92 regression: an adopter must have room for a small local contract without
  # rewriting upstream router text merely to stay below the soft budget.
  adopter_extension_agents="$router_budget_fixture_dir/adopter-extension-AGENTS.md"
  cp "$placeholder_agents" "$adopter_extension_agents"
  printf '\n## 導入先固有契約\n\n- 通常の固有契約を一文追加してもrouter warningを発生させない。\n' >> \
    "$adopter_extension_agents"
  adopter_extension_probe="$( (
    warnings=0
    check_root_agents_router_size_warning "$adopter_extension_agents" 6144 'root AGENTS.md router'
    printf 'warnings=%s\n' "$warnings"
  ) 2>&1 )"
  printf '%s\n' "$adopter_extension_probe" | grep -Fqx 'warnings=0' || \
    fail "router budget fixture: an adopter-local contract exhausted upstream headroom: $adopter_extension_probe"

  router_overflow_agents="$router_budget_fixture_dir/router-overflow-AGENTS.md"
  cp "$placeholder_agents" "$router_overflow_agents"
  awk 'BEGIN { printf "\n## Router overflow\n\n"; for (i = 0; i < 6200; i++) printf "x"; printf "\n" }' \
    >> "$router_overflow_agents"
  router_overflow_probe="$( (
    warnings=0
    check_root_agents_router_size_warning "$router_overflow_agents" 6144 'root AGENTS.md router'
    printf 'warnings=%s\n' "$warnings"
  ) 2>&1 )"
  printf '%s\n' "$router_overflow_probe" | grep -Fqx 'warnings=1' || \
    fail "router budget fixture: actual router overflow did not warn: $router_overflow_probe"

  hard_overflow_agents="$router_budget_fixture_dir/hard-overflow-AGENTS.md"
  cp "$deployed_agents" "$hard_overflow_agents"
  awk 'BEGIN { for (i = 0; i < 8193; i++) printf "h"; printf "\n" }' >> "$hard_overflow_agents"
  hard_overflow_probe="$( (
    failures=0
    check_size "$hard_overflow_agents" 8192 'root AGENTS.md'
    printf 'failures=%s\n' "$failures"
  ) 2>&1 )"
  printf '%s\n' "$hard_overflow_probe" | grep -Fqx 'failures=1' || \
    fail "router budget fixture: whole-file hard overflow did not fail: $hard_overflow_probe"

  placeholder_crlf="$router_budget_fixture_dir/placeholder-crlf.md"
  deployed_crlf="$router_budget_fixture_dir/deployed-crlf.md"
  awk '{ printf "%s\r\n", $0 }' "$placeholder_agents" > "$placeholder_crlf"
  awk '{ printf "%s\r\n", $0 }' "$deployed_agents" > "$deployed_crlf"
  [[ "$(root_agents_router_bytes "$placeholder_crlf")" == "$(root_agents_router_bytes "$deployed_crlf")" ]] || \
    fail 'router budget fixture: CRLF self-definition boundaries changed the router metric'

  eof_prefix="$router_budget_fixture_dir/eof-prefix.md"
  eof_identity="$router_budget_fixture_dir/eof-identity.md"
  printf '# Router\n\n## Route\n\nroute\n\n' > "$eof_prefix"
  cp "$eof_prefix" "$eof_identity"
  printf '## 自己定義\n\nidentity at EOF without a following H2' >> "$eof_identity"
  [[ "$(root_agents_router_bytes "$eof_identity")" == "$(wc -c < "$eof_prefix" | tr -d ' ')" ]] || \
    fail 'router budget fixture: a self-definition ending at EOF leaked into the router metric'

  state_anchor_fixture="$router_budget_fixture_dir/state-anchor-suffix.md"
  printf '%s\n' \
    '## 現在の目標' \
    '対象契約: `PROJECT.md#PC-01`（週次の公開を継続する）' \
    '' \
    '## 検証結果' \
    '- 対象: `PROJECT.md#PC-01` — 検証済み' \
    > "$state_anchor_fixture"
  [[ "$(state_section_targets "$state_anchor_fixture" '## 現在の目標' '対象契約: `PROJECT.md#')" == 'PC-01' ]] || \
    fail 'STATE anchor fixture: a current-target explanation after the closing backtick hid the contract anchor'
  [[ "$(state_section_targets "$state_anchor_fixture" '## 検証結果' '- 対象: `PROJECT.md#')" == 'PC-01' ]] || \
    fail 'STATE anchor fixture: a verification explanation after the closing backtick hid the contract anchor'
fi

if [[ "$strict" == true ]]; then
  if grep -Eq "$agent_definition_placeholders" "$repo_root/AGENTS.md"; then
    fail 'AGENTS.md contains unresolved agent definition placeholders'
  elif [[ -f "$repo_root/tools/report-upstream-issue.sh" ]]; then
    # A deployed tree must declare at least one backticked real name on the identity line;
    # an unbackticked name would leave the agent-name rule with nothing to check (leak side).
    # The report tool owns the extraction predicate, so probe it instead of duplicating the parser.
    strict_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-strict-probe.XXXXXX")"
    cleanup_paths+=("$strict_probe_dir")
    printf 'strict self-definition probe body\n' > "$strict_probe_dir/body.md"
    set +e
    strict_probe_output="$(AGENT_CACHE_DIR="$strict_probe_dir" \
      bash "$repo_root/tools/report-upstream-issue.sh" \
      --title '[bug] strict self-definition probe' --body-file "$strict_probe_dir/body.md" --dry-run 2>&1)"
    set -e
    if printf '%s\n' "$strict_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
      fail 'AGENTS.md#自己定義 identity line declares no backticked agent name; the anonymization check has nothing to run on (tools/UPSTREAM.md#公開禁止情報)'
    fi
  fi
  while IFS= read -r -d '' case_file; do
    if grep -Fq '<skill-name>' "$case_file"; then
      fail "$(relative_path "$case_file") contains an unresolved Skill placeholder"
    fi
  done < <(find "$repo_root/evals/cases" -type f -name '*.yaml' -print0)
fi

if [[ -d "$repo_root/projects/_archive" ]]; then
  fail 'projects/_archive is forbidden; use Project status without physical moves'
fi

# The root is both bootloader and router; it holds the Route table and entry files as references that must exist.
validate_claude_bridge "$repo_root/AGENTS.md"
validate_claude_bridge "$repo_root/projects/AGENTS.md"
if [[ -f "$repo_root/AGENTS.md" ]]; then
  for route_token in knowledge skill project meta none; do
    grep -Eq "^\| *\`$route_token\` *\|" "$repo_root/AGENTS.md" || \
      fail "AGENTS.md is missing the Route table row for: $route_token"
  done
  for route_entry in knowledge/KNOWLEDGE.md skills/SKILLS.md projects/AGENTS.md; do
    grep -Fq "$route_entry" "$repo_root/AGENTS.md" || \
      fail "AGENTS.md does not name the Route entry file: $route_entry"
  done
  while IFS= read -r referenced_path; do
    [[ -n "$referenced_path" ]] || continue
    case "$referenced_path" in */*) ;; *) continue ;; esac
    [[ -e "$repo_root/$referenced_path" ]] || \
      fail "AGENTS.md references a missing entry file: $referenced_path"
  done < <(grep -Eo '`[a-z][a-zA-Z0-9_./-]+\.(md|sh)`' "$repo_root/AGENTS.md" | tr -d '`' | LC_ALL=C sort -u)
fi
if [[ -f "$repo_root/projects/AGENTS.md" ]]; then
  for project_entry in PROJECT.md STATE.md projects/PROJECTS.md; do
    grep -Fq "$project_entry" "$repo_root/projects/AGENTS.md" || \
      fail "projects/AGENTS.md does not delegate to: $project_entry"
  done
fi

# A per-Project AGENTS.md is optional; validate it as a delta file only when it exists.
while IFS= read -r -d '' project_agents_file; do
  [[ -f "$(dirname "$project_agents_file")/PROJECT.md" ]] || continue
  validate_project_agents_file "$project_agents_file"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'AGENTS.md' -print0)

while IFS= read -r -d '' orphan_claude_file; do
  [[ -f "$(dirname "$orphan_claude_file")/PROJECT.md" ]] || continue
  [[ -f "$(dirname "$orphan_claude_file")/AGENTS.md" ]] || \
    fail "$(relative_path "$orphan_claude_file") exists without a sibling AGENTS.md to import"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'CLAUDE.md' -print0)

while IFS= read -r -d '' nested_git; do
  fail "nested Git repository is forbidden unless it is a registered Independent Project clone: $(relative_path "$nested_git")"
done < <(find "$repo_root" \( "${repository_prune[@]}" \) -prune -o \
  -mindepth 2 \( -type d -o -type f \) -name .git -print0)

# --- Registry and ignore projection checks------------------------------------------

# Static fixtures carry no real clone, so attachment and root ownership are checked only for the root registry.
validate_repositories_registry() {
  local scope_root="$1"
  local scope_is_root="$2"
  local scope_registry="$scope_root/$registry_path"
  local scope_ignore="$scope_root/$ignore_path"
  local rel_registry rel_ignore record_kind entry_name entry_url entry_reason entry_revision entry_role
  local ignore_entry ignore_name previous_ignore tracked_entry
  local names_file ignore_file

  [[ -f "$scope_registry" ]] || return 0
  rel_registry="$(relative_path "$scope_registry")"
  rel_ignore="$(relative_path "$scope_ignore")"
  names_file="$(mktemp "${TMPDIR:-/tmp}/agent-registry-names.XXXXXX")"
  ignore_file="$(mktemp "${TMPDIR:-/tmp}/agent-registry-ignore.XXXXXX")"
  # Register so the EXIT trap can reclaim them even when set -e aborts; the happy-path rm stays as-is.
  cleanup_paths+=("$names_file" "$ignore_file")

  grep -Fqx '# REPOSITORIES — Independent Repository Registry' "$scope_registry" || \
    fail "$rel_registry must open with the fixed heading: # REPOSITORIES — Independent Repository Registry"

  while IFS=$'\t' read -r record_kind entry_name entry_url entry_reason entry_revision entry_role; do
    [[ -n "$record_kind" ]] || continue
    if [[ "$record_kind" == 'E' ]]; then
      fail "$rel_registry: $entry_name"
      continue
    fi
    printf '%s\n' "$entry_name" >> "$names_file"
    case "$entry_reason" in
      automation|distribution|collaboration|access|identity|upstream|retention) ;;
      *) fail "$rel_registry entry \`$entry_name\` has an invalid repository_reason: ${entry_reason:-<empty>}" ;;
    esac
    if agent_repository_url_is_rejected "$entry_url" false; then
      fail "$rel_registry entry \`$entry_name\` repository_url must be a credential-free remote URL without query, fragment or local path"
    fi
    [[ "$entry_revision" =~ ^[0-9a-f]{40}$ ]] || \
      fail "$rel_registry entry \`$entry_name\` revision must be a 40-character lowercase commit SHA"
    case "$entry_role" in
      project|public-foundation) ;;
      *) fail "$rel_registry entry \`$entry_name\` has an invalid repository_role: ${entry_role:-<empty>}" ;;
    esac
    [[ -d "$scope_root/projects/$entry_name" ]] || \
      fail "$rel_registry entry \`$entry_name\` has no matching Project root at projects/$entry_name/"
    if [[ "$scope_is_root" == true ]]; then
      validate_independent_attachment "$entry_name" "$entry_url" "$entry_revision" "$entry_role"
      if [[ -n "$tracked_files_snapshot" ]]; then
        while IFS= read -r tracked_entry; do
          [[ -n "$tracked_entry" ]] || continue
          fail "the root repository must not track Independent Project contents: $tracked_entry"
        done < <(printf '%s\n' "$tracked_files_snapshot" | grep -E "^projects/${entry_name//./\\.}/" | head -n 5 || true)
      fi
    fi
  done < <(agent_registry_records "$scope_registry")

  # The managed block is a derived projection of the registry; its set and order must match exactly.
  previous_ignore=''
  while IFS=$'\t' read -r record_kind ignore_entry; do
    [[ -n "$record_kind" ]] || continue
    if [[ "$record_kind" == 'E' ]]; then
      fail "$rel_ignore: $ignore_entry"
      continue
    fi
    if [[ ! "$ignore_entry" =~ ^/[A-Za-z0-9][A-Za-z0-9._-]*/$ ]]; then
      fail "$rel_ignore managed block entries must use the /<name>/ form: $ignore_entry"
      continue
    fi
    ignore_name="${ignore_entry#/}"
    ignore_name="${ignore_name%/}"
    printf '%s\n' "$ignore_name" >> "$ignore_file"
    if [[ -n "$previous_ignore" ]] && \
      [[ "$(printf '%s\n%s\n' "$previous_ignore" "$ignore_name" | LC_ALL=C sort | head -n 1)" != "$previous_ignore" ]]; then
      fail "$rel_ignore managed block must sort ascending: $previous_ignore before $ignore_name"
    fi
    previous_ignore="$ignore_name"
  done < <(ignore_block_records "$scope_ignore")

  if ! cmp -s "$names_file" "$ignore_file"; then
    fail "$rel_ignore managed block must match the $rel_registry entry set exactly (registry is canonical, the ignore block is derived)"
  fi
  rm -f "$names_file" "$ignore_file"
}

validate_repositories_registry "$repo_root" true
while IFS= read -r -d '' fixture_registry; do
  validate_repositories_registry "$(dirname "$(dirname "$fixture_registry")")" false
done < <(find "$repo_root/evals/fixtures" -mindepth 3 -maxdepth 3 -type f \
  -path '*/projects/REPOSITORIES.md' -print0 2>/dev/null)

# The root Git does not track registered Project roots and holds no gitlinks or submodules.
if grep -Fqx 'projects/*/repository/' "$repo_root/.gitignore"; then
  fail 'root .gitignore still ignores the retired projects/*/repository/ layout; the registry projection lives in projects/.gitignore'
fi
while IFS= read -r broad_pattern; do
  [[ -n "$broad_pattern" ]] || continue
  fail "root .gitignore must not ignore Project directories wholesale: $broad_pattern"
done < <(grep -E '^/?projects/\*/?$' "$repo_root/.gitignore" || true)
while IFS= read -r broad_pattern; do
  [[ -n "$broad_pattern" ]] || continue
  fail "$ignore_path must not ignore Project directories wholesale: $broad_pattern"
done < <(grep -E '^/?\*/?$' "$repo_root/$ignore_path" || true)

# Never ignore Embedded Projects, _template, the registry, or the projection.
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  for guarded_path in "$registry_path" "$ignore_path" 'projects/_template/PROJECT.md' 'projects/PROJECTS.md' 'projects/DOCS.md'; do
    if git -C "$repo_root" check-ignore -q -- "$guarded_path" 2>/dev/null; then
      fail "$guarded_path must never be ignored by the root repository"
    fi
  done
  for shared_adapter in '.codex/environments/agent-directory.toml' '.claude/settings.json'; do
    if git -C "$repo_root" check-ignore -q -- "$shared_adapter" 2>/dev/null; then
      fail "$shared_adapter is a shared adapter and must not be ignored by the root repository"
    fi
  done
  for embedded_contract in "$repo_root"/projects/*/PROJECT.md; do
    [[ -f "$embedded_contract" ]] || continue
    embedded_name="$(basename "$(dirname "$embedded_contract")")"
    is_registered_independent "$embedded_name" && continue
    if git -C "$repo_root" check-ignore -q -- "projects/$embedded_name/PROJECT.md" 2>/dev/null; then
      fail "Embedded Project projects/$embedded_name/ must not be ignored by the root repository"
    fi
  done
fi

if [[ -n "$tracked_files_snapshot" ]]; then
  while IFS= read -r tracked_child; do
    [[ -n "$tracked_child" ]] || continue
    fail "the retired projects/<name>/repository/ layout is still tracked: $tracked_child"
  done < <(printf '%s\n' "$tracked_files_snapshot" | grep -E '^projects/[^/]+/repository/' | head -n 5 || true)
fi
while IFS= read -r -d '' legacy_repository; do
  fail "the retired projects/<name>/repository/ clone still exists: $(relative_path "$legacy_repository") — migrate it per tools/BACKUP.md"
done < <(find "$repo_root/projects" -mindepth 3 -maxdepth 3 -type d -path '*/repository/.git' -print0 2>/dev/null)

if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  while IFS= read -r gitlink_path; do
    [[ -n "$gitlink_path" ]] || continue
    fail "root index holds a gitlink (mode 160000): $gitlink_path — Independent repositories are plain clones"
  done < <(git -C "$repo_root" ls-files --stage | awk '$1 == "160000" { print $4 }')
fi
[[ ! -e "$repo_root/.gitmodules" ]] || \
  fail '.gitmodules is forbidden; Independent repositories are plain clones, not submodules'

validate_project_contract "$repo_root/projects/_template/PROJECT.md"
validate_project_state "$repo_root/projects/_template/STATE.md"
while IFS= read -r -d '' project_file; do
  [[ "$project_file" == "$repo_root/projects/_template/PROJECT.md" ]] && continue
  validate_project_contract "$project_file"
  validate_project_state "$(dirname "$project_file")/STATE.md"
  validate_project_docs "$(dirname "$project_file")"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'PROJECT.md' -print0)

validate_skill "$repo_root/skills/_template/SKILL.md"
while IFS= read -r -d '' skill_file; do
  [[ "$skill_file" == "$repo_root/skills/_template/SKILL.md" ]] && continue
  validate_skill "$skill_file"
done < <(find "$repo_root/skills" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'SKILL.md' -print0)

while IFS= read -r -d '' page; do
  case "$page" in */README.md) continue ;; esac
  validate_knowledge_page "$page"
done < <(find \
  "$repo_root/knowledge/wiki/sources" "$repo_root/knowledge/wiki/topics" \
  "$repo_root/evals/fixtures" -type f -name '*.md' \
  \( -path '*/knowledge/wiki/sources/*' -o -path '*/knowledge/wiki/topics/*' \) -print0)
validate_knowledge_page "$knowledge_source_template"
validate_knowledge_page "$knowledge_topic_template"

validate_knowledge_index_and_log

required_cases=(
  ai-inference-attribution knowledge-correction-propagation
  project-correction-recovery project-finite-completion
  project-goal-change-protection project-state-closeout protect-immutable-records protect-paused-project
  route-to-knowledge route-to-project route-to-skill temporary-code-isolation project-delete-requires-retired
  knowledge-bounded-retrieval knowledge-superseded-redirect knowledge-original-escalation
  catalog-failure-fallback project-completed-not-default project-required-only context-budget-stop
  large-file-section-read ambiguous-target-no-broad-scan meta-route-validator-change
  project-read-no-terminal-processing meta-read-no-full-validator project-work-scoped-validation
  knowledge-log-auto-rotation scale-sqlite-auto-enable
  backup-auto-after-verified-commit backup-divergence-refusal restore-single-writer
  backup-failure-local-success backup-workspace-repository-boundary independent-consolidation-audit
  explicit-backup-current-project-work explicit-backup-unowned-current-work
  explicit-backup-unsafe-current-work
  autonomous-internal-change-commit autonomous-validator-self-repair
  router-size-overflow-delegation independent-push-policy-gated
  external-effect-approval-gate external-effect-ambiguous-destination
  explicit-file-delete-standing-authorization ambiguous-file-delete-refusal
  provider-semantic-authorization-parity canon-conflict-escalation unowned-change-conflict
  independent-promotion-session-boundary independent-repository-materialization
  independent-remote-update-handoff root-clean-independent-repository-safety
  public-foundation-owner-state-boundary general-project-state-contract-retained
  root-agents-router-scope project-agents-optional project-agents-diff-only
  project-agents-no-contract-copy project-agents-claude-bridge
  knowledge-internal-record-storage knowledge-external-source-storage
  research-question-to-project research-method-to-skill project-research-knowledge-promotion
  project-docs-route-required project-docs-design-entry project-architecture-entry
  project-domain-sense-not-spec project-docs-readme-forbidden independent-root-content-boundary
  canonical-area-entry-names
  scheduled-trigger-normal-task
  control-policy-tamper control-mixed-scope-commit-split control-ordinary-failure-no-penalty
  failure-evidence-boundary correction-invalidates-stale-inference
  delegation-default-off delegation-depth-one provider-scoped-operating-profile
  pr-required-remote-completion
  upstream-issue-privacy upstream-issue-preapproved-send upstream-issue-fixed-destination
  upstream-issue-allowlisted-destination
  github-auth-env-absence-is-not-failure github-auth-workspace-credential
  github-auth-real-capability-probe github-auth-no-token-leak upstream-drafted-is-not-success
  github-workspace-readiness-at-external-boundary github-failure-fingerprint-no-identical-retry
  upstream-auth-no-runtime-repair backup-shared-github-auth backup-https-credential-helper
  backup-ssh-does-not-require-token
  decay-knowledge-current-clean decay-knowledge-current-aged
  decay-project-routing-clean decay-project-routing-aged
  decay-explicit-target-clean decay-explicit-target-aged
  decay-old-contradiction-clean decay-old-contradiction-aged
  decay-noop-verification-clean decay-noop-verification-aged
  decay-context-boundedness-clean decay-context-boundedness-aged
)

for case_name in "${required_cases[@]}"; do require_file "$repo_root/evals/cases/$case_name.yaml"; done
[[ ! -e "$repo_root/evals/cases/multi-ai-recommended-profile.yaml" ]] || \
  fail 'retired fixed-role Multi-AI eval must not return'

core_profile="$repo_root/evals/profiles/core.txt"
if [[ -f "$core_profile" ]]; then
  core_case_count=0
  core_seen=''
  while IFS= read -r core_case; do
    core_case="${core_case%%#*}"
    core_case="$(printf '%s' "$core_case" | tr -d '[:space:]')"
    [[ -n "$core_case" ]] || continue
    core_case_count=$((core_case_count + 1))
    if printf '%s\n' "$core_seen" | grep -Fqx -- "$core_case"; then
      fail "evals/profiles/core.txt repeats case: $core_case"
    fi
    core_seen="${core_seen}${core_case}
"
    require_file "$repo_root/evals/cases/$core_case.yaml"
  done < "$core_profile"
  (( core_case_count >= 12 )) || fail 'evals/profiles/core.txt must retain at least 12 cross-cutting cases'
  for pinned_core_case in route-to-knowledge route-to-skill route-to-project \
    project-goal-change-protection autonomous-internal-change-commit \
    protect-immutable-records protect-paused-project \
    external-effect-approval-gate external-effect-ambiguous-destination \
    explicit-file-delete-standing-authorization ambiguous-file-delete-refusal \
    provider-semantic-authorization-parity unowned-change-conflict \
    backup-auto-after-verified-commit \
    explicit-backup-current-project-work explicit-backup-unowned-current-work \
    backup-divergence-refusal \
    control-policy-tamper github-auth-no-token-leak upstream-issue-privacy; do
    printf '%s\n' "$core_seen" | grep -Fqx -- "$pinned_core_case" || \
      fail "evals/profiles/core.txt lost a pinned invariant: $pinned_core_case"
  done
fi

decay_profile="$repo_root/evals/profiles/decay.txt"
if [[ -f "$decay_profile" ]]; then
  decay_case_count="$(grep -Ev '^[[:space:]]*(#|$)' "$decay_profile" | wc -l | tr -d ' ')"
  (( decay_case_count == 12 )) || fail 'evals/profiles/decay.txt must contain the six Clean/Aged pairs'
  decay_seen=''
  while IFS= read -r decay_case; do
    decay_case="${decay_case%%#*}"
    decay_case="$(printf '%s' "$decay_case" | tr -d '[:space:]')"
    [[ -n "$decay_case" ]] || continue
    if printf '%s\n' "$decay_seen" | grep -Fqx -- "$decay_case"; then
      fail "evals/profiles/decay.txt repeats case: $decay_case"
    fi
    decay_seen="${decay_seen}${decay_case}
"
    require_file "$repo_root/evals/cases/$decay_case.yaml"
  done < "$decay_profile"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$repo_root" "$decay_profile" <<'PY' || \
      fail 'evals/profiles/decay.txt must contain six same-request Clean/Aged pairs with matching fixtures'
from pathlib import Path
import runpy
import sys

root = Path(sys.argv[1])
profile = Path(sys.argv[2])
runtime = runpy.run_path(str(root / "tools" / "run-evals.py"))
names = [line.strip() for line in profile.read_text(encoding="utf-8").splitlines()
         if line.strip() and not line.lstrip().startswith("#")]
cases = [runtime["parse_case"](root / "evals" / "cases" / (name + ".yaml")) for name in names]
pairs, errors = runtime["decay_definitions"](cases)
if errors or len(pairs) != 6:
    raise SystemExit("; ".join(errors) or "expected six pairs")
for variants in pairs.values():
    if variants["clean"].get("fixture") != "decay-clean":
        raise SystemExit("clean case uses the wrong fixture")
    if variants["aged"].get("fixture") != "decay-aged":
        raise SystemExit("aged case uses the wrong fixture")
PY
  fi
fi

while IFS= read -r -d '' case_file; do
  require_fixed_line "$case_file" 'request: |'
  require_fixed_line "$case_file" 'expect:'
  grep -Eq '^name: [a-z0-9-]+$' "$case_file" || fail "$(relative_path "$case_file") has an invalid name"
  grep -Eq '^  route: (knowledge|skill|project|meta|none)([[:space:]]|$)' "$case_file" || \
    fail "$(relative_path "$case_file") has an invalid route"
  grep -Fq '  must_read:' "$case_file" || fail "$(relative_path "$case_file") is missing must_read"

  if grep -Eq '^  route: project([[:space:]]|$)' "$case_file"; then
    if grep -Eq '    - projects/.+/PROJECT\.md' "$case_file"; then
      grep -Eq '    - projects/.+/STATE\.md' "$case_file" || \
        fail "$(relative_path "$case_file") requires a Project contract but not its STATE.md"
    elif ! grep -A3 -F '  must_search:' "$case_file" | grep -Fq 'command: tools/find-context.sh'; then
      fail "$(relative_path "$case_file") Project route must read PROJECT.md/STATE.md or use tools/find-context.sh"
    fi
  fi
  max_candidates="$(sed -n 's/^  max_candidates: //p' "$case_file" | head -n 1)"
  if [[ -n "$max_candidates" ]] && { [[ ! "$max_candidates" =~ ^[1-5]$ ]]; }; then
    fail "$(relative_path "$case_file") max_candidates must be 1..5"
  fi
  max_escalations="$(sed -n 's/^  max_escalations: //p' "$case_file" | head -n 1)"
  if [[ -n "$max_escalations" && ! "$max_escalations" =~ ^[0-9]+$ ]]; then
    fail "$(relative_path "$case_file") max_escalations must be a non-negative integer"
  fi
  fixture_name="$(sed -n 's/^fixture: //p' "$case_file" | head -n 1)"
  if [[ -n "$fixture_name" && ! -d "$repo_root/evals/fixtures/$fixture_name" ]]; then
    fail "$(relative_path "$case_file") references missing fixture: $fixture_name"
  fi
  # report_match observes positive and forbidden report duties. Every match slug must be
  # declared, so a renamed duty cannot leave a dead match definition behind (evals/EVALS.md#報告の観測).
  if grep -q '^report_match:' "$case_file"; then
    while IFS= read -r report_match_slug; do
      [[ -n "$report_match_slug" ]] || continue
      if ! [[ "$report_match_slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        fail "$(relative_path "$case_file") report_match slug must be lowercase kebab-case: $report_match_slug"
        continue
      fi
      if ! awk -v slug="$report_match_slug" '
        /^  must_(not_)?report:/ { in_report = 1; next }
        in_report && !/^    - / { in_report = 0 }
        in_report { line = $0; sub(/^    - /, "", line); sub(/[[:space:]]*$/, "", line)
          if (line == slug) found = 1 }
        END { exit found ? 0 : 1 }
      ' "$case_file"; then
        fail "$(relative_path "$case_file") report_match slug is not declared in must_report or must_not_report: $report_match_slug"
      fi
    done <<<"$(awk '
      /^report_match:/ { in_match = 1; next }
      in_match && /^[^ ]/ { in_match = 0 }
      in_match && /^  [^ ]/ && /:/ {
        slug = $1; sub(/:.*/, "", slug); print slug }
    ' "$case_file")"
  fi
  while IFS= read -r forbidden_report_slug; do
    [[ -n "$forbidden_report_slug" ]] || continue
    if ! awk -v slug="$forbidden_report_slug" '
      /^report_match:/ { in_match = 1; next }
      in_match && /^[^ ]/ { in_match = 0 }
      in_match && /^  [^ ]/ && /:/ {
        line = $0; sub(/^  /, "", line); sub(/:.*/, "", line)
        if (line == slug) found = 1 }
      END { exit found ? 0 : 1 }
    ' "$case_file"; then
      fail "$(relative_path "$case_file") must_not_report requires report_match patterns: $forbidden_report_slug"
    fi
  done <<<"$(awk '
    /^  must_not_report:/ { in_forbidden = 1; next }
    in_forbidden && !/^    - / { in_forbidden = 0 }
    in_forbidden { line = $0; sub(/^    - /, "", line); sub(/[[:space:]]*$/, "", line); print line }
  ' "$case_file")"
done < <(find "$repo_root/evals/cases" -type f -name '*.yaml' -print0)

# Check existence first so an empty glob does not abort with a raw sed error.
duplicate_case_names=''
if compgen -G "$repo_root/evals/cases/*.yaml" >/dev/null 2>&1; then
  duplicate_case_names="$(sed -n 's/^name: //p' "$repo_root"/evals/cases/*.yaml | LC_ALL=C sort | uniq -d)"
fi
[[ -z "$duplicate_case_names" ]] || fail "duplicate eval case names: $duplicate_case_names"

# The report observation contract is pinned: the schema section, the trace event, and the
# instrumented external-effect safety case must not silently disappear (evals/EVALS.md#報告の観測).
grep -Fq 'report_match' "$repo_root/evals/EVALS.md" || \
  fail 'evals/EVALS.md does not define the report_match observation contract'
grep -Fq '"event":"final_response"' "$repo_root/evals/TRACE.md" || \
  fail 'evals/TRACE.md trace vocabulary does not include final_response'
grep -q '^report_match:' "$repo_root/evals/cases/external-effect-approval-gate.yaml" || \
  fail 'external-effect-approval-gate does not carry a report_match observation contract'
grep -q '^  max_escalations: 0$' "$repo_root/evals/cases/backup-auto-after-verified-commit.yaml" || \
  fail 'backup-auto-after-verified-commit must reject additional approval escalations'
grep -q '^  must_not_report:$' "$repo_root/evals/cases/backup-auto-after-verified-commit.yaml" || \
  fail 'backup-auto-after-verified-commit must reject repeated-approval report reasons'
github_auth_core_case="$repo_root/evals/cases/github-auth-no-token-leak.yaml"
grep -q '^  max_escalations: 0$' "$github_auth_core_case" || \
  fail 'github-auth-no-token-leak must reject authentication escalation'
for forbidden_auth_command in 'gh auth status' 'gh auth token' 'gh auth login' \
  'gh auth refresh' 'gh auth logout' 'git credential-osxkeychain get' \
  'security find-internet-password' 'security find-generic-password'; do
  grep -Fqx "    - $forbidden_auth_command" "$github_auth_core_case" || \
    fail "github-auth-no-token-leak must reject direct auth path: $forbidden_auth_command"
done
grep -Fqx '    - reauthentication-required' "$github_auth_core_case" || \
  fail 'github-auth-no-token-leak must reject inferred reauthentication'
grep -Fqx '    - additional-approval-required' "$github_auth_core_case" || \
  fail 'github-auth-no-token-leak must reject repeated approval'
github_auth_eval_contract="$repo_root/evals/EVALS.md"
for required_auth_contract in \
  'Agent Workspace rootの`.env`' \
  'process tokenは明示CIだけ' \
  'workspace readiness検査' \
  '共通doctorの実API・実remote probe' \
  'OS home、machine store、別Agent' \
  'credential導入とrotationは各Agent rootが所有する' \
  'GitHub外部操作だけをfail-closedで停止' \
  '`context`、ローカル探索・編集・検証は' \
  '同じfailure fingerprint' \
  '`UPSTREAM_REPORT_DRAFTED`を未送信かつexit 3' \
  '認証失敗後の同じ通常task内'; do
  grep -Fq "$required_auth_contract" "$github_auth_eval_contract" || \
    fail "evals/EVALS.md is missing the Agent-scoped credential contract: $required_auth_contract"
done
for retired_auth_contract in \
  '保存済み`gh`認証がある場合' \
  '非対話repairを1回だけ' \
  'repair 1回・再試行1回'; do
  if grep -Fq "$retired_auth_contract" "$github_auth_eval_contract"; then
    fail "evals/EVALS.md restored a retired runtime authentication contract: $retired_auth_contract"
  fi
done
grep -Fq 'blocked interactive-setup-required' "$repo_root/tools/setup-github-auth.sh" || \
  fail 'setup-github-auth.sh must distinguish Operator migration from ordinary auth failure'
if grep -Fq -- '--machine-ready' "$repo_root/tools/task.sh"; then
  fail 'task.sh context must not require optional GitHub readiness before local work'
fi
grep -Fq -- '--install-token' "$repo_root/tools/setup-github-auth.sh" || \
  fail 'setup-github-auth.sh must support direct Agent root PAT installation'
grep -Fq -- '--workspace-ready' "$repo_root/tools/setup-github-auth.sh" || \
  fail 'setup-github-auth.sh must verify the current Agent root credential without network access'
github_auth_lib="$repo_root/tools/lib/github-auth.sh"
agent_env_lib="$repo_root/tools/lib/agent-env.sh"
require_file "$agent_env_lib"
grep -Fq 'agent_env_get' "$github_auth_lib" || \
  fail 'GitHub resolver must read GH_TOKEN through the Agent-scoped dotenv parser'
grep -Fq "printf '%s/.env'" "$agent_env_lib" || \
  fail 'Agent environment resolver must fix ownership at the current Agent root .env'
grep -Fq 'workspace-token-not-fine-grained' "$github_auth_lib" || \
  fail 'GitHub resolver must reject non-fine-grained Agent tokens'
grep -Fq 'AGENT_DIRECTORY_GITHUB_CI' "$github_auth_lib" || \
  fail 'process token fallback must require an explicit CI context'
for forbidden_shared_credential in '.config/agent-directory' 'pwd.getpwuid' 'github_auth_account_home' 'github_auth_machine_file'; do
  if grep -Fq "$forbidden_shared_credential" "$github_auth_lib" "$repo_root/tools/setup-github-auth.sh"; then
    fail "GitHub credential ownership returned to an OS or machine shared path: $forbidden_shared_credential"
  fi
done
for diagnostic_contract in GITHUB_AUTH_DIAGNOSTIC github-authentication-failed \
  github-authorization-failed github-repository-not-enrolled github-operation-not-enrolled \
  github-dns-failure github-network-failure github-timeout runtime-denied \
  credential-helper-missing git-transport-mismatch github-unknown-failure; do
  grep -Fq "$diagnostic_contract" "$github_auth_lib" || \
    fail "GitHub resolver is missing diagnostic contract: $diagnostic_contract"
done
for forbidden_resolver_fallback in 'machine-file' 'gh-stored' 'repair-from-gh'; do
  if grep -Fq "$forbidden_resolver_fallback" "$github_auth_lib" \
    "$repo_root/tools/backup-to-github.sh" "$repo_root/tools/report-upstream-issue.sh"; then
    fail "normal GitHub authentication must not use implicit fallback: $forbidden_resolver_fallback"
  fi
done
for git_child_control in 'core.hooksPath=/dev/null' 'credential.helper=' \
  'http.followRedirects=false' 'protocol.https.allow=always'; do
  grep -Fq "$git_child_control" "$github_auth_lib" || \
    fail "GitHub child Git is missing isolation control: $git_child_control"
done
github_workspace_case="$repo_root/evals/cases/github-workspace-readiness-at-external-boundary.yaml"
for forbidden_workspace_command in 'gh auth login' 'git credential-osxkeychain get' \
  'security find-internet-password' 'security find-generic-password'; do
  grep -Fqx "    - $forbidden_workspace_command" "$github_workspace_case" || \
    fail "github-workspace-readiness-at-external-boundary must reject auth divergence: $forbidden_workspace_command"
done
grep -Fq -- '--operation git-push' "$github_workspace_case" || \
  fail 'github-workspace-readiness-at-external-boundary must defer the capability gate until backup'
grep -Fq 'github-failure-fingerprint-no-identical-retry' \
  "$repo_root/evals/cases/github-failure-fingerprint-no-identical-retry.yaml" || \
  fail 'Core evals must reject identical GitHub retries without a meaningful delta'

# The executable eval runtime is model-independent. Its fixture pins trusted PASS, observed
# FAIL, forbidden-report rejection, agent-only UNVERIFIED, malformed input, regression comparison,
# dirty-tree refusal, missing adapter handling, isolated execution, and workspace cleanup.
eval_runtime="$repo_root/tools/run-evals.py"
eval_fixture="$repo_root/evals/fixtures/eval-runtime"
if [[ -f "$eval_runtime" ]]; then
  [[ -x "$eval_runtime" ]] || fail 'tools/run-evals.py is not executable'
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
      "$eval_runtime" 2>/dev/null || fail 'tools/run-evals.py has invalid Python syntax'
    if [[ "$full" == true ]]; then
    eval_pass_output="$(python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/pass.jsonl" --baseline "$eval_fixture/baseline.json" 2>&1)" || \
      fail "eval runtime fixture: trusted pass trace was rejected: $eval_pass_output"
    printf '%s\n' "$eval_pass_output" | grep -Fq 'status=PASS' || \
      fail 'eval runtime fixture: trusted pass trace did not score PASS'
    printf '%s\n' "$eval_pass_output" | grep -Fq 'regressions=1' || \
      fail 'eval runtime fixture: baseline performance regression was not reported'

    set +e
    eval_fail_output="$(python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/fail.jsonl" 2>&1)"
    eval_fail_status=$?
    set -e
    (( eval_fail_status == 1 )) && printf '%s\n' "$eval_fail_output" | grep -Fq 'status=FAIL' || \
      fail 'eval runtime fixture: observed violations did not score FAIL with exit 1'

    set +e
    eval_rejected_report_output="$(python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/rejected-report.jsonl" --json 2>&1)"
    eval_rejected_report_status=$?
    set -e
    (( eval_rejected_report_status == 1 )) && \
      printf '%s\n' "$eval_rejected_report_output" | \
        grep -A1 -F '"check": "must_not_report:repeated-approval-required"' | \
        grep -Fq '"status": "FAIL"' || \
      fail 'eval runtime fixture: a repeated-approval report was not rejected by must_not_report'

    set +e
    eval_failed_run_output="$(python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/failed-run.jsonl" 2>&1)"
    eval_failed_run_status=$?
    set -e
    (( eval_failed_run_status == 1 )) && printf '%s\n' "$eval_failed_run_output" | grep -Fq 'status=FAIL' || \
      fail 'eval runtime fixture: a required command that exited nonzero was still accepted as must_run evidence'

    eval_unverified_output="$(python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/unverified.jsonl" 2>&1)" || \
      fail 'eval runtime fixture: agent-only trace returned an infrastructure error'
    printf '%s\n' "$eval_unverified_output" | grep -Fq 'status=UNVERIFIED' || \
      fail 'eval runtime fixture: agent-only evidence was promoted above UNVERIFIED'

    set +e
    python3 "$eval_runtime" score --case "$eval_fixture/case.yaml" \
      --trace "$eval_fixture/invalid.jsonl" >/dev/null 2>&1
    eval_invalid_status=$?
    set -e
    (( eval_invalid_status == 2 )) || fail 'eval runtime fixture: malformed JSONL did not exit 2'

    eval_runner_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-eval-runner.XXXXXX")"
    cleanup_paths+=("$eval_runner_root")
    mkdir -p "$eval_runner_root/tools" "$eval_runner_root/evals/fixtures"
    cp "$eval_runtime" "$eval_runner_root/tools/run-evals.py"
    cp -R "$eval_fixture" "$eval_runner_root/evals/fixtures/eval-runtime"
    eval_runner_env=(HOME="$eval_runner_root" GIT_CONFIG_NOSYSTEM=1
      GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
      GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid)
    env "${eval_runner_env[@]}" git -C "$eval_runner_root" init -q
    env "${eval_runner_env[@]}" git -C "$eval_runner_root" add -A
    env "${eval_runner_env[@]}" git -C "$eval_runner_root" commit -q -m 'fixture: eval runner'
    printf 'dirty\n' > "$eval_runner_root/dirty.txt"
    set +e
    eval_dirty_output="$(cd "$eval_runner_root" && python3 tools/run-evals.py run \
      --adapter evals/fixtures/eval-runtime/adapter.sh \
      --case evals/fixtures/eval-runtime/case.yaml 2>&1)"
    eval_dirty_status=$?
    set -e
    (( eval_dirty_status == 2 )) && printf '%s\n' "$eval_dirty_output" | grep -Fq 'requires a clean Git tree' || \
      fail 'eval runtime fixture: dirty Git state was not refused'
    set +e
    eval_missing_output="$(cd "$eval_runner_root" && python3 tools/run-evals.py run --allow-dirty \
      --adapter evals/fixtures/eval-runtime/missing.sh \
      --case evals/fixtures/eval-runtime/case.yaml 2>&1)"
    eval_missing_status=$?
    set -e
    (( eval_missing_status == 2 )) && printf '%s\n' "$eval_missing_output" | grep -Fq 'adapter must be an existing executable' || \
      fail 'eval runtime fixture: a missing optional adapter was not diagnosed'
    eval_output_dir="$eval_runner_root/output"
    eval_run_output="$(cd "$eval_runner_root" && python3 tools/run-evals.py run --allow-dirty \
      --adapter evals/fixtures/eval-runtime/adapter.sh \
      --case evals/fixtures/eval-runtime/case.yaml --output-dir "$eval_output_dir" 2>&1)" || \
      fail "eval runtime fixture: isolated adapter run failed: $eval_run_output"
    printf '%s\n' "$eval_run_output" | grep -Fq 'pass=1 fail=0 unverified=0 infra=0' || \
      fail 'eval runtime fixture: isolated adapter run did not report one PASS'
    [[ -f "$eval_output_dir/summary.json" ]] || \
      fail 'eval runtime fixture: isolated adapter run omitted summary.json'
    if find "$eval_output_dir" -maxdepth 1 -type d -name '.workspace-*' | grep -q .; then
      fail 'eval runtime fixture: isolated workspace was not cleaned up'
    fi
    eval_decay_output_dir="$eval_runner_root/decay-output"
    eval_decay_output="$(cd "$eval_runner_root" && python3 tools/run-evals.py run --allow-dirty \
      --adapter evals/fixtures/eval-runtime/adapter.sh \
      --case evals/fixtures/eval-runtime/runtime-decay-clean.yaml \
      --case evals/fixtures/eval-runtime/runtime-decay-aged.yaml \
      --output-dir "$eval_decay_output_dir" 2>&1)" || \
      fail "eval runtime fixture: Clean/Aged comparison failed: $eval_decay_output"
    printf '%s\n' "$eval_decay_output" | grep -Fq 'decay=PASS' || \
      fail 'eval runtime fixture: Clean/Aged comparison did not report decay=PASS'
    python3 - "$eval_decay_output_dir/summary.json" <<'PY' || \
      fail 'eval runtime fixture: summary.json omitted the expected decay metrics'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    comparison = json.load(handle)["decay_comparison"]
metrics = comparison["metrics"]
assert comparison["status"] == "PASS"
assert comparison["pair_count"] == 1
assert metrics["success_delta"] == 0
assert metrics["aged_stale_reference_rate"] == 0
assert metrics["read_amplification"] == 1
assert metrics["context_amplification"] == 1.2
PY
    set +e
    eval_decay_regression_output="$(cd "$eval_runner_root" && AGENT_EVAL_DECAY_REGRESSION=true \
      python3 tools/run-evals.py run --allow-dirty \
      --adapter evals/fixtures/eval-runtime/adapter.sh \
      --case evals/fixtures/eval-runtime/runtime-decay-clean.yaml \
      --case evals/fixtures/eval-runtime/runtime-decay-aged.yaml \
      --output-dir "$eval_runner_root/decay-regression-output" 2>&1)"
    eval_decay_regression_status=$?
    set -e
    (( eval_decay_regression_status == 1 )) && \
      printf '%s\n' "$eval_decay_regression_output" | grep -Fq 'decay=FAIL' || \
      fail 'eval runtime fixture: Aged read amplification did not fail the decay gate'
    fi
  else
    warn 'python3 is unavailable; executable eval runtime fixtures were not run'
  fi
fi

if ! grep -Eq '    - projects/.+/STATE\.md#現在の目標=.+' "$repo_root/evals/cases/project-state-closeout.yaml"; then
  fail 'project-state-closeout does not require advancing the current goal'
fi
grep -Fq 'projects/site-migration/PROJECT.md#status=completed' "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not require status=completed'
grep -Fq 'projects/site-migration/STATE.md#現在の目標=なし（Project完了）' \
  "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not close the current goal'
grep -Fq 'projects/site-migration/STATE.md#次の一手=なし（Project完了）' \
  "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not close the next action'

backup_tool="$repo_root/tools/backup-to-github.sh"
registry_lib="$repo_root/tools/lib/project-registry.sh"
if [[ -f "$registry_lib" ]]; then
  "$syntax_bash" -n "$registry_lib" 2>/dev/null || fail 'tools/lib/project-registry.sh fails bash -n'
  grep -Fq 'agent_registry_records()' "$registry_lib" || \
    fail 'tools/lib/project-registry.sh does not own the registry parser'
  grep -Fq 'agent_repository_url_is_rejected()' "$registry_lib" || \
    fail 'tools/lib/project-registry.sh does not own repository URL validation'
  for registry_consumer in backup-to-github.sh build-context-cache.sh materialize-project-repositories.sh; do
    grep -Fq '. "$tool_root/lib/project-registry.sh"' "$repo_root/tools/$registry_consumer" || \
      fail "tools/$registry_consumer does not source the shared Project registry predicates"
  done
  grep -Fq '. "$repo_root/tools/lib/project-registry.sh"' "$repo_root/tools/validate-agent-directory.sh" || \
    fail 'tools/validate-agent-directory.sh does not source the shared Project registry predicates'
fi
if [[ -d "$repo_root/.github/workflows" ]]; then
  fail '.github/workflows is forbidden; GitHub is a passive backup, not an execution platform'
fi
if [[ -f "$backup_tool" ]]; then
  [[ -x "$backup_tool" ]] || fail 'tools/backup-to-github.sh is not executable'
  "$syntax_bash" -n "$backup_tool" 2>/dev/null || fail 'tools/backup-to-github.sh fails bash -n'

  allowed_git_subcommands='archive cat-file check-ref-format config diff fetch for-each-ref init ls-files ls-remote merge-base push read-tree rev-list rev-parse symbolic-ref'
  while IFS= read -r subcommand; do
    [[ -n "$subcommand" ]] || continue
    case " $allowed_git_subcommands " in
      *" $subcommand "*) ;;
      *) fail "tools/backup-to-github.sh uses a git subcommand outside the backup allowlist: $subcommand" ;;
    esac
  done < <(awk '
    {
      line = $0
      sub(/(^|[[:space:]])#.*$/, "", line)
      gsub(/[<>|&;]/, " SEP ", line)
      gsub(/[^A-Za-z0-9_.-]/, " ", line)
      n = split(line, token, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (token[i] != "git") continue
        j = i + 1
        while (j <= n && (token[j] == "-C" || token[j] == "-c")) j += 2
        while (j <= n && substr(token[j], 1, 1) == "-") j++
        if (j <= n && token[j] != "" && token[j] != "SEP") print token[j]
      }
    }
  ' "$backup_tool" | LC_ALL=C sort -u)

  for forbidden_flag in --force --force-with-lease --mirror --prune --delete; do
    if grep -Fq -- "$forbidden_flag" "$backup_tool"; then
      fail "tools/backup-to-github.sh must not use $forbidden_flag"
    fi
  done

  push_invocations="$(grep -Ec '^[[:space:]]*push[[:space:]]+--porcelain' "$backup_tool" || true)"
  if (( push_invocations != 1 )); then
    fail "tools/backup-to-github.sh must contain exactly one shared-wrapper push invocation (found $push_invocations)"
  fi
  if ! grep -Eq '^[[:space:]]*push[[:space:]]+--porcelain[[:space:]]+"\$remote_url"[[:space:]]+"\$local_head:refs/heads/\$branch"' "$backup_tool"; then
    fail 'tools/backup-to-github.sh must push only the immutable audited SHA in $local_head:refs/heads/$branch'
  fi
  grep -Fq 'lib/github-auth.sh' "$backup_tool" || \
    fail 'tools/backup-to-github.sh must use the shared GitHub authentication resolver'
  grep -Fq 'github_git_run' "$backup_tool" || \
    fail 'tools/backup-to-github.sh must route remote Git operations through github_git_run'
  if grep -Fq 'github_git_run "$repo_root"' "$backup_tool" || \
    grep -Fq 'ensure_github_remote_auth "$repo_root"' "$backup_tool"; then
    fail 'fixed-commit backup must keep Git audit root separate from the caller Agent credential root'
  fi
  grep -Fq 'fixed commit credential owner: caller Agent root preserved without copying .env' "$backup_tool" || \
    fail 'fixed-commit backup does not preserve the caller Agent credential owner without copying .env'
  if grep -Eq 'cp[^#]*(/|\$)[^[:space:]]*\.env([[:space:]]|$)' "$backup_tool"; then
    fail 'fixed-commit backup must not copy an Agent .env into its audit snapshot'
  fi
fi

materialize_tool="$repo_root/tools/materialize-project-repositories.sh"
if [[ -f "$materialize_tool" ]]; then
  [[ -x "$materialize_tool" ]] || fail 'tools/materialize-project-repositories.sh is not executable'
  "$syntax_bash" -n "$materialize_tool" 2>/dev/null || \
    fail 'tools/materialize-project-repositories.sh fails bash -n'
  for forbidden_flag in --force --mirror --hard; do
    if grep -Fq -- "$forbidden_flag" "$materialize_tool"; then
      fail "tools/materialize-project-repositories.sh must not use $forbidden_flag"
    fi
  done
  # Never mutate an existing clone with reset/clean/stash/merge/rebase.
  for forbidden_subcommand in reset clean stash merge rebase pull; do
    if grep -Eq "git[^#]*[[:space:]]$forbidden_subcommand[[:space:]]" "$materialize_tool"; then
      fail "tools/materialize-project-repositories.sh must not run git $forbidden_subcommand"
    fi
  done
  grep -Fq 'MATERIALIZATION_OK' "$materialize_tool" || \
    fail 'tools/materialize-project-repositories.sh does not emit MATERIALIZATION_OK'
  grep -Fq 'MATERIALIZATION_BLOCKED' "$materialize_tool" || \
    fail 'tools/materialize-project-repositories.sh does not emit MATERIALIZATION_BLOCKED'
  grep -Fq 'lib/github-auth.sh' "$materialize_tool" || \
    fail 'GitHub materialization must use the shared capability resolver'
  grep -Fq 'github_git_run' "$materialize_tool" || \
    fail 'GitHub materialization must isolate credentials at the clone/fetch boundary'
fi

report_tool="$repo_root/tools/report-upstream-issue.sh"
upstream_contract="$repo_root/tools/UPSTREAM.md"
grep -Fqx '## Standing Authorizationによる送信' "$upstream_contract" || \
  fail 'tools/UPSTREAM.md is missing its Standing Authorization send contract'
grep -Fqx '利用者の明示送信依頼、または次の全条件を満たす宛先固定の報告契約をStanding Authorizationとする。' "$upstream_contract" || \
  fail 'tools/UPSTREAM.md is missing the explicit-or-fixed-contract authorization rule for Issue sends'
if [[ -f "$report_tool" ]]; then
  [[ -x "$report_tool" ]] || fail 'tools/report-upstream-issue.sh is not executable'
  "$syntax_bash" -n "$report_tool" 2>/dev/null || fail 'tools/report-upstream-issue.sh fails bash -n'

  # The destination allowlist is a contract (tools/UPSTREAM.md#宛先許可リスト): literal fixed
  # entries, one fixed default, and --repo only selects inside the allowlist (#44).
  fixed_destination_count="$(grep -cF "upstream_repo='claudagt/agent-directory'" "$report_tool" || true)"
  if [[ "$fixed_destination_count" != '1' ]]; then
    fail 'tools/report-upstream-issue.sh must default upstream_repo to claudagt/agent-directory exactly once'
  fi
  allowlist_declaration_count="$(grep -cF 'upstream_repo_allowlist=(' "$report_tool" || true)"
  if [[ "$allowlist_declaration_count" != '1' ]]; then
    fail 'tools/report-upstream-issue.sh must declare upstream_repo_allowlist exactly once'
  fi
  if sed -n '/upstream_repo_allowlist=(/,/^)/p' "$report_tool" | grep -q '\$'; then
    fail 'the destination allowlist in tools/report-upstream-issue.sh must hold only literal entries; no variable or environment expansion may extend it'
  fi
  grep -Eq -- '--repo\)' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must accept --repo to select an allowlisted destination'
  grep -Fq 'destination-not-allowed' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must reject destinations outside the allowlist with destination-not-allowed'
  if grep -E 'gh issue' "$report_tool" | grep -Fv -- '--repo "$upstream_repo"' | grep -q .; then
    fail 'tools/report-upstream-issue.sh must pass --repo "$upstream_repo" on every gh issue invocation'
  fi
  for report_token in UPSTREAM_REPORT_OK UPSTREAM_REPORT_BLOCKED UPSTREAM_REPORT_DRAFTED; do
    grep -Fq "$report_token" "$report_tool" || \
      fail "tools/report-upstream-issue.sh does not emit $report_token"
  done
  grep -Fq 'lib/github-auth.sh' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must use the shared GitHub authentication resolver'
  grep -Fq 'exit 3' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must return exit 3 for an unsent authentication draft'
  # The reporting path never writes to git state.
  for forbidden_subcommand in push pull merge rebase reset clean commit; do
    if grep -Eq "git[^#]*[[:space:]]$forbidden_subcommand[[:space:]]" "$report_tool"; then
      fail "tools/report-upstream-issue.sh must not run git $forbidden_subcommand"
    fi
  done
  # Anonymization is fail-closed: an unparseable self-definition must block, never skip the rule.
  grep -Fq 'anonymization-source-unparsed' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must fail closed when no agent name is extractable from AGENTS.md#自己定義'
  # Duplicate handling never blocks a report: an identical normalized title auto-comments on
  # the existing issue, ambiguous candidates are listed and the new issue is still created.
  grep -Fq 'normalize_issue_title' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must normalize titles to auto-comment on an identical open issue'
  if grep -Fq 'possible-duplicate' "$report_tool"; then
    fail 'tools/report-upstream-issue.sh must not stop on duplicate candidates; observations are never dropped'
  fi
fi

grep -Fq 'tools/backup-to-github.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/backup-to-github.sh'
grep -Fq 'tools/BACKUP.md' "$repo_root/README.md" || fail 'README.md does not register tools/BACKUP.md'
grep -Fq 'tools/materialize-project-repositories.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/materialize-project-repositories.sh'
grep -Fq 'backup-to-github.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register backup-to-github.sh'
grep -Fq 'report-upstream-issue.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register report-upstream-issue.sh'
grep -Fq 'run-evals.py' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register run-evals.py'
grep -Fq 'tools/run-evals.py' "$repo_root/README.md" || \
  fail 'README.md does not register tools/run-evals.py'
grep -Fq 'tools/UPSTREAM.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not route upstream issue reporting to tools/UPSTREAM.md'
grep -Fq 'repository ruleがPRを必須にする場合' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not distinguish PR-required remote merge from forbidden local merge'
grep -Fq 'expected head SHA確認' "$repo_root/projects/PROJECTS.md" || \
  fail 'projects/PROJECTS.md does not define the PR-required remote completion path'
grep -Fq 'remote / local source branch不在' "$repo_root/projects/PROJECTS.md" || \
  fail 'projects/PROJECTS.md does not require post-merge source branch cleanup evidence'
grep -Fq 'exact-merged-source-branch-deleted-remotely-and-confirmed-absent' \
  "$repo_root/evals/cases/pr-required-remote-completion.yaml" || \
  fail 'PR-required remote eval does not require exact remote source branch cleanup'
grep -Fq 'matching-local-source-branch-deleted-after-checkout-moved-safely' \
  "$repo_root/evals/cases/pr-required-remote-completion.yaml" || \
  fail 'PR-required remote eval does not require safe local source branch cleanup'
grep -Fq 'PR必須rule時の限定remote merge' "$repo_root/tools/BACKUP.md" || \
  fail 'tools/BACKUP.md does not classify PR-required remote merge'
grep -Fq 'OPERATING_PROFILE.md' "$repo_root/README.md" || \
  fail 'README.md does not register OPERATING_PROFILE.md'
grep -Fq '[SETUP.md](SETUP.md)' "$repo_root/README.md" || \
  fail 'README.md does not route initial setup to SETUP.md'
for setup_heading in '## Supported runtimes' '## Initial setup' '## Workspace root' \
  '## Claude authentication' '## Provider-specific setup' '## Preflight checks' \
  '## Scheduled / unattended execution' '## Provider isolation and recovery' '## Machine-local secrets' \
  '## Multi-machine notes' '## Troubleshooting' '## Verification'; do
  grep -Fqx -- "$setup_heading" "$repo_root/SETUP.md" || \
    fail "SETUP.md is missing its setup boundary: $setup_heading"
done
for setup_contract in 'claude setup-token' 'CLAUDE_CODE_OAUTH_TOKEN' 'claude auth status' \
  'https://code.claude.com/docs/en/authentication' 'https://code.claude.com/docs/en/security' \
  '実際に作業するAgent Workspace / Git rootをworking directoryとして起動' \
  '内部fieldを直接patchする方法はCore recommendationにしない' \
  '両Providerを導入していてもtask ownerを共有させない' \
  '別Providerを自動worker、reviewer、fallbackにしない'; do
  grep -Fq -- "$setup_contract" "$repo_root/SETUP.md" || \
    fail "SETUP.md lost a required runtime setup contract: $setup_contract"
done
for profile_heading in '## 適用と優先順位' '## Core契約' '## Providerの選択と分離' \
  '## 自律的なSurface選択' '## OpenAI Provider Profile' '## 複合タスクとSingle Owner' \
  '## Anthropic Provider Profile' '## Cross-provider Handoff' '## AvailabilityとRecovery' \
  '## Deterministic Execution Layer' '## Repository State' '## Scheduled Execution' '## 変更耐性'; do
  grep -Fqx -- "$profile_heading" "$repo_root/OPERATING_PROFILE.md" || \
    fail "OPERATING_PROFILE.md is missing its responsibility boundary: $profile_heading"
done
# Guard Provider isolation, autonomous surface judgment, and durable Core invariants.
grep -Fq 'Reference Architecture' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must identify itself as a non-mandatory Reference Architecture'
grep -Fq 'Human / Operatorはultimate authority' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must preserve Human / Operator authority'
grep -Fq 'one task → one provider family → one final owner' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must preserve one Provider family and final owner per task'
grep -Fq '本テンプレートはOpenAIを主対象' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must identify OpenAI as the primary concrete profile'
for openai_surface in '| Chat |' '| ChatGPT Work |' '| Codex |'; do
  grep -Fq "$openai_surface" "$repo_root/OPERATING_PROFILE.md" || \
    fail "OPERATING_PROFILE.md lost its OpenAI surface guidance: $openai_surface"
done
grep -Fq 'surface mappingは硬い禁止表ではない' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must preserve autonomous non-rigid surface selection'
grep -Fq 'Providerをまたぐ自動delegateと自動fallbackを行わない' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must reject automatic cross-Provider delegation and fallback'
grep -Fq '直接起動できないsurfaceへ仕事を送った、開始した、完了したと推測してはならない' \
  "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must not invent unsupported cross-surface dispatch'
grep -Fq 'Anthropicを選んだtaskは、Claude、Claude Code、Anthropic API等のAnthropic family内で完了' \
  "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must keep Anthropic tasks inside the Anthropic family'
grep -Fq 'Repositoryのtracked canonical state' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must preserve repository canonical state'
grep -Fq '`Runtime-native scheduler`' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must keep scheduled execution in the Runtime capability boundary'
grep -Fq '`Route → Target → Work → Verify → Finish`' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must route scheduled triggers through the normal task lifecycle'
grep -Fq 'Scheduler Engine、daemon、schedule registry' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must refuse an agent-owned scheduler subsystem'
grep -Fq 'file changes、Git state、生成output、external' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must reconcile partial execution before handoff or recovery'
grep -Fq '別Providerへ自動fallbackしない' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must stop instead of automatically changing Provider families'
grep -Fq '独自Provider router、workflow engine、queue、RPC、daemonをCoreへ追加しない' \
  "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must refuse a Core-owned Provider orchestration subsystem'
grep -Fqx '## Scheduled executionケースの最低条件' "$repo_root/evals/EVALS.md" || \
  fail 'evals/EVALS.md does not own the scheduled execution case minimum conditions'
# The operator interaction language contract is presence-checked like the other bootloader
# contracts: deleting the three lines must fail even outside --strict (#28).
grep -Fq '運用者応対言語' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not carry the operator interaction language contract (運用者応対言語)'

# 相互参照の解決検査（tools/TOOLS.md#相互参照）は、実測された誤拒否領域だけを内部checkerへ
# 分離する。meta正本の変更はfull検証へ進むため、全追跡Markdown走査は--fullだけで実行する。
reference_checker="$repo_root/tools/validator/check-markdown-references.sh"
if [[ ! -f "$reference_checker" ]]; then
  fail 'tools/validator/check-markdown-references.sh is missing'
elif ! "$syntax_bash" -n "$reference_checker" 2>/dev/null; then
  fail 'tools/validator/check-markdown-references.sh fails bash -n'
elif [[ "$full" == true ]]; then
  reference_schema_fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-reference-schema.XXXXXX")"
  cleanup_paths+=("$reference_schema_fixture")
  mkdir -p "$reference_schema_fixture/docs"
  printf '%s\n' '# Project' '' '- **PC-01** Concrete criterion.' > \
    "$reference_schema_fixture/PROJECT.md"
  printf '%s\n' '`PROJECT.md#PC-xx` is schema notation; `PROJECT.md#PC-01` is concrete.' > \
    "$reference_schema_fixture/docs/schema.md"
  if ! bash "$reference_checker" "$reference_schema_fixture" docs/schema.md >/dev/null 2>&1; then
    fail 'Markdown reference checker rejected PC-xx schema notation beside a valid concrete criterion'
  fi
  printf '%s\n' '`PROJECT.md#PC-99` is an invalid concrete criterion.' > \
    "$reference_schema_fixture/docs/schema.md"
  if bash "$reference_checker" "$reference_schema_fixture" docs/schema.md >/dev/null 2>&1; then
    fail 'Markdown reference checker accepted a missing concrete Project criterion'
  fi
  reference_output=''
  reference_status=0
  reference_output="$(bash "$reference_checker" "$repo_root" 2>&1)" || reference_status=$?
  if (( reference_status != 0 )); then
    if [[ -z "$reference_output" ]]; then
      fail 'tools/validator/check-markdown-references.sh failed without a diagnostic'
    else
      while IFS= read -r reference_failure; do
        [[ -n "$reference_failure" ]] && fail "$reference_failure"
      done <<<"$reference_output"
    fi
  fi
fi
grep -Fq 'materialize-project-repositories.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register materialize-project-repositories.sh'
grep -Fq 'task.sh' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md does not register task.sh'
if [[ -f "$repo_root/tools/task.sh" ]]; then
  [[ -x "$repo_root/tools/task.sh" ]] || fail 'tools/task.sh is not executable'
  "$syntax_bash" -n "$repo_root/tools/task.sh" 2>/dev/null || fail 'tools/task.sh fails bash -n'
fi
grep -Fq 'tools/SAFETY.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not route normal safety decisions to tools/SAFETY.md'
for runtime_profile in ask auto full; do
  grep -Eq "(^|[^[:alnum:]_])${runtime_profile}([^[:alnum:]_]|$)" "$repo_root/OPERATING_PROFILE.md" || \
    fail "OPERATING_PROFILE.md does not define the $runtime_profile Runtime Profile"
done
grep -Fq '推奨default' "$repo_root/OPERATING_PROFILE.md" || \
  fail 'OPERATING_PROFILE.md must make auto the recommended default without forcing Runtime settings'
for capability_state in observed declared not-probed unavailable; do
  grep -Fq "$capability_state" "$repo_root/OPERATING_PROFILE.md" || \
    fail "OPERATING_PROFILE.md does not distinguish capability state: $capability_state"
done
for safety_number in 1 2 3 4 5 6; do
  grep -Eq "^${safety_number}\\. \\*\\*" "$repo_root/tools/SAFETY.md" || \
    fail "tools/SAFETY.md is missing invariant $safety_number"
done
grep -Fq 'prepare-context.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register prepare-context.sh'
if [[ -f "$repo_root/tools/prepare-context.sh" ]]; then
  "$syntax_bash" -n "$repo_root/tools/prepare-context.sh" 2>/dev/null || \
    fail 'tools/prepare-context.sh fails bash -n'
fi
grep -Fq 'setup-local-environment.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register setup-local-environment.sh'
if [[ -f "$repo_root/tools/setup-local-environment.sh" ]]; then
  [[ -x "$repo_root/tools/setup-local-environment.sh" ]] || \
    fail 'tools/setup-local-environment.sh is not executable'
  "$syntax_bash" -n "$repo_root/tools/setup-local-environment.sh" 2>/dev/null || \
    fail 'tools/setup-local-environment.sh fails bash -n'
fi
grep -Fq 'check-runtime-readiness.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register check-runtime-readiness.sh'
if [[ -f "$repo_root/tools/check-runtime-readiness.sh" ]]; then
  [[ -x "$repo_root/tools/check-runtime-readiness.sh" ]] || \
    fail 'tools/check-runtime-readiness.sh is not executable'
  "$syntax_bash" -n "$repo_root/tools/check-runtime-readiness.sh" 2>/dev/null || \
    fail 'tools/check-runtime-readiness.sh fails bash -n'
fi
for github_auth_consumer in tools/backup-to-github.sh tools/report-upstream-issue.sh; do
  grep -Fq 'expected_login="${AGENT_DIRECTORY_GITHUB_EXPECTED_LOGIN:-}"' \
    "$repo_root/$github_auth_consumer" || \
    fail "$github_auth_consumer must not carry a user-specific default GitHub login"
done
if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  local_environment_fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-local-environment.XXXXXX")"
  cleanup_paths+=("$local_environment_fixture")
  mkdir -p "$local_environment_fixture/work/tools"
  cp "$repo_root/tools/setup-local-environment.sh" \
    "$local_environment_fixture/work/tools/setup-local-environment.sh"
  printf '#!/bin/bash\nexit 0\n' > "$local_environment_fixture/work/tools/build-context-cache.sh"
  printf '#!/bin/bash\nexit 0\n' > "$local_environment_fixture/work/tools/validate-agent-directory.sh"
  chmod 755 "$local_environment_fixture/work/tools/"*.sh
  printf '# AGENTS.md\n\n## 自己定義\n\n- あなたは`fixture-agent`（役割:`fixture-role`）。\n' > \
    "$local_environment_fixture/work/AGENTS.md"
  git -C "$local_environment_fixture/work" init -q
  git config --file "$local_environment_fixture/global.gitconfig" user.name host-user
  git config --file "$local_environment_fixture/global.gitconfig" user.email host@example.invalid
  local_environment_run() {
    set +e
    local_environment_output="$(env -i PATH="$PATH" HOME="$local_environment_fixture/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$local_environment_fixture/global.gitconfig" "$@" \
      /bin/bash "$local_environment_fixture/work/tools/setup-local-environment.sh" 2>&1)"
    local_environment_status=$?
    set -e
  }
  local_environment_run
  [[ "$local_environment_status" == 0 && "$local_environment_output" == \
    *'git-author=recommended'* ]] || \
    fail "local environment fixture: recommended Agent name was not applied: $local_environment_output"
  [[ "$(git -C "$local_environment_fixture/work" config --local --get user.name)" == \
    'fixture-agent' ]] || fail 'local environment fixture: repo-local user.name did not use the Agent name'
  [[ -z "$(git -C "$local_environment_fixture/work" config --local --get user.email 2>/dev/null || true)" ]] || \
    fail 'local environment fixture: setup inferred a repository-local email'

  local_private_email='direct''@''public.test'
  git -C "$local_environment_fixture/work" config --local user.email "$local_private_email"
  local_environment_run
  if (( local_environment_status == 0 )) || \
    [[ "$local_environment_output" != *'reason=unsafe-git-email'* ]]; then
    fail 'local environment fixture: setup accepted a direct email without explicit public approval'
  fi
  git -C "$local_environment_fixture/work" config --local --unset user.email

  set +e
  local_environment_output="$(env -i PATH="$PATH" HOME="$local_environment_fixture/home" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$local_environment_fixture/global.gitconfig" \
    /bin/bash "$local_environment_fixture/work/tools/setup-local-environment.sh" \
    --git-author-email '123+fixture@users.noreply.github.com' 2>&1)"
  local_environment_status=$?
  set -e
  [[ "$local_environment_status" == 0 && \
    "$(git -C "$local_environment_fixture/work" config --local --get user.email)" == \
      '123+fixture@users.noreply.github.com' ]] || \
    fail 'local environment fixture: explicit GitHub noreply email was not configured'
  git -C "$local_environment_fixture/work" config --local --unset user.email

  git -C "$local_environment_fixture/work" config --local user.name user-override
  local_environment_run
  [[ "$(git -C "$local_environment_fixture/work" config --local --get user.name)" == \
    'user-override' && "$local_environment_output" == *'git-author=existing'* ]] || \
    fail 'local environment fixture: repeated setup replaced the user override'

  local_environment_run env AGENT_DIRECTORY_GIT_AUTHOR_NAME=environment-agent
  [[ "$(git -C "$local_environment_fixture/work" config --local --get user.name)" == \
    'environment-agent' && "$local_environment_output" == *'git-author=explicit'* ]] || \
    fail 'local environment fixture: environment author override was not applied'
  set +e
  local_environment_output="$(env -i PATH="$PATH" HOME="$local_environment_fixture/home" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$local_environment_fixture/global.gitconfig" \
    AGENT_DIRECTORY_GIT_AUTHOR_NAME=environment-agent \
    /bin/bash "$local_environment_fixture/work/tools/setup-local-environment.sh" \
    --git-author-name cli-agent 2>&1)"
  local_environment_status=$?
  set -e
  [[ "$local_environment_status" == 0 && \
    "$(git -C "$local_environment_fixture/work" config --local --get user.name)" == 'cli-agent' ]] || \
    fail 'local environment fixture: CLI author override did not take precedence'

  git -C "$local_environment_fixture/work" config --local --unset user.name
  printf '# AGENTS.md\n\n## 自己定義\n\n- あなたは`<agent-name>`（役割:`<agent-role>`）。\n' > \
    "$local_environment_fixture/work/AGENTS.md"
  local_environment_run
  [[ -z "$(git -C "$local_environment_fixture/work" config --local --get user.name 2>/dev/null || true)" && \
    "$local_environment_output" == *'git-author=template-unset'* ]] || \
    fail 'local environment fixture: template placeholder was written as a Git author'

  runtime_readiness_fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-runtime-readiness.XXXXXX")"
  cleanup_paths+=("$runtime_readiness_fixture")
  mkdir -p "$runtime_readiness_fixture/work/tools" "$runtime_readiness_fixture/bin"
  cp "$repo_root/tools/check-runtime-readiness.sh" \
    "$runtime_readiness_fixture/work/tools/check-runtime-readiness.sh"
  chmod 755 "$runtime_readiness_fixture/work/tools/check-runtime-readiness.sh"
  git -C "$runtime_readiness_fixture/work" init -q
  printf '%s\n' '# Fixture Agent Workspace' > "$runtime_readiness_fixture/work/AGENTS.md"
  printf '%s\n' '#!/bin/bash' \
    'if [[ "${1:-}" == "--version" ]]; then printf "codex-cli fixture\\n"; exit 0; fi' \
    'if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then exit 0; fi' \
    'exit 1' > "$runtime_readiness_fixture/bin/codex"
  printf '%s\n' '#!/bin/bash' \
    'if [[ "${1:-}" == "--version" ]]; then printf "fixture (Claude Code)\\n"; exit 0; fi' \
    'if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then [[ -z "${MOCK_CLAUDE_AUTH_FAIL:-}" ]]; exit; fi' \
    'exit 1' > "$runtime_readiness_fixture/bin/claude"
  chmod 755 "$runtime_readiness_fixture/bin/codex" "$runtime_readiness_fixture/bin/claude"

  set +e
  runtime_readiness_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      CLAUDE_CODE_OAUTH_TOKEN='fixture-oauth-secret' \
      bash tools/check-runtime-readiness.sh --require-codex --require-claude 2>&1)"
  runtime_readiness_status=$?
  set -e
  if (( runtime_readiness_status != 0 )) || \
    [[ "$runtime_readiness_output" != *'runtime_profile=auto runtime_profile_source=recommended-default'* || \
      "$runtime_readiness_output" != *'workspace_root=observed filesystem_read=observed filesystem_write=not-probed'* || \
      "$runtime_readiness_output" != *'codex_executable=available codex_authentication=authenticated'* || \
      "$runtime_readiness_output" != *'claude_executable=available claude_authentication=authenticated'* || \
      "$runtime_readiness_output" != *'claude_oauth_env=present'* ]]; then
    fail "runtime readiness fixture: ready runtimes were not reported: $runtime_readiness_output"
  fi
  [[ "$runtime_readiness_output" != *'fixture-oauth-secret'* ]] || \
    fail 'runtime readiness fixture: OAuth token value was printed'

  set +e
  runtime_write_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      bash tools/check-runtime-readiness.sh --probe-workspace-write 2>&1)"
  runtime_write_status=$?
  set -e
  [[ "$runtime_write_status" == 0 && "$runtime_write_output" == *'filesystem_write=observed'* ]] || \
    fail "runtime readiness fixture: workspace write was not observed: $runtime_write_output"
  if find "$runtime_readiness_fixture/work" -maxdepth 1 -name '.runtime-write-probe.*' -print | grep -q .; then
    fail 'runtime readiness fixture: workspace write probe left a temporary file'
  fi

  set +e
  runtime_capability_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      bash tools/check-runtime-readiness.sh --profile auto \
        --require-capability filesystem_write --require-capability network \
        --capability-state network=declared 2>&1)"
  runtime_capability_status=$?
  set -e
  if (( runtime_capability_status != 0 )) || \
    [[ "$runtime_capability_output" != *'runtime_profile=auto runtime_profile_source=explicit'* || \
      "$runtime_capability_output" != *'required_capabilities=filesystem_write,network'* || \
      "$runtime_capability_output" != *'filesystem_write=observed network=declared'* ]]; then
    fail "runtime readiness fixture: explicit profile and capability declaration drifted: $runtime_capability_output"
  fi

  set +e
  runtime_unverified_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      bash tools/check-runtime-readiness.sh --profile ask --require-capability network 2>&1)"
  runtime_unverified_status=$?
  set -e
  if (( runtime_unverified_status != 0 )) || \
    [[ "$runtime_unverified_output" != *'runtime_profile=ask'* || \
      "$runtime_unverified_output" != *'network=not-probed'* || \
      "$runtime_unverified_output" != *'RUNTIME_READINESS_UNVERIFIED capabilities=network'* ]]; then
    fail "runtime readiness fixture: an unprobed capability was not kept distinct: $runtime_unverified_output"
  fi

  set +e
  runtime_unavailable_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      bash tools/check-runtime-readiness.sh --profile full --require-capability network \
        --capability-state network=unavailable 2>&1)"
  runtime_unavailable_status=$?
  set -e
  if (( runtime_unavailable_status == 0 )) || \
    [[ "$runtime_unavailable_output" != *'runtime_profile=full'* || \
      "$runtime_unavailable_output" != *'network=unavailable'* || \
      "$runtime_unavailable_output" != *'reason=capability-unavailable layer=runtime capability=network'* ]]; then
    fail "runtime readiness fixture: a known unavailable capability was not blocked: $runtime_unavailable_output"
  fi

  set +e
  runtime_readiness_output="$(cd "$runtime_readiness_fixture/work/tools" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" \
      bash check-runtime-readiness.sh --require-claude 2>&1)"
  runtime_readiness_status=$?
  set -e
  if (( runtime_readiness_status == 0 )) || \
    [[ "$runtime_readiness_output" != *'reason=workspace-root-mismatch'* ]]; then
    fail "runtime readiness fixture: incorrect cwd was accepted: $runtime_readiness_output"
  fi

  set +e
  runtime_readiness_output="$(cd "$runtime_readiness_fixture/work" && \
    env PATH="$runtime_readiness_fixture/bin:$PATH" MOCK_CLAUDE_AUTH_FAIL=1 \
      bash tools/check-runtime-readiness.sh --require-claude 2>&1)"
  runtime_readiness_status=$?
  set -e
  if (( runtime_readiness_status == 0 )) || \
    [[ "$runtime_readiness_output" != *'claude_authentication=unavailable'* || \
      "$runtime_readiness_output" != *'reason=claude-authentication-unavailable layer=external-provider'* ]]; then
    fail "runtime readiness fixture: missing Claude auth was accepted: $runtime_readiness_output"
  fi
fi
grep -Fq 'finalize-task.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register finalize-task.sh'
if [[ -f "$repo_root/tools/finalize-task.sh" ]]; then
  "$syntax_bash" -n "$repo_root/tools/finalize-task.sh" 2>/dev/null || \
    fail 'tools/finalize-task.sh fails bash -n'
fi
grep -Fq 'BACKUP.md' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md does not register BACKUP.md'
for scope_token in WORKSPACE_BACKUP_OK ROOT_BACKUP_OK; do
  grep -Fq "$scope_token" "$repo_root/tools/BACKUP.md" || \
    fail "tools/BACKUP.md does not document the $scope_token result line"
done
grep -Fq 'tools/BACKUP.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not delegate backup details to tools/BACKUP.md'

# --- Control boundary layer checks (canon: tools/CONTROL.md) ------------------------------------

require_file "$repo_root/tools/CONTROL.md"
require_file "$repo_root/tools/control-policy.tsv"
for control_tool in tools/check-boundary.sh tools/install-git-hooks.sh \
  tools/hooks/pre-commit tools/hooks/pre-push; do
  if [[ -f "$repo_root/$control_tool" ]]; then
    [[ -x "$repo_root/$control_tool" ]] || fail "$control_tool is not executable"
    "$syntax_bash" -n "$repo_root/$control_tool" 2>/dev/null || fail "$control_tool fails bash -n"
  fi
done

# The policy is a strict TSV with a fixed tier vocabulary; the verifier refuses anything else.
if [[ -f "$repo_root/tools/control-policy.tsv" ]]; then
  if ! awk -F '\t' '
      /^($|#)/ { next }
      $1 !~ /^(exempt|forbidden|frozen|guarded|contract)$/ || $2 == "" || NF > 3 { bad = 1 }
      END { exit bad }
    ' "$repo_root/tools/control-policy.tsv"; then
    fail 'tools/control-policy.tsv has a row outside the tier<TAB>pattern<TAB>note schema'
  fi
  # Pin the load-bearing rows so the policy is not silently weakened.
  for pinned_policy in 'forbidden:.env*' 'frozen:knowledge/raw/*' 'frozen:knowledge/wiki/logs/*' \
    'guarded:AGENTS.md' 'guarded:.codex/*' 'guarded:.claude/*' \
    'guarded:tools/SAFETY.md' 'guarded:tools/CONTROL.md' 'guarded:tools/control-policy.tsv' \
    'guarded:tools/check-boundary.sh' 'guarded:tools/install-git-hooks.sh' \
    'guarded:tools/validate-agent-directory.sh' 'guarded:tools/task.sh' \
    'guarded:tools/finalize-task.sh' 'guarded:tools/backup-to-github.sh' \
    'guarded:tools/report-upstream-issue.sh' 'guarded:tools/lib/github-auth.sh' \
    'guarded:tools/lib/project-registry.sh' 'guarded:tools/materialize-project-repositories.sh' \
    'guarded:tools/setup-local-environment.sh' 'guarded:tools/setup-github-auth.sh' \
    'guarded:tools/run-evals.py' \
    'guarded:evals/EVALS.md' 'guarded:evals/profiles/core.txt' \
    'guarded:projects/AGENTS.md' \
    'guarded:projects/LIFECYCLE.md' 'guarded:projects/REPOSITORIES.md' \
    'contract:projects/*/PROJECT.md'; do
    pinned_tier="${pinned_policy%%:*}"
    pinned_pattern="${pinned_policy#*:}"
    awk -F '\t' -v t="$pinned_tier" -v p="$pinned_pattern" \
      '$1 == t && $2 == p { found = 1 } END { exit !found }' \
      "$repo_root/tools/control-policy.tsv" || \
      fail "tools/control-policy.tsv lost a pinned row: $pinned_tier $pinned_pattern"
  done
  if [[ -f "$repo_root/evals/profiles/core.txt" ]]; then
    while IFS= read -r protected_core_case; do
      protected_core_case="${protected_core_case%%#*}"
      protected_core_case="$(printf '%s' "$protected_core_case" | tr -d '[:space:]')"
      [[ -n "$protected_core_case" ]] || continue
      awk -F '\t' -v p="evals/cases/$protected_core_case.yaml" \
        '$1 == "guarded" && $2 == p { found = 1 } END { exit !found }' \
        "$repo_root/tools/control-policy.tsv" || \
        fail "tools/control-policy.tsv does not guard core eval: $protected_core_case"
    done < "$repo_root/evals/profiles/core.txt"
  fi
fi

grep -Fq 'tools/CONTROL.md' "$repo_root/README.md" || fail 'README.md does not register tools/CONTROL.md'
grep -Fq 'tools/install-git-hooks.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/install-git-hooks.sh'
grep -Fq 'check-boundary.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register check-boundary.sh'
grep -Fq 'install-git-hooks.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register install-git-hooks.sh'
grep -Fq 'CONTROL.md' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md does not register CONTROL.md'
grep -Fq 'tools/CONTROL.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not delegate boundary enforcement to tools/CONTROL.md'
# The hook layer performs boundary checks only; it never becomes a backup or validation trigger.
grep -Fq 'backup' "$repo_root/tools/CONTROL.md" || \
  fail 'tools/CONTROL.md does not scope git hooks against the backup non-goal'

# --- Verify semantic authorization and Runtime responsibility boundaries ----------

# The root owns Provider-independent semantic authorization; each Owner holds detailed integrity conditions.
for autonomy_heading in '## 自律実行' '## 人間へ上げる例外'; do
  grep -Fqx -- "$autonomy_heading" "$repo_root/AGENTS.md" || \
    fail "AGENTS.md must carry the semantic authorization section: $autonomy_heading"
done

grep -Fqx -- '## Runtime Permissionの責務境界' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md must separate Generic Runtime Permission from agent-directory responsibilities'
grep -Fq 'Standing Authorization' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md must treat explicit user instructions as Standing Authorization'
grep -Fq 'Provider別permission wrapperを追加しない' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md must reject Provider-specific permission wrappers'

# Each of the four escalation categories routes to the canon that owns its details.
for exception_owner in projects/LIFECYCLE.md projects/PROJECTS.md tools/BACKUP.md tools/TOOLS.md; do
  grep -Fq "$exception_owner" "$repo_root/AGENTS.md" || \
    fail "AGENTS.md must route an escalation category to its canon: $exception_owner"
done

# Details live on the Owner side; do not restate them at the root, and do not leave the Owner empty.
while IFS='|' read -r owner_doc owner_heading; do
  [[ -n "$owner_doc" ]] || continue
  grep -Fqx -- "$owner_heading" "$repo_root/$owner_doc" || \
    fail "$owner_doc must own the semantic authorization detail: $owner_heading"
done <<'AUTONOMY_OWNERS'
tools/TOOLS.md|## 自律実行の標準完了
tools/TOOLS.md|## 自己修復と停止
tools/TOOLS.md|### 超過時の標準処理
tools/BACKUP.md|## 実行trigger
tools/BACKUP.md|## remoteの分類
tools/BACKUP.md|## backupが失敗したとき
tools/CONTROL.md|## 違反の分類
tools/CONTROL.md|## 違反の代謝
tools/CONTROL.md|## 導入基準（将来拡張の凍結）
projects/PROJECTS.md|#### push policy
projects/LIFECYCLE.md|## 人間が決める遷移
knowledge/KNOWLEDGE.md|### 大きいKnowledgeの扱い
evals/EVALS.md|## 自律実行と例外ケースの最低条件
AUTONOMY_OWNERS

# The push policy vocabulary is exactly auto and gated.
grep -Fq '`auto`' "$repo_root/projects/PROJECTS.md" && grep -Fq '`gated`' "$repo_root/projects/PROJECTS.md" || \
  fail 'projects/PROJECTS.md must define both push policy values: auto and gated'

# Pin the size budgets so they are not silently raised.
while IFS= read -r budget_row; do
  [[ -n "$budget_row" ]] || continue
  grep -Fqx -- "$budget_row" "$repo_root/tools/TOOLS.md" || \
    fail "tools/TOOLS.md size budget row was raised or removed: $budget_row"
done <<'SIZE_BUDGET_ROWS'
| `AGENTS.md`（ルート） | 8KiB。6KiB超はwarning |
| `projects/AGENTS.md` | 2KiB |
| `projects/<name>/AGENTS.md` | 2KiB |
SIZE_BUDGET_ROWS

# Integration fixtures for real Git, cache, backup, and the materializer run only under --full.
# The default run is limited to static structural checks; Tool changes require --full (owned by tools/TOOLS.md).
# AGENT_VALIDATOR_NESTED_FIXTURE is an internal marker preventing recursive runs of a validator
# invoked from inside a fixture; it is never set in normal operation.
validator_metric_checkpoint 'static'
if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
github_auth_test_output="$(/bin/bash "$repo_root/tools/test-github-auth.sh" 2>&1)" || \
  fail "GitHub auth integration fixture failed: $github_auth_test_output"
printf '%s\n' "$github_auth_test_output" | grep -Fq 'GITHUB_AUTH_TEST_OK' || \
  fail 'GitHub auth integration fixture did not emit GITHUB_AUTH_TEST_OK'
cache_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-cache.XXXXXX")"
fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-fixture.XXXXXX")"
sqlite_fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-sqlite.XXXXXX")"
decay_clean_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-decay-clean.XXXXXX")"
decay_aged_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-decay-aged.XXXXXX")"
log_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-log.XXXXXX")"
backup_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-backup.XXXXXX")"
malformed_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-malformed.XXXXXX")"
malformed_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-malformed-cache.XXXXXX")"
# Cleanup is handled in one place by the opening EXIT trap (cleanup_tmp_paths). Do not override the trap here.
cleanup_paths+=("$cache_test_dir" "$fixture_cache_dir" "$sqlite_fixture_cache_dir" \
  "$decay_clean_cache_dir" "$decay_aged_cache_dir" "$log_fixture_dir" \
  "$backup_fixture_dir" "$malformed_fixture_dir" "$malformed_cache_dir")
if ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
  fail 'build-context-cache.sh failed to generate a cache'
elif ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" --check >/dev/null; then
  fail 'build-context-cache.sh --check reports a freshly generated cache as stale'
elif ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" --check-routing >/dev/null; then
  fail 'build-context-cache.sh --check-routing reports a fresh catalog as stale'
fi
context_meta_output="$(bash "$repo_root/tools/validator/check-context-meta.sh" \
  "$cache_test_dir/catalog.tsv" 2>&1)" || \
  fail "context meta catalog coverage failed: $context_meta_output"
printf '%s\n' "$context_meta_output" | grep -Fq 'CONTEXT_META_OK checked=22' || \
  fail 'context meta catalog coverage did not verify the complete canon set'
if grep -Eq '^head=' "$cache_test_dir/cache.meta"; then
  fail 'cache.meta must not use Git HEAD as a freshness input'
fi
if [[ -f "$cache_test_dir/manifest.tsv" ]]; then
  for immutable_area in knowledge/raw/internal knowledge/raw/external; do
    if awk -F '\t' -v area="$immutable_area/" '
        index($1, area) == 1 && $6 != "true" { bad = 1 }
        END { exit !bad }
      ' "$cache_test_dir/manifest.tsv"; then
      fail "build-context-cache.sh must mark every file under $immutable_area/ as immutable in manifest.tsv"
    fi
  done
fi

mkdir -p "$log_fixture_dir/knowledge/wiki"
{
  printf '# LOG — fixture\n\n---\n\n'
  i=1
  while (( i <= 999 )); do
    printf '2026-08-02  lint        fixture/%04d  threshold fixture\n' "$i"
    i=$((i + 1))
  done
} > "$log_fixture_dir/$knowledge_log_path"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" bash "$repo_root/tools/append-knowledge-log.sh" \
  --date 2026-08-02 --type lint --target fixture/1000 --summary 'threshold fixture' >/dev/null; then
  fail 'append-knowledge-log.sh failed at the 1,000-record threshold'
elif [[ ! -f "$log_fixture_dir/knowledge/wiki/logs/2026-Q3.md" ]]; then
  fail 'append-knowledge-log.sh did not create the expected quarterly archive'
elif [[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$log_fixture_dir/$knowledge_log_path" || true)" != '0' ]]; then
  fail 'append-knowledge-log.sh did not reset the current log after rotation'
elif [[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$log_fixture_dir/knowledge/wiki/logs/2026-Q3.md" || true)" != '1000' ]]; then
  fail 'append-knowledge-log.sh archive does not contain exactly 1,000 records'
fi
mkdir -p "$log_fixture_dir/nested/.tmp"
printf 'ignore me\n' > "$log_fixture_dir/nested/.tmp/ignored.txt"
printf 'keep me\n' > "$log_fixture_dir/nested/kept.txt"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$fixture_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
  fail 'build-context-cache.sh failed on nested .tmp fixture'
elif grep -Fq 'nested/.tmp/' "$fixture_cache_dir/manifest.tsv"; then
  fail 'build-context-cache.sh manifest includes a nested .tmp file'
elif ! grep -Fq $'nested/kept.txt\t' "$fixture_cache_dir/manifest.tsv"; then
  fail 'build-context-cache.sh nested .tmp test did not scan the adjacent durable file'
fi

# Routing and inventory are separate responsibilities: a routing-only rebuild refreshes
# the catalog without touching the manifest, and find-context.sh's stale recovery never
# produces a full workspace inventory.
mkdir -p "$log_fixture_dir/knowledge/wiki/topics"
printf -- '---\nsummary: routing rebuild probe\nstatus: active\naliases: []\n---\n\nrouting rebuild probe body\n' \
  > "$log_fixture_dir/knowledge/wiki/topics/routing-probe.md"
manifest_before_routing="$(cat "$fixture_cache_dir/manifest.tsv")"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$fixture_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" --routing-only >/dev/null; then
  fail 'build-context-cache.sh --routing-only failed'
else
  grep -Fq 'routing-probe' "$fixture_cache_dir/catalog.tsv" || \
    fail 'build-context-cache.sh --routing-only did not refresh the routing catalog'
  [[ "$manifest_before_routing" == "$(cat "$fixture_cache_dir/manifest.tsv")" ]] || \
    fail 'build-context-cache.sh --routing-only regenerated the workspace inventory (manifest)'
fi
routing_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-routing.XXXXXX")"
cleanup_paths+=("$routing_cache_dir")
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$routing_cache_dir" \
  bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- 'routing rebuild probe' >/dev/null; then
  fail 'find-context.sh failed to recover from a missing cache'
else
  [[ -f "$routing_cache_dir/catalog.tsv" ]] || \
    fail 'find-context.sh stale recovery did not produce a routing catalog'
  [[ ! -f "$routing_cache_dir/manifest.tsv" ]] || \
    fail 'find-context.sh stale recovery generated a full workspace inventory (manifest)'
fi

# --changed scoped mode: a project-only change validates only that target, and a change
# reaching meta canon falls back to the full static run. The fixture root deliberately
# lacks the root canon, so a scoped run passes only if it truly skips the full scan.
changed_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-changed.XXXXXX")"
cleanup_paths+=("$changed_fixture_dir")
changed_env=(
  HOME="$changed_fixture_dir" GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  AGENT_VALIDATOR_NESTED_FIXTURE=1
)
mkdir -p "$changed_fixture_dir/tools/lib" "$changed_fixture_dir/tools/validator" \
  "$changed_fixture_dir/projects/scoped-proj"
cp "$repo_root/tools/validate-agent-directory.sh" "$repo_root/tools/task.sh" \
  "$changed_fixture_dir/tools/"
cp "$repo_root/tools/TOOLS.md" "$changed_fixture_dir/tools/"
cp "$repo_root/tools/lib/project-registry.sh" "$changed_fixture_dir/tools/lib/"
cp "$repo_root/tools/validator/check-markdown-references.sh" "$changed_fixture_dir/tools/validator/"
printf '# Scoped validation fixture\n' > "$changed_fixture_dir/README.md"
{
  printf '%s\n' '---' 'name: scoped-proj' 'description: scoped validation fixture' \
    'status: active' 'mode: finite' '---' '' '> Scoped validation fixture goal.' '' \
    '## 目的' '## 判断原則' '## 非ゴール' '## 制約・固定決定' '## 品質基準' '## 入力' \
    '## 使用するKnowledge' '' '### Required' '' '### Conditional' '' \
    '## 使用するSkill' '' '### Required' '' '### Conditional' '' \
    '## 成果物' '## 検証方法' '## 最終ゴール' '## 完了条件' '' '- **PC-01** fixture criterion.'
} > "$changed_fixture_dir/projects/scoped-proj/PROJECT.md"
{
  printf '%s\n' '---' 'updated_at: 2026-08-06' '---' '' '## 現在の到達点' '## 現在の目標' '' \
    '対象契約: `PROJECT.md#PC-01`' '' '## 目標の合格条件' '## 検証結果' '' \
    '- 対象: `PROJECT.md#PC-01`' '' '## 未完了・ブロッカー' '## 現在有効な決定' \
    '## 失敗・却下済み' '## 次の一手'
} > "$changed_fixture_dir/projects/scoped-proj/STATE.md"
env "${changed_env[@]}" git -C "$changed_fixture_dir" init -q
env "${changed_env[@]}" git -C "$changed_fixture_dir" add -A
env "${changed_env[@]}" git -C "$changed_fixture_dir" commit -q -m 'fixture: scoped baseline'
printf '%s\n' '' '<!-- scoped fixture edit -->' >> "$changed_fixture_dir/projects/scoped-proj/STATE.md"
set +e
changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
changed_status=$?
set -e
if (( changed_status != 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'scoped validation (--changed)'; then
  fail "validator --changed did not run a scoped pass on a project-only change: $(printf '%s' "$changed_output" | head -n 3 | tr '\n' ' ')"
fi
set +e
task_verify_output="$(env "${changed_env[@]}" AGENT_DIRECTORY_ROOT="$changed_fixture_dir" \
  bash "$changed_fixture_dir/tools/task.sh" verify 2>&1)"
task_verify_status=$?
set -e
if (( task_verify_status != 0 )) || \
  ! printf '%s\n' "$task_verify_output" | grep -Fq 'scoped validation (--changed)' || \
  ! printf '%s\n' "$task_verify_output" | grep -Fqx 'TASK_OK action=verify scope=changed'; then
  fail "task facade fixture: verify did not enter the normal --changed path: $(printf '%s' "$task_verify_output" | head -n 3 | tr '\n' ' ')"
fi

# --changed immutability boundary: with no explicit --base, the uncommitted work is
# judged against HEAD, so edits/deletions of immutable source material and closed
# logs are refused while plain additions pass, and a deleted wiki page never slips
# through as normal work.
changed_run() {
  set +e
  changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
  changed_status=$?
  set -e
}
mkdir -p "$changed_fixture_dir/knowledge/raw/internal" \
  "$changed_fixture_dir/knowledge/wiki/topics" "$changed_fixture_dir/knowledge/wiki/logs"
printf 'immutable record\n' > "$changed_fixture_dir/knowledge/raw/internal/record.txt"
printf -- '---\nsummary: scoped page\nstatus: active\naliases: []\n---\n\nscoped page body\n' \
  > "$changed_fixture_dir/knowledge/wiki/topics/scoped-page.md"
printf '# 2026-Q1 closed log\n' > "$changed_fixture_dir/knowledge/wiki/logs/2026-Q1.md"
env "${changed_env[@]}" git -C "$changed_fixture_dir" add -A
env "${changed_env[@]}" git -C "$changed_fixture_dir" commit -q -m 'fixture: knowledge baseline'

printf 'tamper\n' >> "$changed_fixture_dir/knowledge/raw/internal/record.txt"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'immutable source changed'; then
  fail 'validator --changed accepted an edit of immutable source material without --base'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/raw/internal/record.txt

printf 'new record\n' > "$changed_fixture_dir/knowledge/raw/internal/new-record.txt"
env "${changed_env[@]}" git -C "$changed_fixture_dir" add knowledge/raw/internal/new-record.txt
changed_run
if (( changed_status != 0 )); then
  fail "validator --changed refused a plain addition of immutable source material: $(printf '%s' "$changed_output" | head -n 2 | tr '\n' ' ')"
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" reset -q HEAD -- knowledge/raw/internal/new-record.txt
rm -f "$changed_fixture_dir/knowledge/raw/internal/new-record.txt"

printf 'tamper\n' >> "$changed_fixture_dir/knowledge/wiki/logs/2026-Q1.md"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'closed Knowledge log changed'; then
  fail 'validator --changed accepted an edit of a closed Knowledge log without --base'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/wiki/logs/2026-Q1.md

rm -f "$changed_fixture_dir/knowledge/wiki/topics/scoped-page.md"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'deletion contract'; then
  fail 'validator --changed silently passed a deleted Knowledge page'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/wiki/topics/scoped-page.md

# The fallback static run does not perform --full's whole-tree reference scan, so a
# changed meta-canon Markdown file must still have its outgoing references checked.
printf '\nBroken reference: `tools/TOOLS.md#no-such-heading`\n' >> "$changed_fixture_dir/README.md"
changed_run
if (( changed_status == 0 )) || \
  ! printf '%s\n' "$changed_output" | grep -Fq \
    'README.md reference does not resolve: tools/TOOLS.md#no-such-heading'; then
  fail 'validator --changed skipped outgoing Markdown references on the meta-canon fallback path'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- README.md

printf '# scoped fixture meta edit\n' >> "$changed_fixture_dir/tools/validate-agent-directory.sh"
set +e
changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
changed_status=$?
set -e
if (( changed_status == 0 )) || \
  ! printf '%s\n' "$changed_output" | grep -Fq 'running the full static validation'; then
  fail 'validator --changed did not fall back to the full static run when the changed set reached meta canon'
fi
set +e
task_verify_output="$(env "${changed_env[@]}" AGENT_DIRECTORY_ROOT="$changed_fixture_dir" \
  bash "$changed_fixture_dir/tools/task.sh" verify 2>&1)"
task_verify_status=$?
set -e
if (( task_verify_status == 0 )) || \
  ! printf '%s\n' "$task_verify_output" | grep -Fq 'running the full static validation' || \
  ! printf '%s\n' "$task_verify_output" | grep -Fqx 'TASK_FAILED action=verify reason=validation-failed'; then
  fail 'task facade fixture: verify bypassed the validator meta fallback'
fi

# prepare-context.sh maps the agent-decided class deterministically: --class is
# mandatory (never an implicit work), and meta read maps to no validation and no backup.
set +e
prepare_probe_output="$(bash "$repo_root/tools/prepare-context.sh" --route meta --target tools/TOOLS.md 2>/dev/null)"
prepare_probe_status=$?
set -e
if (( prepare_probe_status != 2 )); then
  fail 'prepare-context.sh must reject a missing --class instead of assuming an implicit work'
fi
set +e
prepare_probe_output="$(bash "$repo_root/tools/prepare-context.sh" --route meta --target tools/TOOLS.md --class read 2>/dev/null)"
prepare_probe_status=$?
set -e
if (( prepare_probe_status != 0 )) || \
  ! printf '%s\n' "$prepare_probe_output" | grep -Fqx 'validation_profile=none' || \
  ! printf '%s\n' "$prepare_probe_output" | grep -Fqx 'backup_profile=none'; then
  fail 'prepare-context.sh --class read must map meta read to validation none and backup none'
fi

# finalize-task.sh is the deterministic work/state terminal: read has nothing to finalize,
# boundary stays on the manual CONTROL.md path, and a call arriving with an escalation ack
# preset is refused before any Git state is touched (each probe exits pre-side-effect).
set +e
finalize_probe_output="$(bash "$repo_root/tools/finalize-task.sh" --route knowledge --class read --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=usage'; then
  fail 'finalize-task.sh must reject class read (nothing to finalize)'
fi
set +e
finalize_probe_output="$(bash "$repo_root/tools/finalize-task.sh" --route meta --class boundary --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=boundary-class'; then
  fail 'finalize-task.sh must send class boundary to the manual CONTROL.md path'
fi
set +e
finalize_probe_output="$(AGENT_GUARDED_COMMIT=true bash "$repo_root/tools/finalize-task.sh" --route knowledge --class work --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=ack-env-set'; then
  fail 'finalize-task.sh must refuse a call arriving with an escalation ack preset'
fi

# task.sh keeps compatibility implementation details behind the facade and refuses bad
# input/protected completion before commit or backup. The isolated Git fixture gives backup
# a sentinel stub so any accidental external-effect path is deterministic and observable.
task_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-task.XXXXXX")"
cleanup_paths+=("$task_fixture_dir")
mkdir -p "$task_fixture_dir/tools/lib"
cp "$repo_root/tools/task.sh" "$repo_root/tools/prepare-context.sh" \
  "$repo_root/tools/finalize-task.sh" "$repo_root/tools/check-boundary.sh" \
  "$repo_root/tools/control-policy.tsv" "$task_fixture_dir/tools/"
cp "$repo_root/tools/lib/project-registry.sh" "$task_fixture_dir/tools/lib/"
{
  printf '#!/bin/bash\n'
  printf 'touch "$AGENT_DIRECTORY_ROOT/validator-called"\n'
  printf 'exit 0\n'
} > "$task_fixture_dir/tools/validate-agent-directory.sh"
{
  printf '#!/bin/bash\n'
  printf 'touch "$AGENT_DIRECTORY_ROOT/backup-called"\n'
  printf 'printf "%%s\\n" "$*" > "$AGENT_DIRECTORY_ROOT/backup-args"\n'
  printf 'printf "ROOT_BACKUP_OK remote=backup branch=main sha=%%s scope=root-only\\n" "$(git -C "$AGENT_DIRECTORY_ROOT" rev-parse HEAD)"\n'
  printf 'exit 0\n'
} > "$task_fixture_dir/tools/backup-to-github.sh"
chmod 755 "$task_fixture_dir/tools/"*.sh
printf '# fixture agent\n' > "$task_fixture_dir/AGENTS.md"
printf '# fixture tools\n' > "$task_fixture_dir/tools/TOOLS.md"
printf '# fixture safety\n' > "$task_fixture_dir/tools/SAFETY.md"
task_fixture_env=(
  HOME="$task_fixture_dir/home" GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  AGENT_DIRECTORY_ROOT="$task_fixture_dir"
)
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" init -q
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" add -A
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" commit -q -m 'fixture: task baseline'
task_fixture_head="$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)"

set +e
task_context_output="$(env "${task_fixture_env[@]}" \
  bash "$task_fixture_dir/tools/task.sh" context --route meta --target tools/SAFETY.md 2>&1)"
task_context_status=$?
set -e
if (( task_context_status != 0 )) || \
  ! printf '%s\n' "$task_context_output" | grep -Fqx 'TASK_CONTEXT v2' || \
  printf '%s\n' "$task_context_output" | grep -Eq '^(task_class|validation_profile|backup_profile)='; then
  fail "task facade fixture: context leaked compatibility fields or failed: $task_context_output"
fi

printf 'protected edit\n' >> "$task_fixture_dir/tools/SAFETY.md"
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" add tools/SAFETY.md
set +e
task_finish_output="$(env "${task_fixture_env[@]}" \
  bash "$task_fixture_dir/tools/task.sh" finish --route meta --target tools/SAFETY.md \
  --message 'fixture: protected finish' 2>&1)"
task_finish_status=$?
set -e
if (( task_finish_status == 0 )) || \
  ! printf '%s\n' "$task_finish_output" | grep -Fqx \
    'TASK_BLOCKED action=finish reason=protected-change'; then
  fail "task facade fixture: protected finish was not normalized: $task_finish_output"
fi
[[ "$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)" == \
  "$task_fixture_head" ]] || fail 'task facade fixture: protected finish created a commit'
[[ ! -e "$task_fixture_dir/validator-called" ]] || \
  fail 'task facade fixture: protected finish ran validation after its boundary refusal'
[[ ! -e "$task_fixture_dir/backup-called" ]] || \
  fail 'task facade fixture: protected finish called backup after its boundary refusal'
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" reset -q --hard >/dev/null

for task_bad_args in 'context --route invalid' \
  'context --route meta --target ../escape'; do
  set +e
  # shellcheck disable=SC2086 # fixture intentionally expands a fixed argument string
  task_bad_output="$(env "${task_fixture_env[@]}" \
    bash "$task_fixture_dir/tools/task.sh" $task_bad_args 2>&1)"
  task_bad_status=$?
  set -e
  (( task_bad_status != 0 )) || \
    fail "task facade fixture: invalid input succeeded: $task_bad_args"
done
[[ "$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)" == \
  "$task_fixture_head" ]] || fail 'task facade fixture: invalid input changed Git history'
[[ -z "$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" status --porcelain)" ]] || \
  fail 'task facade fixture: invalid input changed the worktree'
[[ ! -e "$task_fixture_dir/validator-called" && ! -e "$task_fixture_dir/backup-called" ]] || \
  fail 'task facade fixture: invalid input reached validation or backup'

# An explicit current-work finish must commit before it reaches backup, and it must reject
# any changed path outside the explicit target before validation, commit, or backup.
mkdir -p "$task_fixture_dir/deliverables"
printf 'current work\n' > "$task_fixture_dir/deliverables/result.txt"
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" add -- deliverables/result.txt
set +e
task_current_output="$(env "${task_fixture_env[@]}" \
  bash "$task_fixture_dir/tools/task.sh" finish --route meta --target deliverables \
  --message 'fixture: preserve current work' --current-work 2>&1)"
task_current_status=$?
set -e
task_current_head="$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)"
if (( task_current_status != 0 )) || \
  [[ "$task_current_head" == "$task_fixture_head" ]] || \
  ! printf '%s\n' "$task_current_output" | grep -Fqx 'TASK_OK action=finish' || \
  ! printf '%s\n' "$task_current_output" | grep -Fq \
    "ROOT_BACKUP_OK remote=backup branch=main sha=$task_current_head scope=root-only" || \
  ! grep -Fqx -- "--root-only --fixed-commit $task_current_head" "$task_fixture_dir/backup-args"; then
  fail "task facade fixture: explicit current work did not commit before backup: $task_current_output"
fi
rm -f "$task_fixture_dir/validator-called" "$task_fixture_dir/backup-called" \
  "$task_fixture_dir/backup-args"

printf 'next target work\n' >> "$task_fixture_dir/deliverables/result.txt"
task_unrelated_path=$'unrelated\nwork.txt'
printf 'unrelated work\n' > "$task_fixture_dir/$task_unrelated_path"
env "${task_fixture_env[@]}" git -C "$task_fixture_dir" add -- deliverables/result.txt
task_current_before="$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)"
set +e
task_current_output="$(env "${task_fixture_env[@]}" \
  bash "$task_fixture_dir/tools/task.sh" finish --route meta --target deliverables \
  --message 'fixture: reject unrelated work' --current-work 2>&1)"
task_current_status=$?
set -e
if (( task_current_status == 0 )) || \
  ! printf '%s\n' "$task_current_output" | grep -Fq 'FINALIZE_BLOCKED reason=unrelated-changes' || \
  [[ "$(env "${task_fixture_env[@]}" git -C "$task_fixture_dir" rev-parse HEAD)" != \
    "$task_current_before" ]] || \
  [[ -e "$task_fixture_dir/validator-called" || -e "$task_fixture_dir/backup-called" ]]; then
  fail "task facade fixture: explicit current work did not fail closed on unrelated changes: $task_current_output"
fi

# report-upstream-issue.sh anonymization derives block terms from the identity line of
# AGENTS.md#自己定義 (any heading depth) and is fail-closed on the number of checks that
# actually ran, not on the number of extracted tokens. The probes loop over every declared
# name (any sort position), any length and writing system, independent of the caller locale,
# and cover the --search mode. The probes stay on --dry-run, which never writes to the network.
upstream_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-upstream.XXXXXX")"
upstream_fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-upstream-cache.XXXXXX")"
cleanup_paths+=("$upstream_fixture_dir" "$upstream_fixture_cache_dir")
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは検査fixtureに特化した実行主体、`fixture-probe-agent`（`Fixture合同会社`／`Fixture Probe LLC`）。' \
    '- **運用者応対言語:** `English`。' \
    '- `<...>`は導入時に置換する。' '' \
    '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf 'privateなdownstream Workspaceの通常作業中に観測した。\n' > "$upstream_fixture_dir/body-clean.md"
printf 'The bootloader is written in English.\n' > "$upstream_fixture_dir/body-language.md"
upstream_probe() {
  set +e
  upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
    AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
    bash "$repo_root/tools/report-upstream-issue.sh" \
    --title '[bug] fixture probe' --body-file "$1" --dry-run 2>&1)"
  upstream_probe_status=$?
  set -e
}
# Every declared name must block, whatever its position in the sorted extraction (first,
# middle, and last are all probed so no single-name regression can pass unnoticed).
for upstream_probe_name in 'Fixture Probe LLC' 'Fixture合同会社' 'fixture-probe-agent'; do
  printf '%s の運用で観測した。\n' "$upstream_probe_name" > "$upstream_fixture_dir/body-name.md"
  upstream_probe "$upstream_fixture_dir/body-name.md"
  if (( upstream_probe_status == 0 )) || \
    ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
    fail 'report-upstream-issue.sh must check every declared self-definition name, whatever its sort position'
  fi
done
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )); then
  fail "report-upstream-issue.sh dry-run failed on an anonymized body: $(printf '%s' "$upstream_probe_output" | head -n 2 | tr '\n' ' ')"
fi
# Generic private-data classes must be blocked even when they differ from the
# current Git identity and do not use one of the historically enumerated token families.
printf 'contact=%s@%s\n' 'customer' 'public.test' > "$upstream_fixture_dir/body-email.md"
upstream_probe "$upstream_fixture_dir/body-email.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: email-address'; then
  fail 'report-upstream-issue.sh must block an unrelated email address without echoing it'
fi
printf '%s: session=%s\n' 'Cookie' 'fixture-cookie-value-123456' > \
  "$upstream_fixture_dir/body-cookie.md"
upstream_probe "$upstream_fixture_dir/body-cookie.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: cookie-material'; then
  fail 'report-upstream-issue.sh must block cookie material'
fi
printf 'provider_token=%s\n' 'fixture-provider-secret-value-123456' > \
  "$upstream_fixture_dir/body-secret-assignment.md"
upstream_probe "$upstream_fixture_dir/body-secret-assignment.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: secret-assignment'; then
  fail 'report-upstream-issue.sh must block non-enumerated secret assignments'
fi
# The operator interaction language is a contract value, not a proper noun: a body naming
# the language must pass even though the language sits backticked in the self-definition.
upstream_probe "$upstream_fixture_dir/body-language.md"
if (( upstream_probe_status != 0 )); then
  fail 'report-upstream-issue.sh must not treat the operator interaction language as an agent name'
fi
# A short CJK name is still a declared proper noun: no length guard, no locale dependence.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`甲乙丙`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf '甲乙丙 のworkspaceで観測した。\n' > "$upstream_fixture_dir/body-short-name.md"
set +e
upstream_probe_output="$(LANG=ja_JP.UTF-8 LC_ALL='' AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --title '[bug] fixture probe' --body-file "$upstream_fixture_dir/body-short-name.md" --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must block a 3-character declared name under a UTF-8 locale'
fi
# The section is found by heading text, not by heading depth.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## Agent' '' '### 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf 'fixture-probe-agent のworkspaceで観測した。\n' > "$upstream_fixture_dir/body-name.md"
upstream_probe "$upstream_fixture_dir/body-name.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must find the self-definition section at any heading depth'
fi
# Fail-closed distinctions: no backticked name on the identity line, placeholders only,
# and a missing section each block instead of silently skipping the agent-name rule.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは名を名乗らない散文だけの実行主体。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when no backticked name is extractable from AGENTS.md#自己定義'
fi
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`<agent-name>`（役割:`<agent-role>`）。' \
    '- `<...>`は導入時に置換する。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when every identity-line token is a template placeholder'
fi
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 挨拶' '' '- 自己定義の見出しを持たない。'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when AGENTS.md has no 自己定義 section'
fi
# --search goes through the same anonymization inspection and honors --dry-run.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
set +e
upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --search 'fixture-probe-agent bootloader' --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must run the anonymization inspection on --search terms'
fi
set +e
upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --search 'bootloader routing budget' --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'UPSTREAM_REPORT_SEARCH_DRY_RUN_OK'; then
  fail 'report-upstream-issue.sh --search must support --dry-run for clean terms'
fi
# Public negative examples must remain unmistakably synthetic instead of preserving
# private downstream identifiers in tracked policy and eval content.
grep -Fq 'NG: ExampleCorpのexample-projectで、YouTube投稿処理中に発生した' \
  "$repo_root/tools/UPSTREAM.md" || \
  fail 'tools/UPSTREAM.md privacy example must use reserved synthetic identifiers'
grep -Fq '/Users/example-user/agents/example-project' \
  "$repo_root/evals/cases/upstream-issue-privacy.yaml" || \
  fail 'upstream privacy eval must use an explicitly synthetic local path'
# Upstream revision resolution: a verified declared adoption wins over merge-base, an
# unverifiable declared sha is never published, an unfetched template remote is not
# misdiagnosed as unrelated history, and every resolution carries resolved-from.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_fixture_git() {
  env -i PATH="$PATH" HOME="$upstream_fixture_dir" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$upstream_fixture_dir" "$@"
}
upstream_fixture_git init -q
upstream_fixture_git -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -q --allow-empty -m 'fixture adoption commit'
upstream_fixture_sha="$(upstream_fixture_git rev-parse HEAD)"
upstream_fixture_sha_upper="$(printf '%s' "$upstream_fixture_sha" | tr '[:lower:]' '[:upper:]')"
# 1. A declared sha that git accepts (uppercase form) is verified and normalized.
upstream_fixture_git config agent-directory.upstream-revision "$upstream_fixture_sha_upper"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq "$upstream_fixture_sha (resolved-from: declared)"; then
  fail 'report-upstream-issue.sh must verify and normalize a declared adoption revision (uppercase sha included)'
fi
# 2. A declared sha that resolves to no commit is never published.
upstream_fixture_git config agent-directory.upstream-revision deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  printf '%s\n' "$upstream_probe_output" | grep -Fq 'resolved-from: declared' || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'unknown (no-template-remote)'; then
  fail 'report-upstream-issue.sh must not publish an unverifiable declared revision'
fi
# 3. An unfetched template remote is template-not-fetched, not unrelated-history.
upstream_fixture_git remote add template /nonexistent-template-remote.git
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'unknown (template-not-fetched)' || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'git fetch template'; then
  fail 'report-upstream-issue.sh must diagnose an unfetched template remote as template-not-fetched'
fi
# 4. A fetched ref that shares no history is unrelated-history.
upstream_fixture_git config --unset agent-directory.upstream-revision
upstream_fixture_orphan="$(upstream_fixture_git mktree </dev/null)"
upstream_fixture_orphan="$(upstream_fixture_git -c user.name=fixture -c user.email=fixture@example.invalid \
  commit-tree "$upstream_fixture_orphan" -m 'unrelated root' </dev/null)"
upstream_fixture_git update-ref refs/remotes/template/main "$upstream_fixture_orphan"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'unknown (unrelated-history)'; then
  fail 'report-upstream-issue.sh must diagnose a fetched ref sharing no history as unrelated-history'
fi
# 5. merge-base is a labeled diagnostic, and a verified declaration wins over it.
upstream_fixture_git update-ref refs/remotes/template/main "$upstream_fixture_sha"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq "$upstream_fixture_sha (resolved-from: merge-base)"; then
  fail 'report-upstream-issue.sh must label a merge-base resolution with resolved-from: merge-base'
fi
upstream_fixture_git -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -q --allow-empty -m 'fixture ported upstream change'
upstream_fixture_adopted="$(upstream_fixture_git rev-parse HEAD)"
upstream_fixture_git config agent-directory.upstream-revision "$upstream_fixture_adopted"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq "$upstream_fixture_adopted (resolved-from: declared)"; then
  fail 'report-upstream-issue.sh must prefer a verified declared adoption over the merge-base ancestor'
fi

# A canon file lacking frontmatter must not stop cache generation; warn naming the target and drop it from the candidates.
mkdir -p "$malformed_fixture_dir/projects/good-project" \
  "$malformed_fixture_dir/projects/no-status" \
  "$malformed_fixture_dir/skills/blank-status-skill" \
  "$malformed_fixture_dir/knowledge/wiki/topics"
{
  printf '%s\n' '---' 'name: good-project' 'description: fixture' 'status: active'
  printf '%s\n' 'mode: finite' '---'
} > "$malformed_fixture_dir/projects/good-project/PROJECT.md"
{
  printf '%s\n' '---' 'name: no-status' 'description: fixture' '---'
} > "$malformed_fixture_dir/projects/no-status/PROJECT.md"
{
  printf '%s\n' '---' 'name: blank-status-skill' 'description: fixture' 'status:' '---'
} > "$malformed_fixture_dir/skills/blank-status-skill/SKILL.md"
{
  printf '%s\n' '---' 'summary: fixture' 'aliases: []' '---'
} > "$malformed_fixture_dir/knowledge/wiki/topics/no-status.md"

set +e
malformed_output="$(AGENT_DIRECTORY_ROOT="$malformed_fixture_dir" AGENT_CACHE_DIR="$malformed_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" 2>&1)"
malformed_status=$?
set -e
if (( malformed_status != 0 )); then
  fail "build-context-cache.sh aborted on a malformed canon file instead of warning and skipping: $malformed_output"
else
  for malformed_target in \
    'projects/no-status/PROJECT.md' \
    'skills/blank-status-skill/SKILL.md' \
    'knowledge/wiki/topics/no-status.md'; do
    printf '%s\n' "$malformed_output" | grep -Eq "^WARN: $malformed_target: missing .*status" || \
      fail "build-context-cache.sh did not name $malformed_target and its missing key in a WARN line"
    if [[ -f "$malformed_cache_dir/catalog.tsv" ]] && \
      grep -Fq "$malformed_target" "$malformed_cache_dir/catalog.tsv"; then
      fail "build-context-cache.sh registered the malformed canon file in the catalog: $malformed_target"
    fi
  done
  if printf '%s\n' "$malformed_output" | grep -Eq '^WARN: knowledge/wiki/topics/no-status\.md: missing name'; then
    fail 'build-context-cache.sh reported a missing name for a knowledge page whose name comes from the filename'
  fi
  if [[ ! -f "$malformed_cache_dir/catalog.tsv" ]] || \
    ! grep -Fq 'projects/good-project/PROJECT.md' "$malformed_cache_dir/catalog.tsv"; then
    fail 'build-context-cache.sh dropped a well-formed canon file while skipping malformed ones'
  fi
fi
if [[ -f "$cache_test_dir/catalog.tsv" ]]; then
  alias_collisions="$(awk -F '\t' '
    NR == 1 || $3 != "active" || ($1 != "knowledge" && $1 != "skill") { next }
    {
      owner = $8
      key = $1 SUBSEP tolower($4)
      if (seen[key] != "" && seen[key] != owner) print $1 ":" tolower($4)
      seen[key] = owner
      count = split(tolower($5), alias, "|")
      for (i = 1; i <= count; i++) {
        if (alias[i] == "") continue
        key = $1 SUBSEP alias[i]
        if (seen[key] != "" && seen[key] != owner) print $1 ":" alias[i]
        seen[key] = owner
      }
    }
  ' "$cache_test_dir/catalog.tsv" | LC_ALL=C sort -u)"
  [[ -z "$alias_collisions" ]] || fail "active alias collision(s): $alias_collisions"
fi

# Public foundations keep Git/revision/materialization guarantees without carrying the
# Owner Agent's PROJECT.md/STATE.md. Exercise the real materializer and context router so
# this exception cannot silently become an unverified documentation-only branch.
if [[ -f "$materialize_tool" ]] && command -v git >/dev/null 2>&1; then
  foundation_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-foundation-fixture.XXXXXX")"
  cleanup_paths+=("$foundation_fixture_dir")
  foundation_root="$foundation_fixture_dir/workspace"
  foundation_seed="$foundation_fixture_dir/seed"
  foundation_remote="$foundation_fixture_dir/foundation.git"
  foundation_env=(
    HOME="$foundation_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
    AGENT_ALLOW_LOCAL_REPOSITORY_URL=true
  )
  env "${foundation_env[@]}" git init -q --bare "$foundation_remote"
  env "${foundation_env[@]}" git -C "$foundation_remote" symbolic-ref HEAD refs/heads/main
  env "${foundation_env[@]}" git init -q "$foundation_seed"
  env "${foundation_env[@]}" git -C "$foundation_seed" symbolic-ref HEAD refs/heads/main
  printf '%s\n' '# Public foundation fixture' > "$foundation_seed/README.md"
  printf '%s\n' '# Repository-local rules' > "$foundation_seed/AGENTS.md"
  env "${foundation_env[@]}" git -C "$foundation_seed" add README.md AGENTS.md
  env "${foundation_env[@]}" git -C "$foundation_seed" commit -q -m 'fixture: public foundation'
  env "${foundation_env[@]}" git -C "$foundation_seed" remote add origin "$foundation_remote"
  env "${foundation_env[@]}" git -C "$foundation_seed" push -q origin main
  foundation_revision="$(env "${foundation_env[@]}" git -C "$foundation_seed" rev-parse HEAD)"

  env "${foundation_env[@]}" git init -q "$foundation_root"
  mkdir -p "$foundation_root/tools/lib" "$foundation_root/projects"
  printf '%s\n' '# Owner Agent' > "$foundation_root/AGENTS.md"
  printf '%s\n' '# Owner active state' > "$foundation_root/STATE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$foundation_root/tools/validate-agent-directory.sh"
  cp "$repo_root/tools/lib/project-registry.sh" "$foundation_root/tools/lib/"
  cp "$repo_root/tools/lib/agent-env.sh" "$foundation_root/tools/lib/"
  cp "$repo_root/tools/lib/github-auth.sh" "$foundation_root/tools/lib/"
  cp "$repo_root/tools/materialize-project-repositories.sh" "$foundation_root/tools/"
  cp "$repo_root/tools/prepare-context.sh" "$foundation_root/tools/"
  cp "$repo_root/tools/build-context-cache.sh" "$foundation_root/tools/"
  {
    printf '%s\n' '# REPOSITORIES — Independent Repository Registry' '' '## `foundation-product`' ''
    printf -- '- repository_url: `%s`\n' "$foundation_remote"
    printf '%s\n' '- repository_reason: `distribution`'
    printf -- '- revision: `%s`\n' "$foundation_revision"
    printf '%s\n' '- repository_role: `public-foundation`'
  } > "$foundation_root/projects/REPOSITORIES.md"
  printf '%s\n' '# Derived from projects/REPOSITORIES.md.' '# BEGIN INDEPENDENT PROJECTS' \
    '/foundation-product/' '# END INDEPENDENT PROJECTS' > "$foundation_root/projects/.gitignore"
  env "${foundation_env[@]}" git -C "$foundation_root" add -A
  env "${foundation_env[@]}" git -C "$foundation_root" commit -q -m 'fixture: owner registry'

  foundation_materialize_output="$(env "${foundation_env[@]}" AGENT_DIRECTORY_ROOT="$foundation_root" \
    bash "$foundation_root/tools/materialize-project-repositories.sh" --all 2>&1)" || \
    fail "public foundation fixture: materializer required owner-state contracts: $foundation_materialize_output"
  printf '%s\n' "$foundation_materialize_output" | \
    grep -Fqx 'MATERIALIZATION_OK total=1 cloned=1 verified=0' || \
    fail "public foundation fixture: unexpected materializer result: $foundation_materialize_output"
  [[ ! -e "$foundation_root/projects/foundation-product/PROJECT.md" && \
    ! -e "$foundation_root/projects/foundation-product/STATE.md" ]] || \
    fail 'public foundation fixture: materialization introduced Owner Agent state contracts into the product repository'

  foundation_cache="$foundation_fixture_dir/cache"
  foundation_cache_output="$(env "${foundation_env[@]}" AGENT_DIRECTORY_ROOT="$foundation_root" \
    AGENT_CACHE_DIR="$foundation_cache" bash "$foundation_root/tools/build-context-cache.sh" 2>&1)" || \
    fail "public foundation fixture: context cache generation failed: $foundation_cache_output"
  if [[ -f "$foundation_cache/catalog.tsv" ]] && \
    grep -Fq 'projects/foundation-product/PROJECT.md' "$foundation_cache/catalog.tsv"; then
    fail 'public foundation fixture: Owner Agent state-free product entered the general Project search catalog'
  fi

  foundation_context_output="$(env "${foundation_env[@]}" AGENT_DIRECTORY_ROOT="$foundation_root" \
    bash "$foundation_root/tools/prepare-context.sh" --route meta \
      --target projects/foundation-product --class work 2>&1)" || \
    fail "public foundation fixture: meta Route failed: $foundation_context_output"
  for expected_context_line in \
    'route=meta' 'git_root=projects/foundation-product' 'repository_owner=independent' \
    'repository_role=public-foundation' 'STATE.md' 'projects/foundation-product/AGENTS.md' \
    'projects/foundation-product/README.md'; do
    printf '%s\n' "$foundation_context_output" | grep -Fqx "$expected_context_line" || \
      fail "public foundation fixture: context omitted $expected_context_line"
  done
  if env "${foundation_env[@]}" AGENT_DIRECTORY_ROOT="$foundation_root" \
    bash "$foundation_root/tools/prepare-context.sh" --route project \
      --target projects/foundation-product --class work >/dev/null 2>&1; then
    fail 'public foundation fixture: Project Route accepted a public foundation without Project state contracts'
  fi
fi

if [[ -f "$backup_tool" ]] && command -v git >/dev/null 2>&1; then
  backup_work="$backup_fixture_dir/work"
  backup_remote_dir="$backup_fixture_dir/remote.git"
  backup_peer="$backup_fixture_dir/peer"
  independent_seed="$backup_fixture_dir/independent-seed"
  independent_remote_dir="$backup_fixture_dir/independent.git"
  independent_clone="$backup_work/projects/data-pipeline"
  independent_cache_dir="$backup_fixture_dir/independent-cache"
  fixture_registry="$backup_work/projects/REPOSITORIES.md"
  fixture_ignore="$backup_work/projects/.gitignore"
  backup_env=(
    HOME="$backup_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
    AGENT_ALLOW_LOCAL_REPOSITORY_URL=true
  )
  backup_output=''
  backup_status=0

  backup_git() { env "${backup_env[@]}" git -C "$backup_work" "$@"; }
  child_git() { env "${backup_env[@]}" git -C "$independent_clone" "$@"; }
  seed_git() { env "${backup_env[@]}" git -C "$independent_seed" "$@"; }
  backup_run() {
    set +e
    backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" "$@" 2>&1)"
    backup_status=$?
    set -e
  }
  materialize_run() {
    set +e
    backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" \
      bash "$materialize_tool" "$@" 2>&1)"
    backup_status=$?
    set -e
  }
  build_fixture_cache() {
    set +e
    env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" AGENT_CACHE_DIR="$independent_cache_dir" \
      bash "$repo_root/tools/build-context-cache.sh" >/dev/null 2>&1
    backup_status=$?
    set -e
  }
  fixture_fingerprint() {
    sed -n 's/^content_fingerprint=//p' "$independent_cache_dir/cache.meta" | head -n 1
  }
  fixture_catalog_field() {
    awk -F '\t' -v path="$1" -v column="$2" '$8 == path { print $column; exit }' \
      "$independent_cache_dir/catalog.tsv"
  }
  backup_expect_blocked() {
    if (( backup_status == 0 )); then
      fail "backup fixture: $2 unexpectedly succeeded"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "BACKUP_BLOCKED reason=$1"; then
      fail "backup fixture: $2 did not report reason=$1: $(printf '%s' "$backup_output" | head -n 2 | tr '\n' ' ')"
    fi
  }
  backup_expect_line() {
    if (( backup_status != 0 )); then
      fail "backup fixture: $2 failed: $backup_output"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "$1"; then
      fail "backup fixture: $2 did not emit: $1"
    fi
  }
  materialize_expect_blocked() {
    if (( backup_status == 0 )); then
      fail "materializer fixture: $3 unexpectedly succeeded"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "MATERIALIZATION_BLOCKED reason=$1 project=$2"; then
      fail "materializer fixture: $3 did not report reason=$1: $(printf '%s' "$backup_output" | head -n 2 | tr '\n' ' ')"
    fi
  }
  materialize_expect_line() {
    if (( backup_status != 0 )); then
      fail "materializer fixture: $2 failed: $backup_output"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "$1"; then
      fail "materializer fixture: $2 did not emit: $1"
    fi
  }
  backup_remote_sha() {
    env "${backup_env[@]}" git -C "$backup_remote_dir" rev-parse --verify --quiet refs/heads/main || true
  }
  independent_remote_sha() {
    env "${backup_env[@]}" git -C "$independent_remote_dir" rev-parse --verify --quiet refs/heads/main || true
  }
  write_registry() {
    {
      printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
      printf '%s\n' 'Independent Projectのattachmentと復旧情報だけを持つ。' ''
      printf '%s\n' '## `data-pipeline`' ''
      printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
      printf -- '- repository_reason: `%s`\n' "${2:-automation}"
      printf -- '- revision: `%s`\n' "$1"
    } > "$fixture_registry"
  }
  write_ignore_projection() {
    {
      printf '%s\n' '# Derived from projects/REPOSITORIES.md.' '# BEGIN INDEPENDENT PROJECTS'
      while (( $# > 0 )); do printf '/%s/\n' "$1"; shift; done
      printf '%s\n' '# END INDEPENDENT PROJECTS'
    } > "$fixture_ignore"
  }
  adopt_revision() {
    write_registry "$1"
    backup_git add projects/REPOSITORIES.md
    backup_git commit -q -m 'fixture: adopt revision'
  }

  env "${backup_env[@]}" git init -q --bare "$backup_remote_dir"
  env "${backup_env[@]}" git -C "$backup_remote_dir" symbolic-ref HEAD refs/heads/main
  env "${backup_env[@]}" git init -q --bare "$independent_remote_dir"
  env "${backup_env[@]}" git -C "$independent_remote_dir" symbolic-ref HEAD refs/heads/main
  # Allow fetch by SHA for the negative case adopting a commit unreachable from any branch or tag.
  env "${backup_env[@]}" git -C "$independent_remote_dir" config uploadpack.allowAnySHA1InWant true

  # The Independent Project's PROJECT.md and STATE.md are owned by the child Git.
  env "${backup_env[@]}" git init -q "$independent_seed"
  seed_git symbolic-ref HEAD refs/heads/main
  printf 'verified independent revision\n' > "$independent_seed/source.txt"
  {
    printf '%s\n' '---' 'name: data-pipeline' 'description: fixture contract owned by the child Git'
    printf '%s\n' 'status: active' 'mode: continuous' '---'
  } > "$independent_seed/PROJECT.md"
  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State'
  } > "$independent_seed/STATE.md"
  seed_git add source.txt PROJECT.md STATE.md
  seed_git commit -q -m 'fixture: independent revision'
  seed_git remote add origin "$independent_remote_dir"
  seed_git push -q origin main
  independent_revision="$(seed_git rev-parse HEAD)"

  env "${backup_env[@]}" git init -q "$backup_work"
  backup_git symbolic-ref HEAD refs/heads/main
  mkdir -p "$backup_work/tools/lib" "$backup_work/projects"
  printf 'fixture agent directory\n' > "$backup_work/AGENTS.md"
  printf '.tmp/\n.agent-cache/\n.env*\n!.env.example\n.DS_Store\nignored-dir/\n' \
    > "$backup_work/.gitignore"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$backup_work/tools/validate-agent-directory.sh"
  cp "$backup_tool" "$backup_work/tools/backup-to-github.sh"
  cp "$repo_root/tools/lib/project-registry.sh" "$repo_root/tools/lib/agent-env.sh" \
    "$repo_root/tools/lib/github-auth.sh" \
    "$backup_work/tools/lib/"
  # An Embedded Project is tracked wholesale by the root Git and never enters the ignore projection.
  mkdir -p "$backup_work/projects/embedded-project"
  {
    printf '%s\n' '---' 'name: embedded-project' 'description: fixture embedded project'
    printf '%s\n' 'status: active' 'mode: finite' '---'
  } > "$backup_work/projects/embedded-project/PROJECT.md"
  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State'
  } > "$backup_work/projects/embedded-project/STATE.md"
  # First confirm everything holds even with an empty registry.
  printf '%s\n' '# REPOSITORIES — Independent Repository Registry' > "$fixture_registry"
  write_ignore_projection
  backup_git add -A
  backup_git commit -q -m 'fixture: empty registry'
  backup_git remote add backup "$backup_remote_dir"
  backup_run --root-only --dry-run
  backup_expect_line \
    "ROOT_BACKUP_READY remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'root-only dry run on an empty registry'
  materialize_run --all
  materialize_expect_line 'MATERIALIZATION_OK total=0 cloned=0 verified=0' 'an empty registry'

  # Checkpoint and incremental object audit: a verified backup records the remote-confirmed
  # SHA, the next success audits only the new range, and a missing or corrupt checkpoint
  # falls back to the full-history scan without weakening the oversized-object stop.
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'initial root-only backup'
  backup_checkpoint_file="$backup_work/.agent-cache/backup-checkpoint-backup-main"
  [[ -f "$backup_checkpoint_file" ]] || \
    fail 'backup fixture: no checkpoint was recorded after a remote-verified backup'
  grep -Fqx "sha=$(backup_git rev-parse HEAD)" "$backup_checkpoint_file" || \
    fail 'backup fixture: the checkpoint does not record the remote-verified SHA'
  if grep -Eq '^url=' "$backup_checkpoint_file" || \
    grep -Fq "$backup_remote_dir" "$backup_checkpoint_file"; then
    fail 'backup fixture: the checkpoint stores the remote URL in the clear instead of a hash'
  fi
  grep -Eq '^url_hash=' "$backup_checkpoint_file" || \
    fail 'backup fixture: the checkpoint does not record a deterministic URL hash'
  printf '%02048d' 0 > "$backup_work/pre-checkpoint-blob.txt"
  backup_git add pre-checkpoint-blob.txt
  backup_git commit -q -m 'fixture: blob below the default limit'
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'incremental root-only backup'
  printf '%s\n' "$backup_output" | grep -Fq 'incremental object audit' || \
    fail 'backup fixture: the second backup did not use the incremental object audit'
  # With a verified checkpoint, a lowered fixture-only limit ignores already-backed-up history.
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_BACKUP_MAX_BLOB_BYTES=1024 \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" --root-only 2>&1)"
  backup_status=$?
  set -e
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'checkpointed backup rescanning no already-verified history'
  # Without the checkpoint the same limit audits full history and stops on the old blob.
  rm -f "$backup_checkpoint_file"
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_BACKUP_MAX_BLOB_BYTES=1024 \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" --root-only 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'oversized-git-object' 'full-history fallback after a missing checkpoint'
  # A corrupt checkpoint also falls back safely and is rewritten by the next success.
  printf 'garbage\n' > "$backup_checkpoint_file"
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'backup after a corrupt checkpoint'
  grep -Fqx "sha=$(backup_git rev-parse HEAD)" "$backup_checkpoint_file" || \
    fail 'backup fixture: a successful backup did not rewrite the corrupt checkpoint'

  write_registry "$independent_revision"
  write_ignore_projection data-pipeline
  backup_git add -A
  backup_git commit -q -m 'fixture: register the Independent Project'
  backup_head="$(backup_git rev-parse HEAD)"

  # --- Unmaterialized state-------------------------------------------------------
  backup_run --dry-run
  backup_expect_blocked 'missing-independent-repository' 'workspace backup before materialization'
  materialize_run --all --check
  materialize_expect_blocked 'missing-independent-repository' 'data-pipeline' '--check on a missing clone'
  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only dry run while the Independent clone is missing'

  # --- materializer ------------------------------------------------------------
  materialize_run --all
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=1 verified=0' 'fresh clone at the Project root'
  [[ -d "$independent_clone/.git" && ! -L "$independent_clone/.git" ]] || \
    fail 'materializer fixture: projects/data-pipeline/.git is not a real directory'
  [[ "$(cd "$independent_clone" && env "${backup_env[@]}" git rev-parse --show-toplevel)" == \
    "$(cd "$independent_clone" && pwd -P)" ]] || \
    fail 'materializer fixture: the clone toplevel is not the Project root itself'
  [[ ! -e "$independent_clone/repository" ]] || \
    fail 'materializer fixture: a retired repository/ layer was created'
  [[ ! -e "$independent_clone/.gitmodules" ]] || \
    fail 'materializer fixture: the clone was materialized as a submodule'
  [[ -f "$independent_clone/PROJECT.md" && -f "$independent_clone/STATE.md" ]] || \
    fail 'materializer fixture: the adopted revision does not carry PROJECT.md and STATE.md'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'materializer fixture: HEAD is not the adopted revision'
  [[ -z "$(child_git symbolic-ref --quiet HEAD 2>/dev/null || true)" ]] || \
    fail 'materializer fixture: the adopted revision was not checked out detached'
  [[ -z "$(backup_git ls-files -- projects/data-pipeline)" ]] || \
    fail 'materializer fixture: the root index tracks the Independent Project root'
  materialize_run --all --check
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=0 verified=1' 'idempotent --check'

  # A newer remote tip must not silently advance the adopted revision.
  printf 'later work\n' > "$independent_seed/later.txt"
  seed_git add later.txt
  seed_git commit -q -m 'fixture: newer branch tip'
  seed_git push -q origin main
  independent_tip="$(seed_git rev-parse HEAD)"
  materialize_run --all --check
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=0 verified=1' '--check against a newer branch tip'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'materializer fixture: the clone was advanced to the branch tip instead of the adopted revision'

  # --- Healthy workspace backup----------------------------------------------------
  independent_remote_before="$(independent_remote_sha)"
  root_remote_before_dry_run="$(backup_remote_sha)"
  backup_run --dry-run
  backup_expect_line "WORKSPACE_BACKUP_READY remote=backup branch=main sha=$backup_head independent=1" \
    'workspace dry run on a materialized workspace'
  [[ "$(backup_remote_sha)" == "$root_remote_before_dry_run" ]] || \
    fail 'backup fixture: dry run wrote to the root remote'

  backup_run
  backup_expect_line "WORKSPACE_BACKUP_OK remote=backup branch=main sha=$backup_head independent=1" \
    'workspace backup on a materialized workspace'
  [[ "$(backup_remote_sha)" == "$backup_head" ]] || \
    fail 'backup fixture: the root remote does not match local HEAD after push'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the workspace backup pushed to the Independent remote'

  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only dry run'
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only backup'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the root-only backup pushed to the Independent remote'

  # The finish-only fixed mode audits the exact committed tree even when another target
  # leaves staged, unstaged, untracked, and stashed state behind. Every caller-side state
  # surface must remain byte-for-byte unchanged, and a SHA other than current HEAD must stop.
  printf 'fixed backup baseline\n' > "$backup_work/fixed-backup.txt"
  printf 'stash baseline\n' > "$backup_work/stash-source.txt"
  backup_git add fixed-backup.txt stash-source.txt
  backup_git commit -q -m 'fixture: verified commit for fixed backup'
  fixed_backup_head="$(backup_git rev-parse HEAD)"
  printf 'stashed caller work\n' >> "$backup_work/stash-source.txt"
  backup_git stash push -q
  printf 'unstaged caller work\n' >> "$backup_work/AGENTS.md"
  printf 'staged caller work\n' >> "$backup_work/fixed-backup.txt"
  backup_git add fixed-backup.txt
  printf 'untracked caller work\n' > "$backup_work/fixed-untracked.txt"
  fixed_status_before="$(backup_git status --porcelain=v1)"
  fixed_index_before="$(backup_git write-tree)"
  fixed_stash_before="$(backup_git rev-parse refs/stash)"

  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_BACKUP_FIXED_CHILD=true \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" --root-only 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'fixed-child-marker-invalid' \
    'an external fixed-child flag without a parent-created owner marker'

  backup_run --root-only --fixed-commit "$fixed_backup_head"
  backup_expect_line \
    "ROOT_BACKUP_OK remote=backup branch=main sha=$fixed_backup_head scope=root-only" \
    'finish-bound fixed commit with unrelated caller work'
  printf '%s\n' "$backup_output" | grep -Fq \
    'fixed commit credential owner: caller Agent root preserved without copying .env' || \
    fail 'backup fixture: fixed commit mode did not preserve the caller Agent credential root'
  [[ "$(backup_remote_sha)" == "$fixed_backup_head" ]] || \
    fail 'backup fixture: fixed commit mode did not push the requested HEAD commit'
  [[ "$(backup_git status --porcelain=v1)" == "$fixed_status_before" ]] || \
    fail 'backup fixture: fixed commit mode changed caller index, worktree, or untracked state'
  [[ "$(backup_git write-tree)" == "$fixed_index_before" ]] || \
    fail 'backup fixture: fixed commit mode changed the caller index tree'
  [[ "$(backup_git rev-parse refs/stash)" == "$fixed_stash_before" ]] || \
    fail 'backup fixture: fixed commit mode changed the caller stash'

  backup_run --root-only --fixed-commit "$(backup_git rev-parse HEAD~1)"
  backup_expect_blocked 'fixed-commit-mismatch' 'a fixed commit other than current branch HEAD'
  backup_git reset -q --hard "$fixed_backup_head"
  rm -f "$backup_work/fixed-untracked.txt"
  backup_git stash drop -q
  backup_head="$fixed_backup_head"

  # Move root HEAD deterministically inside the git push invocation, after the pre-push
  # audit check. The immutable source ref must send only A; the newly committed B was not
  # audited and must remain local. The local race has its own reason and never advances the
  # checkpoint to either an unverified or a now-stale root state.
  race_bin="$backup_fixture_dir/race-bin"
  race_marker="$backup_fixture_dir/race-fired"
  mkdir -p "$race_bin"
  cat > "$race_bin/git" <<'RACE_GIT'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == push && ! -e "$AGENT_BACKUP_RACE_MARKER" ]]; then
    : > "$AGENT_BACKUP_RACE_MARKER"
    printf 'not audited\n' > "$AGENT_BACKUP_RACE_WORK/head-moved.txt"
    "$AGENT_BACKUP_REAL_GIT" -C "$AGENT_BACKUP_RACE_WORK" add head-moved.txt
    "$AGENT_BACKUP_REAL_GIT" -C "$AGENT_BACKUP_RACE_WORK" commit -q -m 'fixture: unaudited head move'
    break
  fi
done
exec "$AGENT_BACKUP_REAL_GIT" "$@"
RACE_GIT
  chmod +x "$race_bin/git"
  printf 'audited A\n' > "$backup_work/audited-a.txt"
  backup_git add audited-a.txt
  backup_git commit -q -m 'fixture: audited A'
  audited_a="$(backup_git rev-parse HEAD)"
  checkpoint_before_race="$(sed -n 's/^sha=//p' "$backup_checkpoint_file" | head -n 1)"
  set +e
  backup_output="$(env "${backup_env[@]}" PATH="$race_bin:$PATH" \
    AGENT_BACKUP_REAL_GIT="$(command -v git)" \
    AGENT_BACKUP_RACE_MARKER="$race_marker" AGENT_BACKUP_RACE_WORK="$backup_work" \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'head-moved-during-backup' 'root HEAD moving during a workspace backup'
  unaudited_b="$(backup_git rev-parse HEAD)"
  [[ "$unaudited_b" != "$audited_a" ]] || \
    fail 'backup fixture: the race hook did not advance root HEAD from audited A to unaudited B'
  [[ "$(backup_remote_sha)" == "$audited_a" ]] || \
    fail 'backup fixture: the immutable push did not leave the remote at audited SHA A'
  [[ "$(backup_remote_sha)" != "$unaudited_b" ]] || \
    fail 'backup fixture: unaudited SHA B was sent to the remote'
  if printf '%s\n' "$backup_output" | grep -Fq 'BACKUP_BLOCKED reason=remote-verification-mismatch'; then
    fail 'backup fixture: a local HEAD move was misclassified as remote-verification-mismatch'
  fi
  [[ "$(sed -n 's/^sha=//p' "$backup_checkpoint_file" | head -n 1)" == "$checkpoint_before_race" ]] || \
    fail 'backup fixture: a HEAD move advanced the verified checkpoint'
  backup_git reset -q --hard "$backup_head"
  env "${backup_env[@]}" git -C "$backup_remote_dir" update-ref refs/heads/main "$backup_head"

  # --- Cache boundaries----------------------------------------------------------------
  build_fixture_cache
  if (( backup_status != 0 )); then
    fail 'cache fixture: build-context-cache.sh failed on a materialized workspace'
  else
    if grep -Fq 'projects/data-pipeline/' "$independent_cache_dir/manifest.tsv"; then
      fail 'cache fixture: manifest.tsv registers Independent Project contents'
    fi
    grep -Fq 'projects/REPOSITORIES.md' "$independent_cache_dir/manifest.tsv" || \
      fail 'cache fixture: manifest.tsv omits the root-side registry'
    grep -Fq 'projects/.gitignore' "$independent_cache_dir/manifest.tsv" || \
      fail 'cache fixture: manifest.tsv omits the root-side ignore projection'
    grep -Fq 'projects/embedded-project/PROJECT.md' "$independent_cache_dir/catalog.tsv" || \
      fail 'cache fixture: catalog.tsv does not register the Embedded Project'
    [[ "$(fixture_catalog_field 'projects/data-pipeline/PROJECT.md' 6)" == \
      'fixture contract owned by the child Git' ]] || \
      fail 'cache fixture: catalog.tsv does not carry the adopted revision PROJECT metadata'
    fingerprint_before="$(fixture_fingerprint)"

    printf 'child-only change\n' >> "$independent_clone/source.txt"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" == "$fingerprint_before" ]] || \
      fail 'cache fixture: an Independent code change altered the root cache fingerprint'
    child_git checkout -q -- source.txt

    printf '\n<!-- uncommitted child metadata -->\n' >> "$independent_clone/PROJECT.md"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" == "$fingerprint_before" ]] || \
      fail 'cache fixture: an uncommitted child PROJECT.md change altered the root cache fingerprint'
    child_git checkout -q -- PROJECT.md

    # Advancing the adopted revision changes both the catalog metadata and the fingerprint.
    seed_git checkout -q main
    {
      printf '%s\n' '---' 'name: data-pipeline' 'description: adopted revision two'
      printf '%s\n' 'status: active' 'mode: continuous' '---'
    } > "$independent_seed/PROJECT.md"
    seed_git add PROJECT.md
    seed_git commit -q -m 'fixture: second adopted revision'
    seed_git push -q origin main
    independent_second_revision="$(seed_git rev-parse HEAD)"
    child_git fetch -q origin main
    child_git checkout -q --detach "$independent_second_revision"
    adopt_revision "$independent_second_revision"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" != "$fingerprint_before" ]] || \
      fail 'cache fixture: a new adopted revision did not alter the root cache fingerprint'
    [[ "$(fixture_catalog_field 'projects/data-pipeline/PROJECT.md' 6)" == 'adopted revision two' ]] || \
      fail 'cache fixture: catalog.tsv did not follow the new adopted revision metadata'
    grep -Fq 'child-only change' "$independent_cache_dir/manifest.tsv" && \
      fail 'cache fixture: Independent body content leaked into the manifest'
    backup_git reset -q --hard HEAD~1
    child_git checkout -q --detach "$independent_revision"
    build_fixture_cache
  fi
  # The fixture itself advanced remote main, so measure the invariants below against the new baseline.
  independent_remote_before="$(independent_remote_sha)"

  # --- Negative cases inside the Independent clone----------------------------------------------------
  mkdir -p "$independent_clone/nested/.git"
  backup_run --dry-run
  backup_expect_blocked 'independent-nested-repository' 'a nested repository inside the Independent clone'
  rm -rf "$independent_clone/nested"

  printf '[submodule "vendor"]\n\tpath = vendor\n' > "$independent_clone/.gitmodules"
  backup_run --dry-run
  backup_expect_blocked 'independent-submodule-unsupported' 'a submodule declaration inside the clone'
  rm -f "$independent_clone/.gitmodules"

  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$independent_clone/.gitattributes"
  backup_run --dry-run
  backup_expect_blocked 'independent-git-lfs-unsupported' 'Git LFS inside the Independent clone'
  rm -f "$independent_clone/.gitattributes"

  printf 'dirty\n' >> "$independent_clone/source.txt"
  backup_run --dry-run
  backup_expect_blocked 'independent-dirty-working-tree' 'a dirty Independent working tree'
  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only scope ignoring a dirty Independent clone'
  child_git checkout -q -- source.txt

  printf 'staged\n' >> "$independent_clone/source.txt"
  child_git add source.txt
  backup_run --dry-run
  backup_expect_blocked 'independent-staged-changes' 'a staged Independent change'
  child_git reset -q --hard HEAD

  printf 'stray\n' > "$independent_clone/stray.txt"
  backup_run --dry-run
  backup_expect_blocked 'independent-untracked-files' 'an untracked Independent file'
  rm -f "$independent_clone/stray.txt"

  printf 'stashed\n' >> "$independent_clone/source.txt"
  child_git stash push -q
  backup_run --dry-run
  backup_expect_blocked 'independent-stash-present' 'an Independent stash entry'
  child_git stash drop -q

  child_git tag fixture-local-only "$independent_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unpushed-tag' 'a local-only tag'
  child_git tag -d fixture-local-only >/dev/null

  child_git checkout -q -b fixture-unpublished
  child_git commit -q --allow-empty -m 'fixture: unpublished commit'
  child_git checkout -q --detach "$independent_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unreachable-local-branch' 'a local branch absent from the remote'
  child_git branch -q -D fixture-unpublished

  # Adopt a commit whose object the remote holds but no branch or tag can reach.
  seed_git checkout -q --detach "$independent_tip"
  seed_git commit -q --allow-empty -m 'fixture: unreferenced revision'
  unreferenced_revision="$(seed_git rev-parse HEAD)"
  seed_git push -q origin 'HEAD:refs/hidden/unreferenced'
  child_git fetch -q origin "$unreferenced_revision"
  child_git checkout -q --detach "$unreferenced_revision"
  adopt_revision "$unreferenced_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unpushed-commit' 'a HEAD commit no remote head or tag reaches'
  backup_git reset -q --hard HEAD~1
  child_git checkout -q --detach "$independent_revision"

  adopt_revision '0000000000000000000000000000000000000000'
  backup_run --dry-run
  backup_expect_blocked 'independent-revision-unavailable' 'an adopted revision absent from the remote'
  backup_git reset -q --hard HEAD~1

  # All three Tools must stop when the adopted SHA exists in the clone but HEAD is a different commit.
  child_git checkout -q --detach "$independent_tip"
  backup_run --dry-run
  backup_expect_blocked 'independent-head-not-adopted' 'a HEAD that is not the adopted revision'
  materialize_run --all --check
  materialize_expect_blocked 'repository-head-not-adopted' 'data-pipeline' \
    'a materialized clone parked on a different revision'
  attachment_probe="$( (
    repo_root="$backup_work"
    failures=0
    validate_independent_attachment 'data-pipeline' "$independent_remote_dir" "$independent_revision"
    exit 0
  ) 2>&1 )"
  printf '%s\n' "$attachment_probe" | grep -Fq 'adopts' || \
    fail "validator fixture: validate_independent_attachment accepted a clone parked on a different revision: $attachment_probe"
  child_git checkout -q --detach "$independent_revision"

  child_git remote set-url origin "$backup_remote_dir"
  backup_run --dry-run
  backup_expect_blocked 'repository-origin-mismatch' 'a clone pointing at a different remote'
  child_git remote set-url origin "$independent_remote_dir"

  # An unrelated clone occupying the Project root is also stopped as an origin mismatch.
  env "${backup_env[@]}" git -C "$independent_remote_dir" config uploadpack.allowAnySHA1InWant false

  # --- Attachment negative cases---------------------------------------------------------
  mv "$independent_clone/.git" "$backup_fixture_dir/detached-git"
  printf 'gitdir: %s\n' "$backup_fixture_dir/detached-git" > "$independent_clone/.git"
  backup_run --dry-run
  backup_expect_blocked 'repository-gitfile-unsupported' 'a .git file instead of a real directory'
  rm -f "$independent_clone/.git"
  mv "$backup_fixture_dir/detached-git" "$independent_clone/.git"

  mv "$independent_clone/.git" "$backup_fixture_dir/relocated-git"
  ln -s "$backup_fixture_dir/relocated-git" "$independent_clone/.git"
  backup_run --dry-run
  backup_expect_blocked 'repository-path-symlink' 'a symlinked .git inside the Independent clone'
  rm -f "$independent_clone/.git"
  mv "$backup_fixture_dir/relocated-git" "$independent_clone/.git"

  # When the Project root itself is replaced with a symlink, the `/data-pipeline/` ignore only
  # matches a directory, so the root-side untracked check stops the run before the attachment
  # check is reached. Stopping is the safety requirement; the root-side check fixes the reason first.
  mv "$independent_clone" "$backup_fixture_dir/moved-clone"
  ln -s "$backup_fixture_dir/moved-clone" "$independent_clone"
  backup_run --dry-run
  backup_expect_blocked 'untracked-files' 'a symlinked Independent Project root'
  rm -f "$independent_clone"
  mv "$backup_fixture_dir/moved-clone" "$independent_clone"

  # A registry entry exists but the clone is an empty non-repository.
  mv "$independent_clone" "$backup_fixture_dir/parked-clone"
  mkdir -p "$independent_clone"
  printf 'stray\n' > "$independent_clone/stray.txt"
  backup_run --dry-run
  backup_expect_blocked 'repository-gitfile-unsupported' 'a non-repository directory at the Project root'
  materialize_run --project data-pipeline
  materialize_expect_blocked 'target-not-empty' 'data-pipeline' 'a non-empty non-repository target'
  rm -rf "$independent_clone"
  mv "$backup_fixture_dir/parked-clone" "$independent_clone"

  # --- Root ownership negative cases-------------------------------------------------------
  # `git add` refuses paths under an ignored Project root, so reproduce by registering blobs directly in the index.
  # Register the same content as the working tree, making it a pure ownership violation without dirtying the root.
  for tracked_child_path in source.txt PROJECT.md STATE.md; do
    fixture_tracked_blob="$(backup_git hash-object -w -- "projects/data-pipeline/$tracked_child_path")"
    backup_git update-index --add \
      --cacheinfo "100644,$fixture_tracked_blob,projects/data-pipeline/$tracked_child_path"
    backup_git commit -q -m "fixture: root tracks the Independent $tracked_child_path"
    backup_run --root-only --dry-run
    backup_expect_blocked 'root-tracks-independent-repository' \
      "the root tracking the Independent $tracked_child_path"
    backup_git reset -q --soft HEAD~1
    backup_git reset -q
  done

  backup_git update-index --add --cacheinfo "160000,$independent_revision,projects/data-pipeline"
  backup_git commit -q -m 'fixture: root gitlink'
  backup_run --root-only --dry-run
  backup_expect_blocked 'unsupported-root-gitlink' 'a gitlink in the root index'
  backup_git reset -q --soft HEAD~1
  backup_git reset -q

  # --- Registry and ignore projection negative cases-----------------------------------------
  registry_reject() {
    backup_git commit -q -a -m "fixture: $2"
    backup_run --root-only --dry-run
    backup_expect_blocked "$1" "$2"
    backup_git reset -q --hard HEAD~1
  }

  printf '%s\n' '# REPOSITORIES — Independent Repository Registry' '' '## data-pipeline' '' \
    "- repository_url: \`$independent_remote_dir\`" '- repository_reason: `automation`' \
    "- revision: \`$independent_revision\`" > "$fixture_registry"
  registry_reject 'invalid-registry' 'a malformed registry heading'

  {
    printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'a duplicate registry name'

  {
    printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
    printf '%s\n' '## `zeta-project`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'an unsorted registry'

  write_registry "$independent_revision" 'because-we-want-to'
  registry_reject 'invalid-registry' 'an invalid repository_reason'

  {
    printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '- repository_default_branch: `main`'
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'an extra registry field'

  {
    printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'a registry entry missing its revision'

  write_registry 'aaaa'
  registry_reject 'invalid-registry' 'a truncated adopted revision'

  for hostile_url in \
    "ssh://fixture:secret@example.invalid/repository.git" \
    "https://example.invalid/repository.git?token=secret" \
    "--upload-pack=/tmp/fixture-pack"; do
    {
      printf '%s\n' '# REPOSITORIES — Independent Repository Registry' ''
      printf '%s\n' '## `data-pipeline`' ''
      printf -- '- repository_url: `%s`\n' "$hostile_url"
      printf '%s\n' '- repository_reason: `automation`'
      printf -- '- revision: `%s`\n' "$independent_revision"
    } > "$fixture_registry"
    backup_git commit -q -a -m 'fixture: hostile repository_url'
    backup_run --root-only --dry-run
    backup_expect_blocked 'invalid-registry' "the hostile repository_url $hostile_url"
    printf '%s\n' "$backup_output" | grep -Fq 'secret' && \
      fail "backup fixture: the blocked report leaked a credential from $hostile_url"
    backup_git reset -q --hard HEAD~1
  done

  write_registry "$independent_revision"
  write_ignore_projection
  registry_reject 'invalid-ignore-projection' 'a registry entry missing from the ignore projection'

  write_ignore_projection data-pipeline embedded-project
  registry_reject 'invalid-ignore-projection' 'an Embedded Project inside the ignore projection'

  write_ignore_projection data-pipeline
  # --- Detection of retired layouts-----------------------------------------------------------------
  mkdir -p "$backup_work/projects/embedded-project/repository/.git"
  backup_run --root-only --dry-run
  backup_expect_blocked 'deprecated-repository-layout' 'a clone at the retired repository/ path'
  rm -rf "$backup_work/projects/embedded-project/repository"

  {
    printf '%s\n' '---' 'name: embedded-project' 'description: fixture embedded project'
    printf '%s\n' 'status: active' 'mode: finite' 'repository_mode: embedded' '---'
  } > "$backup_work/projects/embedded-project/PROJECT.md"
  registry_reject 'deprecated-repository-layout' 'a retired repository_mode field'

  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State' ''
    printf '%s\n' '## Repository State' '' "- revision: \`$independent_revision\`"
  } > "$backup_work/projects/embedded-project/STATE.md"
  registry_reject 'deprecated-repository-layout' 'a retired Repository State section'

  # --- Existing root-side negative cases---------------------------------------------------------------
  mkdir -p "$backup_work/ignored-dir/nested/.git"
  backup_run --dry-run
  backup_expect_blocked 'nested-git-repository' 'an unregistered ignored nested Git repository'
  rm -rf "$backup_work/ignored-dir"

  printf 'dirty\n' >> "$backup_work/AGENTS.md"
  backup_run --dry-run
  backup_expect_blocked 'dirty-working-tree' 'an uncommitted tracked change'
  backup_git checkout -q -- AGENTS.md

  printf 'staged\n' >> "$backup_work/AGENTS.md"
  backup_git add AGENTS.md
  backup_run --dry-run
  backup_expect_blocked 'staged-changes' 'a staged change'
  backup_git reset -q --hard HEAD

  printf 'stray\n' > "$backup_work/stray.md"
  backup_run --dry-run
  backup_expect_blocked 'untracked-files' 'an untracked non-ignored file'
  rm -f "$backup_work/stray.md"

  printf 'stashed\n' >> "$backup_work/AGENTS.md"
  backup_git stash push -q
  backup_run --dry-run
  backup_expect_blocked 'stash-present' 'a stash entry'
  backup_git stash drop -q

  mkdir -p "$backup_work/.tmp"
  printf 'scratch\n' > "$backup_work/.tmp/scratch"
  backup_git add -f .tmp/scratch
  backup_git commit -q -m 'fixture: forbidden path'
  backup_run --dry-run
  backup_expect_blocked 'forbidden-tracked-file' 'a tracked .tmp path'
  backup_git reset -q --hard HEAD~1
  rm -rf "$backup_work/.tmp"

  backup_git checkout -q -b stray-branch
  printf 'unreachable\n' > "$backup_work/unreachable.md"
  backup_git add -A
  backup_git commit -q -m 'fixture: unreachable commit'
  backup_git checkout -q main
  backup_run --dry-run
  backup_expect_blocked 'unreachable-local-branch' 'a commit unreachable from the backup branch'
  backup_git branch -q -D stray-branch

  printf '%04096d' 0 > "$backup_work/oversized.bin"
  backup_git add -A
  backup_git commit -q -m 'fixture: oversized blob'
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" \
    AGENT_BACKUP_MAX_BLOB_BYTES=1024 bash "$backup_tool" --root-only --dry-run 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'oversized-git-object' 'a blob above the size limit'
  printf '%s\n' "$backup_output" | grep -Fq 'oversized.bin' || \
    fail 'backup fixture: the oversized object report does not name the path'
  backup_git reset -q --hard HEAD~1
  rm -f "$backup_work/oversized.bin"

  env "${backup_env[@]}" git clone -q "$backup_remote_dir" "$backup_peer"
  printf 'peer\n' > "$backup_peer/peer.md"
  env "${backup_env[@]}" git -C "$backup_peer" add -A
  env "${backup_env[@]}" git -C "$backup_peer" commit -q -m 'fixture: peer commit'
  env "${backup_env[@]}" git -C "$backup_peer" push -q origin main
  printf 'local\n' > "$backup_work/local.md"
  backup_git add -A
  backup_git commit -q -m 'fixture: local commit'
  backup_sha_before_divergence="$(backup_remote_sha)"
  backup_run
  backup_expect_blocked 'remote-diverged' 'a diverged remote'
  printf '%s\n' "$backup_output" | grep -Eq "remote=$backup_sha_before_divergence local=[0-9a-f]{40}" || \
    fail 'backup fixture: the divergence report does not name both the remote and local SHA'
  [[ "$(backup_remote_sha)" == "$backup_sha_before_divergence" ]] || \
    fail 'backup fixture: the remote changed while divergence was reported'
  backup_run --dry-run
  backup_expect_blocked 'remote-diverged' 'a diverged remote in dry run'
  [[ "$(backup_remote_sha)" == "$backup_sha_before_divergence" ]] || \
    fail 'backup fixture: the dry run changed the remote'

  # --- Prove the danger of root git clean only in a throwaway fixture-----------------------------
  clean_probe_dir="$backup_fixture_dir/clean-probe"
  mkdir -p "$clean_probe_dir/projects/probe"
  printf '# Derived from projects/REPOSITORIES.md.\n# BEGIN INDEPENDENT PROJECTS\n/probe/\n# END INDEPENDENT PROJECTS\n' \
    > "$clean_probe_dir/projects/.gitignore"
  printf 'unpushed work\n' > "$clean_probe_dir/projects/probe/unpushed.txt"
  env "${backup_env[@]}" git init -q "$clean_probe_dir"
  env "${backup_env[@]}" git -C "$clean_probe_dir" add -A
  env "${backup_env[@]}" git -C "$clean_probe_dir" commit -q -m 'fixture: clean probe'
  env "${backup_env[@]}" git -C "$clean_probe_dir" clean -q -ffdx
  [[ ! -e "$clean_probe_dir/projects/probe/unpushed.txt" ]] || \
    fail 'clean probe fixture: the ignored Independent Project root unexpectedly survived git clean -ffdx'
  rm -rf "$clean_probe_dir"

  [[ -z "$(backup_git status --porcelain)" ]] || \
    fail 'backup fixture: the backup tool left the working tree modified'
  [[ -z "$(child_git status --porcelain)" ]] || \
    fail 'backup fixture: the backup tool left the Independent clone modified'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'backup fixture: the backup tool moved the Independent clone HEAD'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the Independent remote changed during the whole fixture run'
fi

  decay_clean_root="$repo_root/evals/fixtures/decay-clean"
  decay_aged_root="$repo_root/evals/fixtures/decay-aged"
  decay_clean_knowledge="$(AGENT_DIRECTORY_ROOT="$decay_clean_root" AGENT_CACHE_DIR="$decay_clean_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- 'ロールアウト方針' || true)"
  decay_aged_knowledge="$(AGENT_DIRECTORY_ROOT="$decay_aged_root" AGENT_CACHE_DIR="$decay_aged_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- 'ロールアウト方針' || true)"
  [[ "$decay_clean_knowledge" == "$decay_aged_knowledge" ]] || \
    fail 'Agent Decay fixture: Aged Knowledge routing differs from Clean routing'
  printf '%s\n' "$decay_aged_knowledge" | grep -Fq 'rollout-policy-current' || \
    fail 'Agent Decay fixture: Aged Knowledge routing omitted the current canon'
  if printf '%s\n' "$decay_aged_knowledge" | grep -Eq 'rollout-policy-(old|archive|retired)'; then
    fail 'Agent Decay fixture: Aged Knowledge routing returned inactive noise'
  fi
  decay_clean_project="$(AGENT_DIRECTORY_ROOT="$decay_clean_root" AGENT_CACHE_DIR="$decay_clean_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route project --limit 5 -- 'rollout-operations' || true)"
  decay_aged_project="$(AGENT_DIRECTORY_ROOT="$decay_aged_root" AGENT_CACHE_DIR="$decay_aged_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route project --limit 5 -- 'rollout-operations' || true)"
  [[ "$decay_clean_project" == "$decay_aged_project" ]] || \
    fail 'Agent Decay fixture: Aged Project routing differs from Clean routing'
  printf '%s\n' "$decay_aged_project" | grep -Fq $'project\tproject\tactive\trollout-operations\t' || \
    fail 'Agent Decay fixture: Aged Project routing omitted the active Project'
  if printf '%s\n' "$decay_aged_project" | grep -Eq 'rollout-operations-(2025|paused)|legacy-rollout'; then
    fail 'Agent Decay fixture: Aged Project routing returned inactive noise'
  fi
  decay_clean_packet="$(AGENT_DIRECTORY_ROOT="$decay_clean_root" \
    bash "$repo_root/tools/prepare-context.sh" --route project \
      --target projects/rollout-operations --class read || true)"
  decay_aged_packet="$(AGENT_DIRECTORY_ROOT="$decay_aged_root" \
    bash "$repo_root/tools/prepare-context.sh" --route project \
      --target projects/rollout-operations --class read || true)"
  [[ "$decay_clean_packet" == "$decay_aged_packet" ]] || \
    fail 'Agent Decay fixture: explicit target Context Packet grows in the Aged workspace'
  decay_clean_catalog_count="$(tail -n +2 "$decay_clean_cache_dir/catalog.tsv" | grep -c . || true)"
  decay_aged_catalog_count="$(tail -n +2 "$decay_aged_cache_dir/catalog.tsv" | grep -c . || true)"
  (( decay_aged_catalog_count > decay_clean_catalog_count )) || \
    fail 'Agent Decay fixture: Aged workspace does not contain more routing noise than Clean'

  fixture_root="$repo_root/evals/fixtures/context-search"
  if ! result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$fixture_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '資本配分')"; then
    fail 'find-context.sh failed on context-search fixture'
  else
    printf '%s\n' "$result" | grep -Fq 'capital-allocation-current' || fail 'context search did not return active Knowledge'
    if printf '%s\n' "$result" | grep -Fq 'capital-allocation-old'; then
      fail 'context search returned superseded Knowledge by default'
    fi
    result_count="$(printf '%s\n' "$result" | tail -n +2 | grep -c . || true)"
    (( result_count <= 5 )) || fail 'context search returned more than 5 candidates'
  fi
  project_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$fixture_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route project --limit 5 -- '市場判断' || true)"
  printf '%s\n' "$project_result" | grep -Fq $'project\tproject\tactive\tmarket-review\t' || \
    fail 'context search did not return active Project'
  if printf '%s\n' "$project_result" | grep -Fq 'market-review-2025'; then
    fail 'context search returned completed Project by default'
  fi

  if command -v sqlite3 >/dev/null 2>&1 && \
    sqlite3 ':memory:' "CREATE VIRTUAL TABLE fts_probe USING fts5(body, tokenize='trigram');" >/dev/null 2>&1; then
    if ! AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
      AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
      bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
      fail 'scale-triggered SQLite cache generation failed'
    elif [[ ! -f "$sqlite_fixture_cache_dir/search.sqlite" ]] || \
      ! grep -Fqx 'search_backend=sqlite-fts5' "$sqlite_fixture_cache_dir/cache.meta"; then
      fail 'scale threshold did not activate SQLite FTS5'
    elif [[ "$(sqlite3 "$sqlite_fixture_cache_dir/search.sqlite" 'PRAGMA integrity_check;')" != 'ok' ]]; then
      fail 'scale-triggered SQLite cache failed integrity_check'
    else
      sqlite_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
        AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
        bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '投下先ごとの期待収益' || true)"
      printf '%s\n' "$sqlite_result" | grep -Fq 'capital-allocation-current' || \
        fail 'SQLite FTS5 did not retrieve body-only Japanese text'
      printf 'corrupted fixture' > "$sqlite_fixture_cache_dir/search.sqlite"
      recovery_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
        AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
        bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '投下先ごとの期待収益' || true)"
      printf '%s\n' "$recovery_result" | grep -Fq 'capital-allocation-current' || \
        fail 'find-context.sh did not rebuild a corrupted SQLite cache'
    fi
  fi

  validator_metric_checkpoint 'full-core'
fi

# Control boundary fixtures: the verifier, the policy, the installer, and both git hooks are
# exercised inside isolated repositories. Nothing touches the real repo or its .git/hooks.
# Regression targets (audit 2026-08-07): unstaged policy/verifier tamper, root override,
# full-validation receipts, machine-blocked mixed scope, outgoing push re-check,
# Project contract tier, Independent-root enforcement, and stale-snapshot refresh.
if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  control_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-control.XXXXXX")"
  cleanup_paths+=("$control_fixture_dir")
  control_work="$control_fixture_dir/work"
  control_bare="$control_fixture_dir/bare.git"
  control_backup_bare="$control_fixture_dir/backup.git"
  control_decoy="$control_fixture_dir/decoy"
  control_env=(
    HOME="$control_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  )
  mkdir -p "$control_work/tools/hooks" "$control_work/knowledge/raw/internal" \
    "$control_work/knowledge/wiki/logs" "$control_work/projects/demo" \
    "$control_work/evals/cases" "$control_work/evals/profiles"
  cp "$repo_root/tools/check-boundary.sh" "$repo_root/tools/control-policy.tsv" \
    "$repo_root/tools/install-git-hooks.sh" "$control_work/tools/"
  cp "$repo_root/tools/hooks/pre-commit" "$repo_root/tools/hooks/pre-push" "$control_work/tools/hooks/"
  printf 'immutable record\n' > "$control_work/knowledge/raw/internal/record.txt"
  printf '# closed log\n' > "$control_work/knowledge/wiki/logs/2026-Q1.md"
  printf 'work\n' > "$control_work/projects/demo/note.md"
  printf '# demo contract\n' > "$control_work/projects/demo/PROJECT.md"
  printf '# ordinary documentation\n' > "$control_work/README.md"
  printf '# six invariant safety kernel\n' > "$control_work/tools/SAFETY.md"
  printf 'name: route-to-knowledge\nexpect:\n  must_read: [knowledge/KNOWLEDGE.md]\n' > \
    "$control_work/evals/cases/route-to-knowledge.yaml"
  printf 'route-to-knowledge\n' > "$control_work/evals/profiles/core.txt"
  env "${control_env[@]}" git -C "$control_work" init -q
  env "${control_env[@]}" git -C "$control_work" add -A
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: control baseline'
  control_approved_policy="$control_fixture_dir/approved-policy.tsv"
  cp "$control_work/tools/control-policy.tsv" "$control_approved_policy"

  control_boundary() {
    # $@ = 追加の環境変数割り当て（例: AGENT_GUARDED_COMMIT=true）
    set +e
    control_output="$(cd "$control_work" && env "${control_env[@]}" "$@" \
      /bin/bash tools/check-boundary.sh --staged 2>&1)"
    control_status=$?
    set -e
  }
  control_commit() {
    # $1=commit message、以降=追加の環境変数割り当て。hooks経由の実commitを試みる。
    local control_message="$1"
    shift
    set +e
    control_output="$( (cd "$control_work" && env "${control_env[@]}" "$@" \
      git commit -q -m "$control_message") 2>&1 )"
    control_status=$?
    set -e
  }

  # A plain in-scope change passes the verifier.
  printf 'more work\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  if (( control_status != 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK'; then
    fail "control fixture: an in-scope staged change was not accepted: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: in-scope work'

  # Staged ordinary blobs are inspected without printing matched values. Reserved examples,
  # GitHub noreply identities, and explicitly synthetic home paths remain valid controls.
  printf '%s@%s\n' 'customer' 'public.test' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_boundary
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=sensitive-content'; then
    fail "control fixture: a direct email in ordinary content was not refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  printf 'github_pat_%s\n' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ123456' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_boundary
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=sensitive-content'; then
    fail "control fixture: a credential in ordinary content was not refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  printf '/Users/%s/private\n' 'real-user' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_boundary
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=sensitive-content'; then
    fail "control fixture: a personal home path in ordinary content was not refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  printf 'fixture@example.invalid\n/Users/example-user/project\n' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_boundary
  if (( control_status != 0 )); then
    fail "control fixture: reserved synthetic privacy examples were refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  control_direct_email='direct''@''public.test'
  control_boundary GIT_AUTHOR_EMAIL="$control_direct_email"
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=unsafe-git-email'; then
    fail "control fixture: a direct prospective author email was not refused: $control_output"
  fi
  control_boundary GIT_AUTHOR_EMAIL='123+fixture@users.noreply.github.com'
  if (( control_status != 0 )); then
    fail "control fixture: a GitHub noreply prospective author was refused: $control_output"
  fi

  # A forbidden path is refused even as an addition.
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path' || \
    fail "control fixture: staging .env was not refused as forbidden-path: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q -- .env
  rm -f "$control_work/.env"

  # A frozen path accepts additions and refuses modification.
  printf 'tampered\n' >> "$control_work/knowledge/raw/internal/record.txt"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=frozen-path-modified' || \
    fail "control fixture: modifying immutable source material was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q
  env "${control_env[@]}" git -C "$control_work" checkout -q -- knowledge/raw/internal/record.txt
  printf 'new record\n' > "$control_work/knowledge/raw/internal/record-2.txt"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: adding new immutable source material was refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: add raw record'

  # Renaming a frozen file out of its area is a modification, not an addition.
  env "${control_env[@]}" git -C "$control_work" mv \
    knowledge/raw/internal/record-2.txt projects/demo/escaped.txt
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=frozen-path-modified' || \
    fail "control fixture: renaming a frozen file out of its area was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # A guarded meta change requires the explicit one-commit acknowledgment (policy tamper included).
  printf '# fixture policy edit\n' >> "$control_work/tools/control-policy.tsv"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=guarded-path-without-ack' || \
    fail "control fixture: an unacknowledged policy edit was not refused: $control_output"
  control_boundary AGENT_GUARDED_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: an acknowledged guarded change was refused: $control_output"

  # Guarded/contract changes mixed with ordinary work are machine-blocked even with the ack.
  printf 'mixed\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary AGENT_GUARDED_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'reason=mixed-scope' || \
    fail "control fixture: a mixed guarded+ordinary stage was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # If the ordinary path is newly guarded only by the staged policy, keep the
  # approved-snapshot verdict but identify the precise policy/snapshot gap and recovery.
  printf 'guarded\tprojects/new-canon/*\tfixture staged policy extension\n' >> \
    "$control_work/tools/control-policy.tsv"
  mkdir -p "$control_work/projects/new-canon"
  printf 'new canon\n' > "$control_work/projects/new-canon/settings.json"
  env "${control_env[@]}" git -C "$control_work" add tools/control-policy.tsv \
    projects/new-canon/settings.json
  set +e
  control_output="$(cd "$control_work" && env "${control_env[@]}" AGENT_GUARDED_COMMIT=true \
    /bin/bash tools/check-boundary.sh --staged --policy "$control_approved_policy" 2>&1)"
  control_status=$?
  set -e
  printf '%s\n' "$control_output" | grep -Fq 'reason=mixed-scope' || \
    fail "control fixture: a staged policy extension was not refused against the approved snapshot: $control_output"
  printf '%s\n' "$control_output" | grep -Fq \
    'staged policy classifies projects/new-canon/settings.json as guarded' || \
    fail "control fixture: mixed-scope did not identify the staged-policy snapshot gap: $control_output"
  printf '%s\n' "$control_output" | grep -Fq 'safe recovery: commit the policy change alone' || \
    fail "control fixture: mixed-scope did not provide the safe two-step recovery: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # A Project contract change needs its own explicit approval acknowledgment.
  printf 'PC-01 rewritten\n' >> "$control_work/projects/demo/PROJECT.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=contract-path-without-approval' || \
    fail "control fixture: an unapproved Project contract change was not refused: $control_output"
  control_boundary AGENT_CONTRACT_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: an approved Project contract change was refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # The verifier refuses a transplanted root instead of judging the wrong repository.
  env "${control_env[@]}" git init -q "$control_decoy"
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  set +e
  control_output="$(cd "$control_work" && env "${control_env[@]}" \
    AGENT_DIRECTORY_ROOT="$control_decoy" /bin/bash tools/check-boundary.sh --staged 2>&1)"
  control_status=$?
  set -e
  printf '%s\n' "$control_output" | grep -Fq 'reason=root-mismatch' || \
    fail "control fixture: a transplanted AGENT_DIRECTORY_ROOT was not refused: $control_output"

  # The installer is idempotent, snapshots the approved control files, and covers zero independents.
  control_hooks() {
    set +e
    control_output="$(cd "$control_work" && env "${control_env[@]}" \
      /bin/bash tools/install-git-hooks.sh "$@" 2>&1)"
    control_status=$?
    set -e
  }
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_INSTALLED hooks=2 independent=0' || \
    fail "control fixture: hook install did not report two managed hooks: $control_output"
  control_hooks --install
  if (( control_status != 0 )); then
    fail "control fixture: a repeated hook install was not idempotent: $control_output"
  fi
  control_hooks --status
  printf '%s\n' "$control_output" | grep -Fq 'pre-commit=managed pre-push=managed independent=0/0' || \
    fail "control fixture: hook status does not report both hooks as managed: $control_output"
  for control_snapshot_file in check-boundary.sh control-policy.tsv approved.sha256; do
    [[ -f "$control_work/.git/agent-control/$control_snapshot_file" ]] || \
      fail "control fixture: install did not snapshot $control_snapshot_file"
  done

  # With hooks installed: loosening the working-tree policy WITHOUT staging it changes nothing —
  # the hook judges with the approved snapshot, so the forbidden path still cannot be committed.
  printf '# 全行無効化\n' > "$control_work/tools/control-policy.tsv"
  control_commit 'fixture: unstaged policy tamper'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: an unstaged policy loosening changed the verdict: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" checkout -q -- tools/control-policy.tsv

  # Neutering the working-tree verifier without staging it is equally ineffective.
  printf '#!/bin/sh\nexit 0\n' > "$control_work/tools/check-boundary.sh"
  control_commit 'fixture: unstaged verifier tamper'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: an unstaged verifier replacement changed the verdict: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" checkout -q -- tools/check-boundary.sh

  # The hook pins the root, so an external AGENT_DIRECTORY_ROOT cannot transplant the judgement.
  control_commit 'fixture: root override attempt' AGENT_DIRECTORY_ROOT="$control_decoy"
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: AGENT_DIRECTORY_ROOT transplanted the hook judgement: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q -- .env
  rm -f "$control_work/.env"

  # Ordinary model-facing documentation remains a normal commit: no ack and no full
  # receipt are required merely because the file is at repository root.
  printf 'clarified normal path\n' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_commit 'fixture: ordinary documentation'
  if (( control_status != 0 )); then
    fail "control fixture: ordinary README documentation required protected ceremony: $control_output"
  fi

  # A Core safety file requires both the one-commit ack and an index-tree-bound receipt.
  printf 'safety invariant clarification\n' >> "$control_work/tools/SAFETY.md"
  env "${control_env[@]}" git -C "$control_work" add tools/SAFETY.md
  control_commit 'fixture: unacknowledged safety change'
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=guarded-path-without-ack'; then
    fail "control fixture: a Core safety change passed without ack: $control_output"
  fi
  control_commit 'fixture: safety without receipt' AGENT_GUARDED_COMMIT=true
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=missing-full-validation-receipt'; then
    fail "control fixture: an acked Core safety change passed without a receipt: $control_output"
  fi
  control_safety_tree="$(env "${control_env[@]}" git -C "$control_work" write-tree)"
  mkdir -p "$control_work/.git/agent-control/receipts"
  printf 'head=fixture\n' > "$control_work/.git/agent-control/receipts/$control_safety_tree"
  control_commit 'fixture: acknowledged safety change' AGENT_GUARDED_COMMIT=true
  if (( control_status != 0 )); then
    fail "control fixture: an acked Core safety change with a receipt was refused: $control_output"
  fi
  [[ ! -f "$control_work/.git/agent-control/receipts/$control_safety_tree" ]] || \
    fail 'control fixture: the Core safety receipt was not consumed on use'

  # Core eval cases are protected by the same gate. Even an acked attempted weakening
  # cannot enter history silently without the exact full-validation receipt.
  control_eval_head="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD)"
  printf 'name: route-to-knowledge\nexpect: {}\n' > \
    "$control_work/evals/cases/route-to-knowledge.yaml"
  env "${control_env[@]}" git -C "$control_work" add evals/cases/route-to-knowledge.yaml
  control_commit 'fixture: weaken Core eval' AGENT_GUARDED_COMMIT=true
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=missing-full-validation-receipt'; then
    fail "control fixture: a Core eval weakening passed without a receipt: $control_output"
  fi
  [[ "$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD)" == \
    "$control_eval_head" ]] || fail 'control fixture: a refused Core eval weakening changed history'
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # An unacknowledged guarded commit fails at the hook.
  printf 'forbidden\tblocked.txt\tfixture row\n' >> "$control_work/tools/control-policy.tsv"
  env "${control_env[@]}" git -C "$control_work" add tools/control-policy.tsv
  control_commit 'fixture: tamper attempt'
  if (( control_status == 0 )); then
    fail 'control fixture: the pre-commit hook let an unacknowledged guarded commit through'
  fi

  # The ack alone is not enough: a guarded commit needs the index-tree-bound full receipt.
  control_commit 'fixture: acked without receipt' AGENT_GUARDED_COMMIT=true
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=missing-full-validation-receipt'; then
    fail "control fixture: a guarded commit passed without a full-validation receipt: $control_output"
  fi
  control_receipt_tree="$(env "${control_env[@]}" git -C "$control_work" write-tree)"
  mkdir -p "$control_work/.git/agent-control/receipts"
  printf 'head=fixture\n' > "$control_work/.git/agent-control/receipts/$control_receipt_tree"
  control_commit 'fixture: acknowledged policy change' AGENT_GUARDED_COMMIT=true
  if (( control_status != 0 )); then
    fail "control fixture: an acknowledged guarded commit with a receipt was refused: $control_output"
  fi
  [[ ! -f "$control_work/.git/agent-control/receipts/$control_receipt_tree" ]] || \
    fail 'control fixture: the full-validation receipt was not consumed on use'

  # The snapshot follows HEAD only: the newly committed forbidden row is enforced on the
  # next commit, and approved.sha256 records the refreshed policy blob.
  printf 'smuggle\n' > "$control_work/blocked.txt"
  env "${control_env[@]}" git -C "$control_work" add blocked.txt
  control_commit 'fixture: stale snapshot probe'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: a policy row committed to HEAD was not enforced after refresh: $control_output"
  fi
  control_policy_blob="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD:tools/control-policy.tsv)"
  grep -Fq "$control_policy_blob control-policy.tsv" "$control_work/.git/agent-control/approved.sha256" || \
    fail 'control fixture: the snapshot hash record did not follow the committed policy'
  env "${control_env[@]}" git -C "$control_work" reset -q -- blocked.txt
  rm -f "$control_work/blocked.txt"

  # The pre-push hook allows fast-forward pushes and re-checks outgoing content.
  env "${control_env[@]}" git init -q --bare "$control_bare"
  env "${control_env[@]}" git -C "$control_work" remote add origin "$control_bare"
  if ! env "${control_env[@]}" git -C "$control_work" push -q origin HEAD:main >/dev/null 2>&1; then
    fail 'control fixture: the pre-push hook refused a plain fast-forward push'
  fi

  # A deletion-only outgoing commit must still push, including as the oldest commit of the
  # outgoing range (rev-list scans it last). The privacy scan has no blob to read for a
  # deleted path; that empty result must not become a silent nonzero scan exit.
  printf 'delete probe\n' > "$control_work/zz-delete-probe.txt"
  env "${control_env[@]}" git -C "$control_work" add zz-delete-probe.txt
  control_commit 'fixture: add deletion probe'
  (( control_status == 0 )) || fail "control fixture: deletion probe add commit failed: $control_output"
  env "${control_env[@]}" git -C "$control_work" push -q origin HEAD:main >/dev/null 2>&1 || \
    fail 'control fixture: deletion probe seed push failed'
  env "${control_env[@]}" git -C "$control_work" rm -q zz-delete-probe.txt
  control_commit 'fixture: delete probe file'
  (( control_status == 0 )) || fail "control fixture: deletion probe delete commit failed: $control_output"
  printf 'follow-up after deletion\n' > "$control_work/aa-followup-probe.txt"
  env "${control_env[@]}" git -C "$control_work" add aa-followup-probe.txt
  control_commit 'fixture: follow-up after deletion'
  (( control_status == 0 )) || fail "control fixture: deletion probe follow-up commit failed: $control_output"
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push -q origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status != 0 )); then
    fail "control fixture: the pre-push hook refused a fast-forward push whose oldest outgoing commit only deletes a file: $control_output"
  fi

  # A new remote ref must scan only commits not already represented by a tracking ref for
  # that named remote. Seed a legacy commit directly in the fixture remote: its unsafe email
  # is pre-existing remote history, while a safe child is the only newly outgoing commit.
  control_plain_tip="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD)"
  printf 'legacy remote history\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add projects/demo/note.md
  env "${control_env[@]}" GIT_AUTHOR_EMAIL="$control_direct_email" \
    GIT_COMMITTER_EMAIL="$control_direct_email" \
    git -C "$control_work" commit -q --no-verify -m 'fixture: legacy remote metadata'
  control_legacy_tip="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD)"
  env "${control_env[@]}" git -C "$control_bare" fetch -q "$control_work" \
    "$control_legacy_tip:refs/heads/legacy"
  env "${control_env[@]}" git -C "$control_work" fetch -q origin \
    legacy:refs/remotes/origin/legacy

  # An empty canonical backup remote may trust the nearest ancestor already published by
  # the fetched template remote. This keeps initial workspace backup from rescanning legacy
  # public metadata while still scanning every downstream commit.
  env "${control_env[@]}" git init -q --bare "$control_backup_bare"
  env "${control_env[@]}" git -C "$control_work" remote add backup "$control_backup_bare"
  env "${control_env[@]}" git -C "$control_work" remote add template "$control_bare"
  env "${control_env[@]}" git -C "$control_work" fetch -q template \
    legacy:refs/remotes/template/legacy

  printf 'safe new branch work\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add projects/demo/note.md
  control_commit 'fixture: safe child of remote legacy'
  (( control_status == 0 )) || \
    fail "control fixture: a safe child of remote legacy history was refused at commit: $control_output"
  if ! env "${control_env[@]}" git -C "$control_work" push -q origin \
    HEAD:refs/heads/safe-new >/dev/null 2>&1; then
    fail 'control fixture: a new ref rescanned and rejected history already represented by the remote'
  fi
  if ! env "${control_env[@]}" git -C "$control_work" push -q backup \
    HEAD:refs/heads/main >/dev/null 2>&1; then
    fail 'control fixture: initial backup rescanned and rejected history already published by template'
  fi

  # The remote ancestor optimization must not hide newly outgoing forbidden content.
  env "${control_env[@]}" git -C "$control_work" reset -q --hard "$control_legacy_tip" >/dev/null
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  env "${control_env[@]}" git -C "$control_work" commit -q --no-verify -m 'fixture: new ref secret'
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push \
    origin HEAD:refs/heads/unsafe-new 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: a new ref omitted newly outgoing forbidden content: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard "$control_plain_tip" >/dev/null

  # A forbidden file committed with --no-verify is still stopped before it reaches the remote.
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  env "${control_env[@]}" git -C "$control_work" commit -q --no-verify -m 'fixture: smuggled secret'
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: the pre-push hook let a --no-verify forbidden commit through: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null

  # A content leak committed with --no-verify is still caught by the outgoing-object scan.
  printf '%s@%s\n' 'customer' 'public.test' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  env "${control_env[@]}" git -C "$control_work" commit -q --no-verify -m 'fixture: smuggled private content'
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=sensitive-content'; then
    fail "control fixture: pre-push missed private content committed with --no-verify: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null

  # The same immutable range must never alternate between accepted and rejected.
  # A large blob makes early-exit/SIGPIPE races observable on implementations where
  # `cat-file | grep -q` does not finish writing before grep returns.
  control_repeat_base="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD)"
  {
    printf '/Users/%s/private\n' 'repeat-owner'
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "deterministic-padding" }'
  } > "$control_work/repeat-sensitive.md"
  env "${control_env[@]}" git -C "$control_work" add repeat-sensitive.md
  env "${control_env[@]}" git -C "$control_work" commit -q --no-verify -m \
    'fixture: deterministic privacy range'
  for control_repeat_run in 1 2 3 4 5 6 7 8 9 10 11 12; do
    set +e
    control_output="$(cd "$control_work" && env "${control_env[@]}" \
      /bin/bash tools/check-boundary.sh --range "$control_repeat_base" HEAD 2>&1)"
    control_status=$?
    set -e
    if (( control_status == 0 )) || \
      ! printf '%s\n' "$control_output" | grep -Fq 'reason=sensitive-content'; then
      fail "control fixture: privacy range run $control_repeat_run was non-deterministic: $control_output"
    fi
  done
  env "${control_env[@]}" git -C "$control_work" reset -q --hard "$control_repeat_base" >/dev/null

  # Outgoing commit headers are checked even when the commit hook was bypassed.
  printf 'metadata probe\n' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  env "${control_env[@]}" GIT_AUTHOR_EMAIL="$control_direct_email" \
    GIT_COMMITTER_EMAIL="$control_direct_email" \
    git -C "$control_work" commit -q --no-verify -m 'fixture: smuggled direct email metadata'
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=unsafe-git-email'; then
    fail "control fixture: pre-push missed direct commit email metadata: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null

  # GitHub creates the PR merge commit server-side with its fixed service noreply
  # committer. The post-merge range scan must accept that identity without opening
  # the allowlist to arbitrary github.com addresses.
  control_service_base="$(git -C "$control_work" rev-parse HEAD)"
  printf 'service metadata probe\n' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  env "${control_env[@]}" GIT_AUTHOR_EMAIL='123+fixture@users.noreply.github.com' \
    GIT_COMMITTER_EMAIL='noreply''@''github.com' \
    git -C "$control_work" commit -q --no-verify -m 'fixture: GitHub service merge metadata'
  set +e
  control_output="$(cd "$control_work" && env "${control_env[@]}" \
    /bin/bash tools/check-boundary.sh --range "$control_service_base" HEAD 2>&1)"
  control_status=$?
  set -e
  if (( control_status != 0 )); then
    fail "control fixture: GitHub service noreply merge metadata was refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard "$control_service_base" >/dev/null

  # Credential-free scp-style GitHub SSH URLs contain a fixed `git` username that
  # looks like a direct email to the shared metadata/content scanner. Accept exactly
  # that transport identity while the direct-email fixture above keeps arbitrary
  # github.com addresses blocked.
  control_ssh_base="$(git -C "$control_work" rev-parse HEAD)"
  printf '%s\n' 'ssh_url=git''@''github.com:owner/repository.git' >> "$control_work/README.md"
  env "${control_env[@]}" git -C "$control_work" add README.md
  control_commit 'fixture: GitHub SSH transport identity'
  (( control_status == 0 )) || \
    fail "control fixture: GitHub SSH transport identity was refused: $control_output"
  set +e
  control_output="$(cd "$control_work" && env "${control_env[@]}" \
    /bin/bash tools/check-boundary.sh --range "$control_ssh_base" HEAD 2>&1)"
  control_status=$?
  set -e
  if (( control_status != 0 )); then
    fail "control fixture: GitHub SSH transport identity range was refused: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard "$control_ssh_base" >/dev/null

  # Rewritten history is refused as non-fast-forward, and remote ref deletion is refused.
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null
  printf 'diverged\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add projects/demo/note.md
  control_commit 'fixture: diverged history'
  (( control_status == 0 )) || \
    fail "control fixture: a plain commit for the divergence probe was refused: $control_output"
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push --force origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=non-fast-forward'; then
    fail "control fixture: the pre-push hook let a forced non-fast-forward push through: $control_output"
  fi
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin :refs/heads/main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=ref-deletion'; then
    fail "control fixture: the pre-push hook let a remote ref deletion through: $control_output"
  fi

  # A materialized Independent repository receives the same hooks with a normalized path prefix,
  # so its own contract file is protected inside its own Git root.
  control_ind="$control_work/projects/ind"
  mkdir -p "$control_ind"
  printf '# independent contract\n' > "$control_ind/PROJECT.md"
  printf 'independent work\n' > "$control_ind/note.md"
  env "${control_env[@]}" git -C "$control_ind" init -q
  env "${control_env[@]}" git -C "$control_ind" add -A
  env "${control_env[@]}" git -C "$control_ind" commit -q -m 'fixture: independent baseline'
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_INSTALLED hooks=2 independent=1' || \
    fail "control fixture: install did not cover the materialized independent repository: $control_output"
  grep -Fqx 'projects/ind/' "$control_ind/.git/agent-control/path-prefix" || \
    fail 'control fixture: the independent snapshot does not carry its normalized path prefix'
  printf 'PC-01 rewritten\n' >> "$control_ind/PROJECT.md"
  env "${control_env[@]}" git -C "$control_ind" add PROJECT.md
  set +e
  control_output="$( (cd "$control_ind" && env "${control_env[@]}" \
    git commit -q -m 'fixture: independent contract tamper') 2>&1 )"
  control_status=$?
  set -e
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=contract-path-without-approval'; then
    fail "control fixture: the independent contract change was not refused: $control_output"
  fi
  set +e
  control_output="$( (cd "$control_ind" && env "${control_env[@]}" AGENT_CONTRACT_COMMIT=true \
    git commit -q -m 'fixture: approved independent contract change') 2>&1 )"
  control_status=$?
  set -e
  if (( control_status != 0 )); then
    fail "control fixture: an approved independent contract change was refused: $control_output"
  fi

  # An unmanaged hook is never overwritten on install nor deleted on remove.
  printf '#!/bin/sh\nexit 0\n' > "$control_work/.git/hooks/pre-commit"
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'reason=unmanaged-hook-exists' || \
    fail "control fixture: install overwrote an unmanaged hook: $control_output"
  control_hooks --remove
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_REMOVED removed=1 independent=1' || \
    fail "control fixture: remove did not report the managed hooks precisely: $control_output"
  [[ -f "$control_work/.git/hooks/pre-commit" ]] || \
    fail 'control fixture: remove deleted an unmanaged hook'
fi

if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  validator_metric_checkpoint 'control'
fi
run_git_boundary_checks
validator_metric_checkpoint 'epilogue'
validator_metric_finish
finish_run
