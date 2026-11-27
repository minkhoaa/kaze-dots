# kaze-ext-bar

- `src/lib.rs` turns shell state into bar layout and translates clicks into requested actions. The daemon executes those actions; the UI draws the result.
- Keep layout and interaction tests beside the implementation so they can run without a display.
