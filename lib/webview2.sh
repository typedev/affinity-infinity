# shellcheck shell=bash
# Microsoft Edge WebView2 Runtime, used by Affinity's web-based panels (home
# screen, account sign-in, help). EXPERIMENTAL, not part of `install`: with the
# seeded Wine 11.0 the browser process crashes (Chromium CHECK failures in the
# GPU and browser processes) and Affinity dies with an unhandled exception when
# Help is opened; without WebView2 Help just does not open. Installed once per prefix from a pinned
# standalone installer known to work under Wine; Edge Update is then disabled
# so it does not replace that version with one that may not.

webview2_version() {
    local dir="$PREFIX_DIR/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application" d
    for d in "$dir"/*/msedgewebview2.exe; do
        [[ -f "$d" ]] && basename "$(dirname "$d")"
    done | sort -V | tail -1
}

webview2_install() {
    local installed
    installed=$(webview2_version)
    if [[ -z "$installed" ]]; then
        local installer="$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64-$WEBVIEW2_SHA256.exe"
        if [[ ! -f "$installer" ]]; then
            log "downloading WebView2 runtime ($WEBVIEW2_LABEL)..."
            curl -fL --retry 3 --progress-bar -o "$installer.part" "$WEBVIEW2_URL" ||
                { warn "failed to download WebView2; web panels will not work"; return 0; }
            sha256sum --status -c <<<"$WEBVIEW2_SHA256  $installer.part" || {
                rm -f "$installer.part"
                warn "checksum mismatch for the WebView2 installer"
                return 0
            }
            mv "$installer.part" "$installer"
        fi

        log "installing WebView2 runtime (takes a minute)..."
        # Edge Update's own threads die with access-denied exceptions under Wine
        # and its service lingers, so neither the exit code nor `wineserver -w`
        # is meaningful here; success is judged by the installed files.
        WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" with_spinner "Installing WebView2..." \
            timeout 600 wine "$(to_winpath "$installer")" /silent /install >/dev/null 2>&1
        installed=$(webview2_version)
        [[ -n "$installed" ]] || { warn "WebView2 installation failed; web panels will not work"; return 0; }
        rm -f "$installer"
    fi

    webview2_configure
    wineserver -k # stop the Edge Update processes the installer left running
    state_set WEBVIEW2_VERSION "$installed"
    log "WebView2 runtime $installed ready"
}

webview2_configure() {
    reg_import <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdate]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdatem]
"Start"=dword:00000004

[HKEY_CURRENT_USER\Software\Wine\AppDefaults\msedgewebview2.exe]
"Version"="win11"
EOF
}
