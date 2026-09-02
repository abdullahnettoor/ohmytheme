#!/usr/bin/env bash
# Validates the bundled Theme Packs and their deterministic catalog.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool swift "Install Xcode and run 'sudo xcode-select --switch /Applications/Xcode.app'."

catalog_path="$REPO_ROOT/Themes/catalog.json"
temporary_catalog="$(mktemp)"
trap 'rm -f "$temporary_catalog"' EXIT

(
  cd "$PACKAGE_PATH"
  swift run ThemeTool validate "$REPO_ROOT"/Themes/Packs/*.json
  swift run ThemeTool catalog "$REPO_ROOT/Themes/Packs" "$temporary_catalog"
)

diff -u "$catalog_path" "$temporary_catalog"
