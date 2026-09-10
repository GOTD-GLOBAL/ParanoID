---
status: proposed
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-10
---

# Isolated full voice rehearsal contract

REQ-DEPLOY-003, REQ-CALL-006 and the proposed RFC-0018/ADR-0012 require actual
relay and coordinator acceptance before the already authorized one-host rollout.
This document specifies the implementation in progress. No full rehearsal,
current-call acceptance or deployment has run under this contract.

The independent design reviewer was actual `claude-opus-5`. Its nine substantive
conditions are retained in the voice-ready evidence. Original Fable architecture
review and the owner's operational authority remain valid. Neither AI review nor
an evidence upload is human ADR acceptance.

## Three immutable profiles

`paranoid-single-host-fixture-v1` remains the existing unprivileged, loopback,
message-only profile. It cannot contain relay or network components or enable
the issuer. `paranoid-single-host-v1` retains every existing production gate.

The new `paranoid-single-host-vm-fixture-v1` uses both exact production components,
the same controller, messaging worker, network implementation, source credential
rules, paths, account names and public-IP template. It additionally contains a
fixed fixture runner. Its four prerequisites are design review, source-bound
offline tests, artifact verification and current-boot isolation. It cannot depend
on the full rehearsal or call receipt that its execution must produce.

Before any VM-profile preflight or mutation, a separate boundary must verify guest
root identity, the specific DMI product marker, current boot ID and a root-owned
0400 single-link manifest binding controller, runner and VM kit. It also verifies
absence of network PCI devices and external/default routes, exact guest veth
inventory and namespace/route ownership. The full pipeline explicitly selects
root-owned extraction, production state paths, credential delivery and lifecycle
for the VM profile. The legacy fixture boundary is not relaxed.

## Actual isolation and evidence

The host VM process remains unprivileged with its existing QEMU seccomp sandbox.
It has no network device, disk, host mount, vsock, guest agent or control listener.
Before guest continuation, actual argv, descriptors, PCI and block inventory are
checked. The guest initially has loopback only and no external route. Only then
does it create the exact guest veth pair, move the client peer into its own guest
namespace and assign the two owner-controlled mirrored IPs. The host never
creates a namespace, veth or firewall rule. Guest teardown verifies loopback only.

Relay and client cannot share a local-address classification: the client's route
must be unicast in the relay namespace. Actual turnserver namespace inode and
kernel nft objects must match the namespace and exact installed policy. Every
denied owned sink has a successful control from a different UID to the identical
address and port. Own-host out-of-range denial and in-range allocation exchange
are distinct cases. Bootstrap creates the exact retained-style TCP38443 UFW
prerequisite and verifies the first loopback accepts. No scan or third-party
endpoint is involved.

## Rehearsal receipt binding

Adding an available profile must not reduce the former structural refusal to a
handwritten PASS/hash assertion. The production `coordinated-full-rehearsal` gate
therefore references real `evidence_path` and `fixture_kit_path` files in addition
to its evidence and VM-kit manifest hashes. Before mutation the verifier reads
bounded, trusted report bytes, verifies the complete fixture kit, and binds the
report to the exact production kit manifest and plan being applied. Controller,
messaging worker, verifier, network implementation and both component manifests
must correspond between the verified kits. The production kit excludes runners
and bootstrap code. Neither production nor the message-only profile can be cited
as a full rehearsal profile.

The report names a finite required case set and references contained execution
logs. Each log binds the actual run, boot, fixture driver, both kits and production
plan, retains commands and their output with hashes, and includes the required
case observations. Every reported boot embeds its actual fixture intent and
computed plan; fresh and retained-v8 mode coverage are both mandatory. IP,
service account names, numeric UIDs/GIDs, root and unit match
the production intent. Fixture profile/interface/kit identity differ explicitly.
Retained fixture TLS/database identity hashes describe synthetic guest data, never
copied production keys or history. Every boot additionally references its own
complete initial/final isolation log. The coordinator's terminal rollback state
is preserved: ordinary rollback and failure recovery use separate disposable
guests with distinct synthetic prior identities, never a reset/retry or a made-up
shared fixture plan. Both mode cases are mandatory. Five matching
production relay/issuer gate hashes must equal the verified case-log hashes.
Missing files, wrong hashes, changed components, missing or
failed case observations, a different plan and hash-only legacy receipts fail
before accounts, locks, credentials or rules are written. Unit parser fixtures
are synthetic and cannot be presented as actual execution evidence.

This is root-controlled evidence integrity, not cryptographic remote attestation
against a malicious operator. Actual tool execution records and independent exact
source/artifact/runtime review remain mandatory; file binding cannot manufacture
runtime truth. All prior failures and the INVALID_RECEIPT remain visible.
The boundary derives its isolation digest from normalized current kernel topology;
a matching arbitrary constant is insufficient. Descriptor reads are bounded,
nonblocking and nofollow; the private boundary's0400 mode is checked on the same
descriptor. Exact namespace inventory, absence of physical NIC devices, and
reciprocal veth peer indices are checked in addition to names/PCI/routes. Bootstrap
must invoke a root-owned extracted kit. Receipts have no time expiry; they bind
specific source/artifact/intent/plan bytes. Changing available profiles changes
the plan hash and invalidates old plan bindings.

## Current-call boundary

Defensive relay/coordinator gates may run under TCG with timing bounds labelled
as distorted. CALL-CURRENT01 requires the genuine Android permission observer and
hardware virtualization inside the isolated guest. The separately reviewed,
temporary per-process KVM group may be used only after exact launcher review,
verified privilege drop, unchanged sandbox and actual enabled-KVM readback.
No permanent host permission change or fallback accelerator is permitted.

The finite three-case matrix and unchanged product deadlines are defined in the
[one-host runbook](voice-single-host.md#reviewed-implementation-boundaries).
Historical CALL-CONNECT01 remains open. A concrete failure stops the affected
matrix; correction requires retained evidence, TDD and independent review before
any changed new run. Actual full fixture implementation, exact source review,
runtime results, final review and conditional attended deployment remain pending.

The current candidate implements the verifier/profile dispatch and21 offline
regressions; the separate full runner is still being implemented. Its evidence,
initial guest/PAM/veth/UFW and actual JNI client foundation exists with six offline
tests, but case registration and execution remain unavailable pending completion
and review. The availability
set remains empty and production `apply` still refuses before mutation. Actual
Opus5 implementation review was conditional; its ten corrections and the additional
veth-pair RED/GREEN are retained. The signed205-package guest closure was actually
acquired (850958764 expanded bytes). The base image has since been assembled and
all17100 cpio members verified (3708965338 regular bytes,1591558686 compressed);
The first reviewed KVM observation stopped before guest continuation because its
descriptor auditor omitted the actual read-only vCPU statistics descriptor. Owned
cleanup completed. The metadata-aware correction received Opus5 approval after13
offline tests; one corrected run booted and powered off cleanly. Actual KVM,
no-NIC/no-disk/loopback-only isolation and20 prerequisite commands were observed.
Nested KVM API12 and emulator `-accel-check` were usable; Android AVD/call acceptance
remains unrun. The original failed observation is preserved.
Read-only production metadata confirms message UID1003/GID1004 and interface
enp5s0; relay UID/GID1902 are available, not created.
