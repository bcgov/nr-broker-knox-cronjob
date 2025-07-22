#!/usr/bin/env sh


env $(cat $GITHUB_ENV | xargs) ./intention-open.sh
source $GITHUB_ENV
env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./action-start.sh
env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./vault-login.sh

env $(cat $GITHUB_ENV | xargs) ./backup-runner.sh

env $(cat $GITHUB_ENV | xargs) ACTION_TOKEN=$ACTION_TOKEN_BACKUP ./action-end.sh
env $(cat $GITHUB_ENV | xargs) ./vault-token-revoke.sh
env $(cat $GITHUB_ENV | xargs) OUTCOME=success ./intention-close.sh
