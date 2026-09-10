# Final bounded peer audit — frozen candidate, 2026-09-10

Disposition: three concrete candidate blockers below. Production activation is
currently unreachable because the fixed full-relay rehearsal profile allowlist
is empty; these findings do not describe executed production changes. This
read-only peer audit is not the required named Fable review, acceptance approval,
or a replacement for actual relay/network tests. Root and installer were notified
immediately, and root reopened the freeze for a bounded offline correction batch.
This report preserves the **pre-correction** snapshot.

## Snapshot and scope

Every file in `installer/source-freeze.json` matched its recorded SHA256 both
before and after this audit. The freeze file SHA256 was
`1a4087d80968ad31bbd0b220e989f08af2655caea54190cf144ea43c615e508d`.
Paths below are in the server worktree
`/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909`.

| Frozen source | SHA256 |
| --- | --- |
| `deploy/single_host.py` | `ba8c1d70ea5bb4e193538f775db0a7b140d6558874a2e070ff64738b7f611413` |
| `deploy/single_host_README.md` | `67f7cba587bbdb6151288e5cdfd164cc9faa5d082e75ccaa5a5188f4d395f6be` |
| `deploy/single_host_build.py` | `f588c878a9f11d2c825e4444aeee21b23032ec56121a1a5a805c1ded5c1ddd98` |
| `deploy/single_host_message.py` | `7d8fa58e10009c2096ceff9a9906b2d9817dfe786ed18c1834d989fd620234e4` |
| `deploy/single_host_network.py` | `a67b89938c05f3e97ff788774b3c46c90956ed78bf7f058819dc97a6b89be121` |
| `deploy/single_host_rehearsal.py` | `bdae4b26ceb76c8cc14f3bcccf93b4efc02f8b2085d98d16f9f72aaea0e756e4` |
| `deploy/test_single_host.py` | `e868b65fee071cdeab809161a9b633e3936d3cc4dfc26a4c3b3c96dea86207b6` |
| `deploy/test_single_host_credentials.py` | `0fba08ff1b37d6d24102a339a20c713fb4c271dbe5114810fadd076c6af7394c` |
| `deploy/test_single_host_message.py` | `a4b91263fec56153885a6a61a2351f99fbf8e17296a7e758c611ebcb17b5a00c` |
| `deploy/test_single_host_network.py` | `6fd20748cbc65e32f9ec3a91f3bf367761564ffbac10e01d18d37edc490b09c8` |

Inspected coordinator/schema/gates, message worker, packaging, scoped network
ownership/parser/journal, rehearsal implementation, targeted test bodies and
retained results. No tests, units, listeners, network commands, namespaces,
secret reads or product mutations were executed by this audit.

## B1 — production update can retain the old running relay

`single_host.py:895–917` verifies the prior active transaction, but the update
path does not close ingress or stop its running relay. `:949` replaces staged
units/releases; `:959–960` calls `systemctl start` on already-active policy and
relay units. Those starts do not replace the old running process. The following
verification (`:961–965`, `verify_system_artifacts:733–744`, `status:646–649`)
checks an active nonzero PID and new disk artifact hashes, without linking that
PID to the new executable/runtime.

Scenario: after future valid production acceptance, update from release A to B
stages B and reports B active while A's coturn/runtime process remains active.
The message-only update test cannot exercise this missing relay cutover.

Small correction within the existing lifecycle contract: journal intent, close
only prior-owned ingress, revalidate the prior loaded unit/artifact ownership,
stop and confirm zero MainPID/ControlPID before replacing relay units. Then
start/readiness-check the new artifact before reopening. Recovery needs an exact
recorded phase for interruption after the prior stop but before new staging.
An active PID alone must not attest the newly staged executable.

## B2 — base unit hashes do not bind the loaded systemd unit

`single_host.py:733–744` validates the fixed `/etc/systemd/system` unit files but
does not validate the loaded `FragmentPath` or `DropInPaths`. Fresh preflight
`:590–602` also checks only the named base paths. A retained drop-in can override
`ExecStart`, `User`, dependencies or confinement while these base bytes retain
their expected hashes. The coordinator would then start/stop the same service
name or report it verified despite an unowned merged configuration. The message
worker's `verify_fragment:68–72` and alpha `v2_unit:1137–1148` similarly bind a
fragment but do not reject merged drop-ins.

This is supported by the installed primary
`/usr/share/man/man5/systemd.unit.5.gz`: drop-in `.conf` files are parsed after the
base unit, and prefix/alias drop-ins may participate. Checking only a neighboring
`unit.service.d` directory would therefore be insufficient.

The narrow correction is to refuse any effective drop-ins for the owned units
and verify the exact loaded fragment/effective entry/identity before lifecycle
actions and successful status, preserving all foreign files. No adoption,
deletion or broad override support is needed. This finding extends the loaded
configuration proof; it does not negate the fixed prior base-file drift check.

## B3 — recovery reopens ingress before verifying the restored relay

`single_host.py:869–878` restores previous unit bytes, daemon-reloads, starts the
restored relay and immediately opens ingress. It does not perform the forward
path's active/PID check, much less bind the running executable to the restored
artifact. The packaged relay unit uses `Type=simple`; start completion alone
does not establish successful runtime credential/config/listener initialization.

Scenario: the restored relay exits during initialization after `systemctl start`
returns, but recovery opens all owned ingress and records `rolled-back` anyway.
Apply the same verified artifact/readiness proof to restored startup before
reopening. Failure must retain closed ingress and an explicit incomplete state.
Actual relay readiness remains a separate unexecuted acceptance gate.

## Earlier I1–I4 disposition

| Prior finding | Frozen-candidate disposition |
| --- | --- |
| I1 acceptance omits exact deployment plan | Resolved: `validate_acceptance:210–227` binds `plan_sha256`; `plan:453–470` includes complete validated intent and rendered network policy hash. The fixed empty full-rehearsal allowlist additionally rejects every production PASS document. |
| I2 fresh path lacks message ingress | Resolved by an explicit supported-host prerequisite: `require_message_ingress:524–545` requires exactly the retained TCP38443 tuple, and both preflights run it before host mutation. The coordinator does not claim to create/adopt that rule; absent/conflicting ingress is rejected and documented. |
| I3 prior unit drift overwritten | Original base-file issue resolved: prior `status:903`, repeated preflight/status and immediate `stage_relay:825–827` compare old bytes to prior recorded hashes before replacement. B2 identifies the additional loaded/drop-in boundary. |
| I4 network conflicts pass preflight | Resolved: `preflight:600–608` observes then classifies absent/exact recorded ownership before state/accounts/secrets. Existing recognized state also receives full status verification. |

The network module still preserves strict production-only specification,
exclusive table creation, exact semantic UFW ownership, pending-operation
recovery, stopped-relay proof before egress removal and first-rule loopback
precondition refusal. No additional blocker in those unchanged offline contracts
was identified during this bounded audit. Actual nft parsing, kernel behavior,
UFW effects and packet enforcement remain untested here.

## Evidence reviewed and its limits

`installer/final-offline.txt` records51 tests passing (SHA256
`ea1fcb867106965dc3bd7f3b092220f1f84ef085ad5bdd9569b0ea3fb4ad95c9`).
Meaningful negative coverage includes profile/gate/plan constraints, redirected
files and locks, component membership, semantic network collisions, partial
ingress recovery, pending-apply ownership, missing owned ingress and shadowed
loopback acceptance. These tests do not establish B1–B3's actual production
lifecycle behavior and must be extended for the correction.

The actual existing-v8 message-only rehearsal is PASS with cleanup, preserving
cluster/TLS/config identity and a post-update row across rollback, plus verified
encrypted backup and idempotence: `installer/message-rehearsal-5.log`, SHA256
`c63ec36d3eedfcf52cf64655d9d30e8e84b9dbe81452a02821b2abd723cb1de4`.

The actual fresh message-only rehearsal is PASS with cleanup, covering initial
message/private-PG/TLS creation, a different fixture-only controller release,
explicit rollback retaining later data, and one injected failure after actual
candidate readiness followed by exact code/config/unit recovery with all rows:
`installer/message-fresh-1.log`, SHA256
`55ebf565b5aa1cc48fdd4dfa490222911940155025346a9b93bb3d9de06739ae`.

The fixture package excludes relay/network code and production system units.
`single_host_message.py:187–196,261–264` refuses issuer credentials/config in
fixture mode, and the fixture code switch preserves exact config bytes without
enabling `voice_turn`. Both real logs expressly retain TURN runtime and firewall
packets as `NOT RUN`; the injected failure is test-only, outside the shipped kit.
Neither result constitutes production issuer, relay, firewall, call or full
coordinated acceptance. The required named Fable review remains unavailable as
recorded separately; this peer audit cannot substitute for it.
