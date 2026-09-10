# Runtime verification capability audit — 2026-09-10

Scope: read-only review of the interrupted TURN worker, retained local evidence,
server/package tests, and local execution capabilities. No source change, service
creation/start/stop, packet test, socket connection, firewall change, namespace
creation, host login, alternate worker/provider execution, or rejected-operation
retry occurred in this audit. These report files are the only new audit outputs.

## Exact retained safety event and its evidential limit

The canonical record is
`/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909/docs/project/evidence/voice-turn-20260910/relay-worker-interruption.json`.
Its original external counterpart is
`/home/codex/paranoid-self-service-evidence/voice-calls-20260909T220516Z/relay-worker-interruption.json`.

It records:

- Time: `2026-09-09T23:54:29.091206+00:00`.
- Worker: `media_discovery`.
- Exact result: `Agent errored: This content was flagged for possible cybersecurity risk.`
- Stage: preparing local relay regression work. No new relay test, patched source
  build, process/listener, or persistent namespace had started.
- Test status: retained-allocation expiry/lifetime-cap RED and GREEN NOT RUN.
- Follow-up: read-only handoff requested; no retry; no running operation or network
  change; no cleanup required.

The retained interruption JSON does **not** identify an individual rejected shell
command, tool-call payload, permission rule, or exact prohibited packet. The audit
did not locate a raw rejected invocation in the bounded evidence files inspected.
Do not invent that missing precision or represent all local tests as prohibited.

The worker's preserved proposal is
`/home/codex/paranoid-self-service-evidence/voice-calls-20260909T220516Z/turn-completion-design.md`.
Its “Required RED/GREEN and actual acceptance” section describes the intended
retained-allocation expiry/cache/refresh/drain tests using owned TURN clients,
short synthetic credentials, and an owned UDP peer; it also proposes namespace
peer-port ACL tests. This gives the task scope, not the exact rejected low-level
operation or a more specific platform reason. The proposed patch/hash metadata
remain next to it as `turn-coturn-expiry.proposed.patch` and `.json`.

The former runtime worker scope must not be reissued to another worker/provider,
or hidden inside a combined installer acceptance script. New placement authority
does not overrule this safety event. Narrow ordinary packaging/controller checks
remain distinct; they cannot close the missing packet/runtime acceptance gates.

## Read-only local capability observations

Commands ran locally in the development environment, not on `157.180.49.125`.

| Read-only command/check | Actual result |
| --- | --- |
| `id` | codex UID1003, GID1004; only codex group |
| `ps -p 1 -o pid=,comm=` | PID1 is systemd |
| `systemctl --version` | systemd255, Ubuntu255.4-1ubuntu8.17 |
| `systemctl --user is-system-running` | manager responds, `degraded` |
| `systemctl is-system-running` | manager responds, `degraded` |
| `systemctl --user show --property=Version --property=Features --property=SystemState` | version255.4-1ubuntu8.17; system state degraded |
| `sudo -n -l` | codex has `(ALL) NOPASSWD: ALL` |
| `sudo -n id` | actual root identity returned, UID/GID0 |
| `sudo -n systemctl show --property=Virtualization --property=Version --property=Features --property=SystemState` | system manager responds; version255; empty Virtualization; degraded |
| `/run/user/1003`, bus, systemd/private access | owned/usable by codex; actual manager calls work |
| `/dev/kvm`, `/var/run/docker.sock` access as codex | no read/write access; neither was opened or invoked |
| available commands | systemd-run, unshare, nsenter, nft, ip, ufw, docker exist; systemd-nspawn/podman not found |
| `/proc/self/status` | no effective/permitted/inheritable/ambient capabilities; NoNewPrivs0, Seccomp0 |
| namespace sysctls | unprivileged_userns_clone1, apparmor_restrict_unprivileged_userns1, max_user_namespaces256587 |
| unprivileged `/proc/1/ns/mnt` readlink | PermissionError; the bounded namespace read stopped there |

The first capability batch's overall shell exit did not summarize every command:
the two `is-system-running` commands returned `degraded`, while subsequent reads
succeeded. The separate manager `show` calls and `sudo -n id` completed exit0.
The namespace-inspection script exited1 on the documented permission error.

These facts disprove a blanket “systemd or local root unavailable” claim. They do
not prove mount/net namespace creation, container isolation, service hardening,
TURN listeners, or firewall enforcement. Passwordless sudo is a capability, not
permission to mutate shared host resources or bypass the interrupted task.
No dedicated disposable VM/container has been proven in this audit. The current
machine is a shared systemd host; any approved local lifecycle work must create
uniquely named owned fixtures and leave unrelated state untouched.

## What existing tests establish

Paths in this section are relative to
`/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909`.

- `deploy/test_turn_environment.py`: offline unit/controller environment tests
  with mocked controller commands. It validates capability mismatches, private
  synthetic credential paths, exact environment forwarding, and the generated
  LoadCredential line. It does not invoke a systemd manager.
- `deploy/turn/test_runtime.py`: two offline tests of secret descriptor guards,
  exact config, private output and clean environment. Its module explicitly says
  “no sockets.” It does not execute the service.
- `deploy/turn/test_package.py`: two offline tests of manifest membership,
  corruption, traversal/link/unexpected-member rejection.
- `deploy/test_v2_systemd.py:22`: actual unique disposable local **messaging** user
  unit, compatible update/reverse update, failed-readiness rollback, retained
  post-update row, PG/TLS/config/identity checks. `:70` checks actual SIGINT/SIGTERM
  after pointer cutover and restoration of old readiness. Neither activates TURN.
- `deploy/test_v2_update.py`: populated real PG, encrypted backup/restore,
  same-current-data reverse code update, wrong cluster/lock/schema refusal,
  retained pin/config and post-update history. It provides reusable existing-v8
  continuity fixtures, not proof of a coordinated new installer.
- `deploy/test_native.py`: historical v0 real PG/TLS lifecycle without systemd.
- `deploy/test_integration.py`: historical v0 real systemd/PG/TLS lifecycle using a
  fixed unit name with an existing-unit refusal. It invokes legacy `install` and
  v0 bearer routes; it is not the modern v2 coordinated-installer acceptance test.

The historical canonical `offline-package-summary.json` records 20 passing
controller/feed/containment tests and four package/launcher tests; relocated native
build/version, package membership, system/user **syntax** and isolated launcher
**check** succeeded. This audit read the evidence and tests; it did not rerun them.

`deploy/turn/runtime.py:74` supports only `check` and `run`, requires the exact
`/run/paranoid-turn` runtime path and non-root UID, and pins the full production
template hash. The unit hardcodes the production release, credential and runtime
paths. An inert helper with a unique runtime directory can verify systemd's
credential primitive but cannot honestly be called the exact relay unit test.
Changing the production template/path to make a local test start would change the
tested contract and must never be slipped into production evidence.

## Genuinely distinct next verification slice

The available managers support attempting an ordinary, no-network credential and
lifecycle integration slice after the installer design review. This was **not
executed** during the audit.

1. Create one private unique temporary root and a newly generated synthetic
   64-lowercase-ASCII-hex source, without printing its bytes; refuse all preexisting
   unit names/paths. For a system-manager fixture, use a unique dynamic identity
   or separately reviewed owned fixture UID. For a user-manager fixture, use the
   existing codex user manager. No production account or unit name is reused.
2. Run an inert, source-hashed helper through real LoadCredential. It opens only
   its own runtime credential, checks descriptor type/link/owner/mode and expected
   content privately, and emits only fixed success/failure categories. It opens
   no network sockets, executes no coturn, and imports no TURN packet client.
3. Exercise actual start/status/restart/stop, missing/bad private source failure,
   and cleanup of that exact owned unit/runtime root. Confirm the secret is absent
   from argv, environment values, emitted output and evidence. Verify identity and
   credential-copy behavior in each manager independently.
4. For the coordinated installer, use existing modern v2 fixture state to test
   plan/preflight/state transitions, retry refusal/idempotence, lock/path guards,
   same-data compatible update/reverse update and interrupted failure recovery.
   Any real messaging fixture socket is a separate explicit local test scope;
   do not silently include it in this inert no-network slice.

This slice is materially different from retrying the rejected retained-allocation
auth/expiry/ACL packet worker. It supplies actual systemd primitive evidence and
installer correctness evidence, while retaining the relay gates as NOT RUN.
It is not an alternate route to execute the previously interrupted actions.

### Concrete inert slice for fresh Fable review; not yet executed

Use **no new operating-system account**. The root system-manager unit uses the
verified existing `User=codex` and `Group=codex` (UID1003/GID1004); its randomly
named service is distinct from every existing unit. The user-manager unit runs as
codex normally. Neither uses `paranoid` or `paranoid-turn` service/account names.

The reviewed runner will select a 128-bit random suffix, create an exclusively
owned fixture under `/var/tmp/paranoid-credential-audit-<suffix>`, and reject any
preexisting path/unit. The system fixture's parent/helper/manifest are root-owned
and nonwritable by the helper; a root-only0700 child holds the root0400 synthetic
secret. A separate codex0700 fixture holds the user-manager0400 source. Both
sources contain only freshly generated disposable test material. Expected secret
digests are used for private comparisons and omitted from published evidence.
No existing secret, account key or relay credential is read.

Two transient units are created sequentially through their actual managers:
`paranoid-credential-audit-system-<suffix>.service` and
`paranoid-credential-audit-user-<suffix>.service`. Use `systemd-run` with
`--collect`; no permanent unit file, enablement, linger or daemon-reload change.
Preflight must read `LoadState=not-found` for each exact name before creation.

The exact reviewed properties include `Type=exec`, `LoadCredential` pointing to
the corresponding private source, a unique `RuntimeDirectory`, mode0700,
`UMask=0077`, `NoNewPrivileges=yes`, `LimitCORE=0`, `TasksMax=4`, `MemoryMax=64M`,
`RuntimeMaxSec=30`, `TimeoutStopSec=3`, and `Restart=no`. The system unit additionally
sets User/Group to codex. `RestrictAddressFamilies=AF_UNIX` and
`SystemCallFilter=~@network-io` constrain the inert helper. Do not create or alter
a network namespace, interface, firewall, listener, ACL, routing table or packet
fixture. If a required inert confinement property is unsupported, report that
property's exact refusal and stop the affected slice; do not silently weaken it.

ExecStart runs the hashed root-owned inert Python helper with `-I -B`. It imports
no networking, coturn, application/server or TURN test code. It opens only its
assigned credential through `O_NOFOLLOW|O_NONBLOCK`, checks descriptor type,
single-link count,0400/0600 mode, runtime owner,64 lowercase hex bytes, and
content against the private fixture digest. It verifies the actual effective UID
and CREDENTIALS_DIRECTORY; it writes only fixed categories and a safe generation
marker in the assigned runtime directory, then stays alive for at most20seconds
without sockets. No secret value/digest enters argv, environment or output.

The parent runner checks the expected safe result, actual manager
`ActiveState/SubState/MainPID`, and private booleans that secret bytes are absent
from only that PID's cmdline/environ and captured output. It performs one explicit
restart of that exact unit, verifies a changed live PID and regenerated runtime
credential, then stops only that unit and verifies no live MainPID, leftover
unit-owned process or credential/runtime directory. No broad process query,
signal, reset-failed, service restart or cleanup pattern is permitted.

Use separate unique transient fixture names for missing-source failure and
malformed-source helper failure. Both must fail without a successful helper
marker or retained process. The outer runner has bounded command timeouts and a
finally block that stops/removes only names and paths it exclusively created.
It retains sanitized commands, service-property readbacks, exit codes, helper
source hash and cleanup results. No whole journal, environment, credential bytes
or unrelated service state is exported.

The parent requested design review before privileged unit creation. Therefore
this subsection is a reviewable plan, **not** proof that its commands or property
combinations work. A passing result would establish actual system/user manager
LoadCredential and ordinary process lifecycle only. It would not establish
coturn's configuration, relay startup, CLI closure, refresh expiry, ACL safety,
production rotation, or complete coordinated-installer acceptance.

## Required acceptance still outstanding

The actual final Fable record inspected is
`/home/codex/paranoid-self-service-evidence/voice-turn-fable-final-20260910T003833Z/attempt-3-focused/review.md`.
Its runtime blocker is at line23 and deployment ACL blocker at line33. Historical
placement-authorization wording is superseded by the new owner confirmation; its
technical missing-evidence findings are not thereby closed.

- **TURN-RT-01:** actual unmodified failure/patched retained-allocation elapsed
  expiry refusal; callback cache race; normal refresh and explicit deletion;
  ChannelData/Send drain; real lifetime clamp cases; measured auth-check-to-grant
  scheduling margin and cleanup. These are the interrupted scope and were not
  attempted here.
- **TURN-ACL-02:** prepared exact dedicated-UID own-host UDP40000–40015 exception,
  refusal of its other own-host destinations, correct live firewall integration,
  and isolated owned packet allow/deny evidence. No rules or packets were tested.
- **Actual relay runtime/lifecycle:** effective CLI closure (5766), exact service
  address-family/capability/memory/resource settings, LoadCredential into the
  actual packaged launcher, startup/readiness/stop/crash/rotation/reverse rollout,
  and correct network/rule cleanup. A helper or syntax check cannot fill this gate.
- **Coordinated installer:** real disposable fresh install and recognized populated
  v8 update, interruption/idempotence/failure recovery, retained TLS/data/identity,
  matching exact artifacts and network policy. Existing component tests are useful
  fixtures, not a completed installer result.

Precise present limitation: the platform-interrupted retained-allocation/ACL
verification has no passing execution evidence and no recovered exact low-level
denial payload; it cannot legitimately be resumed by another worker in this audit.
Local root/systemd primitives are available for independently scoped ordinary
tests. Public relay exposure remains barred until all mandatory technical gates
pass with reviewed exact artifacts. No new broad placement permission question is
justified by these observations.
