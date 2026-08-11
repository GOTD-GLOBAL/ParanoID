---
status: draft
owner: identity
last_reviewed: 2026-08-11
---

# EXP-IDENTITY-0002: Mobile key-derivation conformance

## Decision boundary

This experiment informs `REQ-ID-001`, `REQ-ID-002`, `REQ-ID-005`,
`THR-ID-001`, and `THR-ID-011`, plus open questions 1 through 3 in
[RFC-0002](../rfcs/0002-identity-registration-authentication.md). It is the
narrow mobile/native-boundary spike required by
[ADR-0002](../decisions/0002-initial-technology-stack.md).

It does **not** accept a production mnemonic policy, key hierarchy, account
identifier, secure-storage design, or identity protocol. The candidate names,
salts, public keys, and schema identifiers remain experimental. An accepted ADR,
physical-device evidence, and independent cryptographic review are still
required before a real account can depend on them.

## Question

Can Kotlin Multiplatform independently reproduce the Rust
`hkdf_sha512_v1` public authorities on JVM, Android, and iOS without importing
Rust identity code into the client boundary?

## Provisional policy under test

The product direction for this experiment is deliberately strict:

- 24 English BIP-39 recovery words representing 256 bits of entropy;
- no additional BIP-39 passphrase in paranoid-mode v1;
- losing the words means losing the account, with no operator bypass;
- separate Ed25519 account-root and Solana-registry authorities;
- independently generated device keys remain outside this derivation;
- `hkdf_sha512_v1` is the selected candidate to test across client platforms.

This is a provisional experiment selection, not an accepted cryptographic
contract. It intentionally tests a ParanoID-native registry authority rather
than compatibility with a conventional Solana wallet derivation path. External
wallets may later be attached as optional proofs through a separate decision.

## Implementation and boundaries

- Kotlin Multiplatform module:
  `clients/shared/identity-conformance`
- Common implementation:
  `PrototypeIdentityConformance.kt`
- Executable common tests:
  `PrototypeIdentityConformanceTest.kt`
- JVM fixture-contract test:
  `CommittedVectorContractTest.kt`
- Rust-authored public fixture:
  `specs/protocol/identity/key-derivation-experiment-v1.json`
- Local verification guide:
  [Run mobile identity checks](../how-to/run-mobile-identity-checks.md)
- CI workflow: `.github/workflows/mobile-identity.yml`

The Kotlin implementation performs BIP-39's PBKDF2-HMAC-SHA-512 seed step and
the experiment's two domain-separated HKDF-SHA-512 branches independently. It
uses `cryptography-kotlin` abstractions, Bouncy Castle on JVM/Android, and the
library's native Apple provider path on iOS. The clients consume the public JSON
fixture as the cross-implementation contract; they do not call the Rust crate.

## Tests and results on 2026-08-11

The Windows development host reproduced the selected Rust vector in both JVM
and Android host tests:

- the exact account-root and registry-authority public keys matched;
- repeated derivation was deterministic;
- the two purposes produced unequal public keys;
- a non-empty passphrase was rejected by the prototype policy;
- malformed word count, casing, and spacing were rejected;
- the JVM test confirmed that its expected values occur in the committed JSON
  fixture.

The iOS simulator target and test task are configured, but the Windows host
cannot execute them. The macOS CI job is the next source of iOS evidence. No
physical Android or iOS device has run this experiment yet.

## Limitations and unresolved work

- The common Kotlin code validates only the fixture's ASCII shape. It does not
  validate the BIP-39 English word list, checksum, or Unicode normalization and
  must not be used to create or recover a real account.
- Kotlin `String` inputs cannot be reliably zeroized. Mutable derived byte
  arrays are cleared on a best-effort basis, but compiler, provider, runtime,
  crash, swap, and operating-system copies remain possible.
- An Android host test does not exercise Keystore, screen capture, clipboard,
  backup, accessibility, biometric, or process-death behavior.
- The experiment derives public keys only. It does not define signing,
  canonical envelopes, secure storage, root authorization, or device recovery.
- Provider behavior and raw Ed25519 seed import still require supported-version
  tests on physical devices and review of dependency update behavior.
- The committed vector is public test material and must never control an
  account, nickname, token, or funds.

## Exit criteria

Before a key-hierarchy ADR can be accepted:

1. make JVM, Android host, and iOS simulator conformance CI mandatory;
2. reproduce the candidate on supported physical Android and iOS devices;
3. add full BIP-39 validation and normalization tests without extending secret
   lifetime;
4. publish negative byte-level derivation and signing vectors;
5. document secure generation, confirmation, storage, recovery, and deletion
   behavior on both mobile platforms;
6. complete Solana compatibility and cross-application key-reuse analysis;
7. define versioning and migration before any real identity is created;
8. obtain independent cryptographic and mobile-security review.

## Dependency evidence

- [Kotlin Multiplatform compatibility guide](https://kotlinlang.org/docs/multiplatform/multiplatform-compatibility-guide.html)
- [Android-KMP library plugin](https://developer.android.com/kotlin/multiplatform/plugin)
- [cryptography-kotlin providers](https://whyoleg.github.io/cryptography-kotlin/getting-started/providers/)
- [Gradle checksum reference](https://gradle.org/release-checksums/)
