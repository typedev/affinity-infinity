# shellcheck shell=bash
# Update check on start: a HEAD request tells whether the published installer
# changed (ETag); only then are the last 2 MB of it fetched, which hold its
# version resource, so the exact new version is known without downloading
# the whole ~650 MB installer.

VERSION_TAIL_BYTES=2097152

# How often `run` looks for new versions of Affinity and of the AppImage itself
# (config UPDATE_CHECK). "start" checks Affinity on every start; the AppImage
# is checked at most daily either way (GitHub API rate limit).
UPDATE_CHECK_MODES=(start daily weekly monthly off)

update_check_mode() {
    local mode
    mode=$(config_get UPDATE_CHECK)
    # Before UPDATE_CHECK, AUTO_UPDATE_CHECK=0 turned the start-up check off.
    [[ -z "$mode" && "$(config_get AUTO_UPDATE_CHECK 1)" == 0 ]] && mode=off
    case $mode in
        daily | weekly | monthly | off) echo "$mode" ;;
        *) echo start ;;
    esac
}

# update_due LAST [MIN]: true if an automatic check is due, LAST being the time
# of the last successful check and MIN a minimum interval in seconds.
update_due() {
    local last=${1:-0} interval=${2:-0} mode_interval
    case $(update_check_mode) in
        off) return 1 ;;
        daily) mode_interval=86400 ;;
        weekly) mode_interval=$((7 * 86400)) ;;
        monthly) mode_interval=$((30 * 86400)) ;;
        *) mode_interval=0 ;;
    esac
    ((mode_interval > interval)) && interval=$mode_interval
    (($(date +%s) - last >= interval))
}

# False when NetworkManager knows there is no internet connection (none, captive
# portal, limited), so start-up checks are skipped at once instead of waiting
# for curl's timeouts. Without NetworkManager, assume online.
online() {
    local state
    command -v gdbus >/dev/null || return 0
    state=$(timeout 1 gdbus call --system --dest org.freedesktop.NetworkManager \
        --object-path /org/freedesktop/NetworkManager \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.NetworkManager Connectivity 2>/dev/null) || return 0
    [[ ! "$state" =~ uint32\ [123]\> ]]
}

# update_auto [MODE|--gui]: show or set UPDATE_CHECK.
update_auto() {
    local mode=${1:-} m rows=()
    case $mode in
        "") update_check_mode; return 0 ;;
        --gui)
            local current title="Affinity updates" text="Look for new versions of Affinity and Affinity Infinity:"
            current=$(update_check_mode)
            for m in "${UPDATE_CHECK_MODES[@]}"; do
                case $m in
                    start) rows+=("$m" "On every start") ;;
                    daily) rows+=("$m" "Once a day") ;;
                    weekly) rows+=("$m" "Once a week") ;;
                    monthly) rows+=("$m" "Once a month") ;;
                    off) rows+=("$m" "Never (use Check for updates)") ;;
                esac
            done
            if has_gtk_ui; then
                mode=$(python3 "$ROOT/lib/choose-gui.py" "$title" "$text" "$current" "${rows[@]}") || return 0
            else
                local zrows=() i
                for ((i = 0; i < ${#rows[@]}; i += 2)); do
                    [[ ${rows[i]} == "$current" ]] && zrows+=(TRUE) || zrows+=(FALSE)
                    zrows+=("${rows[i]}" "${rows[i + 1]}")
                done
                mode=$(zenity --list --radiolist --title="$title" --text="$text" \
                    --column="" --column=mode --column="" --hide-column=2 --print-column=2 \
                    --hide-header --width=380 --height=380 "${zrows[@]}" 2>/dev/null) || return 0
            fi
            ;;
    esac
    [[ " ${UPDATE_CHECK_MODES[*]} " == *" $mode "* ]] ||
        die "unknown update check: $mode (${UPDATE_CHECK_MODES[*]})"
    config_set UPDATE_CHECK "$mode"
    log "update check: $mode"
}

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
    [[ -n "$(installed_version)" ]] || return 0
    update_due "$(state_get LAST_CHECK 0)" && online || return 0
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
