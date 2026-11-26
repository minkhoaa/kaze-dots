# Deployment and VM scripts

## Scope
Maintain the shared [package manifest](packages.sh), [package installer](install-packages.sh), [profile installer](install.sh), [symlink and rollback installer](apply.sh), [VM launcher](launch-vm.sh) and [verification harness](../tests/vm-verify.sh).

## Local rules
- Use Bash strict mode (`set -euo pipefail`) and quote paths. Respect `XDG_CONFIG_HOME` and `XDG_DATA_HOME` when deploying.
- Back up replaced files and symlinks before applying. Record installed paths and generate a reversible `rollback.sh`.
- Seed `~/.config/noctalia/config.toml` as an editable file on first apply and preserve user Noctalia Settings GUI edits on reapply.
- Seed `~/.config/hypr/user.lua` only when absent; preserve it across apply and rollback.
- Check `pgrep -x qemu-system-x86` (filtered to `shell-bench-vm` / `vm.pid` so unrelated QEMU instances like Android Emulator are untouched) before starting a test VM. Stop if a test VM is already running.

## Verify
Run `scripts/install-packages.sh --dry-run` and `scripts/install.sh --dry-run` to inspect package changes without installing. For deployment changes, test apply, reapply, and rollback in the guest; verify that pre-existing files, Noctalia GUI edits, and `hypr/user.lua` survive.
