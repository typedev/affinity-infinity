# shellcheck shell=bash
# Updates of the AppImage itself (not of Affinity): at most once a day, ask
# GitHub for the latest release; if it is newer, offer to download it next to
# the running AppImage, check its sha256, swap it in and restart.

SELFUPDATE_INTERVAL=$((24 * 3600))

current_release() {
    [[ -f "$ROOT/VERSION" ]] && head -1 "$ROOT/VERSION"
}

# Sets REL_TAG, REL_APPIMAGE_URL, REL_SHA256_URL, REL_PAGE from the latest release.
latest_release() {
    local json
    json=$(curl -sf --connect-timeout 3 --max-time 10 \
        -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AI_REPO/releases/latest") || return 1
    REL_TAG=$(sed -n 's/^  "tag_name": "\(.*\)",$/\1/p' <<<"$json" | head -1)
    REL_PAGE=$(sed -n 's/^  "html_url": "\(.*\)",$/\1/p' <<<"$json" | head -1)
    REL_APPIMAGE_URL=$(grep -o '"browser_download_url": "[^"]*x86_64\.AppImage"' <<<"$json" | head -1 | cut -d'"' -f4)
    REL_SHA256_URL=$(grep -o '"browser_download_url": "[^"]*x86_64\.AppImage\.sha256"' <<<"$json" | head -1 | cut -d'"' -f4)
    [[ -n "$REL_TAG" && -n "$REL_APPIMAGE_URL" && -n "$REL_SHA256_URL" ]]
}

# Replace $APPIMAGE with the release's AppImage. Returns non-zero on failure.
selfupdate_install() {
    local new="$APPIMAGE.new" sums expected
    log "downloading Affinity Infinity $REL_TAG..."
    if gui_mode; then
        curl -fL --retry 3 -# -o "$new" "$REL_APPIMAGE_URL" 2>&1 |
            stdbuf -oL tr '\r' '\n' | grep --line-buffered -oE '[0-9]+(\.[0-9]+)?%' | stdbuf -oL sed 's/\..*//; s/%//' |
            zenity --progress --auto-close --title="Affinity Infinity" --text="Downloading Affinity Infinity $REL_TAG..." 2>/dev/null
    else
        curl -fL --retry 3 --progress-bar -o "$new" "$REL_APPIMAGE_URL"
    fi
    sums=$(curl -fsSL --retry 3 "$REL_SHA256_URL") || { rm -f "$new"; warn "could not fetch the checksum"; return 1; }
    expected=$(awk '{print $1; exit}' <<<"$sums")
    if [[ ! -f "$new" || "$(sha256sum "$new" | cut -d' ' -f1)" != "$expected" ]]; then
        rm -f "$new"
        warn "downloaded AppImage failed the checksum check"
        return 1
    fi
    chmod +x "$new"
    mv -f "$new" "$APPIMAGE"
    log "Affinity Infinity updated to $REL_TAG"
}

# Run by `run` first thing. Never blocks the start on errors. $@: run's arguments.
selfupdate_check() {
    [[ -n "${APPIMAGE:-}" && -n "${AI_REPO:-}" ]] || return 0
    [[ "$(config_get SELF_UPDATE_CHECK 1)" == 1 ]] || return 0
    local current last now
    current=$(current_release)
    [[ -n "$current" ]] || return 0
    last=$(state_get SELFUPDATE_LAST_CHECK 0)
    now=$(date +%s)
    ((now - last >= SELFUPDATE_INTERVAL)) || return 0
    state_set SELFUPDATE_LAST_CHECK "$now"

    latest_release || return 0
    version_gt "${REL_TAG#v}" "${current#v}" || return 0
    [[ "$(state_get SKIPPED_RELEASE)" == "$REL_TAG" ]] && return 0

    if [[ ! -w "$(dirname "$APPIMAGE")" ]]; then
        can_show_dialogs && zenity --info --title="Affinity Infinity" \
            --text="Affinity Infinity $REL_TAG is available:\n$REL_PAGE" 2>/dev/null
        return 0
    fi
    local answer=later
    if can_show_dialogs; then
        answer=$(zenity --question --title="Affinity Infinity update" \
            --text="Affinity Infinity $REL_TAG is available (installed: $current).\n\nUpdate now? It restarts afterwards." \
            --ok-label="Update" --cancel-label="Later" --extra-button="Skip this version" 2>/dev/null) && answer=install
        [[ "$answer" == "Skip this version" ]] && answer=skip
    fi
    case $answer in
        install)
            if selfupdate_install; then
                exec "$APPIMAGE" run "$@"
            fi
            ;;
        skip) state_set SKIPPED_RELEASE "$REL_TAG" ;;
    esac
    return 0
}
