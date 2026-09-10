---
status: proposed
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-10
---

# One-host install-and-call delivery

## Exact authority and boundary

The current owner task asks: «Доведи до состояния установил и позвонил.
Что от меня надо - говори». The owner then confirmed:

> Размещаем на существующем сервере. Наша задача что бы все было на одном
> сервере. Я напоминаю, что мы планируем сделать one touch установку сервера.

The [retrieved GitHub record](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5613364943)
was posted by `goryanya-deploy[bot]` at `2026-09-10T04:51:46Z`; it preserves the
supplied direct Telegram reply. It is not a GitHub comment authored by the human,
an original Telegram permalink, or permanent ADR acceptance. The current direct
user instruction confirms this bounded operational authority.

The selected placement is the existing `157.180.49.125` host. After mandatory
actual tests and fresh independent AI review pass, the authorized scope is
messaging on retained TLS TCP 38443; a dedicated TURN account and system unit on
TCP/UDP 34781 and UDP 40000–40015; scoped network rules; and a reviewed same-data
issuer update with rollback. Preserve DNS, TLS key/pin, identities, all retained
history/database and neighboring services, including ports 80/443. No second VPS
or mandatory cloud service. No PR20/21 merge, public release, phone automation,
credential reset, data discard or safeguard bypass is authorized.

This amendment supersedes earlier local-only/no-host-authorization wording only
for this exact conditional deployment. It does not turn any missing acceptance
into a passing result. RFC-0018 and ADR-0012 remain proposed.

## Requirement and proposed installer contract

REQ-DEPLOY-003 extends the near-one-click direction in REQ-DEPLOY-001 and
retains the same-data update safeguards of REQ-DEPLOY-002.

**REQ-DEPLOY-003:** messaging, private PostgreSQL and relay run on one host and
are installed, checked, updated and rolled back by one reproducible ParanoID kit.
Separate users, credential sources and service managers are internal isolation.
Explicit host/configuration inputs are required; one touch does not mean zero
inputs or a manual per-component SSH recipe.

The candidate entry point exposes `plan`, `preflight`, `apply`, `status`, `update`
and `rollback`. It distinguishes a genuinely empty fresh installation from a
recognized existing-v8 same-data upgrade. Existing/partial installations must be
recognized idempotently or refused with a precise recovery state. It never routes
an existing host through `fresh-v2` or `replace-v2`. It must preserve previous
release/config/unit bytes and retained current data through failed updates and
rollback. Lock, path, symlink, overwrite and interruption safety are mandatory.
The [corrected design and independent review](../project/evidence/voice-single-host-20260910/README.md)
define the coordinator. Actual message-phase tests pass; final lifecycle
corrections and artifact freeze are recorded in the evidence. Final exact source/artifact review remains required; the owner now explicitly
accepts an independent Opus review recorded under its actual identity.

## Acceptance and current result

Initial client head: `562848658f3b5874827d12185bf3829aba1bfe0d` (PR20).
Initial server head: `923e11b1f0a5ba8709002d21e282778123c2bfe5` (PR21).
Full tracked-file hashes and initial clean status are preserved outside Git in
`voice-single-host-20260910T045552Z`. Older dirty worktrees are unchanged.

| Gate | Current evidence |
| --- | --- |
| Owner location and bounded port authority | Confirmed above, conditional on tests/review |
| Existing signed v10 APK and prior actual relay media | Preserved; no new build or test claimed |
| CALL-CONNECT01 | OPEN; one ordinary fixed-arm non-reproduction is not causal closure |
| TURN-RT01 retained expiry/race/drain | NOT RUN; prior worker rejection preserved |
| TURN-ACL02 and effective own-host port denial | NOT RUN |
| Actual CLI closure, credential delivery and relay lifecycle | NOT RUN |
| Unified coordinator and owned message-phase rehearsal | Earlier fresh/update/rollback/failure/idempotence execution PASS; later fresh-boundary acceptance INVALID_RECEIPT; full relay NOT RUN |
| Fresh installer design | Fable conditional; A1–A5 corrected before implementation |
| Final exact independent code/artifact review | Pending; actual reviewer identity must be recorded, including Opus |
| Hosted installation and external registration/text/call | NOT ATTEMPTED |

The prior rejection was `Agent errored: This content was flagged for possible
cybersecurity risk.` while preparing the `media_discovery` worker at
`2026-09-09T23:54:29Z`. No new test, process, listener or namespace began. The
[original record](../project/evidence/voice-turn-20260910/relay-worker-interruption.json)
remains authoritative. Do not repeat or reroute that rejected work. Inspecting
source, implementing packaging and ordinary regression tests are separate work;
they cannot substitute for missing actual relay security acceptance. Any new
concrete denial must stop that action and preserve the exact capability failure.

## Delivery and rollback gates

Before relay exposure, the exact artifact, runtime configuration, units and
network rule hashes must be reviewed with actual expiry, access-control,
credential, lifecycle and app-media results. Rehearse the single installer in an
owned disposable environment; Python render assertions alone are insufficient.
Then perform the attended authorized installation through the existing operator
access with a recorded action journal and real readback/health. Prove external
registration, text and media using new owned synthetic identities. Physical-phone
audio, Bluetooth, Doze and mobile handover remain separately NOT RUN.

Rollback disables issuance, stops only the relay and removes only installer-owned
network rules, restoring reviewed prior messaging code/config/unit on current
retained data. Never restore a stale dump over newly accepted history. Partial
failure must recover or stop clearly with evidence; it must not reset and retry.

Related: [REQ-CALL-006](../product/voice-relay.md),
[RFC-0018](../rfcs/0018-voice-turn.md), [ADR-0012](../decisions/0012-voice-turn.md),
[TURN contract](../protocol/voice-turn-v1.md),
[threat delta](../security/voice-turn-threats.md).

## Reviewed implementation boundaries

The production and message-only fixture profiles have distinct fixed acceptance
gate lists. A fixture cannot create a fake production PASS receipt: it excludes
relay artifacts/network execution, uses loopback and unique test roots/units, and
produces only messaging-phase rehearsal evidence. The fixture issuer stays
disabled: native public-mode TURN correctly rejects its loopback relay address.
The failed issuer-enabled fixture is retained as a harness design error; it does
not establish a user-manager credential incompatibility. No production address or
credential guard is relaxed. Full coordinated relay rehearsal
remains separately mandatory for production. This resolves initial rehearsal
circularity without bypassing a gate or retrying the denied worker.

Runtime prerequisites include installed PostgreSQL16 binaries and Python
`cryptography` (Cipher/AESGCM API checked before mutation), systemd, supported UFW
and nftables. The kit manages private PG data; it does not replace the shared PG
service or install OS packages. Exact numeric service UIDs are explicit inputs
validated before paths and policy are rendered.

The messaging worker holds the existing operation lock, switches code while
configuration remains unchanged, then adds the exact voice object after cutover.
Rollback restores journaled prior configuration bytes before starting the prior
code, with all current data retained. The relay requires the dedicated persistent
policy oneshot; it loads or verifies exact rules, never flushes them on stop.
Exact systemd dependency resolution passes after genuine RED, but packet and actual
relay lifecycle gates remain unrun. UFW preflight must reject every existing
semantic tuple regardless of comment; removals require the exact nonempty owner
comment. No shared firewall command has been executed.

**CALL-CURRENT01** is the reviewed finite functional acceptance: first-grant
incoming, retained-permission incoming/redial (each at least30seconds connected
with actual decoded media), then one outgoing call against the coordinated owned
fixture. Freeze all three scenarios before execution, preserve all outcomes and
stop on unexplained failure. It can support current-build acceptance while
CALL-CONNECT01 remains an explicit historical unknown. No new diagnostic seam or
Android version is justified before a failure requiring it. This matrix is NOT RUN
until relay gates pass; another identical short A/B is not useful evidence.

## Credential compatibility — measured reader implemented, runtime acceptance pending

Two earlier inert system-manager positive cases stopped and remain preserved.
The parent subsequently executed the approved unchanged-guard diagnostic exactly
once. The delivered synthetic descriptor was root-owned0440, regular, one link;
`credential_descriptor` rejected it. Owned units/sources were removed and scoped
neighbor properties were unchanged. The helper did not measure ACLs or prove
effective in-process confinement. Do not repeat that completed diagnostic.
[The source-bound record](../project/evidence/voice-ready-20260910/parent-diagnostic.json)
and [retrieved issue comment](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5614383522)
replace the previous unmeasured-owner/mode hypothesis with observed evidence.

The original architecture review actually used Fable. The later diagnostic/design
review used actual Opus models; its approval of the diagnostic was valid under
the owner's current identity clarification and the accepted independent-AI policy.
Keep actual model provenance, not the requested label. That review's substantive
conditions still require exact file/directory ACL measurement, the fd-only bounded
recognizer corrections, TDD, and fresh final code/artifact review with manifest
re-pin. No speculative0550/0750 directory alternative or blanket0440 acceptance.

The separately reviewed one-unit synthetic metadata measurement completed:
root-owned0550 directory with ACL permissions5/5/0/5/0, root-owned0440 file with
permissions4/4/0/4/0; version2, five entries, named UID1003, all non-named IDs
0xffffffff. File size64/nlink1 and post-inspection metadata stability were observed;
owned cleanup and scoped neighbor readback passed. No credential content was read.
[Actual metadata evidence](../project/evidence/voice-ready-20260910/metadata-result.json).
Post-observation Opus5 confirmation and its five corrections now precede the
implemented dedicated reader. Twenty-two offline descriptor tests pass, including
actual synthetic xattrs with simulated root ownership. The actual inert matrix
has since completed all six cases; persistent production-unit/UID confirmation
remains pending. The repinned credential-only artifact received independent Opus5
approval. Source/master/installer, alpha issuer and Rust issuer policies remain
private0400/0600. The dedicated systemd-runtime reader pins production paths and
distinguishes the exact named-service-UID ACL from ordinary group access. This primitive cannot close TURN-RT01,
TURN-ACL02, real relay lifecycle, full coordinator or current-call acceptance.

## Current production refusal and reproducibility limits

The fixture profile cannot attest a full relay rehearsal. The candidate has no
implemented, independently reviewed full-relay fixture profile and refuses the
mandatory production gate even if supplied a hand-authored PASS record. There is
no force/skip flag. A future source revision needs a permitted isolated runtime
suite and required review before that capability can become available.

Production also requires the retained exact TCP38443 ingress rule as a verified
host prerequisite; it never adopts, adds or deletes messaging firewall rules.
Fresh mode means a new dedicated installation on the selected existing host with
that prerequisite, not arbitrary host/OS provisioning. The same exact rule is
verified during status. Missing prerequisites fail before account/secret writes.

Kit packaging can be reproduced from the exact retained component binaries.
The new offline TURN build has a different native hash from the earlier build
although pinned upstream input archives match; the cause is unmeasured. No
end-to-end compiler reproducibility or unchanged native binary is claimed.

The later targeted fresh-start wrapper fixture completed and cleaned up, but its
acceptance receipt incorrectly called an import-failed offline report PASS. That
receipt is invalid. Original failed output and execution observation remain
preserved; a separately corrected offline invocation does not retroactively
approve the run. Earlier message-phase receipts bind retained passing reports,
but those plain logs do not prove exact offline-tested source identity. Final
structured evidence must keep that uncertainty visible and reject failed reports.

## Owner clarification of independent reviewer identity 2026-09-10

The direct continuation instruction states: “Actual independent Opus review must
be named honestly; original Fable architecture already done, do not turn
modelbranding into an artificial inertdiagnostic blocker.” This supersedes earlier
Fable-only wording for subsequent independent diagnostic/design/code reviews.
It preserves fresh-context independence, all blocking findings, actual tests,
threat analysis, final artifact review and bounded deployment authorization.
No accepted ADR or review outcome is rewritten and no model/provider probes or
guard changes are authorized. [Continuation evidence](../project/evidence/voice-ready-20260910/README.md).

## Actual credential primitive delivery matrix — 2026-09-10

[The source-bound matrix](../project/evidence/voice-ready-20260910/credential-matrix-result.json)
completed all six owned synthetic cases once after independent Opus5 code review
and its required fixture corrections. Both managers accepted valid values before
and after the single planned restart; missing sources failed at243/CREDENTIALS;
malformed64-byte values failed at the actual reader format check. The system
runtime used measured root0550/0440 ACLs, the user manager used private0500/0400.
Cleanup and scoped neighbor readback passed. User-manager results are informational,
not a production entry-point claim. No specific network-denial syscall was tested.
Persistent production unit/UID, full relay lifecycle/packet/CLI checks, coordinator,
CALL-CURRENT01 and deployment are still pending. The old one-unit diagnostic and
metadata observation were not repeated.

The later credential-only rebuild948cec15b9f186a7ddbf has a measured comparison
against9eff656b71da22a57e24: executable code/data sections match; only debug sections
and GNU build ID differ, with debug-line strings equal after build-path
normalization. This narrows the cause for this pair only, without claiming full
bit reproducibility or explaining every earlier artifact pair. The new archive
and source received [credential-only Opus5 artifact approval](../project/evidence/voice-ready-20260910/opus-credential-artifact-review.md.txt).
The artifact is bound by member hashes (`source_dirty: true`); no previous runtime
acceptance is transferred to it. The frozen external primitive matrix expires if
its exact runtime source hash changes.
