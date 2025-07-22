# nr-broker-knox-cronjob

## Local Testing with Podman

1. Copy `setenv-tmpl.sh` to `setenv-local.sh`. Add values (See deployment repo). (`cp setenv-tmpl.sh setenv-local.sh`)
2. podman build -t knox-vault-backup .
3. podman run --rm -it -v ${PWD}/backup:/backup --env-file setenv-local.sh --userns keep-id knox-vault-backup
