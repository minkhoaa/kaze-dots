# Theme tokens

## Scope
Maintain built-in palettes and color helpers in [lua/kaze/themes.lua](../lua/kaze/themes.lua), the single source of palette values. Use the [token schema](../docs/specs/03-theming.md) for required keys.

## Local rules
- Keep presets declarative. Preserve existing names for persisted state; register new presets in `ORDER`.
- Store semantic colors as six hex digits without `#` or alpha. Omit `term` for derived ANSI colors or supply all 16 entries.
- Keep app-specific formatting in color helpers and emitters, not in palette values. Validate merged overrides without mutating the preset.

## Verify
Run `lua tests/run.lua`; require palette validation and all 3 layouts × 4 themes to pass. In the guest, switch with `kaze-theme <name>` and check the accent in Waybar's generated `colors.css`.
