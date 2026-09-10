# Voice readiness continuation — 2026-09-10

REQ-CALL-006 / REQ-DEPLOY-003, RFC-0018 / proposed ADR-0012.
The current direct owner instruction requires actual delivery with all substantive
review/test gates, and explicitly accepts an independent Opus review as Opus.
It does not authorize relabeling it Fable, repeating the completed diagnostic,
rerouting the rejected worker, changing guards, fabricating receipts or merging PRs.
Existing one-host deployment authority remains conditional on actual acceptance.

[The parent diagnostic](parent-diagnostic.json) records observed root0440 rejection
at credential_descriptor, exact source/result hashes and verified own cleanup.
[The retrieved issue record](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5614383522)
confirms it. This supersedes the prior NOT_MEASURED/NOT_RUN diagnostic status;
it is not runtime credential acceptance or effective confinement evidence.
The original Fable architecture review and later actual Opus supplemental review
remain retained under their actual identities.

Fresh [Opus5 scope review](opus-scope-review.md.txt) conditionally approved the
one-unit observer after concrete corrections. [Closure](metadata-review-closure.md)
and [10 passing source-bound offline checks](metadata-offline.json) preceded
[the single metadata run](metadata-result.json): exact root0550 directory ACL
5/5/0/5/0, root0440 file ACL4/4/0/4/0, five version2 entries, named serviceUID1003,
zero owning-group/other permissions. Own cleanup and scoped neighbors passed.
The helper never read credential content. This proves metadata only; it is not
runtime credential acceptance, effective confinement, relay or deployment proof.

After [independent design confirmation](opus-credential-design.md.txt) and its
[corrections](credential-design-closure.md), the specialized systemd reader now
accepts only the measured root0550/0440 ACL pair or paired service-owned0500/0400.
Generic source/master/installer/issuer rules remain0400/0600. The dedicated
[offline suite passes22 tests](credential-offline.log), including real synthetic
ACLs with explicitly simulated root ownership. The [initial RED](credential-red.json)
and [fixture setup error](credential-green-attempt-1.log) are preserved.
[Associated regression suites](credential-regression-report.json) passed with
source-bound logs and unchanged whole-file/AST guards.

[Fresh independent Opus5 code review](opus-credential-code-review.md.txt) found no
blocking runtime issue; the matrix was conditional on two fixture corrections.
[The closure](credential-code-matrix-closure.md) records those changes and actual
[offline execution of the generated helper](matrix-offline.log). Then the exact
[new six-case inert matrix](credential-matrix-result.json) completed once:
system and user managers delivered valid synthetic values across planned restart,
missing sources produced actual243/CREDENTIALS failures, malformed values produced
actual format refusals. User-manager cases are informational for the system-only
production entry point. Actual process UID/NoNewPrivs/Seccomp and absence of private
material from argv/env/output were checked; network-denial syscalls were not probed.
All owned units/runtime/credential/source paths were cleaned, scoped neighbors
were unchanged. This is PRIMITIVE_MATRIX_COMPLETE, not full relay acceptance.

[The new TURN component](credential-artifact.json) is repinned to release
948cec15b9f186a7ddbf, archive SHA256
0eab990bb9821f7017427d6e7b87deef348b831df6e5a2e57fe5049c35edca83.
Build/manifest/relocated-loader/version verification passed without a listener.
[Native comparison](native-section-comparison.json) observes identical code/data
section bytes; only debug information and GNU build ID differ. Debug line strings
match after build-directory normalization. No runtime receipt is inherited.
[Fresh independent Opus5 source/artifact review](opus-credential-artifact-review.md.txt)
approved this credential-only component and no relay/deployment claim. Package
`source_dirty: true` means correspondence rests on member hashes, not its historical
source_commit. The earlier regression report records the pre-A1 21-test source;
credential-offline.log records the later22-test entry-point suite. The external
matrix and its AST check are frozen evidence, outside CI, and expire on any change
to runtime SHA2566122051fb8b3a97b73b143d13a1590667820dd406ab36b62f413a880a4a16799.
Owner host/port authority is already explicit; the review's closing reference to
unmet authorization does not supersede it. Actual safety/acceptance gates remain.

[Independent Opus5 review](opus-vm-review.md.txt) approved the distinct RAM-only
capability scope after [source corrections](vm-review-closure.md). Actual signed
archive/index/package verification and acquisition of18 Ubuntu packages completed;
no host packages were installed. [One approved VM run](vm-isolation-result.json)
then completed ISOLATION_OBSERVED: live unprivileged TCG argv/fd/PCI/block inventory
before cont, no NIC or guest disk, actual guest loopback only/no external route,
explicit IPv6 state, no production markers, clean poweroff. [Console](vm-isolation-console.json)
and hashes are retained. This is a point-in-time observation, not general QEMU
capability removal or relay acceptance. The prior cloud-image signature URL
refusal remains preserved and was never retried via another tool.

Persistent production unit/static UID, relay lifecycle, CLI closure, expiry/ACL
packets, full coordinator, current calls and deployment remain NOT RUN. A complete
reviewed guest fixture/test profile is the next step; the RAM-only capability
probe contained no relay/server/packet script. Detailed external evidence is
voice-ready-20260910T065350Z under the owner's local evidence directory. All
outcomes, including incomplete reviews and failed session resume, are retained.
