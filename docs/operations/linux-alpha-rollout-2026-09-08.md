---
status: draft
owner: operations
last_reviewed: 2026-09-08
---

# Authorized alpha rollout attempt: blocked and stopped

## Outcome and authority

The exact reviewed native package installed and passed authenticated TLS/database
health on the target host. External TCP/38443 timed out. Read-only firewall
inspection found active UFW, default deny incoming, and no allow rule for 38443.
No firewall rule or neighboring service was changed. The new ParanoID unit was
stopped and disabled, and the account's original `Linger=no` restored. Private
installation data and identities are retained. **There is no working externally
reachable endpoint and no phone acceptance.**

[Owner authorization](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
was freshly fetched through the authenticated GitHub API and attributed to
`martadvix-web`. It covers isolated two-OPPO synthetic-data testing, HTTPS 38443,
separate service/data, unchanged existing services, after safety/rollback checks.
It does not authorize silently widening firewall policy. ADR-0003 applies;
RFC-0009/ADR-0005 remain draft, not production architecture acceptance.

## Source, review and artifact

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

## Actual host checks and execution

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

## Own-change rollback and retained handles

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

Public descriptor, **not presently reachable**:

```json
{
  "server_url": "https://157.180.49.125:38443",
  "tls_spki_sha256": "8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba"
}
```

The descriptor was read over trusted SSH; external SPKI/JVM endpoint verification
was not reached because TCP was blocked. Preserve the identity for resume, but
independently verify it before distributing enrollment information.

## Resume gate and NOT RUN

Obtain explicit owner authorization for a narrowly scoped inbound TCP/38443
firewall rule, including intended source ranges/interfaces. Do not add it from
this document alone or assume phone mobile-network IPs are stable. After authorized
network work, recheck account/host prerequisites, retained installation integrity,
public descriptor and expiry, and re-enable only the retained unit/linger through
the reviewed runbook. Do not rerun `install` over the preserved root. Recheck
external TLS/SPKI fail-closed behavior, authenticated health, systemd restart and
retention before provisioning phones. Further upstream filtering may still block
external reachability; no unsupported promise is made.

NOT RUN: successful external TCP/HTTPS/SPKI or JVM endpoint acceptance, final-unit
restart/crash recovery, phone-client traffic, physical OPPO/Keystore/UI/receipt
acceptance, iOS, reboot persistence, firewall mutation, cross-host encrypted backup
transfer/host-loss recovery, certificate renewal, publisher signatures. No package
upgrade was performed on the final phone installation; native rollback evidence
uses a disposable same-binary fixture, not a future unbuilt release.

Compatible client source documents `org.paranoid.devtext`, ARM64/API 26+, with
explicit HTTPS URL/SPKI and separate Alice/Bob roles. No APK was rebuilt or its
installed signing identity inspected in this attempt. Do not uninstall a
state-bearing app to bypass signature mismatch. Only after endpoint verification:
privately provision each role's token, compare server pin out of band, exchange
and confirm peer public Olm codes, then follow the
[Android guide](../../clients/android/README.md) for synthetic bidirectional text,
one/two checks, receiver offline/reconnect, app restart and no duplicate display.
The earlier local diagnostic APK is not proof of this messaging client.

REQ-DEPLOY-001: native host install/health passed, usable remote deployment blocked.
REQ-MSG-004/V0-14: disposable target native history/restore subset passed, retained
final installation not overwritten. REQ-SEC-001: no credential/key disclosure,
no firewall bypass, no server content keys or production privacy claim.
