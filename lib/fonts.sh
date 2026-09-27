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

# Segoe UI is not redistributable, so Affinity's requests for it go to Tahoma
# (the font Wine's UI uses anyway); the substitute makes that explicit for GDI.
# Earlier versions installed Selawik renamed to "Segoe UI": remove those files.
# A real Segoe UI copied into the prefix by the user is used as is.
segoe_ui_substitute() {
    local fonts="$PREFIX_DIR/drive_c/windows/Fonts" f value='"Segoe UI"="Tahoma"'
    if [[ "$(state_get SEGOE_UI)" == selawik-* ]]; then
        for f in segoeui.ttf segoeuib.ttf segoeuil.ttf seguisb.ttf segoeuisl.ttf; do
            rm -f "${fonts:?}/$f"
        done
        register_fonts <<'EOF' || warn "failed to unregister the old Segoe UI substitute"
"Segoe UI (TrueType)"=-
"Segoe UI Bold (TrueType)"=-
"Segoe UI Light (TrueType)"=-
"Segoe UI Semibold (TrueType)"=-
"Segoe UI Semilight (TrueType)"=-
EOF
        state_set SEGOE_UI ""
    fi
    [[ -f "$fonts/segoeui.ttf" ]] && value='"Segoe UI"=-'
    reg_import <<EOF || warn "failed to set the Segoe UI substitute"
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes]
$value
EOF
}
