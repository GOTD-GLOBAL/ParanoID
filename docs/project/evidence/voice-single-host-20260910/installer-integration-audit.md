# Independent integration audit — pre-fix snapshot, 2026-09-10

Read-only inspection; no product edit, test execution, service/listener action or
network mutation. Installer owns corrections. This report describes the snapshot
read, not a claim that later revisions retain the findings.

Source identities were checked before and after this audit and were unchanged:

- `deploy/single_host.py`: SHA256
  `d89cc12ac44a33e91b841133ce94098c658b06f3b137a849837c0efd75a5b981`.
- `deploy/single_host_network.py`: SHA256
  `a67b89938c05f3e97ff788774b3c46c90956ed78bf7f058819dc97a6b89be121`.

Paths refer to the server worktree
`/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909`.

## I1 — acceptance does not bind the reviewed deployment plan

`single_host.py:208–224` validates only acceptance profile, kit digest, gate names,
PASS values and evidence digests. `plan:459–461` renders the policy from the
runtime relay UID/interface, but neither that policy digest nor the full plan
digest is bound into acceptance. Scenario: an acceptance record reviewed for
specification A can be supplied with a different valid UID/interface B, the same
kit and a newly calculated B plan digest. Both checks pass although the effective
network policy differs from the reviewed/tested plan. Bind acceptance to the exact
plan/config/policy/unit identities, retaining the honest operator-audit meaning of
the evidence hashes.

## I2 — production fresh installation omits messaging ingress

`single_host.py:886–927` creates the fresh messaging installation, then opens
ingress only through the network helper. That helper intentionally supplies only
the three TURN tuples; it does not own TCP38443. Scenario: a supported fresh host
has the required UFW default incoming deny and no existing38443 allow. Installation
cannot make external registration or text reachable. The design assigns the fresh
38443 rule to the coordinator; implement its exact ownership/rollback or refuse
unsupported production fresh activation explicitly.

## I3 — update overwrites an unverified previous system unit

For a changed plan, `apply:852–863` sees a previous active transaction but does
not run its status/system-artifact verification. `preflight` does not validate
previous system unit hashes. `stage_relay:781–788` reads any existing root-owned
unit, checks only that a previous transaction exists, snapshots it and overwrites
it. Scenario: an operator changes the old relay ExecStart or hardening after the
last committed installation. Update silently overwrites that drift, and rollback
may restore/restart the unreviewed bytes. Compare both old system units with the
previous recorded identities before replacement, including immediately before
the write.

## I4 — ownership conflicts pass read-only preflight

`preflight:569–572` calls `network.observe` but does not classify its ownership
against an absent baseline or the current receipt. The first call that rejects an
unowned matching UFW rule or existing `paranoid_voice` table is
`stage_relay:772` via `prepare_receipt`. By then the coordinator has created
accounts/staged the kit and written secret files. Scenario: a foreign overlapping
rule/table exists with no recognized coordinator state; both preflights report
success, followed by a preventable partial installation. Enforce absent or exact
recorded ownership during both preflights before any host mutation.

All four findings were sent to root and installer. They are concrete source
findings at the hashes above, not runtime failure reproductions or claims about
any later corrected candidate. No network or relay acceptance gate is closed by
this audit.

## Failed fixture 4 — retained evidence and definite configuration mismatch

This supplemental read-only inspection concerns the failed, already-cleaned-up
fixture `/var/tmp/paranoid-fixture-cd4b3d37df6c7b8f`; it does not execute a new
fixture, start a unit, inspect secret contents or alter credential validation.
The installer source was being amended during inspection, so the following
retained artifact identities, rather than later working-tree line numbers,
identify the failed candidate:

- Retained kit:
  `/var/tmp/paranoid-fixture-cd4b3d37df6c7b8f-coordinator/releases/c9a0886a061401d594f0`.
- Retained `single_host.py`: SHA256
  `56e10fb62ea4edad079992b59045880df4b1f7cd2c67e1866ba98405364719da`.
- Retained `single_host_message.py`: SHA256
  `064a78b6f10d56962d006321bd0e96847c7fa5c2fc6e531069e62d62effcc7f5`.
- Retained release `releases/4eba2afd548e0666dc24/alpha.py`: SHA256
  `db681763055cd3fbd916f8c4afcab1823de0f6c4c05e107a9cbe60ecf3d11c06`;
  this equals working-tree `deploy/alpha.py` at inspection.
- Working-tree `server/src/main.rs`: SHA256
  `6077732f63af78356ebd443de28e85c9f57f50f6bf16a49d49c5b0430ccb5b38`.
- Working-tree `server/src/voice_turn.rs`: SHA256
  `babc1eace0cb9268357849b3c083a2242860d25ed4ee9ce2f1d435f80ecdeb63`.
- `installer/message-rehearsal-4.log`: SHA256
  `37ae4eddcb76e50255e943faf8409b7e781b375a1ca67d57e386274020841fa0`.

Safe selected journal fields establish fixture profile
`paranoid-single-host-fixture-v1`, address `127.0.0.73`, mode `existing-v8` and
transaction `f70fd500da498074083bb983c86a5e64`. The worker journal remained at
`unit-intent`; coordinator `current.json` records `recovery-incomplete`,
`message_stopped=false` and `relay_stopped=null`. These are retained journal
claims, not an independent observation that a process was running after cleanup.
The rehearsal log reports `FAIL`, `checks=[]`, `cleanup=true`, and both
`firewall_packets` and `turn_runtime` as `NOT RUN`. Its generic final exception
does not preserve the exact original server or systemd failure message.

The retained worker always adds `voice_turn.relay_ip=config.ip` after switching
code (`single_host_message.py:40–44`) and installs the source at line185.
The retained current unit contains `LoadCredential=voice-turn-secret:.../issuer.secret`;
the retained `unit.before` does not. Unit SHA256 values are respectively
`a7cf5eed8ee006615308f5143619160d7840d373937f8f7586418ffcb3807660` and
`0f3c96317754ba693e41ee4946aebc137c60be08242a0fc750ec2e8b11250c92`.

The definite static mismatch is that `alpha.py:224–230` selects public
`PARANOID_MODE=self-service-v2` even for the allowed loopback fixture and forwards
that same address as the TURN relay. `main.rs:124–139` therefore passes
`self_service_local=false`. `voice_turn.rs:30–44,67–76` rejects every `127/8`
relay under this mode before opening the credential. Thus this candidate cannot
start its issuer-enabled server successfully even if user-manager credential
delivery is correct. The log does not establish whether another earlier failure
also occurred, so a **user-manager credential mode/ACL failure is not established**.

Metadata-only inspection of the retained source gives UID1003/GID1004,
regular file, mode0400, nlink1, size64; its parent is UID1003/GID1004 mode0700.
Those are source metadata, not the systemd runtime copy metadata. No secret,
TLS private key, token or full private config was read or emitted.

Root accepted the narrower amended fixture scope: exercise actual messaging
phases with issuer/credential enablement structurally absent; production
configuration remains unchanged. Installer owns that amendment and correction.
This avoids introducing a new alpha/Rust runtime mode exception to satisfy a
fixture. Its evidence must say that issuer delivery, TURN runtime and firewall
acceptance remain untested by this message-only rehearsal. The separate reviewed
inert credential diagnosis addresses runtime credential delivery.
