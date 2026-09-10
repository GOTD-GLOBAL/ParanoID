---
status: proposed
owner: architecture
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# RFC-0018: Complete the local voice relay path

The actual direct-ICE voice checkpoint has working encrypted calls, real media
and a signed APK. It lacks the issuer/client/package needed to hand over an
executable self-hosted network proposal. [REQ-CALL-006](../product/voice-relay.md)
records the original task scope; public deployment remains separately authorized.

Propose the exact [voice TURN v1 contract](../protocol/voice-turn-v1.md): retain
signed sessions and locked active-device authorization, issue random short-lived
coturn REST credentials, relay-only media when available, bounded disclosed
old-server direct fallback and isolated default-disabled configuration. No media
plaintext/key terminates on a server, no DB schema changes, no stack migration.

Alternatives: direct-only does not complete the task; embedded static passwords
or arbitrary free relays violate its trust boundary; a new auth server/pin adds an
unnecessary authority. Existing pinned HTTPS is the smallest issuer boundary.
HMAC-SHA1 is limited to coturn interoperability; identity remains Ed25519 and media
remains peer-authenticated DTLS-SRTP/Opus. Future SFU E2EE remains separate design.

The server foundation owns the canonical API, issuer and deployment package.
The Android PR depends on its exact commit and contains only client changes.
Integration combines both revisions for real tests and APK production. Fresh
bounded Fable design review must precede protected-boundary implementation;
source/artifact final reviews must follow actual tests. No acceptance or merge
is inferred. Proposed disposition is [ADR-0012](../decisions/0012-voice-turn.md).

The [threat delta](../security/voice-turn-threats.md) includes the discovered
upstream cached-credential and lifetime-cap bypasses. The selected package must
include the two narrow reviewed patches and actual before/after relay tests;
unmodified coturn cannot substantiate the bounded residual authority claim.

## Unified one-host installer amendment — 2026-09-10

[REQ-DEPLOY-003 and exact owner provenance](../operations/voice-single-host.md)
require a single coordinated kit on the existing host. Propose explicit
plan/preflight/apply/status/update/rollback operations, with fresh versus
recognized-v8 paths, same-data recovery, exact package verification, exclusive
private secret creation and narrow own-host relay egress. Existing TLS/DB/identity
and neighbors remain unchanged. Separate users/units remain internal isolation.
A manual set of component SSH commands does not meet the requirement. Fresh
Fable review of the exact coordinator/network design precedes implementation.
Existing expiry patches and quotas remain mandatory; stock coturn configuration
is not a substitute for the unproved cached-allocation expiry contract. No
architecture acceptance follows from the conditional deployment authorization.

Fresh Fable design review now conditionally permits local implementation after
A1–A5 corrections recorded in the [one-host runbook](../operations/voice-single-host.md#reviewed-implementation-boundaries).
The production and message-only fixture gate lists are fixed and different; the
fixture has no relay/network activation path and cannot produce full production
rehearsal acceptance. The separate inert systemd credential test proves only that
primitive. Missing runtime expiry/ACL and actual coordinated relay tests remain
mandatory.

## Subsequent reviewer identity clarification — 2026-09-10

The [direct owner clarification](../operations/voice-single-host.md#owner-clarification-of-independent-reviewer-identity-2026-09-10)
retains the completed original Fable architecture review and accepts subsequent
fresh independent Opus review under its actual identity. All substantive security,
TDD, threat analysis, final source/artifact and deployment gates remain mandatory.
This is a bounded review-process clarification, not permanent ADR acceptance or
permission to replace a failed/missing test with approval.
