#!/usr/bin/env bash
# Runs the app-hosted smoke tests.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool xcodebuild "Install Xcode and run 'sudo xcode-select --switch /Applications/Xcode.app'."

xcodebuild test \
  -project "$XCODE_PROJECT" \
  -scheme "$XCODE_SCHEME" \
  -destination "$XCODE_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "$@"
