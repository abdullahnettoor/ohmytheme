#!/usr/bin/env bash
# Runs the OhMyThemeKit package tests.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool swift "Install Xcode and run 'sudo xcode-select --switch /Applications/Xcode.app'."

swift test --package-path "$PACKAGE_PATH" "$@"
