#!/usr/bin/env python3
"""A small dialog with one group of radio buttons.

    choose-gui.py TITLE TEXT CURRENT VALUE LABEL [VALUE LABEL...]

Prints the chosen VALUE and exits 0, or exits 1 when cancelled.
"""
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402


def main():
    if len(sys.argv) < 6 or (len(sys.argv) - 4) % 2:
        sys.exit(__doc__.strip())
    title, text, current = sys.argv[1:4]
    choices = list(zip(sys.argv[4::2], sys.argv[5::2]))
    result = {"value": None}

    def activate(app):
        win = Adw.ApplicationWindow(application=app, title=title, resizable=False)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                      margin_top=12, margin_bottom=18, margin_start=18, margin_end=18)
        box.append(Gtk.Label(label=text, xalign=0, wrap=True, max_width_chars=40))

        radios = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        group = None
        buttons = []
        for value, label in choices:
            button = Gtk.CheckButton(label=label, group=group, active=value == current)
            group = group or button
            buttons.append((value, button))
            radios.append(button)
        box.append(radios)

        def ok(*_):
            result["value"] = next(v for v, b in buttons if b.get_active())
            win.close()

        cancel_button = Gtk.Button(label="Cancel")
        cancel_button.connect("clicked", lambda *_: win.close())
        ok_button = Gtk.Button(label="OK", css_classes=["suggested-action"])
        ok_button.connect("clicked", ok)
        actions = Gtk.Box(spacing=12, halign=Gtk.Align.END, margin_top=6)
        actions.append(cancel_button)
        actions.append(ok_button)
        box.append(actions)

        header = Adw.HeaderBar(show_end_title_buttons=True)
        view = Adw.ToolbarView(content=box)
        view.add_top_bar(header)
        win.set_content(view)
        win.set_default_widget(ok_button)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda _c, key, *_: key == 0xFF1B and win.close())  # Escape
        win.add_controller(keys)
        win.present()

    app = Adw.Application(application_id="io.github.typedev.AffinityInfinity.Choose")
    app.connect("activate", activate)
    app.run([])
    if result["value"] is None:
        sys.exit(1)
    print(result["value"])


if __name__ == "__main__":
    main()
