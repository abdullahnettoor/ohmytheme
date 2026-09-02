#!/usr/bin/env bash
# Shared configuration for the repository scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$REPO_ROOT/Packages/OhMyThemeKit"
XCODE_PROJECT="$REPO_ROOT/OhMyTheme.xcodeproj"
XCODE_SCHEME="OhMyTheme"
XCODE_DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/.build/DerivedData}"

# The Xcode major version the project is developed and validated against.
REQUIRED_XCODE_MAJOR_VERSION=26

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  local tool="$1"
  local hint="$2"
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not available. $hint"
}
