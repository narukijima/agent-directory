#!/usr/bin/env bash

# Agent-scoped dotenv reader. The Agent Workspace root owns .env; this library
# never sources or evaluates it and returns only the explicitly requested key.
set +x

AGENT_ENV_REASON=''
AGENT_ENV_VALUE=''

agent_env_current_uid() { id -u; }

agent_env_stat_field() {
  local target="$1" bsd_format="$2" gnu_format="$3" value=''
  value="$(stat -f "$bsd_format" "$target" 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(stat -c "$gnu_format" "$target" 2>/dev/null || true)"
  printf '%s' "$value"
}

agent_env_stat_mode() { agent_env_stat_field "$1" '%Lp' '%a'; }
agent_env_stat_uid() { agent_env_stat_field "$1" '%u' '%u'; }
agent_env_stat_links() { agent_env_stat_field "$1" '%l' '%h'; }
agent_env_stat_identity() { agent_env_stat_field "$1" '%d:%i' '%d:%i'; }

agent_env_file() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" && "$workspace_root" == /* && -d "$workspace_root" && ! -L "$workspace_root" ]] || {
    AGENT_ENV_REASON='agent-env-root-invalid'
    return 1
  }
  printf '%s/.env' "$workspace_root"
}

agent_env_permissions() {
  local workspace_root="$1" file="$2" uid mode links
  [[ -f "$file" && ! -L "$file" ]] || { AGENT_ENV_REASON='agent-env-missing'; return 1; }
  uid="$(agent_env_stat_uid "$file")"
  [[ "$uid" == "$(agent_env_current_uid)" ]] || { AGENT_ENV_REASON='agent-env-owner'; return 1; }
  mode="$(agent_env_stat_mode "$file")"
  [[ "$mode" == 600 ]] || { AGENT_ENV_REASON='agent-env-permissions'; return 1; }
  links="$(agent_env_stat_links "$file")"
  [[ "$links" == 1 ]] || { AGENT_ENV_REASON='agent-env-hardlink'; return 1; }
}

agent_env_get() {
  local workspace_root="$1" requested_key="$2" file identity_before identity_after
  local line key value match_count=0
  AGENT_ENV_REASON=''
  AGENT_ENV_VALUE=''
  [[ "$requested_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    AGENT_ENV_REASON='agent-env-key-invalid'; return 1;
  }
  file="$(agent_env_file "$workspace_root")" || return 1
  agent_env_permissions "$workspace_root" "$file" || return 1
  identity_before="$(agent_env_stat_identity "$file")"
  [[ -n "$identity_before" ]] || { AGENT_ENV_REASON='agent-env-race'; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|'#'*) continue ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "$requested_key" ]]; then
          match_count=$((match_count + 1))
          case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
          esac
          AGENT_ENV_VALUE="$value"
        fi
        ;;
      *) AGENT_ENV_REASON='agent-env-invalid'; AGENT_ENV_VALUE=''; return 1 ;;
    esac
  done < "$file"
  identity_after="$(agent_env_stat_identity "$file")"
  [[ "$identity_before" == "$identity_after" ]] || {
    AGENT_ENV_REASON='agent-env-race'; AGENT_ENV_VALUE=''; return 1;
  }
  [[ "$match_count" == 1 ]] || {
    AGENT_ENV_REASON="$([[ "$match_count" == 0 ]] && printf 'agent-env-key-missing' || printf 'agent-env-key-duplicate')"
    AGENT_ENV_VALUE=''
    return 1
  }
}
