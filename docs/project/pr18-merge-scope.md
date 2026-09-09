---
status: draft
owner: maintainers
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# PR 18: explicit owner merge direction and next voice stage

## Current direct authority

After reporting responsive physical-phone text exchange ("Работает отлично.
Текст летает туда сюда"), Sergey instructed in the current ParanoID Telegram task:

> 18 pr тестируй, ошибки устраняй и мержим. Следующий этап - голосовые звонки.

He then clarified:

> Как смержишь 18 - делай голосовые вызовы

This is direct task provenance. No independently verifiable Telegram permalink
is available in this context; no permanent ADR approval is invented. The
[phone feedback](https://github.com/GOTD-GLOBAL/ParanoID/issues/16#issuecomment-5609070441)
is a coordinator record of the owner's qualitative observation, not an
instrumented phone-latency/security/background benchmark.

For **PR #18 only**, this instruction supersedes its earlier archival-only,
DO-NOT-MERGE disposition and the requirement to split this already reviewed
integrated v8 checkpoint into separate server/client merge PRs. Component source
and documentation remain separated in the monorepo; this is not a general
repeal of [component boundaries](component-boundaries.md). The initial archival
commit and full evidence remain preserved, not rewritten.

## Merge conditions and preserved invariants

- Fix and verify supported release CI; no skipped or weakened security assertions.
- Preserve known pre-v7 historical tests, raw failure results and exact scope
  separately. Owner explicitly excluded old migration/recovery from this alpha
  release gate; that does not make historical bugs fixed.
- Review changes since the frozen v8 product/security review, including CI wiring
  and this scoped documentation amendment. Merge only the verified final HEAD.
- RFC-0015 and ADR-0010 remain proposed. Merge permission does not constitute
  permanent application-architecture acceptance or a human security audit.
- No new deployment, data reset, phone action, TLS rotation or neighbor change
  is needed to merge the already delivered version8 implementation.

## Actual state and next stage

The owner-reported responsive two-phone text exchange supplements the earlier
[local and hosted evidence](evidence/overnight-realtime-20260909/README.md).
Physical OEM background behavior, Doze, force-stop, battery, accessibility and
camera verification remain unproven by that report. PR merge was authorized but
is not claimed completed merely by writing this document.

After merge, **1:1 encrypted voice calls** become the next implementation stage,
prioritized over other media. Use a separate feature branch and RFC/threat analysis
for authenticated call signaling, media key binding, audio routing, connectivity,
call lifecycle and resource limits. Mature WebRTC/Opus/STUN/TURN components are
candidates, not an accepted cryptographic or deployment contract. Required evidence
includes real media between endpoints, microphone/speaker/mute/end behavior,
reconnect and negative authorization tests; physical-device audio quality cannot
be established by mocked packets or dependency builds. Preserve the working text
path and v8 identity/state/signer throughout. No call implementation or new public
TURN/firewall/DNS deployment is asserted or authorized solely by this document.
