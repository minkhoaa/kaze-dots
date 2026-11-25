#!/usr/bin/env bash
# Sourced by the host VM harness; QMP only injects into the private guest socket.
wait_clients() {
    local pattern=$1 clients
    for _ in {1..25}; do
        clients=$(in_session hyprctl clients) || return
        if grep -Ei "$pattern" <<< "$clients"; then return 0; fi
        sleep .2
    done
    printf 'Guest window not found: %s\n%s\n' "$pattern" "$clients" >&2
    return 1
}

exercise_portals() {
    local dir=$1 client
    in_session busctl --user --timeout=10s call org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop \
        org.freedesktop.portal.Settings ReadOne ss org.freedesktop.appearance color-scheme | tee "$dir/settings.log"
    in_session timeout 25s '~/kaze-dots/tests/portal-probe' file </dev/null >"$dir/file-chooser.log" 2>&1 & client=$!
    wait_clients 'title: Kaze QA File Picker'
    in_session hyprctl clients | grep 'class: xdg-desktop-portal-gtk'
    qmp key esc
    wait "$client" || { tail -n 20 "$dir/file-chooser.log" >&2; return 1; }
    grep -E '^OpenFile response=[12]$' "$dir/file-chooser.log"
    if in_session hyprctl clients | grep -Fq 'title: Kaze QA File Picker'; then return 1; fi

    in_session timeout 38s '~/kaze-dots/tests/portal-probe' cast </dev/null >"$dir/screencast.log" 2>&1 & client=$!
    wait_clients 'class:.*(sharing|picker|xdg-desktop-portal-hyprland)'
    sleep .3 # wait for the picker animation before clicking its monitor row and Share
    in_session grim - > "$dir/share-picker.png"
    qmp click 720 291
    qmp click 1584 909
    wait "$client" || { tail -n 20 "$dir/screencast.log" >&2; return 1; }
    grep -Fx 'Portal session closed; five 1920x1080 frames: PASS' "$dir/screencast.log"
}
