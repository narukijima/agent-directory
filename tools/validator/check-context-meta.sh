#!/usr/bin/env bash
set -euo pipefail

# Validate that the generated routing catalog exposes every stable meta canon.
# Usage: check-context-meta.sh <catalog.tsv>

if (( $# != 1 )) || [[ ! -f "$1" ]]; then
  printf 'Usage: %s <catalog.tsv>\n' "${0##*/}" >&2
  exit 2
fi

catalog="$1"
checked=0

while IFS= read -r required_path; do
  [[ -n "$required_path" ]] || continue
  count="$(awk -F '\t' -v path="$required_path" '
    NR > 1 && $1 == "meta" && $3 == "active" && $8 == path { count += 1 }
    END { print count + 0 }
  ' "$catalog")"
  if [[ "$count" != '1' ]]; then
    printf 'CONTEXT_META_BLOCKED path=%s count=%s\n' "$required_path" "$count" >&2
    exit 1
  fi
  checked=$((checked + 1))
done <<'META_CANON_PATHS'
AGENTS.md
README.md
knowledge/KNOWLEDGE.md
skills/SKILLS.md
projects/AGENTS.md
projects/DOCS.md
projects/PROJECTS.md
projects/REPOSITORIES.md
projects/LIFECYCLE.md
projects/RECOVERY.md
evals/EVALS.md
evals/TRACE.md
tools/TOOLS.md
tools/SAFETY.md
tools/CONTROL.md
tools/REFERENCE.md
tools/BACKUP.md
tools/BACKUP-RECOVERY.md
tools/THREAT_MODEL.md
tools/UPSTREAM.md
META_CANON_PATHS

if awk -F '\t' 'NR > 1 && $8 == "tools/agent-workspace-env-threat-model.md" { found = 1 } END { exit !found }' \
  "$catalog"; then
  printf 'CONTEXT_META_BLOCKED path=tools/agent-workspace-env-threat-model.md reason=retired-path\n' >&2
  exit 1
fi

printf 'CONTEXT_META_OK checked=%s\n' "$checked"
