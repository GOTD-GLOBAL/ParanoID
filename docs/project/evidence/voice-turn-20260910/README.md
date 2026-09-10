# Voice relay foundation evidence — 2026-09-10

This record covers REQ-CALL-006/RFC-0018/proposed ADR-0012 on the separate server
foundation. It does not replace the direct-call client checkpoint or claim live
operation. [The protocol](../../../protocol/voice-turn-v1.md) remains canonical.

- [Fresh Fable design review](fable-design-review.txt) and [verified invocation](fable-design-verification.json):
  gate opened with the exact corrections incorporated before implementation.
  Requested35 turns, actual50; successful Fable model usage is recorded honestly.
- [Server validation](server-validation.json) records85 passing full-matrix tests,
  14 focused issuer tests, the two quota units and exact release TLS checks.
  [Text regression](text-regression.json) records24 warm samples and all nine
  actual messaging/receipt/restart checks passing.
- [Offline package evidence](offline-package-summary.json): actual pinned build,
  native closure, licenses, capability pair and controller/unit checks.
- [Platform interruption](relay-worker-interruption.json): retained-allocation
  expiry/race/drain and ACL packet tests remain NOT RUN. No rejected action was
  retried. Offline checks and ordinary owned app interoperability do not establish
  those missing deployment acceptance results.

Fresh exact-source final review is pending. No permanent ADR acceptance, merge,
public listener, existing-server update or physical-phone action is claimed.
