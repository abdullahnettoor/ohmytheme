#!/usr/bin/env bash
# Runs the VS Code companion unit proof. Set
# OMT_REQUIRE_VSCODE_HOST_TESTS=1 to add the pinned live-host proof.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool node "Install Node.js using the version in .node-version."
require_tool npm "Install npm 11.16.0."
require_tool npx "Install npm 11.16.0."

extension_directory="$REPO_ROOT/Extensions/VSCode/oh-my-theme-companion"

(
    cd "$extension_directory"
    npm ci
    npx --no-install tsc -p .
    npx --no-install mocha 'out/test/unit/**/*.test.js'
)

if [[ "${OMT_REQUIRE_VSCODE_HOST_TESTS:-0}" != "1" ]]; then
    echo "Skipping the network-heavy VS Code host proof. Set OMT_REQUIRE_VSCODE_HOST_TESTS=1 to require it."
    exit 0
fi

echo "Running required VS Code 1.136.0 extension-host tests..."
(cd "$extension_directory" && node ./out/test/host/runTest.js)
