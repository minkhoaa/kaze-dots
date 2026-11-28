#!/usr/bin/env python3
"""Suite D: Notification daemon (org.freedesktop.Notifications), Unicode/tofu, DND matrix, storm."""

from __future__ import annotations

from pathlib import Path
import subprocess
import threading
import time

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

from runner import BlindContext, TestFailure


def _notif_iface():
    bus = dbus.SessionBus()
    proxy = bus.get_object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
    return bus, dbus.Interface(proxy, "org.freedesktop.Notifications")


def _notify_dbus(
    iface,
    summary: str,
    body: str,
    *,
    replaces_id: int = 0,
    actions: list[str] | None = None,
    urgency: int = 1,
    timeout_ms: int = 8000,
) -> int:
    hints = dbus.Dictionary({"urgency": dbus.Byte(urgency)}, signature="sv")
    acts = dbus.Array(actions or [], signature="s")
    nid = iface.Notify(
        "kaze-blind-test",
        dbus.UInt32(replaces_id),
        "",
        summary,
        body,
        acts,
        hints,
        dbus.Int32(timeout_ms),
    )
    return int(nid)


def _run_signal_listener(events: list[tuple], stop_flag: threading.Event) -> threading.Thread:
    def worker():
        ml = dbus.mainloop.glib.DBusGMainLoop()
        bus = dbus.SessionBus(mainloop=ml, private=True)
        loop = GLib.MainLoop()

        def on_closed(nid, reason):
            events.append(("NotificationClosed", int(nid), int(reason)))

        def on_action(nid, key):
            events.append(("ActionInvoked", int(nid), str(key)))

        bus.add_signal_receiver(
            on_closed,
            signal_name="NotificationClosed",
            dbus_interface="org.freedesktop.Notifications",
        )
        bus.add_signal_receiver(
            on_action,
            signal_name="ActionInvoked",
            dbus_interface="org.freedesktop.Notifications",
        )

        def check_stop():
            if stop_flag.is_set():
                loop.quit()
                return False
            return True

        GLib.timeout_add(50, check_stop)
        loop.run()

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    time.sleep(0.15)
    return t


def test_d01_dbus_spec_compliance(ctx: BlindContext) -> None:
    shell_pid = ctx.proc.get_shell_pid()
    owner_pid = ctx.proc.bus_owner_pid("org.freedesktop.Notifications")
    ctx.require(
        owner_pid == shell_pid,
        f"org.freedesktop.Notifications owned by PID {owner_pid}, expected kaze-shell PID {shell_pid}",
    )

    _, iface = _notif_iface()
    srv = iface.GetServerInformation()
    ctx.require(len(srv) == 4 and all(str(x) for x in srv), f"invalid GetServerInformation response: {srv}")
    caps = [str(c) for c in iface.GetCapabilities()]
    ctx.require("body" in caps and "actions" in caps, f"incomplete GetCapabilities: {caps}")

    events: list[tuple] = []
    stop = threading.Event()
    thr = _run_signal_listener(events, stop)
    try:
        nid = _notify_dbus(iface, "D01 Spec", ctx.nonce("d01"), timeout_ms=10000)
        ctx.require(nid > 0, f"Notify returned invalid id {nid}")
        ctx.require(
            ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0) is not None,
            "kaze-notify layer did not appear after Notify",
        )
        iface.CloseNotification(dbus.UInt32(nid))
        ctx.require(
            ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0) is True,
            "kaze-notify did not close after CloseNotification",
        )
        time.sleep(0.2)
        closed = [e for e in events if e[0] == "NotificationClosed" and e[1] == nid]
        ctx.require(
            any(e[2] == 3 for e in closed),
            f"expected NotificationClosed({nid}, 3), got {closed}",
        )
    finally:
        stop.set()
        thr.join(timeout=2)
        ctx.proc.kaze_msg("notify-clear")


def test_d02_vietnamese_cjk_emoji_anti_tofu(ctx: BlindContext) -> None:
    _, iface = _notif_iface()
    nonce_vn = ctx.nonce("vn")
    vn_title = "Tiếng Việt 🎉"
    vn_body = f"Tiếng Việt: Ă Â Đ Ê Ô Ơ Ư — ệ ử ỡ ũ {nonce_vn}"
    cjk_body = f"日本語テスト 🔥🚀✅ {nonce_vn}"
    tofu_title = "\ufffd" * len(vn_title)
    tofu_body_vn = "\ufffd" * len(vn_body)
    tofu_body_cjk = "\ufffd" * len(cjk_body)

    try:
        # Capture tofu baseline first
        id_tofu = _notify_dbus(iface, tofu_title, tofu_body_vn, timeout_ms=15000)
        layer_tofu = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(layer_tofu is not None, "kaze-notify missing for tofu baseline")
        time.sleep(0.25)
        reg = (layer_tofu["x"], layer_tofu["y"], layer_tofu["w"], layer_tofu["h"])
        ctx.require(
            reg[0] >= 0 and reg[1] >= 0 and reg[0] + reg[2] <= 1920 and reg[1] + reg[3] <= 1080,
            f"kaze-notify bounds {reg} out of 1920x1080 screen",
        )
        img_tofu_vn = ctx.vis.capture_ppm(region=reg)
        iface.CloseNotification(dbus.UInt32(id_tofu))
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)

        # Capture Vietnamese + Emoji
        id_vn = _notify_dbus(iface, vn_title, vn_body, timeout_ms=15000)
        layer_vn = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(layer_vn is not None, "kaze-notify missing for Vietnamese notification")
        time.sleep(0.25)
        reg_vn = (layer_vn["x"], layer_vn["y"], layer_vn["w"], layer_vn["h"])
        img_vn = ctx.vis.capture_ppm(region=reg_vn)
        ctx.save_artifact("notify-vietnamese-emoji.png", output="Virtual-1")
        ctx.require(ctx.vis.pixel_variance(img_vn) > 10.0, "notification rendered blank/flat pixels")

        if (img_vn.width, img_vn.height) == (img_tofu_vn.width, img_tofu_vn.height):
            d_vn = ctx.vis.diff_stats(img_vn, img_tofu_vn, threshold=14)
            ctx.require(
                d_vn["changed_ratio"] > 0.015,
                f"Vietnamese/Emoji render too close to U+FFFD tofu control (changed_ratio={d_vn['changed_ratio']:.4f})",
            )
        iface.CloseNotification(dbus.UInt32(id_vn))
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)

        # Capture CJK + Emoji vs tofu
        id_tofu2 = _notify_dbus(iface, tofu_title, tofu_body_cjk, timeout_ms=15000)
        l_t2 = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        time.sleep(0.25)
        img_t2 = ctx.vis.capture_ppm(region=(l_t2["x"], l_t2["y"], l_t2["w"], l_t2["h"]))
        iface.CloseNotification(dbus.UInt32(id_tofu2))
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)

        id_cjk = _notify_dbus(iface, "CJK Test 🚀", cjk_body, timeout_ms=15000)
        l_cjk = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(l_cjk is not None, "kaze-notify missing for CJK notification")
        time.sleep(0.25)
        img_cjk = ctx.vis.capture_ppm(region=(l_cjk["x"], l_cjk["y"], l_cjk["w"], l_cjk["h"]))
        ctx.require(ctx.vis.pixel_variance(img_cjk) > 10.0, "CJK notification rendered blank pixels")
        if (img_cjk.width, img_cjk.height) == (img_t2.width, img_t2.height):
            d_cjk = ctx.vis.diff_stats(img_cjk, img_t2, threshold=14)
            ctx.require(
                d_cjk["changed_ratio"] > 0.015,
                f"CJK/Emoji render too close to U+FFFD tofu control (changed_ratio={d_cjk['changed_ratio']:.4f})",
            )
    finally:
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)


def test_d03_replaces_id_in_place(ctx: BlindContext) -> None:
    _, iface = _notif_iface()
    try:
        nid = _notify_dbus(iface, "Progress", "Downloading 10%", timeout_ms=12000)
        l0 = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(l0 is not None, "kaze-notify did not appear")
        time.sleep(0.2)
        h0 = l0["h"]
        img0 = ctx.vis.capture_ppm(region=(l0["x"], l0["y"], l0["w"], l0["h"]))

        for pct in (20, 40, 60, 80, 100):
            nid2 = _notify_dbus(iface, "Progress", f"Downloading {pct}%", replaces_id=nid, timeout_ms=12000)
            ctx.require(nid2 == nid, f"replaces_id={nid} returned different id {nid2}")
            time.sleep(0.08)

        time.sleep(0.2)
        layers = ctx.proc.find_layers(namespace="kaze-notify")
        ctx.require(len(layers) == 1, f"expected 1 kaze-notify layer, got {len(layers)}")
        l1 = layers[0]
        ctx.require(
            l1["h"] <= h0 * 1.4 + 8,
            f"replaces_id stacked cards instead of replacing in-place: h {h0} -> {l1['h']}",
        )
        img1 = ctx.vis.capture_ppm(region=(l1["x"], l1["y"], min(l0["w"], l1["w"]), min(h0, l1["h"])))
        img0_crop = ctx.vis.capture_ppm(region=(l0["x"], l0["y"], min(l0["w"], l1["w"]), min(h0, l1["h"]))) if (l0["w"], h0) != (l1["w"], l1["h"]) else img0
        if (img0_crop.width, img0_crop.height) == (img1.width, img1.height):
            ctx.require(
                ctx.vis.diff_stats(img0_crop, img1, threshold=12)["changed_count"] > 5,
                "in-place replaces_id update did not alter notification pixels",
            )
    finally:
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)


def test_d04_urgency_dnd_matrix(ctx: BlindContext) -> None:
    _, iface = _notif_iface()
    try:
        # Capture normal border/look first for comparison
        _notify_dbus(iface, "Normal Ref", ctx.nonce("norm"), urgency=1, timeout_ms=8000)
        ln = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(ln is not None, "normal notification missing")
        time.sleep(0.2)
        img_norm = ctx.vis.capture_ppm(region=(ln["x"], ln["y"], ln["w"], min(ln["h"], 90)))
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)

        # Enable DND: low and normal must NOT pop up
        ctx.proc.kaze_msg("dnd-on")
        time.sleep(0.15)
        _notify_dbus(iface, "Suppressed Low", ctx.nonce("low"), urgency=0, timeout_ms=5000)
        _notify_dbus(iface, "Suppressed Norm", ctx.nonce("norm2"), urgency=1, timeout_ms=5000)
        time.sleep(0.4)
        ctx.require(
            not ctx.proc.find_layers(namespace="kaze-notify"),
            "low/normal notification popped up while DND was on",
        )

        # Critical with default timeout (-1) MUST bypass DND and NOT auto-expire after 8.5s
        _notify_dbus(iface, "Critical Alert", ctx.nonce("crit"), urgency=2, timeout_ms=-1)
        lc = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(lc is not None, "critical notification was suppressed by DND")
        time.sleep(0.2)
        img_crit = ctx.vis.capture_ppm(region=(lc["x"], lc["y"], lc["w"], min(lc["h"], 90)))
        if (img_crit.width, img_crit.height) == (img_norm.width, img_norm.height):
            # Check border edge pixels differ (top 3px row)
            top_norm = ctx.vis.mean_rgb(img_norm, (0, 0, img_norm.width - 1, 2))
            top_crit = ctx.vis.mean_rgb(img_crit, (0, 0, img_crit.width - 1, 2))
            ctx.require(
                sum(abs(a - b) for a, b in zip(top_norm, top_crit)) > 15.0,
                f"critical notification border indistinguishable from normal ({top_norm} vs {top_crit})",
            )

        time.sleep(8.5)
        ctx.require(
            bool(ctx.proc.find_layers(namespace="kaze-notify")),
            "critical notification auto-expired before user dismissed it",
        )
    finally:
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.kaze_msg("dnd-off")
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)


def test_d05_notification_storm(ctx: BlindContext) -> None:
    _, iface = _notif_iface()
    pid0 = ctx.proc.get_shell_pid()
    base_memfd = ctx.proc.snapshot(pid0)["memfd_count"]
    try:
        for i in range(50):
            _notify_dbus(iface, f"Storm #{i}", ctx.nonce("storm"), urgency=1, timeout_ms=2500)
            time.sleep(0.015)

        l_storm = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(l_storm is not None, "kaze-notify missing during notification storm")
        ctx.require(
            l_storm["h"] <= 720 and l_storm["y"] + l_storm["h"] <= 1080,
            f"unbounded notification stack height during storm: h={l_storm['h']} (expected capped <= 5 cards / <= 720px)",
        )
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed during 50-notification storm")
        rc, out, _ = ctx.proc.kaze_msg("ping", timeout=1.0)
        ctx.require(rc == 0 and out == "pong", "IPC unresponsive after notification storm")

        ctx.require(
            ctx.proc.wait_layer("kaze-notify", present=False, timeout=5.0) is True,
            "kaze-notify surface did not destroy after storm notifications expired",
        )
        time.sleep(0.2)
        end_memfd = ctx.proc.snapshot(pid0)["memfd_count"]
        ctx.require(
            end_memfd <= base_memfd + 1,
            f"memfd leaked after notification storm: {base_memfd} -> {end_memfd}",
        )
    finally:
        ctx.proc.kaze_msg("notify-clear")


def test_d06_action_and_mouse_clicks(ctx: BlindContext) -> None:
    _, iface = _notif_iface()
    events: list[tuple] = []
    stop = threading.Event()
    thr = _run_signal_listener(events, stop)
    try:
        # 1. Left-click on notification with default action -> ActionInvoked + close
        nid1 = _notify_dbus(
            iface,
            "Action Card",
            ctx.nonce("act"),
            actions=["default", "Open"],
            timeout_ms=15000,
        )
        l1 = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(l1 is not None, "action notification missing")
        time.sleep(0.25)
        ctx.inp.click(l1["x"] + l1["w"] // 2, l1["y"] + l1["h"] // 2, button="left")
        ctx.require(
            ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.5) is True,
            "left-click on action notification did not dismiss card",
        )
        time.sleep(0.2)
        act = [e for e in events if e[0] == "ActionInvoked" and e[1] == nid1]
        ctx.require(
            any(e[2] == "default" for e in act),
            f"expected ActionInvoked({nid1}, 'default') on left-click, got {events}",
        )

        # 2. Right-click -> dismiss immediately with NotificationClosed(id, 2)
        nid2 = _notify_dbus(iface, "Dismiss Card", ctx.nonce("rmb"), timeout_ms=15000)
        l2 = ctx.proc.wait_layer("kaze-notify", present=True, timeout=2.0)
        ctx.require(l2 is not None, "second notification missing")
        time.sleep(0.25)
        ctx.inp.right_click(l2["x"] + l2["w"] // 2, l2["y"] + l2["h"] // 2)
        ctx.require(
            ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.5) is True,
            "right-click did not dismiss notification",
        )
        time.sleep(0.2)
        closed = [e for e in events if e[0] == "NotificationClosed" and e[1] == nid2]
        ctx.require(
            any(e[2] == 2 for e in closed),
            f"expected NotificationClosed({nid2}, 2) on right-click, got {closed}",
        )
    finally:
        stop.set()
        thr.join(timeout=2)
        ctx.proc.kaze_msg("notify-clear")


def _set_drm_connector(ctx: BlindContext, name: str, state: str) -> None:
    paths = list(Path("/sys/class/drm").glob(f"card*-{name}/status"))
    ctx.require(bool(paths), f"DRM sysfs connector status file not found for {name}")
    subprocess.run(
        ["sudo", "-n", "/usr/bin/tee", str(paths[0])],
        input=f"{state}\n",
        text=True,
        check=True,
        capture_output=True,
        timeout=5,
    )
    subprocess.run(
        ["sudo", "-n", "/usr/bin/udevadm", "trigger", "--subsystem-match=drm", "--action=change"],
        check=True,
        capture_output=True,
        timeout=5,
    )


def test_d07_display_present_dnd_two_way_sync(ctx: BlindContext) -> None:
    _set_drm_connector(ctx, "Virtual-2", "on")
    try:
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            mons = [m["name"] for m in ctx.proc.hypr_json("monitors all")]
            if "Virtual-2" in mons:
                break
            time.sleep(0.1)
        else:
            raise TestFailure("Virtual-2 did not appear in hyprctl monitors after DRM plug")

        # Dismiss hotplug menu if opened by Hyprland monitor.added hook
        time.sleep(0.4)
        if ctx.proc.find_layers(namespace="kaze-launcher"):
            ctx.proc.kaze_msg("launcher-close")
            ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

        # Case (a): DND initially off -> present -> on -> stop-present -> off
        ctx.proc.kaze_msg("dnd-off")
        subprocess.run(["kaze-display", "present", "8"], check=True, capture_output=True, text=True, timeout=8)
        _, st1, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(st1 == "on", f"DND did not turn on during present (got {st1!r})")
        subprocess.run(["kaze-display", "stop-present"], check=True, capture_output=True, text=True, timeout=8)
        _, st2, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(st2 == "off", f"DND did not restore to off after stop-present (got {st2!r})")

        # Case (b): DND already on -> present -> on -> stop-present -> STILL on
        ctx.proc.kaze_msg("dnd-on")
        subprocess.run(["kaze-display", "present", "8"], check=True, capture_output=True, text=True, timeout=8)
        _, st3, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(st3 == "on", f"DND turned off during present when pre-enabled (got {st3!r})")
        subprocess.run(["kaze-display", "stop-present"], check=True, capture_output=True, text=True, timeout=8)
        _, st4, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(st4 == "on", f"stop-present cleared pre-existing user DND (got {st4!r}, expected 'on')")
    finally:
        subprocess.run(["kaze-display", "cleanup"], capture_output=True, timeout=8)
        ctx.proc.kaze_msg("dnd-off")
        _set_drm_connector(ctx, "Virtual-2", "off")
        time.sleep(0.4)
        ctx.proc.kaze_msg("launcher-close")


TESTS = {
    "D01": test_d01_dbus_spec_compliance,
    "D02": test_d02_vietnamese_cjk_emoji_anti_tofu,
    "D03": test_d03_replaces_id_in_place,
    "D04": test_d04_urgency_dnd_matrix,
    "D05": test_d05_notification_storm,
    "D06": test_d06_action_and_mouse_clicks,
    "D07": test_d07_display_present_dnd_two_way_sync,
}
