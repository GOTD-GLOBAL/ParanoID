---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Self-service v2 threat delta — local server candidate

Scope: [RFC-0012](../rfcs/0012-self-service-messenger.md), draft
[ADR-0007](../decisions/0007-self-service-messenger.md),
[v2 wire contract](../protocol/self-service-v2.md) and
[local server evidence](../server/self-service-local.md#independent-server-review-evidence).
This supplements, not rewrites, the [v0/v1 analysis](server-v0-threats.md) and
[key deployment delta](key-deployment-delta.md). It analyzes implemented local
server controls, not an accepted architecture or a completed application.

## Fresh-only deployment amendment

The later [fresh-v2 candidate](../operations/fresh-self-service-v2.md) adds a separate
explicit exact-IP TLS mode and stopped cluster replacement, not a live deployment.
Owner-supplied deletion/no-backup provenance applies only to the old isolated
server cluster. Loss of those old grants/rows/verification DBs is intentional;
TLS, phone state, socket/locks and neighbors are outside deletion.

SV2-09 (high): unintended deletion/redirection. The controller requires sticky
key-v1, explicit confirmation and PG system ID, canonical private root, exact
public root/IP/SPKI, stopped PG, lifecycle/operation/worker locks, no-follow
regular-tree checks, no hard links/foreign owner/device and no nested mounts.
Sticky v2 intent precedes fd-based deletion of only `data`; repeat discard is
refused. `test_fresh_v2.py` and `test_fresh_guards.py` cover synthetic replacement,
wrong-ID/live/lock/link/mount/root rejection and preserved outside-data sentinels.
The dedicated same-UID operator and artifact remain trusted; malicious concurrent
mount/path changes and forced power-loss recovery are not proven safe.

FV2-R01 closes false-success interrupt handling in the local candidate: the three
fresh-v2 lifecycle operations catch `KeyboardInterrupt`, report a static redacted
fail-stopped diagnostic and exit 130. `test_v2_interrupts.py` sends real SIGINT
at AST-anchored pre-/post-discard and fresh-initialization boundaries, checking
sticky intent, PG cleanup, TLS/neighbor/lock preservation, no backup and refused
repeat discard. No rollback or additional service-manager action is introduced;
an installer interrupted after unit enable requires operator inspection/stopping
of its dedicated unit. Graceful supervisor and legacy CLI handling remain intact.
This is bounded process-interruption evidence, not exhaustive crash recovery or
independent review acceptance; the final rebuilt artifact still needs re-review.

SV2-10 (high): accidental public exposure/downgrade/misleading readiness. Separate
exact reviewed IPv4:38443 opt-in, mandatory TLS, no v1-IP bypass of local v2,
versioned package probes and sticky config preserve older modes. Health adds SQL
version/realm/SPKI/required-column/enabled-guard checks to verified TLS liveness;
not full schema/constraint attestation or E2EE. New bind tests cover the literal
reviewed address without binding it. Packaged loopback tests use three synthetic
proof identities and retained opaque messages across actual supervisor restart.
Old backup/update/switch paths refuse v2; no partial comparison is a v2 restore
guarantee. Real host/systemd activation/reboot and phone acceptance remain gates.
Human risk/disposition owner remains martadvix-web; this analysis is not approval.

Historical local/migration evidence and its limits below remain scoped to those
original tests, not proof of the new destructive path.

## Changed authority and assets

Ordinary signup now depends on root credential validity, fresh device possession
and bounded admission policy, not operator grants. General account/device and
account-pair message state replaces fixed-slot routing. Migration retains old-slot
ownership only through verified existing bindings. The local migration operator
is trusted to select the private database and saved realm/SPKI, not to approve each
new user. Old v1 authority remains historical; its rollout permission does not
permit hosted v2 signup.

Assets: root/device public bindings and revocation tombstones; client-held private
root/auth/Olm/storage keys; pinned server trust; proof nonce/epoch and consumption
state; acknowledged ciphertext/IDs/sequence/dedup; retained legacy rows and current
backups; availability budgets; relationship and traffic metadata. The server holds
public credentials and opaque ciphertext, not private content keys. This storage
boundary alone is not proof of client E2EE or receipt correctness.

## Data flow and trust boundaries

```text
Untrusted client / copied public credential / network attacker
  | root-signed credential or known account/device/fingerprint + request intent
  | pinned HTTPS (actual local runtime: loopback only, bounded TLS sockets)
  v
Server ingress budget -> strict parser -> credential/realm/SPKI eligibility
  | fresh nonce + epoch + expiry + exact purpose/method/path/query/body digest
  v
Bounded in-memory challenge store -> client device signature -> proof verifier
  | invalid proof leaves valid challenge usable; one valid concurrent use wins
  | consumed proof BEFORE DB effect; uncertain outcome needs fresh proof
  v
Private PostgreSQL socket [trusted host/DB owner boundary]
  | synchronous transaction + ss_meta row lock
  | recheck durable binding/mode -> register OR append/retry OR own inbox read
  v
ss_accounts / ss_devices / ss_conversations / ss_messages -> commit -> response
  | IDs, public credentials, graph, ciphertext lengths and order visible here
  | content interpretation and peer delivery receipts remain client-side

Offline trusted migration operator (same process-lifetime lock)
  -> exact supported legacy schema + verified bindings + retained envelopes
  -> one transaction: import + legacy key_meta archive + downgrade guards
  -> v2-aware current-state dump/restore; no stale-backup downgrade
```

Physical phones, saved client snapshots, multi-peer Olm sessions, installation,
public exposure, package/controller update and host lifecycle lie outside the
executed v2 server boundary. The binary uses one host/private socket namespace;
direct router construction is a disposable test facility, not deployment guidance.

## Threats, controls and residual risk owners

Ratings are qualitative impact/priorities, not measured exploit probabilities.
`martadvix-web` is the human residual risk/disposition owner for **every row**, pending
explicit disposition; listing that owner does not accept risk. Delivery roles below
identify follow-up work, not fabricated human delegations or reviewer approvals.
Test labels T01–T19 refer to the exact matrix below; P refers to retained independent
Python/TLS/PostgreSQL probes, not an in-repository regression.

| ID / threat / priority | Implemented mitigation and evidence | Residual risk / follow-up role |
| --- | --- | --- |
| SV2-01: spoofed root/device, cross-request replay or substituted authority; high | Existing root credential verification; v2 LP domain binds nonce, epoch, expiry, realm/SPKI, account/device/fingerprint and exact intent. Device signature, two expiry clocks, atomic one-use removal, durable binding recheck; no bearer fallback. T01–T03, T07–T10, P | No independent frozen v2 golden-vector file. Review protocol composition; security/protocol role. Key theft still confers device authority; no new recovery/rotation API. |
| SV2-02: pre-auth allocation/CPU/TLS exhaustion and Sybil signup; high | 8 new accounts/60s durably metered, 1024-account cap, 16 global/4 account challenges, 2 challenges/account/s, global ingress 20/s and auth 8/s, bounded bodies, 10s handlers; TLS 16 concurrent permits with handshake/stream deadlines and keepalive disabled. T04–T06, T15, P | Global budgets can deny legitimate users. A copied public credential can starve its account's challenge allowance. No fairness, Sybil resistance or sustained DoS/load certification; server/operations role. |
| SV2-03: cross-account inbox access, unsolicited traffic and enumeration; high | Sender derives from proof, inbox filters authenticated recipient; canonical recipient and active-account check, strict input and ciphertext bounds; no directory endpoint. T02–T03, T11, P | No mutual-contact ACL/block/consent policy; any authenticated sender knowing an active ID can submit unsolicited ciphertext and probe existence. Product/security disposition needed; client contact verification does not create a server ACL. |
| SV2-04: duplicate/altered retries, skipped concurrent commits, quota eviction; high | Synchronous transaction under ss_meta lock serializes binding/quota/sequence/effects; acknowledgement after commit. Exact (sender,id) retry first; changed bytes/recipient conflicts. Four storage limits reject without eviction. T11–T12, T19, P | Global serialization/full-table quota aggregates limit throughput. Consumption before DB result means timeout/connection loss needs fresh proof and exact retry. No exhaustive cancellation, commit-response-loss or power-loss/disk-full fault experiment; server/storage role. |
| SV2-05: legacy takeover, revoked revival or partial migration; high | Exact legacy schema comparison plus signature/binding/realm/SPKI/accounting validation in one offline transaction. Approved/pending needs matching device activation; revoked remains tombstoned; unknown roots get empty independent accounts. T13–T16, P | DB owner/host and mapping input remain trusted. Structural comparison does not attest owner/ACLs; mid-migration process kill not tested. Installed client keys/history migration is separate; operations/client role. |
| SV2-06: stale code/dump reopens old authority or loses later history; high | V2 marker rejects historical entry points; retained v0 startup trigger, archived key_meta then version 2 blocks pre-marker startup. Current populated dump/restore retains old and new rows. T13, T17–T19, P | Actual historical executable coverage is unchanged HEAD in v0/key-v1 modes, not every past artifact. No v2 package update/rollback controller tested. Never remove guards or overwrite newer data with stale dumps; operations role. |
| SV2-07: metadata disclosure, hostile operator or client compromise; high | Opaque content only, no content-key API; verified TLS runtime and static errors, no payload/private-key logging added. T11, T15, P provide bounded transport evidence, not a privacy audit | Server/DB owner sees stable IDs, public credentials, graph, IPs, timing, sizes and ciphertext. TLS/E2EE do not hide all metadata or protect a compromised endpoint. Real multi-peer E2EE/receipts, Android storage and phones unrun here; security/client role. |
| SV2-08: corrupted v2 schema or misleading health/readiness; medium | Ordinary startup requires ss_meta version-2 row; no implicit schema initialization. Runtime is locking TLS/loopback with private DB. T15–T16 | Startup does NOT attest the full v2 schema/data fingerprint; /health is liveness only. Corrupted-v2-schema startup tests and stronger readiness remain follow-up, not an implemented fail-closed guarantee; server/operations role. |

## Exact test mapping

All T tests live in [`server/tests/self_service.rs`](../../server/tests/self_service.rs).
Their exact names below are runnable with
`TEST_FILTER=<exact-name> python3 server/check-self-service.py`; the unfiltered
command runs all 19. Requirement associations are server-side coverage only, not
completion of every requirement or the broader RFC acceptance gate.

| Label | Exact executable test name | RFC gate / requirement / checked property |
| --- | --- | --- |
| T01 | `three_accounts_self_register_only_after_device_pop_and_retry_same_identity` | SS-01/02; REQ-ID-001/005/008: three independent accounts, no durable account before device proof, identical retry/replay |
| T02 | `auth_status_is_bound_to_known_device_and_restart_invalidates_proofs` | SS-02; REQ-ID-004/006: known binding, status and restart epoch |
| T03 | `every_proof_field_wrong_signer_and_cross_request_are_rejected_without_consuming` | SS-02; REQ-ID-004/006: all signed fields, wrong signer/body/route, concurrent one-use winner, duplicate registration field |
| T04 | `registration_capacity_rejects_new_accounts_but_allows_fresh_identical_retry` | SS-01/02; REQ-ID-004/008: real account capacity and retry |
| T05 | `new_account_rate_is_durable_across_router_restart` | SS-02; REQ-ID-004: persistent registration window |
| T06 | `unauthenticated_ingress_and_challenge_memory_are_bounded_without_rows` | SS-02; REQ-ID-004: auth/challenge limits before durable allocation |
| T07 | `conflicting_device_binding_is_rejected_without_creating_an_account` | SS-02; REQ-ID-006: duplicate device conflicts without account creation |
| T08 | `durable_device_binding_changes_between_issue_and_use_fail_closed` | SS-02; REQ-ID-006: durable auth-key substitution rechecked at use |
| T09 | `expired_v2_challenge_never_creates_an_account` | SS-02; REQ-ID-004: real 61-second wait, no account, fresh retry succeeds |
| T10 | `fresh_offline_schema_has_no_operator_or_accounts` | SS-01/02; REQ-ID-008: explicit empty initialization, no repeated init |
| T11 | `general_messaging_preserves_ciphertext_ids_and_inbox_history_across_restart` | SS-03/04; REQ-ID-007, REQ-MSG-002/003/004: three accounts/conversations, recipient isolation, cursor, ciphertext/retry; NOT E2EE proof |
| T12 | `ciphertext_storage_quotas_reject_without_eviction_and_retry_still_works` | SS-04; REQ-MSG-004: account/global row/byte limits, no eviction; account-quota exact retry |
| T13 | `offline_migration_preserves_history_and_requires_pending_device_proof` | SS-02/05; REQ-ID-006, REQ-MSG-004: four legacy states, no unknown-root history, marker-aware downgrade refusal |
| T14 | `migration_rejects_ambiguous_schema_and_unbound_state_transactionally` | SS-05; REQ-ID-006, REQ-MSG-004: schema/binding/accounting mutations fail without new v2 tables, old rows remain |
| T15 | `local_tls_mode_requires_single_worker_and_offline_schema_lock` | SS-04/05/06 partial; REQ-DEPLOY-001, REQ-MSG-004: real binary TLS, lock exclusion, SIGKILL/restart inbox, public-bind refusal; NOT package lifecycle |
| T16 | `nominally_empty_database_with_unknown_function_is_not_initialized` | SS-05; REQ-ID-006: unknown function is not fresh storage |
| T17 | `historical_admin_cannot_initialize_legacy_tables_in_v2_database` | SS-05; REQ-ID-006: marker-aware admin refusal before legacy tables |
| T18 | `pre_marker_binary_startup_sql_is_blocked_on_fresh_and_migrated_storage` | SS-05; REQ-ID-006: historical SQL fails in both storage states; NOT an executable build test |
| T19 | `migrated_history_and_post_cutover_message_survive_database_dump_restore` | SS-04/05; REQ-MSG-004: populated PG dump/restore, imported and later rows, exact retries and continued sequence |

P: `independent-server-probes.py`, retained outside Git with
`independent-server-probes.log`, independently signs Ed25519 LP transcripts using
Python `cryptography` and contacts the actual verified local HTTPS/PostgreSQL
runtime. It checks historical executable positive startup controls and downgrade
negatives, original envelope bytes, approved activation/unknown-root isolation,
simultaneous exact retries and distinct commits with one-row pagination,
changed-recipient conflict, malformed cursor/duplicate/unknown fields, body and
ciphertext bounds, absent old routes and bearer rejection. See the
[independent evidence record](../server/self-service-local.md#independent-server-review-evidence)
for provenance and limits. These probes are not claimed as permanent repository
regressions or formal linearizability proof.

## Open verification and disposition gates

- SS-01: server registration/retry passed; client saved-identity/lost-reply/reload
  and storage-failure journey is not established by this server review.
- SS-03/07: real multi-peer Olm, QR/key substitution, authenticated receipts,
  installed Android/iOS and physical two-phone acceptance remain unrun here.
  Opaque server fixtures are not replacement E2EE evidence.
- SS-05: populated DB restore passed; client snapshot migration, forced power loss,
  disk-full, mid-migration kill and exhaustive timeout/transaction-cancellation
  schedules were not run. No recovery/device-add/deletion contract is added.
- SS-06: binary TLS/restart/lock passed locally; v2 package install/update/rollback,
  host migration/reboot, neighboring-service isolation and release provenance need
  separately scoped operational execution. No live host was accessed here.
- Independent runtime review had no runtime blocker but overall failed on SR-01.
  This delta addresses missing documentation; independent documentation re-review
  and owner architecture disposition remain pending. No new approval is implied.
