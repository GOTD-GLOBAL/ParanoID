---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# Same-key renewal evidence

The [operational record](../../../operations/tls-renewal-2026-09-13.md) defines
scope, authority, preserved state, exact certificate dates and rollback limits.
No private TLS/SSH key, credential or application-message content is included.

## Actual host and external evidence

- [Prepared host receipt](prepared.json): old/new public certificate hashes,
  retained key check, old-copy restore check, baseline configuration/release,
  cluster identity and neighboring service observations.
- [Apply intent](apply-94fbb7005b0242bda9f87c16d3d87237-started.json) and
  [successful application](apply-94fbb7005b0242bda9f87c16d3d87237-success.json).
- [External exact DER and Android TLS/JVM check](external-verification.json).
- [Old public certificate](old.crt) and [renewed public certificate](new.crt).

## Reviewed source and tests

- [One-off maintenance script](renewal.py.txt): inert archived text, not a
  deployment-package update or automatic job. Script SHA-256:
  `2b992f31c10ad76b37790491fa7e2b6d1e215ddec6f303e955ebd6e57c47a77a`.
- [Initial independent review](review-initial.txt): REQUEST_CHANGES; all three
  findings were addressed before live application.
- [Final independent review transcript](review-final-transcript.txt): APPROVE
  against the final source hash; tool/result bodies in this runtime transcript
  are bounded previews. Reviewer is an isolated Hermes AI context; actual model
  identity was not exposed in the returned review. Not a human audit.
- [Transaction fault tests](transaction-tests.py.txt) and
  [actual output](transaction-tests.log): eight tests PASS; temporary real
  files/signatures, mocked systemd/health/served-certificate integration.
  The recovery-failed diagnostic is expected in the outstanding-job negative case.
- [Loopback TLS tests](tls-tests.py.txt), [JVM probe](RenewalTlsProbe.java.txt)
  and [actual result](result.json): six cases PASS with real TLS and unchanged
  product `PinnedTls.java`, synthetic key only. Three negative cases send no HTTP.

The archived test sources retain the actual build-host paths from execution.
For reproduction, restore the script as `/tmp/paranoid-tls-renewal.py`, the
transaction suite as `/tmp/paranoid-renewal-transaction-tests.py`, and the JVM
probe as `/tmp/RenewalTlsProbe.java`; adjust only the local repository location
in the loopback test if necessary. Run transaction tests with `python3` and the
loopback script with Python cryptography plus the installed JDK. These tests do
not authorize execution of the production script against a host.

No live fault injection or live rollback was performed. Physical phones,
iOS/TestFlight, full database-history comparison and power-loss recovery are
NOT RUN. Same-key renewal does not implement key rotation or auto-repin.
