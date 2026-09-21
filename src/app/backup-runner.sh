#!/usr/bin/env bash
timestamp=$(date +'%Y%m%d-%H%M%S')
BACKUP_FILENAME="/backup/vault-$timestamp.backup"

prune_backups() {
  local backup_file
  local ts_compact
  local day
  local current_epoch
  local cutoff_24h
  local cutoff_10d
  local files=()
  declare -A keep_daily

  current_epoch=$(date +'%s')
  cutoff_24h=$(date -d "@$((current_epoch - 24 * 3600))" +'%Y%m%d%H%M%S')
  cutoff_10d=$(date -d "@$((current_epoch - 10 * 86400))" +'%Y%m%d%H%M%S')

  while IFS= read -r backup_file; do
    files+=("$backup_file")
  done < <(find /backup -maxdepth 1 -type f -name 'vault-????????-??????.backup' -exec basename {} \; | sort)

  # First pass: record the most recent backup per day (24h-10d)
  for backup_file in "${files[@]}"; do
    ts_compact="${backup_file:6:8}${backup_file:15:6}"
    day=${backup_file:6:8}

    if [[ $ts_compact > $cutoff_24h ]]; then
      continue
    elif [[ $ts_compact > $cutoff_10d ]]; then
      keep_daily[$day]=$backup_file
    fi
  done

  # Second pass: delete anything that is not within 24h or the retained daily backup
  for backup_file in "${files[@]}"; do
    ts_compact="${backup_file:6:8}${backup_file:15:6}"
    day=${backup_file:6:8}

    if [[ $ts_compact > $cutoff_24h ]]; then
      continue
    elif [[ $ts_compact > $cutoff_10d ]]; then
      [[ ${keep_daily[$day]} == "$backup_file" ]] || rm "/backup/$backup_file"
    else
      rm "/backup/$backup_file"
    fi
  done
}

echo "===> Backup start"

# Backup vault to backup volume
curl \
  --request GET \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_URL/v1/sys/storage/raft/snapshot > \
  $BACKUP_FILENAME

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
