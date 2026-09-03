#!/usr/bin/env bash
# Shared configuration for the repository scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$REPO_ROOT/Packages/OhMyThemeKit"
XCODE_PROJECT="$REPO_ROOT/OhMyTheme.xcodeproj"
XCODE_SCHEME="OhMyTheme"
XCODE_DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/.build/DerivedData}"

# Local development accepts this major version or later. CI also requires the exact pins.
REQUIRED_XCODE_MAJOR_VERSION=26
PINNED_XCODE_VERSION=26.1
PINNED_XCODE_BUILD=17B55
PINNED_SWIFT_VERSION=6.2.1

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  local tool="$1"
  local hint="$2"
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not available. $hint"
}
