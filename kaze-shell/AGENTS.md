# kaze-shell workspace

`Cargo.toml` defines the workspace; `Cargo.lock` records its dependency resolution. Source lives under `crates/`. Read the [repository rules](../AGENTS.md), then the guide for the folder you are changing.

| Folder | Start here for |
| --- | --- |
| [kaze-cli](crates/kaze-cli/AGENTS.md) | Command-line entry points and daemon orchestration |
| [kaze-core](crates/kaze-core/AGENTS.md) | Shared state, configuration and extension contracts |
| [kaze-ext-bar](crates/kaze-ext-bar/AGENTS.md) | Bar layout and interactions |
| [kaze-hypr](crates/kaze-hypr/AGENTS.md) | Compositor commands and events |
| [kaze-ipc](crates/kaze-ipc/AGENTS.md) | Communication between local clients and the daemon |
| [kaze-ui](crates/kaze-ui/AGENTS.md) | Window surfaces, input and drawing |

## Basic commands

From a crate folder: `cargo check --frozen` and `cargo test --frozen` check that crate. From the workspace root:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --frozen -- -D warnings
cargo test --workspace --frozen
```

`--frozen` uses the existing lockfile and local dependency cache. These checks do not require a running desktop; test live behavior only in the isolated guest.
