---
status: accepted
owner: maintainers
last_reviewed: 2026-08-11
---

# Run the Rust identity checks

## Prerequisites

Install Rust through `rustup` and satisfy the platform prerequisites documented
by the Rust project. The repository pins Rust `1.97.1` plus `rustfmt` and
`clippy` in `rust-toolchain.toml`; do not silently test with another toolchain.

## Verify the workspace

Run from the repository root:

```shell
cargo fmt --all -- --check
cargo test --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
```

The test suite checks that the generated public identity fixture matches
`specs/protocol/identity/key-derivation-experiment-v1.json` exactly.

## Inspect the public experiment vector

```shell
cargo run -p paranoid-identity-core --example generate_vectors --locked
```

The example uses a fixed public mnemonic and emits public keys only. Never adapt
it to print a private key, BIP-39 seed, or mnemonic generated for a real account.
If the output changes, treat it as a protocol-research change: explain why,
update the experiment document and fixture together, and obtain security review.
