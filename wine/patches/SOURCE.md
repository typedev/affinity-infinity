# Wine patches

`11.19/` is copied from
[ryzendew/Affinity-Wine-Builder](https://github.com/ryzendew/Affinity-Wine-Builder)
`patches/wine-11.19`, commit `6d7151b3c650a0db1a3a0582d4a8ed2b32a2fbe9` (2026-11-04),
licensed GPL-2.0 (the patches themselves modify Wine, LGPL-2.1-or-later).

`0001-0031` are ElementalWarrior's base set (dxcore, OpenCL bridge, d2d1 fixes,
XDG Desktop Portal file dialogs, OpenCL/SRW-lock optimisations); `0032` onwards is
jfacemyer's Affinity 3.3 set (window management and focus under KWin, palette
docking via the internal move loop, process exit, OpenCL event callbacks that no
longer hang startup on a real GPU, wined3d/d2d1 rendering and speed, printing,
login). Patches are applied in file-name order with `patch -p1 --forward`, so
every file must apply exactly; two differ from upstream for that reason:

- `0001-downgrade-dxcore-to-10_8.patch`: the hunks deleting `dlls/dxcore/dxcore.c`
  and `dlls/dxcore/tests/dxcore.c` are removed. On 11.19 `patch` rejects them as
  reversed and upstream's build script carries on with the rest of the file; the
  result (both files left in place, unused) is the same.
- `0004-vkd3d-shader-zero-pad-output-signature.patch` is dropped: Wine 11.19's
  bundled vkd3d already contains it (upstream skips it as already applied).

Up to `0127`, the patched tree is identical to the one upstream's
`Build-Wine-11.19.sh` produces.

This project's own patches are numbered `9000-*` so they sort after the
upstream set:

- `9000-winex11-size-owned-palettes-internally.patch`: SC_SIZE of an owned palette
  (the windows upstream `0037`/`0065` move internally) runs win32u's size loop
  instead of `_NET_WM_MOVERESIZE`. Since `0057` made these windows managed, a
  floating Affinity panel resized by the window manager (Mutter) got no
  `WM_SIZING`, would not resize and left garbage.

The former `0100-winex11-move-windows-with-user32-loop.patch`
(11.12, every window moved with the internal loop) is superseded by upstream
`0037`/`0065`, which move owned palettes internally and leave main windows to the
window manager.

To update, copy the new `patches/wine-<version>/` directory here (keeping and
rebasing any `9000-*` patches), check that every patch applies with
`patch -p1 --forward`, record the commit above, and bump
`WINE_VERSION`/`AI_WINE_REV` in `../build.env`.
