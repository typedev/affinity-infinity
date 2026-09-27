#!/usr/bin/env bash
# Install Affinity Infinity for the current user, or remove it:
#   curl -fsSL https://raw.githubusercontent.com/typedev/affinity-infinity/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/typedev/affinity-infinity/main/install.sh | bash -s -- --uninstall
# Installs the latest AppImage into ~/Applications (AFFINITY_INFINITY_BIN_DIR),
# adds "Affinity" to the applications menu and starts the first-run setup.
set -euo pipefail

REPO=typedev/affinity-infinity
DEST_DIR=${AFFINITY_INFINITY_BIN_DIR:-$HOME/Applications}
APP="$DEST_DIR/Affinity-Infinity-x86_64.AppImage"
XDG_DATA=${XDG_DATA_HOME:-$HOME/.local/share}
DATA_DIR=${AFFINITY_INFINITY_DATA:-$XDG_DATA/affinity-infinity}
CONFIG_DIR=${AFFINITY_INFINITY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/affinity-infinity}

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

# Questions go to the terminal even when this script is piped into bash.
ask() {
    local answer=""
    [[ -r /dev/tty ]] || return 1
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty || true
    [[ "$answer" == [yY]* ]]
}

uninstall() {
    say "Removing Affinity Infinity"
    rm -f "$XDG_DATA/applications/affinity-infinity.desktop" \
        "$XDG_DATA/icons/hicolor/scalable/apps/affinity-infinity.svg" \
        "$XDG_DATA/mime/packages/affinity-infinity.xml" \
        "$APP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$XDG_DATA/applications" 2>/dev/null
    command -v update-mime-database >/dev/null && update-mime-database "$XDG_DATA/mime" 2>/dev/null
    note "menu entry and $APP removed"
    if [[ -d "$DATA_DIR" ]]; then
        note "$DATA_DIR holds Affinity, its settings and anything saved inside its Windows folders ($(du -sh "$DATA_DIR" | cut -f1))."
        if ask "Delete it too?"; then
            rm -rf "${DATA_DIR:?}" "${CONFIG_DIR:?}"
            note "deleted"
        else
            note "kept"
        fi
    fi
}

install() {
    [[ "$(uname -m)" == x86_64 ]] || die "only x86_64 is supported"
    local c
    for c in curl sha256sum; do
        command -v "$c" >/dev/null || die "$c is required"
    done
    if ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; then
        die "FUSE is missing; install it first: 'sudo apt install fuse3' (Ubuntu/Debian) or 'sudo dnf install fuse3' (Fedora)"
    fi
    command -v zenity >/dev/null || note "zenity is not installed: setup dialogs will not be shown (sudo apt/dnf install zenity)"
    command -v python3 >/dev/null || note "python3 is not installed: the font manager and Affinity's menu icon need it"

    say "Looking up the latest release"
    local json url sums_url tag expected
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest") ||
        die "could not reach GitHub"
    tag=$(sed -n 's/^  "tag_name": "\(.*\)",$/\1/p' <<<"$json" | head -1)
    url=$(grep -o '"browser_download_url": "[^"]*/Affinity-Infinity-[^"/]*-x86_64\.AppImage"' <<<"$json" | head -1 | cut -d'"' -f4)
    sums_url=$(grep -o '"browser_download_url": "[^"]*/Affinity-Infinity-[^"/]*-x86_64\.AppImage\.sha256"' <<<"$json" | head -1 | cut -d'"' -f4)
    [[ -n "$url" && -n "$sums_url" ]] || die "no AppImage found in the latest release"

    say "Downloading Affinity Infinity $tag"
    mkdir -p "$DEST_DIR"
    curl -fL --retry 3 --progress-bar -o "$APP.part" "$url"
    expected=$(curl -fsSL "$sums_url" | awk '{print $1; exit}')
    [[ "$(sha256sum "$APP.part" | cut -d' ' -f1)" == "$expected" ]] || {
        rm -f "$APP.part"
        die "checksum mismatch; try again"
    }
    chmod +x "$APP.part"
    mv -f "$APP.part" "$APP"
    note "$APP"

    say "Adding Affinity to the applications menu"
    "$APP" desktop

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        if [[ -f "$DATA_DIR/prefix/system.reg" ]]; then
            say "Starting Affinity"
        else
            say "Starting the setup: follow the window that opens (about 15 minutes, once)"
        fi
        setsid "$APP" </dev/null >/dev/null 2>&1 &
    else
        say "Done. Start Affinity from the applications menu, or run: $APP"
    fi
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "") install ;;
    *) die "unknown option: $1 (use --uninstall to remove)" ;;
esac
