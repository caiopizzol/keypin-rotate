#!/usr/bin/env bash
# Installs the exact keypin version the inputs name.
set -euo pipefail

npm install --global --no-audit --no-fund "keypin@$KEYPIN_VERSION"
keypin --version
