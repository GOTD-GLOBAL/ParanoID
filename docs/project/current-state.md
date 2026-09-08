---
status: accepted
owner: maintainers
last_reviewed: 2026-09-08
---

# Current project state

## Phase

**Inception and architecture discovery.** This repository is a clean reboot. It
contains documentation, Android diagnostics and a development transport
increment, but no usable messenger or accepted production architecture.

The earlier proof of concept is preserved in the private
`GOTD-GLOBAL/ParanoID-legacy` repository. It may be mined for lessons, UX ideas,
and experiments, but it is not a dependency or source of current architecture.

## Experimental device evidence

A disposable Android packaging diagnostic exists in
`spikes/002-android-bootstrap`. The owner supplied a screenshot of installation
and launch on OPPO CPH2671 (Android 16/API 36). It displays device information
locally, has no network permission and is not a messenger or stack acceptance.

## Present facts

- The new repository is private and intentionally starts from a clean history.
- The product vision is documented as a draft.
- Initial product requirements are traceable but do not yet have complete
  acceptance criteria.
- Documentation-as-code is the first accepted project decision.
- No application stack, blockchain, identity protocol, messaging protocol,
  cryptographic construction, database, hosting platform, or token model has
  been selected.
- No production security or privacy claims are valid yet.

## Experimental Android evidence (not a production capability)

The isolated [Android probe](../../spikes/002-android-bootstrap/README.md) builds
an ARM64 APK using vodozemac with a JNI boundary for a local synthetic self-test.
Host tests and cross-compilation pass. The session handoff records owner-reported
local diagnostic PASS on OPPO CPH2671 and CPH2659 (Android 16 ARM64); this is not
a new physical-device run or proof of phone-to-phone messaging. No server, real
conversation, account recovery or production stack is introduced. RFC-0004
(closed PR #6) is historical proposal context only.

## Active single-server implementation boundary

The founder now prioritizes one server and two OPPO phones exchanging E2EE text
with history, reconnect and no duplicates. One check means server acceptance;
two mean peer delivery, not reading. Server history remains until an additional
explicit deletion request. iPhone and multiple-server support remain future
scope; a second server is not an acceptance gate for this slice.

[RFC-0006](../rfcs/0006-single-server-text-contract.md) records concrete assistant
recommendations and their [acceptance matrix](../protocol/server-v0-acceptance.md).
It is draft, not an accepted architecture. Identity/E2EE, delivery/persistence
and stack still require their own disposition and durable owner approval
evidence under the now-accepted ADR-0003 process. Absence of a second human
is not itself a closed-alpha blocker. Earlier PRs #1, #2, #5, #6 and #10 were
closed without merge during owner-requested cleanup. Their branches and research
are retained, not accepted architecture. PR #12 published ADR-0003. This
contract, native crypto evidence and host-access documentation are separate
artifacts, not prerequisites requiring another broad research phase.

A [dependency-only stack check](../research/2026-09-08-server-stack-check.md)
compiled pinned Axum/Tokio/SQLx dependencies on Linux. It implements no server,
API, message store or client. No phone-to-phone message has been demonstrated.
The local Docker daemon was inaccessible to this invocation; no production host
was changed. No iOS build or protected-domain implementation was performed.

The older discovery list below is background, not a request to restart broad
research. The immediate gate is disposition of the narrow contract, then the
TDD implementation order in RFC-0006.

## Closed-alpha review policy

The founder requested removal of the mandatory second-human reviewer after
reporting that none is available. [RFC-0007](../rfcs/0007-closed-alpha-review-policy.md)
records a bounded private test-data alpha exception with independent AI review
and retained human decision-owner approval, approved by martadvix-web in PR #12.
[ADR-0003](../decisions/0003-closed-alpha-review-policy.md) records acceptance;
the policy is normative on main. It accepts no application architecture,
authorizes no deployment and makes no security claim.

## Executable transport increment in development

RFC-0008 and draft ADR-0004 accompany `server/`: a loopback HTTP process with
PostgreSQL ciphertext append, idempotent retry, recipient cursor sync and
non-evicting quotas. Real tests include killing/restarting the binary and Olm
fixture ciphertext exchange. Fixture identities are trusted inside the test
process, not two phones. No Android/iOS messaging client, remote peer verification,
durable client ratchet, delivery receipt or hosted rollout is claimed. The full
RFC-0006 acceptance matrix remains unfulfilled; architecture is not accepted.

A fresh owner-authorized read-only host inventory confirmed Docker, Nginx and
PostgreSQL active and HTTP/HTTPS ports occupied. No remote mutation occurred.
ParanoID deployment must be isolated from existing services. The local test
runner creates/removes its own private PostgreSQL cluster; it does not connect
to that host. Simple reproducible Linux deployment remains a product requirement.

## Development client and IP-TLS work

`clients/core` and the Android adapter now contain peer-pinned Olm text/receipt
logic, an encrypted atomic local snapshot and IP-based pinned HTTPS. An ARM64
APK builds; Rust, Linux JVM JNI/codec, packaging and local TLS smoke checks pass.
These do not prove runtime behavior on OPPO. The [client README](../../clients/android/README.md)
records two outstanding synchronization findings and the bounded test sequence.
No hosted TLS endpoint, new production process or public port is created by this
increment. Full two-phone acceptance is still pending.

## Next decision gates

1. Validate and prioritize the initial requirements with the founder.
2. Define assets, adversaries, metadata exposure, recovery, and trust boundaries.
3. Specify identity and nickname lifecycle, including cost and abuse resistance.
4. Compare protocol and implementation strategies, including open-source prior art.
5. Select the first vertical slice and its measurable acceptance criteria.
6. Accept the initial architecture and stack through RFCs and ADRs.

## Update trigger

Update this document whenever a gate is completed, a production capability is
added, a major risk changes, or an accepted decision changes what a newcomer
should believe about the project.
