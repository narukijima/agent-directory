#!/usr/bin/env bash

# Shared deterministic predicates for projects/REPOSITORIES.md consumers.
# Keep this file side-effect free: callers own policy, error handling, and output wording.

# Emit registry entries as
# "R<TAB>name<TAB>url<TAB>reason<TAB>revision<TAB>role" and structural errors as
# "E<TAB>detail". Fenced examples are never parsed as live entries. The omitted role
# keeps the established Project attachment meaning; public foundations must opt in.
agent_registry_records() {
  LC_ALL=C awk '
    function flush_entry() {
      if (current == "") return
      if (url_count != 1) print "E\t`" current "` must declare repository_url exactly once"
      if (reason_count != 1) print "E\t`" current "` must declare repository_reason exactly once"
      if (revision_count != 1) print "E\t`" current "` must declare revision exactly once"
      if (role_count > 1) print "E\t`" current "` must declare repository_role at most once"
      if (role == "") role = "project"
      print "R\t" current "\t" url "\t" reason "\t" revision "\t" role
      current = ""
    }
    {
      if (substr($0, 1, 3) == "```") { fence = 1 - fence; next }
      if (fence) next
      if (substr($0, 1, 3) == "## ") {
        flush_entry()
        heading = $0
        url = ""; reason = ""; revision = ""; role = ""
        url_count = 0; reason_count = 0; revision_count = 0; role_count = 0
        if (heading ~ /^## `[A-Za-z0-9][A-Za-z0-9._-]*`[ \t]*$/) {
          sub(/^## `/, "", heading)
          sub(/`[ \t]*$/, "", heading)
          current = heading
          if (current in seen) print "E\tduplicate registry entry: `" current "`"
          seen[current] = 1
          if (previous != "" && previous >= current)
            print "E\tregistry entries must sort ascending: `" previous "` before `" current "`"
          previous = current
        } else {
          print "E\tinvalid registry heading: " $0
        }
        next
      }
      if (substr($0, 1, 2) == "- ") {
        field = $0
        sub(/^- /, "", field)
        if (field !~ /^[a-z_]+: `[^`]*`[ \t]*$/) next
        if (current == "") { print "E\tregistry field outside an entry: " $0; next }
        key = field
        sub(/:.*$/, "", key)
        value = field
        sub(/^[a-z_]+: `/, "", value)
        sub(/`[ \t]*$/, "", value)
        if (key == "repository_url") { url = value; url_count++ }
        else if (key == "repository_reason") { reason = value; reason_count++ }
        else if (key == "revision") { revision = value; revision_count++ }
        else if (key == "repository_role") { role = value; role_count++ }
        else print "E\tunsupported registry field in `" current "`: " key
        next
      }
    }
    END { flush_entry() }
  ' "$1"
}

# Return success when a repository URL must be rejected. Local paths are accepted only
# when the explicit second argument is true (isolated validator fixtures).
agent_repository_url_is_rejected() {
  local url="$1"
  local allow_local="${2:-false}"
  local authority userinfo
  [[ -n "$url" ]] || return 0
  case "$url" in
    -*) return 0 ;;
    *[[:space:]]*|*'`'*) return 0 ;;
    *'?'*|*'#'*) return 0 ;;
    file://*|FILE://*) return 0 ;;
  esac
  authority="${url#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    *@*)
      userinfo="${authority%%@*}"
      case "$userinfo" in *:*) return 0 ;; esac
      ;;
  esac
  if [[ "$allow_local" != 'true' ]]; then
    case "$url" in
      /*|./*|../*|~*) return 0 ;;
      *://*|*:*) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}
