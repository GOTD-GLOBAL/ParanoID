# Independent Opus 5.5 r3 review

Runtime modelUsage confirmed claude-opus-5-5. Supplied-text review, no tests or tool execution.
Original report retained verbatim as text below. R2 reviews 39e6d8f; R3 reviews
its N1–N3 correction delta, not the later implementation.

````text
**Verdict: APPROVE_FOR_LOCAL_IMPLEMENTATION**

This review covers only the pasted diff. I did not verify `program_info`, run lints, or run tests. I'm relying on the coordinator's check of `sbf_size=73800`. This approves local implementation only. It is not an ADR disposition, a human approval, or deploy authorization.

## Blocker closure

**N1: identity-only lookup and no pre-RPC cross-membership oracle. Closed.**
- Inspect looks up only by `(genesis, program, identity PDA)` derived from the verified owner. It never looks up by name, device or Olm digest.
- Before RPC, hints are limited to the proven owner's own state: retry, banned, generation, cooldown, cap and retired candidate.
- Name and binding uniqueness are checked only under the final `ss_meta` lock, after registry verification. A name collision returns generic `identity_invalid`.
- The equivalence between a foreign name and an absent random name is stated and covered by AUTH-03.

**N2: start budget, call order and size cap. Closed.**
- The budget is 8 starts per fixed 60-second window, with no per-identity or per-IP map. Starts are consumed on failure, 429 is returned before any RPC, and the semaphore permit is taken without waiting before a token is spent.
- Clock rollback fails closed.
- The PDA pair is fetched and validated first; genesis and loader/ProgramData checks follow. No success is returned before all checks pass.
- The cap is derived from the pinned size: `4*ceil(73845/3) = 98460`, plus 16384 for the envelope, gives 114844 bytes. Other responses are capped at 65536. Caps apply while streaming, before JSON decode.
- The remaining DoS risk is disclosed.

**N3: fixture-only ban and Sybil disclosure. Closed.**
- Ban is fixture-only and no operator API or tool is delivered.
- The active→banned effects are specified: taken under `ss_meta`, bindings made inactive, push tokens deleted, sessions invalidated and waiters notified, grants blocked. Status and inspect still report banned. All eight reserved slots are retained.
- Sybil exhaustion of the 128 memberships and monopolization of the challenge pool and start quota are disclosed in both the ADR and the threat doc. Owner disposition is required and public rollout is excluded.

## Non-blocking items to fix during implementation or before merge

1. **Markdown lint will likely fail.** Both the ADR and `identity-login-v3-threats.md` add two consecutive blank lines after the new paragraph, which triggers MD012. Several edited lines in `identity-login-v3.md` are also much longer than the surrounding wrap and may trip MD013, depending on config.
2. **ProgramData length is ambiguous.** State whether 73800 is the ELF length or the ProgramData allocation (`max_data_len`). If the program was deployed with a larger `--max-len` or later extended, the account is larger than 45 + ELF size. The cap would then reject valid responses. That fails closed, so it's an availability problem rather than a security one. Specify an exact account data length check and pin `encoding: "base64"` (not zstd), so the formula stays valid.
3. **Post-RPC binding collisions are unspecified.** Only name collisions are mapped to `identity_invalid`. Collisions on device UUID, Olm digest, auth key or credential fingerprint after RPC could still be a distinct error. That would let any holder of a free Devnet identity probe other members' identifiers, at a cost of one start each. Either map them to the same generic error or add this to the disclosed residuals.
4. **Challenge consumed before a possible 429.** A request can burn its v3 challenge and then hit 429 on the start budget. This is acceptable, but add it to the AUTH-03 capacity tests.
5. **Stale "locked owner" wording.** Inspect is now lock-free. Check that AUTH-04's "status with … locked owner" still describes the intended status path and doesn't imply that inspect takes a lock.

**Next step:** fix item 1 so lint and CI pass, clarify item 2 in the protocol doc, then start the local implementation against AUTH-01..05. Owner disposition of self-admission and the DoS residuals remains pending and must not be marked as recorded.
````
