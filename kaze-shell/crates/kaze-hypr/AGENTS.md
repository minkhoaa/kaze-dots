# kaze-hypr

- `src/lib.rs` owns compositor socket access and translates snapshots and events into shell state. Keep bar layout out of this adapter.
- Test parsing with captured or synthetic messages rather than connecting to the host compositor.
