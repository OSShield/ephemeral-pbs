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

# Ensure the datastore directory exists inside the static container layout.
# NO, do not do this.
# mkdir -p "${DATSTORE_PATH}/level1/level2/level3" "${DATSTORE_PATH}/level1-2"
chown -R backup:backup "${DATSTORE_PATH}" 2>/dev/null || true

echo "Creating datastore at ${DATSTORE_PATH}..."
# Create the datastore if it is missing.
if ! proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -e --arg name "$DATASTORE_NAME" '.[] | select(.name == $name)' >/dev/null 2>&1; then
  proxmox-backup-manager datastore create "$DATASTORE_NAME" "$DATSTORE_PATH" >/dev/null
fi

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

# DO NOT DO THIS, PBS does this all by itself
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
