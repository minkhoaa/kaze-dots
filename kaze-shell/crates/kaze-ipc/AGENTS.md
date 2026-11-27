# kaze-ipc

- `src/lib.rs` owns local sockets, message framing and request/response encoding. Command behavior belongs in the daemon.
- When changing the wire format, check both endpoints. Exercise round trips with a private test socket.
