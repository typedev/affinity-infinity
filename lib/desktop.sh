# shellcheck shell=bash
# Desktop menu entry, icon and file associations for Affinity documents.
# Entries run launcher_path: the AppImage when running from one, else this script.

DESKTOP_ID="$AI_NAME.desktop"
ICON_NAME="$AI_NAME"
MIME_TYPE="application/x-affinity"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

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

install_desktop() {
    local data="${XDG_DATA_HOME:-$HOME/.local/share}" exe foreign
    local mime="$data/mime" icons="$data/icons/hicolor"
    if foreign=$(foreign_integration); then
        log "already in the menu via $(basename "$foreign"); not adding another entry"
        return 0
    fi
    exe=$(launcher_path)

    mkdir -p "$APPS_DIR" "$mime/packages" "$icons/scalable/apps"
    cp -f "$ROOT/share/$AI_NAME.svg" "$icons/scalable/apps/$ICON_NAME.svg"

    cat >"$APPS_DIR/$DESKTOP_ID" <<EOF
[Desktop Entry]
Type=Application
Name=Affinity
GenericName=Graphic Design
Comment=Affinity by Canva on Wine, managed by Affinity Infinity
Icon=$ICON_NAME
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
    log "menu entry installed: $APPS_DIR/$DESKTOP_ID"
}

# Keep our entry pointing at the AppImage after it was moved or replaced.
refresh_desktop() {
    [[ -n "${APPIMAGE:-}" && -f "$APPS_DIR/$DESKTOP_ID" ]] || return 0
    grep -qxF "TryExec=$APPIMAGE" "$APPS_DIR/$DESKTOP_ID" && return 0
    install_desktop >/dev/null 2>&1
}
