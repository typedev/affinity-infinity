# shellcheck shell=bash
# Update check on start: a HEAD request tells whether the published installer
# changed (ETag); only then are the last 2 MB of it fetched, which hold its
# version resource, so the exact new version is known without downloading
# the whole ~650 MB installer.

VERSION_TAIL_BYTES=2097152

# Print the version of the published installer (empty on failure).
remote_version() {
    local tmp version
    mkdir -p "$CACHE_DIR"
    tmp=$(mktemp "$CACHE_DIR/tail.XXXXXX")
    if curl -sf --connect-timeout 3 --max-time 15 -r "-$VERSION_TAIL_BYTES" -o "$tmp" "$AFFINITY_URL"; then
        version=$(pe_file_version "$tmp")
    fi
    rm -f "$tmp"
    printf '%s' "${version:-}"
}

# version_gt A B: true if version A is newer than B.
version_gt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# Sets NEW_VERSION and returns 0 if a newer Affinity is published, 1 if not,
# 2 if the check could not be done.
find_update() {
    NEW_VERSION=""
    local installed
    installed=$(installed_version)
    remote_info || return 2
    state_set LAST_CHECK "$(date +%s)"
    [[ -n "$installed" && "$(state_get INSTALLED_ETAG)" == "$REMOTE_ETAG" ]] && return 1

    NEW_VERSION=$(remote_version)
    if [[ -z "$NEW_VERSION" ]]; then
        # Installer layout changed? Fall back to "something new was published".
        NEW_VERSION="(published $REMOTE_MODIFIED)"
        return 0
    fi
    if [[ -n "$installed" ]] && ! version_gt "$NEW_VERSION" "$installed"; then
        # Re-published or same build: remember it so the next start is quick.
        [[ "$NEW_VERSION" == "$installed" ]] && state_set INSTALLED_ETAG "$REMOTE_ETAG"
        return 1
    fi
    return 0
}

can_show_dialogs() {
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null
}

# Ask whether to install NEW_VERSION. Prints install, later or skip.
ask_update() {
    local installed answer
    installed=$(installed_version)
    if can_show_dialogs; then
        answer=$(zenity --question --title="Affinity update" --icon=software-update-available \
            --text="Affinity $NEW_VERSION is available.\nInstalled: ${installed:-none}\n\nDownload (~650 MB) and install it now?" \
            --ok-label="Install" --cancel-label="Later" --extra-button="Skip this version" 2>/dev/null)
        case $? in
            0) echo install ;;
            *) [[ "$answer" == "Skip this version" ]] && echo skip || echo later ;;
        esac
    elif [[ -t 0 && -t 2 ]]; then
        read -r -p "Affinity $NEW_VERSION is available (installed: ${installed:-none}). Install now? [y/N/s=skip] " answer
        case $answer in
            [yY]*) echo install ;;
            [sS]*) echo skip ;;
            *) echo later ;;
        esac
    else
        echo later
    fi
}

# Run by `run` before starting Affinity. Never prevents the start: a failed
# check or install falls through to launching the installed version.
startup_update_check() {
    [[ "$(config_get AUTO_UPDATE_CHECK 1)" == 1 ]] || return 0
    [[ -n "$(installed_version)" ]] || return 0
    find_update || return 0
    [[ "$(state_get SKIPPED_VERSION)" == "$NEW_VERSION" ]] && return 0

    case $(ask_update) in
        install)
            # In a subshell, so a failure (die) returns here instead of exiting.
            (install_affinity --force) || warn "update failed; starting the installed version"
            ;;
        skip)
            state_set SKIPPED_VERSION "$NEW_VERSION"
            log "not offering Affinity $NEW_VERSION again"
            ;;
    esac
    return 0
}
