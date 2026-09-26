# shellcheck shell=bash
# Font fixes for Affinity's UI. Affinity (WinUI + its own DWriteCore) asks for
# "Segoe UI" and builds its font collection from the registry font lists.

# The seeded prefix's 64-bit font lists lack the regular faces of Arial, Times
# New Roman, Courier New and all of Tahoma, although the files are in
# windows/Fonts and the 32-bit (Wow6432Node) list has them. Affinity's
# DWriteCore builds its font collection from these lists, so its Segoe UI ->
# Tahoma -> Arial fallback ended at Arial Italic: the whole UI in italics.
# Copy the complete 32-bit list into both 64-bit keys.
fix_font_registry() {
    local wow='[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Fonts]'
    local entries
    entries=$(K=$wow awk '
        index($0, ENVIRON["K"]) == 1 { f = 1; next }
        f && /^\[/ { exit }
        f && /^"[^"]+"="[^"]+"$/ { print }' "$PREFIX_DIR/system.reg")
    [[ -n "$entries" ]] || { warn "no 32-bit font list found; font registry left unchanged"; return 0; }
    register_fonts <<<"$entries" || warn "failed to update the font registry"
}

# register_fonts < lines of "Name (TrueType)"="file.ttf": add them to both 64-bit font lists.
register_fonts() {
    local entries
    entries=$(cat)
    reg_import <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]
$entries

[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Fonts]
$entries
EOF
}

# Segoe UI is not redistributable. Selawik is Microsoft's metric-compatible open
# (OFL) substitute; it is renamed to "Segoe UI" here, on the user's machine, and
# installed under the standard Windows file names (which the prefix's FontLink
# entries already reference). Without it the UI falls back to Tahoma.
install_segoe_ui() {
    local fonts="$PREFIX_DIR/drive_c/windows/Fonts" marker="selawik-$SELAWIK_VERSION"
    [[ "$(state_get SEGOE_UI)" == "$marker" ]] && return 0
    if [[ -f "$fonts/segoeui.ttf" && -z "$(state_get SEGOE_UI)" ]]; then
        log "a Segoe UI is already installed in the prefix; leaving it alone"
        return 0
    fi
    command -v python3 >/dev/null || { warn "python3 not found; skipping Segoe UI substitute (UI will use Tahoma)"; return 0; }

    local archive="$CACHE_DIR/Selawik-$SELAWIK_VERSION.zip"
    if [[ ! -f "$archive" ]] || ! sha256sum --status -c <<<"$SELAWIK_SHA256  $archive"; then
        log "downloading Selawik $SELAWIK_VERSION..."
        curl -fsSL --retry 3 -o "$archive.part" "$SELAWIK_URL" || { warn "failed to download Selawik"; return 0; }
        sha256sum --status -c <<<"$SELAWIK_SHA256  $archive.part" || {
            rm -f "$archive.part"
            warn "checksum mismatch for Selawik $SELAWIK_VERSION"
            return 0
        }
        mv "$archive.part" "$archive"
    fi

    # Selawik file -> Segoe UI file, registry name.
    local -a map=(
        "selawk.ttf segoeui.ttf Segoe UI"
        "selawkb.ttf segoeuib.ttf Segoe UI Bold"
        "selawkl.ttf segoeuil.ttf Segoe UI Light"
        "selawksb.ttf seguisb.ttf Segoe UI Semibold"
        "selawksl.ttf segoeuisl.ttf Segoe UI Semilight"
    )
    local tmp entry src dst name entries=""
    tmp=$(mktemp -d "$CACHE_DIR/selawik.XXXXXX")
    for entry in "${map[@]}"; do
        read -r src dst name <<<"$entry"
        if ! python3 -c 'import sys, zipfile; open(sys.argv[3], "wb").write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' \
            "$archive" "$src" "$tmp/$src" ||
            ! python3 "$ROOT/lib/rename-font.py" "$tmp/$src" "$fonts/$dst" Selawik "Segoe UI"; then
            rm -rf "$tmp"
            warn "failed to build $dst from Selawik"
            return 0
        fi
        entries+="\"$name (TrueType)\"=\"$dst\""$'\n'
    done
    rm -rf "$tmp"

    register_fonts <<<"$entries" || { warn "failed to register Segoe UI"; return 0; }
    state_set SEGOE_UI "$marker"
    log "installed Selawik $SELAWIK_VERSION as Segoe UI"
}
