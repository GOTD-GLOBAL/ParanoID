---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-10-06
---

# iOS identity v3 threat delta (RFC-0030)

Delta for [RFC-0030](../rfcs/0030-ios-identity-v3.md), the proposal that the
iOS client adopt identity v3. It extends [the iOS client delta](ios-client-threats.md),
[the identity-login v3 delta](identity-login-v3-threats.md) and the RFC-0028
section of [the threat model](threat-model.md), and everything in those
remains required. The identity-login contract is
unchanged. This document adds what is specific to iOS: a second secret at
rest on Apple's storage, one system-trust session, the words on an Apple
screen, contacts added by nickname, and the move of iOS users to other
servers.

Until an ADR is accepted, the recorded state of
[the iOS client delta](ios-client-threats.md) stays as written: no change to
realm or pin, and no automatic recovery, is authorized there
(`ios-client-threats.md:70-71`).

Human residual risk owner: `martadvix-web`. Private synthetic data only. No
human audit, no production assurance and no completed independent review is
claimed here. Independent qualified human review of identity, cryptography,
persistence and application security remains required before this client
carries real communication
([policy item 6](../governance/documentation-policy.md#closed-alpha-review-exception)).

```text
Unchanged: core identity/Olm/frame2 -> pinned TLS -> server; first contact; calls
New realms: identity-v3 servers from a compiled list, fresh installs only
New secret at rest: nickname owner entropy -> second Keychain wrapping key
  (WhenUnlockedThisDeviceOnly) + sealed file (protection complete) + marker
New signer: paranoid-devnet-client (BIP39, SLIP-0010, Ed25519) behind the C ABI
New trusted source: the Devnet RPC, one system-trust TLS session, one host
New observers: the Devnet RPC operator; the public Devnet registry
Contacts: by nickname through the directory and the registry; the existing
  QR exchange stays only until question 18 removes it
Not used: background owner signing, background tasks, push, faucet
```

## Secret at rest

| Threat | Proposed control | Residual |
| --- | --- | --- |
| The entropy is read from a backup or another device | A sealed file excluded from backup on its own inode; the wrapping key is `ThisDeviceOnly` and not synchronizable | A forensically opened, unlocked phone reads it, as on Android |
| The entropy is read while the phone is locked | Keychain class `WhenUnlockedThisDeviceOnly` and file protection `complete`; `errSecInteractionNotAllowed` means "retry when unlocked" | none beyond the platform's |
| A Keychain item survives deletion of the application and silently restores a nickname | The install marker: on a fresh install, stale items are deleted before anything is created; a nickname returns only from the words | none beyond the existing marker limits |
| A torn write loses or forks the owner material | Write-intent marker synced first, `F_FULLFSYNC`, rename, byte-exact readback, directory sync, marker removal and another sync; a leftover marker or key XOR file freezes the owner functions only; a key is never regenerated | Power loss NOT RUN |
| The words or entropy stay in freed native memory | Devnet requests are copied into zeroizing buffers, and replies are overwritten by `paranoid_devnet_free` | Swift-managed copies cannot be guaranteed zeroized (RFC-0026:177-178) |
| The words reach a log, the clipboard or a crash report | No logging of words, entropy, keys or signatures; no clipboard by default | as above |

## Owner signing

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A background or hostile code path signs as the owner | Owner operations only from an explicit foreground screen, behind a device-owner prompt (question 7); never during a call | A compromised, unlocked phone can still sign; a phone without a passcode gets a tap or a refusal (question 7) |
| Swift signs bytes it built | Swift passes typed requests only; Rust builds and signs (RFC-0026:174-178, draft) | none |
| A wrong program or cluster is signed for | The live genesis, Program/ProgramData and record checks run in Swift, ported from Android's Java with its negative cases, against pins that come only from Rust `program_info` | A consistent RPC lie, or a program upgrade between verification and execution (RFC-0026:205-206) |
| Whoever holds the words or the old phone's key takes the login back | Disclosed in the replacement confirmation; one replacement per 24 hours, at most eight generations including the enrollment (seven replacements) | A private-alpha limit that awaits human risk acceptance (ADR-0016:28-35, proposed) |
| Real wallet words are entered | A warning before entry; `m/44'/501'/0'/0'` is the usual Solana wallet path, so such words would put that wallet's key into the application. Recovery stores nothing when the words hold no ParanoID nickname, so such words never reach registration | The warning can be ignored; the RPC learns which wallet address was looked up |

## The words on screen

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A screenshot captures the words | Shown only after an explicit tap; after `userDidTakeScreenshotNotification`, a notice that the picture may be in Photos and iCloud and how to delete it | **Open gap**: iOS cannot refuse a screenshot |
| Recording, mirroring or AirPlay captures the words | Covered while the scene's capture state reports capture; checked again before each display | Frames drawn before a capture starts can be recorded |
| The app-switcher snapshot holds the words | Covered whenever the scene resigns active; never restored from scene state | not measured on a device |
| A third-party keyboard, dictation or writing tools learn the words | Third-party keyboards refused app-wide; autocorrection, spell checking, prediction, dictation and writing tools off | System keyboard behaviour NOT RUN |

## Network trust

| Threat | Proposed control | Residual |
| --- | --- | --- |
| An interceptor on the phone's path holds a certificate the trust store accepts (a mis-issued certificate, or a user- or MDM-installed root) | One host, one reviewed session, TLS 1.2 or later, no proxies, redirects, cookies or caches, a method allowlist and size limits; the RPC's answers are checked for consistency, not proven | **A false registration success or a false recovered name**; a false directory confirmation only together with a dishonest server. The v3 server checks the registry over its own connection before `commit`, so no false membership |
| The RPC provider itself is dishonest | The RPC is a trusted source (ADR-0016:32-33); the same consistency checks | **All of the above, plus a false membership and a false directory add on an honest server**, because both v3 servers read the same provider unless `PARANOID_REGISTRY_RPC` is set (`server/src/main.rs:299-309`; `server/src/identity_v3.rs:649`) and the installer does not set it |
| The v3 server lies about membership | Owner and device proofs; the result must match the phone's own credential; nothing is automatic on error | A malicious server can refuse or ban |
| A v3 pin is substituted | Compiled in, confirmed explicitly, never learned from a challenge or a link | none |
| A server registered its own key for a nickname | The directory add checks the finalized registry before pairing (`clients/core/src/clean_service.rs:174-180`) | Defeated by a dishonest RPC provider alone, or by an interceptor together with that server; the stale-card residual in the RFC-0028 section of `threat-model.md` |

## The sponsor and the servers

| Threat | Proposed control | Residual |
| --- | --- | --- |
| The sponsor, which is the v3 server, front-runs a name with its own key, withholds or delays the transaction, or misreports its limits | The pending attempt is sealed before the signature leaves the phone; success only from the registry | **Can block registration**; the server learns the name before the chain does |
| The sponsor is drained, or the 128 memberships are filled | Server-side caps of 20 per hour, 60 per day and 3 distinct names per owner (`server/src/sponsor.rs:25-30`) | The caps live in process memory and reset on restart (`threat-model.md`, section «Fresh Solana Devnet identity boundary»); the realms and pins are public in the repository, so anyone can reach the servers; this can block increment 9 |

## Supply chain

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A dependency drifting from the Android builds | The bridge lock keeps every core-lock entry with its name, version, source and checksum, and every other entry must match the Devnet crate's lock | 50 new crates; six shared crates run at the core's versions, which Android's Devnet library never shipped with; host tests with the public vectors cover them |
| C or assembly compiled for an Apple target on a CI host without its SDK | `blake3/pure` through feature unification | A build with `pure` is NOT RUN |

## New observers

- **The Devnet RPC operator** sees the phone's IP address and which owner and
  nickname it reads or registers.
- **The Devnet registry** makes the nickname-to-owner binding public and
  enumerable (RFC-0026:182); the deployed program has no rename, transfer or
  close (RFC-0026:131-132).
- **The v3 server** sees the owner and the nickname in addition to everything
  the v2 server saw, sees a chosen name before the chain as sponsor, and
  learns who searched for whom.
- **Other active members of the same server** see a visible member's
  nickname, owner key, identity PDA, credential and contact card. Members are
  visible by default (RFC-0028), so iOS shows the visibility switch before
  the first publication.

## Move and coexistence

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A saved v2 identity is silently moved to v3, or the reverse | Saved trust wins; the core refuses a realm change; no fallback in either direction | none |
| A user believes v2 contacts moved with them | Moving is a clean reinstall with a new ID, stated in the app (question 9) | v2 accounts stay on a stopped server without a deletion path |
| A replaced phone keeps retrying | `revoked` stops the realtime lanes and seals a flag that forbids re-enrolling that credential; while the phone is locked the flag is kept in memory and sealed after unlock | The owner key on that phone can still move the login back |
| A v3 database reset leaves the phone in an unexplained state | `absent` leads to an explicit login, never an automatic enrollment or rekey | Untested on Android too |

## Verification status

Everything in this delta is proposed and NOT RUN, except the feasibility
checks in [the evidence](../project/evidence/ios-identity-v3-20261006/feasibility-mac.md),
which are not phone evidence.
