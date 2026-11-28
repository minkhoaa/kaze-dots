# kaze-dots

kaze-dots deploys Arch Linux / CachyOS dotfiles for Hyprland. Its desktop shell is `kaze-shell`, a native Rust Wayland client.
The [session target](config/systemd/user/kaze-session.target) starts [kaze-shell.service](config/systemd/user/kaze-shell.service) to run `kaze-shell daemon`; do not start a second shell from compositor config.

## Global invariants

- Keep the idle desktop event-driven: no polling, new resident helpers or telemetry. Extend the shell instead of starting another daemon.
- Do not add Qt/QML, GTK, Electron, wgpu, Node or Python dependencies to implement shell features.
- Require zero early portals. Check passively; a client request can start the very service being measured.
- Enforce shell and shell+session PSS, idle CPU and context-switch limits from the [T0 sampler](tests/vm/idle_sampler.py).
  Use a cold 1920×1080 guest; neither RSS nor a post-interaction sample proves the idle budget.
- Never modify, reload, restart or kill the live host compositor or shell. Never use `pkill -f`.
- No host `sudo`, package changes or writes to `/etc` or `/usr`. Never apply to host dotfiles without an explicit request.
- Preserve user overrides on apply, reapply and rollback. Keep generated theme and display state separate from repository files.

## Read by scope

Read the matching guide before editing; follow a second route only if the change crosses that boundary.

| Directory | Guide | When |
| --- | --- | --- |
| `kaze-shell/`, `config/kaze-shell/` | [Rust shell](kaze-shell/AGENTS.md) | Daemon, IPC, rendering or shell config contracts |
| `hypr/`, `templates/` | [Hyprland](hypr/AGENTS.md) | Compositor hooks, reload order, overrides or layer rules |
| `lua/`, `bin/` | [Lua and CLIs](lua/AGENTS.md) | Display planning, pickers or session lifecycle |
| `scripts/`, `config/` | [Deployment](scripts/AGENTS.md) | Installed files, packages, backups or user units |
| `tests/`, `scripts/launch-vm.sh` | [Verification](tests/AGENTS.md) | Fixtures, guest isolation or resource measurements |

## Local verification

Run Gate 1 from the repository root before a commit or VM deployment. Parse one file per invocation:

```sh
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/kaze-*' \) -print0 | xargs -0 -r -n1 luac -p
lua tests/run.lua
python3 -B -m unittest tests/vm/test_idle_sampler.py
find scripts tests/vm -type f -name '*.sh' -print0 | xargs -0 -r -n1 bash -n
shellcheck --severity=error scripts/*.sh tests/vm/verify.sh tests/vm/common.sh
```

On pull requests and pushes to `main`, [`static-and-unit`](.github/workflows/ci.yml) runs Lua syntax and tests,
sampler unit tests, Bash checks, ShellCheck and installer dry-runs for both profiles. ShellCheck warnings are advisory; errors are not.

For Rust changes, run the workspace gates locally; neither Rust nor VM tests run in CI:

```sh
(cd kaze-shell && cargo test --workspace --frozen)
(cd kaze-shell && cargo clippy --workspace --all-targets --frozen -- -D warnings)
```

For runtime, UI or resource changes, run `tests/vm/verify-kaze-shell.sh` from the repository root.
Use only the disposable Arch KVM overlay described in the [verification guide](tests/AGENTS.md).
Report the checks run, any failures and any unmeasured budgets separately.

## Maintaining the guides

When a contract or check changes, update the relevant scoped guide and verify its pointers against the implementation.
Keep this hub limited to shared rules, verification entry points and routing; link to manifests and tests instead of copying their contents.
