#!/usr/bin/env bash
# Copies .keypin/rotation.json and status.json out of the checkout, for the artifact and the save.
# keypin may write either one alone; with neither, there is nothing to stage.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

rm -rf "$STAGED"
mkdir -p "$STAGED"
for file in rotation.json status.json; do
  [ -e ".keypin/$file" ] || [ -L ".keypin/$file" ] || continue
  if [ -L ".keypin/$file" ] || [ ! -f ".keypin/$file" ]; then
    echo "::error::.keypin/$file isn't a regular file"
    exit 1
  fi
  cp ".keypin/$file" "$STAGED/$file"
done
if [ -z "$(ls -A "$STAGED")" ]; then
  echo "::notice::keypin wrote no state, so there is nothing to save."
  output staged false
  exit 0
fi
output staged true
