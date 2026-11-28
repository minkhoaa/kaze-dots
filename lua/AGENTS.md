# Lua helpers and CLI entry points

## Planning and side effects

- Use stock Lua and the standard library. Keep [CLI entry points](../bin/) usable both from the checkout
  and from an installed link or copy: resolve sibling modules, then fall back to the XDG data directory.
- Keep the [display planner](kaze/display.lua) free of I/O. Pass it snapshots and prior state;
  return a plan. Run compositor queries, locks, notifications and writes in [kaze-display](../bin/kaze-display).
- Release the menu lock before taking the display mutation lock. Waiting for input must not block disconnect recovery.
- Tie external-only auto-revert to the staged generation so an old timeout cannot undo a newer layout.
- Use [kaze.fs](kaze/fs.lua): `fs.private_runtime_dir` for session state, `fs.write_atomic` for replacement,
  `fs.shell_quote` for shell arguments. Quote values embedded in generated Lua as Lua strings instead.

## Shell and session integration

- Send picker entries through [`kaze.popups.run_dmenu`](kaze/popups.lua) to `kaze-shell dmenu` on stdin;
  never interpolate a label into a shell command. Resolve the selected label against the offered entries.
- Distinguish an empty selection from `nil, err`; for timed prompts check the timeout return as well.
  Cancellation must not apply the default action of a destructive menu.
- Publish display and recorder changes when they occur (e.g. `kaze-shell msg display-status idle`), not from a watcher.
  Restore bars on the recorded outputs; undo DND only if the display operation enabled it.
- Keep session ownership checks in [kaze.session](kaze/session.lua): a stale compositor must not stop
  another session's target or clear its activation environment. Lock via `kaze-shell msg lock` before the logind fallback.

## Verify

- Run the [per-file `luac -p` check](../AGENTS.md#local-verification) from the root; extensionless CLIs count too.
- Run `lua tests/run.lua` from the root. Test planner changes with supplied monitor/workspace data;
  stub the shell and compositor commands for CLI side effects.
- Assert stdout and exit status separately: several callers consume the selection or path, not a human-readable message.
