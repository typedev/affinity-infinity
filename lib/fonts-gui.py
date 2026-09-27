#!/usr/bin/env python3
"""Affinity Fonts: a GTK window for the font manager (`affinity-infinity fonts`).

Started by `affinity-infinity fonts --gui`, which passes:
  AI_CLI            the command to run (the AppImage or bin/affinity-infinity)
  AI_FONTS_DIR      the font manager's data directory (library.tsv, ...)
  AI_CONFIG_DIR     where the sample settings are remembered
  AI_WINDOWS_FONTS  the prefix's windows/Fonts (to find disabled prefix fonts)

Everything that changes state goes through the CLI, so the window and the
command line always agree; the window only reads `fonts list --all --tsv`
and watches the data directory and the library's font files for changes.
"""
import hashlib
import json
import os
import shutil
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk, Pango, PangoCairo  # noqa: E402

APP_ID = "io.github.typedev.AffinityInfinity.Fonts"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.environ.get("AI_CLI") or os.path.join(ROOT, "bin", "affinity-infinity")
FONTS_DIR = os.environ.get("AI_FONTS_DIR", os.path.expanduser("~/.local/share/affinity-infinity/fonts"))
CONFIG_DIR = os.environ.get("AI_CONFIG_DIR", os.path.expanduser("~/.config/affinity-infinity"))
WINDOWS_FONTS = os.environ.get("AI_WINDOWS_FONTS", "")
SETTINGS_FILE = os.path.join(CONFIG_DIR, "fonts-gui.conf")
# Per family, the styles that were on when the family was switched off.
FAMILIES_FILE = os.path.join(CONFIG_DIR, "fonts-gui-families.json")
PREVIEW_DIR = os.path.join(GLib.get_user_cache_dir(), "affinity-infinity", "font-previews")
DEFAULT_SAMPLE = "The quick brown fox jumps over the lazy dog 0123456789"
DEFAULT_SETTINGS = {"sample": DEFAULT_SAMPLE, "size": "36", "background": "light"}
AFFINITY_EXE = "C:\\Program Files\\Affinity\\Affinity\\Affinity.exe"

SOURCES = [
    ("all", "All sources"),
    ("fontconfig", "Linux"),
    ("prefix", "Windows prefix"),
    ("wine", "Wine"),
]

CSS = """
.ai-badge { border-radius: 99px; padding: 0 8px; font-size: smaller; font-weight: bold;
            background: alpha(currentColor, 0.1); }
.ai-badge.accent { color: @accent_color; background: alpha(@accent_bg_color, 0.15); }
.ai-badge.warning { color: @warning_color; background: alpha(@warning_bg_color, 0.15); }
.ai-badge.error { color: @error_color; background: alpha(@error_bg_color, 0.15); }
.ai-light listview, .ai-light listview > row { background: #ffffff; color: #1e1e1e; }
.ai-dark listview, .ai-dark listview > row { background: #000000; color: #f0f0f0; }
.ai-light listview > header { background: #f0f0f0; color: #1e1e1e; }
.ai-dark listview > header { background: #1a1a1a; color: #f0f0f0; }
.ai-light listview > row { border-color: alpha(#000000, 0.08); }
.ai-dark listview > row { border-color: alpha(#ffffff, 0.12); }
"""


def affinity_running() -> bool:
    """True while Affinity.exe runs (matched on its Windows command line)."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                arg0 = f.read().split(b"\0", 1)[0].decode(errors="replace")
        except OSError:
            continue
        if arg0 == AFFINITY_EXE:
            return True
    return False


def short(text: str) -> str:
    """A CLI message without the program prefix and with file names instead of paths."""
    text = text.removeprefix("affinity-infinity: ")
    return " ".join(os.path.basename(w) if w.startswith("/") else w for w in text.split(" "))


class Face(GObject.Object):
    """One face of a font file, as listed by `fonts list --all --tsv`."""

    __gtype_name__ = "AiFace"

    source = GObject.Property(type=str, default="")
    state = GObject.Property(type=str, default="on")
    flags = GObject.Property(type=str, default="")
    ps = GObject.Property(type=str, default="")
    family = GObject.Property(type=str, default="")
    style = GObject.Property(type=str, default="")
    instances = GObject.Property(type=int, default=0)
    path = GObject.Property(type=str, default="")
    # Changes when the file is rebuilt, so the preview is redrawn.
    revision = GObject.Property(type=int, default=0)

    def has(self, flag: str) -> bool:
        return flag in self.flags.split(",")

    @property
    def family_key(self) -> str:
        return ("library" if self.source == "library" else "system") + "\0" + self.family

    @property
    def key(self) -> str:
        return f"{self.source}\0{self.path}\0{self.ps}\0{self.style}"

    @property
    def file(self) -> str:
        """Where the file is now: disabled prefix fonts wait in fonts/prefix-off."""
        if WINDOWS_FONTS and self.path.startswith(WINDOWS_FONTS + "/") and not os.path.exists(self.path):
            return os.path.join(FONTS_DIR, "prefix-off", os.path.basename(self.path))
        return self.path


def parse_list(text: str) -> list:
    faces = []
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) != 8:
            continue
        source, state, flags, ps, family, style, instances, path = cols
        face = Face(source=source, state=state, flags="" if flags == "-" else flags, ps=ps,
                    family=family or os.path.basename(path), style=style,
                    instances=int(instances or 0), path=path)
        faces.append(face)
    return faces


class Previews:
    """Loads font files that fontconfig does not know into the window's font map.

    Each version of a file is loaded from its own copy, as fonts added later take
    precedence in Pango: a rebuilt font shows its new glyphs.
    """

    def __init__(self):
        self.fontmap = PangoCairo.FontMap.get_default()
        self.enabled = hasattr(self.fontmap, "add_font_file")
        self.loaded = {}
        shutil.rmtree(PREVIEW_DIR, ignore_errors=True)

    def load(self, face: Face) -> bool:
        """Load the face's file if it is new or changed; True if it changed."""
        if not self.enabled or face.source == "fontconfig":
            return False
        try:
            mtime = os.stat(face.file).st_mtime_ns
        except OSError:
            return False
        if self.loaded.get(face.file) == mtime:
            return False
        os.makedirs(PREVIEW_DIR, exist_ok=True)
        name = hashlib.sha1(face.file.encode()).hexdigest()[:16]
        copy = os.path.join(PREVIEW_DIR, f"{name}-{mtime}{os.path.splitext(face.file)[1]}")
        try:
            shutil.copyfile(face.file, copy)
            self.fontmap.add_font_file(copy)
        except (OSError, GLib.Error) as e:
            print(f"preview of {face.file}: {e}", file=sys.stderr)
            return False
        changed = face.file in self.loaded
        self.loaded[face.file] = mtime
        return changed


class FontRow(Gtk.Box):
    """A row of the font lists: switch, style, sample, badges, actions."""

    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12,
                         margin_start=12, margin_end=12, margin_top=6, margin_bottom=6)
        self.window = window
        self.face = None
        self.handler = 0
        self.updating = False

        self.switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        self.switch.connect("state-set", self.on_switch)
        self.lock = Gtk.Image(icon_name="changes-prevent-symbolic", valign=Gtk.Align.CENTER,
                              tooltip_text="Needed by Affinity's interface; cannot be disabled")
        self.lock.set_size_request(48, -1)
        self.append(self.switch)
        self.append(self.lock)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        top = Gtk.Box(spacing=8)
        self.title = Gtk.Label(xalign=0, css_classes=["caption-heading"])
        self.subtitle = Gtk.Label(xalign=0, css_classes=["dim-label", "caption"],
                                  ellipsize=Pango.EllipsizeMode.END)
        self.badges = Gtk.Box(spacing=4)
        top.append(self.title)
        top.append(self.subtitle)
        top.append(self.badges)
        self.sample = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END, single_line_mode=True)
        text.append(top)
        text.append(self.sample)
        self.append(text)

        self.conflict = Gtk.Button(label="Disable system version", valign=Gtk.Align.CENTER,
                                   css_classes=["flat"],
                                   tooltip_text="A system font has the same PostScript name; "
                                                "Affinity may use either file")
        self.conflict.connect("clicked", lambda _b: window.disable_system_twin(self.face))
        self.remove = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER,
                                 css_classes=["flat"], tooltip_text="Remove from the library "
                                                                    "(the file stays where it is)")
        self.remove.connect("clicked", lambda _b: window.run(["remove", self.face.path]))
        self.append(self.conflict)
        self.append(self.remove)

    def bind(self, face: Face):
        self.face = face
        self.handler = face.connect("notify", lambda *_: self.update())
        self.update()

    def unbind(self):
        if self.face and self.handler:
            self.face.disconnect(self.handler)
        self.face, self.handler = None, 0

    def badge(self, text: str, kind: str = "", tooltip: str = ""):
        label = Gtk.Label(label=text, css_classes=["ai-badge"] + ([kind] if kind else []),
                          valign=Gtk.Align.CENTER, tooltip_text=tooltip or None)
        self.badges.append(label)

    def update(self):
        face = self.face
        if face is None:
            return
        library = face.source == "library"
        protected = face.has("protected")
        family_on = self.window.family_on.get(face.family_key, True)
        self.updating = True
        self.switch.set_active(face.state == "on")
        self.updating = False
        # The family switch is the master: while it is off the styles are shaded.
        self.switch.set_sensitive(family_on)
        self.switch.set_visible(not protected)
        self.lock.set_visible(protected)

        self.title.set_label(f"{face.family} {face.style}".strip())
        self.subtitle.set_label(face.ps)
        self.set_tooltip_text(f"{face.ps}\n{face.path}")

        while child := self.badges.get_first_child():
            self.badges.remove(child)
        if face.instances:
            self.badge(f"Variable · {face.instances}", tooltip="Variable font with named instances")
        if face.has("missing"):
            self.badge("File missing", "error", face.path)
        if face.has("unreadable"):
            self.badge("Unreadable", "error", "Not a TrueType/OpenType font")
        if face.has("pending"):
            self.badge("After restart", "accent", "Applies when Affinity starts next")
        if face.has("system"):
            self.badge("Also a system font", "warning")

        desc = Pango.FontDescription.from_string(f"{face.family} {face.style}".strip())
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_font_desc_new(desc))
        attrs.insert(Pango.attr_size_new_absolute(int(self.window.sample_size * Pango.SCALE)))
        self.sample.set_attributes(attrs)
        self.sample.set_label(self.window.sample_text)
        self.sample.set_opacity(0.45 if face.state == "off" or not family_on or face.has("missing") else 1.0)
        self.title.set_opacity(0.55 if not family_on else 1.0)

        self.conflict.set_visible(library and face.has("system") and face.state == "on")
        self.remove.set_visible(library)

    def on_switch(self, _switch, state):
        if not self.updating and self.face is not None:
            self.window.set_enabled(self.face, state)
        return False


class FamilyHeader(Gtk.Box):
    """The line above a family's faces: a switch for all of them and a count."""

    def __init__(self, font_list):
        super().__init__(spacing=12, margin_start=12, margin_end=12, margin_top=6, margin_bottom=6)
        self.font_list = font_list
        self.faces = []
        self.updating = False
        self.switch = Gtk.Switch(valign=Gtk.Align.CENTER, tooltip_text="All styles of this family")
        self.switch.connect("state-set", self.on_switch)
        self.name = Gtk.Label(xalign=0, css_classes=["heading"])
        self.count = Gtk.Label(xalign=0, css_classes=["dim-label", "caption"])
        self.append(self.switch)
        self.append(self.name)
        self.append(self.count)

    def bind(self, header):
        model = self.font_list.model
        self.faces = [model.get_item(i) for i in range(header.get_start(), header.get_end())]
        self.font_list.headers.add(self)
        self.update()

    def unbind(self):
        self.font_list.headers.discard(self)
        self.faces = []

    def switchable(self):
        return [f for f in self.faces if not f.has("protected")]

    def update(self):
        if not self.faces:
            return
        faces = self.switchable()
        on = sum(1 for f in self.faces if f.state == "on")
        n = len(self.faces)
        self.name.set_label(self.faces[0].family)
        self.count.set_label(f"{n} styles · {on} on" if n > 1 else ("on" if on else "off"))
        self.updating = True
        self.switch.set_active(self.font_list.window.family_on.get(self.faces[0].family_key, True))
        self.updating = False
        self.switch.set_sensitive(bool(faces))

    def on_switch(self, _switch, state):
        if not self.updating:
            self.font_list.window.set_family_enabled(self.faces[0].family_key, self.switchable(), state)
        return False


class FontList(Gtk.Box):
    """A searchable font list, sorted and grouped by family."""

    def __init__(self, window, store: Gio.ListStore, filter_func):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.headers = set()
        self.filter = Gtk.CustomFilter.new(filter_func)
        filtered = Gtk.FilterListModel(model=store, filter=self.filter)
        family = Gtk.PropertyExpression.new(Face, None, "family")
        style = Gtk.PropertyExpression.new(Face, None, "style")
        sorter = Gtk.MultiSorter()
        sorter.append(Gtk.StringSorter(expression=family))
        sorter.append(Gtk.StringSorter(expression=style))
        self.model = Gtk.SortListModel(model=filtered, sorter=sorter,
                                       section_sorter=Gtk.StringSorter(expression=family))

        factory = Gtk.SignalListItemFactory()
        factory.connect("setup", lambda _f, item: item.set_child(FontRow(window)))
        factory.connect("bind", lambda _f, item: item.get_child().bind(item.get_item()))
        factory.connect("unbind", lambda _f, item: item.get_child().unbind())
        header = Gtk.SignalListItemFactory()
        header.connect("setup", lambda _f, h: h.set_child(FamilyHeader(self)))
        header.connect("bind", lambda _f, h: h.get_child().bind(h))
        header.connect("unbind", lambda _f, h: h.get_child().unbind())
        self.view = Gtk.ListView(model=Gtk.NoSelection(model=self.model), factory=factory,
                                 header_factory=header, show_separators=True)
        scroller = Gtk.ScrolledWindow(vexpand=True, child=self.view)
        self.append(scroller)

    def refilter(self):
        self.filter.changed(Gtk.FilterChange.DIFFERENT)

    def update_headers(self):
        for header in list(self.headers):
            header.update()


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Affinity Fonts", default_width=960, default_height=760)
        self.previews = Previews()
        self.set_font_map(self.previews.fontmap)
        self.settings = self.load_settings()
        self.sample_text = self.settings["sample"] or DEFAULT_SAMPLE
        self.sample_size = self.setting_size()
        self.query = ""
        self.source = "all"
        self.library = Gio.ListStore(item_type=Face)
        self.system = Gio.ListStore(item_type=Face)
        self.faces = {}
        self.reload_pending = 0
        self.listing = False
        self.busy = 0
        self.restarting = False
        self.mtimes = {}
        # A family is on while any of its (switchable) styles is on.
        self.family_on = {}
        self.remembered = self.load_families()

        # Header: page switcher, add and search buttons.
        self.stack = Adw.ViewStack()
        header = Adw.HeaderBar(title_widget=Adw.ViewSwitcher(stack=self.stack,
                                                             policy=Adw.ViewSwitcherPolicy.WIDE))
        add_menu = Gio.Menu()
        add_menu.append("Add Font Files…", "win.add-files")
        add_menu.append("Add Folder…", "win.add-folder")
        header.pack_start(Gtk.MenuButton(icon_name="list-add-symbolic", menu_model=add_menu,
                                         tooltip_text="Add fonts to the library"))
        self.search_button = Gtk.ToggleButton(icon_name="system-search-symbolic", tooltip_text="Search")
        header.pack_end(self.search_button)
        main_menu = Gio.Menu()
        main_menu.append("Refresh", "win.refresh")
        main_menu.append("Restart Affinity", "win.restart")
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=main_menu))

        search = Gtk.SearchEntry(placeholder_text="Family, PostScript name or file", hexpand=True)
        search.connect("search-changed", self.on_search)
        self.search_bar = Gtk.SearchBar(child=Adw.Clamp(child=search, maximum_size=600),
                                        key_capture_widget=self)
        self.search_bar.connect_entry(search)
        self.search_button.bind_property("active", self.search_bar, "search-mode-enabled",
                                         GObject.BindingFlags.BIDIRECTIONAL)

        sample = Gtk.Entry(text=self.settings["sample"], placeholder_text="Sample text", hexpand=True)
        sample.connect("changed", self.on_sample)
        size = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 12, 120, 1)
        size.set_value(self.sample_size)
        size.set_size_request(160, -1)
        size.set_tooltip_text("Sample size")
        size.connect("value-changed", self.on_size)
        self.size_label = Gtk.Label(label=f"{self.sample_size:.0f} px", width_chars=6, xalign=1,
                                    css_classes=["dim-label", "numeric"])
        contrast = Gtk.ToggleButton(icon_name="image-adjust-contrast-symbolic", valign=Gtk.Align.CENTER,
                                    active=self.settings["background"] == "dark",
                                    tooltip_text="Samples on black / on white")
        contrast.connect("toggled", lambda b: self.on_background("dark" if b.get_active() else "light"))
        sample_bar = Gtk.Box(spacing=12, margin_start=12, margin_end=12, margin_top=6, margin_bottom=6)
        sample_bar.append(sample)
        sample_bar.append(size)
        sample_bar.append(self.size_label)
        sample_bar.append(contrast)

        self.banner = Adw.Banner(title="Changes to system fonts apply when Affinity starts again",
                                 button_label="Restart Affinity")
        self.banner.connect("button-clicked", lambda _b: self.restart())

        # My fonts: the list, or a hint while the library is empty.
        self.library_list = FontList(self, self.library, self.matches)
        empty = Adw.StatusPage(icon_name="font-x-generic-symbolic", title="No Fonts Yet",
                               description="Drop font files or folders here, or use the + button.\n"
                                           "Files stay where they are; a rebuilt font is reloaded "
                                           "in Affinity within a second.")
        self.library_stack = Gtk.Stack()
        self.library_stack.add_named(empty, "empty")
        self.library_stack.add_named(self.library_list, "list")
        page = self.stack.add_titled(self.library_stack, "library", "My Fonts")
        page.set_icon_name("font-x-generic-symbolic")

        # System: a source filter above the list.
        self.system_list = FontList(self, self.system, self.matches)
        sources = Gtk.DropDown.new_from_strings([label for _k, label in SOURCES])
        sources.connect("notify::selected", self.on_source)
        self.system_summary = Gtk.Label(xalign=1, hexpand=True, css_classes=["dim-label"])
        bar = Gtk.Box(spacing=12, margin_start=12, margin_end=12, margin_top=6, margin_bottom=6)
        bar.append(sources)
        bar.append(self.system_summary)
        system_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        system_box.append(bar)
        system_box.append(self.system_list)
        page = self.stack.add_titled(system_box, "system", "System")
        page.set_icon_name("computer-symbolic")

        self.toasts = Adw.ToastOverlay(child=self.stack)
        view = Adw.ToolbarView(content=self.toasts)
        view.add_top_bar(header)
        view.add_top_bar(self.search_bar)
        view.add_top_bar(sample_bar)
        view.add_top_bar(self.banner)
        self.set_content(view)
        self.on_background(self.settings["background"])

        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop.connect("drop", self.on_drop)
        self.add_controller(drop)

        for name, callback in (("add-files", self.add_files), ("add-folder", self.add_folder),
                               ("refresh", self.reload), ("restart", self.restart)):
            action = Gio.SimpleAction(name=name)
            action.connect("activate", lambda _a, _p, cb=callback: cb())
            self.add_action(action)
        app.set_accels_for_action("win.add-files", ["<Control>o"])
        app.set_accels_for_action("win.refresh", ["<Control>r", "F5"])

        # The CLI (or another window) changes the data files; font files get rebuilt.
        os.makedirs(FONTS_DIR, exist_ok=True)
        self.monitor = Gio.File.new_for_path(FONTS_DIR).monitor_directory(Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", lambda *_: self.schedule_reload())
        GLib.timeout_add_seconds(2, self.poll)
        self.reload()

    # ------------------------------------------------------------ data

    def matches(self, face: Face) -> bool:
        if face.source != "library" and self.source != "all" and face.source != self.source:
            return False
        if not self.query:
            return True
        q = self.query.lower()
        return q in face.family.lower() or q in face.ps.lower() or q in face.path.lower()

    def schedule_reload(self, delay_ms: int = 300):
        if self.reload_pending:
            GLib.source_remove(self.reload_pending)
        self.reload_pending = GLib.timeout_add(delay_ms, self.reload)

    def reload(self):
        self.reload_pending = 0
        if self.listing:
            self.schedule_reload()
            return False
        self.listing = True
        self.cli(["list", "--all", "--tsv"], self.on_list, quiet=True)
        return False

    def on_list(self, ok, out, err):
        self.listing = False
        if not ok:
            self.toast(short(err.strip().splitlines()[-1]) if err.strip() else "Cannot read the font list")
            return
        faces = parse_list(out)
        family_on = {}
        for face in faces:
            if not face.has("protected"):
                family_on[face.family_key] = family_on.get(face.family_key, False) or face.state == "on"
        changed_families = {k for k in set(family_on) | set(self.family_on)
                            if family_on.get(k, True) != self.family_on.get(k, True)}
        self.family_on = family_on
        seen = set()
        for face in faces:
            seen.add(face.key)
            old = self.faces.get(face.key)
            if old is None:
                self.faces[face.key] = face
                (self.library if face.source == "library" else self.system).append(face)
                old = face
            else:
                for prop in ("state", "flags", "family", "instances"):
                    if old.get_property(prop) != face.get_property(prop):
                        old.set_property(prop, face.get_property(prop))
            if self.previews.load(old) or old.family_key in changed_families:
                old.revision += 1
        for store in (self.library, self.system):
            for i in reversed(range(store.get_n_items())):
                if store.get_item(i).key not in seen:
                    del self.faces[store.get_item(i).key]
                    store.remove(i)
        self.mtimes = {f.path: self.mtime(f.path) for f in faces if f.source == "library"}
        self.library_list.update_headers()
        self.system_list.update_headers()
        self.library_stack.set_visible_child_name("list" if self.library.get_n_items() else "empty")
        off = sum(1 for f in faces if f.source != "library" and f.state == "off")
        self.system_summary.set_label(f"{off} disabled" if off else "")
        self.update_banner()

    @staticmethod
    def mtime(path: str) -> int:
        try:
            return os.stat(path).st_mtime_ns
        except OSError:
            return 0

    def poll(self):
        """Rebuilt library fonts: reload (previews) when a file changes."""
        if any(self.mtime(p) != m for p, m in self.mtimes.items()):
            self.schedule_reload(0)
        self.update_banner()
        return True

    def update_banner(self):
        pending = any(self.system.get_item(i).has("pending") for i in range(self.system.get_n_items()))
        if self.restarting:
            self.banner.set_title("Waiting for Affinity to close…")
            self.banner.set_button_label(None)
            self.banner.set_revealed(True)
        else:
            self.banner.set_title("Changes to system fonts apply when Affinity starts again")
            self.banner.set_button_label("Restart Affinity")
            self.banner.set_revealed(pending and affinity_running())

    # ------------------------------------------------------------ actions

    def cli(self, args, done=None, quiet=False):
        """Run `affinity-infinity fonts ARGS…` (or ARGS as given, if it starts with "!")."""
        argv = [CLI] + (args[1:] if args[0] == "!" else ["fonts"] + args)
        try:
            proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE)
        except GLib.Error as e:
            self.toast(f"Cannot run {CLI}: {e.message}")
            return
        if not quiet:
            self.busy += 1

        def finish(p, result):
            try:
                _ok, out, err = p.communicate_utf8_finish(result)
            except GLib.Error as e:
                out, err = "", e.message
            if not quiet:
                self.busy -= 1
            if done:
                done(p.get_successful(), out or "", err or "")

        proc.communicate_utf8_async(None, None, finish)

    def run(self, args):
        """A state-changing fonts command: report what matters, then reload."""
        def done(ok, _out, err):
            notable = [short(line) for line in err.splitlines()
                       if "warning" in line or "error" in line or "same PostScript" in line
                       or "system font" in line]
            if notable:
                self.toast(notable[-1] if len(notable) == 1 else f"{notable[-1]} (+{len(notable) - 1} more)")
            elif not ok:
                self.toast("The fonts command failed")
            self.schedule_reload(0)
        self.cli(args, done)

    def set_enabled(self, face: Face, on: bool):
        args = ["enable" if on else "disable"]
        if face.source != "library":
            args.append("--system")
        self.run(args + [face.path])

    def set_family_enabled(self, key: str, faces, on: bool):
        """Switch a family: off remembers which styles were on, on restores them (or all)."""
        paths = {f.path for f in faces}
        if not on:
            self.remembered[key] = sorted({f.path for f in faces if f.state == "on"})
            self.save_families()
        else:
            restore = paths & set(self.remembered.get(key, []))
            faces = [f for f in faces if not restore or f.path in restore]
        library = sorted({f.path for f in faces if f.source == "library"})
        system = sorted({f.path for f in faces if f.source != "library"})
        if library:
            self.run(["enable" if on else "disable"] + library)
        if system:
            self.run(["enable" if on else "disable", "--system"] + system)

    def disable_system_twin(self, face: Face):
        twins = [f.path for f in self.faces.values()
                 if f.source != "library" and f.ps == face.ps and f.state == "on" and not f.has("protected")]
        if twins:
            self.run(["disable", "--system"] + sorted(set(twins)))
        else:
            self.toast("The system font with this name cannot be disabled")

    def add_paths(self, paths):
        if paths:
            self.toast(f"Adding {len(paths)} item{'s' if len(paths) > 1 else ''}…")
            self.run(["add"] + paths)

    def add_files(self):
        dialog = Gtk.FileDialog(title="Add Font Files")
        fonts = Gtk.FileFilter(name="Fonts")
        for pattern in ("*.ttf", "*.otf", "*.ttc", "*.TTF", "*.OTF", "*.TTC"):
            fonts.add_pattern(pattern)
        filters = Gio.ListStore(item_type=Gtk.FileFilter)
        filters.append(fonts)
        dialog.set_filters(filters)

        def done(d, result):
            try:
                files = d.open_multiple_finish(result)
            except GLib.Error:
                return
            self.add_paths([files.get_item(i).get_path() for i in range(files.get_n_items())])
        dialog.open_multiple(self, None, done)

    def add_folder(self):
        def done(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return
            self.add_paths([folder.get_path()])
        Gtk.FileDialog(title="Add Folder").select_folder(self, None, done)

    def on_drop(self, _target, value, _x, _y):
        self.stack.set_visible_child_name("library")
        self.add_paths([f.get_path() for f in value.get_files() if f.get_path()])
        return True

    def restart(self):
        if self.restarting:
            return

        def done(ok, _out, err):
            self.restarting = False
            if not ok:
                lines = [short(line) for line in err.splitlines() if line.strip()]
                self.toast(lines[-1] if lines else "Affinity was not restarted")
            else:
                self.toast("Affinity is starting")
            self.update_banner()
            self.schedule_reload(0)
        self.restarting = True
        self.update_banner()
        self.cli(["!", "restart"], done, quiet=True)

    # ------------------------------------------------------------ UI state

    def toast(self, text: str):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(text), timeout=5))

    def on_search(self, entry):
        self.query = entry.get_text().strip()
        self.library_list.refilter()
        self.system_list.refilter()

    def on_source(self, dropdown, _pspec):
        self.source = SOURCES[dropdown.get_selected()][0]
        self.system_list.refilter()

    def redraw(self):
        for store in (self.library, self.system):
            for i in range(store.get_n_items()):
                store.get_item(i).revision += 1

    def on_sample(self, entry):
        self.sample_text = entry.get_text() or DEFAULT_SAMPLE
        self.save_setting("sample", entry.get_text())
        self.redraw()

    def on_size(self, scale):
        self.sample_size = round(scale.get_value())
        self.size_label.set_label(f"{self.sample_size} px")
        self.save_setting("size", str(self.sample_size))
        self.redraw()

    def on_background(self, background: str):
        for widget in (self.library_list, self.system_list):
            widget.remove_css_class("ai-light")
            widget.remove_css_class("ai-dark")
            widget.add_css_class(f"ai-{background}")
        self.save_setting("background", background)

    def setting_size(self) -> int:
        try:
            return min(120, max(12, int(self.settings["size"])))
        except ValueError:
            return int(DEFAULT_SETTINGS["size"])

    @staticmethod
    def load_families() -> dict:
        try:
            with open(FAMILIES_FILE) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_families(self):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(FAMILIES_FILE, "w") as f:
                json.dump(self.remembered, f, indent=1)
        except OSError:
            pass

    @staticmethod
    def load_settings() -> dict:
        settings = dict(DEFAULT_SETTINGS)
        try:
            with open(SETTINGS_FILE) as f:
                for line in f:
                    key, sep, value = line.rstrip("\n").partition("=")
                    if sep and key in settings:
                        settings[key] = value
        except OSError:
            pass
        return settings

    def save_setting(self, key: str, value: str):
        if self.settings.get(key) == value:
            return
        self.settings[key] = value
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(SETTINGS_FILE, "w") as f:
                f.writelines(f"{k}={v.replace(chr(10), ' ')}\n" for k, v in self.settings.items())
        except OSError:
            pass


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        quit_action = Gio.SimpleAction(name="quit")
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)

    def do_startup(self):
        Adw.Application.do_startup(self)
        css = Gtk.CssProvider()
        css.load_from_string(CSS)
        display = Gdk.Display.get_default()
        Gtk.StyleContext.add_provider_for_display(display, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        # Icons not every theme has (image-adjust-contrast-symbolic).
        Gtk.IconTheme.get_for_display(display).add_search_path(os.path.join(ROOT, "share", "icons"))

    def do_activate(self):
        window = self.get_active_window() or Window(self)
        window.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv[:1]))
