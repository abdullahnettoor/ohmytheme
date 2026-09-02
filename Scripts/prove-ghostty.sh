#!/usr/bin/env bash
# Runs a disposable Ghostty configuration ownership and validation proof.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool ghostty "Install Ghostty 1.3.0 or later to run this proof."

temporary_directory="$(mktemp -d)"
temporary_home="$temporary_directory/home"
xdg_config_home="$temporary_home/xdg"
config_directory="$xdg_config_home/ghostty"
parent_config="$config_directory/config.ghostty"
legacy_config="$config_directory/config"
managed_directory="$config_directory/oh-my-theme"
managed_fragment="$managed_directory/config.ghostty"
invalid_config="$temporary_directory/invalid.ghostty"

cleanup() {
    rm -f "$invalid_config" "$temporary_directory/original-parent.ghostty"
    rm -f "$managed_fragment" "$parent_config" "$legacy_config"
    rmdir "$managed_directory" "$config_directory" "$xdg_config_home" "$temporary_home" "$temporary_directory"
}
trap cleanup EXIT

mkdir -p "$managed_directory"
printf 'background = #010101\n' > "$legacy_config"
printf 'background = #101010\nforeground = #123456\n' > "$parent_config"

discovered_configuration="$(
    HOME="$temporary_home" XDG_CONFIG_HOME="$xdg_config_home" ghostty +show-config --changes-only
)"
grep -Fx "background = #101010" <<< "$discovered_configuration" >/dev/null ||
    fail "Ghostty did not prefer config.ghostty over the legacy config file."

printf 'background = #abcdef\n' > "$managed_fragment"
printf 'config-file = ?oh-my-theme/config.ghostty\n' >> "$parent_config"
cp "$parent_config" "$temporary_directory/original-parent.ghostty"

HOME="$temporary_home" XDG_CONFIG_HOME="$xdg_config_home" \
    ghostty +validate-config --config-file="$parent_config"

resolved_configuration="$(
    HOME="$temporary_home" XDG_CONFIG_HOME="$xdg_config_home" ghostty +show-config --changes-only
)"
grep -Fx "background = #abcdef" <<< "$resolved_configuration" >/dev/null ||
    fail "Ghostty did not apply the managed fragment after its parent configuration."
grep -Fx "foreground = #123456" <<< "$resolved_configuration" >/dev/null ||
    fail "Ghostty did not preserve the parent configuration."
cmp --silent "$parent_config" "$temporary_directory/original-parent.ghostty" ||
    fail "Ghostty changed the reviewed parent configuration."

printf 'not-a-ghostty-option = true\n' > "$invalid_config"
if HOME="$temporary_home" XDG_CONFIG_HOME="$xdg_config_home" \
    ghostty +validate-config --config-file="$invalid_config" >/dev/null 2>&1
then
    fail "Ghostty accepted an invalid configuration."
fi

ghostty +version | head -1
echo "Ghostty configuration proof passed. All test files were created under $temporary_directory."
