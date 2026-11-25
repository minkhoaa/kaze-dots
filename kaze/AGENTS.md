# Lua compiler and CLI

## Scope
Keep config resolution, state and emitters in [lua/kaze/](../lua/kaze/) and executable entry points in [bin/](../bin/). Follow the [pipeline](../docs/specs/01-architecture.md) and [CLI contract](../docs/specs/04-cli-and-keybinds.md).

## Local rules
- Use `snake_case` for Lua modules and keys; use `kebab-case` for executable names.
- Keep emitters pure: return config contents from the resolved config, theme and layout. Perform no I/O or process calls in emitters.
- Write generated files and persisted state atomically with `fs.write_atomic`. Quote shell arguments with `fs.shell_quote`.
- Reject invalid layouts, themes and missing CLI dependencies with a clear message on stderr and a non-zero exit status.

## Verify
Run `bin/kaze-sync --check` for a dry run of the active configuration. Expect `check ok` without file writes or daemon reloads.
