#!/usr/bin/env bash
set -Eeuo pipefail

: "${PASSWORD:=demo}"
: "${DATASTORE_NAME:=data}"
: "${BACKUP_USER:=backupuser}"
: "${RESTORE_USER:=restoreuser}"
: "${BACKUP_PASSWORD:=$(openssl rand -hex 12 2>/dev/null || printf 'backup-pass')}"
: "${RESTORE_PASSWORD:=$(openssl rand -hex 12 2>/dev/null || printf 'restore-pass')}"
: "${DEFAULT_TOKEN_SECRET:=12345678-1234-1234-1234-1234567890ab}"
: "${BACKUP_TOKEN_SECRET:=${DEFAULT_TOKEN_SECRET}}"
: "${RESTORE_TOKEN_SECRET:=${DEFAULT_TOKEN_SECRET}}"

BACKUP_AUTH_ID="${BACKUP_USER}@pbs"
RESTORE_AUTH_ID="${RESTORE_USER}@pbs"
DATSTORE_PATH="/var/lib/proxmox-backup/datastore"
PBS_API_URL="https://localhost:${PORT:-8007}/api2/json"
# Parents must be listed before their children.
NAMESPACES=(
  "level1"
  "level1/level2"
  "level1/level2/level3"
  "level1-2"
)

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
    --data-urlencode "password=${PASSWORD}")"

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

# Ensure the datastore directory exists inside the static container layout.
# NO, do not do this.
# mkdir -p "${DATSTORE_PATH}/level1/level2/level3" "${DATSTORE_PATH}/level1-2"
chown -R backup:backup "${DATSTORE_PATH}" 2>/dev/null || true

echo "Creating datastore at ${DATSTORE_PATH}..."
# Create the datastore if it is missing.
if ! proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -e --arg name "$DATASTORE_NAME" '.[] | select(.name == $name)' >/dev/null 2>&1; then
  proxmox-backup-manager datastore create "$DATASTORE_NAME" "$DATSTORE_PATH" >/dev/null
fi

echo "Creating namespaces in datastore ${DATASTORE_NAME}..."
# Namespaces must be created through the PBS API, not by creating directories on disk.
api_login
for ns in "${NAMESPACES[@]}"; do
  create_namespace "$DATASTORE_NAME" "$ns"
done

echo "Ensuring static test users exist..."
# Create the required static test users. PBS expects user ids in the form user@realm.
proxmox-backup-manager user create "$BACKUP_AUTH_ID" --password "$BACKUP_PASSWORD"
proxmox-backup-manager user create "$RESTORE_AUTH_ID" --password "$RESTORE_PASSWORD"

echo "Granting explicit datastore permissions to static test users..."
# Grant the users explicit datastore permissions using the PBS API.
proxmox-backup-manager acl update / DatastoreBackup --auth-id "$BACKUP_AUTH_ID"
proxmox-backup-manager acl update / DatastoreBackup --auth-id "$RESTORE_AUTH_ID"
proxmox-backup-manager acl update / DatastoreReader --auth-id "$RESTORE_AUTH_ID"

echo "Create API tokens for static test users..."
# Generate API tokens for the static users, then overwrite the stored secret with a fixed value.
BACKUP_TOKEN_JSON="$(proxmox-backup-manager user generate-token "$BACKUP_AUTH_ID" backup --comment 'backup token' 2>/dev/null || true)"
echo $BACKUP_TOKEN_JSON
RESTORE_TOKEN_JSON="$(proxmox-backup-manager user generate-token "$RESTORE_AUTH_ID" restore --comment 'restore token' 2>/dev/null || true)"
echo $RESTORE_TOKEN_JSON

echo "Overwriting API token secrets with fixed values..."
overwrite_token_secret "$BACKUP_AUTH_ID" backup "$BACKUP_TOKEN_SECRET"
overwrite_token_secret "$RESTORE_AUTH_ID" restore "$RESTORE_TOKEN_SECRET"
BACKUP_TOKEN_VALUE="$BACKUP_TOKEN_SECRET"
RESTORE_TOKEN_VALUE="$RESTORE_TOKEN_SECRET"

echo "Updating ACLs for API tokens..."
proxmox-backup-manager acl update / DatastoreBackup --auth-id "${BACKUP_AUTH_ID}!backup" 
proxmox-backup-manager acl update / DatastoreBackup --auth-id "${RESTORE_AUTH_ID}!restore"
proxmox-backup-manager acl update / DatastoreReader --auth-id "${RESTORE_AUTH_ID}!restore"

echo "Verifying API token authentication..."
# Sanity check: a wrong secret must be rejected, otherwise the checks below prove nothing.
if [ "$(token_auth_status "${BACKUP_AUTH_ID}!backup" "invalid-secret")" = "200" ]; then
  echo "ERROR: Token authentication accepted an invalid secret." >&2
  exit 1
fi
verify_token "${BACKUP_AUTH_ID}!backup" "$BACKUP_TOKEN_SECRET"
verify_token "${RESTORE_AUTH_ID}!restore" "$RESTORE_TOKEN_SECRET"

# DO NOT DO THIS, PBS does this all by itself and will throw errors if you mess with the filesystem
# Instead, we need to create namespaces via the rest api
# # The static layout intentionally creates the filesystem namespaces that correspond to
# # the PBS datastore structure, without depending on the Python client runtime.
# for ns in "${DATSTORE_PATH}/level1" "${DATSTORE_PATH}/level1/level2" "${DATSTORE_PATH}/level1/level2/level3" "${DATSTORE_PATH}/level1-2"; do
#   mkdir -p "$ns"
#   chown -R backup:backup "$ns" 2>/dev/null || true
# done

# Output the generated credentials in a plain-text form for easy inspection.
echo "root@pam password: ${PASSWORD}"
echo "${BACKUP_AUTH_ID} password: ${BACKUP_PASSWORD}"
echo "${BACKUP_AUTH_ID}!backup token: ${BACKUP_TOKEN_VALUE}"
echo "${RESTORE_AUTH_ID} password: ${RESTORE_PASSWORD}"
echo "${RESTORE_AUTH_ID}!restore token: ${RESTORE_TOKEN_VALUE}"
