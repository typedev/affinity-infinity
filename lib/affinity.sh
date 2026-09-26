# shellcheck shell=bash
# Detect, download and install Affinity from the official installer.
#
# The official "Affinity x64.exe" is a small bootstrapper whose resources carry
# a regular WiX MSI. We carve that MSI out and install it with Wine's msiexec,
# so no installer GUI is needed and upgrades go through the MSI major-upgrade path.

OLE_MAGIC='\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'
INSTALLER_EXE="$CACHE_DIR/Affinity-x64.exe"

# Sets REMOTE_ETAG, REMOTE_SIZE, REMOTE_MODIFIED from a HEAD request.
remote_info() {
    local headers
    headers=$(curl -sfIL --max-time 30 "$AFFINITY_URL" | tr -d '\r') || return 1
    # With redirects, the last value of each header belongs to the final response.
    REMOTE_ETAG=$(awk -F': ' 'tolower($1)=="etag"{v=$2} END{print v}' <<<"$headers" | tr -d '"')
    REMOTE_SIZE=$(awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}' <<<"$headers")
    REMOTE_MODIFIED=$(awk -F': ' 'tolower($1)=="last-modified"{v=$2} END{print v}' <<<"$headers")
    [[ -n "$REMOTE_ETAG" && -n "$REMOTE_SIZE" ]]
}

installed_version() {
    [[ -f "$AFFINITY_DIR/Affinity.exe" ]] && pe_file_version "$AFFINITY_DIR/Affinity.exe"
}

# Returns 0 if an update (or first install) is available, 1 if up to date, 2 on error.
check_update() {
    local quiet=${1:-0}
    remote_info || { [[ "$quiet" == 1 ]] || warn "could not reach $AFFINITY_URL"; return 2; }
    state_set LAST_CHECK "$(date +%s)"

    local installed etag
    installed=$(installed_version)
    etag=$(state_get INSTALLED_ETAG)
    if [[ -z "$installed" ]]; then
        [[ "$quiet" == 1 ]] || log "Affinity is not installed; latest installer published $REMOTE_MODIFIED"
        return 0
    fi
    if [[ "$etag" == "$REMOTE_ETAG" ]]; then
        [[ "$quiet" == 1 ]] || log "Affinity $installed is up to date"
        return 1
    fi
    [[ "$quiet" == 1 ]] || log "update available: installed $installed, new installer published $REMOTE_MODIFIED"
    return 0
}

download_installer() {
    remote_info || die "could not reach $AFFINITY_URL"
    mkdir -p "$CACHE_DIR"

    if [[ -f "$INSTALLER_EXE" && "$(state_get CACHED_ETAG)" == "$REMOTE_ETAG" &&
        "$(stat -c %s "$INSTALLER_EXE")" == "$REMOTE_SIZE" ]]; then
        log "using cached installer"
        return 0
    fi

    local part="$INSTALLER_EXE.part"
    # A partial download of a different release cannot be resumed.
    if [[ "$(state_get PARTIAL_ETAG)" != "$REMOTE_ETAG" ]]; then
        rm -f "$part"
    fi
    state_set PARTIAL_ETAG "$REMOTE_ETAG"

    log "downloading installer ($((REMOTE_SIZE / 1024 / 1024)) MB)..."
    if gui_mode; then
        curl -fL -C - --retry 3 -# -o "$part" "$AFFINITY_URL" 2>&1 |
            stdbuf -oL tr '\r' '\n' | grep --line-buffered -oE '[0-9]+(\.[0-9]+)?%' | stdbuf -oL sed 's/\..*//; s/%//' |
            zenity --progress --auto-close --title="Affinity" --text="Downloading Affinity..." 2>/dev/null
    else
        curl -fL -C - --retry 3 --progress-bar -o "$part" "$AFFINITY_URL"
    fi

    [[ -f "$part" && "$(stat -c %s "$part")" == "$REMOTE_SIZE" ]] ||
        die "download incomplete; run the command again to resume"
    mv "$part" "$INSTALLER_EXE"
    state_set CACHED_ETAG "$REMOTE_ETAG"
    state_set PARTIAL_ETAG ""
}

# carve_msi <installer.exe> <out.msi>
carve_msi() {
    local exe=$1 out=$2 offset
    offset=$(LC_ALL=C grep -m1 -obUaP "$OLE_MAGIC" "$exe" | cut -d: -f1)
    [[ -n "$offset" ]] || die "no MSI found inside $exe (installer format changed?)"
    tail -c +$((offset + 1)) "$exe" >"$out.part"
    mv "$out.part" "$out"
}

# Install the MSI's files with an administrative install (msiexec /a) into a
# staging directory, then swap the program directory.
#
# A regular `msiexec /i` fails under Wine for this package: Wine copies it to
# C:\windows\Installer and cannot reopen the ~650 MB copy in transacted mode
# (STG_E_INSUFFICIENTMEMORY). /a opens the package read-only and just unpacks
# the files; the few registry values the MSI would write are set by
# affinity_registry. The user's apl/ directory (plugin config, logs) is kept.
msi_install() {
    local msi=$1 logfile rc
    local stage_rel='windows\temp\affinity-stage'
    local stage="$PREFIX_DIR/drive_c/windows/temp/affinity-stage"
    local program_files="$PREFIX_DIR/drive_c/Program Files/Affinity"
    logfile="$CACHE_DIR/msiexec-$(date +%Y%m%d-%H%M%S).log"

    rm -rf "$stage"
    log "unpacking $(basename "$msi") (takes a few minutes)..."
    WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" with_spinner "Installing Affinity..." \
        wine msiexec /a "$(to_winpath "$msi")" /qn /l*v "$(to_winpath "$logfile")" "TARGETDIR=C:\\$stage_rel"
    rc=$?
    wineserver -w
    [[ $rc == 0 ]] || die "msiexec failed with code $rc; log: $logfile"

    local new="$stage/Affinity/Affinity"
    [[ -f "$new/Affinity.exe" ]] || die "msiexec finished but Affinity.exe is missing; log: $logfile"

    mkdir -p "$program_files"
    if [[ -d "$AFFINITY_DIR/apl" ]]; then
        rm -rf "$new/apl"
        mv "$AFFINITY_DIR/apl" "$new/apl"
    fi
    rm -rf "$AFFINITY_DIR" "$program_files/Common"
    mv "$new" "$AFFINITY_DIR"
    [[ -d "$stage/Affinity/Common" ]] && mv "$stage/Affinity/Common" "$program_files/Common"
    rm -rf "$stage"

    affinity_registry
}

# Affinity renders through Direct3D 12, provided by the runtime's vkd3d-proton.
# The prefix overrides d3d12/d3d12core to "native" only, so the DLLs must sit
# next to Affinity.exe; without them Affinity's renderer libraries fail to load
# and Affinity.exe balloons until the OOM killer stops it.
install_d3d12() {
    local src="$WINE_ROOT/lib/wine/vkd3d-proton/x86_64-windows" f
    for f in d3d12.dll d3d12core.dll; do
        [[ -f "$src/$f" ]] || die "runtime has no vkd3d-proton $f ($src)"
        cp -f "$src/$f" "$AFFINITY_DIR/$f"
    done
}

# Registry values the MSI (and its WriteMachineRegistry custom action) would set.
affinity_registry() {
    local machine_id
    machine_id=$(state_get MACHINE_ID)
    if [[ -z "$machine_id" ]]; then
        # The seeded prefix carries its builder's ID; every install needs its own.
        machine_id=$(cat /proc/sys/kernel/random/uuid)
        state_set MACHINE_ID "$machine_id"
    fi
    reg_import <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Serif\\Affinity]
"Machine ID"="$machine_id"

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Serif\\Affinity\\Affinity]
"Affinity Install Path"="C:\\\\Program Files\\\\Affinity\\\\Affinity\\\\"
"Affinity Desktop Shortcut"=dword:00000000
"ML Models Path"=""
"No Crash Reports"=dword:00000001
"No ML Models Config"=dword:00000000
"No Registration"=dword:00000000
"No Update Check"=dword:00000001
EOF
}

affinity_running() {
    pgrep -f 'Affinity(Hook)?\.exe' >/dev/null
}

# install_affinity [--exe FILE | --msi FILE] [--force]
install_affinity() {
    local exe="" msi="" force=0
    while (($#)); do
        case $1 in
            --exe) exe=$2; shift 2 ;;
            --msi) msi=$2; shift 2 ;;
            --force) force=1; shift ;;
            *) die "unknown install option: $1" ;;
        esac
    done

    require_setup
    affinity_running && die "Affinity is running; close it first"
    wine_env

    local etag=""
    if [[ -z "$exe" && -z "$msi" ]]; then
        if [[ "$force" != 1 ]]; then
            local rc=0
            check_update 1 || rc=$?
            if ((rc == 1)); then
                log "Affinity $(installed_version) is already up to date (use --force to reinstall)"
                return 0
            fi
        fi
        download_installer
        exe=$INSTALLER_EXE
        etag=$REMOTE_ETAG
    fi

    local version
    if [[ -z "$msi" ]]; then
        [[ -f "$exe" ]] || die "no such file: $exe"
        version=$(pe_file_version "$exe")
        [[ -n "$version" ]] || die "cannot read installer version from $exe"
        msi="$CACHE_DIR/Affinity-$version.msi"
        [[ -f "$msi" ]] || carve_msi "$exe" "$msi"
    fi
    [[ -f "$msi" ]] || die "no such file: $msi"

    local before
    before=$(installed_version)
    msi_install "$msi"
    install_d3d12
    version=$(installed_version)
    log "Affinity ${before:+$before -> }$version installed"

    state_set INSTALLED_VERSION "$version"
    state_set INSTALLED_ETAG "$etag"
    apl_install
    prefix_configure
    prune_cache "$version"
}

# Keep the MSI of the installed version and the one before it (for rollback);
# the downloaded bootstrapper is not needed once its MSI is extracted.
prune_cache() {
    local current=$1 f
    local -a msis
    rm -f "$INSTALLER_EXE"
    state_set CACHED_ETAG ""
    mapfile -t msis < <(ls -1t "$CACHE_DIR"/Affinity-*.msi 2>/dev/null)
    local kept=0
    for f in "${msis[@]}"; do
        if [[ "$f" == "$CACHE_DIR/Affinity-$current.msi" ]]; then
            continue
        fi
        if ((kept < 1)); then
            kept=1
            continue
        fi
        rm -f "$f"
    done
}

# Per-application Wine settings for Affinity, independent of the Affinity version.
prefix_configure() {
    reg_import <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\Affinity.exe]
"DpiAwareness"="System"

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\Affinity.exe\DllOverrides]
"d2d1"="native,builtin"
EOF
}
