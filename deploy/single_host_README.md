# Coordinated single-host kit candidate

REQ-DEPLOY-003; existing same-data REQ-DEPLOY-002; REQ-CALL-006; RFC-0018 and
proposed ADR-0012. This candidate is not deployment-ready: required TURN expiry,
ACL packets, actual relay/CLI lifecycle, full coordinated rehearsal and current
call acceptance remain NOT RUN. A successful build is not runtime acceptance.

This offline kit contains one coordinator, its message-user worker, the exact
messaging release and (production profile only) the exact coturn release and
root network helper. PostgreSQL16 executables are a preinstalled prerequisite;
the coordinator manages only the application's private cluster. Python3.12 with
cryptography Cipher/algorithms/modes/AESGCM, OpenSSL, compatible x86_64/glibc,
systemd system+user LoadCredential, nft, UFW, ip/ss, and dedicated account creation
tools are required. No package installer/downloader or shared PG service change.

Production inputs explicitly select `157.180.49.125`, interface, numeric dedicated
UID/GIDs, existing message root/unit, exact kit digest, and `fresh` or
`existing-v8` mode. Existing mode also pins actual prior release/manifest, cluster,
TLS certificate/key/SPKI, config and unit hashes. JSON duplicate/unknown keys fail.
The full schema is executable in `single_host.py:validate_intent`; `plan` prints
all fixed required acceptance gates and a SHA256 of the precise plan.

```sh
python3 single_host.py plan --config /absolute/intent.json --kit /absolute/release
sudo python3 single_host.py preflight --config /absolute/intent.json --kit /absolute/release
sudo python3 single_host.py apply --config /absolute/intent.json --kit /absolute/release \
  --acceptance /absolute/actual-acceptance.json --expect-plan REVIEWED_PLAN_SHA256
sudo python3 single_host.py status --state /var/lib/paranoid-single-host
sudo python3 single_host.py update --config /absolute/next-intent.json --kit /absolute/next-release \
  --acceptance /absolute/actual-next-acceptance.json --expect-plan REVIEWED_NEXT_PLAN_SHA256
sudo python3 single_host.py rollback --state /var/lib/paranoid-single-host \
  --transaction EXACT_CURRENT_TRANSACTION --expect-state EXACT_STATUS_STATE_SHA256
```

Read-only production preflight needs root access to validate retained private
state. Production kit sources must already be root-owned and nonwritable by
service accounts. Acceptance is a privately reviewed, exact artifact-bound audit
record, not cryptographic proof that assertions are true. Every fixed production
gate must actually pass; there is no force/skip flag. Do not author a PASS receipt
for missing tests. The existing host/port authority is conditional on these gates.

The distinct `paranoid-single-host-fixture-v1` kit excludes TURN binaries, network
helper and production system units. It permits only loopback messaging/privatePG
under the current existing unprivileged UID with unique fixture root/unit names,
and refuses production markers. Its three fixed prior gates are design review,
offline tests and artifact verification. Its results establish message-phase
rehearsal only, never full coordinated relay acceptance. No coturn packet/expiry/
ACL operation, namespace creation or shared firewall mutation is part of it.

One global private flock serializes coordinator actions; the message worker also
holds the established alpha operation lock. Code switches use the existing
actual encrypted restore-verified backup primitive; only after its successful
cutover does voice config change. Recovery restores exact old config/unit bytes
before old-v8 startup and retains all current DB rows. Fresh refuses any existing
root and never adopts, discards or resets state. Successful identical apply
verifies state and returns already-applied. Ambiguous partial work requires its
exact retained transaction/rollback, without secret regeneration or deletion.

Relay files/users/credential sources/system unit remain internally isolated.
Policy installs first; ingress opens last. Its root helper owns only the exact
nft table and three tagged UFW TURN tuples; egress denies other local destinations
while permitting same-host UDP relay-range pairs. It does not prove CLI closure.
Stopping the policy unit stops the dependent relay; policy stop never flushes the
firewall. Existing TLS/identity/data, neighbors, DNS and other rules are preserved.
Never expose this candidate before the missing actual acceptance is complete.

The fixture profile also never enables `voice_turn` or creates any TURN credential.
It exercises new message code with the default-disabled issuer. This is a fixed
profile boundary, not a runtime skip flag; actual issuer integration remains a
separate required production gate. Production fresh provisioning currently requires
an already verified exact TCP38443 inbound rule on the configured interface/IP;
the coordinator never creates or adopts that rule. If absent or conflicting,
preflight refuses before mutation. Existing-host delivery retains that rule.

No reviewed full-relay rehearsal profile currently exists. The immutable production
acceptance guard therefore refuses even a hand-authored complete PASS receipt;
message-only fixture evidence cannot be submitted as full-rehearsal proof. A future
reviewed source revision and actual full-relay evidence are required to make that
gate satisfiable. This artifact can plan, inspect and rehearse its message phases;
it cannot expose a production relay.
Production apply reports the fixed `full-relay-rehearsal-unavailable` category with
`mutations: false` and exit status 2 before creating a transaction.

For safe normalized archive extraction, use the exact hashed coordinator file from this candidate:

```sh
sudo python3 single_host.py extract --archive /absolute/kit.tar \
  --archive-sha256 ACTUAL_ARCHIVE_SHA256 --destination /opt/new-paranoid-kit
```

Extraction creates only a new destination, validates bounded regular members and
all hashes, refuses links/traversal/collisions, and normalizes root-owned production
directories to0755, ordinary files0644 and native executables0755. No service starts.
The destination parent must allow traversal by the intended service account.
`plan` and `apply` still require the exact configuration and plan-bound acceptance.

The initial design received independent Fable review. Subsequent independent
reviews use the actual recorded model identity; the owner explicitly accepts
Opus. Credential-only source/artifact review is complete, while full-runtime and
deployment review remain required. Production
update closes owned ingress, verifies and stops the old relay before replacement;
both activation and recovery require the expected packaged executable to be active
before reopening ingress. Loaded unit fragments, merged drop-ins, reload state,
entry points and configured identities are checked; unreviewed overrides refuse.
These added production branches have offline regression evidence only.
Fresh messaging reuses the retained alpha initialization and database primitives,
then links and validates the loaded unit before separate enable/start operations.
It does not use the component's combined enable--now operation. One targeted
message-only fresh execution observed this boundary and cleaned up, but its old
harness incorrectly labeled a failed offline report PASS. Its acceptance receipt
is invalid and remains preserved. Later passing tests do not repair that receipt;
no relay or issuer started. The development rehearsal harness now requires a
structured successful prior offline report with exact commands, exit status,
test count, output digest and source/package correspondence. Raw file hashes
alone cannot authorize a fixture.

The candidate `paranoid-single-host-vm-fixture-v1` profile adds a distinct
root-owned no-NIC guest boundary and binds actual referenced case files, boot,
driver, component hashes and both fixture modes to the exact production plan.
Its fixed prerequisites are design review, offline tests, artifact verification
and current-boot isolation. The full guest runner is not implemented yet; no
full-profile kit or runtime acceptance exists and production availability remains
closed. Production kits exclude the VM runner. Referenced evidence files and a
verified fixture kit are mandatory; a plausible digest alone is insufficient.
See the repository's `docs/operations/voice-vm-rehearsal.md` for the exact current
contract and remaining runtime obligations.
