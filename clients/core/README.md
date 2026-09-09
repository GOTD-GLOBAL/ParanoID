# Development client core

The issue #16 candidate now uses an explicit schema3 clean-install first-contact
adapter. Previous version0/v1/v2 source and tests remain historical compatibility
evidence, with actual failures reported separately. [Client contract and historical
migration evidence](../../docs/clients/core/self-service.md) explain the single
shared Olm Account, unchanged signed contact/root/device credentials and the
owner's explicit clean-state compatibility boundary.

The current clean-install candidate adds explicit core schema **3** with mandatory
signed account-ID intro-v2 and strict PlainV1 text/receipts. A receiver with zero
contacts gets immediate plaintext/reply as `network_unverified`. One shared Olm
Account, immutable pins, full-state rejection rollback and exact durable frame2
outbox are required. [The new protocol](../../docs/protocol/first-contact-v1.md)
controls this clean path; the earlier compatibility record remains historical.
Unsupported old snapshots fail unchanged; no migration/reset is performed.

Clean acceptance and historical compatibility are run/reported separately:

```sh
cargo test --offline --locked --manifest-path clients/core/Cargo.toml --lib --test clean_first_contact
cargo test --offline --locked --manifest-path clients/core/Cargo.toml --test self_service --no-fail-fast
```

The second command retains existing historical regressions; its failures are not
fixed or suppressed by selecting the owner's fresh-install release scope.

`command(state, request)` returns a candidate snapshot and public/UI view. Persist
that complete snapshot atomically **before** sending ciphertext or receipts.
Errors return no adopted candidate. Raw core snapshots contain private keys and
plaintext history: only the platform's sealed atomic storage protects them at rest.
Never log returned `state` or use public test wrapping keys for real storage.

```sh
cargo test --locked --manifest-path clients/core/Cargo.toml
cargo clippy --locked --manifest-path clients/core/Cargo.toml --all-targets -- -D warnings
```

The shared `key-protocol` v2 library belongs to the separate server PR dependency.
The client owns contact extension/local state, not a competing server wire contract.
Rust and real JVM/JNI tests are evidence, not physical Android or production
security acceptance. Reusable fallback bootstrap has weaker initial forward
secrecy than independently consumed one-time keys; review/owner disposition remain
required. No recovery, multi-device or iOS implementation is claimed.
