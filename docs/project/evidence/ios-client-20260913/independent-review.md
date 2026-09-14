# Independent review of the iOS client branch

This is the record the closed-alpha exception in
[documentation-policy.md](../../../governance/documentation-policy.md) asks
for: an independent AI review in a fresh context, separate from the context
that wrote the code, with the reviewer, the revision, every finding and what
became of it. It is not a human audit and does not replace one.

## Reviews run by the contributor

| | Review 1 | Review 2 |
| --- | --- | --- |
| Date | 2026-09-13 | 2026-09-13 |
| Reviewed revision | `bcb4046` (24 commits, 185 files against `origin/main`) | `bcb4046` |
| Reviewer | `forge:code-reviewer` agent, model `claude-opus-5`, fresh context | general-purpose agent, model `claude-sonnet-5`, fresh context |
| Mandate | read-only; run any local check; nothing against the hosted server; report, do not fix | the same |
| Scope taken | the whole branch, with three sub-audits it ran itself: TLS pinning and the "nine checks", call-v2 SDP and TURN rules, a sweep of the documents for false claims | the branch's claims against the tree: about twenty statements re-run or re-read, ten `file:line` citations re-checked |
| Ran | `test_component_boundary.py`, `test_ui_contract.py`, `test_bridge_lock.py`, `test_toolchain.py --no-xcode`, `test_webrtc_dependency.py --offline`, `test_notices.py`, `test_call_controller_parity.py`, `swift test`, `check-pinned-tls.py`, `test_realtime_transport.py`, `test_voice_relay_lane.py`, `markdownlint` | `test_component_boundary.py`, `test_ui_contract.py`, `swift test`, `test_call_controller_parity.py`, `test_qr_cross.py`, `test_android_compatibility.py --skip-stand` |
| Did not run | anything against `157.180.49.125`; `xcodebuild` (simulator, device, keychain gate) | the full cross-test with a live stand; every `xcodebuild` suite; the simulator scripts |

Neither reviewer wrote a line of the branch, and neither was handed the
implementing context. Both reports are quoted below by finding; the two
reports overlapped on two findings, which are listed once.

## Findings and what became of them

Statuses: `fixed` — changed in the named commit and re-run; `not-a-defect` —
kept on purpose, with the reason written next to the code; `escalated` — for
the owner.

| # | Found by | Finding | Status | Resolution |
| --- | --- | --- | --- | --- |
| 1 | Review 1 | **Blocker.** `test_ui_contract.py` was red on `bcb4046`: `DebugFixture.trust` had gained an `environment:` parameter and the contract still expected the old Release signature, so the first CI run would have failed and `build.sh` would have stopped at gate 15 | `fixed` | `8f63b60` — the contract now covers both channels and requires the Release branch to read neither |
| 2 | Reviews 1 and 2 | **Blocker.** `verification.md`, the evidence catalogue's gate 15 and the "twelve of thirteen `run` commands" sentence all claimed that red test green | `fixed` | `8f63b60` — every command re-run at the new head, the catalogue rewritten from that run |
| 3 | Review 1 | **Major.** The `PARANOID_REALM` / `PARANOID_PIN` environment channel entered with the entitlements commit without a word in its message or in any document | `fixed` | `8f63b60` — described in `clients/ios/README.md`, `build-and-testflight.md` and the `DebugFixture` comments, with why `devicectl` needs it |
| 4 | Review 1 | **Major.** The contract's `-paranoid` prefix filter never saw the new channel: green by construction | `fixed` | `8f63b60` — the contract asserts both channels are `DEBUG`-only by reading the `#else` branch |
| 5 | Review 1 | **Major.** `build.sh` and the catalogue said the keychain tests ran "ad hoc, no team" while the same commit said they cannot pass without a team | `fixed` | `8f63b60` — measured three ways and recorded: pass under an ad-hoc simulator signature, pass under the team, fail only with signing disabled. `88652c9` then made the tests borrow an installed account instead of deleting it |
| 6 | Reviews 1 and 2 | **Major.** `current-state.md`, `build-and-testflight.md`, RFC-0021 and ADR-0014 said the Android cross-test host files "have not landed" or were "not in the committed tree", while `git ls-files` showed them and `build.sh` ran them | `fixed` | `8f63b60` — the full fifteen-check run with a live stand was repeated and every document points at that run |
| 7 | Review 1 | **Major.** "The same nine leaf checks" was inflated: number 9 is a group of five rules, two of which map to Android; checks 4 and 5 are proven on parsed certificates only; the `protocolFloor` refusal is unreachable through the shipped configuration | `fixed` and `not-a-defect` | `8f63b60` — the documents now count eight one-rule checks plus the group of five, and separate what a live handshake proves from what only a parsed certificate does. The `protocolFloor` guard stays: it is the one floor statement a caller cannot bypass by building its own configuration, the comment beside it says so, and `PinnedTrustTests` reaches it |
| 8 | Review 1 | **Minor.** A `build.sh` comment called both cross-tests unconditional while the Java host was gated on `java_deps.sh` | `fixed` | `8f63b60` — the comment describes the gate |
| 9 | Review 1 | **Minor.** Line citations into `PinnedTls.java` and `KeyClient.java` had drifted | `fixed` | `8f63b60` — re-cited; `KeyClient.java:37-41` re-checked against the Android source on 2026-09-14 |
| 10 | Review 1 | **Minor.** A `- Throws:` comment written for `trust()` was left above `realmVariable` | `fixed` | `8f63b60` |

What the reviewers checked and did not fault, in their words: the component
boundary (`0 outside allowlist`, no build output under `clients/android`), no
secrets, the pin byte-identical to `KeyClient.java`, no `SecTrustEvaluate*`,
no `performDefaultHandling`, no `URLSession.shared`, redirects refused,
`check-pinned-tls.py` at one accepted and seven refused with a zero request
counter on every refusal, the TURN lane never falling back to direct mode on
401, 429 or 503, the 71-line bridge's null checks and `catch_unwind`,
`StorageGuard` failing closed, and 284 Swift tests none of which is without
an assertion.

## After the fixes

The suites were run again at `8f63b60` and later heads; the commands and
their output are the rows of [README.md](README.md). Nothing was marked
passed by editing a document: where a claim was larger than the evidence,
the claim was cut to the evidence.

## A defect neither review found — 2026-09-13

Both reviews above ran on 2026-09-13 at `bcb4046` and neither found the
connectivity-change gap: this client had no restart when the default network
changes, so a lane parked in a long poll or in a `Backoff` sleep stayed there
until its own 30-second bound and the backoff after it, and «Повторить
подключение» — `loop.wake()`, which arms the send lane's signal alone — could
free neither. It was found in **use**, not in review: the contributor lost
network on his iPhone on 2026-09-13 and the client stayed at «Нет подключения»
while the hosted server answered from the build Mac and the pinned key was
unchanged.

Three things make that late catch worth writing down rather than passing over.

- It was not a novel defect. The owner had reported exactly this on Android on
  2026-09-12, and Android fixed it the same day
  (`TextEngine.watchNetwork()`, whose comment states the symptom verbatim —
  `TextEngine.java:200-215` in this branch's merged Android tree `0.0.22-push`;
  the method does not exist at `fe9c26c`, the v15 reference this client's Java
  citations are otherwise written from). The fix was one day old when the two
  reviews read this branch, and neither review was asked to re-derive parity
  against Android code newer than that reference — so a rule that had just
  changed on the other client is precisely the shape of thing this review round
  was not built to catch.
- Neither reviewer ran the application. Review 1 ran the offline suites and the
  socket fixtures and explicitly did not run `xcodebuild`; review 2 ran no
  simulator script either. Nothing in the source is *wrong* about the gap —
  there is simply no code where the restart should be — and an absence is what
  a source review is worst at seeing.
- What it cost: a defect on the owner's own alpha for a day, one open item
  carried in five documents from 2026-09-13 to 2026-09-14, and a reproduction
  measuring 25 seconds of «Подключение» with the server answering the whole
  time. It cost no data and no key: the lanes' generation rules held, nothing
  was sent twice and no message was lost — the client was silent, not wrong.

The fix was written on this branch on 2026-09-14 and put through fresh-context
verification passes of its own before it was recorded here; twelve findings
were raised against it and all twelve are answered in the code. Its status is
`CLAIMED`, on a simulator against the local stand, and the path change it is
for has still never been produced — [verification.md](../../../clients/ios/verification.md)
and the NOT RUN table of [README.md](README.md) say so in their own rows.
Neither review is re-run at the new head, so nothing here inherits their
approval.

## Reviews run by the owner's side

On 2026-09-14 the owner's agents started their own reviews of pull request
[#36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36) in isolated contexts,
against the committed tree (GitHub does not serve the full diff of this
size) and without Swift or Xcode on their machine. They make no claim of a
second model. Their findings are answered in the pull request and, where a
document changes, in a commit named there. Their first finding — documents
that still described the state before the phone run and the two hosted
registrations of 2026-09-13 — is answered by the commit that adds this file.
