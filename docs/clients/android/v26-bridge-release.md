---
status: draft
owner: android-client
last_reviewed: 2026-09-13
---

# v26 bridge release: published, server rollout blocked

This is the dated 2026-09-13 operation record, not a fresh server-status check.
The [PR34 integration review](pr34-integration-review.md) records subsequent
source corrections and their separate verification scope. Its candidate bytes
are not the historical signed APK described below.

## Scope and provenance

Sergey Maltsev authorized server update and a legacy-compatible Android bridge
with “Го” after PRs32/33 merged. This record covers actual Android publication,
not server deployment or permanent architecture acceptance. REQ-CLIENT-003,
RFC-0013 and draft ADR-0008 retain signer/data/consent/trust gates.

The released v25 branch contained fixes not yet in main: explicit main-thread
CallController ownership after cold FCM wake, native exit reporting and separate
Firebase-only R8 processing. v26 integrates these byte-preserved source fixes with
the merged updater; building old main alone would have regressed released behavior.
No APK-sized buffering, new signer, identity reset or loss of the updater fixes.

## Actual artifact and checks

- Source commit: `62a2300dda58cb8bda6ed71b6ecb05e79b8ae7f7`, clean before build.
- Package: `global.paranoid.messenger`; version26 / `0.0.26-update`; ARM64/API26+.
- APK SHA256: `2a00e8dbf2f4cc7bc7d6b9d34a174a6530d20abee9ea81ea7342d5ab8cc4bc1e`.
- Size: 16,443,022 bytes, within installed clients' legacy16MiB ceiling.
- Retained certificate SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- Canonical `clients/android/build.sh` completed successfully: native Rust,
  Java/JNI, UI/call/update policies, pinned-TLS transport, split DEX, APK signing
  and zip alignment. No keystore/password entered the repository or feed.
- Independent fallback AI review (gpt-6-astra, not Opus/human audit) approved
  source/artifact and the bounded single-publisher publication script. It checked
  actual v25/v26 signatures, all98 unsigned ZIP payload entries and1195 D8-only
  class definitions, preserving411 WebRTC and291 ZXing classes.
- The old v25 updater source from `2e5614d` parsed exact v26 metadata and verified
  the actual APK on local pinned TLS. After publication, the same old updater
  fetched version26 from the live pinned origin and downloaded all16,443,022 bytes
  with matching SHA256. This is host transport evidence, not phone installation.

## Actual publication and remaining gates

The live `/v2/updates/android` feed now advertises version26. The immutable
hash-named APK was fsynced first; metadata was atomically replaced last. Previous
public v25 metadata is retained as `updates/android-v25-before26.json`; the v25
APK remains. No service/config/TLS/DB mutation belongs to this publication.

Server deployment stopped on the original coordinator's config/certificate/unit
identity-drift guard, before code switch. Release, PG identifier, TLS key and pin
were unchanged. The server remains on `9e6549ecd92080e20fcc` and still has its old
APK ceiling. Do not publish larger APKs until that separate rollout succeeds.
Do not rewrite the coordinator journal to bypass its gate.

Physical-phone installation, call/push runtime acceptance and Android Binder
behavior remain unrun. User should update both phones in place and confirm v26;
never uninstall or clear data if installation fails. Archive/source manifests and
redacted build evidence are under `/home/codex/paranoid-update-publish/v26/` on the
build host. Stale v15 artifact verifier was not claimed passing.
