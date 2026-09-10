# Measured credential design confirmation closure — 2026-09-10

Actual independent reviewer Opus5; report in opus-credential-confirmation/review.md.
Verdict CONDITIONAL with five corrections before TDD; all are resolved here.

1. baseline-guards.json is preserved as a historical source snapshot. The executable
   unchanged contract is credential-guard-contract.json: ASTs for read_secret,
   render_config, write_config, child_environment and TEMPLATE_SHA256; other
   source/installer/alpha/Rust files remain whole-file unchanged. Runtime main/new
   dedicated helpers are intentionally changed, never claimed byte-unchanged.
2. Choose removal of the temporary-path production check workflow. Source grep
   confirms plan/preflight do not invoke runtime.py check; only the persistent
   unit invokes run. Builder invokes --version/loader verification, no check.
   README is corrected with the implementation, documenting descriptor-unit tests
   for offline synthetic evidence and check only under exact service context.
3. Select layout by fd uid/mode first. Only the root-owned exact ACL branch calls
   fgetxattr; any ACL error rejects that branch. The service-owned private fallback
   has no ACL lookup. No mixed pair accepted.
4. Directory size/nlink are never matched to observed60/2. They are only compared
   self-to-self during the recheck; only the file requires64 bytes and nlink1.
5. Add all named negatives: 52-byte ACL/ERANGE, wrong named UID, permuted identical
   set, MASK5, both mixed pairs, inode/ctime races, in addition to earlier cases.

Residuals retained: root can replace mounts; nofollow does not stop malicious root.
The transient codex measurement is not the exact persistent production unit/user.
Inert user-manager and persistent system-unit evidence remain needed, bounded by
reviewed owned scope; no production runtime acceptance from offline tests.
Systemd layout drift fails closed and requires exact owned metadata measurement
and fresh design/code review, never mode broadening or secret fixup.
All relay/installer/current-call/artifact/deployment gates remain mandatory.
