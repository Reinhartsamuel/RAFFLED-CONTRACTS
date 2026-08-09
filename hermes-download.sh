#!/bin/bash
set -euo pipefail

VPS="admin@5.189.182.39"
PROJECT=$(basename "$PWD")
CONTAINER="hermes"

REMOTE_WORKSPACE="/opt/workspaces/current/$PROJECT"
REMOTE_RESULTS="/opt/results/$PROJECT"

rm -rf "/tmp/$PROJECT-download"
mkdir -p "/tmp/$PROJECT-download"

ssh "$VPS" "docker exec $CONTAINER sh -c 'tar --exclude=.git --exclude=.env --exclude=\"._*\" --exclude=\"./._*\" -czf - -C $REMOTE_WORKSPACE .'" > "/tmp/${PROJECT}-download.tar.gz"

tar -xzf "/tmp/${PROJECT}-download.tar.gz" -C "/tmp/$PROJECT-download"

find "/tmp/$PROJECT-download" -name '._*' -delete
find "$PWD" -name '._*' -delete
rsync -a --delete \
  --exclude=.git \
  --exclude=.env \
  --exclude='._*' \
  --exclude=hermes-upload.sh \
  --exclude=hermes-download.sh \
  "/tmp/$PROJECT-download/" "$PWD/"

rm -rf "/tmp/$PROJECT-download" "/tmp/${PROJECT}-download.tar.gz"

echo "--- Downloading hermes results ---"
ssh "$VPS" "docker exec $CONTAINER sh -c 'tar --exclude=.env --exclude=\"._*\" --exclude=\"./._*\" -czf - -C $REMOTE_RESULTS .'" > "/tmp/${PROJECT}-results.tar.gz" 2>/dev/null || true

if [ -s "/tmp/${PROJECT}-results.tar.gz" ]; then
  mkdir -p "$PWD/hermes-results"
  rm -rf "/tmp/${PROJECT}-results-extract"
  mkdir -p "/tmp/${PROJECT}-results-extract"
  tar -xzf "/tmp/${PROJECT}-results.tar.gz" -C "/tmp/${PROJECT}-results-extract" 2>/dev/null || true
  find "/tmp/${PROJECT}-results-extract" -name '._*' -delete
  find "$PWD/hermes-results" -name '._*' -delete
  rsync -a --exclude='._*' "/tmp/${PROJECT}-results-extract/" "$PWD/hermes-results/"
  rm -rf "/tmp/${PROJECT}-results-extract" "/tmp/${PROJECT}-results.tar.gz"
  echo "Results downloaded to hermes-results/"
else
  echo "No results found"
fi
