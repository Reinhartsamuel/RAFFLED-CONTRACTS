#!/bin/bash
set -euo pipefail

VPS="admin@5.189.182.39"
REMOTE_DIR="~/hermes-workspaces"
RESULTS_DIR="~/hermes-results"

PROJECT=$(basename "$PWD")

ssh "$VPS" "mkdir -p $REMOTE_DIR/current $RESULTS_DIR"

tar \
  --exclude=.git \
  --exclude=.env \
  --exclude=node_modules \
  --exclude=lib \
  --exclude=cache \
  --exclude=out \
  --exclude=broadcast \
  --exclude=.DS_Store \
  -czf "/tmp/$PROJECT.tar.gz" .

scp "/tmp/$PROJECT.tar.gz" "$VPS:$REMOTE_DIR/"

ssh "$VPS" <<EOF
rm -rf $REMOTE_DIR/current/$PROJECT
mkdir -p $REMOTE_DIR/current/$PROJECT
tar -xzf $REMOTE_DIR/$PROJECT.tar.gz \
    -C $REMOTE_DIR/current/$PROJECT
rm -f $REMOTE_DIR/$PROJECT.tar.gz
EOF

rm -f "/tmp/$PROJECT.tar.gz"
