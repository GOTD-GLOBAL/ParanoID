# Solana Devnet local review packet — 2026-09-21

Scope: RFC-0026, REQ-ID-001..005, REQ-CLIENT-001 and REQ-SEC-001;
ADR-0001/0003 retain independent review and human decision/deployment gates.
Separate registration-only Android candidate `global.paranoid.devnet`; no change
to the installed messenger, hosted DB, phone data or Mainnet. Fresh test identity
only. No permanent architecture acceptance or production security claim.

## Review closure candidates

Original verdict: [REQUEST_CHANGES](initial-code-review.md). Independent
[code/artifact re-review](code-review-closure.json) returned APPROVE for bounded
Devnet deployment and chain tests, closing B1-B5 and I1. It is not approval for
phone release, Mainnet or architecture acceptance. The [documentation supplement](documentation-review.json) also received APPROVE. [Deployment gates](../../../../blockchain/solana/DEPLOYMENT.md)
record exact allocation, pin-change consequences, node-version capture and
remaining phone acceptance. N5's misleading store comment was corrected; no
persistent latch is claimed. N4's runtime gap is valid, but all Android classes
were compiled by build.sh (contrary to its literal wording).
The supplemental review saw a tool-redacted slot in the diff; the actual source
contains501971808 and matches this record. Original review-input hashes identify
the exact reviewed packet; subsequent changes are documentation/formatting and the
approved store comment only. The [post-comment rebuild](post-comment-build.json)
records its distinct APK hash; SBF and ARM64 native hashes are unchanged. No phone
release approval is inferred. `last_reviewed` on larger existing documents is not
advanced by reviewing only this bounded new section.

- B1: `identity` no longer exports mnemonic; separate `export_mnemonic` is used
  only by creation/explicit backup UI. Native and actual host JNI tests pass.
- B2: program/upgrade-authority keypairs were generated outside Git/APK. Public
  readback via `solana-keygen pubkey` matches the RFC pins; directory0700,
  keyfiles0600. These are locally retained keys, NOT an offline/HSM claim.
  Native `program_info` owns all Android pins, removing duplicate Java literals.
  Its PDA test and real JNI consumer test bind the clients. Actual chain deployment
  and independent dump/hash/authority readback remain NOT RUN; they follow review,
  and remain release gates rather than being circular prerequisites for code review.
- B3: `python3 blockchain/solana/check_recovery_vector.py` independently reproduces
  the public zero-entropy BIP39/Solana-path address using Python3.12.3 stdlib
  PBKDF2/HMAC plus cryptography41.0.7/OpenSSL Ed25519, not either Rust derivation
  library. It first passes the published SLIP-0010 vector1. Only public test
  material; no argument accepts private mnemonics. See [result](recovery-vector.log).
- B4 / I1: exact loader-v3 tags, paired finalized Program/ProgramData reads,
  canonical ProgramData PDA linkage, authority option/key, executable flags,
  owners, allocation size and SBF SHA256 are checked before client signing.
  RED→GREEN evidence: [native pins](pins-red.log), [authority](authority-red.log),
  [bytecode](bytecode-red.log), [actual RPC gate](rpc-pin-red.log).
  [Host result](host-jni.log) covers valid SBF plus19 malformed/substituted cases
  and the real DevnetRpc→JNI path with an explicit in-process transport double.
  This is not live-chain evidence or an atomic guarantee against later upgrades.
- B5: all three Cargo manifests/lockfiles, Android manifest/build script, actual
  native/Android outputs and hashes are included in the re-review input.
  Signing credentials are environment-only in the repository build script;
  no signer/key material is included in this packet.

## Actual checks and artifacts

- [SBF build](sbf-build.log): Agave4.3.0, platform-tools1.57, archv0, locked deps.
- [Native client](client-tests.log): 7 passing tests.
- [Runtime](runtime-tests.log): 10 SBF registry tests plus1 mobile/SBF interop.
- [Host/JNI](host-jni.log): no live RPC or funded keys, actual compiled Rust.
- [Android build/signature](android-build.log): ARM64 native/API26, SDK35,
  build-tools35.0.0, NDK28.2.13676358; signature v2/v3 and16KiB alignment pass.
- [Clippy](clippy.log): all-targets `-D warnings` for all three crates.
- [Diff whitespace](diff-check.log): pass.
- [Artifact digests/sizes](artifacts.json): actual files, not expected values.

Reproduce host checks after native/SBF builds with `JSON_JAR` pointing to Maven
`org.json:json:20240303` and run `python3 clients/android-devnet/check_host.py`.
The script verifies the jar SHA256. Android build uses
`ANDROID_SDK_ROOT`, `PARANOID_ANDROID_KEYSTORE`, `PARANOID_ANDROID_KS_PASSWORD`;
run `bash clients/android-devnet/build.sh`. The local wrapper in the receipt only
supplies the retained signer environment and redacts its password. Do not commit
or share that credential. Runtime lockfile resolves Agave4.2.2, not CLI4.3.0.

## Remaining boundaries and nonblocking initial-review findings

I2/I3: bounded identical-wire rebroadcast and clearer exhausted-attempt recovery
are not implemented. No success is inferred from submission alone.
I4: ambiguous-write freeze is process-lifetime only; not persistent across restart.
I5: UI result ordering needs a generation fence.
I6: explicit phrase reveal has screenshot protection but no device reauthentication.
I7: app permits only one faucet request; owner-mediated transfer remains possible.
I8: queried signature status is not used to classify errors (record checks and
finalized block-height expiry govern retry).
I9: identity PDA helper currently uses an ignored dummy name argument.
I10: record verify receives compiled genesis after caller checks live cluster.
I11: missing-payer, max-name/tag0 and rent-deficient exact-retry test gaps remain.
These were classified nonblocking in the initial review, not silently fixed here.

Funding was separately verified as1 test SOL at finalized Devnet slot501971808;
no airdrop loop, Mainnet spend or deployment occurred in this closure task.
Before a usable release: approved code/artifact review, exact-artifact Devnet
deployment, finalized dump/authority checks, actual registration/readback,
then physical Android Keystore/restart/recovery acceptance. Local builds are not
phone evidence; the unsigned-off candidate is not delivered as ready.
