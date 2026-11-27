# kaze-cli

- `src/main.rs` handles command-line arguments, output and exit status.
- `src/daemon.rs` connects the event loop, configuration reload and extension actions. Keep socket framing and drawing in their owning crates.
- Test command-line behavior with a temporary configuration directory, not a live daemon.
