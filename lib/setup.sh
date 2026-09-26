# shellcheck shell=bash
# Seed the Wine runtime and base prefix from an existing Affinity AppImage.
# The Affinity program files inside it are dropped: Affinity itself is always
# installed from the official installer (see affinity.sh).

setup_from_appimage() {
    local appimage=$1 force=${2:-0}
    [[ -f "$appimage" ]] || die "no such file: $appimage"
    appimage=$(readlink -f "$appimage")

    if is_setup && [[ "$force" != 1 ]]; then
        die "already set up in $DATA_DIR (use --force to replace runtime and prefix)"
    fi

    mkdir -p "$DATA_DIR" "$RUNTIME_DIR" "$CACHE_DIR"
    local work="$DATA_DIR/.extract"
    rm -rf "$work"
    mkdir -p "$work"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT

    log "extracting $appimage (a few GB, this takes a while)..."
    [[ -x "$appimage" ]] || chmod +x "$appimage" 2>/dev/null || true
    (cd "$work" && "$appimage" --appimage-extract >/dev/null) || die "AppImage extraction failed"

    local root="$work/squashfs-root"
    [[ -x "$root/usr/bin/wine" ]] || die "no Wine found in AppImage (usr/bin/wine)"
    [[ -f "$root/wineprefix/system.reg" ]] || die "no Wine prefix found in AppImage (wineprefix/)"

    local wine_version
    wine_version=$(LD_LIBRARY_PATH="$root/usr/lib/wine/x86_64-unix:$root/usr/lib" "$root/usr/bin/wine" --version 2>/dev/null) ||
        die "bundled Wine does not run on this system"
    log "found $wine_version"

    # Runtime: runtime/<wine-version>, with runtime/current pointing at it.
    local rt="$RUNTIME_DIR/$wine_version"
    rm -rf "$rt"
    mv "$root/usr" "$rt"
    ln -sfn "$wine_version" "$RUNTIME_DIR/current"

    # Prefix: drop the bundled Affinity and host-specific drive links.
    local pfx="$root/wineprefix"
    rm -rf "$pfx/drive_c/Program Files/Affinity"
    find "$pfx/dosdevices" -mindepth 1 -maxdepth 1 ! -name 'c:' -exec rm -rf {} +
    # Wine only creates z: for a brand-new prefix; msiexec and file opening need it.
    ln -sfn / "$pfx/dosdevices/z:"
    retarget_user_paths "$pfx"

    prefix_backup
    mv "$pfx" "$PREFIX_DIR"
    [[ -f "$root/affinity.svg" ]] && cp "$root/affinity.svg" "$DATA_DIR/icon.svg"

    rm -rf "$work"
    trap - EXIT

    log "updating prefix for this user..."
    wine_env
    WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" wine wineboot -u >/dev/null 2>&1 || warn "wineboot -u returned an error"
    wineserver -w

    state_set WINE_VERSION "$wine_version"
    state_set SEED_SOURCE "$(basename "$appimage")"
    state_set DPI_APPLIED ""
    state_set PREFIX_CONFIGURED ""

    import_legacy_dpi
    log "environment ready in $DATA_DIR"
}

# Identifies the Wine build: our builds carry a BUILD file (same Wine version
# can ship with different patches); otherwise the plain version string.
wine_build_id() {
    if [[ -f "$WINE_ROOT/BUILD" ]]; then
        head -1 "$WINE_ROOT/BUILD"
    else
        wine --version 2>/dev/null
    fi
}

# After the Wine build changed (e.g. a new AppImage), update the prefix to it
# before starting anything else in it. Expects wine_env.
sync_wine_build() {
    local build
    build=$(wine_build_id)
    [[ -n "$build" ]] || die "bundled Wine does not run on this system ($WINE_ROOT)"
    [[ "$(state_get WINE_VERSION)" == "$build" ]] && return 0
    log "updating the Wine prefix for $build..."
    WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" with_spinner "Updating the Windows environment..." \
        wine wineboot -u >/dev/null 2>&1 || warn "wineboot -u returned an error"
    wineserver -w
    state_set WINE_VERSION "$build"
}

# The seeded registry points TEMP, Documents etc. at C:\users\<builder>, which
# does not exist here (a missing TEMP even breaks msiexec). Point them at $USER.
retarget_user_paths() {
    local pfx=$1 old
    old=$(sed -nE 's/^"TEMP"="C:\\\\users\\\\([^\\]+)\\\\.*/\1/p' "$pfx/user.reg" | head -1)
    [[ -n "$old" && "$old" != "$USER" ]] || return 0
    log "retargeting user paths from '$old' to '$USER'"
    # shellcheck disable=SC1003 # literal backslashes of .reg paths
    local from='\\\\users\\\\'"$old" to='\\\\users\\\\'"$USER"
    sed -i -e "s#${from}\\\\\\\\#${to}\\\\\\\\#g" -e "s#${from}\"#${to}\"#g" \
        "$pfx/user.reg" "$pfx/system.reg" "$pfx/userdef.reg"
    if [[ -d "$pfx/drive_c/users/$old" && ! -e "$pfx/drive_c/users/$USER" ]]; then
        mv "$pfx/drive_c/users/$old" "$pfx/drive_c/users/$USER"
    fi
}

# Carry over the DPI chosen in the old ryzendew AppImage, if any.
import_legacy_dpi() {
    local legacy="$HOME/.affinity-appimage-dpi.conf" dpi
    [[ -z "$(config_get DPI)" && -f "$legacy" ]] || return 0
    dpi=$(tr -dc '0-9' <"$legacy")
    if [[ -n "$dpi" ]] && ((dpi >= 96 && dpi <= 480)); then
        config_set DPI "$dpi"
        log "imported DPI $dpi from $legacy"
    fi
}
