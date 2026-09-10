# Code and inert-matrix review closure — 2026-09-10

Actual independent reviewer: claude-opus-5; full modelUsage retained in result.json.
The full report approved Part A code, and approved one Part B run after B1/B2 and
re-freeze. This closure implements those required amendments; it is not a new
review verdict or runtime result.

- A1: added entry-point test for check AND run calling the no-argument strict
  systemd reader before config/exec. Runtime source remains 6122051fb8b3a97b73b143d13a1590667820dd406ab36b62f413a880a4a16799.
  Dedicated suite now 22 tests. CHANGELOG change exists (omitted from review inputs).
- B1: generated helper actually executed offline in two unprivileged owned
  temporary fixtures: private0500/0400 accepted, then owned process stopped;
  malformed64-byte uppercase failed at credential_primitive/format with exit2.
  No systemd, relay or socket action. Six matrix offline tests pass.
- B2: positive live checks persist closed helper output and manager properties
  before validation failures. Failure-only descriptor metadata uses fixed68-byte
  fgetxattr observation (uid/mode/nlink/size/ACL size/errno/entry count), no content.
  Parser rejects extra/non-numeric/out-of-bound fields. The four production
  primitives remain exact AST copies; failure observer is separately named.
- B3: record actual existence of predicted credential directory before live
  validation. No dynamic path acceptance or production override.
- B4: user-manager cases explicitly informational; production is system-only.
- B5: polling parses complete newline-terminated records only.
- B6: retain original review freeze; amended freeze pins driver/helper/log, while
  runtime hash above and all existing strict source/issuer/installer guards stay.

Actual logs: review-closure-offline.json and review-closure-offline-[0,1].log.
No old diagnostic or metadata observation was rerun. The authorized matrix is one
finite new run. Persistent production entry point/UID, relay lifecycle, packet
policy, expiry, CLI closure, full coordinator, current calls and deployment are
not inferred from it. No artifact approval yet.
