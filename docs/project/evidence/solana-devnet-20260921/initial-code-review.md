# Initial independent code review

## Verdict: REQUEST_CHANGES

The program logic is the strongest part of this candidate: the PDA/bump handling, the atomic two-record creation, the vacancy/prefund rules, and the exact-bytes idempotency check all hold up under the cases I could trace, and the LiteSVM suite covers the interesting negative paths. The problems I found are concentrated in the client/Android boundary and in evidence that the RFC itself declares to be a precondition. All blockers below are small, concrete diffs — none require redesign.

---

## Blockers

**B1 — The mnemonic is returned from the native layer on nearly every operation.**
`Command::Identity` in `blockchain/solana/client/src/lib.rs` always includes `"mnemonic": mnemonic(&bytes)?.to_string()`. `MainActivity` calls that op from `describe()`, `fund()`, `check()`, and `register()` — so the 24 words are materialized into an unzeroizable Java `String` plus `JSONObject` internals on app start, on every status refresh, and immediately before signing and submitting. The RFC's stated boundary is narrower: *"mnemonic text necessarily crosses JNI for explicit backup or recovery UI."* As written, the code does not honour the boundary it documents.
*Fix:* split into `identity` (owner / identity / program / genesis) and a distinct `export_mnemonic` op, and call the latter only from `create()`'s backup dialog and `backup()`.

**B2 — The pinned program ID has no stated provenance, and the program is not deployed.**
`PROGRAM = "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas"` appears in `client/src/lib.rs` and again, independently, in `DevnetRpc.java`, and is baked into the signed APK. The RFC says the program keypair is generated privately *before* first deployment; nothing in the reviewed set records whether this address corresponds to a keypair that is actually held offline, or whether it is a placeholder. A candidate pinned to an address nobody controls cannot complete the acceptance goal, and the failed-faucet state means this has never been exercised against a real deployment.
*Fix:* state the provenance in the RFC (held offline / placeholder), and add the release step that updates both constants and the test expectations and re-builds and re-signs the APK after deployment. Add a test asserting the Rust and Java constants match — right now they are two hand-maintained copies.

**B3 — No independent external reproduction of the Solana-path derivation vector.**
`slip0010_published_vector_and_nonhardened_rejection` checks the published SLIP-0010 ed25519 vector (`m/0'/1'/2'/2'/1000000000'` → `3c24da04…`) and hardened-only rejection — that part is correct and genuinely external. But `standard_public_recovery_vector` asserts `3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx` for the all-zero-entropy mnemonic at `m/44'/501'/0'/0'`, and that assertion is only self-consistent: it would pass just as happily against a wrong path or a wrong seed-to-key step. The RFC makes external reproduction a gate *before generating phone keys* ("verify published SLIP-0010 vectors **and** an independent public 32-byte-entropy BIP39/path reproduction").
*Fix:* reproduce that address with a second independent implementation with the derivation path named explicitly, and record the tool, version, and exact command in the RFC or the test comment.

**B4 — `DevnetRpc.program()` does not bind the upgrade authority.**
It checks only that the pinned address is `executable` and owned by `BPFLoaderUpgradeab1e…`. For an upgradeable program whose authority the RFC explicitly names as a threat ("Upgradeable Devnet program authority can change program behavior"), the client will sign, pay, and report a registry result against arbitrary swapped bytecode. Reading the programdata account and comparing the authority against a pinned expected pubkey is one extra `getAccountInfo` and a string compare.
*Fix:* pin the expected upgrade authority and check it in `program()` before any signing path. (Hashing the program bytes against the reviewed artifact is the stronger version — see I1.)

**B5 — Build and pinning evidence is outside the reviewed set, so I cannot approve the candidate as a whole.**
No `Cargo.toml`, Gradle/NDK config, ABI filters, or signing config was provided. That means the RFC's mandatory pins (`bip39=3.0.0`, `ed25519-dalek-bip32=0.3.0`, LiteSVM 0.16.0, platform-tools v1.57, SBF v0), the "no UniFFI or external wallet dependency" claim, and the artifact hashes are all unverified by this review. This is an evidence gap rather than a code defect, but the RFC makes "retain tool/dependency versions and artifact hashes" part of acceptance.
*Fix:* supply the manifests and the recorded hashes for a second pass, or scope the approval explicitly to the source reviewed here.

---

## Improvements (non-blocking)

**I1 — Verify the deployed bytecode, not just its loader.** Fetch the programdata account and compare a hash of the program bytes against the reviewed `.so` hash before signing. This is the client-side half of the RFC's "verify program dump against the SBF" and closes B4 properly rather than partially.

**I2 — The app never rebroadcasts a stored signed transaction.** `sendTransaction` is called with `maxRetries: 0`, and the blockhash is fetched at `finalized` commitment (already ~32 slots old), so a dropped transaction is quite likely to expire. The attempt record already stores the full serialized transaction, but nothing ever resends it. Resending the *identical* signed bytes is safe, does not consume a new attempt, and is the single highest-value reliability fix here.

**I3 — Attempt exhaustion is a terminal dead end, and the UI says the opposite.** After three expired attempts, `check()` reports *"Нет подтверждённой записи. Можно зарегистрировать/повторить выбранный ник"* while `register()` throws `attempt_limit`. Separately, `s.put("name", n)` is never cleared after all attempts expire with no on-chain record, so the identity is locked to one name forever. The escape hatch (uninstall, reinstall, recover from the 24 words) exists but is undocumented in-app. At minimum, make the `check()` message truthful on the exhausted path and document the recovery route.

**I4 — The storage freeze is process-lifetime only.** `DevnetStore.frozen` is an in-memory field. After an ambiguous write freezes mutation, killing and relaunching the app silently resumes from the last committed state — the fail-closed guarantee the class comment claims does not survive a restart. Persist a freeze marker (or a sentinel in the encrypted state) if the intent is a real latch.

**I5 — Stale UI results can overwrite newer ones.** `work()` posts `status.setText(result); enabled(true)` unconditionally. `showWords()` is displayed from inside a running work item, so tapping *"Я записал слова"* enqueues work #2 while work #1 is still finishing; #1's completion then re-enables the controls mid-operation and overwrites #2's status text. The `OWNER` single-thread executor and `synchronized` store prevent data corruption, so this is UI-level only — but it can replace a *"Транзакция отправлена"* message with an older one. A monotonic request token checked in `post()` fixes it.

**I6 — Showing the recovery phrase has no re-authentication.** `backup()` reveals the 24 words on a single tap, and the Keystore key is generated without `setUserAuthenticationRequired`. `FLAG_SECURE` is correctly applied to the activity and both dialogs, which satisfies the RFC's literal wording, but a device-credential confirmation on the reveal path is the normal bar for anything holding an identity key.

**I7 — One faucet attempt, permanently consumed.** `fund()` writes `faucet_attempted=true` *before* the call (correct ordering), but that means any transport failure or `429` burns the only attempt forever, against an RFC that allows "at most three bounded RPC attempts, respecting rate-limit responses." Since `describe()` shows the address, owner-mediated funding remains possible — but allowing bounded retries specifically on `rpc_rate_limit` matches the RFC and costs nothing.

**I8 — `expired()` discards the `getSignatureStatuses` result entirely.** The comment explains the intent (status alone never claims success, and the finalized readback that precedes the call is the real authority), and that reasoning is right — but the call is then pure RPC cost. Either drop it, or use it to distinguish "finalized error" from "dropped" in the status text, which is what the RFC's reconciliation paragraph actually describes.

**I9 — `Identity` derives the identity PDA via `addresses(&public, "aaa")`.** Correct today only because the identity seed ignores the name. If the identity seeds ever change, this silently returns a wrong address rather than failing. Split out a name-independent `identity_address()` helper.

**I10 — `readback()` passes the constant `DevnetRpc.GENESIS` to the native `verify` op**, making that check tautological, while `register()` correctly passes the live value from `rpc.cluster()`. Pass the live value in both.

**I11 — Test gaps.** No case for a missing *payer* signature (only the owner is covered), no `24`-byte boundary name, no tag `0`, and no exact-retry case where the record is correct but rent-deficient (the `rent.is_exempt` guard on the idempotent path is currently unexercised). `initialize()`'s `copy_from_slice` would panic on a length mismatch; `[..SIZE]` indexing or an explicit length check would be cheaper to reason about than relying on `allocate` having just set the length.

---

## What I checked and what I am not asserting

I traced the program's aliasing and substitution defences and did not find a path where a sponsor seizes a name, where a prefunded PDA blocks registration (a third party can only add lamports, which leaves the account System-owned and empty, so `vacant()` still holds), where one identity gets a second name, or where partial/corrupt state gets silently repaired. The `Verify` op compares all 128 bytes including the reserved zero padding and rejects non-canonical base64, which matches the RFC. Durability ordering in `register()` is correct: the attempt is persisted and read back before any network submission. Cost caps (`rent*2 + fee`, `rent ≤ 5_000_000`, `fee ≤ 100_000`) are consistent with the 0.01 SOL figure shown in the confirmation dialog.

I am not asserting anything about funding, deployment, on-device execution, storage lifecycle, or the build configuration — none of that is in the material I reviewed, and the faucet failure means none of it has been exercised.
