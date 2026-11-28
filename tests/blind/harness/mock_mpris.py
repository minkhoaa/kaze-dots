#!/usr/bin/env python3
"""Independent mock MPRIS2 D-Bus player for kaze-shell blind tests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib


class MockMprisPlayer(dbus.service.Object):
    def __init__(self, bus, args):
        super().__init__(bus, "/org/mpris/MediaPlayer2")
        self._bus = bus
        self._log_path = Path(args.log) if args.log else None
        self.props = {
            "org.mpris.MediaPlayer2": {
                "CanQuit": dbus.Boolean(False),
                "CanRaise": dbus.Boolean(False),
                "HasTrackList": dbus.Boolean(False),
                "Identity": dbus.String("Kaze Blind Test Player"),
                "DesktopEntry": dbus.String("kaze-blind-test"),
            },
            "org.mpris.MediaPlayer2.Player": {
                "PlaybackStatus": dbus.String(args.status),
                "LoopStatus": dbus.String("None"),
                "Rate": dbus.Double(1.0),
                "Shuffle": dbus.Boolean(False),
                "Metadata": dbus.Dictionary(
                    {
                        "mpris:trackid": dbus.ObjectPath("/org/kaze/blind/track/1"),
                        "mpris:length": dbus.Int64(args.length_us),
                        "xesam:title": dbus.String(args.title),
                        "xesam:artist": dbus.Array([dbus.String(args.artist)], signature="s"),
                    },
                    signature="sv",
                ),
                "Volume": dbus.Double(1.0),
                "Position": dbus.Int64(args.position_us),
                "MinimumRate": dbus.Double(1.0),
                "MaximumRate": dbus.Double(1.0),
                "CanGoNext": dbus.Boolean(True),
                "CanGoPrevious": dbus.Boolean(True),
                "CanPlay": dbus.Boolean(True),
                "CanPause": dbus.Boolean(True),
                "CanSeek": dbus.Boolean(False),
                "CanControl": dbus.Boolean(True),
            },
        }

    def _record(self, method: str, *args) -> None:
        if self._log_path is None:
            return
        entry = {"ts": time.monotonic(), "method": method, "args": [str(a) for a in args]}
        with self._log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")

    @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
    def PropertiesChanged(self, interface_name, changed_properties, invalidated_properties):
        pass

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        self._record("Get", iface, prop)
        if iface not in self.props or prop not in self.props[iface]:
            raise dbus.exceptions.DBusException(
                f"Unknown property {iface}.{prop}",
                name="org.freedesktop.DBus.Error.InvalidArgs",
            )
        return self.props[iface][prop]

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        self._record("GetAll", iface)
        return self.props.get(iface, {})

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv", out_signature="")
    def Set(self, iface, prop, value):
        self._record("Set", iface, prop, value)

    def _toggle_status(self):
        cur = str(self.props["org.mpris.MediaPlayer2.Player"]["PlaybackStatus"])
        nxt = "Paused" if cur == "Playing" else "Playing"
        self.props["org.mpris.MediaPlayer2.Player"]["PlaybackStatus"] = dbus.String(nxt)
        self.PropertiesChanged(
            "org.mpris.MediaPlayer2.Player",
            dbus.Dictionary({"PlaybackStatus": dbus.String(nxt)}, signature="sv"),
            dbus.Array([], signature="s"),
        )
        return nxt

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def PlayPause(self):
        nxt = self._toggle_status()
        self._record("PlayPause", nxt)

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def Play(self):
        self.props["org.mpris.MediaPlayer2.Player"]["PlaybackStatus"] = dbus.String("Playing")
        self._record("Play")

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def Pause(self):
        self.props["org.mpris.MediaPlayer2.Player"]["PlaybackStatus"] = dbus.String("Paused")
        self._record("Pause")

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def Next(self):
        self._record("Next")

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def Previous(self):
        self._record("Previous")

    @dbus.service.method("org.mpris.MediaPlayer2.Player", in_signature="", out_signature="")
    def Stop(self):
        self.props["org.mpris.MediaPlayer2.Player"]["PlaybackStatus"] = dbus.String("Stopped")
        self._record("Stop")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus-name", default="org.mpris.MediaPlayer2.kaze_blind_test")
    ap.add_argument("--title", default="Blind Test Track")
    ap.add_argument("--artist", default="Blind Artist")
    ap.add_argument("--status", default="Playing")
    ap.add_argument("--length-us", type=int, default=240_000_000)
    ap.add_argument("--position-us", type=int, default=42_000_000)
    ap.add_argument("--log", default="")
    ap.add_argument("--ready", default="")
    args = ap.parse_args()

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    _bus_name = dbus.service.BusName(args.bus_name, bus)
    player = MockMprisPlayer(bus, args)

    def on_sigusr1():
        player._toggle_status()
        return True

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, on_sigusr1)
    if args.ready:
        Path(args.ready).write_text("ready\n", encoding="utf-8")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
