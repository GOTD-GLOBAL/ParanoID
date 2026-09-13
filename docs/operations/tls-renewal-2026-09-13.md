---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# Same-key TLS certificate renewal — 2026-09-13

## Outcome and authority

At `2026-09-13T07:44:21Z`, the existing private alpha at
`https://157.180.49.125:38443` successfully activated a renewed self-signed
certificate. The TLS private key and SPKI did not change. This is certificate
maintenance under [RFC-0008](../rfcs/0008-executable-text-development-slice.md#ip-https-with-an-explicitly-pinned-server-key)
and the [existing renewal boundary](linux-alpha-deployment.md#backup-and-disaster-recovery-limits),
not a new key-rotation design or permanent architecture acceptance.

In the current ParanoID Telegram task, Sergey Maltsev said:

> Коммент оставил к issue
> Key renewal делай

This directly follows the coordinator's explicit same-key certificate-renewal
proposal, not a proposal to replace the key. It authorizes this bounded operation
and the required dedicated-service restart. The original Telegram permalink is
not available in this tool context; this record does not invent one or claim
permanent ADR acceptance. The independently retrieved
[owner comment in issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)
is a **separate delegation record**, not TLS approval.

## Exact certificate change

| Property | Value |
| --- | --- |
| Old expiry | `2026-12-07T16:41:17Z` |
| Renewed validity begins | `2026-09-13T07:38:09Z` |
| Renewed expiry | `2026-12-12T07:38:09Z` |
| Validity profile | Existing 90-day profile, five-minute not-before backdating |
| Key | Retained EC P-256; unchanged bytes, no export or rewrite |
| SPKI SHA-256 | `8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba` |
| Old certificate PEM SHA-256 | `c0c6cdc3d4dc68eeef55fc3bad6e98f111f0d962927d15a0c6369dac0f13c53f` |
| New certificate PEM SHA-256 | `bdf0a677a2bef2c1b7a2f8ede654dd0edc87b89501ab627ab25890c7fbfb40d4` |
| New serial | `1C84A61F5D1D48EB58EBD3A27FDD87322258B104` |

Subject, issuer, public key and every extension/critical flag match the old
certificate. SAN remains exactly the hosted IPv4; non-CA, digital-signature
keyUsage and serverAuth EKU remain unchanged. Only validity, serial and the
corresponding certificate signature changed. Both certificate/key pairs loaded
successfully on the host; OpenSSL verified the new self-signed certificate,
server purpose and exact IP independently on the build host.

**This early renewal extends the old expiry only to December 12.** It does not
solve ongoing lifecycle management: another reviewed same-key renewal is needed
before that date. There is no automatic renewal, reminder job, indefinite key
lifetime authorization or key-compromise recovery claim in this change.

## Procedure and preservation boundary

The reviewed one-off script is preserved as inert
[evidence](../project/evidence/tls-renewal-20260913/renewal.py.txt).
Its production-script SHA-256 is
`2b992f31c10ad76b37790491fa7e2b6d1e215ddec6f303e955ebd6e57c47a77a`.
It is not installed as an automatic renewal service.

1. Used the [strict SSH procedure](production-access.md) with a temporary agent.
   No SSH private key was printed, written decrypted or forwarded.
2. Verified live health, safe file metadata, space, active release, dedicated unit
   and neighboring service identities. Acquired the existing `operation.lock`.
3. Read the TLS key only in host-process memory. Signed the candidate under the
   same key and checked exact SPKI/profile, signature, validity and key matching.
4. Preserved **public certificates only** and a prepared receipt in the private
   host directory `/home/paranoid/tls-renewal-20260913` (0700; files 0600).
   The old public-certificate copy was read back and loaded with the retained key
   as a restore check. No private-key copy or database backup was made or needed
   for this certificate-only rollback boundary; this is not a global backup waiver.
5. After independent review and local tests, stopped only the user unit
   `paranoid-alpha.service`. Confirmed no active process or queued systemd job,
   atomically replaced `tls/server.crt` using a unique exclusive temporary file
   and directory fsync, then started the same unit.
6. Waited for actual TLS/authenticated-database readiness, verified the exact
   served certificate DER and checked retained identity/configuration metadata.
7. Independently verified the endpoint from the build host with the unchanged
   Android `PinnedTls` implementation on the JVM and the retained pin.

The messaging package remains `9e6549ecd92080e20fcc`. Configuration and dedicated
unit hashes, private PostgreSQL system identifier `7683525211206671315` and data
root inode match the prepared receipt. The private PostgreSQL process follows
its existing supervisor's normal stop/start; no SQL mutation, migration,
restore, reset or application release replacement was performed by this task.
This establishes cluster identity and readiness, **not a full history row audit**.

TURN, Nginx, Docker and the neighboring PostgreSQL service retained their observed
PIDs/start timestamps/states. No firewall, DNS, push configuration, update feed,
client snapshot or contact credential was modified. A read-only feed probe
returned HTTP 200 with `global.paranoid.messenger`, versionCode 25; this task did
not publish or audit that APK.

## Review, tests and exact limits

[Preserved evidence](../project/evidence/tls-renewal-20260913/README.md) contains:

- Initial independent AI `REQUEST_CHANGES` on recovery-state handling, temporary
  filename collisions and startup readiness; no live application preceded closure.
- Fresh independent final AI `APPROVE` against the script hash above. The retained
  live transcript contains bounded tool/result previews, not every full tool body.
  Runtime model identity was not exposed in the result; no human audit is claimed.
- Eight synthetic transaction/fault tests PASS. Real file/signature operations;
  systemd, health and served-certificate checks are mocked in this suite.
- Six real loopback TLS/JVM cases PASS using a synthetic key: old certificate,
  same-key renewal, old-certificate restoration, rejected wrong pin, expired
  certificate and wrong SAN. Negative cases send no HTTP request.
- Host application receipt: `PASS: TLS authenticated database readiness`;
  retained key bytes/config/release/cluster identity/neighbors unchanged.
- External exact renewed DER and current Android TLS/JVM HTTP 200 PASS;
  curl certificate/IP/SPKI verification result 0.

Physical Android phones, native iOS/TestFlight and new E2EE exchanges were NOT RUN.
No claim about their acceptance or an iOS implementation is inferred from JVM
results. Applicable boundaries: REQ-ID-007, REQ-MSG-002/004/005,
REQ-SEC-001 and REQ-DEPLOY-002; ADR-0003 governs the independent alpha review.

## Rollback and follow-up

The old public certificate is retained at
`/home/paranoid/tls-renewal-20260913/old.crt`; it expires on December 7. If the
new certificate causes a failure, the reviewed script's explicit `rollback`
mode accepts only the recorded old/new certificate hashes under the same lock,
without requiring an initially healthy service. It stops/reconciles the dedicated
unit, restores the old certificate atomically, starts and verifies readiness and
exact served DER. Unknown certificate/config/release drift fails closed rather
than overwriting another operator's work. Invoke through the authorized strict
SSH procedure with the preserved exact script; do not copy the TLS private key.

The live operation succeeded and did not invoke rollback. Interrupted-file,
fsync, delayed-start and timed-out-start recovery were tested on synthetic local
fixtures, not by injecting faults into the hosted service. Host power-loss
recovery remains untested. Do not use the old certificate after its expiry.

Key rotation still requires a separate RFC covering transport trust, credential
bindings and first-contact channels, mixed client versions, long-offline clients
and rollback. No automatic repin or replacement of stored contacts is permitted.
