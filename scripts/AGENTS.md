# Deployment, rollback and session units

## Preserve the uninstall baseline

- In [apply.sh](apply.sh), record managed destinations and move aside originals, including dangling symlinks,
  before linking or seeding. Respect XDG overrides and paths containing spaces.
- On reapply, carry forward the original backups and manifests; do not replace the uninstall baseline with managed files.
  Generate `rollback.sh` in the new backup **before** publishing the `last-backup` pointer by atomic rename.
- Roll back dotfiles only from the current backup with the session stopped. Restore the original link or file,
  not its resolved contents. Keep system rollback opt-in and never auto-remove packages.
- Seed the [shell config](../config/kaze-shell/config.toml) as an editable copy; preserve the managed copy on reapply.
  Seed the Hyprland `user.lua` only if neither a file nor a link exists. Never include it in the removal manifest.
- Keep [Foot's theme include](../config/foot/foot.ini) valid before the first shell template pass,
  including with a non-default XDG config directory. Do not write theme output through a link into the repo.

## Packages and activation

- Source [packages.sh](packages.sh) from both installers. Keep core dependencies in official Arch repos;
  install optional AUR helpers separately so their failure cannot block core deployment.
- Apply links an already-built release shell if present; it is not a Rust build step.
- Put session dependencies in [kaze-session.target](../config/systemd/user/kaze-session.target).
  Preserve `DefaultDependencies=no`: wanted services start **after** the target, not before it.
- Follow [kaze-shell.service](../config/systemd/user/kaze-shell.service) for session-bound services:
  `PartOf=` propagates stops; `Requisite=` rejects starts without the target; `After=` orders startup.
  Use `EnvironmentFile=` to read the environment prepared by the [session helper](../lua/kaze/session.lua).
- Linking a unit does not enable it. Keep [the recorder](../config/systemd/user/kaze-record.service) on demand, outside the target's startup wants.

## Verify from the repository root

Run the [Bash and ShellCheck gates](../AGENTS.md#local-verification) and compare both installers' plans without applying:

```sh
for p in minimal full; do
  scripts/install-packages.sh --profile "$p" --dry-run
  scripts/install.sh --profile "$p" --dry-run
done
```

Exercise apply → reapply → generated rollback in a disposable home with private XDG directories and no live user bus.
Check that stale rollback is refused, original symlinks are restored and the user override survives.
