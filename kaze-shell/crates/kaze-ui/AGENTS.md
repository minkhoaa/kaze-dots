# kaze-ui

- `src/lib.rs` manages outputs, surface lifetimes and pointer input. `src/render.rs` turns drawing instructions into pixels.
- Keep logical layout coordinates separate from buffer pixels. Check scaling, input alignment and surface cleanup in the isolated guest.
