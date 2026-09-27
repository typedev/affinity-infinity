# shellcheck shell=bash
# Font manager: a library of font files the user enabled for Affinity, applied
# live by the FontSync plugin (lib/fontsync.sh). Files are referenced where
# they are, not copied, so a font rebuilt in place is reloaded by Affinity.
#
# Affinity finds a font's file by its PostScript name: with two enabled files
# of the same PostScript name it silently uses either. So enabling a font
# disables the other library fonts with the same name; a clash with an enabled
# system font is reported (the system one can be disabled, see lib/fontsys.sh).
#
# library.tsv holds "on|off<TAB>path" lines; active.list, the enabled files
# that exist, is what the plugin reads. Both are replaced atomically. The
# commands need no Wine and never touch state.env, so they can run while
# Affinity does; a lock serialises concurrent fonts commands.

FONT_EXT_RE='\.([Tt][Tt][Ff]|[Oo][Tt][Ff]|[Tt][Tt][Cc])$'
# Tab-separated rows are split on the unit separator instead: a tab in IFS is
# whitespace, so read would merge empty fields and shift the columns.
US=$'\x1f'

LIB_STATE=()
LIB_PATH=()
declare -A LIB_INDEX=()
# Per path: the TSV rows of font-info.py (one per face) and the PostScript names.
declare -A FONT_ROWS=()
declare -A FONT_PS=()

fonts_lock() {
    mkdir -p "$FONTS_DIR"
    exec {FONTS_LOCK_FD}>"$FONTS_DIR/.lock"
    flock "$FONTS_LOCK_FD"
}

fonts_load() {
    local state path
    LIB_STATE=() LIB_PATH=() LIB_INDEX=()
    [[ -f "$FONTS_LIBRARY" ]] || return 0
    while IFS=$'\t' read -r state path; do
        [[ -n "$path" && -z "${LIB_INDEX[$path]:-}" ]] || continue
        LIB_INDEX[$path]=${#LIB_PATH[@]}
        LIB_STATE+=("$state")
        LIB_PATH+=("$path")
    done <"$FONTS_LIBRARY"
}

fonts_save() {
    local i
    mkdir -p "$FONTS_DIR"
    for i in "${!LIB_PATH[@]}"; do
        printf '%s\t%s\n' "${LIB_STATE[$i]}" "${LIB_PATH[$i]}"
    done >"$FONTS_LIBRARY.tmp" || die "cannot write $FONTS_LIBRARY"
    mv -f "$FONTS_LIBRARY.tmp" "$FONTS_LIBRARY"
    for i in "${!LIB_PATH[@]}"; do
        if [[ "${LIB_STATE[$i]}" == on && -f "${LIB_PATH[$i]}" ]]; then
            printf '%s\n' "${LIB_PATH[$i]}"
        fi
    done >"$FONTS_ACTIVE.tmp" || die "cannot write $FONTS_ACTIVE"
    mv -f "$FONTS_ACTIVE.tmp" "$FONTS_ACTIVE"
}

# fonts_scan PATH...: read the names of the given files into FONT_ROWS/FONT_PS.
fonts_scan() {
    local row path idx ps
    (($#)) || return 0
    while IFS= read -r row; do
        IFS=$US read -r path idx ps _ <<<"${row//$'\t'/$US}"
        FONT_ROWS[$path]+="$row"$'\n'
        [[ -n "$ps" ]] && FONT_PS[$path]+="$ps"$'\n'
    done < <(printf '%s\0' "$@" | xargs -0 python3 "$ROOT/lib/font-info.py" 2>/dev/null)
}

fonts_scan_library() {
    local -a existing=()
    local p
    for p in "${LIB_PATH[@]}"; do
        [[ -f "$p" ]] && existing+=("$p")
    done
    fonts_scan "${existing[@]}"
}

# fonts_expand ARG...: font files for the arguments (files, or directories
# searched recursively), as absolute paths, one per line, sorted.
fonts_expand() {
    local a
    for a in "$@"; do
        if [[ -d "$a" ]]; then
            find "$(realpath -- "$a")" -type f -regextype posix-extended -regex ".*$FONT_EXT_RE" | sort
        elif [[ -f "$a" ]]; then
            realpath -- "$a"
        else
            warn "no such file or directory: $a"
        fi
    done
}

# fonts_match ARG...: library indexes matching each argument: a file, a
# directory (everything below it), or a PostScript or family name. Quiet: the
# caller reports arguments that matched nothing.
fonts_match() {
    local a i dir
    for a in "$@"; do
        if [[ -e "$a" || "$a" == /* ]]; then
            dir=$(realpath -m -- "$a")
            for i in "${!LIB_PATH[@]}"; do
                [[ "${LIB_PATH[$i]}" == "$dir" || "${LIB_PATH[$i]}" == "$dir/"* ]] && echo "$i"
            done
        else
            for i in "${!LIB_PATH[@]}"; do
                while IFS=$US read -r _ _ ps family _; do
                    if [[ -n "$ps" && ("$a" == "$ps" || "$a" == "$family") ]]; then
                        echo "$i"
                        break
                    fi
                done <<<"$(tr '\t' '\037' <<<"${FONT_ROWS[${LIB_PATH[$i]}]:-}")"
            done
        fi
    done
}

# fonts_enable INDEX...: enable fonts in the given order. Another enabled font
# with the same PostScript name is disabled; within one call the first font
# claiming a name wins and later ones stay disabled.
fonts_enable() {
    local i j ps skip
    local -A claimed=()
    for i in "$@"; do
        skip=""
        while IFS= read -r ps; do
            [[ -n "$ps" && -n "${claimed[$ps]:-}" && "${claimed[$ps]}" != "$i" ]] && skip=$ps
        done <<<"${FONT_PS[${LIB_PATH[$i]}]:-}"
        if [[ -n "$skip" ]]; then
            LIB_STATE[i]=off
            log "left disabled (same PostScript name $skip as ${LIB_PATH[${claimed[$skip]}]}): ${LIB_PATH[$i]}"
            continue
        fi
        while IFS= read -r ps; do
            [[ -n "$ps" ]] || continue
            claimed[$ps]=$i
            for j in "${!LIB_PATH[@]}"; do
                ((j != i)) && [[ "${LIB_STATE[$j]}" == on ]] || continue
                if grep -qxF -- "$ps" <<<"${FONT_PS[${LIB_PATH[$j]}]:-}"; then
                    LIB_STATE[j]=off
                    log "disabled (same PostScript name $ps): ${LIB_PATH[$j]}"
                fi
            done
            [[ -n "${SYSTEM_PS[$ps]:-}" ]] &&
                warn "$ps is also a system font (${SYSTEM_PS[$ps]}); Affinity may use either file"
        done <<<"${FONT_PS[${LIB_PATH[$i]}]:-}"
        [[ -f "${LIB_PATH[$i]}" ]] || warn "file is missing: ${LIB_PATH[$i]}"
        if [[ "${LIB_STATE[$i]}" != on ]]; then
            LIB_STATE[i]=on
            log "enabled: ${LIB_PATH[$i]}"
        fi
    done
}

fonts_add() {
    local off=0 path a
    local -a new=() args=()
    for a in "$@"; do
        [[ "$a" == --off ]] && off=1 || args+=("$a")
    done
    set -- "${args[@]}"
    (($#)) || die "usage: $AI_NAME fonts add [--off] FILE|DIR..."
    fonts_load
    while IFS= read -r path; do
        [[ "$path" != *$'\t'* ]] || { warn "skipping a path with a tab: $path"; continue; }
        if [[ -z "${LIB_INDEX[$path]:-}" ]]; then
            LIB_INDEX[$path]=${#LIB_PATH[@]}
            LIB_STATE+=(off)
            LIB_PATH+=("$path")
            log "added: $path"
        fi
        new+=("${LIB_INDEX[$path]}")
    done < <(fonts_expand "$@")
    ((${#new[@]})) || die "no font files found"
    if ((!off)); then
        fonts_scan_library
        fonts_scan_system
        fonts_enable "${new[@]}"
    fi
    fonts_save
}

# fonts_set enable|disable|remove [--system] --all | ARG...: each argument
# names library fonts; one that matches none (or all with --system) names
# system fonts, which only enable and disable accept.
fonts_set() {
    local action=$1 system=0 all=0 a i
    local -a args=() idx=() sys=() found=()
    shift
    for a in "$@"; do
        case $a in
            --system) system=1 ;;
            --all) all=1 ;;
            *) args+=("$a") ;;
        esac
    done
    ((all || ${#args[@]})) || die "usage: $AI_NAME fonts $action [--system] --all | FILE|DIR|NAME..."
    fonts_load
    fonts_scan_library
    fonts_system_load
    if ((all)); then
        ((system)) && sys=("${!SYS_PATH[@]}") || idx=("${!LIB_PATH[@]}")
    else
        fonts_system_scan
        for a in "${args[@]}"; do
            found=()
            ((system)) || mapfile -t found < <(fonts_match "$a")
            if ((${#found[@]})); then
                idx+=("${found[@]}")
                continue
            fi
            mapfile -t found < <(fonts_system_match "$a")
            if ((${#found[@]})) && [[ "$action" != remove ]]; then
                sys+=("${found[@]}")
            else
                warn "no such font${found[*]:+ in the library}: $a"
            fi
        done
    fi
    ((${#idx[@]} || ${#sys[@]})) || return 1
    ((${#sys[@]})) && fonts_system_set "$action" "${sys[@]}"
    ((${#idx[@]})) || return 0
    case $action in
        enable)
            fonts_scan_system
            fonts_enable "${idx[@]}"
            ;;
        disable)
            for i in "${idx[@]}"; do
                [[ "${LIB_STATE[$i]}" == off ]] && continue
                LIB_STATE[i]=off
                log "disabled: ${LIB_PATH[$i]}"
            done
            ;;
        remove)
            for i in "${idx[@]}"; do
                [[ -n "${LIB_PATH[i]+x}" ]] || continue
                log "removed from the library: ${LIB_PATH[$i]}"
                unset 'LIB_PATH[i]' 'LIB_STATE[i]'
            done
            LIB_PATH=("${LIB_PATH[@]}") LIB_STATE=("${LIB_STATE[@]}")
            ;;
    esac
    fonts_save
}

# _fonts_rows SOURCE STATE FLAGS FILE PATH: print the faces of one font file.
_fonts_rows() {
    local source=$1 state=$2 base=$3 file=$4 path=$5 rows flags ps family style instances
    rows=${FONT_ROWS[$file]:-}
    if [[ -z "$rows" ]]; then
        base+=${base:+,}$([[ -f "$file" ]] && echo unreadable || echo missing)
        rows=$'-\t0\t\t\t\t0'
    fi
    rows=${rows%$'\n'}
    while IFS=$US read -r _ _ ps family style instances; do
        flags=$base
        if [[ "$source" == library && -n "$ps" && -n "${SYSTEM_PS[$ps]:-}" ]]; then
            flags+=${flags:+,}system
        fi
        if ((FONTS_TSV)); then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$source" "$state" "${flags:--}" "$ps" "$family" "$style" "${instances:-0}" "$path"
        else
            printf '%-10s %-3s  %-32s  %-40s  %s%s\n' "$source" "$state" "${ps:--}" "$family${style:+ / $style}" "$path" \
                "$( ((instances > 0)) && printf '  [variable, %s instances]' "$instances")${flags:+  [$flags]}"
        fi
    done <<<"${rows//$'\t'/$US}"
}

# fonts list [--all] [--tsv]: one line per face; --all adds the system fonts.
# --tsv (for scripts and the GUI):
#   source  state  flags  postscript  family  style  named-instances  path
# source: library, fontconfig, prefix or wine. flags: comma-separated or "-":
#   missing, unreadable; system (a library font with the PostScript name of an
#   enabled system font); protected (needed by Affinity's UI, cannot be
#   disabled); pending (system font changed, applies when Affinity starts).
fonts_list() {
    local all=0 i path state flags a
    FONTS_TSV=0
    for a in "$@"; do
        case $a in
            --tsv) FONTS_TSV=1 ;;
            --all) all=1 ;;
            *) die "usage: $AI_NAME fonts list [--all] [--tsv]" ;;
        esac
    done
    fonts_load
    fonts_scan_library
    fonts_scan_system
    for i in "${!LIB_PATH[@]}"; do
        _fonts_rows library "${LIB_STATE[$i]}" "" "${LIB_PATH[$i]}" "${LIB_PATH[$i]}"
    done
    ((all)) || return 0
    for i in "${!SYS_PATH[@]}"; do
        path=${SYS_PATH[$i]} state=on flags=""
        [[ -n "${SYS_OFF[$path]:-}" ]] && state=off
        sys_protected "${SYS_SOURCE[$i]}" "$path" && flags=protected
        if [[ "${SYS_OFF[$path]:+1}" != "${SYS_APPLIED[$path]:+1}" ]]; then
            flags+=${flags:+,}pending
        fi
        _fonts_rows "${SYS_SOURCE[$i]}" "$state" "$flags" "$(sys_file "$path")" "$path"
    done
}

fonts_summary() {
    local on=0 total=0
    [[ -f "$FONTS_LIBRARY" ]] && on=$(grep -c $'^on\t' "$FONTS_LIBRARY") total=$(grep -c . "$FONTS_LIBRARY")
    printf '%s enabled / %s in library' "$on" "$total"
    [[ -s "$FONTS_SYSTEM_OFF" ]] && printf ', %s system fonts disabled' "$(grep -c . "$FONTS_SYSTEM_OFF")"
}

# The Affinity Fonts window (lib/fonts-gui.py), a GTK front end to these commands.
fonts_gui() {
    local check='import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw
assert (Gtk.get_major_version(), Gtk.get_minor_version()) >= (4, 12)
assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 4)'
    python3 -c "$check" 2>/dev/null ||
        die "Affinity Fonts needs Python bindings for GTK 4.12+ and libadwaita 1.4+ (Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1)"
    AI_CLI=$(launcher_path)
    export AI_CLI AI_FONTS_DIR="$FONTS_DIR" AI_CONFIG_DIR="$CONFIG_DIR" AI_WINDOWS_FONTS="$WINDOWS_FONTS"
    exec python3 "$ROOT/lib/fonts-gui.py"
}

cmd_fonts() {
    local sub=${1:-list}
    (($#)) && shift
    need_cmd python3
    # The window runs fonts commands itself; it must not hold the lock.
    [[ "$sub" == --gui ]] && fonts_gui
    fonts_lock
    case $sub in
        list) fonts_list "$@" ;;
        add) fonts_add "$@" ;;
        enable | disable | remove) fonts_set "$sub" "$@" ;;
        *) die "unknown fonts command: $sub (list, add, enable, disable, remove)" ;;
    esac
}
