# TODO

Ideas that are worked out but not needed yet. Everything below is unimplemented.

## Activate missing fonts from the library

When a document uses fonts that are not active, find them in the font library
and enable them, automatically or after asking (like the auto-activation in
Suitcase / FontExplorer).

Why it cannot work at the OS level: Affinity asks GDI for the full font list once
and then resolves fonts by PostScript name in its own list, so a missing font
never reaches Windows/Wine as a request that could be intercepted.

What exists inside Affinity (names seen in its assembly metadata, 3.3.0.4850):

- `Serif.Affinity.dll`: `CheckForMissingFonts`, `HasMissingFonts`,
  `ShowReplaceFontDialog`, `ReplaceFontControllerDialog`,
  `ReplaceFontControllerDataSource`.
- `Serif.Interop.Persona.dll`: `ToastStrings.DocumentContainsMissingFontsTitle`,
  `GetMissingFontsMessage(vector<string>)` (the "document contains missing fonts"
  toast gets the list of names), `TextBaseTarget.GetMissingFonts`.
- `0Harmony.dll` ships with AffinityPluginLoader; WineFix patches Affinity with it.

Plan, using only what the plugin system gives (no decompiling):

1. **Explore with reflection** from FontSync: log the types and method signatures
   in `Serif.Affinity.dll` whose names contain `MissingFont` / `ReplaceFont`.
2. **Observe with Harmony postfixes** that only log (when called, arguments,
   return value). Open a document with a disabled library font and see where
   the list of missing names is available.
3. Alternative without patching: a WPF class handler on `Window.Loaded`
   (`EventManager.RegisterClassHandler`) that notices `ReplaceFontControllerDialog`
   and reads the missing fonts from its `DataContext`. Only works if Affinity
   shows that dialog rather than just the toast.

Shape of the feature:

- A postfix only (never a prefix that replaces Affinity's behaviour); the plugin
  writes the missing names to a file in `fonts/` (like `fonts/control`).
- The CLI / Affinity Fonts window matches them against `library.tsv` (PostScript
  name, then family) and enables them, automatically or on confirmation (setting).
- Fonts not found in the library are left to Affinity's own "Replace missing
  fonts" dialog.
- If a hook target is missing in a new Affinity version, log "hook not found"
  and carry on.

Open question to answer first: does an already open document pick up a font
enabled after it was opened? (A font rebuilt in place is already redrawn in open
documents, but "became available" may differ from "changed".) If not, fonts have
to be enabled before the document loads, or the document reopened.

A cheap addition for files opened from the file manager: `cmd_run` gets the
document path before Affinity starts, but reading font names from the
proprietary `.af` format is unreliable; the in-process hook is preferred.
