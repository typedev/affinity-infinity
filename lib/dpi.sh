# shellcheck shell=bash
# UI scaling. Affinity is per-monitor DPI aware and would read the raw monitor
# DPI from Wine; prefix_configure forces DpiAwareness=System for Affinity.exe,
# so it honours LogPixels, which is what we set here.

DPI_MIN=96
DPI_MAX=480

clamp_dpi() {
    local v=$1
    ((v < DPI_MIN)) && v=$DPI_MIN
    ((v > DPI_MAX)) && v=$DPI_MAX
    echo "$v"
}

# Best guess from the desktop: X resources (GNOME/KDE export their scale here
# for Xwayland), then GNOME settings, then GDK_SCALE.
detect_dpi() {
    local v=""
    if command -v xrdb >/dev/null; then
        v=$(xrdb -query 2>/dev/null | awk '$1=="Xft.dpi:"{printf "%d", $2; exit}')
    fi
    if [[ -z "$v" ]] && command -v gsettings >/dev/null; then
        local sf tf
        sf=$(gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null | awk '{print $NF}')
        tf=$(gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null)
        if [[ -n "$sf" && -n "$tf" ]]; then
            ((sf == 0)) && sf=1
            v=$(awk -v s="$sf" -v t="$tf" 'BEGIN{printf "%d", 96 * s * t}')
        fi
    fi
    if [[ -z "$v" && -n "${GDK_SCALE:-}" ]]; then
        v=$(awk -v s="$GDK_SCALE" 'BEGIN{printf "%d", 96 * s}')
    fi
    clamp_dpi "${v:-96}"
}

effective_dpi() {
    local cfg
    cfg=$(config_get DPI auto)
    if [[ "$cfg" == auto ]]; then
        detect_dpi
    else
        clamp_dpi "$cfg"
    fi
}

# Write LogPixels into the prefix if it differs from what was applied last time.
apply_dpi() {
    local dpi hex
    dpi=$(effective_dpi)
    [[ "$(state_get DPI_APPLIED)" == "$dpi" ]] && return 0
    hex=$(printf '%08x' "$dpi")
    reg_import <<EOF || { warn "failed to apply DPI $dpi"; return 1; }
REGEDIT4

[HKEY_CURRENT_USER\\Control Panel\\Desktop]
"LogPixels"=dword:$hex

[HKEY_CURRENT_USER\\Software\\Wine\\Fonts]
"LogPixels"=dword:$hex
EOF
    state_set DPI_APPLIED "$dpi"
    log "UI scale set to $dpi DPI ($((dpi * 100 / 96))%)"
}

dpi_dialog() {
    need_cmd zenity
    local current auto value
    current=$(effective_dpi)
    auto=$(detect_dpi)
    value=$(zenity --scale --title="Affinity – interface scale" \
        --text="DPI for the Affinity interface (96 = 100%, 192 = 200%).\nDetected from your desktop: $auto" \
        --min-value=$DPI_MIN --max-value=$DPI_MAX --step=4 --value="$current" 2>/dev/null) || return 0
    config_set DPI "$value"
    echo "$value"
}
