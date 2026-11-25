# Deployment and VM scripts

## Scope
Maintain the [package installer](install-packages.sh), [symlink and rollback installer](apply.sh), [VM launcher](launch-vm.sh) and [verification harness](../tests/vm-verify.sh).

## Local rules
- Use Bash strict mode (`set -euo pipefail`) and quote paths. Respect `XDG_CONFIG_HOME` and `XDG_DATA_HOME` when deploying.
- Back up replaced files and symlinks before applying. Record installed paths and generate a reversible `rollback.sh`.
- Seed `kaze/user.lua` only when absent; preserve it across apply and rollback.
- Check `pgrep -x qemu-system-x86` before starting a test VM. Stop if a VM is already running.

## Verify
Run `scripts/install-packages.sh --dry-run` to inspect package changes without installing. For deployment changes, test apply and rollback in the guest; verify that pre-existing files and `user.lua` survive.
