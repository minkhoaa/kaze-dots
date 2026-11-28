# Rust shell

## Daemon and IPC

- Inherit the [workspace lints](Cargo.toml), including `deny(clippy::unwrap_used)`.
  Return errors at config and protocol boundaries; a bad reload must leave the active config in use.
- Register Wayland, socket readiness, timers and channels on the daemon's single
  [`calloop` loop](crates/kaze-cli/src/daemon.rs). Reuse the shared filesystem watcher and system-service channel.
- Keep the Hyprland event stream non-blocking. On EOF, remove the source and reconnect with backoff;
  take a fresh snapshot on reconnect rather than polling for workspace or monitor changes.
- Keep the [IPC listener](crates/kaze-ipc/src/lib.rs) non-blocking and frames size-limited.
  Bound synchronous reads/writes; defer the responder when waiting for user input, as `dmenu` does.
- Keep framing independent of command behavior. Test wire changes at both ends with a private socket.
- Have [extensions](crates/kaze-core/src/extension.rs) return surface specs and dirty flags and request actions;
  let the daemon execute actions and the UI own Wayland objects. Keep layout tests display-free.

## Rendering and lifetime

- Render in software into `wl_shm`; do not link GTK, Qt, EGL or wgpu into the shell.
- Keep a `SlotPool` per managed surface in the [UI backend](crates/kaze-ui/src/lib.rs).
  Keep layout and hit testing in logical coordinates; scale buffer dimensions and damage in pixels.
- Draw configured, dirty surfaces. Drive animation with frame callbacks and stop requesting frames at rest.
- On close or output removal, stop its frame clock, clear input references and drop the surface and pool.
  Check retained PSS after repeated popup or hotplug cycles, not just after the first draw.

## Headless checks

- From this directory, use `cargo fmt --all -- --check` and `cargo check --workspace --frozen`.
- Run the workspace tests and all-target Clippy commands in the [root gates](../AGENTS.md#local-verification);
  a passing leaf-crate test does not check consumers of shared state or protocol changes.
- `--frozen` requires the existing [lockfile](Cargo.lock) and cached dependencies. Use the
  [pinned toolchain](rust-toolchain.toml); do not regenerate the lockfile to get a lint run to pass.
