---
status: draft
owner: architecture
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# RFC-0013: User-triggered signed Android updates

## User direction and scope

On 2026-09-09 Sergey requested an in-app Update button to download later APKs
without repeatedly receiving files in Telegram. He confirmed both phones still
run the prior operator-registration app. The supplied screenshot corroborates
the historical UI, not an exact installed version/signature inspection.
This is local implementation direction and a new distribution trust boundary,
not permanent architecture acceptance, silent install permission or deployment.
The first APK containing this button must still be installed in place manually.
[Draft ADR-0008](../decisions/0008-user-triggered-android-updates.md) records the
proposed decision; independent review precedes live publication.

Scope: explicit button -> check -> download verified APK -> Android installer
confirmation. No background update, forced upgrade, content-key/state export,
uninstall, data clear, downgrade flag, new signing key or credential in a URL.
For in-place updates from v14 onward keep package `global.paranoid.messenger`,
the existing signing certificate and all phone keys/history/contacts/outbox/server trust.
The owner-directed v14 rename is a new Android application identity, not an
in-place migration from `org.paranoid.devtext`. No automatic data transfer,
uninstall or reset is authorized. This 2026-09-11 clarification supersedes the
earlier package pin only; this RFC and ADR-0008 remain drafts. Android user confirmation and
per-source installation permission remain mandatory; do not evade them.

## Proposed interoperable contract

Use the phone's already trusted HTTPS origin and SPKI, never an arbitrary URL or
trust-all TLS. Public update routes are read-only distribution, not signup/auth.

- GET `/v2/updates/android`: max 8192-byte UTF-8 JSON object with exactly these keys:
  `schema` (integer 1), `package` (`global.paranoid.messenger`), `version_code` (positive
  integer), `version_name` (bounded nonempty string), `min_sdk` (positive integer),
  `abi` (`arm64-v8a`), `apk_sha256` (64 lowercase hex), `apk_size` (1..16777216 bytes).
- APK URL is derived, NOT supplied by metadata:
  `/v2/updates/android/apk/<apk_sha256>` on that same trusted origin.
- Metadata availability: 200 on valid configured publication; 404 if no publication.
  Invalid publication fails closed with a static error, no path/private data leak.
- No redirects/proxies, external URL fields, user credentials, auth/session grants,
  cookies, query-based file selection, arbitrary filenames or file browser.
- Server distribution is optional and independent of the server DB. An explicit
  `PARANOID_ANDROID_UPDATE_ROOT` references a private same-owner real directory
  outside `data`, intended `ROOT/updates`. Absent configuration/publication leaves
  routes unavailable; legacy modes do not gain update routes.
- Files: `android.json` and `<apk_sha256>.apk`. Exact regular same-owner no-follow
  single-link files; reject unsafe root/ancestors and oversized metadata/APK.
  Publication files are untrusted data, not instructions or executable config.
  Validate schema/fields, bounds and APK actual hash/size before serving. Use only
  fixed metadata filename and strictly validated digest-derived APK filename.
- Publisher publishes a reviewed signed immutable digest-named APK first, metadata
  atomically last. Never overwrite a different artifact at an existing digest name.
  Publishing distribution content is a separately controlled coordinator action;
  no change to TLS, system services, firewall or neighboring applications.

## Client trust and install gates

The check/download path must reuse the existing per-connection explicitly pinned
self-signed-leaf TLS policy: saved origin/SPKI, leaf self-signature, exact IP SAN
and normal hostname verification, certificate validity, server-auth usages and
key strength. It does not introduce system-CA-chain trust or accept CA-issued
chains. This corrects the earlier ambiguous “CA/IP/SAN/expiry/SPKI” wording,
aligning with the existing [development TLS policy](0008-executable-text-development-slice.md)
and [threat model](../security/server-v0-threats.md), not changing TLS behavior
or accepting a new architecture decision. No pin replacement, insecure fallback
or upgrade through HTTP. Version must be greater
than installed versionCode; same/lower version means no update. Enforce device API
and ABI compatibility and bounded file size before/during download. Compute SHA256
and exact length, then inspect the actual APK using Android PackageManager:
package, versionCode/minSdk and signer must match metadata/installed app identity.
No multi-signer or unsupported signing-lineage shortcuts. Reject mismatches before
opening the installer; OS signature verification is an additional gate, not the
only planned check. A hash without trusted transport/signer is insufficient.

Download only into a dedicated private cache subdirectory, temporary file first;
no contact with `text-state.enc` or Keystore keys. Verify before promoting to the
installable cache file. Share only that fixed verified file through a non-exported
read-only content provider with temporary URI grant to the installer; never broad
file:// URLs, arbitrary-path providers or world-readable files. Clear failures are
shown in Russian with retry available. Network/download failure never resets ID.
The installer remains user-mediated; no claim of installed success before actual
PackageManager state confirms it. Avoid blocking UI/network on the main thread.

## Threats and independent review gates

Update feed compromise/replay, artifact substitution/truncation, malicious paths,
rollback, signing-key substitution, redirect to attacker origin, leaked URI grants,
APK parser mistakes and arbitrary file exposure are protected-domain concerns.
Mitigations above reduce these risks but do not make an alpha a secure update
framework: compromised signing key and malicious same-UID host remain trusted
failures; compromised server can withhold updates or replay an older still-higher
signed version. No TUF/transparency, staged rollout or signer rotation is claimed.
Review must independently examine the new permissions/provider and distribution
routes, source-to-APK provenance, published artifact, and preserved phone state.

## Verification / delivery

TDD for parser/network/provider/server behavior where executable tooling permits;
real generated pinned-TLS metadata + APK download, reject wrong pin/hash/size/
package/signer/lower version/redirect/unsafe path, no-update case and absent feed.
Test private cache/URI scope and no phone state changes. Build signed update APK
with monotonically increased versionCode and the retained signing identity, not a
new test key. Host/JVM tests are not installed Android installer/permission proof.
Final independent client/server review and an actual phone update remain separate.
Keep code changes small and keep the existing messaging/replacement work moving.
