#!/usr/bin/env bash
# Rebuilds the VS Code companion without touching the checked-in VSIX, then
# verifies its canonical contents and the checked-in checksum.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool npm "Install Node.js using the version in .node-version."
require_tool npx "Install npm 11.16.0."
require_tool shasum "Install a SHA-256 checksum utility."
require_tool unzip "Install unzip."
require_tool zip "Install zip."

extension_directory="$REPO_ROOT/Extensions/VSCode/oh-my-theme-companion"
resource_directory="$REPO_ROOT/App/OhMyThemeApp/Resources"
vsix_name="oh-my-theme-companion-0.1.0.vsix"
checked_vsix="$resource_directory/$vsix_name"
checked_checksum="$checked_vsix.sha256"
runtime_source="$REPO_ROOT/App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

canonicalize_vsix() {
    local source_vsix="$1"
    local unpacked_directory="$2"
    local canonical_vsix="$3"

    mkdir -p "$unpacked_directory"
    unzip -qq "$source_vsix" -d "$unpacked_directory"
    find "$unpacked_directory" -type d -exec chmod 0755 {} +
    find "$unpacked_directory" -type f -exec chmod 0644 {} +
    find "$unpacked_directory" -exec touch -t 198001010000 {} +
    (
        cd "$unpacked_directory"
        LC_ALL=C find . -type f -print | LC_ALL=C sort | zip -X -q "$canonical_vsix" -@
    )
}

checksum_line="$(awk 'NF { print; exit }' "$checked_checksum")"
expected_checksum="${checksum_line%%[[:space:]]*}"
[[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] ||
    fail "$checked_checksum does not start with a lowercase SHA-256 digest."
actual_checksum="$(shasum -a 256 "$checked_vsix" | awk '{ print $1 }')"
[[ "$actual_checksum" == "$expected_checksum" ]] ||
    fail "$checked_vsix does not match $checked_checksum."
grep -Fq "static let companionSHA256 = \"$expected_checksum\"" "$runtime_source" ||
    fail "$runtime_source does not pin the checked-in VSIX digest."

(
    cd "$extension_directory"
    npm ci
    npx --no-install tsc -p .
    npx --no-install vsce package \
        --no-yarn \
        --skip-license \
        --out "$temporary_directory/generated.vsix"
)

canonicalize_vsix \
    "$temporary_directory/generated.vsix" \
    "$temporary_directory/generated" \
    "$temporary_directory/generated-canonical.vsix"
canonicalize_vsix \
    "$checked_vsix" \
    "$temporary_directory/checked" \
    "$temporary_directory/checked-canonical.vsix"

if ! cmp -s \
    "$temporary_directory/generated-canonical.vsix" \
    "$temporary_directory/checked-canonical.vsix"
then
    diff -ru "$temporary_directory/checked" "$temporary_directory/generated" || true
    fail "The checked-in VSIX contents are stale. Run 'npm run package:vsix' and update its SHA-256 file."
fi

canonical_checksum="$(shasum -a 256 "$temporary_directory/generated-canonical.vsix" | awk '{ print $1 }')"
echo "Checked-in VSIX SHA-256: $actual_checksum"
echo "Canonical generated SHA-256: $canonical_checksum"
echo "VS Code generated output is current."
