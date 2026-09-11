---
status: draft
owner: android-client
last_reviewed: 2026-09-09
---

# User-triggered Android update candidate (RFC-0013)

Current candidate: versionCode 15 / `0.0.15-voice`, package
`global.paranoid.messenger`, ARM64,
minSDK 26, targetSDK 35. This is implementation evidence, not feature acceptance,
publication permission, installed-phone evidence, or production update security.
The coordinator owns RFC-0013, draft ADR-0008, global threat/current-state/changelog
integration and publication. Those draft documents are in the separate server
worktree until integration; no historical ADR is accepted or rewritten here.

## Package transition and publication status — 2026-09-11

v15 updates v14 in place with the retained signer. Old `org.paranoid.devtext`
is a different application, not an in-place migration target. Preserve its data;
never uninstall or reset it automatically. Historical v5/v6 verification below
remains evidence of those old-package builds, not v15 device acceptance.
The live feed was observed advertising old-package v13; the new client correctly
rejects it. A source merge does not publish an update or authorize deployment.

## User flow

The first APK containing the button still needs one external in-place APK handoff.
Never uninstall, clear data, downgrade, or replace the signing key to make it work.

1. Tap **Обновить — проверить**. The updater reads only saved origin/SPKI from the
   existing state owner. No saved trust or unreadable state means no update request;
   there is no fallback to defaults for a previously configured phone.
2. A missing feed (404) or same/lower version says **Обновлений пока нет**. A compatible
   newer version offers **Скачать обновление**. No download starts without that tap.
3. Download and verification use a separate worker, not the messaging worker or UI
   thread. Successful verification offers **Установить обновление**.
4. That tap requests Android's per-source installation permission if needed. Return
   and tap Install again: granting permission never automatically starts installation.
5. Bytes and actual APK identity are rechecked before opening the system installer
   with a temporary read-only URI. Android confirmation is still mandatory. The app
   says only that it opened the installer, never that installation succeeded.

Failure gives Russian retry text and never creates an identity, resets state or
claims installed success. Activity recreation discards the UI stage; checking again
is safe. Since v13, a silent startup check is throttled to once per six hours;
manual checks remain available. A new-version banner opens the same explicit
download/install flow. No silent installation, forced upgrade, recovery/export
or automatic rollback is implemented. An explicitly
requested finite download can finish if the Activity loses focus; it does not
install automatically. Cache files are disposable, not messaging data.

## Wire and trust

- Only GET `/v2/updates/android` on the saved HTTPS origin; max 8192 UTF-8 bytes.
- Exactly `schema`, `package`, `version_code`, `version_name`, `min_sdk`, `abi`,
  `apk_sha256`, `apk_size`. Duplicate/unknown keys, invalid UTF-8/JSON, numeric
  strings/fractions/overflow, malformed escapes, trailing input and controls fail.
- Schema 1; fixed package/ARM64; positive versionCode (signed-long representable),
  positive minSDK (int representable), nonempty versionName <=128 UTF-8 bytes and
  no control characters; 64 lowercase hex SHA256; APK 1..16777216 bytes. The
  server implementation inspected uses the same 128-byte versionName bound.
- APK path derives only from the validated digest:
  `/v2/updates/android/apk/<apk_sha256>`. No metadata URL or filename is accepted.
- The existing `PinnedTls` verifies one explicitly pinned **self-signed leaf**, its
  self-signature, SAN/IP, expiry, key strength, usages and SPKI. It does **not** use
  system CA-chain trust. RFC-0013's earlier “CA/IP/SAN/expiry/SPKI” wording was
  clarified for FPD-D01 to describe this existing pinned self-signed-leaf policy,
  not add CA-issued-chain acceptance or a new architecture decision. No TLS code
  was changed, no pin was replaced and no trust-all or cleartext fallback was added.
- No HTTP redirect, proxy, cache, cookies or updater authentication fields. A global
  CookieHandler causes a fail-closed error. The app installs no global Authenticator.
  Connection/read timeout 8 seconds; streaming deadline 60 seconds (checked per
  read, therefore up to one read timeout beyond the deadline); bounded streaming
  works with fixed-length and chunked responses. Non-identity encoding is rejected.

## APK and URI gates / threat delta

`UpdateClient` creates only `cache/android-update/download.part` and `verified.apk`,
with private directory/file permissions and no-follow regular-file checks. SHA256
and exact byte count precede PackageManager inspection; failure removes partial and
ready files. Only after all gates does an atomic move expose `verified.apk`.
A new explicit check revokes an older grant. Only fixed update-cache names are
removed, never `files/`, `text-state.enc`, Keystore aliases or arbitrary paths.

`AndroidUpdateVerifier` inspects the real archive and installed app through
PackageManager. Package, versionCode/minSDK, newer-than-installed status and exact
single signing certificate must agree; incompatible devices, signer substitution,
multiple signers and observable rotation history are rejected. API26/27 use
GET_SIGNATURES; API28+ use SigningInfo and require a one-entry history. Native ZIP
entries must be ARM64 and contain the app's native core. Android's own installation
signature/version checks are additional gates, not a substitute for these checks.

`UpdateProvider` is nonexported and has only `/verified.apk` as a grantable path.
Its only URI is `content://global.paranoid.messenger.updates/verified.apk`. Queries expose
only display name and size. Selectors, unknown columns, altered authority/path/query/
fragment/encoding and all write modes/mutations fail. `openFile` uses O_RDONLY,
O_NOFOLLOW, O_CLOEXEC and fstat: regular file, app UID, one link, private permissions,
size bound. No directory listing, broad FileProvider roots, world-readable file,
file URI or write grant. Installer resolution is restricted to a system handler.

Supply-chain residuals: a compromised signing key or same-UID process remains a
trusted failure; a compromised feed can withhold or replay an older still-newer
signed release. No TUF, transparency log, signer rotation or Play compliance is
claimed. APK/OS parser flaws and real OEM installer/permission behavior remain
independent-review and phone-test concerns.

## Invariants and executed verification

REQ-ID-005/006/008 and SS-05: no new keys, registration or persistence from updater;
read-only saved-trust getter exercised with nondefault realm/SPKI on real JVM/JNI.
REQ-MSG-002/003/004 and SS-04: ratchets/history/contacts/outbox untouched; existing
locked Rust and JVM migration/storage/sync tests rerun. REQ-SEC-001 and SS-03/07:
new supply-chain/provider gates tested locally, not accepted as production security.
RFC-0013 supplies the update-specific contract; accepted ADR-0001/0003 govern docs
and review only. The first v6 build used the retained signing identity, not a new key.

Run after the normal build (Python `cryptography`, existing SDK/JDK/Rust required):

```sh
python3 clients/android/test_updates.py
python3 clients/android/test_update_wiring.py
ANDROID_SDK_ROOT=/path/to/sdk python3 clients/android/test_update_artifact.py \
  --previous /path/to/retained-v5.apk --evidence /path/to/private/evidence
```

The normal build now runs update wiring and real host TLS fixtures too. Tests use
only `127.0.0.23:<ephemeral port>`, disposable TLS certificates and auto-removed
private caches. They do not touch the hosted server or the parallel .19:38443 fixture.
A signed APK is the transfer payload, not fabricated APK data. TLS tests use a
callback gate for archive rejection; they do not pretend that callback is Android.
`test_update_artifact.py` separately uses real apksigner/aapt certificate and manifest
outputs from v5/v6, the production Java identity/hash policy, fresh Java/DEX/aapt
compilation, native build and byte-for-byte APK payload comparison. Public
certificates may be extracted temporarily; signing keys are never copied.

TDD evidence includes observed missing-parser/policy/network/trust/wiring failures,
then passing checks, plus a reproduced non-ASCII JSON hex-escape acceptance defect
and its failing regression/fix. Source-wiring tests supplement, not replace,
behavioral tests. Provider-policy tests execute the exact pure Java policy used by
the provider; Android Binder/grant enforcement, Os/PFD adapter and PackageManager
archive execution have **not** run on Android. Physical install/permission cancellation,
in-place v4/v5→v6 state continuity, OPPO behavior and two-phone messaging remain
NOT RUN. No server reimplementation, live request, delivery, commit or merge here.

Exact artifact/source hashes, build/test logs, publishable JSON values and actual
remaining gates are recorded in the coordinator evidence handoff, not invented
acceptance results. Independent review and controlled publication come next.
