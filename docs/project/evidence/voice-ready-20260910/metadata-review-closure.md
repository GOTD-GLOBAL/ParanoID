# Opus scope review A closure

Actual reviewer: claude-opus-5; modelUsage additionally lists Haiku4.5 ancillary usage.
Original report/input hashes retained in opus-scope-review. A was CONDITIONAL
with permission to run once after A1–A5 corrections, offline tests and source re-pin.

- A1/A2: instrument uses fixed68 bytes, records 1..8 decoded numeric entries and
  arbitrary version; absent/unsupported/oversized ACL records errno and stat;
  malformed short/unaligned length is retained numerically. Production recognizer
  is still unchanged and any future accepted ACL remains exact44bytes.
- A3/A4: strict fixed failure envelope retained for nonzero exit; per-object
  stat/ACL/recheck stages and closed failure-stage allowlist.
- A5: explicit022 umask, source/helper fd metadata verified and numeric descriptors
  retained before start. Source remains root0400/one-link/64bytes.
- A6/A7: nofollow fd traversal into evidence, mkdir/open/fchown by dirfd; exclusive
  random0600 temporary report, replace by dirfd, no truncation of existing files.
- A8: own stop, readback, guarded source removal and neighbors are independently
  attempted; cleanup errors retained and prohibit a clean exit.
- A9–A11: InvocationID requested; JSON explicitly says confinement requested only,
  never effective proof; redundant stderr override removed; synthetic argv paths
  are explicitly permitted provenance, credential bytes/digests remain excluded.
- A12: four new tests first failed (four actual errors), then all10 tests passed.
  They cover variable ACL shapes, errno outcomes, malformed length and failure
  envelope. Existing content-read/secret-mutation tripwire was expanded.

This is one new metadata measurement, never a rerun of the parent's completed
strict-rejection diagnostic. No relay/network acceptance follows from completion.
