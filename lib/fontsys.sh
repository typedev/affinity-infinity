# shellcheck shell=bash disable=SC2034  # SYS_* and SYSTEM_PS are also read by lib/fontlib.sh
# System fonts in the font manager: the fonts Affinity sees without the
# library, from fontconfig (Linux), the prefix's windows/Fonts and Wine itself.
#
# They cannot be removed from a running Affinity: Wine's RemoveFontResource
# only drops fonts added with AddFontResource. Disabling one therefore takes
# effect when Affinity starts next (fonts_apply_system, called by cmd_run):
#
# - prefix fonts are moved out of windows/Fonts into fonts/prefix-off;
# - fontconfig fonts: Wine reads fontconfig's per-directory caches directly,
#   so <rejectfont> has no effect. Instead Wine gets a FONTCONFIG_FILE that
#   includes the system configuration (rendering settings, aliases), drops its
#   directories and lists fonts/system-mirror: symlinks to the enabled files.
#   Wine also loads every font listed in the registry before it reconciles its
#   "External Fonts", so a stale entry keeps a font alive: the entries naming
#   a disabled file are deleted. Only those: the external list also holds the
#   UI fonts (Tahoma from Wine), and deleting them breaks Affinity's UI font.
# - Wine's own fonts and the UI fonts set up by lib/fonts.sh are protected.
#
# system-off.list is what the user wants disabled (canonical paths: prefix
# fonts by their windows/Fonts path), system-applied.list what the last start
# of Affinity applied; a difference is shown as pending.

FONTS_SYSTEM_OFF="$FONTS_DIR/system-off.list"
FONTS_SYSTEM_APPLIED="$FONTS_DIR/system-applied.list"
FONTS_PREFIX_OFF="$FONTS_DIR/prefix-off"
FONTS_MIRROR="$FONTS_DIR/system-mirror"
FONTS_FC_CONF="$FONTS_DIR/fontconfig.conf"
WINDOWS_FONTS="$PREFIX_DIR/drive_c/windows/Fonts"
WINE_FONTS="$WINE_ROOT/share/wine/fonts"
# Prefix fonts Affinity's UI needs (lib/fonts.sh), matched on the lowercase file name.
PROTECTED_PREFIX_RE='^(tahoma|tahomabd|segoeui[a-z]*|seguisb|arial[a-z]*)\.ttf$'

SYS_SOURCE=()
SYS_PATH=()
declare -A SYS_INDEX=()
declare -A SYS_OFF=()
declare -A SYS_APPLIED=()

_sys_add() {
    [[ -z "${SYS_INDEX[$2]:-}" ]] || return 0
    SYS_INDEX[$2]=${#SYS_PATH[@]}
    SYS_SOURCE+=("$1")
    SYS_PATH+=("$2")
}

# Where a system font file is now: disabled prefix fonts sit in prefix-off.
sys_file() {
    if [[ "$1" == "$WINDOWS_FONTS/"* && ! -e "$1" ]]; then
        printf '%s' "$FONTS_PREFIX_OFF/${1##*/}"
    else
        printf '%s' "$1"
    fi
}

sys_protected() {
    local source=$1 name=${2##*/}
    [[ "$source" == wine ]] && return 0
    [[ "$source" == prefix && "${name,,}" =~ $PROTECTED_PREFIX_RE ]]
}

fonts_system_load() {
    local f
    SYS_SOURCE=() SYS_PATH=() SYS_INDEX=() SYS_OFF=() SYS_APPLIED=()
    if command -v fc-list >/dev/null; then
        while IFS= read -r f; do
            [[ -n "$f" && "$f" != "$FONTS_MIRROR/"* ]] && _sys_add fontconfig "$f"
        done < <(env -u FONTCONFIG_FILE fc-list --format '%{file}\n' 2>/dev/null | sort -u)
    fi
    while IFS= read -r f; do
        _sys_add prefix "$WINDOWS_FONTS/${f##*/}"
    done < <(find "$WINDOWS_FONTS" "$FONTS_PREFIX_OFF" -maxdepth 1 -type f -regextype posix-extended \
        -regex ".*$FONT_EXT_RE" 2>/dev/null | sort)
    while IFS= read -r f; do
        _sys_add wine "$f"
    done < <(find "$WINE_FONTS" -maxdepth 1 -type f -regextype posix-extended -regex ".*$FONT_EXT_RE" 2>/dev/null | sort)
    [[ -f "$FONTS_SYSTEM_OFF" ]] && while IFS= read -r f; do [[ -n "$f" ]] && SYS_OFF[$f]=1; done <"$FONTS_SYSTEM_OFF"
    [[ -f "$FONTS_SYSTEM_APPLIED" ]] && while IFS= read -r f; do [[ -n "$f" ]] && SYS_APPLIED[$f]=1; done <"$FONTS_SYSTEM_APPLIED"
    return 0
}

fonts_system_save() {
    mkdir -p "$FONTS_DIR"
    if ((${#SYS_OFF[@]})); then
        printf '%s\n' "${!SYS_OFF[@]}" | sort
    fi >"$FONTS_SYSTEM_OFF.tmp" || die "cannot write $FONTS_SYSTEM_OFF"
    mv -f "$FONTS_SYSTEM_OFF.tmp" "$FONTS_SYSTEM_OFF"
}

fonts_system_scan() {
    local -a files=()
    local p
    for p in "${SYS_PATH[@]}"; do
        files+=("$(sys_file "$p")")
    done
    fonts_scan "${files[@]}"
}

# fonts_system_match ARG...: system font indexes matching each argument: a
# file (or directory) path, or a PostScript or family name. Quiet: the caller
# reports arguments that matched nothing.
fonts_system_match() {
    local a i dir
    for a in "$@"; do
        if [[ -e "$a" || "$a" == /* ]]; then
            dir=$(realpath -m -- "$a")
            for i in "${!SYS_PATH[@]}"; do
                [[ "${SYS_PATH[$i]}" == "$dir" || "${SYS_PATH[$i]}" == "$dir/"* ]] && echo "$i"
            done
        else
            for i in "${!SYS_PATH[@]}"; do
                while IFS=$US read -r _ _ ps family _; do
                    if [[ -n "$ps" && ("$a" == "$ps" || "$a" == "$family") ]]; then
                        echo "$i"
                        break
                    fi
                done <<<"$(tr '\t' '\037' <<<"${FONT_ROWS[$(sys_file "${SYS_PATH[$i]}")]:-}")"
            done
        fi
    done
}

# fonts_system_set enable|disable INDEX...
fonts_system_set() {
    local action=$1 i path
    shift
    for i in "$@"; do
        path=${SYS_PATH[$i]}
        if sys_protected "${SYS_SOURCE[$i]}" "$path"; then
            warn "cannot $action a font Affinity's interface needs: $path"
            continue
        fi
        if [[ "$action" == disable && -z "${SYS_OFF[$path]:-}" ]]; then
            SYS_OFF[$path]=1
            log "disabled when Affinity starts next: $path"
        elif [[ "$action" == enable && -n "${SYS_OFF[$path]:-}" ]]; then
            unset "SYS_OFF[$path]"
            log "enabled when Affinity starts next: $path"
        fi
    done
    fonts_system_save
}

# PostScript names of the enabled system fonts: SYSTEM_PS[name]=file.
declare -A SYSTEM_PS=()
fonts_scan_system() {
    local i path ps
    SYSTEM_PS=()
    ((${#SYS_PATH[@]})) || fonts_system_load
    fonts_system_scan
    for i in "${!SYS_PATH[@]}"; do
        path=${SYS_PATH[$i]}
        [[ -z "${SYS_OFF[$path]:-}" && -z "${LIB_INDEX[$path]:-}" ]] || continue
        while IFS= read -r ps; do
            [[ -n "$ps" ]] && SYSTEM_PS[$ps]=$path
        done <<<"${FONT_PS[$(sys_file "$path")]:-}"
    done
}

# Registry values (REGEDIT4 lines, by key) whose data names one of the files
# given on stdin (Unix paths), from the prefix's saved registry.
_sys_stale_registry() {
    local files
    files=$(sed 's|/|\\\\|g; s|^|Z:|')
    [[ -n "$files" ]] || return 0
    FILES=$files awk '
        BEGIN {
            n = split(ENVIRON["FILES"], f, "\n")
            for (i = 1; i <= n; i++) want[tolower(f[i])] = 1
            key["[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts]"] = "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
            key["[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts]"] = "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Fonts"
            key["[Software\\\\Wine\\\\Fonts\\\\External Fonts]"] = "HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\External Fonts"
        }
        /^\[/ { section = ""; for (k in key) if (index($0, k) == 1) section = key[k]; next }
        section != "" && match($0, /^".*"="/) {
            name = substr($0, 1, RLENGTH - 2)
            data = substr($0, RLENGTH + 1); sub(/"$/, "", data)
            if (tolower(data) in want) print section "\t" name
        }' "$PREFIX_DIR/system.reg" "$PREFIX_DIR/user.reg"
}

# Apply system-off.list before Affinity starts (see the top of this file).
# Does nothing while no system font is or was disabled.
fonts_apply_system() {
    local i path dest n=0 stale lines
    local -a fc_off=()
    fonts_system_load
    ((${#SYS_OFF[@]} || ${#SYS_APPLIED[@]})) || return 0

    for i in "${!SYS_PATH[@]}"; do
        path=${SYS_PATH[$i]}
        [[ "${SYS_SOURCE[$i]}" == prefix ]] || continue
        dest="$FONTS_PREFIX_OFF/${path##*/}"
        if [[ -n "${SYS_OFF[$path]:-}" ]] && ! sys_protected prefix "$path"; then
            [[ -f "$path" ]] && { mkdir -p "$FONTS_PREFIX_OFF"; mv -f "$path" "$dest"; }
        elif [[ -f "$dest" ]]; then
            mv -f "$dest" "$path"
        fi
    done

    for i in "${!SYS_PATH[@]}"; do
        [[ "${SYS_SOURCE[$i]}" == fontconfig && -n "${SYS_OFF[${SYS_PATH[$i]}]:-}" ]] && fc_off+=("${SYS_PATH[$i]}")
    done
    rm -rf "${FONTS_MIRROR:?}"
    if ((${#fc_off[@]})); then
        mkdir -p "$FONTS_MIRROR"
        for i in "${!SYS_PATH[@]}"; do
            path=${SYS_PATH[$i]}
            [[ "${SYS_SOURCE[$i]}" == fontconfig && -z "${SYS_OFF[$path]:-}" ]] || continue
            # Stable names, so registry entries stay valid from one start to the next.
            ln -s "$path" "$FONTS_MIRROR/${path//\//_}" && n=$((n + 1))
        done
        cat >"$FONTS_FC_CONF" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by $AI_NAME: the system configuration with only the enabled system fonts. -->
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <reset-dirs/>
  <dir>$FONTS_MIRROR</dir>
</fontconfig>
EOF
        export FONTCONFIG_FILE="$FONTS_FC_CONF"

        # Entries naming disabled files are written by Wine sessions without the
        # mirror (e.g. install); delete them with the registry saved to disk.
        wineserver -w
        stale=$(printf '%s\n' "${fc_off[@]}" | _sys_stale_registry)
        if [[ -n "$stale" ]]; then
            lines=$(awk -F'\t' '$1 != last { printf "%s[%s]\n", (NR > 1 ? "\n" : ""), $1; last = $1 } { print $2 "=-" }' <<<"$stale")
            printf 'REGEDIT4\n\n%s\n' "$lines" | reg_import || warn "failed to remove disabled fonts from the registry"
            wineserver -w
        fi
        log "system fonts: ${#fc_off[@]} disabled, $n available to Affinity"
    else
        rm -f "$FONTS_FC_CONF"
    fi

    if ((${#SYS_OFF[@]})); then
        printf '%s\n' "${!SYS_OFF[@]}" | sort
    fi >"$FONTS_SYSTEM_APPLIED"
}
