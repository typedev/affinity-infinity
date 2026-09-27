# shellcheck shell=bash
# Build the base Wine prefix on the user's machine. Microsoft components
# (.NET 4.8, VC++ runtime, core fonts) are installed by winetricks from
# Microsoft's own installers, so none of them are shipped by this project.
# Steps are recorded in state.env, so an interrupted setup resumes.

TOOLS_DIR="${AI_TOOLS_DIR:-$DATA_DIR/tools}"

PREFIX_STEPS=(init vcrun2022 dotnet48 fonts settings)
declare -A PREFIX_STEP_TITLE=(
    [init]="Creating the Windows environment"
    [vcrun2022]="Installing the Visual C++ runtime"
    [dotnet48]="Installing .NET Framework 4.8 (the longest step)"
    [fonts]="Installing core fonts"
    [settings]="Configuring Windows 11 mode and Vulkan rendering"
)
declare -A PREFIX_STEP_TIMEOUT=([init]=600 [vcrun2022]=900 [dotnet48]=3600 [fonts]=900 [settings]=300)
# Seconds per percent the progress bar creeps during a step (steps report no progress).
declare -A PREFIX_STEP_CREEP=([init]=2 [vcrun2022]=4 [dotnet48]=12 [fonts]=4 [settings]=2)

prefix_tools_env() {
    export PATH="$TOOLS_DIR/bin:$PATH"
    export WINE="$WINE_ROOT/bin/wine"
    export XDG_CACHE_HOME="$CACHE_DIR/xdg" # winetricks download cache
    export WINETRICKS_LATEST_VERSION_CHECK=disabled
    if ! command -v winetricks >/dev/null || ! command -v cabextract >/dev/null; then
        die "winetricks and cabextract are needed to set up the prefix (bundled in the AppImage; else install them or set AI_TOOLS_DIR)"
    fi
}

# Print the command for a step, one argument per line.
prefix_step_cmd() {
    case $1 in
        init) printf '%s\n' "$WINE" wineboot -i ;;
        vcrun2022) printf '%s\n' winetricks --unattended --optout vcrun2022 ;;
        dotnet48) printf '%s\n' winetricks --unattended --optout dotnet48 ;;
        fonts) printf '%s\n' winetricks --unattended --optout corefonts tahoma ;;
        settings) printf '%s\n' winetricks --unattended --optout win11 renderer=vulkan ;;
    esac
}

prefix_run_step() {
    local step=$1 n=$2 total=$3 logfile="$CACHE_DIR/prefix-$1.log" attempt rc
    local -a cmd
    mapfile -t cmd < <(prefix_step_cmd "$step")
    progress_phase "prefix-$step" "Step $n/$total: ${PREFIX_STEP_TITLE[$step]}..." "${PREFIX_STEP_CREEP[$step]}"
    for attempt in 1 2; do
        # No Wine Mono/Gecko prompts: .NET and Edge are not the builtin replacements here.
        WINEDLLOVERRIDES="mscoree,mshtml=;$WINEDLLOVERRIDES" \
            with_spinner "Step $n/$total: ${PREFIX_STEP_TITLE[$step]}..." \
            timeout "${PREFIX_STEP_TIMEOUT[$step]}" "${cmd[@]}" >>"$logfile" 2>&1
        rc=$?
        timeout 120 "$WINESERVER" -w || "$WINESERVER" -k
        ((rc == 0)) && return 0
        warn "step '$step' failed (exit $rc, attempt $attempt); log: $logfile"
        "$WINESERVER" -k 2>/dev/null
    done
    die "setting up the Windows environment failed at '${PREFIX_STEP_TITLE[$step]}'; log: $logfile"
}

# Build (or resume building) the prefix.
prefix_build() {
    wine_env
    prefix_tools_env
    mkdir -p "$PREFIX_DIR" "$CACHE_DIR"
    state_set PREFIX_READY 0

    local done_step skip=0 n=0 step total=${#PREFIX_STEPS[@]}
    done_step=$(state_get PREFIX_STEP)
    [[ -n "$done_step" ]] && skip=1
    for step in "${PREFIX_STEPS[@]}"; do
        n=$((n + 1))
        if ((skip)); then
            [[ "$step" == "$done_step" ]] && skip=0
            continue
        fi
        prefix_run_step "$step" "$n" "$total"
        state_set PREFIX_STEP "$step"
    done

    state_set WINE_VERSION "$(wine_build_id)"
    state_set PREFIX_CONFIGURED ""
    progress_phase prefix-configure "Applying font and display fixes..." 2
    prefix_configure
    state_set PREFIX_READY 1
    log "Windows environment ready in $PREFIX_DIR"
}

# Move an existing prefix aside instead of deleting it: it holds the user's
# Affinity settings and files.
prefix_backup() {
    [[ -d "$PREFIX_DIR" ]] || return 0
    local backup
    backup="$PREFIX_DIR.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$PREFIX_DIR" "$backup"
    state_set PREFIX_STEP ""
    state_set PREFIX_READY 0
    log "previous prefix kept as $backup"
}

# Remove the data dir's runtimes other than KEEP (the one runtime/current points at).
runtime_prune() {
    local keep=$1 d
    for d in "$RUNTIME_DIR"/*/; do
        d=${d%/}
        [[ -L "$d" || "${d##*/}" == "$keep" ]] && continue
        rm -rf "${d:?}"
        log "removed old runtime ${d##*/}"
    done
}

# Unpack a Wine build tarball (from wine/build.sh) as the data dir's runtime.
runtime_install_tarball() {
    local tarball=$1 name
    [[ -f "$tarball" ]] || die "no such file: $tarball"
    name=$(tar -tf "$tarball" | head -1 | cut -d/ -f1)
    [[ -n "$name" ]] || die "not a Wine build tarball: $tarball"
    mkdir -p "$RUNTIME_DIR"
    rm -rf "${RUNTIME_DIR:?}/$name"
    tar -C "$RUNTIME_DIR" -xf "$tarball"
    [[ -x "$RUNTIME_DIR/$name/bin/wine" ]] || die "no bin/wine in $tarball"
    ln -sfn "$name" "$RUNTIME_DIR/current"
    runtime_prune "$name"
    log "runtime $name installed"
}
