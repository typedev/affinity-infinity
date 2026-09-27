# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Affinity Infinity runs Affinity by Canva (Windows, .NET 4.8 WPF + WinUI) on Linux via Wine, shipped as an AppImage. The ground rule behind most design choices: **nothing from Microsoft or Canva is redistributed**. The Wine prefix (.NET, VC++, fonts) is built on the user's machine by winetricks; Affinity is downloaded from `downloads.affinity.studio`; the Segoe UI substitute (Selawik renamed) and the Affinity menu icon (extracted from `Affinity.exe`) are produced locally at runtime. Keep it that way: never commit or bundle a prefix, Microsoft DLLs/fonts, or Affinity's logo.

## Commands

```sh
# lint (the only automated check besides CI smoke; shellcheck from the uv venv)
uv pip install --python .venv shellcheck-py
.venv/bin/shellcheck -x -P SCRIPTDIR bin/affinity-infinity lib/*.sh install.sh \
    packaging/*.sh packaging/AppRun wine/*.sh versions.env

wine/build-in-container.sh              # build Wine in podman/docker (ubuntu:22.04) -> wine/out/*.tar.xz (~5 min on 32 cores)
packaging/build-tools.sh                # winetricks + cabextract/libmspack -> packaging/out/tools
packaging/build-appimage.sh wine/out/wine-11.12-ai1-x86_64.tar.xz [VERSION]   # -> packaging/out/*.AppImage
```

There are no unit tests. Verify changes by running the real thing against an **isolated data dir** so the user's installation is untouched:

```sh
export AFFINITY_INFINITY_DATA=$HOME/.local/share/affinity-infinity-test AFFINITY_INFINITY_CONFIG=$HOME/.config/affinity-infinity-test
packaging/out/Affinity-Infinity-<ver>-x86_64.AppImage setup     # full prefix build (~5-15 min)
packaging/out/Affinity-Infinity-<ver>-x86_64.AppImage install --msi <cached Affinity-*.msi>   # skip the 650 MB download
packaging/out/Affinity-Infinity-<ver>-x86_64.AppImage run
```

Useful runtime checks: `grep -oE '/[^ ]*(d2d1|d3d12|WineFix)\.dll' /proc/$(pgrep -f '^C:\\Program Files\\Affinity\\Affinity\\Affinity\.exe')/maps` (which DLLs actually loaded), `/proc/<pid>/maps` for `*.ttf` (fonts in use). Affinity reads fonts/registry/DLL overrides only at startup: before trusting an in-app check, confirm the `Affinity.exe` start time (`ps -o lstart=`) is after the change (it also often hangs on exit, so "closed the window" ≠ restarted).

**Never run `bin/affinity-infinity` from the repo against the user's real data dir** (`~/.local/share/affinity-infinity`, used by the installed AppImage in `~/Applications`): without `AI_WINE_ROOT` it uses `<data>/runtime/current` (an older Wine) and would `wineboot -u` the prefix to a different Wine.

## Architecture

`bin/affinity-infinity` is the CLI dispatcher; it sources `versions.env` and every `lib/*.sh` (order matters: `common` first). All modules are plain bash functions sharing globals from `lib/common.sh` (`DATA_DIR`, `PREFIX_DIR`, `WINE_ROOT`, `AFFINITY_DIR`, …). `packaging/AppRun` is the AppImage entry point: it sets `AI_WINE_ROOT=$APPDIR/wine` and `AI_TOOLS_DIR=$APPDIR/tools` and defaults to `run`. When run from an AppImage, `$APPIMAGE` is set by the runtime; `launcher_path` uses it for menu entries.

State: `state.env` (machine-written: versions, ETags, setup step, applied DPI, …) and `config.env` (user settings) are sourceable `KEY=%q` files accessed only via `state_get/state_set/config_get/config_set`. Writes are read-modify-write, so **no two processes may write state concurrently** (why `prefetch_installer` writes only the `.part` file).

`run` flow (`cmd_run`): `selfupdate_check` (AppImage, daily) → `first_run` if no prefix → `wine_env` → `sync_wine_build` (`wineboot -u` when the Wine BUILD id changed) → `refresh_desktop` → `startup_update_check` (Affinity) → d3d12 refresh → `prefix_configure` if `PREFIX_CONFIG_REV` changed → `apply_dpi` → start `AffinityHook.exe` in background + `exit_watchdog` → `wineserver -w` (so the AppImage mount outlives Wine).

Key mechanisms and why they are the way they are:

- **Installing Affinity** (`lib/affinity.sh`): the official `Affinity x64.exe` is a bootstrapper with a WiX MSI in its resources; `carve_msi` cuts it out at the OLE signature and `msiexec /a` (administrative install) unpacks it into a staging dir, then the program dir is swapped (user's `apl/` kept). **Do not switch to `msiexec /i`**: under Wine it copies the 650 MB package into `C:\windows\Installer` and fails to reopen it transacted, leaving copies behind. Registry values the MSI would write (incl. a per-install `Machine ID`) are set by `affinity_registry`.
- **Updates**: Affinity — HEAD request, compare ETag; only if changed, fetch the last 2 MB with an HTTP Range request and read the PE `FileVersion` (`pe_file_version`, `lib/update.sh`). AppImage — GitHub `releases/latest`, sha256-verified in-place replace (`lib/selfupdate.sh`); asset matching must stay anchored on `Affinity-Infinity-*-x86_64.AppImage`.
- **After every Affinity install**: `install_d3d12` copies vkd3d-proton's `d3d12*.dll` from the Wine build next to `Affinity.exe` (without them Affinity's renderer libs fail and it balloons until OOM-killed); `apl_install` unpacks AffinityPluginLoader + WineFix (Affinity must be started via `AffinityHook.exe`, and WineFix's `d2d1.dll` is enabled by an AppDefaults DllOverride).
- **`prefix_configure`** holds idempotent prefix fixes (DpiAwareness=System for DPI via LogPixels, d2d1/d3d12 overrides, font registry repair, Selawik). Bump `PREFIX_CONFIG_REV` whenever it changes so existing prefixes are reconfigured on next `run`.
- **Prefix build** (`lib/prefix.sh`): winetricks steps with timeouts, one retry, per-step logs in `cache/prefix-*.log`, resumable via `PREFIX_STEP`; `PREFIX_READY=0` marks an unfinished build. Wine Mono/Gecko are suppressed with `WINEDLLOVERRIDES=mscoree,mshtml=` **only for setup/tooling commands** — never when running Affinity (it needs native mscoree/.NET).
- **Progress UI** (`lib/common.sh` `progress_*`): during `first_run` one zenity progress window is fed through a fifo; `progress_phase NAME` maps to `PROGRESS_PLAN` percent ranges, `with_spinner` and downloads report into it instead of opening their own dialogs. `gui_mode` = no tty on stderr + display + zenity.
- **Font manager** (`lib/fontlib.sh`, `lib/fontsync.sh`, `plugin/FontSync/FontSync.cs`): Affinity builds its font list from GDI and rebuilds it on `WM_FONTCHANGE`, but Wine's GDI font table is per process, so registry entries, files in `windows/Fonts` or `AddFontResource` from another process never reach a running Affinity. The FontSync APL plugin runs inside it, loads the files in `AI_FONTS_LIST` (`fonts/active.list`, exported by `cmd_run`) with `AddFontResourceEx` at stage 0 and polls every second from a dedicated thread (a `System.Threading.Timer` never fired inside Affinity), re-adding a file whose mtime changed. It is compiled on the user's machine with the prefix's .NET 4.8 `csc.exe` (C# 5 only) against the installed APL; `fontsync_outdated` rebuilds it when the source or `APL_VERSION` changes. Affinity resolves a font's file by **PostScript name**, hence the rule that enabling a font disables library fonts with the same name. `fonts` commands need no Wine and don't write `state.env`; `library.tsv` is theirs, `active.list` is what the plugin reads (both replaced atomically, commands serialised with `flock`). Registry entries in HKCU `...\Fonts` are ignored by Affinity.
- **Exit watchdog**: Affinity usually hangs after its last window closes (settings already saved). `exit_watchdog` watches X11 windows of class `affinity.exe` via `xprop` and runs `wineserver -k` after 20 s without windows and low CPU.
- **Process matching**: match Wine processes by their Windows command line anchored at the start (`^C:\\Program Files\\Affinity\\Affinity\\...`), never a loose `pgrep -f Affinity.exe` (matches unrelated shells/editors).

## Wine build and CI

`wine/build.sh` builds `WINE_VERSION` from `wine/build.env` on Ubuntu 22.04 (glibc 2.35 baseline — do not move the build to a newer distro), applies `wine/patches/<version>/*.patch` (vendored from ryzendew/Affinity-Wine-Builder, see `wine/patches/SOURCE.md`), adds vkd3d-proton, writes a `BUILD` id file and packs a relocatable tarball. To ship a new Wine: bump `WINE_VERSION`/`AI_WINE_REV` (and patches) → `wine.yml` publishes release `wine-<ver>-ai<rev>` → pin `WINE_TARBALL_URL`/`WINE_TARBALL_SHA256` in `packaging/tools.env`.

Workflows: `wine.yml` (Wine release), `appimage.yml` (AppImage; a `v*` tag publishes a GitHub release with `.AppImage`, `.sha256`, `.zsync` — the self-update and `install.sh` depend on those names), `smoke.yml` (headless full first run under xvfb + file/registry checks; weekly, on pushes/PRs touching the app, or `workflow_dispatch`). All external downloads are pinned with sha256 in `versions.env`, `wine/build.env`, `packaging/tools.env`.

## Known limitations (don't re-investigate blindly)

- WebView2 (Help/web panels): runtime 142 crashes in Chromium CHECKs (`msedge.dll+0xa358862` GPU process, `+0x801542d` browser) on Wine 11.0 and 11.12, also with `--disable-gpu --no-sandbox`, and Affinity dies when Help opens. Hence `webview2` is an explicit experimental command, not part of `install`. Untried: fixed-version runtime (e.g. 109) via `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`.
- Affinity uses Wine's `dwrite.dll` only for UI text; `GetSystemFontCollection(checkForUpdates)` is a FIXME in Wine but irrelevant for the font menu (that comes from GDI via `libkernel.dll`).
- Switching Wine's system UI fonts (WindowMetrics) to Selawik made the UI render badly; the UI deliberately stays on Tahoma, Selawik only serves explicit "Segoe UI" requests.

## Shell notes

- In this environment's interactive shell `grep` is ugrep and `find` is bfs (different regex/option handling); use `command grep` / standard options when running ad-hoc commands. Scripts run under plain bash and are unaffected.
- `rm -rf` on variable paths must use `"${VAR:?}/..."`.
- User-facing messages to the maintainer are in Russian; code, comments, commit messages and README are in English.
