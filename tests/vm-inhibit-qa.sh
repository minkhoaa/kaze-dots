#!/usr/bin/env bash
# Guest-only actual hypridle seat timer regression test, with compressed timeouts.
set -euo pipefail
qa=$(mktemp -d "$XDG_RUNTIME_DIR/kaze-inhibit-qa.XXXXXXXX")
units="$XDG_RUNTIME_DIR/systemd/user"
idle_drop="$units/kaze-hypridle.service.d/99-stage2-qa.conf"
inhibit_drop="$units/kaze-inhibit.service.d/99-stage2-qa.conf"
cleanup() {
    systemctl --user stop kaze-inhibit.service || true
    rm -f -- "$idle_drop" "$inhibit_drop"
    systemctl --user daemon-reload
    systemctl --user restart kaze-hypridle.service
    rm -rf -- "$qa"
}
trap cleanup EXIT
mkdir -p -- "$(dirname -- "$idle_drop")" "$(dirname -- "$inhibit_drop")"
awk '/^listener/ { exit } { print }' "$HOME/kaze-dots/templates/hypridle.conf" > "$qa/hypridle.conf"
printf 'listener {\n    timeout = 2\n    on-timeout = touch %s/fired\n}\n' "$qa" >> "$qa/hypridle.conf"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/hypridle --config %s/hypridle.conf\n' "$qa" > "$idle_drop"
systemctl --user daemon-reload
systemctl --user restart kaze-hypridle.service
sleep 3.5
test ! -e "$qa/fired"
invocation=$(systemctl --user show -p InvocationID --value kaze-hypridle.service)
logs() { journalctl --user --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation"; }
grep -F 'systemd idle inhibit active' <<< "$(logs)"
grep -F 'Ignoring from onIdled(), inhibit locks: 1' <<< "$(logs)"
kaze-inhibit off
for _ in {1..25}; do
    if [ -e "$qa/fired" ]; then break; fi
    sleep .2
done
test -e "$qa/fired"
grep -F 'systemd idle inhibit inactive' <<< "$(logs)"
if grep -Eq '^Kaze[[:space:]]' <<< "$(systemd-inhibit --list --no-pager)"; then exit 1; fi
echo '    Actual idle callback suppressed while inhibited and resumed after release'

printf '[Service]\nRuntimeMaxSec=3s\n' > "$inhibit_drop"
systemctl --user daemon-reload
kaze-inhibit on
sleep .6
grep -E '^Kaze[[:space:]]' <<< "$(systemd-inhibit --list --no-pager)"
sleep 3
result=$(systemctl --user show -p Result --value kaze-inhibit.service)
test "$result" = timeout
test "$(kaze-inhibit status)" = off
if grep -Eq '^Kaze[[:space:]]' <<< "$(systemd-inhibit --list --no-pager)"; then exit 1; fi
echo '    RuntimeMaxSec expired; no Kaze logind inhibitor survived'
