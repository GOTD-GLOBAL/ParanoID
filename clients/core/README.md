# Development client core

Library-backed Olm for one explicitly pinned peer. `command(state, request)`
returns a new candidate snapshot and a public/UI view. Persist the full snapshot
atomically before sending any encrypted outbox entry, including delivery receipts.
On error retain the previous snapshot; never adopt partial ratchet changes.
The raw snapshot contains private account/session state and plaintext history:
it is NOT an encrypted-at-rest format until the platform adapter protects it.

```sh
cargo test --locked --manifest-path clients/core/Cargo.toml
cargo clippy --locked --manifest-path clients/core/Cargo.toml --all-targets -- -D warnings
```

Three tests cover fresh identity/public export, pinned text/receipt exchange with
snapshot reload, and negative/retry behavior. They do not exercise actual devices,
platform storage or hosted TLS. This is disposable development identity, not the
proposed seed/root/device hierarchy. See the Android README for current blockers.
