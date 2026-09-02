#!/usr/bin/env bash
# Runs every automated test in the repository.

set -euo pipefail
script_directory="$(dirname "${BASH_SOURCE[0]}")"

"$script_directory/test-package.sh"
"$script_directory/test-themes.sh"
"$script_directory/test-app.sh"
