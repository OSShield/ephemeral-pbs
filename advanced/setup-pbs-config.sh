#!/usr/bin/env bash
set -Eeuo pipefail

# Applies a YAML config (see README.md) to a running PBS instance.
# Only the small YAML subset documented in the README is supported.

CONFIG_FILE="${1:-${CONFIG_FILE:-/etc/pbs-config.yml}}"

: "${PASSWORD:=demo}"
: "${DEFAULT_TOKEN_SECRET:=12345678-1234-1234-1234-1234567890ab}"

DATASTORE_NAME="data"
DATASTORE_PATH="/var/lib/proxmox-backup/datastore"
PBS_API_URL="https://localhost:${PORT:-8007}/api2/json"

# Parsed config. Namespaces are stored as full paths, parents before children.
NAMESPACES=()
USERS=()
declare -A USER_PASSWORD=()
declare -A USER_NAMESPACES=()
declare -A USER_PERMISSIONS=()
declare -A USER_TOKENS=()
declare -A USER_TOKEN_SECRET=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

unquote() {
  local value="$1"

  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

# Turn "[a, b]" into "a b".
parse_inline_list() {
  local value="$1"
  local item
  local items=()

  value="${value//[[:space:]]/}"
  value="${value#[}"
  value="${value%]}"

  IFS=',' read -r -a parts <<< "$value"
  for item in "${parts[@]}"; do
    [ -n "$item" ] && items+=("$(unquote "$item")")
  done

  printf '%s' "${items[*]:-}"
}

normalize_role() {
  case "${1:-}" in
    DatastoreRead|Datastore.Reader|DatastoreReader) echo "DatastoreReader" ;;
    DatastoreBackup|Datastore.Backup) echo "DatastoreBackup" ;;
    *) echo "$1" ;;
  esac
}

parse_config() {
  local config_path="$1"
  local section=""
  local current_user=""
  local current_field=""
  local line key value indent parent_path depth
  declare -A namespace_by_indent=()

  [ -f "$config_path" ] || die "Config file not found: $config_path"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "${line//[[:space:]]/}" ] && continue

    # Top-level keys.
    if [[ "$line" =~ ^([A-Za-z_]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(unquote "${BASH_REMATCH[2]}")"
      section=""
      current_user=""
      current_field=""

      case "$key" in
        datastore) DATASTORE_NAME="$value" ;;
        default_token_secret) DEFAULT_TOKEN_SECRET="$value" ;;
        namespaces|users) section="$key" ;;
        *) die "Unknown top-level key in config: $key" ;;
      esac
      continue
    fi

    if [[ "$section" == "namespaces" ]]; then
      [[ "$line" =~ ^([[:space:]]+)([A-Za-z0-9_-]+):$ ]] || die "Invalid namespace line: $line"
      indent="${#BASH_REMATCH[1]}"
      key="${BASH_REMATCH[2]}"

      parent_path=""
      for depth in "${!namespace_by_indent[@]}"; do
        if (( depth >= indent )); then
          unset "namespace_by_indent[$depth]"
        fi
      done
      for depth in $(printf '%s\n' "${!namespace_by_indent[@]}" | sort -n); do
        parent_path="${namespace_by_indent[$depth]}"
      done

      namespace_by_indent[$indent]="${parent_path:+${parent_path}/}${key}"
      NAMESPACES+=("${namespace_by_indent[$indent]}")
      continue
    fi

    if [[ "$section" == "users" ]]; then
      if [[ "$line" =~ ^[[:space:]]{2}([A-Za-z0-9._-]+):$ ]]; then
        current_user="${BASH_REMATCH[1]}"
        current_field=""
        USERS+=("$current_user")
        continue
      fi

      [ -n "$current_user" ] || die "Invalid users line: $line"

      if [[ "$line" =~ ^[[:space:]]{4}([a-z_]+):[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        current_field="$key"

        case "$key" in
          password) USER_PASSWORD[$current_user]="$(unquote "$value")" ;;
          namespaces) USER_NAMESPACES[$current_user]="$(parse_inline_list "$value")" ;;
          permissions) USER_PERMISSIONS[$current_user]="$(parse_inline_list "$value")" ;;
          token|tokens) USER_TOKENS[$current_user]="$(parse_inline_list "$value")" ;;
          token_secret) USER_TOKEN_SECRET[$current_user]="$(unquote "$value")" ;;
          *) die "Unknown key for user $current_user: $key" ;;
        esac
        continue
      fi

      if [[ "$current_field" =~ ^tokens?$ && "$line" =~ ^[[:space:]]{6}-[[:space:]]*(.+)$ ]]; then
        value="$(unquote "${BASH_REMATCH[1]}")"
        USER_TOKENS[$current_user]+="${USER_TOKENS[$current_user]:+ }${value}"
        continue
      fi

      die "Invalid users line: $line"
    fi

    die "Unexpected line in config: $line"
  done < "$config_path"
}

fixed_token_hash() {
  local secret="$1"
  mkpasswd -m yescrypt "$secret"
}

overwrite_token_secret() {
  local auth_id="$1"
  local token_name="$2"
  local secret="$3"
  local token_key="${auth_id}!${token_name}"
  local hash_value
  local shadow_file="/etc/proxmox-backup/token.shadow"
  local existing="{}"

  hash_value="$(fixed_token_hash "$secret")"

  if [ -f "$shadow_file" ] && [ -s "$shadow_file" ]; then
    existing="$(cat "$shadow_file")"
  fi

  printf '%s' "$existing" | jq --arg key "$token_key" --arg value "$hash_value" '.[$key] = $value' > "$shadow_file"
}

# Log in as root@pam and store the ticket/CSRF token for subsequent API calls.
api_login() {
  local response

  response="$(curl -fsSk "${PBS_API_URL}/access/ticket" \
    --data-urlencode "username=root@pam" \
    --data-urlencode "password=${PASSWORD}")" || die "Could not log in to the PBS API as root@pam."

  API_TICKET="$(printf '%s' "$response" | jq -r '.data.ticket')"
  API_CSRF="$(printf '%s' "$response" | jq -r '.data.CSRFPreventionToken')"
}

create_namespace() {
  local store="$1"
  local ns="$2"
  local name="${ns##*/}"
  local parent=""

  [[ "$ns" == */* ]] && parent="${ns%/*}"

  if curl -fsSk "${PBS_API_URL}/admin/datastore/${store}/namespace" \
      -b "PBSAuthCookie=${API_TICKET}" \
      | jq -e --arg ns "$ns" '.data[] | select(.ns == $ns)' >/dev/null 2>&1; then
    echo "Namespace ${store}:${ns} already exists."
    return 0
  fi

  curl -fsSk -X POST "${PBS_API_URL}/admin/datastore/${store}/namespace" \
    -b "PBSAuthCookie=${API_TICKET}" \
    -H "CSRFPreventionToken: ${API_CSRF}" \
    --data-urlencode "name=${name}" \
    ${parent:+--data-urlencode "parent=${parent}"} >/dev/null
  echo "Created namespace ${store}:${ns}."
}

# Print the HTTP status for an authenticated API call using the given token.
token_auth_status() {
  local token_id="$1"
  local secret="$2"

  curl -sk -o /dev/null -w '%{http_code}' \
    -H "Authorization: PBSAPIToken=${token_id}:${secret}" \
    "${PBS_API_URL}/version"
}

verify_token() {
  local token_id="$1"
  local secret="$2"
  local status

  status="$(token_auth_status "$token_id" "$secret")"
  if [ "$status" != "200" ]; then
    echo "ERROR: Token ${token_id} failed to authenticate (HTTP ${status})." >&2
    return 1
  fi

  echo "Token ${token_id} authenticated successfully."
}

user_exists() {
  proxmox-backup-manager user list --output-format json \
    | jq -e --arg id "$1" '.[] | select(.userid == $id)' >/dev/null
}

token_exists() {
  proxmox-backup-manager user list-tokens "$1" --output-format json \
    | jq -e --arg id "$1!$2" '.[] | select(.tokenid == $id)' >/dev/null
}

# ACL paths for a user: one per configured namespace, or the whole datastore.
user_acl_paths() {
  local user="$1"
  local ns

  if [ -z "${USER_NAMESPACES[$user]:-}" ]; then
    echo "/datastore/${DATASTORE_NAME}"
    return 0
  fi

  for ns in ${USER_NAMESPACES[$user]}; do
    echo "/datastore/${DATASTORE_NAME}/${ns}"
  done
}

parse_config "$CONFIG_FILE"

echo "Applying PBS config from ${CONFIG_FILE}..."

chown -R backup:backup "${DATASTORE_PATH}" 2>/dev/null || true

echo "Creating datastore ${DATASTORE_NAME} at ${DATASTORE_PATH}..."
if ! proxmox-backup-manager datastore list --output-format json \
    | jq -e --arg name "$DATASTORE_NAME" '.[] | select(.name == $name)' >/dev/null; then
  proxmox-backup-manager datastore create "$DATASTORE_NAME" "$DATASTORE_PATH" >/dev/null
fi

echo "Creating namespaces in datastore ${DATASTORE_NAME}..."
# Namespaces must be created through the PBS API, not by creating directories on disk.
api_login
for ns in "${NAMESPACES[@]}"; do
  create_namespace "$DATASTORE_NAME" "$ns"
done

declare -A TOKEN_SECRETS=()

for user in "${USERS[@]}"; do
  auth_id="${user}@pbs"

  echo "Configuring user ${auth_id}..."
  if ! user_exists "$auth_id"; then
    proxmox-backup-manager user create "$auth_id" --password "${USER_PASSWORD[$user]:-${user}-password}"
  fi

  for token_name in ${USER_TOKENS[$user]:-}; do
    if ! token_exists "$auth_id" "$token_name"; then
      proxmox-backup-manager user generate-token "$auth_id" "$token_name" --comment "$token_name" >/dev/null
    fi

    TOKEN_SECRETS["${auth_id}!${token_name}"]="${USER_TOKEN_SECRET[$user]:-$DEFAULT_TOKEN_SECRET}"
    overwrite_token_secret "$auth_id" "$token_name" "${TOKEN_SECRETS["${auth_id}!${token_name}"]}"
  done

  # Tokens need their own ACLs; they get the same permissions as their user.
  for path in $(user_acl_paths "$user"); do
    for permission in ${USER_PERMISSIONS[$user]:-}; do
      permission="$(normalize_role "$permission")"
      proxmox-backup-manager acl update "$path" "$permission" --auth-id "$auth_id"
      for token_name in ${USER_TOKENS[$user]:-}; do
        proxmox-backup-manager acl update "$path" "$permission" --auth-id "${auth_id}!${token_name}"
      done
    done
  done
done

echo "Verifying API token authentication..."
# Sanity check: a wrong secret must be rejected, otherwise the checks below prove nothing.
for token_id in "${!TOKEN_SECRETS[@]}"; do
  if [ "$(token_auth_status "$token_id" "invalid-secret")" = "200" ]; then
    die "Token authentication accepted an invalid secret."
  fi
  break
done

failed=0
for token_id in "${!TOKEN_SECRETS[@]}"; do
  verify_token "$token_id" "${TOKEN_SECRETS[$token_id]}" || failed=1
done
[ "$failed" -eq 0 ] || exit 1

echo "PBS config applied."
