# Changelog

All notable changes to Affinity Infinity. Versions are the AppImage releases
(`v*` tags); the Wine builds they ship are released separately as
`wine-<version>-ai<rev>`.

## [0.3.1] - 2026-09-27

### Added
- One setting for how often to look for updates of Affinity and of Affinity
  Infinity itself: on every start (default), once a day, week or month, or never.
  Set it with **Update settings…** in the Affinity menu entry (a small window
  with radio buttons) or `update --auto start|daily|weekly|monthly|off`.
  `status` shows it.

### Changed
- **Check for updates** (`update`) checks both Affinity and the AppImage right
  away, whatever the setting, and reports in one dialog.
- Update intervals count from the last *successful* check: after an offline
  start the next start tries again (the AppImage check used to lose a day).
- When NetworkManager reports no internet connection, the start-up checks are
  skipped at once instead of waiting for network timeouts.
- Menu entries carry a revision and are rewritten when an update changes them.
  GNOME Shell may show new menu actions only after logging in again.
- `AUTO_UPDATE_CHECK` and `SELF_UPDATE_CHECK` are replaced by `UPDATE_CHECK`;
  `AUTO_UPDATE_CHECK=0` is read as `off`.

## [0.3.0] - 2026-09-27

### Added
- Studio panels dock and group again: they can be dragged onto each other and
  back into the dock instead of staying loose floating windows. Ships Wine
  11.12-ai2 with our own patch: a window drag runs Wine's move loop instead of
  the window manager's, so Affinity sees where a panel is dropped
  (`WINE_X11_WM_MOVE=1` restores the old behaviour).

### Changed
- "Segoe UI" is mapped to Tahoma (FontSubstitutes) instead of installing
  Selawik renamed to Segoe UI; existing prefixes are cleaned up on the next
  start. One download less, no visible difference.
- README leads with the main features and shows the Affinity Fonts window.

## [0.2.1] - 2026-09-27

### Fixed
- Leftovers no longer pile up across updates: only the last two msiexec logs,
  only the current AffinityPluginLoader archive and only the current Wine
  runtime are kept.

## [0.2.0] - 2026-09-27

### Added
- Font manager: fonts are applied to a **running** Affinity. The FontSync
  plugin (compiled on your machine, loaded by AffinityPluginLoader) adds and
  removes fonts inside Affinity within about a second and reloads a font file
  rebuilt in place, so open documents are redrawn with the new version.
- `fonts list|add|enable|disable|remove`: a library of font files referenced
  where they are. Enabling a font disables library fonts with the same
  PostScript name; clashes with system fonts are reported.
- System fonts (Linux/fontconfig, the Wine prefix, Wine's own) can be disabled
  to clean up Affinity's font menu, effective from the next start; the fonts
  Affinity's interface needs are locked.
- `restart`: closes Affinity like its close button (it asks about unsaved
  documents) and starts it again in about 4 seconds.
- **Affinity Fonts** window (`fonts --gui`, own menu entry): My Fonts and
  System pages, family and style switches, a sample line per face with
  adjustable text, size and background, search, drag and drop, badges for
  variable fonts, missing files, clashes and pending changes, and a restart
  banner with progress.
- `fonts` and `restart` are available through the AppImage.

### Fixed
- Test runs with `AFFINITY_INFINITY_DATA` no longer rewrite the real menu
  entries.
- Selawik's PostScript name is renamed correctly when the family name has
  spaces.

## [0.1.3] - 2026-09-26

### Changed
- README rewritten for the current state; documented that WebView2 (Help and
  web panels) also crashes on Wine 11.12.

## [0.1.2] - 2026-09-26

### Added
- The menu entry uses Affinity's own icon, taken from the installed
  `Affinity.exe` on your machine (`ICON=own` keeps ours).

### Fixed
- vkd3d-proton's `d3d12` DLLs next to Affinity are refreshed whenever they
  differ from the Wine build, so AppImage updates bring new vkd3d-proton along.

## [0.1.1] - 2026-09-26

### Added
- `install.sh` (`curl | bash`): installs the latest AppImage into
  `~/Applications`, checksum-verified, adds the menu entry and starts the
  setup; `--uninstall` removes it and asks before deleting Affinity's data.
- First run: one question, then one progress window for the whole setup; the
  Affinity download runs in parallel with building the Windows environment.

### Fixed
- Release assets and the self-update only match `Affinity-Infinity-*` AppImages.

## [0.1.0] - 2026-09-26

First release.

- Affinity is installed and updated from Canva's official installer: the MSI
  inside it is unpacked without the installer GUI. Every start checks for a new
  Affinity (ETag, then the version from the installer's last 2 MB) and offers
  **Install**, **Later** or **Skip this version**.
- Own Wine build (wine-11.12-ai1): Wine 11.12 with the Affinity patches from
  Affinity-Wine-Builder and vkd3d-proton, built on Ubuntu 22.04.
- The Windows environment (.NET Framework 4.8, VC++ 2022, core fonts) is built
  on your machine by winetricks, resumable; nothing from Microsoft or Canva is
  redistributed.
- AffinityPluginLoader + WineFix, Direct3D 12 through vkd3d-proton.
- Fixes: italic UI font (regular faces restored in the 64-bit font registry),
  Selawik as a Segoe UI substitute, a watchdog that ends Affinity's Wine session
  when it hangs after its last window closes.
- Interface scale follows the desktop or a fixed DPI; menu entry with file
  associations for Affinity documents.
- AppImage with daily self-update (sha256-verified) and zsync information.
- Experimental `webview2` command (not part of the install: it crashes).

[0.3.1]: https://github.com/typedev/affinity-infinity/releases/tag/v0.3.1
[0.3.0]: https://github.com/typedev/affinity-infinity/releases/tag/v0.3.0
[0.2.1]: https://github.com/typedev/affinity-infinity/releases/tag/v0.2.1
[0.2.0]: https://github.com/typedev/affinity-infinity/releases/tag/v0.2.0
[0.1.3]: https://github.com/typedev/affinity-infinity/releases/tag/v0.1.3
[0.1.2]: https://github.com/typedev/affinity-infinity/releases/tag/v0.1.2
[0.1.1]: https://github.com/typedev/affinity-infinity/releases/tag/v0.1.1
[0.1.0]: https://github.com/typedev/affinity-infinity/releases/tag/v0.1.0
