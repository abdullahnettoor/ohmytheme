#!/usr/bin/env bash
# Reports whether this machine can build and test Oh My Theme.
# It never installs software.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

xcode_hint="Install Xcode and run 'sudo xcode-select --switch /Applications/Xcode.app'."

# /usr/bin/xcodebuild is an xcode-select shim that exists even without Xcode, so ask it
# for a version instead of only looking for the executable.
if ! xcode_version_output="$(xcodebuild -version 2>&1)"; then
  fail "xcodebuild needs a full Xcode installation. $xcode_hint"
fi

xcode_version="$(printf '%s\n' "$xcode_version_output" | head -1 | awk '{print $2}')"
xcode_major_version="${xcode_version%%.*}"
if ! [[ "$xcode_major_version" =~ ^[0-9]+$ ]]; then
  fail "Could not read the Xcode version from: $xcode_version_output"
fi
if [[ "$xcode_major_version" -lt "$REQUIRED_XCODE_MAJOR_VERSION" ]]; then
  fail "Xcode $REQUIRED_XCODE_MAJOR_VERSION or later is required for Swift 6 language mode. Found $xcode_version."
fi

if [[ "${OMT_REQUIRE_PINNED_TOOLCHAIN:-0}" == "1" ]]; then
  [[ "$xcode_version" == "$PINNED_XCODE_VERSION" ]] ||
    fail "CI requires Xcode $PINNED_XCODE_VERSION. Found $xcode_version."
  [[ "$xcode_version_output" == *"Build version $PINNED_XCODE_BUILD"* ]] ||
    fail "CI requires Xcode build $PINNED_XCODE_BUILD."
fi

if ! swift_version_output="$(swift --version 2>&1)"; then
  fail "swift needs a full Xcode installation. $xcode_hint"
fi
if [[ "${OMT_REQUIRE_PINNED_TOOLCHAIN:-0}" == "1" ]]; then
  [[ "$swift_version_output" == *"Apple Swift version $PINNED_SWIFT_VERSION"* ]] ||
    fail "CI requires Apple Swift $PINNED_SWIFT_VERSION."
fi

echo "Xcode:  $xcode_version ($(xcode-select --print-path))"
echo "Swift:  $(printf '%s\n' "$swift_version_output" | head -1)"
echo "macOS:  $(sw_vers -productVersion)"
echo "Ready to build Oh My Theme."
