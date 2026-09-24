# Integrated Android v28 build evidence — 2026-09-22

Owner request: one main ParanoID APK with Devnet nickname registration plus
existing chats/calls, not a separate registrar. The owner then asked for an update
build after explicit disclosure that the24 words recover the Devnet name key,
NOT the messenger account/history. Telegram provenance has no exposed permalink.
PR53's earlier no-phone-release approval is NOT treated as approval of this new
build scope. RFC0026 is amended; ADR0015 is proposed, not accepted.

## Candidate and limits

`global.paranoid.messenger`, version28 / `0.0.28-devnet`, ARM64, minAPI26;
retained signer82b29cc0…5926. The existing messenger main activity remains the
only launcher. My ID -> Nick in Devnet opens a non-exported internal activity.
Existing server account, contact QR, E2EE keys and chat/call implementation are
not replaced. No on-chain code/deployment or server/update-feed change is included.

This is a privately requested **update-build candidate**, not full-account seed
recovery, architectural acceptance, a public release, or physical-phone acceptance.
If the faucet fails, the UI exposes only the public address for operator-mediated
Devnet funding; no sponsor key is packaged and no real SOL is requested.

## Real checks

- [Full main APK build](build.log): existing native chat/call, JVM, SDK, TLS,
  background, update/wiring/download and artifact/signature gates passed. This is
  not a skipped-gates repack of the standalone registrar.
- [Artifact](artifact.json): package/version/retained signer, size and SHA256.
- [JNI/controller](jni.log): real native derivation/signing, same-wire pending
  rebroadcast, bounded expired-ledger reconciliation, explicit name change only
  after expiry/absent identity, UI generation fence and19 program-pin negatives.
  Transport/store fixtures are synthetic, not live-chain evidence.
- [Android storage](android-storage-runtime.log): actual Android35 emulator,
  Keystore and AtomicFile, separate disposable `global.paranoid.devnet.acceptance`
  package using the production store class and x86_64 build of the same Rust code.
  Write, separate-process reopen, and durable leftover-intent refusal pass. The
  refusal test was RED before the store fix. Only this disposable test package
  was cleared; the real messenger/phone data was not touched. This is NOT a
  physical ARM64 phone or full integrated UI installation test.
- [Live registration](live-registration.json): the real shared controller/native
  client registered `p28_accept_0922` in Devnet, read both records at finalized,
  restored the same key from its24 words into fresh local state and rediscovered
  the same registered name. A repeated user registration returned already
  registered without a new transaction. Test funding0.01 Devnet SOL; no Mainnet.
  Secrets stayed outside Git/APK/logs; only public handles are recorded.
- [Notices](notices.log): main and Devnet Rust dependency closures are attributed;
  missing crate license texts are pinned in `clients/android/licenses/devnet/`.

## Explicit handoff limitations (review B2/B3)

A leftover `devnet-write.pending` marker intentionally blocks the Devnet section.
This build has NO supported safe in-app reset of only that store. Clearing the
whole application's data would remove the marker but also destroy the messenger
ID and local history; **do not clear data or uninstall to fix Devnet**. Keep the
messenger data, report the error and wait for scoped recovery tooling. Chat/call
storage is not mutated by the Devnet latch. The UI explicitly explains this.

The integrated ARM64 APK has not been launched on an Android runtime here: host
checks compiled the full application, while Android runtime checks used a separate
x86_64 storage harness. My ID -> Devnet screen/navigation and library loading in
the actual messenger process are for the owner's first physical acceptance. No
claim of full UI/device readiness or full-account seed recovery is made.

## Review closure and owner report — 2026-09-22

The retained [review closure](review-closure.json) approved private artifact
handoff after the artifact-scope blockers recorded in that file were corrected.
The APK was handed to the owner in Telegram;
he subsequently reported that nickname registration works. This is a user report,
not independently captured full-app phone instrumentation, seed recovery or a
new joint audio/video acceptance. Earlier NOT RUN statements below describe
what the build host actually observed and remain preserved.

The owner now requests completion and merge of PR54, separate from publication
or permanent ADR acceptance. The new offline `devnet-client` CI job covers native
Rust and actual JNI/controller tests plus integration/notices; exact-SBF program
pin verification and Android storage checks remain separate artifact evidence.
No live transaction, reset, server change or APK publication is performed by the
merge-preparation follow-up.

## Remaining acceptance

The proposed update is to be installed over the existing package, not by deleting
it. Physical-phone installer, live audio/video and UI recovery acceptance remain
for the owner after private handoff. Existing chat/call regression checks are not
misrepresented as a new joint physical-phone call. In-app feed publication, server
changes, Git merge and full messenger seed recovery are NOT performed by building
this artifact. Independent current-source/artifact review is required before
calling it ready for private handoff.
