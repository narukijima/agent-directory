#!/usr/bin/env bash
set -euo pipefail

# Small, provider-independent validator for the public Agent Workspace contract.

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_root/.." && pwd -P)"
. "$tool_root/lib/project-registry.sh"
contract_version='1.0.0'
strict=false
full=false
base_ref=''
bootstrap_status=false
failures=0
warnings=0
tool_fixture_root=''

cleanup() {
  [[ -z "$tool_fixture_root" ]] || rm -rf -- "$tool_fixture_root"
}
trap cleanup EXIT

usage() {
  printf 'Usage: %s [--strict] [--full] [--base <ref>] [--bootstrap-status] [--version]\n' "${0##*/}" >&2
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
    --base)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --bootstrap-status) bootstrap_status=true; shift ;;
    --version) printf 'agent-directory contract %s\n' "$contract_version"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ "$bootstrap_status" == true ]]; then
  [[ "$strict" == false && "$full" == false && -z "$base_ref" ]] || {
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

require_file() {
  [[ -f "$repo_root/$1" ]] || fail "missing required file: $1"
}

check_size() {
  local path="$1" limit="$2" label="$3" bytes
  [[ -f "$repo_root/$path" ]] || return 0
  bytes="$(wc -c < "$repo_root/$path" | tr -d ' ')"
  (( bytes <= limit )) || fail "$label exceeds ${limit}B: $path (${bytes}B)"
}

# Character count independent of the caller's locale: ${#var} degrades to a byte
# count under LC_ALL=C, so UTF-8 code points are counted by dropping continuation bytes.
char_length() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '
}

# Repository-relative reference paths (corrects, source, superseded_by,
# artifacts_retained_at) must stay inside the repository: no absolute path,
# backslash, empty segment, or `.` / `..` traversal component.
repo_path_is_unsafe() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  case "$path" in
    /*|*'\'*) return 0 ;;
  esac
  case "/$path/" in
    *'/../'*|*'/./'*|*'//'*) return 0 ;;
  esac
  return 1
}

# $1 is a YYYY-MM-DD string that already matched the shape regex; succeed only
# when the calendar date exists.
date_is_real() {
  local year=$((10#${1:0:4})) month=$((10#${1:5:2})) day=$((10#${1:8:2})) max_day=31
  (( month >= 1 && month <= 12 && day >= 1 )) || return 1
  case "$month" in
    4|6|9|11) max_day=30 ;;
    2)
      if (( (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 )); then
        max_day=29
      else
        max_day=28
      fi
      ;;
  esac
  (( day <= max_day ))
}

# $1 is a recorded_at value that already matched the shape regex; succeed only
# when date, time, and timezone offset denote a real instant.
datetime_is_real() {
  local value="$1" hour minute second offset_hour offset_minute
  date_is_real "${value:0:10}" || return 1
  (( ${#value} > 10 )) || return 0
  hour=$((10#${value:11:2})); minute=$((10#${value:14:2})); second=$((10#${value:17:2}))
  (( hour <= 23 && minute <= 59 && second <= 59 )) || return 1
  [[ "${value:19}" != 'Z' ]] || return 0
  offset_hour=$((10#${value:20:2})); offset_minute=$((10#${value:23:2}))
  (( offset_hour <= 14 && offset_minute <= 59 ))
}

# YAML keys defined twice in one frontmatter block are ambiguous: parsers may
# silently pick either value. Reject the duplicates instead of guessing.
check_frontmatter_unique() {
  local file="$1" duplicate
  [[ "$(sed -n '1p' "$file")" == '---' ]] || return 0
  while IFS= read -r duplicate; do
    [[ -n "$duplicate" ]] || continue
    fail "${file#"$repo_root"/} has a duplicate frontmatter key: $duplicate"
  done < <(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    !in_frontmatter { next }
    match($0, /^[A-Za-z_-][A-Za-z0-9_.-]*:/) {
      key = substr($0, 1, RLENGTH - 1)
      if (top_seen[key]++ == 1) print key
      next
    }
    match($0, /^[[:space:]]+[A-Za-z_-][A-Za-z0-9_.-]*:/) {
      key = $0
      sub(/^[[:space:]]+/, "", key)
      sub(/:.*$/, "", key)
      if (nested_seen[key]++ == 1) print key
    }
  ' "$file")
}

# Comma-separated or one-line-array alias values must not repeat an alias.
check_alias_duplicates() {
  local file="$1" list="$2" item seen=$'\n'
  local IFS=','
  for item in $list; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    case "$seen" in
      *$'\n'"$item"$'\n'*)
        fail "${file#"$repo_root"/} has a duplicate alias: $item"
        return 0
        ;;
    esac
    seen="$seen$item"$'\n'
  done
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
  local file="$1" allowed="$2" status
  [[ -f "$file" ]] || return 0
  [[ "$(sed -n '1p' "$file")" == '---' ]] || {
    fail "${file#"$repo_root"/} must start with YAML frontmatter"
    return 0
  }
  status="$(frontmatter_value "$file" status)"
  if [[ -z "$status" ]]; then
    fail "${file#"$repo_root"/} is missing frontmatter status"
  elif [[ "|$allowed|" != *"|$status|"* ]]; then
    fail "${file#"$repo_root"/} has invalid status: $status (allowed: $allowed)"
  fi
}

# Contract for knowledge/raw/internal records: knowledge/KNOWLEDGE.md#内部原記録のRecord形式.
validate_raw_internal_record() {
  local file="$1" name="${1##*/}" record_root="${1%%/knowledge/raw/internal/*}"
  local recorded_at kind subjects subjects_compact corrects corrects_name key
  [[ "${file#*/knowledge/raw/internal/}" == "$name" && \
     "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] || {
    fail "${file#"$repo_root"/} must be knowledge/raw/internal/YYYY-MM-DD-<lowercase-kebab>.md"
    return 0
  }
  [[ "$(sed -n '1p' "$file")" == '---' ]] || {
    fail "${file#"$repo_root"/} must start with YAML frontmatter"
    return 0
  }
  check_frontmatter_unique "$file"
  recorded_at="$(frontmatter_value "$file" recorded_at)"
  if [[ ! "$recorded_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2}))?$ ]]; then
    fail "${file#"$repo_root"/} recorded_at must be YYYY-MM-DD or ISO 8601 with timezone offset"
  elif ! datetime_is_real "$recorded_at"; then
    fail "${file#"$repo_root"/} recorded_at is not a real timestamp: $recorded_at"
  elif [[ "${name:0:10}" != "${recorded_at:0:10}" ]]; then
    fail "${file#"$repo_root"/} filename date must match recorded_at: ${recorded_at:0:10}"
  fi
  kind="$(frontmatter_value "$file" kind)"
  case "$kind" in
    instruction|decision|preference|fact|observation|hypothesis|correction) ;;
    '') fail "${file#"$repo_root"/} is missing frontmatter kind" ;;
    *) fail "${file#"$repo_root"/} has invalid kind: $kind" ;;
  esac
  subjects="$(frontmatter_value "$file" subjects)"
  subjects_compact=''
  [[ "$subjects" =~ ^\[(.*)\]$ ]] && subjects_compact="${BASH_REMATCH[1]// /}"
  if [[ -z "$subjects_compact" || "$subjects" == *$'\t'* || \
        "$subjects_compact" == ,* || "$subjects_compact" == *, || "$subjects_compact" == *,,* ]]; then
    fail "${file#"$repo_root"/} subjects must be a one-line array with at least one subject"
  fi
  corrects="$(frontmatter_value "$file" corrects)"
  if [[ "$kind" == 'correction' ]]; then
    if repo_path_is_unsafe "$corrects"; then
      fail "${file#"$repo_root"/} corrects must not traverse outside the repository: $corrects"
    elif [[ "$corrects" != knowledge/raw/internal/* || "${corrects##*/}" == '' ]]; then
      fail "${file#"$repo_root"/} correction must set corrects to a knowledge/raw/internal/ path"
    elif [[ "$record_root/$corrects" == "$file" || ! -f "$record_root/$corrects" ]]; then
      fail "${file#"$repo_root"/} corrects must point to an existing earlier record: $corrects"
    else
      corrects_name="${corrects##*/}"
      if [[ "${corrects_name:0:10}" > "${name:0:10}" ]]; then
        # A correction records something learned later; it cannot correct a
        # record dated after its own permanent-ID date.
        fail "${file#"$repo_root"/} corrects must point to an earlier record, not a later one: $corrects"
      fi
    fi
  fi
  while IFS= read -r key; do
    case "$key" in
      recorded_at|kind|subjects) ;;
      corrects) [[ "$kind" == 'correction' ]] || \
        fail "${file#"$repo_root"/} corrects is only allowed on correction records" ;;
      *) fail "${file#"$repo_root"/} has non-standard record field: $key" ;;
    esac
  done < <(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && match($0, /^[a-z][a-z0-9_-]*:/) { print substr($0, 1, RLENGTH - 1) }
  ' "$file")
}

require_headings() {
  local file="$1" label="$2" heading
  shift 2
  [[ -f "$file" ]] || return 0
  for heading in "$@"; do
    grep -Fqx "## $heading" "$file" || fail "$label is missing required heading: ## $heading"
  done
}

validate_skill_frontmatter() {
  local file="$1" status legacy_status aliases legacy_aliases key name description compatibility description_length
  [[ -f "$file" ]] || return 0
  [[ "$(sed -n '1p' "$file")" == '---' ]] || {
    fail "${file#"$repo_root"/} must start with YAML frontmatter"
    return 0
  }
  check_frontmatter_unique "$file"
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
  else
    check_alias_duplicates "$file" "$aliases"
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
  description_length="$(char_length "$description")"
  (( description_length >= 1 && description_length <= 1024 )) || \
    fail "${file#"$repo_root"/} description must be 1-1024 characters"
  (( description_length <= 200 )) || \
    warn "${file#"$repo_root"/} description exceeds the 200-character discovery recommendation"
  [[ -z "$compatibility" || "$(char_length "$compatibility")" -le 500 ]] || \
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
  local locale_skill_dir locale_output reference_fixture reference_scope_output
  local raw_record_dir raw_record_output
  local raw_git_root raw_diff_output lifecycle_root lifecycle_output
  local ownership_root ownership_output url_probe

  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-directory-tool-test.XXXXXX")"
  tool_fixture_root="$fixture_root"

  # SKILL.md length checks count characters in every locale: an in-budget Japanese
  # description must stay clean under LC_ALL=C, and an over-budget one must still warn.
  locale_skill_dir="$fixture_root/locale-skill"
  mkdir -p "$locale_skill_dir"
  printf '%s\n' '---' 'name: locale-fixture' \
    "description: $(printf '案%.0s' {1..89})" \
    'metadata:' '  agent-directory.status: "active"' '  agent-directory.aliases: ""' '---' \
    > "$locale_skill_dir/SKILL.md"
  locale_output="$( (export LC_ALL=C; validate_skill_frontmatter "$locale_skill_dir/SKILL.md") 2>&1 )"
  [[ -z "$locale_output" ]] || \
    fail "SKILL.md character checks must be locale-independent: $locale_output"
  printf '%s\n' '---' 'name: locale-fixture' \
    "description: $(printf '案%.0s' {1..201})" \
    'metadata:' '  agent-directory.status: "active"' '  agent-directory.aliases: ""' '---' \
    > "$locale_skill_dir/SKILL.md"
  locale_output="$( (export LC_ALL=C; validate_skill_frontmatter "$locale_skill_dir/SKILL.md") 2>&1 )"
  printf '%s\n' "$locale_output" | grep -Fq '200-character' || \
    fail 'SKILL.md description discovery recommendation check was lost'

  # Reference validation covers the current canon but never immutable knowledge/raw/ records.
  reference_fixture="$fixture_root/reference-scope"
  mkdir -p "$reference_fixture/knowledge/raw/internal" "$reference_fixture/knowledge/wiki/topics"
  printf '%s\n' 'See `tools/removed.md#gone`.' \
    > "$reference_fixture/knowledge/raw/internal/2026-01-01-record.md"
  printf '%s\n' 'See `tools/removed.md#gone`.' \
    > "$reference_fixture/knowledge/wiki/topics/broken.md"
  if reference_scope_output="$(bash "$repo_root/tools/validator/check-markdown-references.sh" "$reference_fixture" 2>&1)"; then
    fail 'check-markdown-references.sh missed a broken wiki reference'
  fi
  printf '%s\n' "$reference_scope_output" | grep -Fq \
    'knowledge/wiki/topics/broken.md references a missing file: tools/removed.md' || \
    fail 'check-markdown-references.sh lost the broken wiki reference failure'
  ! printf '%s\n' "$reference_scope_output" | grep -Fq 'knowledge/raw/' || \
    fail 'check-markdown-references.sh must not require resolution inside immutable knowledge/raw records'

  # raw/internal record schema: canonical decision and correction records pass,
  # and the kind allowlist still rejects a non-canonical classification.
  raw_record_dir="$fixture_root/raw-schema/knowledge/raw/internal"
  mkdir -p "$raw_record_dir"
  printf '%s\n' '---' 'recorded_at: 2026-08-20T13:01:00+09:00' 'kind: decision' \
    'subjects: [fixture, deploy]' '---' '' '# Fixture decision' \
    > "$raw_record_dir/2026-08-20-fixture-decision.md"
  printf '%s\n' '---' 'recorded_at: 2026-08-21' 'kind: correction' 'subjects: [fixture]' \
    'corrects: knowledge/raw/internal/2026-08-20-fixture-decision.md' '---' '' '# Fixture correction' \
    > "$raw_record_dir/2026-08-21-fixture-correction.md"
  raw_record_output="$( { validate_raw_internal_record "$raw_record_dir/2026-08-20-fixture-decision.md"
    validate_raw_internal_record "$raw_record_dir/2026-08-21-fixture-correction.md"; } 2>&1 )"
  [[ -z "$raw_record_output" ]] || \
    fail "canonical raw/internal records must validate cleanly: $raw_record_output"
  printf '%s\n' '---' 'recorded_at: 2026-08-22T09:00:00+09:00' 'kind: summary' 'subjects: [fixture]' '---' \
    > "$raw_record_dir/2026-08-22-invalid-kind.md"
  raw_record_output="$(validate_raw_internal_record "$raw_record_dir/2026-08-22-invalid-kind.md" 2>&1)"
  printf '%s\n' "$raw_record_output" | grep -Fq 'invalid kind' || \
    fail 'validate_raw_internal_record lost the kind allowlist check'
  rm -f "$raw_record_dir/2026-08-22-invalid-kind.md"

  # Record schema negatives: traversal in corrects, correction of a later record,
  # an unreal timestamp, and an ambiguous duplicate frontmatter key.
  printf '%s\n' '---' 'recorded_at: 2026-08-21' 'kind: correction' 'subjects: [fixture]' \
    'corrects: knowledge/raw/internal/../../../AGENTS.md' '---' \
    > "$raw_record_dir/2026-08-21-traversal.md"
  raw_record_output="$(validate_raw_internal_record "$raw_record_dir/2026-08-21-traversal.md" 2>&1)"
  printf '%s\n' "$raw_record_output" | grep -Fq 'must not traverse' || \
    fail 'validate_raw_internal_record accepted a path-traversal corrects target'
  rm -f "$raw_record_dir/2026-08-21-traversal.md"
  printf '%s\n' '---' 'recorded_at: 2026-08-30' 'kind: decision' 'subjects: [fixture]' '---' \
    > "$raw_record_dir/2026-08-30-later-decision.md"
  printf '%s\n' '---' 'recorded_at: 2026-08-21' 'kind: correction' 'subjects: [fixture]' \
    'corrects: knowledge/raw/internal/2026-08-30-later-decision.md' '---' \
    > "$raw_record_dir/2026-08-21-future-correction.md"
  raw_record_output="$(validate_raw_internal_record "$raw_record_dir/2026-08-21-future-correction.md" 2>&1)"
  printf '%s\n' "$raw_record_output" | grep -Fq 'earlier record, not a later one' || \
    fail 'validate_raw_internal_record accepted a correction of a later record'
  rm -f "$raw_record_dir/2026-08-30-later-decision.md" "$raw_record_dir/2026-08-21-future-correction.md"
  printf '%s\n' '---' 'recorded_at: 2026-99-99T99:99:99+99:99' 'kind: decision' 'subjects: [fixture]' '---' \
    > "$raw_record_dir/2026-99-99-unreal-date.md"
  raw_record_output="$(validate_raw_internal_record "$raw_record_dir/2026-99-99-unreal-date.md" 2>&1)"
  printf '%s\n' "$raw_record_output" | grep -Fq 'not a real timestamp' || \
    fail 'validate_raw_internal_record accepted an unreal recorded_at timestamp'
  rm -f "$raw_record_dir/2026-99-99-unreal-date.md"
  printf '%s\n' '---' 'recorded_at: 2026-08-23' 'kind: decision' 'kind: fact' 'subjects: [fixture]' '---' \
    > "$raw_record_dir/2026-08-23-duplicate-key.md"
  raw_record_output="$(validate_raw_internal_record "$raw_record_dir/2026-08-23-duplicate-key.md" 2>&1)"
  printf '%s\n' "$raw_record_output" | grep -Fq 'duplicate frontmatter key' || \
    fail 'validate_raw_internal_record accepted a duplicate frontmatter key'
  rm -f "$raw_record_dir/2026-08-23-duplicate-key.md"

  # Immutable raw enforcement over committed history: modification, deletion, and
  # rename against a base revision must fail; the erasure exception permits
  # deletion only.
  raw_git_root="$fixture_root/raw-immutability"
  mkdir -p "$raw_git_root/knowledge/raw/internal"
  git -C "$raw_git_root" init -q
  git -C "$raw_git_root" config user.name 'Agent Directory Fixture'
  git -C "$raw_git_root" config user.email 'fixture@example.invalid'
  printf '%s\n' '---' 'recorded_at: 2026-08-01' 'kind: fact' 'subjects: [fixture]' '---' 'Original.' \
    > "$raw_git_root/knowledge/raw/internal/2026-08-01-immutable.md"
  git -C "$raw_git_root" add -A
  git -C "$raw_git_root" commit -qm 'Add immutable record'
  printf 'Tampered.\n' >> "$raw_git_root/knowledge/raw/internal/2026-08-01-immutable.md"
  raw_diff_output="$( (check_raw_tree_diff "$raw_git_root" HEAD) 2>&1 )"
  printf '%s\n' "$raw_diff_output" | grep -Fq 'modified, deleted or renamed' || \
    fail 'check_raw_tree_diff accepted a committed raw record modification'
  raw_diff_output="$( (AGENT_ALLOW_RAW_ERASURE=true check_raw_tree_diff "$raw_git_root" HEAD) 2>&1 )"
  printf '%s\n' "$raw_diff_output" | grep -Fq 'modified, deleted or renamed' || \
    fail 'the erasure exception must not allow raw record modification'
  git -C "$raw_git_root" checkout -q -- .
  git -C "$raw_git_root" mv knowledge/raw/internal/2026-08-01-immutable.md \
    knowledge/raw/internal/2026-08-01-renamed.md
  raw_diff_output="$( (check_raw_tree_diff "$raw_git_root" HEAD) 2>&1 )"
  printf '%s\n' "$raw_diff_output" | grep -Fq 'modified, deleted or renamed' || \
    fail 'check_raw_tree_diff accepted a raw record rename'
  git -C "$raw_git_root" mv knowledge/raw/internal/2026-08-01-renamed.md \
    knowledge/raw/internal/2026-08-01-immutable.md
  rm "$raw_git_root/knowledge/raw/internal/2026-08-01-immutable.md"
  git -C "$raw_git_root" add -A
  raw_diff_output="$( (check_raw_tree_diff "$raw_git_root" HEAD) 2>&1 )"
  printf '%s\n' "$raw_diff_output" | grep -Fq 'modified, deleted or renamed' || \
    fail 'check_raw_tree_diff accepted a raw record deletion'
  raw_diff_output="$( (AGENT_ALLOW_RAW_ERASURE=true check_raw_tree_diff "$raw_git_root" HEAD) 2>&1 )"
  [[ -z "$raw_diff_output" ]] || \
    fail "the erasure exception must allow a pure raw deletion: $raw_diff_output"

  # Lifecycle enforcement against a base revision: paused Projects reject normal
  # work, and Project deletion requires the committed base-side gate.
  lifecycle_root="$fixture_root/lifecycle"
  mkdir -p "$lifecycle_root/projects/frozen/outputs" "$lifecycle_root/projects/sunset"
  git -C "$lifecycle_root" init -q
  git -C "$lifecycle_root" config user.name 'Agent Directory Fixture'
  git -C "$lifecycle_root" config user.email 'fixture@example.invalid'
  printf '%s\n' '---' 'name: frozen' 'description: Paused fixture Project' 'status: paused' \
    'mode: finite' '---' '# frozen' > "$lifecycle_root/projects/frozen/PROJECT.md"
  printf '%s\n' '---' 'updated_at: 2026-08-01' '---' '# State' > "$lifecycle_root/projects/frozen/STATE.md"
  printf 'artifact\n' > "$lifecycle_root/projects/frozen/outputs/report.md"
  printf '%s\n' '---' 'name: sunset' 'description: Retired fixture Project' 'status: retired' \
    'mode: finite' 'deletion_approved: true' 'artifacts_retained_at: none' '---' '# sunset' \
    > "$lifecycle_root/projects/sunset/PROJECT.md"
  printf '%s\n' '---' 'updated_at: 2026-08-01' '---' '# State' > "$lifecycle_root/projects/sunset/STATE.md"
  git -C "$lifecycle_root" add -A
  git -C "$lifecycle_root" commit -qm 'Add lifecycle fixture projects'
  printf 'more\n' >> "$lifecycle_root/projects/frozen/outputs/report.md"
  lifecycle_output="$( (check_lifecycle_diff "$lifecycle_root" HEAD) 2>&1 )"
  printf '%s\n' "$lifecycle_output" | grep -Fq 'was paused at HEAD' || \
    fail 'check_lifecycle_diff accepted normal work in a paused Project'
  git -C "$lifecycle_root" checkout -q -- .
  printf '%s\n' '---' 'updated_at: 2026-08-02' '---' '# State' > "$lifecycle_root/projects/frozen/STATE.md"
  lifecycle_output="$( (check_lifecycle_diff "$lifecycle_root" HEAD) 2>&1 )"
  [[ -z "$lifecycle_output" ]] || \
    fail "check_lifecycle_diff rejected a state transition edit: $lifecycle_output"
  git -C "$lifecycle_root" checkout -q -- .
  rm -rf "$lifecycle_root/projects/frozen"
  lifecycle_output="$( (check_lifecycle_diff "$lifecycle_root" HEAD) 2>&1 )"
  printf '%s\n' "$lifecycle_output" | grep -Fq 'requires base status retired' || \
    fail 'check_lifecycle_diff accepted deleting a Project that was not retired'
  git -C "$lifecycle_root" checkout -q -- .
  rm -rf "$lifecycle_root/projects/sunset"
  lifecycle_output="$( (check_lifecycle_diff "$lifecycle_root" HEAD) 2>&1 )"
  [[ -z "$lifecycle_output" ]] || \
    fail "check_lifecycle_diff rejected a gated Project deletion: $lifecycle_output"
  git -C "$lifecycle_root" checkout -q -- .

  # Canonical Ownership: dual ownership by root Git and an unregistered nested
  # Project Git are both violations.
  ownership_root="$fixture_root/ownership"
  mkdir -p "$ownership_root/projects/owned" "$ownership_root/projects/rogue"
  git -C "$ownership_root" init -q
  git -C "$ownership_root" config user.name 'Agent Directory Fixture'
  git -C "$ownership_root" config user.email 'fixture@example.invalid'
  printf '%s\n' '# Independent repositories' '' '## `owned`' \
    '- repository_url: `git@example.invalid:fixture/owned.git`' \
    '- repository_reason: `distribution`' \
    "- revision: \`$(printf 'a%.0s' {1..40})\`" > "$ownership_root/projects/REPOSITORIES.md"
  printf '%s\n' '# BEGIN INDEPENDENT PROJECTS' '/owned/' '# END INDEPENDENT PROJECTS' \
    > "$ownership_root/projects/.gitignore"
  printf 'duplicated\n' > "$ownership_root/projects/owned/PROJECT.md"
  git -C "$ownership_root" add -A -f
  git -C "$ownership_root" commit -qm 'Add dual-ownership fixture'
  git -C "$ownership_root" -c init.defaultBranch=main init -q "$ownership_root/projects/rogue"
  ownership_output="$( (check_independent_ownership "$ownership_root") 2>&1 )"
  printf '%s\n' "$ownership_output" | grep -Fq 'dual ownership' || \
    fail 'check_independent_ownership accepted root-tracked files inside an Independent Project'
  printf '%s\n' "$ownership_output" | grep -Fq 'not registered in projects/REPOSITORIES.md' || \
    fail 'check_independent_ownership accepted an unregistered nested Project Git'

  # Repository URL contract: canonical shapes pass, credential-bearing and
  # non-canonical URLs are rejected.
  for url_probe in 'git@example.com:owner/repo.git' 'ssh://git@example.com/owner/repo.git' \
    'https://example.com/owner/repo.git'; do
    agent_repository_url_is_rejected "$url_probe" && \
      fail "agent_repository_url_is_rejected rejected a canonical URL shape: $url_probe"
  done
  for url_probe in 'https://token@example.com/owner/repo.git' \
    'https://user:pass@example.com/owner/repo.git' 'ssh://git:pass@example.com/owner/repo.git' \
    'https://example.com/owner/repo.git?token=x' 'https://example.com/owner/repo.git#frag' \
    'git://example.com/owner/repo.git' 'file:///srv/repo.git' 'http://example.com/owner/repo.git' \
    '/srv/local/repo.git' '../relative/repo' 'https://example.com' 'git@example.com:/abs/path'; do
    agent_repository_url_is_rejected "$url_probe" || \
      fail 'agent_repository_url_is_rejected accepted a forbidden repository URL'
  done

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
  page_basename="${page##*/}"
  [[ "$page_basename" =~ ^[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] || \
    fail "${page#"$repo_root"/} must use a lowercase-kebab page name"
  validate_status_file "$page" 'active|superseded|archived|retired'
  [[ "$(sed -n '1p' "$page")" != '---' ]] || check_frontmatter_unique "$page"
  page_summary="$(frontmatter_value "$page" summary)"
  if [[ -z "$page_summary" ]]; then
    fail "${page#"$repo_root"/} is missing frontmatter summary"
  elif [[ "$page_summary" == *$'\t'* ]] || (( $(char_length "$page_summary") > 200 )); then
    fail "${page#"$repo_root"/} summary must be a tab-free line of at most 200 characters"
  fi
  page_aliases="$(frontmatter_value "$page" aliases)"
  if ! frontmatter_has_key "$page" aliases; then
    fail "${page#"$repo_root"/} is missing frontmatter aliases"
  elif [[ ! "$page_aliases" =~ ^\[.*\]$ || "$page_aliases" == *$'\t'* ]]; then
    fail "${page#"$repo_root"/} aliases must be a tab-free one-line array"
  else
    check_alias_duplicates "$page" "${page_aliases:1:$(( ${#page_aliases} - 2 ))}"
  fi
  page_review_after="$(frontmatter_value "$page" review_after)"
  if frontmatter_has_key "$page" review_after; then
    if [[ ! "$page_review_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date_is_real "$page_review_after"; then
      fail "${page#"$repo_root"/} review_after must be a real YYYY-MM-DD date"
    fi
  fi
  if [[ "$page" == "$repo_root/knowledge/wiki/sources/"* ]]; then
    page_source="$(frontmatter_value "$page" source)"
    if repo_path_is_unsafe "$page_source"; then
      fail "${page#"$repo_root"/} source must not traverse outside the repository: $page_source"
    elif [[ "$page_source" != knowledge/raw/internal/* && "$page_source" != knowledge/raw/external/* ]]; then
      fail "${page#"$repo_root"/} source must be a repository-relative path under knowledge/raw/"
    elif [[ ! -f "$repo_root/$page_source" ]]; then
      fail "${page#"$repo_root"/} source raw record does not exist: $page_source"
    fi
  fi
  if [[ "$(frontmatter_value "$page" status)" == 'superseded' ]]; then
    replacement="$(frontmatter_value "$page" superseded_by)"
    if [[ -z "$replacement" ]]; then
      fail "${page#"$repo_root"/} superseded page is missing superseded_by"
    elif repo_path_is_unsafe "$replacement" || \
      [[ "$replacement" != knowledge/wiki/sources/*.md && "$replacement" != knowledge/wiki/topics/*.md ]]; then
      fail "${page#"$repo_root"/} superseded_by must stay under knowledge/wiki/sources/ or knowledge/wiki/topics/: $replacement"
    elif [[ ! -f "$repo_root/$replacement" ]]; then
      fail "${page#"$repo_root"/} superseded_by must be a repository-relative path to an existing page: $replacement"
    elif [[ "$(frontmatter_value "$repo_root/$replacement" status)" != 'active' ]]; then
      fail "${page#"$repo_root"/} superseded_by page is not active: $replacement"
    fi
  fi
  bytes="$(wc -c < "$page" | tr -d ' ')"
  if (( bytes > 24576 )); then
    grep -Fqx '## Retrieval Map' "$page" || fail "${page#"$repo_root"/} exceeds 24KiB without a Retrieval Map"
  fi
  (( bytes <= 65536 )) || fail "${page#"$repo_root"/} exceeds 64KiB"
done < <(find "$repo_root/knowledge/wiki/sources" "$repo_root/knowledge/wiki/topics" -type f -name '*.md' -print0)

index_entries="$(grep -c '^- ' "$repo_root/knowledge/wiki/INDEX.md" 2>/dev/null || true)"
[[ -z "$index_entries" ]] || (( index_entries <= 50 )) || \
  fail "knowledge/wiki/INDEX.md exceeds the 50-entry limit: $index_entries entries"

while IFS= read -r -d '' record; do
  validate_raw_internal_record "$record"
done < <(find "$repo_root/knowledge/raw/internal" -mindepth 1 \
  -not -name '.gitkeep' -not -name '.DS_Store' -print0)

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
      [[ -n "$replacement_status" ]] || \
        replacement_status="$(frontmatter_value "$repo_root/skills/$replacement/SKILL.md" status)"
      # Replacements must be active, so deprecated chains can neither dangle nor cycle.
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
    validate_status_file "$project_dir/PROJECT.md" 'active|paused|completed|retired'
    project_status=''
    project_pc_ids=$'\n'
    if [[ -f "$project_dir/PROJECT.md" ]]; then
      check_frontmatter_unique "$project_dir/PROJECT.md"
      [[ "$(frontmatter_value "$project_dir/PROJECT.md" name)" == "$project_name" ]] || \
        fail "projects/$project_name/PROJECT.md name must match its directory"
      project_description="$(frontmatter_value "$project_dir/PROJECT.md" description)"
      if [[ -z "$project_description" ]]; then
        fail "projects/$project_name/PROJECT.md is missing frontmatter description"
      elif [[ "$project_description" == *$'\t'* ]] || (( $(char_length "$project_description") > 200 )); then
        fail "projects/$project_name/PROJECT.md description must be a tab-free line of at most 200 characters"
      fi
      while IFS= read -r pc_line; do
        [[ -n "$pc_line" ]] || continue
        if [[ ! "$pc_line" =~ ^-\ \*\*(PC-[0-9]{2,})\*\*\ .+$ ]]; then
          fail "projects/$project_name/PROJECT.md has an invalid PC-ID line: $pc_line"
          continue
        fi
        pc_id="${BASH_REMATCH[1]}"
        case "$project_pc_ids" in
          *$'\n'"$pc_id"$'\n'*) fail "projects/$project_name/PROJECT.md has a duplicate PC-ID: $pc_id" ;;
        esac
        project_pc_ids="$project_pc_ids$pc_id"$'\n'
      done < <(grep -E '^- \*\*PC-' "$project_dir/PROJECT.md" || true)
      project_status="$(frontmatter_value "$project_dir/PROJECT.md" status)"
      project_mode="$(frontmatter_value "$project_dir/PROJECT.md" mode)"
      case "$project_mode" in
        finite)
          require_headings "$project_dir/PROJECT.md" "projects/$project_name/PROJECT.md" \
            最終ゴール 完了条件 ;;
        continuous)
          require_headings "$project_dir/PROJECT.md" "projects/$project_name/PROJECT.md" \
            継続的使命 成功指標 見直し・終了条件
          [[ "$project_status" != 'completed' ]] || \
            fail "projects/$project_name/PROJECT.md is continuous and must not use status completed" ;;
        '') fail "projects/$project_name/PROJECT.md is missing frontmatter mode" ;;
        *) fail "projects/$project_name/PROJECT.md has invalid mode: $project_mode" ;;
      esac
      require_headings "$project_dir/PROJECT.md" "projects/$project_name/PROJECT.md" \
        目的 判断原則 非ゴール 制約・固定決定 品質基準 入力 使用するKnowledge 使用するSkill 成果物 検証方法
    fi
    if [[ -f "$project_dir/STATE.md" ]]; then
      check_frontmatter_unique "$project_dir/STATE.md"
      require_headings "$project_dir/STATE.md" "projects/$project_name/STATE.md" \
        現在の到達点 現在の目標 目標の合格条件 検証結果 未完了・ブロッカー 現在有効な決定 失敗・却下済み 次の一手
      check_size "projects/$project_name/STATE.md" 8192 "projects/$project_name/STATE.md"
      while IFS= read -r state_pc; do
        [[ -n "$state_pc" ]] || continue
        case "$project_pc_ids" in
          *$'\n'"${state_pc#PROJECT.md#}"$'\n'*) ;;
          *) fail "projects/$project_name/STATE.md targets a PC-ID that PROJECT.md does not define: $state_pc" ;;
        esac
      done < <(grep -oE 'PROJECT\.md#PC-[0-9]+' "$project_dir/STATE.md" | LC_ALL=C sort -u || true)
      if [[ "$project_status" == 'completed' ]]; then
        grep -Fq '対象契約: `PROJECT.md#status`' "$project_dir/STATE.md" || \
          fail "projects/$project_name/STATE.md must target PROJECT.md#status for a completed Project"
      fi
    fi
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

# Immutable raw sources: only additions may appear between the given revision and the
# working tree. Deletion is tolerated only under the canonical privacy/security erasure
# exception (knowledge/KNOWLEDGE.md#Secret・privacy削除の限定例外), which the operator
# asserts explicitly with AGENT_ALLOW_RAW_ERASURE=true; modification and rename stay
# rejected even then because raw paths are permanent IDs.
check_raw_tree_diff() {
  local root="$1" base="$2" allow_erasure="${AGENT_ALLOW_RAW_ERASURE:-false}" raw_mutations
  raw_mutations="$(git -C "$root" diff --name-status -M "$base" -- knowledge/raw | \
    LC_ALL=C awk -v allow_erasure="$allow_erasure" '
      $1 == "A" { next }
      $1 == "D" && allow_erasure == "true" { next }
      { print }
    ')"
  if [[ -n "$raw_mutations" ]]; then
    fail "immutable knowledge/raw records are modified, deleted or renamed against $base"
    printf '%s\n' "$raw_mutations" >&2
  fi
}

# Deleting a Project requires the base-side gate of projects/LIFECYCLE.md#削除:
# a retired status, a committed deletion approval, an artifact retention target, and
# zero remaining references from the current canon (immutable raw records excluded).
check_project_deletion_gate() {
  local root="$1" base="$2" name="$3"
  local base_status approved retained references label="projects/$name deletion against $base"
  base_status="$(git -C "$root" show "$base:projects/$name/PROJECT.md" 2>/dev/null | \
    frontmatter_value /dev/stdin status)"
  [[ "$base_status" == 'retired' ]] || \
    fail "$label requires base status retired, found: ${base_status:-<missing>}"
  approved="$(git -C "$root" show "$base:projects/$name/PROJECT.md" 2>/dev/null | \
    frontmatter_value /dev/stdin deletion_approved)"
  [[ "$approved" == 'true' ]] || \
    fail "$label requires a committed deletion_approved: true"
  retained="$(git -C "$root" show "$base:projects/$name/PROJECT.md" 2>/dev/null | \
    frontmatter_value /dev/stdin artifacts_retained_at)"
  if [[ -z "$retained" ]]; then
    fail "$label requires artifacts_retained_at: <repository-relative-path> or none"
  elif [[ "$retained" == 'none' ]]; then
    if [[ -n "$(git -C "$root" ls-tree -r --name-only "$base" -- "projects/$name/outputs" 2>/dev/null)" ]]; then
      fail "$label declares artifacts_retained_at: none but tracked outputs/ existed at $base"
    fi
  elif repo_path_is_unsafe "$retained" || [[ ! -e "$root/$retained" ]]; then
    fail "$label artifacts_retained_at must be an existing repository-relative path: $retained"
  fi
  references="$(git -C "$root" grep -l -F "projects/$name" -- '*.md' 2>/dev/null | \
    grep -v '^knowledge/raw/' || true)"
  if [[ -n "$references" ]]; then
    fail "$label requires zero remaining references to projects/$name"
    printf '%s\n' "$references" >&2
  fi
}

# Base-aware lifecycle enforcement: a Project that was paused or retired at the base
# revision only accepts PROJECT.md / STATE.md state-transition edits, and a Project
# removed since the base revision must pass the deletion gate. Independent Projects
# are invisible to the root tree here; their lifecycle lives in their own Git.
check_lifecycle_diff() {
  local root="$1" base="$2" name base_status disallowed
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != '_template' ]] || continue
    git -C "$root" cat-file -e "$base:projects/$name/PROJECT.md" 2>/dev/null || continue
    if [[ ! -e "$root/projects/$name" ]]; then
      check_project_deletion_gate "$root" "$base" "$name"
      continue
    fi
    base_status="$(git -C "$root" show "$base:projects/$name/PROJECT.md" | \
      frontmatter_value /dev/stdin status)"
    case "$base_status" in
      paused|retired)
        disallowed="$(git -C "$root" diff --name-only "$base" -- "projects/$name/" | \
          LC_ALL=C awk -v prefix="projects/$name/" '
            index($0, prefix) == 1 {
              rest = substr($0, length(prefix) + 1)
              if (rest != "PROJECT.md" && rest != "STATE.md") print
            }
          ')"
        if [[ -n "$disallowed" ]]; then
          fail "projects/$name was $base_status at $base; only PROJECT.md / STATE.md state transitions may change"
          printf '%s\n' "$disallowed" >&2
        fi
        ;;
    esac
  done < <(git -C "$root" ls-tree --name-only "$base:projects" 2>/dev/null)
}

# Canonical Ownership: registry entries must be structurally valid, the root Git must
# not track any file inside a registered Independent Project, and a Project carrying
# its own .git/ must be registered. One Project, one owning Git.
check_independent_ownership() {
  local root="$1"
  local registry="$root/projects/REPOSITORIES.md"
  local record_kind field_a field_b field_c field_d field_e entry_error
  local registered_names=$'\n' name tracked_inside project_dir
  [[ -f "$registry" ]] || return 0
  while IFS=$'\t' read -r record_kind field_a field_b field_c field_d field_e; do
    [[ -n "$record_kind" ]] || continue
    if [[ "$record_kind" == 'E' ]]; then
      fail "projects/REPOSITORIES.md: $field_a"
      continue
    fi
    entry_error="$(agent_registry_entry_error "$field_a" "$field_b" "$field_c" "$field_d" "$field_e" \
      "${AGENT_ALLOW_LOCAL_REPOSITORY_URL:-false}")"
    [[ -z "$entry_error" ]] || fail "projects/REPOSITORIES.md: $entry_error"
    registered_names="$registered_names$field_a"$'\n'
  done < <(agent_registry_records "$registry")
  if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      tracked_inside="$(git -C "$root" ls-files -- "projects/$name/" | head -n 5)"
      if [[ -n "$tracked_inside" ]]; then
        fail "root Git must not track files inside Independent projects/$name (dual ownership)"
        printf '%s\n' "$tracked_inside" >&2
      fi
    done <<<"$registered_names"
  fi
  for project_dir in "$root"/projects/*; do
    [[ -d "$project_dir" ]] || continue
    name="${project_dir##*/}"
    [[ "$name" != '_template' && -d "$project_dir/.git" ]] || continue
    case "$registered_names" in
      *$'\n'"$name"$'\n'*) ;;
      *) fail "projects/$name has its own .git but is not registered in projects/REPOSITORIES.md" ;;
    esac
  done
}

check_independent_ownership "$repo_root"

if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  tracked_forbidden=''
  while IFS= read -r tracked_path; do
    [[ -n "$tracked_path" && -e "$repo_root/$tracked_path" ]] || continue
    tracked_forbidden="${tracked_forbidden}${tracked_path}\n"
  done < <(git -C "$repo_root" ls-files | grep -E '(^|/)(\.env($|\.)|\.DS_Store$|\.tmp/|__pycache__/)' || true)
  [[ -z "$tracked_forbidden" ]] || fail "forbidden generated or secret-bearing paths are tracked"

  # Deterministic high-confidence secret check: a tracked private key block is always a
  # violation. Anything subtler than path and key-block detection stays owned by
  # Runtime / Operator review (tools/SAFETY.md).
  tracked_private_keys="$(git -C "$repo_root" grep -lE -e \
    '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----$' 2>/dev/null || true)"
  if [[ -n "$tracked_private_keys" ]]; then
    fail 'tracked files contain a private key block'
    printf '%s\n' "$tracked_private_keys" >&2
  fi

  if git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    check_raw_tree_diff "$repo_root" HEAD
  fi

  if [[ -n "$base_ref" ]]; then
    if ! git -C "$repo_root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null 2>&1; then
      fail "--base does not resolve to a commit: $base_ref"
    else
      check_raw_tree_diff "$repo_root" "$base_ref"
      check_lifecycle_diff "$repo_root" "$base_ref"
    fi
  fi
elif [[ -n "$base_ref" ]]; then
  fail '--base requires a Git working tree'
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

printf 'PASS: agent-directory structure is valid (%s warning(s))\n' "$warnings"
