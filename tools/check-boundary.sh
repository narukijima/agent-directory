#!/bin/bash
# tools/check-boundary.sh — commit・push境界のPortable Verifier。
# tools/control-policy.tsv を正本として差分を判定する。意味論は tools/CONTROL.md が所有する。
# stdoutの1行が機械可読結果、stderrのDETAIL:が人間向け補足。ネットワークへ接続しない。
# 執行時はhookが .git/agent-control/ の承認済みsnapshotを実行する（working tree版ではない）。
set -euo pipefail

usage() {
  printf 'Usage: %s [--staged | --base <git-ref> | --range <old> <new>] [--policy <file>] [--path-prefix <prefix>]\n' "${0##*/}" >&2
}

blocked() {
  # $1=reason $2=violation count
  printf 'BOUNDARY_BLOCKED reason=%s paths=%s\n' "$1" "$2"
  exit 1
}

mode='staged'
base_ref=''
range_old=''
range_new=''
policy_file=''
path_prefix=''
while (( $# > 0 )); do
  case "$1" in
    --staged) mode='staged'; shift ;;
    --base)
      mode='base'
      base_ref="${2:-}"
      if [[ -z "$base_ref" ]]; then usage; exit 2; fi
      shift 2
      ;;
    --range)
      mode='range'
      range_old="${2:-}"
      range_new="${3:-}"
      if [[ -z "$range_old" || -z "$range_new" ]]; then usage; exit 2; fi
      shift 3
      ;;
    --policy)
      policy_file="${2:-}"
      if [[ -z "$policy_file" ]]; then usage; exit 2; fi
      shift 2
      ;;
    --path-prefix)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      path_prefix="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# rootの決定と固定: 環境変数のrootとcwdのGit rootが両方見えて食い違うなら、
# 判定の転送（別リポジトリを検査させる迂回）として拒否する。
env_root="${AGENT_DIRECTORY_ROOT:-}"
cwd_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$env_root" && -n "$cwd_root" ]]; then
  env_root_physical="$(cd "$env_root" 2>/dev/null && pwd -P || true)"
  cwd_root_physical="$(cd "$cwd_root" && pwd -P)"
  if [[ -z "$env_root_physical" || "$env_root_physical" != "$cwd_root_physical" ]]; then
    printf 'DETAIL: AGENT_DIRECTORY_ROOT (%s) does not match the working Git root (%s)\n' \
      "$env_root" "$cwd_root" >&2
    blocked 'root-mismatch' 0
  fi
fi
repo_root="${env_root:-$cwd_root}"
if [[ -z "$repo_root" ]]; then
  printf 'DETAIL: run inside a Git repository or set AGENT_DIRECTORY_ROOT\n' >&2
  blocked 'not-a-git-repository' 0
fi

[[ -n "$policy_file" ]] || policy_file="$repo_root/tools/control-policy.tsv"
if [[ ! -f "$policy_file" ]]; then
  printf 'DETAIL: %s not found\n' "$policy_file" >&2
  blocked 'missing-policy' 0
fi

# policyを先勝ち順の平行配列へ読む（bash 3.2: 連想配列不可）。
tiers=()
patterns=()
policy_line=0
while IFS=$'\t' read -r tier pattern _note; do
  policy_line=$((policy_line + 1))
  case "$tier" in ''|'#'*) continue ;; esac
  case "$tier" in
    exempt|forbidden|frozen|guarded|contract) ;;
    *)
      printf 'DETAIL: line %d has an unknown tier: %s\n' "$policy_line" "$tier" >&2
      blocked 'invalid-policy' 0
      ;;
  esac
  if [[ -z "$pattern" ]]; then
    printf 'DETAIL: line %d has no pattern\n' "$policy_line" >&2
    blocked 'invalid-policy' 0
  fi
  tiers+=("$tier")
  patterns+=("$pattern")
done < "$policy_file"

# A staged policy is diagnostic input only. The approved policy above remains the sole
# source of the verdict. When a policy addition and its newly guarded file are staged
# together, this lets mixed-scope explain the HEAD-snapshot gap without trusting the
# unapproved candidate policy for enforcement.
staged_policy_valid=false
staged_tiers=()
staged_patterns=()
if [[ "$mode" == 'staged' ]] && \
   git -C "$repo_root" diff --cached --name-only -- tools/control-policy.tsv | \
     grep -Fqx 'tools/control-policy.tsv'; then
  staged_policy_valid=true
  while IFS=$'\t' read -r staged_tier staged_pattern _staged_note; do
    case "$staged_tier" in ''|'#'*) continue ;; esac
    case "$staged_tier" in
      exempt|forbidden|frozen|guarded|contract) ;;
      *) staged_policy_valid=false; break ;;
    esac
    if [[ -z "$staged_pattern" ]]; then
      staged_policy_valid=false
      break
    fi
    staged_tiers+=("$staged_tier")
    staged_patterns+=("$staged_pattern")
  done < <(git -C "$repo_root" show :tools/control-policy.tsv 2>/dev/null || true)
fi

tier_for() {
  # $1=repo相対path（path-prefix適用済み）。最初に一致した行のtierを返す（一致なしはnone）。
  local path="$1" i
  if (( ${#patterns[@]} == 0 )); then
    printf 'none'
    return 0
  fi
  for (( i = 0; i < ${#patterns[@]}; i++ )); do
    # shellcheck disable=SC2254 # patternはpolicy正本のglobとして展開する
    case "$path" in
      ${patterns[$i]}) printf '%s' "${tiers[$i]}"; return 0 ;;
    esac
  done
  printf 'none'
}

staged_tier_for() {
  local path="$1" i
  if [[ "$staged_policy_valid" != true || ${#staged_patterns[@]} == 0 ]]; then
    printf 'none'
    return 0
  fi
  for (( i = 0; i < ${#staged_patterns[@]}; i++ )); do
    # shellcheck disable=SC2254 # staged candidate is parsed only for a non-authoritative diagnostic
    case "$path" in
      ${staged_patterns[$i]}) printf '%s' "${staged_tiers[$i]}"; return 0 ;;
    esac
  done
  printf 'none'
}

case "$mode" in
  base)
    if ! git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
      printf 'DETAIL: base ref does not resolve to a commit: %s\n' "$base_ref" >&2
      blocked 'invalid-base' 0
    fi
    diff_output="$(git -C "$repo_root" diff --name-status -M "$base_ref" --)"
    ;;
  range)
    for range_ref in "$range_old" "$range_new"; do
      if ! git -C "$repo_root" rev-parse --verify "$range_ref^{tree}" >/dev/null 2>&1; then
        printf 'DETAIL: range ref does not resolve: %s\n' "$range_ref" >&2
        blocked 'invalid-base' 0
      fi
    done
    diff_output="$(git -C "$repo_root" diff --name-status -M "$range_old" "$range_new" --)"
    ;;
  *)
    diff_output="$(git -C "$repo_root" diff --cached --name-status -M --)"
    ;;
esac

guarded_ack="${AGENT_GUARDED_COMMIT:-}"
contract_ack="${AGENT_CONTRACT_COMMIT:-}"
checked=0
violations=0
first_reason=''
first_reason_count=0
guarded_count=0
contract_count=0
normal_count=0
ordinary_paths=()

record_violation() {
  # $1=reason $2=op $3=path
  violations=$((violations + 1))
  [[ -n "$first_reason" ]] || first_reason="$1"
  # paths= reports the count for the reported reason only, so the machine-readable
  # pair stays consistent with the DETAIL lines of that reason (issue #64).
  [[ "$1" != "$first_reason" ]] || first_reason_count=$((first_reason_count + 1))
  printf 'DETAIL: %s %s %s\n' "$1" "$2" "$3" >&2
}

# Public Git identity and tracked-content privacy checks share one local allowlist.
# Values are compared but never printed. GitHub user noreply addresses, GitHub's
# fixed service noreply committer for server-generated merge commits, Git's fixed
# SSH username at github.com, and reserved example.invalid fixtures are safe by
# construction; an intentionally public direct address must be explicitly approved
# in repository-local Git config:
#   git config --local --add agent-directory.allowed-public-email <address>
email_is_public_safe() {
  local candidate="$1" allowed github_service_noreply github_git_ssh_user
  [[ -n "$candidate" ]] || return 1
  github_service_noreply='noreply''@''github.com'
  github_git_ssh_user='git''@''github.com'
  [[ "$candidate" != "$github_service_noreply" ]] || return 0
  [[ "$candidate" != "$github_git_ssh_user" ]] || return 0
  case "$candidate" in
    *@users.noreply.github.com|*@example.invalid) return 0 ;;
  esac
  while IFS= read -r allowed; do
    [[ -n "$allowed" ]] || continue
    [[ "$candidate" != "$allowed" ]] || return 0
  done < <(git -C "$repo_root" config --get-all agent-directory.allowed-public-email 2>/dev/null || true)
  return 1
}

check_git_email() {
  # $1=role $2=email. Diagnostics intentionally omit the matched value.
  local role="$1" candidate="$2"
  if ! email_is_public_safe "$candidate"; then
    record_violation 'unsafe-git-email' 'metadata' "($role-email)"
  fi
}

blob_has_sensitive_content() (
  # Return 0 only when the immutable Git blob contains a blocked value.
  # Never print blob contents or matches.
  local blob="$1" candidate content_file
  git -C "$repo_root" cat-file -e "$blob^{blob}" 2>/dev/null || return 1
  # Read the immutable blob exactly once. With pipefail, `cat-file | grep -q`
  # races: grep may exit after its first match, SIGPIPE the writer, and turn a
  # positive match into a failed pipeline. A private temporary file removes that
  # timing dependency and gives every detector the same bytes.
  umask 077
  content_file="$(mktemp "${TMPDIR:-/tmp}/agent-boundary-blob.XXXXXX")" || return 1
  trap 'rm -f -- "$content_file"' EXIT
  git -C "$repo_root" cat-file blob "$blob" > "$content_file" || return 1
  # Empty and binary blobs are outside this text scanner. Known binary/document assets
  # remain subject to repository structure checks and review.
  LC_ALL=C grep -Iq . "$content_file" || return 1

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    email_is_public_safe "$candidate" || return 0
  done < <(LC_ALL=C grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    "$content_file" | LC_ALL=C sort -u || true)

  while IFS= read -r candidate; do
    case "$candidate" in
      /Users/example-user|/home/example-user) ;;
      *) return 0 ;;
    esac
  done < <(LC_ALL=C grep -Eo '/(Users|home)/[A-Za-z0-9._-]+' \
    "$content_file" | LC_ALL=C sort -u || true)

  if LC_ALL=C grep -Eq \
    'github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}' \
    "$content_file"; then
    return 0
  fi
  if LC_ALL=C grep -Eiq -- \
    '-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/-]{10,}|([Cc]ookie|[Ss]et-[Cc]ookie):[[:space:]]*[^[:space:]]+=[^[:space:];]+' \
    "$content_file"; then
    return 0
  fi
  if LC_ALL=C grep -Eiq -- \
    '(^|[^A-Za-z0-9_])(api[_-]?key|access[_-]?token|auth[_-]?token|provider[_-]?token|secret|password|cookie)[A-Za-z0-9_-]*[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._/+:-]{16,}' \
    "$content_file"; then
    return 0
  fi
  return 1
)

scan_blob() {
  # $1=blob oid $2=path
  if blob_has_sensitive_content "$1"; then
    record_violation 'sensitive-content' 'blob' "$2"
  fi
}

scan_staged_privacy() {
  local ident email status path1 path2 path blob
  ident="$(git -C "$repo_root" var GIT_AUTHOR_IDENT 2>/dev/null || true)"
  email="$(printf '%s\n' "$ident" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
  check_git_email author "$email"
  ident="$(git -C "$repo_root" var GIT_COMMITTER_IDENT 2>/dev/null || true)"
  email="$(printf '%s\n' "$ident" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
  check_git_email committer "$email"

  while IFS=$'\t' read -r status path1 path2; do
    [[ -n "$status" ]] || continue
    case "$status" in
      A|M|T) path="$path1" ;;
      R*|C*) path="$path2" ;;
      *) continue ;;
    esac
    blob="$(git -C "$repo_root" ls-files -s -- "$path" | awk '$3 == 0 { print $2; exit }')"
    if [[ -n "$blob" ]]; then
      scan_blob "$blob" "$path"
    fi
  done <<EOF
$diff_output
EOF
}

scan_range_privacy() {
  local revision_range commit email path blob
  if [[ "$(git -C "$repo_root" cat-file -t "$range_old" 2>/dev/null || true)" == 'commit' ]]; then
    revision_range="$range_old..$range_new"
  else
    revision_range="$range_new"
  fi
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    email="$(git -C "$repo_root" show -s --format=%ae "$commit")"
    check_git_email author "$email"
    email="$(git -C "$repo_root" show -s --format=%ce "$commit")"
    check_git_email committer "$email"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      blob="$(git -C "$repo_root" ls-tree "$commit" -- "$path" | awk '$2 == "blob" { print $3; exit }')"
      if [[ -n "$blob" ]]; then
        scan_blob "$blob" "$path"
      fi
    done < <(git -C "$repo_root" diff-tree --root --no-commit-id --name-only -r "$commit")
  done < <(git -C "$repo_root" rev-list "$revision_range")
}

check_op() {
  # $1=op（add|modify|delete） $2=repo相対path
  local op="$1" path="$2" tier
  tier="$(tier_for "$path_prefix$path")"
  case "$tier" in
    exempt|none)
      normal_count=$((normal_count + 1))
      ordinary_paths+=("$path")
      ;;
    forbidden)
      if [[ "$op" == 'delete' ]]; then
        normal_count=$((normal_count + 1))
        ordinary_paths+=("$path")
      else
        record_violation 'forbidden-path' "$op" "$path"
      fi
      ;;
    frozen)
      if [[ "$op" == 'add' ]]; then
        normal_count=$((normal_count + 1))
        ordinary_paths+=("$path")
      else
        record_violation 'frozen-path-modified' "$op" "$path"
      fi
      ;;
    guarded)
      guarded_count=$((guarded_count + 1))
      # rangeモード（push再検査）ではcommit時に執行済みのackを再要求しない。
      # 客観的なforbidden/frozenだけを再検査し、ackの常用を要求する設計を避ける。
      if [[ "$mode" != 'range' && "$guarded_ack" != 'true' ]]; then
        record_violation 'guarded-path-without-ack' "$op" "$path"
      fi
      ;;
    contract)
      contract_count=$((contract_count + 1))
      if [[ "$mode" != 'range' && "$contract_ack" != 'true' ]]; then
        record_violation 'contract-path-without-approval' "$op" "$path"
      fi
      ;;
  esac
}

while IFS=$'\t' read -r status path1 path2; do
  [[ -n "$status" ]] || continue
  checked=$((checked + 1))
  case "$status" in
    A) check_op 'add' "$path1" ;;
    M|T) check_op 'modify' "$path1" ;;
    D) check_op 'delete' "$path1" ;;
    R*)
      # renameは旧pathの削除と新pathの追加へ分解して判定する。
      check_op 'delete' "$path1"
      check_op 'add' "$path2"
      ;;
    C*) check_op 'add' "$path2" ;;
    *)
      record_violation 'unknown-diff-status' "$status" "${path1:-}"
      ;;
  esac
done <<EOF
$diff_output
EOF

# Privacy and secret checks run on immutable staged/outgoing Git objects. They apply to
# guarded and ordinary paths alike and are never weakened by the path tier or ack flags.
case "$mode" in
  staged) scan_staged_privacy ;;
  range) scan_range_privacy ;;
esac

# guarded / contractの変更は、通常の成果と同じcommitへ混ぜない（stagedモードだけの機械拒否）。
if [[ "$mode" == 'staged' ]] && (( guarded_count + contract_count > 0 )) && (( normal_count > 0 )); then
  printf 'DETAIL: meta/contract changes and ordinary work are staged together; split them into separate commits\n' >&2
  snapshot_gap_count=0
  for ordinary_path in ${ordinary_paths[@]+"${ordinary_paths[@]}"}; do
    candidate_tier="$(staged_tier_for "$path_prefix$ordinary_path")"
    case "$candidate_tier" in
      guarded|contract)
        snapshot_gap_count=$((snapshot_gap_count + 1))
        if (( snapshot_gap_count <= 5 )); then
          printf 'DETAIL: staged policy classifies %s as %s, but the approved HEAD snapshot still classifies it as ordinary\n' \
            "$ordinary_path" "$candidate_tier" >&2
        fi
        ;;
    esac
  done
  if (( snapshot_gap_count > 0 )); then
    printf 'DETAIL: safe recovery: commit the policy change alone, reinstall managed hooks from the new HEAD, then commit the newly protected paths; do not bypass the hooks\n' >&2
  fi
  record_violation 'mixed-scope' 'staged' '(guarded/contract + ordinary paths)'
fi

if (( violations > 0 )); then
  case "$first_reason" in
    guarded-path-without-ack)
      printf 'DETAIL: meta canon changes require AGENT_GUARDED_COMMIT=true for this one commit and --full validation (tools/CONTROL.md#明示エスカレーション)\n' >&2
      ;;
    contract-path-without-approval)
      printf 'DETAIL: Project contract changes are decided by the human; commit them alone with AGENT_CONTRACT_COMMIT=true after that approval (tools/CONTROL.md#明示エスカレーション)\n' >&2
      ;;
  esac
  blocked "$first_reason" "$first_reason_count"
fi
printf 'BOUNDARY_OK checked=%d guarded=%d contract=%d\n' "$checked" "$guarded_count" "$contract_count"
