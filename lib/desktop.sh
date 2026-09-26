# shellcheck shell=bash
# Desktop menu entry and file associations for Affinity documents.

DESKTOP_ID="$AI_NAME.desktop"
MIME_TYPE="application/x-affinity"

install_desktop() {
    local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local mime="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
    local icon="$DATA_DIR/icon.svg"
    [[ -f "$icon" ]] || icon=applications-graphics

    mkdir -p "$apps" "$mime/packages"
    cat >"$apps/$DESKTOP_ID" <<EOF
[Desktop Entry]
Type=Application
Name=Affinity
GenericName=Graphic Design
Comment=Affinity by Canva (Wine, managed by $AI_NAME)
Icon=$icon
Exec="$SELF" run %F
Terminal=false
Categories=Graphics;VectorGraphics;RasterGraphics;Publishing;
MimeType=$MIME_TYPE;
StartupNotify=true
StartupWMClass=affinity.exe
Actions=update;scale;

[Desktop Action update]
Name=Check for updates
Exec="$SELF" update --gui

[Desktop Action scale]
Name=Interface scale…
Exec="$SELF" dpi --gui
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
    command -v update-desktop-database >/dev/null && update-desktop-database "$apps" >/dev/null 2>&1
    log "menu entry installed: $apps/$DESKTOP_ID"
}
