#!/usr/bin/env bash
set -euo pipefail

# Import one provenance-bound Skill and expose the same canon through the
# standard Codex and Claude Code project Skill locations.
# Trust boundary: this tool executes the source repository's tools/import-skill.sh,
# so --source must point to a trusted local repository whose content the operator
# has reviewed. There is no sandbox or signature verification (tools/TOOLS.md#Skill import).

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="${AGENT_DIRECTORY_ROOT:-$(cd "$tool_root/.." && pwd -P)}"
repo_root="$(cd "$repo_root" && pwd -P)"

usage() {
  printf 'Usage: %s <skill-name> --source <agent-skills-root>\n' "${0##*/}" >&2
}

if [[ $# -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
  usage
  exit 0
fi
[[ $# -ge 3 ]] || { usage; exit 2; }
skill_name="$1"
shift
source_root=''
while (( $# > 0 )); do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      source_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$source_root" || ! "$skill_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  usage
  exit 2
fi

source_root="$(cd "$source_root" && pwd -P)"
source_importer="$source_root/tools/import-skill.sh"
destination="$repo_root/skills/$skill_name"
codex_adapter="$repo_root/.agents/skills/$skill_name"
claude_adapter="$repo_root/.claude/skills/$skill_name"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-directory-skill-import.XXXXXX")"
committed=false
destination_created=false
codex_adapter_created=false
claude_adapter_created=false

cleanup() {
  rm -rf -- "$temporary_root"
  if [[ "$committed" == false ]]; then
    [[ "$codex_adapter_created" == false ]] || rm -f -- "$codex_adapter"
    [[ "$claude_adapter_created" == false ]] || rm -f -- "$claude_adapter"
    [[ "$destination_created" == false ]] || rm -rf -- "$destination"
  fi
}
trap cleanup EXIT

[[ -x "$source_importer" ]] || {
  printf 'ERROR: source importer is missing or not executable: %s\n' "$source_importer" >&2
  exit 1
}
[[ -f "$repo_root/AGENTS.md" && -f "$repo_root/tools/validate-agent-directory.sh" ]] || {
  printf 'ERROR: target is not an Agent Directory root: %s\n' "$repo_root" >&2
  exit 1
}
[[ ! -e "$destination" && ! -L "$destination" ]] || {
  printf 'ERROR: destination exists; compare upstream and remove it explicitly before reimport: %s\n' "$destination" >&2
  exit 1
}
for adapter in "$codex_adapter" "$claude_adapter"; do
  [[ ! -e "$adapter" && ! -L "$adapter" ]] || {
    printf 'ERROR: Runtime adapter exists; refusing to overwrite: %s\n' "$adapter" >&2
    exit 1
  }
done

bash "$source_importer" "$skill_name" --target "$temporary_root"
temporary_skill="$temporary_root/skills/$skill_name"
skill_file="$temporary_skill/SKILL.md"
[[ -f "$skill_file" && -f "$temporary_skill/agents/upstream.yaml" ]] || {
  printf 'ERROR: source importer did not produce a provenance-bound Skill\n' >&2
  exit 1
}

# The distribution repository may emit legacy top-level lifecycle projections
# for older consumers. Normalize those fields into the Agent Skills metadata map
# so the imported canon stays portable across current OpenAI and Anthropic hosts.
python3 - "$skill_file" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
match = re.match(r"^---\n(.*?)\n---(?:\n|$)", text, re.S)
if not match:
    raise SystemExit("ERROR: imported Skill has invalid frontmatter")

lines = match.group(1).splitlines()
top = {}
metadata = {}
in_metadata = False
for line in lines:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    if indent == 0:
        in_metadata = line.strip() == "metadata:"
        item = re.fullmatch(r"([a-z][a-z0-9_-]*):\s*(.*?)\s*", line)
        if item and item.group(1) != "metadata":
            top[item.group(1)] = item.group(2)
        continue
    if in_metadata:
        item = re.fullmatch(r"\s+([a-zA-Z0-9_.-]+):\s*(.*?)\s*", line)
        if item:
            metadata[item.group(1)] = item.group(2)

def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value

status = unquote(
    metadata.get("agent-directory.status")
    or top.get("status")
    or ""
)
if status not in {"active", "deprecated", "retired"}:
    raise SystemExit("ERROR: imported Skill has no valid lifecycle status")

raw_aliases = (
    metadata.get("agent-directory.aliases")
    or top.get("aliases")
    or '""'
)
if raw_aliases.lstrip().startswith("["):
    try:
        aliases = ",".join(str(value).strip() for value in json.loads(raw_aliases) if str(value).strip())
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"ERROR: imported Skill has invalid aliases: {exc}") from exc
else:
    aliases = unquote(raw_aliases)

replacement = unquote(
    metadata.get("agent-directory.replaced-by")
    or top.get("replaced_by")
    or ""
)

filtered = []
metadata_end = None
in_metadata = False
for line in lines:
    indent = len(line) - len(line.lstrip(" "))
    if indent == 0:
        if in_metadata and metadata_end is None:
            metadata_end = len(filtered)
        in_metadata = line.strip() == "metadata:"
        if re.match(r"^(status|aliases|replaced_by):", line):
            continue
    if in_metadata and re.match(r"^\s+agent-directory\.(status|aliases|replaced-by):", line):
        continue
    filtered.append(line)
if in_metadata and metadata_end is None:
    metadata_end = len(filtered)
if metadata_end is None:
    filtered.append("metadata:")
    metadata_end = len(filtered)

projection = [
    f'  agent-directory.status: {json.dumps(status, ensure_ascii=False)}',
    f'  agent-directory.aliases: {json.dumps(aliases, ensure_ascii=False)}',
]
if replacement:
    projection.append(
        f'  agent-directory.replaced-by: {json.dumps(replacement, ensure_ascii=False)}'
    )
filtered[metadata_end:metadata_end] = projection

normalized = "---\n" + "\n".join(filtered) + "\n---\n" + text[match.end():]
path.write_text(normalized, encoding="utf-8")
PY

mkdir -p "$repo_root/skills" "$repo_root/.agents/skills" "$repo_root/.claude/skills"
mv "$temporary_skill" "$destination"
destination_created=true
ln -s "../../skills/$skill_name" "$codex_adapter"
codex_adapter_created=true
ln -s "../../skills/$skill_name" "$claude_adapter"
claude_adapter_created=true
committed=true

source_commit="$(sed -n 's/^source_commit: "\([0-9a-f][0-9a-f]*\)"$/\1/p' "$destination/agents/upstream.yaml")"
printf 'SKILL_IMPORT_OK skill=%s source_commit=%s adapters=2\n' \
  "$skill_name" "${source_commit:-unknown}"
