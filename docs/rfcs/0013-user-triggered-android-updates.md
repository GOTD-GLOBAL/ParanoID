---
status: draft
owner: architecture
decision_owner: martadvix-web
last_reviewed: 2026-10-06
last_reviewed_scope: fixed-service candidate reconciliation and no-ceiling regression repair
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
confirmation. No background download/install, forced upgrade, content-key/state export,
uninstall, data clear, downgrade flag, new signing key or credential in a URL.
For in-place updates from v14 onward keep package `global.paranoid.messenger`,
the existing signing certificate and all phone keys/history/contacts/outbox/server trust.
The owner-directed v14 rename is a new Android application identity, not an
in-place migration from `org.paranoid.devtext`. No automatic data transfer,
uninstall or reset is authorized. This 2026-09-11 clarification supersedes the
earlier package pin only; this RFC and ADR-0008 remain drafts. Android user confirmation and
per-source installation permission remain mandatory; do not evade them.

## Owner amendment: no fixed APK size ceiling (2026-09-13)

Sergey Maltsev explicitly requested in Telegram: “Нет никакого смысла в этом
лимите. Но и конечно раздувать файл не стоит. Давай уберем лимит и с сервера и
с клиента”. This authorizes local implementation, not merge/deployment or permanent
ADR acceptance. The original message permalink is unavailable in this tool context.

REQ-CLIENT-003: remove the arbitrary 16 MiB APK ceiling on both components; do not
replace it with another product-size ceiling. Retain useful dependency optimization,
without stripping required runtime behavior. Size is a positive signed 64-bit byte
count (numeric representation, not a chosen APK budget). Metadata remains <=8192
bytes; actual length, SHA256, pinned origin, signer, package and installer consent
remain mandatory. Old clients still enforce their old ceiling.

Server candidate: hash/copy via fixed buffers into an anonymous private disk
snapshot on the publication filesystem, then stream those exact verified bytes.
No APK-sized heap allocation. Hold the existing two-reader permit for the entire
response lifetime, including cancellation/cleanup. Require enough available disk
for the snapshot and reject I/O failure; Linux O_TMPFILE support is required with
no unsafe named-file fallback. Root/service-UID compromise is outside the boundary.
Disk usage now scales with APK size (up to two concurrent snapshots), not RAM;
free-space checks are advisory under concurrent other writers, not a disk quota.
Normal timeouts and cancellation remain resource controls, not success guarantees
for arbitrarily large artifacts or slow links.

Client candidate: remove parser/provider ceilings; stream only the declared length
with overflow-safe accounting and disk-space preflight, retaining error cleanup and
all install checks. Existing network deadlines remain unchanged in this scope.

Rollout: separate server and Android PRs. Publish a retained-signer bridge APK that
still fits old clients before any larger APK, or explicitly deliver the new client
manually in place. Do not erase data or downgrade. Server rollback is compatible
only with a feed that the old server accepts. No live action follows from this RFC.

Tests: >16 MiB server roundtrip, snapshot immutability and permit lifetime;
large client manifest/provider/download, exact length/hash rejection, numeric
range/overflow and unchanged trust gates. Host fixtures are not phone acceptance.

## Fixed-service implementation reconciliation — 2026-10-06

This dated amendment describes the retained private-alpha implementation introduced
by `0f48d57` and repairs regressions under the existing no-ceiling direction. It
supersedes the transport description below **for the current Android candidate**;
the per-server section is historical, not an additional active production policy.
The owner requested verification and merge of PR #70 after the discrepancies were
reported (ParanoID Telegram, 2026-10-06; original permalink unavailable). That is
bounded work/merge authority, not permanent architecture acceptance. ADR-0008 stays
draft and independent implementation/security review is required before merge.

- Production `new UpdateClient()` always fetches
  `https://paranoid.global/updates/android.json` and derives
  `https://paranoid.global/updates/<apk_sha256>.apk`. The selected messenger server,
  identity state, metadata and contact links cannot redirect that origin.
- HTTPS uses the platform CA store and normal hostname/certificate validation;
  there is no trust-all manager, custom production pin, HTTP fallback or redirect.
  A well-known domain, certificate transparency or a matching hash does not by
  itself grant signer authority. The installed APK signer/package/version/ABI and
  Android user consent are separate mandatory checks. DNS/CA/CDN/feed compromise
  can censor or replay distribution; signing-key compromise remains a trusted
  failure. This record does not retrospectively manufacture owner TLS approval or
  claim production security; it makes the existing candidate and its risks explicit.
- The two-argument pinned-origin constructor serves local compatibility fixtures,
  using the historical `/v2/updates/android` paths; production callers do not select
  it. It must reject malformed origins before any request. Its pinned-leaf tests
  do not establish the default constructor's public-CA transport behavior.
- Restore real cache free-space preflight, declared-length header/body limits and
  fixed-buffer streaming, without an arbitrary 64 MiB or 512,000,000-byte ceiling.
  Enforce the 8192-byte metadata limit also when Content-Length is absent/chunked,
  and enforce bounds **before** writing the offending bytes. Retain SHA-256,
  signer verification, private/no-follow cache writes and failure cleanup.
- Test fixtures must fail on handler errors and verify the expected rejection
  cause/zero requests for invalid origins, not call any process failure a security
  pass. Exercise both default fixed-origin routing and pinned fixture transport;
  name host-adapter, real local TLS, and physical Android evidence separately.

No messenger TLS, key/session/history, server, publication, installer or permission
change is authorized by this repair. The historical optional per-server feed may
remain implemented on servers but is not the current APK's distribution source.
A future architecture acceptance or distribution-policy change requires its own
human evidence and ADR disposition; merge leaves that status unchanged.

## Historical per-server interoperable proposal

Use the phone's already trusted HTTPS origin and SPKI, never an arbitrary URL or
trust-all TLS. Public update routes are read-only distribution, not signup/auth.

- GET `/v2/updates/android`: max 8192-byte UTF-8 JSON object with exactly these keys:
  `schema` (integer 1), `package` (`global.paranoid.messenger`), `version_code` (positive
  integer), `version_name` (bounded nonempty string), `min_sdk` (positive integer),
  `abi` (`arm64-v8a`), `apk_sha256` (64 lowercase hex), `apk_size` (positive signed 64-bit byte count; no fixed APK ceiling).
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
  single-link files; reject unsafe root/ancestors, oversized metadata and APK length mismatches.
  Publication files are untrusted data, not instructions or executable config.
  Validate schema/fields, bounds and APK actual hash/size before serving. Use only
  fixed metadata filename and strictly validated digest-derived APK filename.
- Publisher publishes a reviewed signed immutable digest-named APK first, metadata
  atomically last. Never overwrite a different artifact at an existing digest name.
  Publishing distribution content is a separately controlled coordinator action;
  no change to TLS, system services, firewall or neighboring applications.

## Historical pinned transport and retained install gates

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
and ABI compatibility and exact declared file size before/during download. Compute SHA256
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

## UI reachability correction (2026-10-06)

The update controls must be in a visible, attached page reached from the menu or
available-update banner, separate from My ID. A missing/older/same-version feed
must display its result, not leave the user with an invisible action. Use the
Activity's existing window so installer focus checks remain meaningful. Reopening
the page must not advance download/install automatically; native consent remains
mandatory. Installation-result routing shows the controller message without
starting another check. Existing phone keys and data are untouched.

This was a bounded presentation correction under REQ-CLIENT-003, not a new TLS or
publication decision. The later fixed-service reconciliation above describes the
retained distribution implementation and repairs its size/test regressions without
changing its production trust selection. Neither amendment accepts architecture.

## Verification / delivery

TDD for parser/network/provider/server behavior where executable tooling permits;
real generated pinned-TLS metadata + APK download, reject wrong pin/hash/size/
package/signer/lower version/redirect/unsafe path, no-update case and absent feed.
Test private cache/URI scope and no phone state changes. Build signed update APK
with monotonically increased versionCode and the retained signing identity, not a
new test key. Host/JVM tests are not installed Android installer/permission proof.
Final independent client/server review and an actual phone update remain separate.
Keep code changes small and keep the existing messaging/replacement work moving.
