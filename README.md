# Affinity-Infinity

Run [Affinity by Canva](https://www.affinity.studio/) on Linux in a Wine sandbox that
installs and updates Affinity **from the official installer**, so you are not waiting
for someone to repackage every release.

The sandbox (Wine runtime + prefix with .NET 4.8 / VC++ runtimes) is separate from
Affinity itself. Affinity is downloaded from `downloads.affinity.studio`, its embedded
MSI is installed with Wine's `msiexec` (no installer GUI), and
[AffinityPluginLoader + WineFix](https://github.com/noahc3/AffinityPluginLoader) are added
on top to fix Wine-specific bugs.

## Status

Milestone 1: command-line tool. The runtime and base prefix are seeded from an existing
Affinity AppImage (e.g. from
[Linux-Affinity-Installer](https://github.com/ryzendew/Linux-Affinity-Installer/releases));
the Affinity copy inside that AppImage is discarded. A standalone AppImage with a
reproducibly built prefix is the next milestone.

## Usage

```sh
bin/affinity-infinity setup --from-appimage ~/AppImages/Affinity-3.2.0-x86_64.AppImage
bin/affinity-infinity install      # download + install the latest Affinity
bin/affinity-infinity desktop      # menu entry, file associations
bin/affinity-infinity run          # or start "Affinity" from the menu
```

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

`run` also checks once a day in the background and shows a notification when an update
is available. The menu entry has "Check for updates" and "Interface scale…" actions.

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
