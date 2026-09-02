#!/usr/bin/env bash
# Checks Swift formatting with the swift-format that ships in the Xcode toolchain.
# Pass --fix to rewrite files instead of reporting.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! swift_format="$(xcrun --find swift-format 2>/dev/null)"; then
  fail "swift-format is not in the active toolchain. Install Xcode $REQUIRED_XCODE_MAJOR_VERSION or later and run 'sudo xcode-select --switch /Applications/Xcode.app'."
fi

swift_sources=("$REPO_ROOT/App" "$REPO_ROOT/Packages")

if [[ "${1:-}" == "--fix" ]]; then
  "$swift_format" format --in-place --recursive "${swift_sources[@]}"
  echo "Formatted Swift sources."
else
  "$swift_format" lint --strict --recursive "${swift_sources[@]}"
  echo "Swift sources are formatted."
fi
