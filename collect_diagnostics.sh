#!/bin/bash
# Collect Battery support information using macOS tools and GNU Bash 3.2.
set -o pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C TZ=UTC COPYFILE_DISABLE=1
unset TAR_OPTIONS GZIP
umask 077
shopt -s nullglob

[[ $# -eq 0 && $EUID -ne 0 && $(uname -s) == Darwin ]] || { echo "Run as an ordinary macOS user: bash $0" >&2; exit 1; }
output="battery-diagnostics-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
echo "Collecting Battery diagnostics. Administrator permission allows reading protected installation files." >&2
sudo -v || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/battery-diagnostics.XXXXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
report="$work/battery-diagnostics"
mkdir "$report" || exit 1

# Replace private identities in command output before it enters the report.
obfuscate_user_identity() {
    local rules="" escaped_home obfuscation_status

    # Match the current home path literally, including homes outside /Users.
    if [[ -n $HOME ]]; then
        escaped_home=$(printf '%s' "$HOME" | sed 's/[][\\.^$*+?{}()|~]/\\&/g')
        rules="s~(^|[^[:alnum:]_])${escaped_home}([^[:alnum:]_]|$)~\\1<HIDDEN>\\2~g"
    fi

    # Cover identities from older log entries using Battery's specific output formats.
    rules+="
# Home paths in CLI messages, GUI errors, and collected file metadata.
s~/Users/[^/[:space:]\"'\\\\<>]+~/Users/<HIDDEN>~g
# CLI maintenance debug trail: User: account, config folder: ...
s~(User: *)[^[:space:],<>]+~\1<HIDDEN>~g
# GUI installation message and the setup command it logs.
s~(Installing battery for )[^[:space:]<>]+~\1<HIDDEN>~g
s~(bash -s -- )[[:alnum:]_.-]+~\1<HIDDEN>~g
# macOS temporary paths printed by setup.sh and update.sh.
s~/(private/)?var/folders/[^/[:space:]]+/[^/[:space:]]+~<HIDDEN>~g
# CLI daemon message: Disabling daemon at gui/501/com.battery.app
s~gui/[0-9]+~gui/<HIDDEN>~g
"

    sed -E "$rules"
    obfuscation_status=$?
    unset rules escaped_home
    return "$obfuscation_status"
}
obfuscate_user_identity < /dev/null > /dev/null || exit 1

# Original SHA-256 hashes of installed CLI files and configuration.
{
    shasum -a 256 /usr/local/co.palokaj.battery/battery
    shasum -a 256 /usr/local/co.palokaj.battery/smc
    sudo -n /usr/bin/shasum -a 256 /private/etc/sudoers.d/battery
    shasum -a 256 /etc/paths.d/50-battery
    shasum -a 256 "$HOME/Library/LaunchAgents/battery.plist"
} 2>&1 | obfuscate_user_identity > "$report/hashes.txt"

# File permissions, numeric owner/group IDs, sizes, dates, and symlink targets.
{
    ls -ldn /usr/local/co.palokaj.battery
    ls -ldn /usr/local/bin/battery
    ls -ldn /usr/local/bin/smc
    ls -ldn /usr/local/co.palokaj.battery/battery
    ls -ldn /usr/local/co.palokaj.battery/smc
    sudo -n /bin/ls -ldn /private/etc/sudoers.d/battery
    ls -ldn /etc/paths.d/50-battery
    ls -ldn "$HOME/Library/LaunchAgents/battery.plist"
    ls -ldn "$HOME/.battery/battery.log"
    ls -ldn "$HOME/.battery/gui.log"
    ls -ldn "$HOME/.battery/maintain.percentage"
    ls -ldn "$HOME/.battery/maintain.voltage"
    ls -ldn "$HOME/Library/Application Support/battery/config.json"
} 2>&1 | obfuscate_user_identity > "$report/files.txt"

# Collect configuration, logs, and charging settings into named text files.
sudo -n /bin/cat /private/etc/sudoers.d/battery 2>&1 | obfuscate_user_identity > "$report/sudoers.txt"
cat /etc/paths.d/50-battery 2>&1 | obfuscate_user_identity > "$report/paths.d.txt"
cat "$HOME/.battery/battery.log" 2>&1 | obfuscate_user_identity > "$report/battery.log"
cat "$HOME/.battery/gui.log" 2>&1 | obfuscate_user_identity > "$report/gui.log"
cat "$HOME/.battery/maintain.percentage" 2>&1 | obfuscate_user_identity > "$report/maintain.percentage.txt"
cat "$HOME/.battery/maintain.voltage" 2>&1 | obfuscate_user_identity > "$report/maintain.voltage.txt"
cat "$HOME/Library/Application Support/battery/config.json" 2>&1 | obfuscate_user_identity > "$report/gui-config.json"

# macOS, hardware model, firmware, and installed GUI versions.
{ sw_vers; uname -srm; sysctl hw.model; } 2>&1 | obfuscate_user_identity > "$report/system.txt"
system_profiler SPHardwareDataType -detailLevel mini 2>/dev/null |
    awk '/^[[:space:]]*(Model Name|Model Identifier|Chip|System Firmware Version|OS Loader Version|Boot ROM Version|SMC Version \(system\)):/' |
    obfuscate_user_identity >> "$report/system.txt"
for app in /Applications/[Bb]attery*.app "$HOME"/Applications/[Bb]attery*.app; do
    printf '%s: ' "$app"
    plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"
    printf '\n'
done 2>&1 | obfuscate_user_identity > "$report/gui-version.txt"

# Archive with private permissions and standard root:wheel ownership.
(set -C; tar --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname wheel -czf - -C "$work" battery-diagnostics > "$output") || exit 1
printf 'Created %s\n' "$output"
