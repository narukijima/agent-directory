#!/usr/bin/env bash
set -euo pipefail

# Exercise root-router budgets and STATE target parsing independently of the
# validator implementation. Usage: test-router-boundaries.sh <repository-root>

if (( $# != 1 )) || [[ ! -f "$1/AGENTS.md" ]]; then
  printf 'Usage: %s <repository-root>\n' "${0##*/}" >&2
  exit 2
fi

repo_root="$(cd "$1" && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-router-boundaries.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
  printf 'ROUTER_BOUNDARIES_BLOCKED reason=%s\n' "$1" >&2
  exit 1
}

router_bytes() {
  local file="$1"
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

state_targets() {
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

write_agents_fixture() {
  local identity_file="$1"
  local output_file="$2"
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

placeholder_identity="$fixture_dir/placeholder-identity.md"
deployed_identity="$fixture_dir/deployed-identity.md"
placeholder_agents="$fixture_dir/placeholder-AGENTS.md"
deployed_agents="$fixture_dir/deployed-AGENTS.md"

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

deployed_identity_bytes="$(wc -c < "$deployed_identity" | tr -d ' ')"
(( deployed_identity_bytes >= 1024 && deployed_identity_bytes <= 1536 )) || \
  fail "realistic-identity-size-${deployed_identity_bytes}"

write_agents_fixture "$placeholder_identity" "$placeholder_agents"
write_agents_fixture "$deployed_identity" "$deployed_agents"

placeholder_router_bytes="$(router_bytes "$placeholder_agents")"
deployed_router_bytes="$(router_bytes "$deployed_agents")"
[[ "$placeholder_router_bytes" == "$deployed_router_bytes" ]] || fail 'identity-changed-router-metric'
(( placeholder_router_bytes <= 6144 )) || fail 'placeholder-router-soft-budget'
(( deployed_router_bytes <= 6144 )) || fail 'deployed-router-soft-budget'

adopter_agents="$fixture_dir/adopter-extension-AGENTS.md"
cp "$placeholder_agents" "$adopter_agents"
printf '\n## 導入先固有契約\n\n- 通常の固有契約を一文追加してもrouter warningを発生させない。\n' >> \
  "$adopter_agents"
(( $(router_bytes "$adopter_agents") <= 6144 )) || fail 'adopter-headroom'

router_overflow="$fixture_dir/router-overflow-AGENTS.md"
cp "$placeholder_agents" "$router_overflow"
awk 'BEGIN { printf "\n## Router overflow\n\n"; for (i = 0; i < 6200; i++) printf "x"; printf "\n" }' >> \
  "$router_overflow"
(( $(router_bytes "$router_overflow") > 6144 )) || fail 'router-overflow-not-detected'

hard_overflow="$fixture_dir/hard-overflow-AGENTS.md"
cp "$deployed_agents" "$hard_overflow"
awk 'BEGIN { for (i = 0; i < 8193; i++) printf "h"; printf "\n" }' >> "$hard_overflow"
(( $(wc -c < "$hard_overflow" | tr -d ' ') > 8192 )) || fail 'hard-overflow-not-detected'

placeholder_crlf="$fixture_dir/placeholder-crlf.md"
deployed_crlf="$fixture_dir/deployed-crlf.md"
awk '{ printf "%s\r\n", $0 }' "$placeholder_agents" > "$placeholder_crlf"
awk '{ printf "%s\r\n", $0 }' "$deployed_agents" > "$deployed_crlf"
[[ "$(router_bytes "$placeholder_crlf")" == "$(router_bytes "$deployed_crlf")" ]] || \
  fail 'crlf-identity-boundary'

eof_prefix="$fixture_dir/eof-prefix.md"
eof_identity="$fixture_dir/eof-identity.md"
printf '# Router\n\n## Route\n\nroute\n\n' > "$eof_prefix"
cp "$eof_prefix" "$eof_identity"
printf '## 自己定義\n\nidentity at EOF without a following H2' >> "$eof_identity"
[[ "$(router_bytes "$eof_identity")" == "$(wc -c < "$eof_prefix" | tr -d ' ')" ]] || \
  fail 'eof-identity-boundary'

state_fixture="$fixture_dir/state-anchor-suffix.md"
printf '%s\n' \
  '## 現在の目標' \
  '対象契約: `PROJECT.md#PC-01`（週次の公開を継続する）' \
  '' \
  '## 検証結果' \
  '- 対象: `PROJECT.md#PC-01` — 検証済み' \
  > "$state_fixture"
[[ "$(state_targets "$state_fixture" '## 現在の目標' '対象契約: `PROJECT.md#')" == 'PC-01' ]] || \
  fail 'current-target-anchor-suffix'
[[ "$(state_targets "$state_fixture" '## 検証結果' '- 対象: `PROJECT.md#')" == 'PC-01' ]] || \
  fail 'verification-anchor-suffix'

printf 'ROUTER_BOUNDARIES_OK checks=10\n'
