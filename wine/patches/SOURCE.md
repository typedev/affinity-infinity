# Wine patches

`11.12/` is copied unchanged from
[ryzendew/Affinity-Wine-Builder](https://github.com/ryzendew/Affinity-Wine-Builder)
`patches/wine-11.12`, commit `362276c6246546e9b86c0bd3d37271bb0234d958` (2026-06-29),
licensed GPL-2.0 (the patches themselves modify Wine, LGPL-2.1-or-later).

They carry ElementalWarrior's Affinity work (dxcore, OpenCL), d2d1 fixes (cubic
Bézier subdivision, collinear joins, bounded recursion), XDG Desktop Portal file
dialogs for comdlg32, and assorted OpenCL/SRW-lock optimisations. Patches are
applied in file-name order with `patch -p1`.

To update, copy the new `patches/wine-<version>/` directory here, record the
commit above, and bump `WINE_VERSION`/`AI_WINE_REV` in `../build.env`.
