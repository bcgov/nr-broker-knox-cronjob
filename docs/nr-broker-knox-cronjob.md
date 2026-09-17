# Architecture and script flow

This document describes the architecture and script flow of [nr-broker-knox-cronjob](https://github.com/bcgov-nr/nr-broker-knox-cronjob).

## Container startup

The `Dockerfile` uses `alpine:3.22.1` and installs `curl`, `bash`, `jq`, and `s5cmd` (a fast S3 client). The entrypoint is:

```sh
./mask-runner.sh ./backup-cron.sh
```

Two environment variables are pre-set in the image:

- `GITHUB_ENV=/tmp/ENV` — a file used to pass state between scripts (mimicking GitHub Actions' env file mechanism)
- `GITHUB_OUTPUT=/tmp/OUT` — captures job outputs (e.g. the audit URL)

`src/ENV` seeds the env file with `INTENTION_PATH=/app/backup-intention.json` before the cron runs.

---

## mask-runner.sh — secret masking wrapper

`mask-runner.sh` wraps `backup-cron.sh` and processes its combined stdout/stderr line by line. Any line matching `::add-mask::<value>` causes `<value>` to be added to an in-memory secrets list and suppressed from output. All subsequent lines have those secret values replaced with `****`. This is how tokens provisioned at runtime never appear in logs.

---

## backup-cron.sh — the orchestrator

This is the main script. It calls the other scripts in sequence, threading state through the `$GITHUB_ENV` file:

```sh
env $(cat $GITHUB_ENV | xargs) ./intention-open.sh
source $GITHUB_ENV
env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./action-start.sh
env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./vault-login.sh

env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./backup-runner.sh

env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./action-end.sh
env $(cat $GITHUB_ENV | xargs) ./vault-token-revoke.sh
env $(cat $GITHUB_ENV | xargs) OUTCOME=success ./intention-close.sh
```

Each step passes the current contents of `$GITHUB_ENV` as environment variables to the next script, so tokens written by earlier steps are available to later ones.

---

## Step 1 — intention-open.sh

POSTs `backup-intention.json` to NR Broker at `/v1/intention/open`, authenticated with `BROKER_JWT`. The intention JSON declares:

- **One action** with `"id": "backup"` and `"provision": ["token/self"]`, targeting the `vsync` service in the `vault` project
- `"transient": true` — the intention is not permanently recorded in the graph
- The cloud target scopes it to a specific OpenShift namespace (`7e553b-prod`)

Broker responds with:

- An **intention token** (`INTENTION_TOKEN`) — used to close the intention later
- An **action token** per action (`ACTION_TOKEN_BACKUP`) — used to start/end each action and provision Vault tokens

Both are written to `$GITHUB_ENV` (with `::add-mask::` so they are redacted in logs).

---

## Step 2 — action-start.sh

POSTs to `/v1/intention/action/start` using `ACTION_TOKEN_BACKUP`. This tells Broker the backup action has begun and creates an audit record of the start time.

---

## Step 3 — vault-login.sh

POSTs to `/v1/provision/token/self` using `ACTION_TOKEN_BACKUP`. Broker validates the action is allowed to provision a Vault token (per the `"provision": ["token/self"]` declaration in the intention) and returns a **wrapped** Vault token.

The script then unwraps it by POSTing to `$VAULT_URL/v1/sys/wrapping/unwrap`, yielding a short-lived `VAULT_TOKEN` scoped to exactly what that service account is allowed to do in Vault. This is written (masked) to `$GITHUB_ENV`.

---

## Step 4 — backup-runner.sh

Uses `VAULT_TOKEN` to:

1. **Snapshot Vault's raft storage** via `GET $VAULT_URL/v1/sys/storage/raft/snapshot`, saving it to `/backup/vault-<YYYYMMDD-HHMMSS>.backup`. Local retention keeps all backups from the last 24 hours, then only the oldest backup from each of the preceding seven calendar days.
2. **Copy the snapshot to S3** using `s5cmd` and the `OBJECT_STORAGE_BUCKET` / AWS credentials from the container environment. S3 objects are named `vault-backup-<YYYYMMDD-HHMMSS>.raft`, preserving each upload with a timestamped name.
3. **Record the artifact** by POSTing to `/v1/intention/action/artifact` with the filename, SHA-256 checksum, and file size — this creates a traceable record in Broker of exactly what was produced

---

## Step 5 — action-end.sh

POSTs to `/v1/intention/action/end` with `OUTCOME=success`. Broker closes the audit record for this action.

---

## Step 6 — vault-token-revoke.sh

POSTs to `$VAULT_URL/v1/auth/token/revoke-self` using `VAULT_TOKEN`. This immediately invalidates the short-lived token so it cannot be reused if it were ever exposed.

---

## Step 7 — intention-close.sh

POSTs to `/v1/intention/close` with `OUTCOME=success` using `INTENTION_TOKEN`. Broker finalises the audit trail. The response includes an audit URL which is written to `$GITHUB_OUTPUT`.

---

## Overall flow

```
Container starts
    └── mask-runner.sh wraps all output
        └── backup-cron.sh orchestrates:
            1. intention-open     → get INTENTION_TOKEN + ACTION_TOKEN_BACKUP from Broker
            2. action-start       → tell Broker the backup action began
            3. vault-login        → exchange ACTION_TOKEN_BACKUP for VAULT_TOKEN via Broker → Vault
            4. backup-runner      → snapshot Vault raft → S3; record artifact in Broker
            5. action-end         → tell Broker the backup action succeeded
            6. vault-token-revoke → revoke VAULT_TOKEN in Vault
            7. intention-close    → finalise audit trail in Broker
```

---

## Key design points

| Concept | Purpose |
|---|---|
| **Transient intention** | Not stored permanently in the Broker graph — just creates an audit trail |
| **Wrapped Vault token** | Broker never gives the token directly; it's wrapped so only this job can unwrap it |
| **Token revocation** | Vault token is revoked immediately after use, minimising exposure window |
| **mask-runner.sh** | Prevents secrets from ever appearing in container logs |
| **GITHUB_ENV file** | Stateless scripts share tokens through a file, mimicking GitHub Actions — no global state |
| **Action token scoping** | Each action in the intention gets its own short-lived token; `ACTION_TOKEN_BACKUP` only authorises the backup action |
