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

Tests cover fresh identity/public export, pinned text/receipt exchange, exact
retries, simultaneous initial sends, bad-event recovery, full-history receipt
processing and bounded rejection notices. A classified payload rejection now
returns a candidate snapshot with transport progress and a notice, NOT successful
plaintext acceptance. The original account/session/history/outbox is restored
before that notice; committing the candidate emits no receipt for the rejected
event. Local-state and untrustworthy transport-header failures remain errors.

The platform must persist notice/cursor changes atomically like every other
candidate. Old v0 snapshots receive empty additive notice fields without replacing
keys. These tests do not exercise actual devices, platform storage or hosted TLS.
This remains disposable development identity, not the seed/root/device hierarchy.
See the Android README for resource limits and remaining runtime gates.
