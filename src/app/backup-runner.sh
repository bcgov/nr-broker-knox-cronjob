#!/usr/bin/env bash
week=$(($(date +'%U') % 5))
hour=$(date +'%H')
timestamp=$(date +'%Y%m%d-%H%M%S')
BACKUP_FILENAME="/backup/vault-$week-$hour.backup"

echo "===> Backup start"

# Backup vault to backup volume
curl \
  --request GET \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_URL/v1/sys/storage/raft/snapshot > \
  $BACKUP_FILENAME

date +'%Y-%m-%d %T' > /backup/vault-$week-$hour-date.txt
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
ls -lh /backup/vault-*

echo "Success"
