---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Android publication: offline preparation and server contract

Local RFC-0013 candidate, not deployment or accepted architecture. Requirements:
REQ-CLIENT-003, REQ-ID-008, REQ-MSG-004, REQ-SEC-001. See
[RFC-0013](../rfcs/0013-user-triggered-android-updates.md),
[draft ADR-0008](../decisions/0008-user-triggered-android-updates.md) and
[v2 protocol](../protocol/self-service-v2.md). No DB, TLS or phone changes belong
to publication. Independent review and coordinator authorization precede live use.

## Exact publication and HTTP contract

Only the v2 router reads optional `PARANOID_ANDROID_UPDATE_ROOT`. Unset means no
feed. Intended value is `ROOT/updates`, a sibling of `ROOT/data`, never a DB path.
The absolute path must have no empty/dot/parent components or component `data`.
Root is a real directory, process-eUID owned, mode 0700. Ancestors must be real,
root/eUID-owned and not group/world writable. Files are same-owner regular,
single-link, no group/world writes (publish mode 0600); neither symlinks nor
hardlinks, directories, FIFO/device/socket entries are served. Keep only public
update artifacts here, never credentials/config/keys. No directory listing exists.

Linux x86_64/aarch64 with openat2 (Linux 5.6+) is required. Directory-FD-relative
opens reject symlinks/magic links; publication-root and file opens also reject
mount crossings (including same-device bind mounts). Trusted system mounts on
safe earlier ancestors may exist. Unsupported kernels fail closed, no fallback.

Publication contains `android.json` and `<apk_sha256>.apk`. Metadata is UTF-8 JSON,
up to 8192 bytes including whitespace, exactly eight keys, no duplicates, extra
fields, floats, numeric strings or trailing input:

- `schema`: integer 1.
- `package`: `global.paranoid.messenger`.
- `version_code`: positive signed 64-bit integer (Android long version code).
- `version_name`: 1..128 UTF-8 bytes, no Unicode control characters.
- `min_sdk`: positive signed 32-bit integer.
- `abi`: `arm64-v8a`.
- `apk_sha256`: exactly 64 lowercase ASCII hex characters.
- `apk_size`: integer 1..16777216 inclusive.

GET `/v2/updates/android` returns the exact validated metadata bytes as
`application/json`. GET `/v2/updates/android/apk/<apk_sha256>` returns the exact
validated APK bytes as `application/vnd.android.package-archive`, with length.
Both verify actual APK hash/length BEFORE returning success. Bytes are read once
from checked descriptors, bounded, checked for in-read metadata changes, then
that buffer is returned; no reopen-for-streaming substitution window exists.
Only the CURRENT manifest digest is served: after a feed change, an old check
may receive 404 and must check again. No history/browser/static-files service.

Absent configuration/root/metadata: 404. Invalid publication/missing advertised
APK/hash or size mismatch/unsafe path: static 503
`{"error":"update_unavailable"}`. Unknown digest, malformed digest, any query:
404. Non-GET (including HEAD): 405. No redirects, external URLs, cookies, auth
or session grants; no filesystem error/path detail in responses. Existing v2
body, ingress and handler-time budgets still apply; updates can receive 429.
Two concurrent blocking readers per router prevent unbounded disk/hash jobs;
excess reads fail 503. This is not load certification or fair bandwidth control.

## Build-host-only preparation recipe (not executed publication)

1. Stop the build writer or copy its completed APK ONCE to a new private local
   staging directory outside any served directory. Use `umask 077`,
   `mktemp -d "$HOME/paranoid-update-stage.XXXXXX"`, and `install -m 600` to copy.
   Do not hash a moving `out/paranoid-text.apk` and later copy a different build.
2. On that snapshot, run the retained SDK tools:

   ```sh
   "$ANDROID_SDK_ROOT/build-tools/35.0.0/apksigner" verify --verbose --print-certs "$SNAPSHOT"
   "$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt" dump badging "$SNAPSHOT"
   sha256sum "$SNAPSHOT"
   stat -c %s "$SNAPSHOT"
   ```

   Require successful signature verification, exactly one retained signer with
   certificate SHA-256 equal to the previously trusted installed/release signer
   (not merely a fingerprint supplied by the new APK), package
   `global.paranoid.messenger`, intended greater version code, exact version name,
   compatible minSdk and arm64-v8a. Check the actual badging values, not source
   constants. Reject mismatch; never generate a replacement signing identity.
3. Only after those checks, prepare a private `updates/` staging subdirectory.
   Copy the snapshot into an exclusively created `<verified-sha256>.apk`, 0600.
   Recheck the staged file's hash/size. An existing digest name must already have
   exactly those bytes; do not overwrite it. Do not hardlink the snapshot.
4. Generate the eight-field JSON from the verified APK values with a JSON encoder,
   not shell interpolation. Check the exact bounds above. Write `android.json.tmp`
   (0600), fsync it, then atomically rename it to `android.json` LAST and fsync
   the staging directory. The digest APK must be durable first. Keep signer audit
   output and build provenance outside the publication directory.
5. Hand the staged artifact and evidence to the coordinator. This recipe performs
   no SSH/upload/live write. A later separately authorized publisher must repeat
   destination owner/path/bytes checks, publish APK first and metadata atomically
   last. Never replace a digest with different bytes. Removing metadata disables
   a feed; it does not delete DB/history or downgrade installed applications.

The server validates transport bytes, NOT Android signatures/package internals.
Publisher verification and the client's installed-signer/package/version gates
remain mandatory. A compromised same-UID host or signing key remains trusted
failure; replay/withholding and traffic metadata are not eliminated.

## Controller integration after interrupt-fix worker handoff

The updater worker handed off the v2-only router separately. After the FV2-R01
fix handoff and independent bounded closure, the local bundle integration adds
exactly this line inside
`environment(root)`'s existing `if c.get('deployment') == 'self-service-v2':`
branch, after v2 mode selection:

```python
env['PARANOID_ANDROID_UPDATE_ROOT'] = str(root / 'updates')
```

Do not inherit arbitrary shell env into other modes; do not add a publication
route to v0/key-v1, automatic directory creation, upload API, DB change or a new
controller action. Missing `ROOT/updates` intentionally remains 404. Add a focused
controller test asserting this env value for v2 and absence for v0/key-v1; rerun
fresh/interrupt guards and rebuild/review the exact combined bundle before any
separately authorized publication. The env line is now applied; strict RED/GREEN
coverage is in `deploy/test_update_environment.py`. This is local integration,
not independent updater review or publication approval.
