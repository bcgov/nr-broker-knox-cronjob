#!/usr/bin/env bash
timestamp=$(date +'%Y%m%d-%H%M%S')
BACKUP_FILENAME="/backup/vault-$timestamp.backup"

prune_backups() {
  local backup_file
  local backup_day
  local cutoff_day
  local cutoff_hour
  local current_epoch
  declare -A retained_days

  current_epoch=$(date +'%s')
  cutoff_day=$(date -d "@$((current_epoch - 7 * 86400))" +'%Y%m%d')
  cutoff_hour=$(date -d "@$((current_epoch - 24 * 3600))" +'%Y%m%d%H%M%S')

  while IFS= read -r backup_file; do
    backup_day=${backup_file:6:8}

    if [[ $backup_day < $cutoff_day ]]; then
      rm "/backup/$backup_file" "/backup/${backup_file%.backup}-date.txt"
    elif [[ $backup_file < "vault-$cutoff_hour.backup" && -z ${retained_days[$backup_day]} ]]; then
      retained_days[$backup_day]=1
    elif [[ $backup_file < "vault-$cutoff_hour.backup" && -n ${retained_days[$backup_day]} ]]; then
      rm "/backup/$backup_file" "/backup/${backup_file%.backup}-date.txt"
    fi
  done < <(find /backup -maxdepth 1 -type f -name 'vault-????????-??????.backup' -exec basename {} \; | sort)
}

echo "===> Backup start"

# Backup vault to backup volume
curl \
  --request GET \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_URL/v1/sys/storage/raft/snapshot > \
  $BACKUP_FILENAME

date +'%Y-%m-%d %T' > "${BACKUP_FILENAME%.backup}-date.txt"
SHASUM=$(sha256sum $BACKUP_FILENAME)
BACKUP_FILESIZE=$(ls -l $BACKUP_FILENAME | awk '{print $5}')

# Copy backup to s3
s5cmd cp $BACKUP_FILENAME s3://${OBJECT_STORAGE_BUCKET}/vault-backup-$timestamp.raft

curl -s -X POST $BROKER_URL/v1/intention/action/artifact -H 'X-Broker-Token: '"$ACTION_TOKEN"'' \
    -H 'Content-Type: application/json' \
    -d @<(cat backup-artifact.json | \
        jq ".name=\"$(basename $BACKUP_FILENAME)\" | \
            .checksum=\"sha256:$(echo $SHASUM | awk '{print $1}')\" | \
            .size=$BACKUP_FILESIZE" \
    )

echo $BACKUP_FILENAME

prune_backups
ls -lh /backup/vault-*

echo "Success"
