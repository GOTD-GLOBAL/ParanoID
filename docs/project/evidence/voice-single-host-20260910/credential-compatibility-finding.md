# Inert credential slice: observed failure and source-supported compatibility risk

The first runtime run and the single coordinator-reviewed corrected run both
stopped at the first system-manager positive case. systemd-run accepted each
transient service request and returned0; no success marker appeared within5s.
The first helper output was not retained. The corrected run retained exactly
`credential_validation_failed`; all other five cases were NOT_RUN. Restart,
explicit stop, missing/malformed-source and user-manager acceptance therefore
remain NOT_RUN, not PASS. The failed helpers auto-collected before manager
readback; not-found default properties are not live-service confinement evidence.

Both runs used identical inert helper bytes and mandatory unit properties. The
only intervening correction was the independently inspected fixture directory
chmod and failure-output retention, each with actual offline RED/GREEN. The
corrected root source descriptor was observed as UID0, mode0400, one link,64bytes.
Both exclusively created fixture roots/sources were removed; own unit/runtime/
credential directories were absent; exact nginx/system-paranoid-turn/user-
paranoid-alpha readbacks were unchanged. No production unit was mutated, no new
account created and no TURN/network/namespace/firewall operation was performed.

## Source-supported incompatibility hypothesis; runtime metadata NOT_MEASURED

Installed systemd255 systemd.exec documentation says service credentials are
read-only copies accessible to the unit user and root; it does not promise that
the copied file is owned by the unit user. Upstream v255 implementation:
[Primary systemd credential source](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/exec-credential.c)

`write_credential`, lines176–191, sets0400 then prefers adding a named-user read
ACL when the service UID differs from the manager UID. Ownership transfer is only
a fallback when ACL use is unavailable. Named-user ACL mask bits can consequently
make stat mode0440 while preserving root ownership. This is a specific supported
systemd layout, not permission to accept arbitrary group-readable files.

The inert helper currently requires runtime credential owner equal to codex and
mode0400/0600. It therefore rejects a legitimate root-owned ACL-delivered copy.
The packaged relay loader at deploy/turn/runtime.py:24–27 permits root ownership
but still accepts only0400/0600. Its actual compatibility with the system-manager
ACL layout is unproven and needs resolution before deployment. The issuer loader
at deploy/alpha.py:147–151 has a similar strict mode guard, although a same-UID user
manager does not normally need the named-user ACL branch.

This is a source-supported explanation, not attribution of the corrected runtime
failure: the generic helper failure did not retain which validation stage failed
or the copied credential metadata. Changing validators to accept0440 or any root
file without verifying the exact ACL and private runtime context would weaken the
contract and is not authorized by this finding. No production file was changed.

The smallest next observation, if separately coordinated, would leave every
validator and confinement property unchanged and retain an allowlisted failure
stage plus numeric descriptor owner/mode/link metadata before the helper exits.
It needs no credential bytes, digest, sockets, ACL probe, extra privileges or
alternate execution route. A subsequent production compatibility correction,
if justified by actual observed metadata, requires its own precise descriptor/ACL
contract and independent review. No such observation or correction was executed.

Retained references: runtime/result.json; first-runtime-exit.json;
corrected-once/runtime/result.json; corrected-once/runtime-exit.json;
harness-correction.diff; harness-correction-red.log;
harness-correction-green.log (10 PASS). All relay/CLI/runtime acceptance gates
remain NOT_RUN. No blanket systemd-unavailable or platform-denied claim is made.
