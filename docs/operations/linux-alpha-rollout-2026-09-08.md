---
status: draft
owner: operations
last_reviewed: 2026-09-08
---

# Authorized alpha rollout: retained-service resume succeeds

## Current outcome and authority

**The retained alpha now runs at `https://157.180.49.125:38443` and passed external
pinned TLS health and negative pin/auth checks. Physical OPPO acceptance is unrun.**
The initial firewall-blocked attempt stopped its unit and reverted linger without
changing firewall policy. Its historical evidence is retained below. The subsequent
owner authorization in the current 2026-09-08 Telegram turn explicitly permits
inbound TCP 38443 from any IPv4 source on the public IPv4 interface and resume of
the retained dedicated service, leaving other rules/services unchanged. No Telegram
permalink is available to this tool context; none is invented or substituted with
an unrelated GitHub approval. This operational scope does not accept a production
architecture or authorize release, merge, phone-state resets or cloud changes.

At `2026-09-08T17:04:34Z`, exactly one destination/interface-specific IPv4 UFW rule
was added and the retained unit/linger resumed. Original config, TLS key/cert,
release pointer and database identity were preserved. No real admission credential
was exported, printed, added to process arguments or committed. External tests used
public health and deliberately invalid auth; authenticated DB health ran on-host.

[Owner authorization](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
was freshly fetched through the authenticated GitHub API and attributed to
`martadvix-web`. It covers isolated two-OPPO synthetic-data testing, HTTPS 38443,
separate service/data, unchanged existing services, after safety/rollback checks.
It does not authorize silently widening firewall policy. ADR-0003 applies;
RFC-0009/ADR-0005 remain draft, not production architecture acceptance.

## Resume preflight and exact authorized changes

At `2026-09-08T17:03:25Z`, read-only SSH verified uid 1003/gid 1004, no unrelated
account workload, no 38443 listener, inactive/not-found unit, and `Linger=no`.
`ip -4 -o address show` showed `157.180.49.125/32` on `enp5s0`;
`ip -4 route get 1.1.1.1` returned gateway `157.180.49.65`, device `enp5s0`,
source `157.180.49.125`. UFW was active with incoming/routed deny and outgoing allow;
no 38443 rule existed. Retained package installation/config validation, current and
staging manifest/component equality, and exact generated-unit comparison passed.
`systemd-analyze --user verify` passed. Root is 0700; config and TLS key are 0600.
The existing certificate has IP SAN `157.180.49.125`, validity
`2026-09-08T16:41:17Z` through `2026-12-07T16:41:17Z`, and the expected SPKI below.

Executed as `paranoid` with the runbook's temporary-agent strict SSH procedure:

```sh
sudo -n ufw allow in on enp5s0 proto tcp from 0.0.0.0/0 \
  to 157.180.49.125 port 38443 comment 'ParanoID authorized private alpha'
sudo -n loginctl enable-linger paranoid
systemctl --user enable --now /home/paranoid/paranoid-alpha/paranoid-alpha.service
python3 /home/paranoid/paranoid-alpha/current/alpha.py health \
  --root /home/paranoid/paranoid-alpha
```

UFW returned `Rule added`. Comparison of before/after verbose rule lists proved
all previous entries/defaults retained. SHA-256 comparisons proved byte-identical
`user6.rules`, `before.rules`, `after.rules`, `before6.rules`, `after6.rules`,
`/etc/default/ufw` and `/etc/ufw/ufw.conf`. No IPv6 38443 rule or provider/cloud
change was made. UFW remains enabled, default-deny inbound. The added rule was
number 6 at final inspection, but rollback must use its exact specification,
not a potentially renumbered numeric index.

The only new user-unit links are `~/.config/systemd/user/paranoid-alpha.service`
and its `default.target.wants` link, both pointing to the retained unit file.
No install/init, release update, TLS rotation, credential regeneration, database
reset or phone enrollment command ran.

### Exact rollback, not executed after successful resume

```sh
systemctl --user stop paranoid-alpha.service
systemctl --user disable paranoid-alpha.service
systemctl --user daemon-reload
sudo -n loginctl disable-linger paranoid
sudo -n ufw delete allow in on enp5s0 proto tcp from 0.0.0.0/0 \
  to 157.180.49.125 port 38443 comment 'ParanoID authorized private alpha'
```

This reverses only this resume's unit/linger/rule changes. Preserve the root,
configuration, TLS, database and staging recovery copy. Recheck that no 38443
listener remains and existing services/rules remain unchanged. Do not disable UFW,
restore a global firewall snapshot, remove other rules or delete persistent data.

## Actual resume verification

From the separate Hermes build host at `2026-09-08T17:05:33Z`, curl used the public
certificate obtained over trusted SSH, exact IP verification and the independently
supplied pin; no `-k`, redirects, proxies or real admission tokens:

```text
health: {"protocol":"paranoid-dev-v0","status":"ok"}
200 157.180.49.125 0
missing auth: {"error":"unauthorized"}
401 157.180.49.125 0
invalid auth: {"error":"unauthorized"}
401 157.180.49.125 0
wrong pin: curl exit 90, curl: (90) SSL: public key does not match pinned public key
PASS: external certificate/IP/SPKI validation, health 200, missing/invalid auth 401,
      mismatched SPKI rejected; no real credentials exported
```

The trailing columns are HTTP status, remote IP and `ssl_verify_result`. Requests
were GET `/health` and `/v0/messages?after=0&limit=1`; invalid auth used the literal
noncredential `synthetic-invalid-not-an-admission-token`. Correct curl pin:
`sha256//iqWUqRSPYQ2p3mcdfHrnxpDmceU+sOijuTG+64iJcLo=`; the rejected pin was
32 zero bytes encoded as base64. Curl used `--noproxy '*' --connect-timeout 10
--max-time 15 --cacert PUBLIC_CERT --pinnedpubkey PIN`.

The repository's unchanged real `PinnedTls.java` and `PinnedEndpointSmoke.java`
compiled with local `javac` (deprecation note only) and ran against the public URL:

```text
PASS: Android PinnedTls JVM adapter accepts native Rust TLS SPKI, rejects wrong pin
```

This is Linux JVM execution of the Android TLS adapter, not OPPO runtime evidence.
The later combined external curl/JVM repeat after restart was held by the tool's
raw-IP URL approval gate and did not run; it is not falsely marked passed. Parent
independent post-restart public verification is still required. The successful
external runs above preceded restart; final on-host health below followed it.

The final enrollment installation had **0 envelope rows and 1 room-state row**.
Without inserting records or consuming phone sessions, the verifier compared every
ordered envelope/room-state row and retained identity bytes around these actions:

```text
PASS: explicit dedicated-unit restart 3648091 -> 3650640;
      authenticated DB health and complete ordered rows unchanged
PASS: killed only dedicated server child 3650652;
      automatic supervisor restart 3650640 -> 3650761;
      authenticated health, ordered rows, config/TLS/current unchanged
```

The supervisor's actual `Restart=on-failure` path ran; `NRestarts=1`. This proves
restart against original empty enrollment state, not populated phone history.
For populated history, the unchanged remote disposable `test_native.py` ran with
`PARANOID_ALPHA_ARTIFACT` selecting the retained archive and bytecode disabled:

```text
Ran 1 test in 2.342s
OK
PASS: real archive/PG16/TLS/auth retry/live lock; same-binary update/code rollback
retain post-update history; two dump/restore/full-row comparisons;
unchanged TLS/config; no systemd
```

That isolated fixture cleaned its own cluster/processes, not retained state.
There was no final-installation update or messaging write. Full V0-14 receipt-state
or host-loss recovery remains unproven.

### Final live handles

At `2026-09-08T17:06:48Z`, after closing earlier SSH sessions and reconnecting:

- `paranoid-alpha.service`: enabled, active/running; supervisor PID **3650761**,
  server PID **3650773**, private PostgreSQL parent PID **3650763**.
- Cgroup: `/user.slice/user-1003.slice/user@1003.service/app.slice/paranoid-alpha.service`.
- Listener: only `157.180.49.125:38443` for this service; `Linger=yes`.
- MemoryMax 536870912, TasksMax 128, CPUQuotaPerSecUSec 1s.
- `PASS: TLS authenticated database readiness`.
- Nginx PID 4077836, Docker PID 1386, PostgreSQL aggregate unit MainPID 0;
  all active and their activation timestamps unchanged from preflight.
  Nginx: September 1 06:28:00 CEST; PG: August 25 06:35:53 CEST;
  Docker: August 25 06:35:56 CEST. No neighboring restart/configuration occurred.

Private credentials remain only at `/home/paranoid/paranoid-alpha/config.json`
(0600). Public descriptor lives at `tls/public-connection.json` under that root;
public values below are unchanged. The recovery controller remains under
`/home/paranoid/paranoid-alpha-staging-20260908/release`. Process IDs are observed
handles, not promises they never change. No host reboot was attempted.

## Evidence validation and handoff

Only seven Markdown documents changed in the existing
`docs/linux-alpha-rollout-evidence` worktree; application/package code is unchanged.
`npx --yes markdownlint-cli2 '**/*.md'` checked 46 files with 0 issues;
`git diff --check` passed. Changed-document local links: 31 passed. Diff scanning
found no private-key or admission-token patterns. This is local evidence pending
parent review and endpoint verification, not a pushed branch or released build.

Local non-secret verification helpers and public certificate are retained in
`/home/codex/.hermes/profiles/paranoid/cache/` with prefix `paranoid-resume-` for
parent reproduction. The SSH helper uses only the encrypted credential pipe into
a temporary agent and strict existing known_hosts; it stores no private key.
The start helper is deliberately one-shot and refuses an existing 38443 rule;
do not rerun it now. The external helper exports only the public certificate and
uses no valid bearer credential. Restart/start helpers are operational mutations,
not passive checks; do not invoke them as a generic evidence reader.

## Historical first attempt: source, review and artifact

- PR #15: MERGED at `2026-09-08T16:37:28Z`.
- Fetched `origin/main` and live GitHub main both:
  `f8131cd92e9e5945667b0257944552676885455d`.
- Reviewed package source: `bbac867dbf74f4db863dbf9f96dd1b1497ce4ad4`;
  Git tree equality with merged main verified, and range diff empty.
- [Independent review](https://github.com/GOTD-GLOBAL/ParanoID/pull/15#issuecomment-5588484192):
  fresh-context Hermes/gpt-6-astra, no blockers for bounded package publication,
  not a human audit or deployment authorization. Original docs' pending-review
  statements describe preparation before this report.
- All four PR checks SUCCESS: markdown, native-package, postgres-http,
  client-core-and-tls. API ruleset list was empty; these are observed CI results,
  not a claim that branch protection requires them.
- GitHub CLI: `/home/codex/.local/bin/gh`, existing Gorynya installation-bot
  authentication unchanged. `GET /user` returned 403 for the installation token;
  repository, comment, PR and ruleset APIs succeeded.
- Archive: `paranoid-alpha-605c9d469926f666042f-linux-x86_64.tar`.
- SHA-256: `1ca65db749cfa64b775caf8674915c370a48cfc438ad9386a0a7ca1f8f667bed`.
- Original artifact directory:
  `/home/codex/projects/paranoid-worktrees/linux-alpha-deployment/dist/build-_7w9gsta/`.
- Manifest: `source_dirty=false`, reviewed source above, x86_64, Rust 1.98.1,
  PostgreSQL major 16. Local and remote archive checksum, exact six regular
  allowlisted members, and component hashes passed. No signature or independent
  clean-toolchain rebuild is claimed.

Evidence is recorded on `docs/linux-alpha-rollout-evidence`, a separate worktree
based on merged main. No push, merge, release, repository setting or GitHub secret
change was performed.

## Historical first attempt: host checks and execution

SSH used the production-access runbook's encrypted-credential pipe into a
short-lived ssh-agent, strict existing known_hosts, the public identity file,
and no agent forwarding. No plaintext private key was printed or stored.

At `2026-09-08T16:39:36Z`, read-only prerequisites returned:

- Dedicated `paranoid`, uid 1003/gid 1004; no unrelated account workload observed.
- Linux 6.8.0-138-generic x86_64; glibc 2.39, Python 3.12.3,
  OpenSSL 3.0.13, all six required PG16 tools present at the runbook path,
  PostgreSQL 16.15. Remote `ldd` resolved all binary libraries.
- Root/home ancestors root-owned 0755; `/home/paranoid` account-owned 0750.
- Disk: 174G available, 58% used; available RAM 54931 MiB.
- User manager running, `Linger=no`, 38443 unbound, intended root/unit absent.
- Nginx, PostgreSQL and Docker active, before and after this attempt.

The target ran the unchanged `deploy/test_native.py` with
`PARANOID_ALPHA_ARTIFACT` selecting the transferred archive and
`PYTHONDONTWRITEBYTECODE=1`. Result: **1 test, OK, 2.482s**. Actual disposable
loopback configuration exercised TLS/authenticated append/exact retry, recipient
catchup, stop/start, same-binary update/code rollback, post-update history retention,
two PG dump/isolated restore/full-row comparisons and unchanged TLS/config.
The synthetic cluster/processes were cleaned by the harness. This is not physical
phone E2EE or a systemd restart test; no final phone admission state was consumed.

The only administrative mutation was scoped `loginctl enable-linger paranoid`.
The packaged command then ran:

```sh
python3 release/alpha.py install --root /home/paranoid/paranoid-alpha \
  --ip 157.180.49.125 \
  --release /home/paranoid/paranoid-alpha-staging-20260908/release
python3 release/alpha.py health --root /home/paranoid/paranoid-alpha
```

Results: `PASS: isolated unit enabled and TLS/database ready` and
`PASS: TLS authenticated database readiness`. Service was enabled/active/running,
supervisor PID 3612542, MemoryMax 536870912, TasksMax 128, CPUQuotaPerSecUSec 1s.
Listener was bound specifically to `157.180.49.125:38443`; private PG used only
its isolated Unix socket/data, never the existing database.

From the Hermes host, `curl --noproxy '*' --connect-timeout 10 --max-time 15`
to the HTTPS health URL returned curl 28 after 10002ms. An independent Python
socket attempt also failed (`connect_ex=11`, 8-second timeout). Host-local verified
TLS/authenticated health still passed. `sudo -n ufw status verbose` and read-only
INPUT/ufw-user-input inspection showed default inbound deny, INPUT DROP, and
existing allows for SSH, HTTP/HTTPS and a scoped 18081 rule, but none for 38443.
Other upstream network controls have not been excluded. No TLS trust bypass was
used to turn this external failure into a success.

## Historical first attempt: rollback and retained handles

Executed only for the newly installed unit/account setting:

```sh
systemctl --user stop paranoid-alpha.service
systemctl --user disable paranoid-alpha.service
sudo -n loginctl disable-linger paranoid
systemctl --user daemon-reload
```

At `2026-09-08T16:42:25Z`: `Linger=no`, MainPID=0, LoadState=not-found,
ActiveState=inactive, SubState=dead, no 38443 listener, no ParanoID server or private
PG process in the account process list. Both newly created unit symlinks were
removed. Existing Nginx/PostgreSQL/Docker remained active. No reboot or host-wide
service restart occurred. Ordinary SSH/sudo audit logs and account user-manager/
D-Bus activation are possible side effects; they are not application deployment.

Retained private paths, intentionally not deleted or regenerated:

- `/home/paranoid/paranoid-alpha` (0700): initialized private PG data, releases,
  socket/backups directories, lifecycle lock and original generated unit file.
- `current` selects `releases/605c9d469926f666042f`.
- `/home/paranoid/paranoid-alpha/config.json` (0600): separate private Alice/Bob
  admission credentials. Do not print, commit or put them in command arguments.
- `/home/paranoid/paranoid-alpha/tls/server.key` (0600): private TLS identity.
- `/home/paranoid/paranoid-alpha/tls/public-connection.json`: public descriptor.
- `/home/paranoid/paranoid-alpha-staging-20260908` (0700): verified tar/sidecar,
  extracted six-file release/controller recovery copy, and unchanged public
  `build.py`/`test_native.py` harness sources. No phone keys or token export.

Public descriptor (offline at the first attempt; externally verified on resume):

```json
{
  "server_url": "https://157.180.49.125:38443",
  "tls_spki_sha256": "8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba"
}
```

The first attempt read this descriptor over trusted SSH but could not reach TCP.
The resume verified the same SPKI externally with curl and the JVM adapter.
The parent must independently verify the live endpoint before enrollment.

## Current remaining gates and NOT RUN

The network authorization and initial external verification gates are completed
as recorded above. Do not rerun `install` or reset retained identities. Parent
independent post-restart endpoint verification remains pending; the repeated
combined external check was held by the tool approval gate. Authenticated external
requests with real tokens were not run: only host-local authenticated DB health,
external public health and invalid/missing-auth rejection were exercised.

NOT RUN: phone-client traffic, physical OPPO/Keystore/UI/receipt acceptance, iOS,
host reboot persistence, cross-host encrypted backup transfer/host-loss recovery,
certificate renewal and publisher signatures. No package upgrade was performed
on the final phone installation; native rollback evidence uses a disposable
same-binary fixture, not a future unbuilt release. No cloud changes, push, merge
or release was performed. Evidence awaits parent review before publication.

Compatible client source documents `org.paranoid.devtext`, ARM64/API 26+, with
explicit HTTPS URL/SPKI and separate Alice/Bob roles. No APK was rebuilt or its
installed signing identity inspected in this attempt. Do not uninstall a
state-bearing app to bypass signature mismatch. Only after endpoint verification:
privately provision each role's token, compare server pin out of band, exchange
and confirm peer public Olm codes, then follow the
[Android guide](../../clients/android/README.md) for synthetic bidirectional text,
one/two checks, receiver offline/reconnect, app restart and no duplicate display.
The earlier local diagnostic APK is not proof of this messaging client.

REQ-DEPLOY-001: retained native service, external pinned TLS and dedicated-unit
restart/recovery passed, independent parent recheck pending. REQ-MSG-004/V0-14:
disposable target populated history/restore subset passed; original empty phone
enrollment state preserved through actual restart/crash recovery. REQ-SEC-001:
no credential/key disclosure or server content keys; only explicitly authorized
IPv4 firewall exposure; negative pin/auth tests passed, no production privacy claim.
