#!/usr/bin/env python3
"""Independent mock StatusNotifierItem + com.canonical.dbusmenu service."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib


def _green_pixmap_argb() -> dbus.Array:
    w, h = 22, 22
    buf = bytearray()
    for _ in range(w * h):
        # Solid #19E619 in ARGB32 network byte order
        buf.extend((0xFF, 0x19, 0xE6, 0x19))
    return dbus.Array(
        [dbus.Struct((dbus.Int32(w), dbus.Int32(h), dbus.ByteArray(bytes(buf))), signature="iiay")],
        signature="(iiay)",
    )


def _corrupt_pixmap_argb() -> dbus.Array:
    return dbus.Array(
        [
            dbus.Struct((dbus.Int32(-16), dbus.Int32(-16), dbus.ByteArray(b"\x00\x01")), signature="iiay"),
            dbus.Struct((dbus.Int32(32), dbus.Int32(32), dbus.ByteArray(b"\xff\x00\x00")), signature="iiay"),
        ],
        signature="(iiay)",
    )


class MockTrayItem(dbus.service.Object):
    def __init__(self, bus, args, log_fn):
        super().__init__(bus, "/StatusNotifierItem")
        self._log = log_fn
        if args.profile == "pixmap_green":
            pixmap = _green_pixmap_argb()
            icon_name = ""
        elif args.profile == "icon_name":
            pixmap = dbus.Array([], signature="(iiay)")
            icon_name = "audio-volume-high"
        else:
            pixmap = _corrupt_pixmap_argb()
            icon_name = ""

        self.props = {
            "Id": dbus.String(args.id),
            "Category": dbus.String("ApplicationStatus"),
            "Title": dbus.String(args.title),
            "Status": dbus.String("Active"),
            "IconName": dbus.String(icon_name),
            "IconThemePath": dbus.String(""),
            "Menu": dbus.ObjectPath("/MenuBar"),
            "ItemIsMenu": dbus.Boolean(False),
            "IconPixmap": pixmap,
        }

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        self._log("SNI.Get", iface, prop)
        if prop not in self.props:
            raise dbus.exceptions.DBusException(
                f"Unknown property {prop}",
                name="org.freedesktop.DBus.Error.InvalidArgs",
            )
        return self.props[prop]

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        self._log("SNI.GetAll", iface)
        return self.props

    @dbus.service.method("org.kde.StatusNotifierItem", in_signature="ii", out_signature="")
    def Activate(self, x, y):
        self._log("Activate", int(x), int(y))

    @dbus.service.method("org.kde.StatusNotifierItem", in_signature="ii", out_signature="")
    def SecondaryActivate(self, x, y):
        self._log("SecondaryActivate", int(x), int(y))

    @dbus.service.method("org.kde.StatusNotifierItem", in_signature="ii", out_signature="")
    def ContextMenu(self, x, y):
        self._log("ContextMenu", int(x), int(y))

    @dbus.service.method("org.kde.StatusNotifierItem", in_signature="is", out_signature="")
    def Scroll(self, delta, orientation):
        self._log("Scroll", int(delta), str(orientation))


class MockDBusMenu(dbus.service.Object):
    def __init__(self, bus, menu_label: str, log_fn):
        super().__init__(bus, "/MenuBar")
        self._menu_label = menu_label
        self._log = log_fn

    def _items(self):
        def mk(mid, label, enabled=True, sep=False):
            d = dbus.Dictionary(
                {"visible": dbus.Boolean(True), "enabled": dbus.Boolean(enabled)},
                signature="sv",
            )
            if sep:
                d["type"] = dbus.String("separator")
            else:
                d["label"] = dbus.String(label)
            return dbus.Struct((dbus.Int32(mid), d, dbus.Array([], signature="v")), signature="ia{sv}av")

        return [
            mk(101, self._menu_label, enabled=True),
            mk(102, "", sep=True),
            mk(103, "Disabled Status Item", enabled=False),
        ]

    @dbus.service.method("com.canonical.dbusmenu", in_signature="iias", out_signature="u(ia{sv}av)")
    def GetLayout(self, parent_id, recursion_depth, property_names):
        self._log("GetLayout", int(parent_id), int(recursion_depth))
        root = dbus.Struct(
            (
                dbus.Int32(0),
                dbus.Dictionary({"children-display": dbus.String("submenu")}, signature="sv"),
                dbus.Array(self._items(), signature="v"),
            ),
            signature="ia{sv}av",
        )
        return dbus.UInt32(1), root

    @dbus.service.method("com.canonical.dbusmenu", in_signature="aias", out_signature="a(ia{sv})")
    def GetGroupProperties(self, ids, property_names):
        self._log("GetGroupProperties", [int(i) for i in ids])
        return dbus.Array([], signature="(ia{sv})")

    @dbus.service.method("com.canonical.dbusmenu", in_signature="i", out_signature="b")
    def AboutToShow(self, item_id):
        self._log("AboutToShow", int(item_id))
        return dbus.Boolean(False)

    @dbus.service.method("com.canonical.dbusmenu", in_signature="isvu", out_signature="")
    def Event(self, item_id, event_id, data, timestamp):
        self._log("Event", int(item_id), str(event_id), str(data), int(timestamp))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", choices=("pixmap_green", "icon_name", "corrupt_pixmap"), default="pixmap_green")
    ap.add_argument("--id", default="kaze-blind-tray")
    ap.add_argument("--title", default="Kaze Blind Tray")
    ap.add_argument("--menu-label", default="BlindAction")
    ap.add_argument("--bus-name", default="")
    ap.add_argument("--log", default="")
    ap.add_argument("--ready", default="")
    args = ap.parse_args()

    log_path = Path(args.log) if args.log else None

    def log_fn(method: str, *margs):
        if log_path is None:
            return
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.monotonic(), "method": method, "args": list(margs)}) + "\n")

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    bname = args.bus_name or f"org.kde.StatusNotifierItem-kaze-blind-{args.profile}"
    _owned = dbus.service.BusName(bname, bus)
    MockTrayItem(bus, args, log_fn)
    MockDBusMenu(bus, args.menu_label, log_fn)

    watcher = bus.get_object("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher")
    dbus.Interface(watcher, "org.kde.StatusNotifierWatcher").RegisterStatusNotifierItem("/StatusNotifierItem")
    if args.ready:
        Path(args.ready).write_text("ready\n", encoding="utf-8")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
