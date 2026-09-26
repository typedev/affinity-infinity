# shellcheck shell=bash disable=SC2034
# Shared paths, logging, state and Wine environment for affinity-infinity.

AI_NAME=affinity-infinity

DATA_DIR="${AFFINITY_INFINITY_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/$AI_NAME}"
CONFIG_DIR="${AFFINITY_INFINITY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/$AI_NAME}"
RUNTIME_DIR="$DATA_DIR/runtime"
# An AppImage sets AI_WINE_ROOT to its bundled Wine; otherwise the one set up in the data dir.
WINE_ROOT="${AI_WINE_ROOT:-$RUNTIME_DIR/current}"
PREFIX_DIR="$DATA_DIR/prefix"
CACHE_DIR="$DATA_DIR/cache"
STATE_FILE="$DATA_DIR/state.env"
CONFIG_FILE="$CONFIG_DIR/config.env"

AFFINITY_DIR="$PREFIX_DIR/drive_c/Program Files/Affinity/Affinity"
AFFINITY_WIN_DIR='C:\Program Files\Affinity\Affinity'

# What desktop entries should run: the AppImage itself when running from one.
launcher_path() {
    printf '%s' "${APPIMAGE:-$SELF}"
}

# ---------------------------------------------------------------- logging

# True when there is no terminal to talk to (e.g. launched from a .desktop file).
gui_mode() {
    [[ ! -t 2 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null
}

log() { printf '%s: %s\n' "$AI_NAME" "$*" >&2; }

warn() { printf '%s: warning: %s\n' "$AI_NAME" "$*" >&2; }

die() {
    printf '%s: error: %s\n' "$AI_NAME" "$*" >&2
    progress_end
    if gui_mode; then
        zenity --error --title="Affinity" --text="$*" 2>/dev/null || true
    fi
    exit 1
}

# ---------------------------------------------------------------- progress
# One progress window for long multi-step work (the first run). While it is
# open, phases, downloads and with_spinner report into it instead of opening
# windows of their own. PROGRESS_PLAN maps phase names to "from to" percent.

PROGRESS_FD=""
PROGRESS_PID=""
PROGRESS_TICKER=""
PROGRESS_LO=0
PROGRESS_HI=0
declare -A PROGRESS_PLAN=()

progress_active() { [[ -n "$PROGRESS_FD" ]]; }

progress_begin() {
    local title=$1 fifo
    gui_mode || return 0
    mkdir -p "$CACHE_DIR"
    fifo=$(mktemp -u "$CACHE_DIR/progress.XXXXXX")
    mkfifo "$fifo"
    zenity --progress --title="$title" --text="$title" --percentage=0 --auto-close --no-cancel \
        --width=480 <"$fifo" 2>/dev/null &
    PROGRESS_PID=$!
    exec {PROGRESS_FD}>"$fifo"
    rm -f "$fifo"
    trap '' PIPE # the window may be closed by the user; keep going
}

_progress_write() {
    progress_active || return 0
    { printf '%s\n' "$@" >&"$PROGRESS_FD"; } 2>/dev/null
    return 0
}

_progress_ticker_stop() {
    [[ -n "$PROGRESS_TICKER" ]] && kill "$PROGRESS_TICKER" 2>/dev/null
    PROGRESS_TICKER=""
}

# progress_phase <name> <text> [creep]: enter a phase of PROGRESS_PLAN. With
# creep, the bar advances slowly on its own within the phase (for steps that
# report no progress), never reaching its end.
progress_phase() {
    local name=$1 text=$2 creep=${3:-}
    log "$text"
    progress_active || return 0
    _progress_ticker_stop
    read -r PROGRESS_LO PROGRESS_HI <<<"${PROGRESS_PLAN[$name]:-$PROGRESS_LO $PROGRESS_LO}"
    _progress_write "$PROGRESS_LO" "# $text"
    if [[ -n "$creep" ]] && ((PROGRESS_HI - PROGRESS_LO > 1)); then
        (
            p=$PROGRESS_LO
            while ((p < PROGRESS_HI - 1)); do
                sleep "$creep"
                p=$((p + 1))
                _progress_write "$p"
            done
        ) &
        PROGRESS_TICKER=$!
    fi
}

# progress_pct <0-100>: position within the current phase.
progress_pct() {
    progress_active || return 0
    _progress_write "$((PROGRESS_LO + (PROGRESS_HI - PROGRESS_LO) * $1 / 100))"
}

progress_end() {
    progress_active || return 0
    _progress_ticker_stop
    _progress_write 100
    exec {PROGRESS_FD}>&-
    PROGRESS_FD=""
    wait "$PROGRESS_PID" 2>/dev/null
    trap - PIPE
}

# with_spinner <text> <cmd...>: run cmd; in GUI mode show a pulsating progress dialog meanwhile.
with_spinner() {
    local text=$1
    shift
    if progress_active; then
        _progress_write "# $text"
        "$@"
        return
    fi
    gui_mode || { "$@"; return; }
    "$@" &
    local pid=$! rc
    while kill -0 "$pid" 2>/dev/null; do
        echo "# $text"
        sleep 1
    done | zenity --progress --pulsate --auto-close --no-cancel --title="Affinity" --text="$text" 2>/dev/null &
    wait "$pid"
    rc=$?
    wait
    return $rc
}

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null || die "required command not found: $c"
    done
}

# ---------------------------------------------------------------- state / config
# Both files are KEY=value lines written with printf %q, so they can be sourced.

_kv_set() {
    local file=$1 key=$2 value=$3 tmp
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "$file.XXXXXX")
    if [[ -f "$file" ]]; then
        grep -v "^${key}=" "$file" >"$tmp" || true
    fi
    printf '%s=%q\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$file"
}

_kv_get() {
    local file=$1 key=$2 default=${3-}
    if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
        (
            # shellcheck disable=SC1090
            source "$file"
            printf '%s' "${!key}"
        )
    else
        printf '%s' "$default"
    fi
}

state_set() { _kv_set "$STATE_FILE" "$@"; }
state_get() { _kv_get "$STATE_FILE" "$@"; }
config_set() { _kv_set "$CONFIG_FILE" "$@"; }
config_get() { _kv_get "$CONFIG_FILE" "$@"; }

# ---------------------------------------------------------------- wine

has_wine() {
    [[ -x "$WINE_ROOT/bin/wine" ]]
}

# PREFIX_READY is 0 while a prefix build is unfinished; prefixes from before it
# existed have no such key and count as ready.
is_setup() {
    has_wine && [[ -f "$PREFIX_DIR/system.reg" && "$(state_get PREFIX_READY 1)" == 1 ]]
}

require_setup() {
    is_setup || die "the Windows environment is not set up yet; run: $AI_NAME setup"
}

wine_env() {
    export WINEPREFIX="$PREFIX_DIR"
    export WINEARCH=win64
    export PATH="$WINE_ROOT/bin:$PATH"
    export LD_LIBRARY_PATH="$WINE_ROOT/lib/wine/x86_64-unix:$WINE_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export WINEDLLPATH="$WINE_ROOT/lib/wine/x86_64-windows:$WINE_ROOT/lib/wine/i386-windows"
    export WINELOADER="$WINE_ROOT/bin/wine"
    export WINESERVER="$WINE_ROOT/bin/wineserver"
    export WINEDEBUG="${WINEDEBUG:--all}"
    # Keep Wine from littering the host menu and MIME database with its own entries.
    export WINEDLLOVERRIDES="winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
}

wine() { "$WINE_ROOT/bin/wine" "$@"; }
wineserver() { "$WINE_ROOT/bin/wineserver" "$@"; }

to_winpath() { wine winepath -w "$1" 2>/dev/null | tr -d '\r'; }

# Import a .reg file (REGEDIT4 text) given on stdin in a single Wine start.
reg_import() {
    local tmp rc
    mkdir -p "$CACHE_DIR"
    tmp=$(mktemp --suffix=.reg "$CACHE_DIR/import.XXXXXX")
    cat >"$tmp"
    wine regedit /S "$(to_winpath "$tmp")"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# ---------------------------------------------------------------- misc

# Print the FileVersion string from a PE file's version resource.
pe_file_version() {
    LC_ALL=C grep -m1 -aoP 'F\x00i\x00l\x00e\x00V\x00e\x00r\x00s\x00i\x00o\x00n\x00(?:\x00\x00)+(?:[0-9.]\x00)+' "$1" 2>/dev/null |
        tr -d '\0' | sed 's/^FileVersion//'
}
