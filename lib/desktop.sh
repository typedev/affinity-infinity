# shellcheck shell=bash
# Desktop menu entry, icon and file associations for Affinity documents.
# Entries run launcher_path: the AppImage when running from one, else this script.

DESKTOP_ID="$AI_NAME.desktop"
# The font manager window; named after its application id (lib/fonts-gui.py),
# which Wayland shells match to find the entry and its icon.
FONTS_DESKTOP_ID="io.github.typedev.AffinityInfinity.Fonts.desktop"
ICON_NAME="$AI_NAME"
MIME_TYPE="application/x-affinity"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

# With a separate data dir (AFFINITY_INFINITY_DATA, e.g. a test install) the
# menu entries keep pointing at the user's installation: only an explicit
# `desktop` command writes them.
isolated_data() {
    [[ -n "${AFFINITY_INFINITY_DATA:-}" ]]
}

# An entry that Gear Lever or AppImageLauncher already created for this AppImage.
foreign_integration() {
    [[ -n "${APPIMAGE:-}" ]] || return 1
    local f
    for f in "$APPS_DIR"/gearlever_*.desktop "$APPS_DIR"/appimagekit_*.desktop; do
        if [[ -f "$f" ]] && grep -qF "$APPIMAGE" "$f"; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# Print the icon name for the menu entry: Affinity's own icon, extracted from
# the installed Affinity.exe on this machine (never shipped by us), unless
# ICON=own is configured or it cannot be extracted; else ours.
desktop_icon() {
    local icons=$1 png="$1/256x256/apps/$AI_NAME-app.png"
    if [[ "$(config_get ICON affinity)" != own && -f "$AFFINITY_DIR/Affinity.exe" ]] &&
        command -v python3 >/dev/null && mkdir -p "$(dirname "$png")" &&
        python3 "$ROOT/lib/extract-icon.py" "$AFFINITY_DIR/Affinity.exe" "$png" 2>/dev/null; then
        echo "$AI_NAME-app"
    else
        echo "$ICON_NAME"
    fi
}

install_fonts_desktop() {
    local exe=$1
    mkdir -p "$APPS_DIR"
    cat >"$APPS_DIR/$FONTS_DESKTOP_ID" <<EOF
[Desktop Entry]
Type=Application
Name=Affinity Fonts
Comment=Choose the fonts Affinity sees; changes apply while it runs
Icon=preferences-desktop-font
TryExec=$exe
Exec="$exe" fonts --gui
Terminal=false
Categories=Graphics;
Keywords=font;typeface;Affinity;
StartupNotify=true
EOF
}

install_desktop() {
    local data="${XDG_DATA_HOME:-$HOME/.local/share}" exe foreign icon
    local mime="$data/mime" icons="$data/icons/hicolor"
    exe=$(launcher_path)
    install_fonts_desktop "$exe"
    if foreign=$(foreign_integration); then
        log "already in the menu via $(basename "$foreign"); only adding Affinity Fonts"
        return 0
    fi

    mkdir -p "$APPS_DIR" "$mime/packages" "$icons/scalable/apps"
    cp -f "$ROOT/share/$AI_NAME.svg" "$icons/scalable/apps/$ICON_NAME.svg"
    icon=$(desktop_icon "$icons")

    cat >"$APPS_DIR/$DESKTOP_ID" <<EOF
[Desktop Entry]
Type=Application
Name=Affinity
GenericName=Graphic Design
Comment=Affinity by Canva on Wine, managed by Affinity Infinity
Icon=$icon
TryExec=$exe
Exec="$exe" run %F
Terminal=false
Categories=Graphics;VectorGraphics;RasterGraphics;Publishing;
MimeType=$MIME_TYPE;
StartupNotify=true
StartupWMClass=affinity.exe
Actions=update;scale;

[Desktop Action update]
Name=Check for updates
Exec="$exe" update --gui

[Desktop Action scale]
Name=Interface scale…
Exec="$exe" dpi --gui
EOF

    cat >"$mime/packages/$AI_NAME.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="$MIME_TYPE">
    <comment>Affinity document</comment>
    <glob pattern="*.af"/>
    <glob pattern="*.afdesign"/>
    <glob pattern="*.afphoto"/>
    <glob pattern="*.afpub"/>
    <glob pattern="*.aftemplate"/>
  </mime-type>
</mime-info>
EOF

    command -v update-mime-database >/dev/null && update-mime-database "$mime" >/dev/null 2>&1
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$icons" >/dev/null 2>&1
    log "menu entries installed: $APPS_DIR/$DESKTOP_ID, $FONTS_DESKTOP_ID"
}

# Keep our entry pointing at the AppImage after it was moved or replaced.
refresh_desktop() {
    [[ -n "${APPIMAGE:-}" && -f "$APPS_DIR/$DESKTOP_ID" ]] && ! isolated_data || return 0
    grep -qxF "TryExec=$APPIMAGE" "$APPS_DIR/$DESKTOP_ID" &&
        grep -qxF "TryExec=$APPIMAGE" "$APPS_DIR/$FONTS_DESKTOP_ID" 2>/dev/null && return 0
    install_desktop >/dev/null 2>&1
}
