# shellcheck shell=bash
# AffinityPluginLoader + WineFix (https://github.com/noahc3/AffinityPluginLoader).
# Installed next to Affinity.exe after every Affinity install, since an MSI
# upgrade may replace files in the same directory. Affinity is then started
# through AffinityHook.exe so the WineFix patches are applied at runtime.

apl_install() {
    local archive="$CACHE_DIR/$APL_ASSET-$APL_VERSION"
    local url="https://github.com/noahc3/AffinityPluginLoader/releases/download/$APL_VERSION/$APL_ASSET"

    if [[ ! -f "$archive" ]] || ! sha256sum --status -c <<<"$APL_SHA256  $archive"; then
        log "downloading AffinityPluginLoader $APL_VERSION..."
        curl -fsSL --retry 3 -o "$archive.part" "$url" || die "failed to download $url"
        sha256sum --status -c <<<"$APL_SHA256  $archive.part" || {
            rm -f "$archive.part"
            die "checksum mismatch for $APL_ASSET $APL_VERSION"
        }
        mv "$archive.part" "$archive"
    fi

    # The archive only contains APL binaries and apl/plugins; the user's apl/config is left alone.
    tar -xJf "$archive" -C "$AFFINITY_DIR" --no-same-owner || die "failed to unpack $archive"
    [[ -f "$AFFINITY_DIR/AffinityHook.exe" ]] || die "AffinityHook.exe missing after unpacking APL"
    state_set APL_VERSION "$APL_VERSION"
    log "AffinityPluginLoader $APL_VERSION with WineFix installed"
}
