# shellcheck shell=bash
# FontSync: an AffinityPluginLoader plugin (plugin/FontSync/FontSync.cs) that
# loads the fonts enabled with the fonts command into Affinity and applies
# changes while it runs. It is compiled here, on the user's machine, with the
# C# compiler of the prefix's .NET Framework 4.8 against the installed APL, so
# no binary is shipped. Rebuilt when the source or the APL version changes.

FONTSYNC_SRC="$ROOT/plugin/FontSync/FontSync.cs"
FONTSYNC_DLL="$AFFINITY_DIR/apl/plugins/FontSync.dll"

fontsync_hash() {
    { cat "$FONTSYNC_SRC"; printf '%s\n' "$APL_VERSION"; } | sha256sum | cut -d' ' -f1
}

fontsync_outdated() {
    [[ -f "$FONTSYNC_SRC" ]] || return 1
    [[ -f "$FONTSYNC_DLL" ]] || return 0
    [[ "$(state_get FONTSYNC_HASH)" != "$(fontsync_hash)" ]]
}

# Build and install the plugin. Failure only costs the font manager, so it warns
# instead of stopping the install or the start of Affinity.
fontsync_install() {
    local csc='C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    local out="$CACHE_DIR/FontSync.dll" logfile="$CACHE_DIR/fontsync-build.log" attempt
    [[ -f "$FONTSYNC_SRC" ]] || return 0
    [[ -f "$AFFINITY_DIR/AffinityPluginLoader.dll" ]] || { warn "AffinityPluginLoader missing; font manager plugin not built"; return 0; }
    mkdir -p "$CACHE_DIR" "$(dirname "$FONTSYNC_DLL")"
    # csc.exe is a .NET program: unlike other tooling runs, keep mscoree enabled.
    # Under Wine it rarely dies with an internal compiler error (0xc06d007e); retry once.
    for attempt in 1 2; do
        rm -f "$out"
        with_spinner "Building the font manager plugin..." \
            wine "$csc" /nologo /target:library /platform:x64 /optimize \
            "/out:$(to_winpath "$out")" \
            "/r:$AFFINITY_WIN_DIR\\AffinityPluginLoader.dll" "/r:$AFFINITY_WIN_DIR\\0Harmony.dll" \
            "$(to_winpath "$FONTSYNC_SRC")" >"$logfile" 2>&1
        wineserver -w
        [[ -s "$out" ]] && break
        ((attempt == 1)) && warn "building the font manager plugin failed; retrying"
    done
    if [[ ! -s "$out" ]]; then
        warn "failed to build the font manager plugin (see $logfile)"
        return 0
    fi
    mv -f "$out" "$FONTSYNC_DLL"
    state_set FONTSYNC_HASH "$(fontsync_hash)"
    log "font manager plugin installed"
}
