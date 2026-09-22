# Solana Devnet registration candidate

RFC-0026 / issue #52. This is a fresh-test-identity workstream, not a migration
of the installed messenger or an accepted Mainnet protocol.

## Components

- `registry/`: native Solana program, only atomic `RegisterV1` and exact retries.
- `client/`: shared Rust derivation, fixed registration signing, strict record
  verification and JNI. No arbitrary transaction-signing API.
- `runtime-tests/`: executes the compiled SBF under LiteSVM, including client/SBF
  interoperability. Virtual lamports and public vectors only; no RPC calls.
- `../../clients/android-devnet/`: separate Android registration-only candidate.

Names are 3..24 ASCII characters, a-z first, then a-z/0-9/underscore. One nickname
per identity, no transfers/rename/close. Clients visibly normalize ASCII case.
Recovery: 24 English BIP39 words, empty passphrase, hardened SLIP-0010 path
`m/44'/501'/0'/0'`; this does not restore messenger history. Never import a wallet
used for real funds. New Devnet-only keys are mandatory.

## Network and deployment status

RPC: `https://api.devnet.solana.com`.
Observed and pinned genesis: `EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG`.
Program ID (**deployed in Devnet**, finalized slot502240101):
`C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas`.
Dedicated deployment/upgrade authority public address:
`5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm`.
Private keys are outside the repository and APK; generated target key files are
ignored and must never be staged. Program/authority keys are different.

The actual Devnet genesis query succeeded. Initial RPC airdrop attempts failed;
the owner subsequently obtained 1 test SOL, verified at finalized slot501971808.
Funding is no longer a blocker. On2026-09-22 the owner explicitly authorized
Devnet deployment; the exact SBF is now finalized and independently dumped/verified.
See the [deployment receipt](../../docs/project/evidence/solana-devnet-deploy-20260922/README.md).
No registration transaction or physical-phone acceptance is claimed.
Funding must be obtained through the official Devnet faucet/owner, never paid SOL,
Mainnet, borrowed real-wallet keys or quota evasion. Required rent for the current
73,845-byte program-data allocation was queried as 0.37578284 test SOL; the
36-byte Program account adds 0.00083312. The initial buffer is drained back to the
payer before ProgramData allocation by loader-v3, not an additional permanent
deposit. Transaction fees are additional. Recompute before deployment if the
artifact changes. This candidate pins exact allocation size (no growth reserve).

## Reproducible local checks

Pinned tools: Agave CLI4.3.0, platform-tools v1.57, SBF arch v0, Rust1.98.1.
Official CLI archive SHA256:
`c97289a8abb1d0efb497d8b5cb285baabd9b7f8ea6647f5d145c5dc8ff3611e8`.
Registry `solana-program=5.0.0`, client modular SDK versions and every transitive
version are locked per Cargo.lock. LiteSVM0.16.0 resolves Agave runtime4.2.2 in
its lockfile; it is older-runtime coverage, not identical to CLI or Devnet.

```sh
cargo-build-sbf --tools-version v1.57 --arch v0 --manifest-path registry/Cargo.toml
cargo +1.98.1 test --locked --manifest-path runtime-tests/Cargo.toml
cargo +1.98.1 test --locked --manifest-path client/Cargo.toml
```

The initial rejecting SBF produced a real RED in LiteSVM; registration then went
GREEN. Temporarily removing the owner-signature guard made the missing-signature
test fail by accepting an unauthorized registration; restoring it returned GREEN.
Native client derivation, transaction and record-verification tests each had RED
before implementation. Later negative cases are additional regression coverage.
Clippy `--all-targets -- -D warnings` passed for all three crates.

Before live use: independent code review, finalized program dump/hash/authority
readback, actual Devnet registration and retained-state readback. Android SDK
compilation and host JNI checks are NOT physical-phone storage/lifecycle evidence.
No database/phone wipe, hosted change, merge or APK-feed publication is performed
by these local build/check commands.
