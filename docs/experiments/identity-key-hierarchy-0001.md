---
status: draft
owner: identity
last_reviewed: 2026-08-11
---

# EXP-IDENTITY-0001: Key-hierarchy candidates

## Decision boundary

This experiment informs `REQ-ID-001`, `REQ-ID-002`, `REQ-ID-005`, `THR-ID-001`,
and `THR-ID-011`, plus open questions 1 through 3 in
[RFC-0002](../rfcs/0002-identity-registration-authentication.md).

It does **not** select a production key hierarchy, mnemonic policy, recovery
format, Solana registry model, device-key construction, or signed encoding. An
accepted ADR and independent cryptographic review are still required.

## Question

Can a 24-word English BIP-39 fixture reproducibly yield separated Ed25519
account-root and Solana-registry authorities while preserving an explicit probe
of the conventional Solana `m/44'/501'/0'/0'` path?

## Fixed input

- 256 bits of all-zero public test entropy;
- the corresponding 24-word English BIP-39 mnemonic;
- an empty BIP-39 passphrase for the committed baseline;
- BIP-39 seed output as the input to every candidate.

The mnemonic and entropy are public test fixtures. They must never control an
account, nickname, token, or funds.

## Candidates

| Candidate | Account root | Registry authority | Purpose |
| --- | --- | --- | --- |
| `hkdf_sha512_v1` | HKDF-SHA-512 with an experiment-specific salt and account-root `info` | HKDF-SHA-512 with a distinct registry `info` | Tests explicit domain separation without wallet-path compatibility. |
| `hybrid_hkdf_root_solana_registry_v1` | Same HKDF account-root branch | SLIP-0010 Ed25519 at `m/44'/501'/0'/0'` | Tests root separation while retaining the Solana compatibility path for registry control. |
| `slip10_ed25519_v1` | SLIP-0010 Ed25519 at experimental `m/0'` | SLIP-0010 Ed25519 at `m/44'/501'/0'/0'` | Tests an all-SLIP-0010 hierarchy with separate hardened paths. |

All names, salts, paths, and schema identifiers are experiment-only. They are
not reserved production values.

## Implementation and artifacts

- Reference crate: `crates/identity-core`
- Generator example: `crates/identity-core/examples/generate_vectors.rs`
- Executable tests: `crates/identity-core/tests/key_hierarchy.rs`
- Public vector:
  `specs/protocol/identity/key-derivation-experiment-v1.json`
- Local verification guide: [Run Rust checks](../how-to/run-rust-checks.md)

The crate rejects invalid English mnemonics, exposes public keys only, forbids
unsafe Rust, and zeroizes selected secret buffers on a best-effort basis. Those
implementation choices reduce accidental exposure; they are not proof against
memory forensics, compiler copies, malware, or a compromised operating system.

## Results on 2026-08-11

- The fixed public document is deterministic and byte-for-byte checked against
  the committed JSON fixture.
- Every candidate produced distinct account-root and registry public keys.
- The hybrid and all-SLIP-0010 candidates produced a registry public key equal
  to the explicit Solana compatibility probe.
- The HKDF-only registry branch intentionally differed from that probe.
- A non-empty BIP-39 passphrase changed every tested public authority.
- The local SLIP-0010 implementation matched the official Ed25519 master and
  first-hardened-child test vector.
- Seven integration tests and two internal tests passed on the pinned Rust
  toolchain. CI repeats formatting, tests, and Clippy on Ubuntu.

These results establish reproducibility of the experiment, not fitness for
production.

## Limitations and unresolved work

- No candidate has received independent cryptographic review.
- The vector has not yet been cross-checked against Kotlin, Swift, a Solana CLI,
  or hardware wallets.
- The experiment does not test Unicode mnemonic languages, recovery UX, secure
  storage, process memory capture, mobile backups, or crash reporting.
- Using the conventional Solana path may improve compatibility but may also
  increase cross-application key reuse and phishing risk. The trade-off remains
  unresolved.
- `m/0'` is only an experiment path; adopting it without a versioned namespace
  and migration analysis would be unsafe.
- Device keys should remain independently generated unless a later reviewed
  decision proves deterministic derivation is required.
- Algorithm agility, canonical account identifiers, encrypted seed retention,
  and passphrase policy remain open.

## Exit criteria

Before a key-hierarchy ADR can be accepted:

1. reproduce the selected candidate in Rust and Kotlin, and across any necessary
   Swift boundary;
2. publish positive and negative byte-level conformance vectors;
3. document Solana wallet and hardware compatibility evidence;
4. complete recovery, mobile secret-lifetime, and cross-purpose reuse analysis;
5. obtain independent cryptographic review;
6. define versioning and migration behavior before any real identity is created.

## Standards used as experiment inputs

- [BIP-39](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
- [SLIP-0010](https://github.com/satoshilabs/slips/blob/master/slip-0010.md)
- [HKDF, RFC 5869](https://www.rfc-editor.org/rfc/rfc5869.html)
- [Ed25519, RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html)
