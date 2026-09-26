# Affinity-Infinity

Run [Affinity by Canva](https://www.affinity.studio/) on Linux in a Wine sandbox that
installs and updates Affinity **from the official installer**, so you are not waiting
for someone to repackage every release.

Nothing from Microsoft or Canva is redistributed:

- **Wine** is built by this project (`wine/`): Wine 11.12 with the Affinity patches
  from [Affinity-Wine-Builder](https://github.com/ryzendew/Affinity-Wine-Builder)
  (ElementalWarrior's work, d2d1 fixes, XDG portal file dialogs) plus
  [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton), on Ubuntu 22.04
  (glibc 2.35) so it runs on current Ubuntu, Fedora and friends.
- **The Windows environment** (Wine prefix with .NET Framework 4.8, VC++ 2022, core
  fonts) is built on your machine on first start by winetricks from Microsoft's
  installers (~15 minutes, once).
- **Affinity** is downloaded from `downloads.affinity.studio`; its embedded MSI is
  unpacked with Wine's `msiexec` (no installer GUI), and
  [AffinityPluginLoader + WineFix](https://github.com/noahc3/AffinityPluginLoader) are
  added on top to fix Wine-specific bugs.

Not affiliated with Canva. Affinity is a trademark of Canva.

## AppImage

Download `Affinity-Infinity-<version>-x86_64.AppImage`, make it executable and start it.
The first start sets up the environment, installs Affinity and offers a menu entry
(with icon and `.af*` file associations). Needs `fuse3` (preinstalled on desktop
Ubuntu/Fedora; no `libfuse2`), `zenity` for dialogs and optionally `python3`
(Segoe UI substitute). Commands work on the AppImage too, e.g.
`./Affinity-Infinity-*.AppImage status` or `... dpi 192`.

## From the repository

```sh
wine/build-in-container.sh                  # build Wine (podman/docker) -> wine/out/
packaging/build-tools.sh                    # winetricks + cabextract    -> packaging/out/tools
bin/affinity-infinity setup --wine wine/out/wine-11.12-ai1-x86_64.tar.xz
AI_TOOLS_DIR=packaging/out/tools bin/affinity-infinity setup   # resume, if needed
bin/affinity-infinity install      # download + install the latest Affinity
bin/affinity-infinity desktop      # menu entry, file associations
bin/affinity-infinity run
packaging/build-appimage.sh wine/out/wine-11.12-ai1-x86_64.tar.xz   # -> packaging/out/
```

`setup --from-appimage PATH` still seeds runtime and prefix from another Affinity
AppImage (legacy path).

Updates:

```sh
bin/affinity-infinity check        # exit 0 if a newer Affinity was published
bin/affinity-infinity update       # install it
```

Prefix fixes applied automatically (and once more on `run` when they change):

- the regular faces of Arial, Tahoma etc. missing from the 64-bit font registry are
  restored — without them Affinity's UI is drawn in Arial Italic;
- Segoe UI, which Affinity's UI asks for, is provided by
  [Selawik](https://github.com/microsoft/Selawik) (OFL), renamed locally to "Segoe UI"
  (needs `python3`; otherwise the UI uses Tahoma).

`run` checks for a new Affinity on every start: a HEAD request (~0.2 s) compares the
installer's ETag, and only when it changed are the last 2 MB of the installer fetched to
read its exact version. If it is newer, a dialog offers **Install**, **Later** or
**Skip this version**; a failed check or update never prevents Affinity from starting
(offline, the start is delayed by at most ~3 s). `AUTO_UPDATE_CHECK=0` in the config
turns this off. The menu entry has "Check for updates" and "Interface scale…" actions.

### Interface scale (4K / HiDPI)

```sh
bin/affinity-infinity dpi          # configured / detected / effective DPI
bin/affinity-infinity dpi 192      # 200 %
bin/affinity-infinity dpi auto     # follow the desktop (Xft.dpi, GNOME scaling, GDK_SCALE)
bin/affinity-infinity dpi --gui    # slider
```

A DPI chosen in the old AppImage (`~/.affinity-appimage-dpi.conf`) is imported on setup.

### Rollback

The MSI of the installed and the previous Affinity version are kept in the cache:

```sh
bin/affinity-infinity install --msi ~/.local/share/affinity-infinity/cache/Affinity-<version>.msi
```

## Files

| Path | Contents |
|---|---|
| `~/.local/share/affinity-infinity/runtime/` | Wine builds, `current` → active one |
| `~/.local/share/affinity-infinity/prefix/` | Wine prefix (Affinity, settings, user data) |
| `~/.local/share/affinity-infinity/cache/` | Installer MSIs, plugin loader archive, msiexec logs |
| `~/.local/share/affinity-infinity/state.env` | Installed versions, installer ETag, applied DPI |
| `~/.config/affinity-infinity/config.env` | `DPI=auto\|96..480`, `AUTO_UPDATE_CHECK=1\|0` |

Pinned third-party versions and checksums live in `versions.env`.

## Development

```sh
uv pip install --python .venv shellcheck-py
.venv/bin/shellcheck -x -P SCRIPTDIR bin/affinity-infinity lib/*.sh versions.env
```
