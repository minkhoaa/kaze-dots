# kaze-core

- `src/config.rs` owns settings and validation; `src/theme.rs` reads palettes and writes theme files. Use a private temporary directory for file tests.
- `src/state.rs`, `src/extension.rs` and `src/surface.rs` define the data shared across crates. Keep compositor and drawing details out of these contracts.
- Check consuming crates after changing a shared contract.
