#!/bin/bash
set -euo pipefail

VPS="admin@5.189.182.39"
REMOTE_DIR="~/hermes-workspaces"

PROJECT=$(basename "$PWD")

ssh "$VPS" "mkdir -p $REMOTE_DIR/current/$PROJECT"

ssh "$VPS" "tar --exclude=.git -czf /tmp/$PROJECT.tar.gz -C $REMOTE_DIR/current/$PROJECT ."

scp "$VPS:/tmp/$PROJECT.tar.gz" "/tmp/$PROJECT.tar.gz"

ssh "$VPS" "rm -f /tmp/$PROJECT.tar.gz"

rm -rf "/tmp/$PROJECT-download"
mkdir -p "/tmp/$PROJECT-download"
tar -xzf "/tmp/$PROJECT.tar.gz" -C "/tmp/$PROJECT-download"

rsync -a --delete --exclude=.git --exclude=.env "/tmp/$PROJECT-download/" "$PWD/"

rm -rf "/tmp/$PROJECT-download" "/tmp/$PROJECT.tar.gz"
