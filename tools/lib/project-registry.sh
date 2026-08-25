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

# Return success when a repository URL must be rejected. The registry allows only the
# canonical shapes from projects/REPOSITORIES.md#entry形式 — `git@host:path.git`,
# `ssh://git@host/path.git`, `https://host/path.git` — with no credential and a
# path of at least two segments. Nested namespaces are allowed. There is no
# query, fragment, port, or local path. Local absolute paths are accepted only when the
# explicit second argument is true (isolated validator fixtures).
agent_repository_path_is_rejected() {
  local path="$1"
  [[ -n "$path" && "$path" == */* && "$path" == *.git ]] || return 0
  case "$path" in
    /*|*/|*/.git|*//*|*'\'*) return 0 ;;
  esac
  case "/$path/" in
    *'/../'*|*'/./'*) return 0 ;;
  esac
  return 1
}

agent_repository_url_is_rejected() {
  local url="$1"
  local allow_local="${2:-false}"
  local rest userinfo host path
  [[ -n "$url" ]] || return 0
  case "$url" in
    -*|*[[:space:]]*|*'`'*|*"'"*|*'"'*) return 0 ;;
    *'?'*|*'#'*) return 0 ;;
  esac
  if [[ "$allow_local" == 'true' ]]; then
    case "$url" in
      /*) return 1 ;;
    esac
  fi
  case "$url" in
    https://*)
      rest="${url#https://}"
      [[ "$rest" == */* ]] || return 0
      host="${rest%%/*}"
      path="${rest#*/}"
      case "$host" in
        ''|*@*|*:*) return 0 ;; # https carries no userinfo (tokens included) and no port
      esac
      agent_repository_path_is_rejected "$path" && return 0
      return 1
      ;;
    ssh://*)
      rest="${url#ssh://}"
      [[ "$rest" == */* ]] || return 0
      host="${rest%%/*}"
      path="${rest#*/}"
      case "$host" in
        *@*) userinfo="${host%%@*}"; host="${host#*@}" ;;
        *) return 0 ;;
      esac
      [[ "$userinfo" == 'git' ]] || return 0
      case "$host" in ''|*:*|*@*) return 0 ;; esac
      agent_repository_path_is_rejected "$path" && return 0
      return 1
      ;;
    *://*) return 0 ;; # file, git, http and every other scheme
    *@*:*)
      userinfo="${url%%@*}"
      rest="${url#*@}"
      [[ "$rest" == *:* ]] || return 0
      host="${rest%%:*}"
      path="${rest#*:}"
      [[ "$userinfo" == 'git' ]] || return 0
      case "$host" in ''|*/*|*@*) return 0 ;; esac
      agent_repository_path_is_rejected "$path" && return 0
      return 1
      ;;
    *) return 0 ;;
  esac
}

# Print one error line when a parsed registry entry violates the field contracts of
# projects/REPOSITORIES.md; print nothing when the entry is valid. Never echoes the
# URL itself so a rejected credential-bearing value cannot leak into reports.
agent_registry_entry_error() {
  local name="$1" url="$2" reason="$3" revision="$4" role="$5" allow_local="${6:-false}"
  case "$reason" in
    automation|distribution|collaboration|access|identity|upstream|retention) ;;
    *) printf '`%s` has an invalid repository_reason: %s\n' "$name" "${reason:-<empty>}"; return 0 ;;
  esac
  if agent_repository_url_is_rejected "$url" "$allow_local"; then
    printf '`%s` repository_url must be credential-free git@host:path.git, ssh://git@host/path.git or https://host/path.git without query, fragment, port or local path\n' "$name"
    return 0
  fi
  if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '`%s` revision must be a 40-character lowercase commit SHA\n' "$name"
    return 0
  fi
  case "$role" in
    project|public-foundation) ;;
    *) printf '`%s` has an invalid repository_role: %s\n' "$name" "${role:-<empty>}" ;;
  esac
}
