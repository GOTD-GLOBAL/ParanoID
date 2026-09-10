# Installer test sequence — proposed, not executed

2026-09-10. Applies to server checkout voice-turn-server-20260909. REQ-DEPLOY-003 (new kit), REQ-DEPLOY-002 (retained same-data update), REQ-CALL-006. Fresh design Fable gate precedes implementation. No tests below are claimed to have run.

## Slice 1: offline kit, configuration, plan and refusal

Write `deploy/test_single_host.py`; first RED is absent coordinated entry point. Use new temporary roots only. Tests must prove semantic properties, not mirror lines:

- Default/missing/malformed receipt prevents mutating subprocess or filesystem before any host side effect; NOT RUN cannot be parsed as PASS.
- Existing-v8 intent requires exact expected release, cluster, TLS/config/unit and UID. Mode error or an existing root in fresh mode cannot select fresh-v2 or replace-v2.
- Duplicate/unknown JSON keys, unsafe units/users/paths/interface/ports, symlink ancestors, hardlinks, extra archive members and modified component bytes reject. Existing unrelated marker files remain byte-identical.
- Plan is deterministic for the same declared intent and exact kit bytes, binds numeric relay UID and both component release IDs; any changed reviewed relevant byte changes plan digest. Plan does not create roots/locks/credentials or invoke systemctl/nft/UFW writes.
- Kit builder preserves earlier source/release directories, uses exclusive new output, contains only exact component files and coordinator allowlist, and has no secret/state/backup/cache members.
- Protected state lock opens no-follow, validates descriptor owner/type/mode/link count, fails on competing lock, never unlinks it. A broken symlink or foreign retained lock fails without replacement.

Record exact RED/GREEN command and output before broadening.

## Slice 2: message worker transaction semantics with ordinary controlled manager

Keep `deploy/alpha.py` unchanged. `single_host_message.py` uses current alpha primitives rather than CLI concatenation. Exact structured request over stdin, strict sanitized response. Controlled manager fixture allows ordinary worker tests without TURN or root service actions.

- Recognize expected old disabled unit/config before touching it. Take alpha operation lock through cutover and recovery; concurrent original alpha update fails lock instead of racing.
- Stop only exact unit; call `switch_v2_locked` for actual backup/stage/pointer; only then add exact voice object and LoadCredential line, keeping base config bytes/values and TLS untouched.
- Old-v8 rollback restores exact disabled config/unit before capability-checking old release; new current data survives. Reject drifted recovery config/unit/release instead of overwriting operator changes.
- Fault injection immediately before/after snapshot, source creation, code pointer, config rename, unit rename, manager reload/start and health. Every post-intent exception returns nonzero and either restores old readiness or explicit failed-stopped state. SIGINT/SIGTERM semantics cannot become successful exit.
- Secret is generated once outside stdout/argv/environment, source has0400/one link; rerun validates equality privately. A preexisting different or unsafe source stops; no overwrite/rotation.
- Pure repeat of committed plan is status verification with no service restart or secret regeneration. Unknown partial transaction cannot route through fresh/reset.

Mocked manager assertions are control-flow evidence only, never actual LoadCredential/lifecycle proof.

## Slice 3: actual owned private PG/TLS continuity

Reuse current modern `deploy/test_v2_update.py` fixture with retained old release and candidate package; create a new private PG16 root on an owned loopback TLS address. This is ordinary messaging testing, separate from denied TURN/auth/ACL operations.

Insert synthetic account/device/conversation/message state, then use coordinated worker's existing-v8 preparation/cutover/reverse code path. Verify encrypted archive is actually restored and ordered rows compared. After candidate switch insert another synthetic row and reverse to old release with issuer disabled; both original and newly accepted rows must persist. TLS key/certificate/pin, config base values, PG system ID and encrypted snapshot identity remain unchanged. Fail candidate readiness and independently fail restore comparison; assert no successful cutover or false completion. All fixture processes must be stopped and own directories retained or cleaned by explicit fixture ownership.

With source preserved and only current supported checks selected, no general server suite re-run is necessary absent change/failure. Existing fourteen historical client failures remain separately visible.

## Slice 4: network helper offline ownership

Another worker may own `single_host_network.py` and test file after Fable review. Test exact nft render, own-host source/destination relay-range exception preceding local-IP deny, IPv6/private deny, output of unrelated UIDs unchanged, and only exact UFW ingress tuples. Verify rejection of unknown table/rule owner, UID reuse, interface/IP drift and delete-by-index. Simulate lost reply/interrupt after nft/UFW write and require readback ownership before subsequent cleanup. No socket, nft write, UFW change or packet probe runs from these offline tests.

## Separately bounded real manager primitive test

The runtime audit proposes new transient inert LoadCredential helpers for system and user managers. It is separate from application worker fixture above and uses no coturn/network. Its real result can support the primitive check only. Root coordinates Fable-gated execution with another agent. Exact relay service credential/lifecycle remains NOT RUN.

## Unavailable full installer acceptance

Full fresh complete install with actual TURN, effective ACL packets, retained expiry/auth/drain, relay CLI/lifecycle and selected relay media cannot be claimed from this test sequence. The prior denied scope must not be hidden in an install rehearsal. A production apply cannot be invoked with synthetic PASS acceptance to make its first rehearsal possible. Resolve isolated rehearsal mechanism in design review; missing permitted actual fixture capability remains explicit and blocks public exposure. Build and final review can preserve a candidate without an active/deployed claim.

## Fable-gated implementation refinement

Fresh A-CONDITIONAL design is amended before code. Immutable per-profile gate lists resolve circularity. Production kit includes both actual components and requires all full runtime gates. Local fixture kit carries its own embedded profile, message component only, no TURN binary/network helper or production unit, existing unprivileged UID, unique fixture names, loopback-only root and addresses, and rejects production markers. Its three prerequisite gates cannot turn into production acceptance. Actual fixture results are labeled message-phases rehearsal only; coordinated-full-rehearsal stays NOT RUN. Test source must demonstrate absence/rejection of production networking paths, not emulate public apply with forged PASS.
