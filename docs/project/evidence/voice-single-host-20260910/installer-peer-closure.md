# B1–B3 bounded closure review — 2026-09-10

Scope is limited to the three findings in `installer-final-peer-audit.md`.
No new whole-system review, product edit, unit/listener action, network command,
credential observation or test run was performed. This is peer source/evidence
review only, not named Fable approval or production acceptance.

## First correction snapshot

The following hashes matched before and after this bounded source read:

| Source | SHA256 |
| --- | --- |
| `deploy/single_host.py` | `66d85829448a6f98819d9973abc5114c13a2803e27d5f05974c6694169c49a9f` |
| `deploy/single_host_message.py` | `e607f2666e5d4e976e3cc1e5165bc481aceb9276e7c6a1fb83a6e3a69c669c7a` |
| `deploy/test_single_host.py` | `482cdd4df98375f6fcc7b92380a1fb33e2fd554e419370abfbc98afcea1552fd` |
| `deploy/test_single_host_message.py` | `ce817886329e3202c9238c32e738dbdc73de5ae99d5327503be94328862cc0f1` |

`installer/final-offline-2.txt` records54 passing offline tests. The added cases
exercise refusal of drop-ins/stale-manager state/wrong loaded identity or argv,
ordered previous-relay ingress closure/stop/readback, and no ingress reopening
when restored-runtime verification fails. Commands are mocked in these cases.

B1 is corrected in the inspected source: `single_host.py:1048–1057` records
`prior_relay_stop_intent` before quiescing the old relay, then stages new relay
units only afterward. `quiesce_previous_relay:761–769` verifies prior artifacts
and loaded units, closes exact owned ingress, stops, and requires inactive/failed
with MainPID0 and ControlPID0. `recover:936–940` recognizes an interrupted prior
stop before staging and restores the prior exact relay through its own recorded
kit. A partial staging failure still fails closed into retained recovery state
if current artifact authority cannot be established.

B3 is corrected at the requested bounded process-identity level:
`restart_previous_relay:806–814` verifies restored artifacts, applies policy,
starts units, and calls `wait_relay_active` before opening ingress.
`wait_relay_active:772–803` requires the manager's active MainPID, the exact
release `bin/turnserver` kernel executable link, matching root-owned single-link
regular executable bytes, and a repeated same-active-PID observation. The
packaged runtime uses direct `os.execve` of that `bin/turnserver`. The claim is
explicitly only **active packaged executable**, not CLI, listener, packet,
credential-lifecycle or call acceptance. Those mandatory real gates remain open.

B2 is partially corrected: the closed loaded-unit property schema validates
exact fragment, empty effective DropInPaths, NeedDaemonReload=no, expected argv,
and explicit system User/Group. Existing message preflight/status, update and
recovery use the new guard. However, the first correction snapshot still starts
fresh system policy/relay at `single_host.py:1067–1068` before its first loaded
guard inside `wait_relay_active:1069`. Fresh messaging similarly calls
`alpha.install_v2` at `single_host_message.py:236`; that controller invokes
`enable --now` internally before the later worker guard. Therefore first-start
drop-ins can execute before rejection. Root and installer were notified; B2
requires the guard at each first-start boundary before this snapshot can be
declared closed.

Production remains rejected by the empty fixed full-relay rehearsal-profile
allowlist. This report does not change that boundary or the separate named-model
capability failure.

## Pre-edit first-start correction outline

Root selected a guarded fresh primitive wrapper so the authorized fresh path is
preserved. The outline was reviewed before implementation. It reuses alpha's
existing initialization/TLS/DB and stage/point/fresh-v2 primitives and modifies
only coordinator sequencing: initialize the exclusively new root; stage/point
under the existing lifecycle lock; run `fresh_v2` with its existing internal
operation/lifecycle locks; then hold the operation lock while writing the exact
unit, verifying it, linking without starting, daemon-reloading, validating loaded
authority, and separately enabling/starting with health verification. The global
coordinator lock remains held. There is no alpha API/source change, monkeypatch,
new DB algorithm or credential exception.

An initially proposed outer operation lock was corrected before editing: that
lock requires the initialized root, and `fresh_v2` itself acquires the same lock,
so nesting would fail. The accepted sequence preserves the original primitive
locking and uses no recursive flock. A negative offline case must show that a
loaded-unit rejection permits neither enable nor start. For system services,
the exact loaded-artifact guard must run immediately after staging/daemon-reload,
before the first policy/relay start. Final implementation/test correspondence
and after-hashes are still required to close B2.

## B2 source closure, with separate evidence correction

The first-start code now matches the reviewed outline. Source hashes below
matched before and after the final bounded read:

| Source | SHA256 |
| --- | --- |
| `deploy/single_host.py` | `0c5564208cd724ea5c4dec8e284d11641faacb80a054ca224262101465e55dab` |
| `deploy/single_host_message.py` | `cb40c3fba427e64e791bf2a10dc84373aad5a635cc9c2db1abb3190426cb6b32` |
| `deploy/test_single_host.py` | `482cdd4df98375f6fcc7b92380a1fb33e2fd554e419370abfbc98afcea1552fd` |
| `deploy/test_single_host_message.py` | `63710dd1cbf4b0ed23c62e4755f53ab3cceeab585c256c7b0c1132872d0983f9` |

`single_host.py:1057–1058` now verifies exact system artifacts and loaded units
immediately after staging, before message or system activation. The guarded fresh
wrapper at `single_host_message.py:231–250` uses the approved primitive and lock
sequence, links/reloads, verifies loaded authority at247, and enables/starts only
at248–249. `apply_fresh:258` uses this wrapper. The added negative test verifies
that a guard rejection causes neither enable/start nor health calls; the positive
test asserts guard-before-enable/start ordering. This closes B2 at the source
contract level without changing alpha or credential predicates.

The actual owned stopped-unit link/readback/unlink record at
`installer/message-loaded-authority-positive.json` validates the manager's
property serialization against the strict guard, with no enable/start/restart,
source change or neighbor state change. The targeted fresh runtime record shows
successful execution and cleanup, but its acceptance receipt is invalid: its
offline PASS entry cites a failed log. See `installer-evidence-correction.md` for
the exact reconstructed receipt, preserved failed bytes, prior-rehearsal binding
audit and explicit UNKNOWN offline-tested-source correspondence. **Do not cite
the targeted fresh run as valid acceptance or grant retrospective credit.**

All three source findings are addressed in this candidate. This statement is
limited to inspected code ordering/ownership and preserved observations; it is
not named Fable review, valid full rehearsal acceptance or production readiness.

## Final candidate correspondence

The later final coordinator SHA256 is
`2e0869b1401f55f814ec3cdd1b21f0db22a347373d4904fb58e66c30c7bfc164`;
worker remains
`cb40c3fba427e64e791bf2a10dc84373aad5a635cc9c2db1abb3190426cb6b32`.
Both hashes matched before and after this final bounded read. A direct source
diff against the inspected0c556420 coordinator shows only the typed
`FullRehearsalUnavailable` exception, its explicit early production guard and
redacted pre-mutation CLI error. B1–B3's corrected source is unchanged.

`installer/final-structured-offline-1/report.json`, SHA256
`756ead82450cb4daf6b35bc7294e55bb639151d098ebbec5bc8284f228f57fc0`,
records the actual unittest-discovery command, exit0,59 tests and PASS. Its
tests.log SHA256
`739daade21b80f556868b6a7a3f8b0f5731b5c81ef03381fc3690284bded49cf`
matches retained bytes, whose summary is59 tests/OK. All ten reported source/test
hashes match the files inspected. This is a later honest offline observation;
it does not replace the failed prior report in any runtime receipt or repair
the historical invalid acceptance. No additional runtime was replayed.

The original B1–B3 code corrections are acceptable for candidate freezing with
these explicit limits. Named Fable review and required real production acceptance
remain incomplete; no deployment or relay exposure follows from this closure.
