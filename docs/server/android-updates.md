---
status: draft
owner: server
last_reviewed: 2026-09-09
---

# Android update distribution: local candidate and offline preparation

Implements the narrow server portion of [RFC-0013](../rfcs/0013-user-triggered-android-updates.md)
and [draft ADR-0008](../decisions/0008-user-triggered-android-updates.md).
This is not deployment, publication permission, ADR acceptance or phone evidence.
REQ-ID-008 signup and REQ-MSG-004 ciphertext/history semantics are unchanged;
REQ-SEC-001 privacy claims and REQ-DEPLOY-001 deployment gates remain separate.

## Publication contract

Only the self-service-v2 router reads optional `PARANOID_ANDROID_UPDATE_ROOT`.
Intended layout, outside the PostgreSQL `data` directory:

```text
ROOT/updates/                 # dedicated server UID, mode 0700
  android.json                # regular single-link file; prefer 0600
  <64-lowercase-hex>.apk       # regular single-link file; prefer 0400
```

No distribution file is executable configuration. No keystore, signing key,
password, TLS key, client state or operator grant belongs in this directory.
Other files are not addressable. No directory listing, URL field, query selector,
redirect, proxy, cookie, authentication token or generic static-file service exists.

GET `/v2/updates/android` returns the exact valid UTF-8 JSON bytes (at most 8192).
Exactly eight required keys, no duplicates/unknown keys, floats, nulls or coercion:

| Key | Bound/value |
| --- | --- |
| `schema` | integer 1 |
| `package` | `global.paranoid.messenger` |
| `version_code` | positive signed 64-bit integer (Android long version code) |
| `version_name` | 1–128 UTF-8 bytes, no C0/C1 control characters |
| `min_sdk` | positive signed 32-bit integer |
| `abi` | `arm64-v8a` |
| `apk_sha256` | exactly 64 lowercase hexadecimal characters |
| `apk_size` | positive signed 64-bit byte count, no fixed APK size ceiling |

GET `/v2/updates/android/apk/<apk_sha256>` serves only the **current manifest's**
digest, with `application/vnd.android.package-archive` and exact content length.
Both routes validate actual APK size and SHA-256 before returning success; the
response streams a verified anonymous disk snapshot, never a second pathname read. A feed switch
between check and download can give 404: the client must check again, not follow
an alternate URL. Metadata is not an APK signature; signer/package/version/SDK
verification is the publisher and Android client's separate mandatory gate.

Missing config/root/manifest returns 404. Invalid publication returns static
503 `{"error":"update_unavailable"}`; paths and parser/OS details are not returned
or logged. Unknown digest, malformed filename or query returns 404. Non-GET
methods, including HEAD, return 405 on the two registered routes. Legacy routers
never gain these routes, even if the variable exists in the parent environment.

## Filesystem and resource boundary

Linux `openat2` (kernel 5.6+, deployed x86-64/aarch64 ABI) is required; there is no
unsafe fallback. Absolute root only, no empty/dot/dot-dot/`data` components.
Every ancestor is opened fd-relative without symlinks/magic links and must be
owned by root or the server UID, without group/other write. Publication root must
be owned by the server UID and mode 0700. Normal trusted ancestor filesystem
mounts are permitted; a mount/bind mount at the publication root or either file
is rejected by kernel `RESOLVE_NO_XDEV`, including same-device bind mounts.
Files must be regular, single-link, same-owner and not group/other writable.
Nonblocking open prevents FIFO hangs; directories/devices are not served.
Metadata reads remain bounded at 8193 bytes. APKs are copied/hashed in 64 KiB
chunks, exactly the declared size plus a one-byte overshoot probe, with pre/post
fd metadata checks. A renamed/replaced path cannot redirect a held descriptor.
Before success, the verified bytes are captured in an anonymous mode-0600 inode
on the publication filesystem (Linux O_TMPFILE, no named-file fallback). The
response streams this snapshot with fixed buffers; later mutation of the source
cannot alter the response. Closing the snapshot reclaims its disk space.
APK size no longer dictates heap allocation. Snapshot disk space scales with
artifact size: available-space preflight is advisory under concurrent writers;
I/O failure is fail-closed. Require a disk-backed publication filesystem with
O_TMPFILE support; tmpfs would consume memory and is not a large-APK deployment.
The copy has a 10-second elapsed deadline between I/O operations; kernel-stalled
I/O cannot be preempted by this check. Existing transport deadlines still apply. Replacing a file between requests is
revalidated, and changing APK bytes invalidates both routes. Same-UID/root
compromise is outside the isolation claim, as is hostile kernel/filesystem behavior.

Reads/hash work run outside Tokio's async workers, at most two concurrent reads
per router and no waiting queue. A cancelled request retains its permit until its
blocking read ends; a successful APK response retains it through body consumption
or drop. Thus slow consumers cannot accumulate unbounded live snapshots. The merge is before the existing v2 ingress/body/10-second
handler layers and reuses existing TLS socket/stream budgets. This is bounded
alpha distribution, not bandwidth fairness, a CDN, TUF or a DoS guarantee.

## Build-host preparation only (recipe, not executed publication)

1. Freeze the reviewed **signed** build output into a new private local staging
   directory, never use a moving `out/paranoid-text.apk` for multiple independent
   reads. Example local-only setup:

   ```sh
   umask 077
   STAGE=$(mktemp -d "$HOME/paranoid-update-stage.XXXXXX")
   install -m 0600 "$REVIEWED_APK" "$STAGE/candidate.apk"
   TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
   "$TOOLS/apksigner" verify --verbose --print-certs "$STAGE/candidate.apk"
   "$TOOLS/aapt" dump badging "$STAGE/candidate.apk"
   sha256sum "$STAGE/candidate.apk"
   stat -c '%s' "$STAGE/candidate.apk"
   ```

2. Require successful signature verification and **exactly one signer**, retained
   certificate SHA-256
   `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
   Inspect actual badging: package `global.paranoid.messenger`, the reviewed increasing
   versionCode/versionName, actual minSdk and only expected `arm64-v8a` native ABI.
   Compare with the reviewed build/client and installed signing identity. Do not
   infer these fields from the filename. Stop on any mismatch or unsupported
   signer lineage. Do not print/copy private keystore material.
3. Only after those checks, prepare a local `feed/` directory mode 0700. Copy the
   snapshot as `<actual-sha256>.apk`, mode 0400 (not a hard link), verify the copied
   size/hash again, then generate `android.json` with the eight keys above using
   the inspected values and a JSON serializer. Enforce all bounds. Retain signer
   and badging review evidence separately; it is not an extra manifest field.
4. Handoff only the reviewed feed and nonsecret evidence to the coordinator. No
   SSH, live copy, service-manager call, firewall change or delivery to a phone
   is part of this recipe. A future separately authorized publisher must create
   the digest-named APK **first**, exclusively (never overwrite a different
   artifact at an existing name), fsync it, then fsync/atomically rename metadata
   **last** in the same directory and fsync the directory. Replacing metadata
   must not follow an existing link. Leave TLS, DB, locks and neighbors untouched.
   Retire the feed by removing metadata under that separate authorization, not
   by downgrading the installed APK or restoring an old DB.

## Parent-only controller integration after FV2-R01 handoff/re-review

The server's v2 router merge and env lookup are already implemented; no `main.rs`
change or capability widening is needed. The updater worker did not edit
`deploy/alpha.py` or its interruption fix. After the fixworker and independent
FV2-R01 reviewer hand off, add **only inside `environment(root)`'s existing
`if c.get('deployment') == 'self-service-v2':` branch**:

```python
env['PARANOID_ANDROID_UPDATE_ROOT'] = str(root / 'updates')
```

Do not set it in `clean_env`, v0/v1 branches or globally. This line does not create
or publish the directory: absence stays 404. Add controller tests for v2-only env
selection, missing feed and preserved legacy env. Rebuild and independently review
the combined final bundle; the earlier interrupt-only tar is not the updater
artifact. Keep `https://157.180.49.125:38443` and its existing certificate/SPKI.
Parent owns shared changelog/current-state/threat/index updates after parallel
ownership ends; this dedicated delta intentionally avoids those worker-owned files.

## Executable checks and limits

- `cargo test --locked --manifest-path server/Cargo.toml --lib android_updates`
- `cargo test --locked --manifest-path server/Cargo.toml --test android_updates`
- `python3 scripts/check-server.py`: private disposable PostgreSQL, full legacy
  and self-service signup/messages regressions plus v2-only env/budget integration.
- Optional real-build transport check (no signer/installer claim):
  `PARANOID_TEST_APK=/absolute/reviewed.apk cargo test --locked --manifest-path server/Cargo.toml --test android_updates actual_build_apk -- --ignored --nocapture`

Tests use owned private fixtures under HOME and ephemeral `127.0.0.1:0` listeners,
not the parallel interrupt worker's `127.0.0.19:38443`. The mount guard test opens
existing `/proc` to observe kernel EXDEV; it creates no mounts. Host transport
roundtrip is not a signer audit or an installed phone update. Generated/pinned-TLS
updater integration and physical Android installer acceptance remain coordinator/
client review gates; no live publication or deployment is established here.
