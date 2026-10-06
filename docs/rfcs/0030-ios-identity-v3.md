---
status: draft
owner: ios
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-10-15
required_reviewers: []
last_reviewed: 2026-10-06
---

# RFC-0030: The iOS client on identity v3

This is a draft. Nothing in it is accepted, implemented, deployed or measured
on a phone. It proposes a decision that only a future ADR could record, and
only with the human decision owner's exact approval. The author is the
contributor `Cooldom66671`. Merging this file does not change its authority.

The base is `main` `2470dca711929fb4575c75cd61578d77acdd3102` (Android
`0.0.48-solana-id`). Android moved
from v42 to v48 on the evening of 2026-10-05 through commits pushed straight
to `main`; every Android fact below was re-checked at that commit. Before choosing 0030, the published branches were listed
with the command in [the RFC index](README.md#naming), fetch included. The
highest number in use is 0029, held twice: `0029-invite-sponsored-registration.md`
on `main` (PR #69) and `0029-ios-background-delivery.md` on the open PR #58.
Under the naming rule PR #58 renumbers when it merges, to the next number free
at that time. No ADR number is reserved here: the ADR gets the next free
number when it is drafted, re-checked before `proposed`.

## Required review rationale

This proposal touches these
[protected decision domains](../governance/documentation-policy.md#protected-decision-domains):

| Domain | What changes |
| --- | --- |
| Identity, key derivation, recovery, and blockchain integration | BIP39 words, SLIP-0010 derivation and owner proofs on iOS; recovery from words; the Devnet registry |
| Cryptographic algorithms and end-to-end encryption semantics | Ed25519 owner signing on iOS; E2EE unchanged |
| Federation, protocol compatibility, persistence formats, event models, and public APIs | iOS speaks identity-login-v3 as specified; a second sealed file, a combined install matrix and the Devnet command contract on iOS; the RFC-0028 directory routes and the `paranoid.global/c/` link format on iOS |
| Storage, data retention, and payment boundaries | the owner entropy kept on the phone |
| The primary stack and foundational dependencies | `paranoid-devnet-client`, `bip39`, `ed25519-dalek-bip32`, the `solana-*` crates and `blake3` in the iOS graph |
| Security boundaries and trust assumptions | further server pins; one system-trust RPC session; contacts bound by the directory proof and the registry read through the RPC instead of an in-person QR comparison (question 18); the phone's contact card listed to every member of its server by default |
| Deployment topology and backward compatibility | new iOS users move from the v2 service to identity v3 |

`review_mode: closed-alpha-ai` is proposed, so `required_reviewers` is empty.
The author holds delegated technical decision authority
([issue #27 comment](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)),
but cannot review his own proposal, and the delegation covers neither product
scope nor server actions. No other qualified human reviewer exists, so the
second-reviewer requirement can be met only through the
[closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception).
Its evidence, item by item (`docs/governance/documentation-policy.md:155-183`):

1. **Scope and approval.** `review_mode: closed-alpha-ai`, the exact
   features, devices, data and environment below, the human risk owner, and
   a permanent owner approval of that scope. A blanket instruction to proceed
   does not count. iOS on identity v3 expands the scopes of RFC-0027 and
   ADR-0016, so it needs its own approval. **Pending.**
2. **Independent AI review** in a fresh context, separate from the authoring
   context, with the reviewer and model, the reviewed revision, the findings,
   their resolutions and a final report recorded in this RFC or its ADR and in
   each implementation pull request. A model other than the author's is
   preferred. The author's own pre-review in the pull request does not count.
   **Pending.**
3. **No unresolved blocking finding.** A failed, unfinished or materially
   disagreeing review is fixed and re-reviewed, or escalated to the owner; the
   gate is never silently marked passed, and the owner cannot make a failed
   test into passing evidence by approving it.
4. **Records:** this RFC and its ADR, the versioned contract
   ([identity-login-v3](../protocol/identity-login-v3.md), plus the iOS
   Devnet command and store specifications that increments 2 and 4 add), the
   [threat delta](../security/ios-identity-v3-threats.md), the
   requirement-to-test mapping below, actual verification evidence, and every
   unmeasured item marked NOT RUN. Acceptance criteria for delivered
   behaviour must pass, and missing phone evidence cannot be replaced by a
   simulator or dependency build. ADR acceptance still requires the human
   decision owner's exact decision approval and all lifecycle records.
5. **Testers and data:** private, informed alpha testers and synthetic data
   only. E2EE stays required, with no plaintext fallback, no server key escrow
   and no invented recovery guarantee. A closed test endpoint is not
   production-ready just because it runs on the owner's existing production
   machine, and deployment still needs explicit bounded authorization,
   isolation and rollback.
6. **Exit gate:** independent qualified human review of identity,
   cryptography, persistence and application security before real sensitive
   communication, public release, any production, security or privacy claim,
   or expansion beyond the approved scope.

Each implementation increment from 2 to 9 records items 1 to 6 again in its
own pull request; increment 1 touches no protected domain.

Scope proposed for the owner's approval:

- **Features:** increments 2 to 9 below: recovery of a nickname from 12 or 24
  words, v3 login with enrollment and explicit replacement, the nickname
  directory, sponsored Devnet registration from 12 new words, then the
  existing text, receipts and calls on a v3 server.
- **Devices:** the contributor's iPhone 16 Pro Max as the only iOS device. The
  owner's Android phone is a peer only, with his explicit consent for each
  session. A spare Android, or a clean reinstall of the owner's application,
  is needed only for an Android leg of the replacement test (question 14).
- **Data:** synthetic accounts, nicknames and messages only.
- **Environment:** the v3 endpoint or endpoints chosen in question 1; Solana
  Devnet through `https://api.devnet.solana.com` with program
  `C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas`; a local identity-v3 stand for
  development builds.
- **Human risk owner:** `martadvix-web`.

## Summary

The iOS client has no reachable server today, and it cannot talk to anyone who
installed Android recently.

- iOS knows one server, the v2 service at `https://157.180.49.125:38443`. That
  endpoint did not answer a pinned health check at 2026-10-05T22:00:46Z, and
  Android's source marks it "stopped 2026-10-05"
  (`clients/android/src/org/paranoid/text/KeyClient.java:12`).
- The same host now runs identity v3 on port 38444, which Android's source
  names "Hetzner Production", sets as its default realm and sends its sponsor
  calls to (`KeyClient.java:9-11`). Android's login, however, still creates
  the identity on the test server `https://138.16.180.53:38444`
  (`TextEngine.java:289-290`), which also runs identity v3.
- Since Android v30 a fresh install can only create its identity through the
  Solana nickname onboarding; v29 still offered the v2 path. A contact is
  bound to its server's realm and pin, so an iPhone on v2 could not pair with
  those users even while v2 ran ([Motivation](#motivation)).
- Since v47 Android no longer draws its own QR, key hash or fingerprint on
  «Мой ID». It has a nickname line, which stays empty because nothing sets
  the field it reads (open PR #70 fixes that), and its scanner remains for
  now. The direction relayed by the contributor is to remove QR entirely and
  add contacts by nickname through the server directory (RFC-0028). Until the
  directory comes to iOS, an Android user can add an iPhone, but not the other
  way round.

This RFC proposes that the iOS client adopt identity v3 for fresh installs. It
behaves as Android does where Android follows the recorded contracts, and
follows the contracts where Android does not:

- recover a nickname from 12 or 24 words;
- log in to an identity-v3 server with an owner proof and a device proof,
  either by enrollment or by an explicit, disclosed replacement of another
  phone;
- find other members by nickname and add them through the RFC-0028
  directory, with the registry check before pairing;
- create a Devnet nickname from 12 new words, registered at the server
  sponsor's expense;
- then use the existing text, receipts and calls on that server, unchanged.

A saved realm is never switched silently: an existing iOS install moves only
by a clean reinstall. The directory depends on RFC-0028's own disposition;
opening links by tap and invitations (RFC-0029) are later.

Nothing outside the iOS component boundary changes (`clients/ios/`, `docs/`
and the allowlisted `.github/workflows/ios.yml`;
`clients/ios/test_component_boundary.py:22-24`): no core, key-protocol,
server, protocol, deployment or Android change. The device side of identity v3
is already in the shared core and reachable through the existing bridge
command. The owner side (BIP39 words, SLIP-0010 derivation, Solana
transactions, owner proofs) is the Rust crate Android ships,
`blockchain/solana/client`, linked into the iOS bridge behind two more C
exports (a command and its zeroizing free) instead of JNI. Android's genesis, program and record checks are Java,
so iOS ports them to Swift.

What was measured on the build Mac on 2026-10-06
([feasibility evidence](../project/evidence/ios-identity-v3-20261006/feasibility-mac.md)):

- the crate compiles for `aarch64-apple-ios` unchanged;
- the crate and the core build into one static library, which links into an
  iOS executable;
- a separate Rust binary that calls both crates directly reproduced the public
  `abandon … about` vector (`HAgk14…`) and the core's v3 credential on the iOS
  simulator.

The linked library was never run, and the C ABI from Swift is NOT RUN.

What it costs:

- a second secret on the phone, the nickname owner entropy (question 8);
- contacts bound by the directory proof and the registry, read through the
  Devnet RPC, instead of a comparison in person, and the phone listed to every
  member of its server by default (question 18);
- a new observer and a new trusted source, the Devnet RPC, through one TLS
  session on the system trust store (question 6);
- new foundational dependencies in the iOS graph (question 5);
- for an existing iOS user, a clean reinstall with a new ID, losing v2
  contacts and history, which are unreachable while v2 is stopped anyway;
- on-chain nicknames that cannot be renamed or closed, and sponsored
  registrations from a shared, finite budget;
- the owner's time: the decisions below, a go for each live action, phone
  sessions, and confirming the state of the v3 servers;
- about six to nine weeks elapsed ([increments](#implementation-increments)).

## Motivation

### The servers on 2026-10-05

| Fact | Evidence |
| --- | --- |
| The v2 service did not answer; Android's source marks it stopped. | pinned `GET /health` to `https://157.180.49.125:38443` at 2026-10-05T22:00:46Z: connection timed out after 10 s ([gap analysis](../project/evidence/ios-identity-v3-20261006/gap-analysis.md#1-the-servers-and-the-split)); `KeyClient.java:12-14` |
| The production host runs identity v3 on port 38444, Android's default realm. | the same check answered `paranoid-identity-v3` with pin `536c1544…`; `KeyClient.java:9-11` |
| The test VPS runs identity v3. | the same check at `https://138.16.180.53:38444` answered `paranoid-identity-v3` with pin `427a7046…`; `KeyClient.java:15-18` |
| Android's sponsor calls go to the production host, while its login creates the identity on the test VPS. | `clients/android-devnet/src/org/paranoid/devnet/OnboardingActivity.java:513-516`; `clients/android/src/org/paranoid/text/TextEngine.java:289-290` |
| No recorded owner decision covers the stop of v2 or identity v3 on the production host. | the change arrived in commit `b488331`, pushed to `main` without a pull request; ADR-0016's approvals leave "any deployment" unauthorized (`docs/decisions/0016-solana-server-authentication.md:78`) |

The commits that moved Android to v44, v45 and v46 change only the version
code, while their messages describe a server-choice screen, the nickname on
«Мой ID» and the removal of the key hash. The repository does not hold that
code, so what the published application does cannot be read here.

### Why iPhones and new Android users cannot meet

| Fact | Evidence |
| --- | --- |
| A fresh Android install opens only the nickname onboarding; since v30 no caller is left for the v2 identity creation. | `clients/android/src/org/paranoid/text/MainActivity.java:163-168,927-928`; `TextEngine.java:278`; commit `c6eed44` |
| Its login creates the messenger identity for the v3 test realm. | `TextEngine.java:285-290` |
| The iOS Release build starts only on the v2 realm and accepts only the v2 health protocol and v2 paths. | `clients/ios/ParanoidKit/Sources/ParanoidKit/Service/Snapshot.swift:93-98`; `clients/ios/ParanoidKit/Sources/ParanoidKit/Net/Health.swift:14,44-47`; `clients/ios/ParanoidKit/Sources/ParanoidKit/Net/RealtimeTransport.swift:261` |
| A contact from another realm or pin is refused; realm and pin are part of the first-contact transcript. | `clients/core/src/intro_v2.rs:21-25,42-43`; `clients/core/src/contact_v2.rs:50-53` |
| There is no federation. | `docs/product/requirements.md:45` (REQ-FED-001, a direction); excluded from the identity-v3 scope (`docs/rfcs/0027-solana-server-authentication.md:23-24`) |
| Since v47 «Мой ID» no longer shows the contact QR, key hash or fingerprint; its nickname line reads a `solana_nick` field that nothing sets (v48 shows «Нет ника»); scanning and pasting a contact remain. | `MainActivity.java:205-208,226,583-588,956-964`; `TextEngine.java:436`; commits `b422310`, `2470dca`; open PR #70 |

The gap grows with every Android release, all of it on v3: v36 added nickname
search and contact links (PR #67), and v37 to v42 (PR #69) reworked the
onboarding, simplified the main and «Мой ID» screens, allowed screenshots and
moved the update service. Invitations are drafted (RFC-0029).

RFC-0021's acceptance asks for joint tests with the owner's Android against
the hosted v2 alpha (`docs/rfcs/0021-ios-client.md:494-497,513-524`). With
v2 stopped, that acceptance cannot be run as written. The owner's phones moved
to v3 on 2026-09-30: one logged in there, and the other registered a nickname
but its first login failed with `challenge_mismatch`, fixed in v35 and not
re-run (`docs/project/current-state.md`, section «Solana ID login and
sponsored nicknames on the test VPS — 2026-09-30»). Two-phone messaging and
calls through a v3 server have no recorded phone evidence even between two
Android phones: ADR-0016's AUTH-06 and AUTH-07 gates have not passed
(`docs/decisions/0016-solana-server-authentication.md:75-77`).

### Requirements

REQ-CLIENT-001 (Android and iOS are supported clients) is the driver.
Android's identity-v3 client is traced to REQ-ID-001, 002, 003, 004, 005,
007 and 008 (`docs/rfcs/0027-solana-server-authentication.md:39`); its
acceptance is not recorded. The owner-approved REQ-ID-006 exception covers the
local Devnet identity-v3 test mode only (`docs/product/requirements.md:33`;
`docs/decisions/0016-solana-server-authentication.md:62-77`), and no recorded
approval covers the remote mode on which both v3 servers run (question 4).
The iOS client meets neither REQ-ID-002 nor REQ-ID-003 today.

### How far iOS is behind

[The gap analysis](../project/evidence/ios-identity-v3-20261006/gap-analysis.md)
inventories the gap with evidence. In short:

- identity v3 (this RFC) is the only large gap. Together with the directory,
  which depends on it and is now the way to add contacts, it blocks
  communication;
- contact links by tap depend on both;
- the rest are small or medium platform items that need no protected-domain
  decision;
- several Android-only behaviours are recorded platform differences, not
  gaps.

## Goals and non-goals

### Goals

1. A fresh iOS install can recover a nickname from 12 or 24 words and log in
   to an identity-v3 server, by enrollment or by an explicit replacement of
   another phone.
2. A fresh iOS install can create a Devnet nickname and register it through
   the server sponsor.
3. An iPhone and an Android user on the same server find each other by
   nickname through the directory, and after that text, receipts, voice and
   video calls work through the existing contracts.
4. A saved realm is never switched silently; an existing install moves only
   by a clean reinstall.
5. Where Android deviates from a recorded contract, iOS follows the contract
   and the deviation is reported
   ([discrepancies](#discrepancies-found-while-preparing-this-rfc)). The one
   forced exception is the sponsor's blockhash (discrepancy 7).
6. Nothing changes outside the iOS component boundary.

### Non-goals

- Opening `paranoid.global/c/` links by tap, which needs an Apple
  app-site-association file on `paranoid.global` (a deployment action), and
  RFC-0029 invitations: later, each after its own disposition. A pasted link
  is resolved through the directory in this scope.
- Removing QR from iOS: a later product change once the owner records it
  (question 18).
- Moving an existing v2 account, its contacts or its history to v3; deleting
  v2 accounts (the v2 server has no deletion path).
- Two identities in one install, and several active devices for one nickname.
- An own-SOL or faucet fallback when the sponsor refuses (question 11).
- Any typed server address or pin (REQ-ID-008;
  `docs/clients/ios/self-service.md:232-241`).
- Background owner signing, background tasks, push.
- Mainnet, a public mode, TestFlight distribution (the export-compliance gate
  stays closed), any server or VPS action.

## Proposed design

### Where each part lives

| Concern | Android | iOS (proposed) |
| --- | --- | --- |
| Messenger device credential, device proof, sessions, E2EE | `clients/core` through JNI | the same core through the existing `paranoid_core_command` |
| 12 words, owner key derivation, registration transaction, sponsored signing and assembly, owner proof | `blockchain/solana/client` as `libparanoid_devnet_client.so` (`clients/android/build.sh:60-61,91`) | the same crate in the iOS bridge, through a new `paranoid_devnet_command` |
| Program, genesis and RPC pins | Rust `program_info` (`blockchain/solana/client/src/lib.rs:205-216`) | the same; no Swift literals |
| Live genesis, Program/ProgramData and identity-record checks | Java: `DevnetRpc.java:42,48-56`, `ProgramPin.java:20-35`, `RegistrationFlow.java` `check` | a Swift port with Android's negative cases |
| Devnet RPC transport | `DevnetRpc.java` | one reviewed Swift session |
| Registration orchestration | `RegistrationFlow.java` | a Swift port with the corrections below |
| Devnet secret at rest | `DevnetStore.java` | a Keychain wrapping key plus a sealed file |
| Login orchestration | `IdentityLogin.java` | a Swift port that persists the login intent |
| Directory: search, verified add, own card, visibility, links | `MainActivity.java`, `RealtimeLoop.java`, the core's directory operations | Swift over the same core operations |
| Screens | `OnboardingActivity.java` | SwiftUI |

No BIP39, SLIP-0010, Ed25519 or transaction code is written in Swift, and
Swift never signs bytes it built. RFC-0026 (draft) keeps derivation,
transaction construction and signing in shared Rust
(`docs/rfcs/0026-solana-devnet-registration.md:174-178`).

### The native bridge (question 5)

**Proposed: one static library.** `clients/ios/bridge` gains a path dependency
on `paranoid-devnet-client` and two exports:

```c
/* Runs one Devnet command. */
char *paranoid_devnet_command(const char *request);
/* Overwrites, then releases, a reply of paranoid_devnet_command. */
void paranoid_devnet_free(char *reply);
```

The command wraps `paranoid_devnet_client::command`
(`blockchain/solana/client/src/lib.rs:375-385`) with the same `catch_unwind`,
NULL and UTF-8 handling as `paranoid_core_command`, and copies its input into
a zeroizing buffer, as the crate's JNI wrapper does (`lib.rs:387-405`). Its
replies can carry the words or the entropy, so they are released only by
`paranoid_devnet_free`, which overwrites the bytes first. The crate's own
16384-byte input cap applies. The JSON contract is the one Android uses, and
increment 2 records it as a versioned specification for iOS.

Consequences, measured on 2026-10-06:

- **Graph.** The combined graph has 167 distinct registry crates (181 lock
  entries): the core's 117 plus 50 that only the Devnet crate uses, such as
  `bip39`, `pbkdf2`, `ed25519-dalek-bip32` and `blake3`. `jni` is already in
  the iOS graph through the core (`clients/core/Cargo.toml:16`;
  `clients/ios/notices.py:18-19`).
- **Lock rule.** Android ships two separately locked libraries, and 13 crates
  differ in version between its two locks, so one iOS graph cannot equal both.
  The bridge-lock gate (`clients/ios/test_bridge_lock.py:2-11`) is restated:
  - every entry of `clients/core/Cargo.lock` stays in the bridge lock with the
    same name, version, source and checksum, as today;
  - every other registry entry of the bridge lock appears with the same name,
    version, source and checksum in `blockchain/solana/client/Cargo.lock`;
  - the path packages are the core, the key protocol, the Devnet crate and the
    bridge.
- **Shared crates.** A resolution seeded from the bridge lock keeps the core's
  version of six crates (`cfg-if`, `syn` 3, `toml_edit`, `unicode-ident`,
  `zerocopy`, `zerocopy-derive`), so on iOS the Devnet crate runs with
  versions that Android's Devnet library never shipped with. The host tests
  with the public vectors cover that. The seven crates that Android already
  carries twice keep both versions. The same seeded resolution picked `cc`
  1.6.0 and `find-msvc-tools` 0.1.14 for crates the bridge lock lacked; they
  are pinned to the Devnet lock's 1.4.7 and 0.1.13.
- **No C or assembly.** `blake3` 1.8.7 compiles NEON C on `aarch64` and x86-64
  assembly unless its `pure` feature is set (its `build.rs:345-358,366-370`).
  The iOS static CI job checks the bridge for `aarch64-apple-ios` on Ubuntu,
  where no iOS SDK exists (`.github/workflows/ios.yml:16,42`). The bridge
  therefore enables `blake3/pure` through feature unification, and no C or
  assembly is compiled for any target; the hash output does not change. A
  build with `pure` and the Ubuntu job are NOT RUN.
- **Dead code.** The crate's JNI export
  `Java_org_paranoid_devnet_SolanaBridge_call` is compiled in unused. Gating
  it behind a default feature is a small change in `blockchain/solana/client`,
  outside the iOS boundary: an optional follow-up for the owner's agents.
- **CI paths.** `.github/workflows/ios.yml` adds `blockchain/solana/client/**`
  to its paths. The notices and licences cover the new crates.

### Server profiles

- The client keeps compiled server profiles as a list. Each entry holds the
  realm, the pin and the kind (v2 or identity v3). Question 1 chooses the v3
  entries, with their pins from Android:
  - production `https://157.180.49.125:38444`, pin
    `536c154440a3107e1fe63f967ed39389aa1a1f4f2b3407070066b76c3a78ae0f`
    (`KeyClient.java:9-11`). It is a closed test endpoint on the owner's
    production machine, not production-ready;
  - test `https://138.16.180.53:38444`, pin
    `427a7046408aa4001318b86dfee86682a4bc6aea47b27720e08876b33d2490e7`
    (`KeyClient.java:15-18`).
- A profile is confirmed explicitly during onboarding, before the messenger
  identity exists, and is never learned from a challenge
  (`docs/protocol/identity-login-v3.md:58-59`). It is never typed
  (`docs/clients/ios/self-service.md:232-233`), and a link never joins an
  unknown server. Question 10 decides whether the screen offers both v3
  entries, as Android's v44 commit message describes, or confirms one.
- The kind of a saved realm comes from the compiled list. A Debug build that
  points at a local stand declares the kind with an explicit launch flag,
  checked together with the realm and the pin. The kind is never inferred
  from `/health`, and no field is added to the snapshot wrapper.
- Saved trust wins. A saved v2 realm stays v2. Nothing falls back from v3 to
  v2 or the other way (`docs/protocol/identity-login-v3.md:60`). The core
  refuses a realm change: a schema-0 state answers `identity_change_refused`
  (`clients/core/src/lib.rs:459-466`), and a registered schema-3 state has no
  `create_identity` operation (`clients/core/src/lib.rs:448-453`).
- The health check accepts `paranoid-identity-v3` only for a v3 profile and
  `paranoid-self-service-v2` only for a v2 profile. The transport allows
  `/v3/identity/`, `/v3/sponsor/` and the session-signed `/v3/directory/`
  only for a v3 profile, and never calls
  `/v2/registration/` there: it answers `404`
  (`docs/protocol/identity-login-v3.md:305`).
- As on Android, discovery comes before registration
  (`clients/android/src/org/paranoid/text/RealtimeLoop.java:191-204`);
  today's iOS flow registers first
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Service/ProofFlow.swift:285-298`).
- The identity routes are sent without the transport's automatic one-time
  repeat after a lost connection, because a repeated proof hits a consumed
  challenge. A transport loss on `commit` means "outcome unknown", which is
  resolved by the device-only status and the persisted intent, never shown as
  a proof failure.
- A v3 server's database can be re-created for a schema change; PR #67's
  description says the test VPS's was. After such a reset an active iPhone
  sees `absent`, and logging in again is an explicit user action.

### The Devnet secret at rest (question 8)

The text identity's storage stays as it is: one Keychain item
(`paranoid-text-state-v0`,
`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/KeychainKey.swift:39-41`)
wrapping one sealed snapshot, guarded by the install marker
(`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/StorageGuard.swift:28-37`).
The nickname owner material gets a second, independent pair, which mirrors
Android's (`clients/android-devnet/src/org/paranoid/devnet/DevnetStore.java:12-21`):

- **Keychain item.** A second generic-password item under Android's alias,
  `paranoid.devnet.seed.v1`, holding only an AES-256 wrapping key. Its class
  is `WhenUnlockedThisDeviceOnly`, not synchronizable. Owner operations are
  foreground-only, and status and traffic never need the owner key, so nothing
  needs it while the phone is locked. `errSecInteractionNotAllowed` means
  "retry when unlocked", never "absent".
- **Sealed file.** `devnet-state.enc` (AES-GCM), with file protection
  `complete`, excluded from backup on its own inode before the rename.
- **Write order** (RFC-0026:104-106; `DevnetStore.java:26-30,59-63`):
  1. create the write-intent marker `devnet-write.pending`, sync it and its
     directory;
  2. write the sealed candidate with `F_FULLFSYNC`, rename it, read it back
     byte for byte, and sync the directory;
  3. remove the marker and sync the directory again.
- **Contents.** The entropy, its genesis and program binding, the
  backup-confirmed flag, the nickname, every sponsored and signed registration
  attempt, the persisted login intent, and the "replaced" flag. The entropy is
  never a Keychain value, because Keychain items survive deletion of the
  application. A versioned specification of this format (version, AEAD
  layout, schema and limits) comes with increment 4.

The install-marker rule becomes a combined matrix with two frozen states.
**Text-frozen** stops the whole application, as today. **Owner-frozen**
disables the words, registration, login and replacement with a stated
reason, while messaging and calls continue.

| Marker | Files present | Result |
| --- | --- | --- |
| absent | any file of either pair, or `devnet-write.pending` | text-frozen before any deletion |
| absent | none | both stale Keychain items deleted, then the marker recorded; a failed delete records nothing |
| present | text key XOR text file | text-frozen |
| present | Devnet key XOR Devnet file, or a leftover `devnet-write.pending` | owner-frozen |
| present | each pair whole or absent | valid: a v2 install (text pair only), a nickname held but not logged in (Devnet pair only), or both |

A stale Keychain item never recovers anything. A reinstall starts a new device
ID. The nickname comes back only from the words, through a replacement, with
fresh contacts and no history
(`docs/decisions/0016-solana-server-authentication.md:55-58`).

Nothing new goes into the core's state or the snapshot wrapper. Moving between
builds therefore cannot leave an older build unable to open the snapshot.

### Owner signing (question 7)

Owner operations run only from an explicit foreground screen and never during
a call: registration (`sponsored_sign`), `inspect`, `enroll` and `replace`
(`docs/protocol/identity-login-v3.md:410-412`; RFC-0026:107-108). Status,
sessions and traffic use the device key only
(`docs/protocol/identity-login-v3.md:176,208,310`).

Proposed: before each owner operation the app asks for the device owner with
`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`, which means Face ID,
Touch ID or the passcode.

- The prompt comes first, then the challenge is fetched and the proof is
  signed and posted at once, so the 60 s challenge cannot expire while the
  user authenticates.
- One context serves one operation and is invalidated afterwards.
- The prompt gates the operation; it is not an access-control flag on the
  Keychain item, because such an item vanishes when the passcode is removed.
- `NSFaceIDUsageDescription` is added to `Info.plist` and checked by the
  bundle gate.
- A phone without a passcode fails with `LAError.passcodeNotSet`. Question 7
  chooses between an explicit tap, with a stated weaker guarantee, and
  refusal.

Android satisfies the same clause with a tap. Its Devnet key is not bound to
user authentication (`DevnetStore.java:55`). A related review finding says the
phrase reveal has no device reauthentication
(`docs/project/evidence/solana-devnet-20260921/README.md:80`).

### Devnet RPC (question 6)

**The RPC is a trusted source of chain state.** Its answers supply the genesis
hash, the Program and ProgramData accounts and the paired registry readback.
The pins and the readback detect an inconsistent RPC, not a consistent liar
(RFC-0026:205-206, 253-254; `docs/security/threat-model.md`, section «Fresh
Solana Devnet identity boundary»;
`docs/decisions/0016-solana-server-authentication.md:32-33`). Two adversaries
differ:

- **An interceptor on the phone's path**, holding a certificate the phone's
  trust store accepts (a mis-issued certificate, or a user- or MDM-installed
  root), can show a registration that never landed or a recovered name that
  is not on chain, and a false directory confirmation only together with a
  dishonest ParanoID server. It cannot create a membership: the v3 server
  checks the registry over its own connection before `commit`
  (`docs/protocol/identity-login-v3.md:253-259`).
- **A dishonest RPC provider** can do all of that, and can also create a
  false membership and pass a false directory add on an honest server. Unless
  `PARANOID_REGISTRY_RPC` is set, both v3 servers read the same
  `https://api.devnet.solana.com` as the phone (`server/src/main.rs:299-309`;
  `server/src/identity_v3.rs:649`), and the installer does not set it
  (`deploy/one-touch/install.sh:124-135`).

Both see which IP address asks about which owner and nickname.

The session:

- one endpoint, `https://api.devnet.solana.com`, taken from Rust
  `program_info`; the genesis hash is checked before every flow
  (RFC-0026:184-186);
- built once, in one reviewed factory, with these constraints:
  - TLS 1.2 or later, set on the session, because App Transport Security is
    off for the whole bundle (`clients/ios/App/ParanoID/Info.plist:27-31`);
  - HTTPS to exactly that host; the challenge handler takes the default
    server-trust evaluation for that host only, and cancels client-certificate
    and HTTP authentication challenges;
  - no cookie, cache or credential stores; an empty proxy dictionary; redirects
    refused; a constant `User-Agent` and `Accept-Language`;
  - requests of at most 8192 bytes and replies of at most 1 MiB, with the
    JSON-RPC `id` echo checked;
  - the methods `getGenesisHash`, `getAccountInfo`, `getMultipleAccounts`,
    `getBlockHeight`, `getSignatureStatuses` and `sendTransaction` only;
  - any error fails closed.

Why not pinned: a public provider rotates its keys, so a pin to its leaf
would break at the next rotation. Why not through the ParanoID server: the
core's directory contract already requires each caller to confirm names on
the finalized registry itself (`clients/core/src/clean_service.rs:176-180`),
and RFC-0026 makes the client's own finalized paired readback the success
authority (RFC-0026:215-218, 230-231). A server proxy would make the server
vouch for the fact the client checks it against. Options that narrow the
residual, all under question 6: pin the provider's CA set; cross-check a
second, independent RPC provider at the cost of a second observer; or run
the servers' registry checks on a provider independent of the phone's.

This amends ADR-0014's "never on a CA chain" for exactly this host
(`docs/decisions/0014-ios-client.md:138-147`) and adds one reviewed
constructor to the pinned-session contract
(`clients/ios/pinned_session_contract.py:17-18,24-31`). The server routes keep
the pinned delegate with their own pins.

### Recovery

1. The user chooses between creating a nickname and recovering one before any
   entropy is written.
2. The entry screen warns not to enter the words of a real wallet, before
   entry. The derivation path `m/44'/501'/0'/0'` is the usual Solana wallet
   path (`blockchain/solana/client/src/lib.rs:99`), so a real wallet's words
   would put that wallet's key into this application. Android's «Ник в
   Devnet» dialog warns before entry; its onboarding warns only after an
   invalid phrase (`clients/android-devnet/src/org/paranoid/devnet/DevnetWork.java:15`).
3. 12 or 24 English words go to Rust `recover`, which returns the entropy
   (`blockchain/solana/client/src/lib.rs:363-372`).
4. Rust `identity` derives the owner and the identity PDA, and a finalized
   read of the identity PDA gives the name. If the identity PDA is absent,
   nothing is stored and the screen says that these words hold no ParanoID
   nickname.
5. The paired readback is checked through Rust `verify`.
6. The material is sealed, then the login starts.

If a Devnet pair already exists, recovery is refused with that reason; the
typed words are never ignored silently, as Android does. The words restore
the nickname and the owner key only, not chats or contacts (REQ-ID-002;
RFC-0026:180-182).

Word entry disables autocorrection, spell checking, smart punctuation,
predictive text, dictation and writing tools. The application refuses
third-party keyboards app-wide
(`application(_:shouldAllowExtensionPointIdentifier:)` through the
application delegate adaptor).

### Login

- **Proofs.** The device side uses core `identity_credential_v3` and
  `identity_device_proof_v3` (`clients/core/src/clean_service.rs:116-123`).
  The owner side uses Rust `identity_owner_proof_v3`
  (`blockchain/solana/client/src/lib.rs:74-81,349-362`). Both receive the
  wall-clock
  `now` in seconds. Rust applies the ±300 s plausibility window, and the
  server alone enforces the 60 s lifetime
  (`docs/protocol/identity-login-v3.md:163-169`).
- **Order.**
  1. `create_identity`, then commit the text snapshot with its readback,
     before any `inspect`.
  2. `status` with the device proof: `active` continues at step 6, which
     covers a lost `commit` reply; `revoked` or `banned` stops the flow.
  3. `inspect` with both proofs: `absent` leads to `enroll` at generation `0`;
     `active` leads to the replacement confirmation, then `replace` at the
     observed generation.
  4. Before the first mutation request (its `/v3/identity/challenge`), seal
     the whole intent with its readback: the challenge request with every
     digest field, including the credential object and its fingerprint.
  5. `commit`; every retry reuses the sealed intent
     (`docs/protocol/identity-login-v3.md:127-128, 197-200, 226-231`).
  6. Check that the result is `mode: active` with the account and device equal
     to the phone's own credential, then commit `server_status_v2` into the
     core.
  7. Only then clear the intent.

  An intent that names a credential other than the core's current one is
  discarded and reported, never committed. `409 generation_conflict` leads
  only to a new, user-confirmed `inspect`.
- **Replacement confirmation.** It states:
  - the other phone is disconnected, and history and contacts are not
    transferred;
  - the other phone keeps its copy of the key, so whoever has it or the words
    can move the login back once per 24 hours; delete the app there;
  - each contact must add this phone again, which uses one of their limited
    contact slots (16 unverified, 64 in total);
  - how many replacements remain: seven at most, because the eight generations
    include the enrollment (`docs/protocol/identity-login-v3.md:386-399,
    417-424`; `server/src/identity_v3.rs:26,408-412`).
- **Capacity errors.** `contact_limit`, `unverified_contact_limit`,
  `capacity` and `replacement_limit` get their own messages in the captions
  gate.
- **Pacing**, as on Android
  (`clients/android-devnet/src/org/paranoid/devnet/IdentityLogin.java:28-53`):
  about 200 ms between calls, bounded retries of `429` only, one post per
  proof. Android bounds only the caller's wait (3 minutes,
  `TextEngine.java:295`) and leaves the flow running; iOS cancels the flow at
  its bound.
- **No automatic action.** No error ever triggers key recreation, a fallback
  to v2 or an automatic replacement
  (`docs/protocol/identity-login-v3.md:427-434`).

### A replaced phone and a peer that moved

- **This phone was replaced.** A `401` or `409` from a v3 realm in ordinary
  traffic runs the device-only status. `revoked` or `device_revoked` stops the
  realtime lanes and seals the "replaced" flag, which forbids any later
  enrollment of that credential. While the phone is locked the Devnet file
  cannot be written, so the state is kept in memory and sealed after unlock;
  a refused write is not a torn write. The screen says that this phone was
  disconnected from the account, that a new installation and the words are
  needed, and that the owner key still on this phone could move the login back.
- **A peer that moved.** A send to a peer that replaced its phone answers
  `409 recipient_retired` (`server/src/self_service_messages.rs:72-87`). That
  envelope stops being offered, and the chat says that the contact moved to
  another phone and needs a fresh contact exchange. Today both clients defer
  every `409` and retry it indefinitely.

### The directory (question 18; RFC-0028)

Since v47 Android shows no QR of its own, and the relayed direction is to
drop QR altogether. iOS implements RFC-0028's client side once RFC-0028 is
disposed:

- **Search** appears only for a v3 profile while the membership is active.
  Queries run only on an explicit action, within the server's budgets: pages
  of 50; 60 directory requests per member each hour, shared by searches, card
  publications and visibility changes; and 600 searches per server each hour
  (`server/src/identity_directory.rs:20-23,88-110`), with `429 directory_rate`
  beyond them. Republishing the own card is bounded so that it cannot spend
  the member's budget.
- **An add** follows a fixed order, as the core's contract requires
  (`clients/core/src/clean_service.rs:170-216`):
  1. core `verify_directory_entry_v1` checks the owner's proof in the entry;
  2. the registry check: the nickname format, the genesis and program checks,
     Rust `lookup` giving the entry's identity PDA, and a finalized paired
     readback through Rust `verify`. Without it, a server that registered its
     own key for the name could impersonate the nickname
     (`clean_service.rs:174-180`);
  3. a confirmation «Добавить @nick?» showing the key fingerprint, as Android
     does (`clients/android/src/org/paranoid/text/MainActivity.java:671-688`),
     but saying Devnet where Android says «в Solana» (RFC-0026:72; listed in
     the captions gate);
  4. core `pair_directory_entry_v1`, which adds the contact as
     network-unverified.

  Any mismatch or RPC uncertainty adds nothing.
- **The own card.** The phone publishes its contact card (`directory_card`)
  after login, whenever its fingerprint changes, and again when a search
  reports it missing (`clients/android/src/org/paranoid/text/RealtimeLoop.java:246-305`).
  Visibility in search is a switch whose truth is on the server
  (`directory_visibility`; `MainActivity.java:214-224`). Because RFC-0028
  lists members by default, iOS shows the switch on the last onboarding
  screen, before the first publication.
- **A pasted link**, `https://paranoid.global/c/<server>/<nick>` or
  `paranoid://c/<server>/<nick>`, compares `<server>` with the first 16 hex
  digits of the phone's own pin, then runs an exact-name search and the same
  add. A link for another server says that the phone is not connected to it
  and that ParanoID does not join servers by links (`MainActivity.java:692-729`;
  RFC-0028:79-86, 134-137).
- **What replaces the QR check.** Without QR and an in-person fingerprint
  check, a contact's binding rests on the directory proof and the registry,
  read through the trusted RPC. A dishonest RPC provider alone can pass a
  false add, and an interceptor on the phone's path can do so together with a
  dishonest server. The stale-card residual of `docs/security/threat-model.md`,
  section «Server member directory and contact links (RFC-0028)», applies.

### Registration

1. Check the genesis, then the program accounts.
2. Draw 16 random bytes (`SecRandomCopyBytes`) and pass them to
   `export_mnemonic` to get the words, shown only after an explicit tap
   ([the words screens](#the-words-screens-question-9)).
3. Registration is refused until the user confirms the words are written down
   (`backup_confirmation_required`).
4. The nickname must match `[a-z][a-z0-9_]{2,23}`. The canonical lower-case
   `@nick` is shown for explicit confirmation before signing (RFC-0026:226),
   with the word Devnet and the statement that a nickname cannot be changed
   later.
5. `POST /v3/sponsor/prepare {genesis}` returns
   `{payer, blockhash, last_valid_height}`.
6. Rust `sponsored_sign` signs as the owner. **Before** the signature leaves
   the phone, a pending sponsored record (name, blockhash,
   `last_valid_height`, owner signature) is sealed with its readback. From
   then on it counts as an attempt for the different-name guard and for
   expiry, because the server could complete and land the transaction.
7. `POST /v3/sponsor/register {owner, name, blockhash, owner_signature}`
   returns `{payer_signature, payer}`; Rust `sponsored_assemble` verifies both
   signatures (RFC-0026:12-36; `server/src/sponsor.rs:151-251`).
8. The full attempt is sealed. `sends` is incremented and sealed before each
   `sendTransaction`; at most three submissions per attempt, the first
   included, with identical bytes (RFC-0026:97-98). Confirmation is polled
   within a bound (Android: 40 checks, 3 s apart).
9. The registry decides:
   - success is a finalized `getMultipleAccounts` of both PDAs that passes
     Rust `verify`;
   - if the owner's identity PDA exists with another name, an earlier attempt
     landed: that pair is verified and adopted as the nickname;
   - both PDAs absent, once the finalized height has passed every saved
     `last_valid_height`, allows a rebuild;
   - a nickname PDA bound to another owner, or a malformed record, is terminal
     ("name taken");
   - a different name is refused while an attempt can still land.

Sponsor answers (`server/src/sponsor.rs:83-99,169-251`):

- `409 sponsor_used` means this key has tried three distinct names through
  this server process. A new name cannot be sponsored until the server
  restarts, while the last name tried can still be retried
  (`server/src/sponsor.rs:210-219`); the screen says so. It never means "name
  taken", which only the registry can show; Android reads it that way
  (discrepancy 11).
- `429 sponsor_limit`, `503 sponsor_empty` and `503 sponsor_rpc_unavailable`
  mean "try later".
- The `400` codes (`wrong_cluster`, `invalid_owner`, `invalid_name`,
  `invalid_blockhash`, `invalid_owner_signature`, `sponsor_unavailable`) are
  shown with their code.

The sponsor's limits live in the server process's memory and reset on
restart: 20 per hour, 60 per day, 3 distinct name attempts per owner, and a
0.02 SOL reserve (`server/src/sponsor.rs:25-30`). Its initial 0.3 test SOL
covered on the order of 50 registrations at RFC-0026's estimate of about
0.0055 SOL each (RFC-0026:27-35); RFC-0029 estimates about 0.0026 SOL. Some
are spent, and the current balance is not recorded here. There is no own-SOL
fallback (question 11).

The sponsor is the v3 server itself. It learns the chosen name before the
chain does, and it supplies the blockhash and `last_valid_height`. It could
therefore front-run the name with its own key, withhold or delay the
transaction, or misreport its limits. The threat delta records this.

### The words screens (question 9)

iOS cannot refuse a screenshot (`docs/security/ios-client-threats.md:108`).
Proposed:

- the words appear only after an explicit tap;
- they are covered while the scene's capture state
  (`UITraitCollection.sceneCaptureState`) reports recording, mirroring or
  AirPlay, and the state is checked again before each display. A capture that
  starts while the words are on screen can record the frames drawn before the
  cover;
- they are covered whenever the scene resigns active, so the app-switcher
  snapshot does not hold them, and they are not restored from scene state;
- after `userDidTakeScreenshotNotification` the screen says that a picture of
  the words may now be in Photos and iCloud, and how to delete it, including
  from Recently Deleted;
- there is no clipboard, following RFC-0026:177-181;
- the text never claims a protection the platform does not give.

Android instead clears `FLAG_SECURE` on its onboarding screens, the words
included, and offers «Скопировать слова», while its «Ник в Devnet» word
dialogs still set the flag
(`clients/android-devnet/src/org/paranoid/devnet/MainActivity.java:66,70`).
It cites an owner decision of 2026-10-05 that has no permalink, and the
recorded rules were not updated (discrepancy 1). If the owner confirms that
decision on GitHub, iOS adds the copy action with `UIPasteboard` `localOnly`
and a short expiry.

### Screens

The order follows Android
(`clients/android-devnet/src/org/paranoid/devnet/OnboardingActivity.java:20`).

- **New nickname:** start, the words, the nickname, registering, the server,
  login, done.
- **Existing nickname:** «Войти», the words, the server screen with the found
  nickname, login.

The texts are Android's where the meaning is the same. In four places iOS
follows a contract that Android does not: the Devnet disclosure, the
canonical-name confirmation, the replacement disclosure and the words screens.
Each difference is listed in the captions gate. The «Аккаунт создан, но вход
не выполнен.» screen (`OnboardingActivity.java:483`) retries the login only. A
failure screen names its error code; Android's «Временный сбой» hides the
reason it computed (`OnboardingActivity.java:338-358`).

The words can be shown again later, from «Мой ID», behind the device-owner
prompt and with the same protections. On Android only the «Ник в Devnet»
screen can do that (`clients/android-devnet/src/org/paranoid/devnet/MainActivity.java:33-49`).

iOS keeps the elements Android does not have: the new-message marks, the
collapsed «Заблокированные» list, the bar that returns to a running call, the
frozen-storage screen, the video cover during screen capture, and the
foreground-only disclosure on «Мой ID». Android v38 removed its «Приложение»
section; copying that change would remove the disclosure of a recorded iOS
difference (`clients/ios/App/ParanoID/Screens/Identity.swift:133-158`).

### What does not change

E2EE, the message and call wire formats, the server with its routes and
limits, the key protocol, and Android. The core's state schema inside the
existing wrapper is unchanged; only the wrapper's realm and pin are a v3 pair
for a new install.

## Implementation increments

Each increment is one pull request inside the iOS component boundary, with a
Mac receipt on its exact head. Recovery, login and the directory come before
registration: after increment 6 an iPhone can join a v3 server with a
nickname whose words come from Android and find other members by nickname.

| # | Increment | Needs | Size |
| --- | --- | --- | --- |
| 0 | This RFC, the gap analysis, the feasibility evidence, the threat delta, and the caption-contract fix for the six captions Android v47 and v48 removed | — | this pull request |
| 1 | Resync with `main`: `java_deps.sh`, the caption pairs PR #69 commented out, the stale `FLAG_SECURE` statements, and a plain message for a contact or a link from another server | question 16 | S |
| 2 | Bridge: the Devnet crate, both exports, the lock rule, `blake3/pure`, notices, CI paths, host tests with the public vectors, the Devnet command specification | questions 1, 2, 3 and 5 | M |
| 3 | ParanoidKit: the profile list, health and paths by kind, discovery first, no automatic repeat on identity routes, realtime on v3; a local identity-v3 stand with a registry fixture; the v2 path regression-tested on the v2 stand | questions 4 and 15 | M |
| 4 | Devnet store, RPC session, the Swift chain checks with Android's negative cases, recovery and its screens, the store specification | questions 6, 8 and 9 | L |
| 5 | Login: status, inspect, enroll, replace, the persisted intent, the owner prompt, the server screen, the replaced and moved states | questions 7, 10 and 13 | L |
| 6 | Directory: search by nickname, the verified add, the own contact card and visibility, a pasted `paranoid.global/c/` link resolved through the directory | RFC-0028's disposition; question 18 | M |
| 7 | Registration: the words, the nickname, the sponsored exchange, the attempt ledger | questions 11 and 12 | M |
| 8 | Remaining screens: «Мой ID» states with the nickname, the words shown again, the notice for an existing v2 install, captions | question 9 | M |
| 9 | Device validation, each live action with its go | questions 14 and 17 | M |

**Effort.** Android's v3 client is about 1,300 lines in
`clients/android-devnet/src` plus smaller changes across six files in
`clients/android/src`, over the shared Rust; its directory adds the search,
add, visibility and link code in `MainActivity.java` and `RealtimeLoop.java`.
In this repository iOS sources run at about 4.2 times Android's line count
(1.4 times by non-comment bytes), and iOS tests add about three quarters
again. That suggests about 7,000 lines of Swift and 5,000 lines of tests, with
a new stand mode and cross-tests. Increments 2 to 9 take about six to nine
weeks elapsed, four to six of them contributor work. This assumes questions 1
to 4 and RFC-0028's disposition by the deadline, a stand available in the
first week, and owner sessions within a week of each request.

## Alternatives

| Alternative | Why not |
| --- | --- |
| Keep iOS on v2 | The v2 service is stopped, so the client would have no server at all. |
| Move iOS to v3 without a nickname | v3 has no self-registration: `/v2/registration/` answers `404`. It would need a server change and an admission policy that does not exist (`docs/protocol/identity-login-v3.md:40-42`). |
| Recovery, login and the directory only, registration later | This is the first milestone of the proposed order (increments 4 to 6). Stopping there would leave an iOS user without an Android unable to obtain a nickname (REQ-ID-003, REQ-ID-004), so registration stays in scope. |
| Two identities in one install | Two snapshots and two contact lists in one application. RFC-0021 excluded a second realm (`docs/rfcs/0021-ios-client.md:188`), and no requirement of this milestone needs it (REQ-MULTI-001 is a draft for later: `docs/product/requirements.md:50`). |
| Two static libraries | Each would keep its Android lock exactly, and they linked into one executable on 2026-10-06 without duplicate-symbol errors. But both carry their own `std` and shared crates, and whether the linker keeps resolving the duplicated members depends on each future toolchain and graph. |
| Owner operations rebuilt inside the iOS bridge over `key-protocol` | `key-protocol` already has the transcript, PDA and record checks (`key-protocol/src/identity_v3.rs`), and the server builds the registration message with `key-protocol` alone, without any `solana-*` crate (`server/src/sponsor.rs:102-149`). The lock rule would hold, but BIP39, SLIP-0010 and the transaction would get a second implementation that no Android test exercises, contrary to RFC-0026:174-175 (draft). |
| Owner cryptography in Swift | Contrary to RFC-0026:174-175 (draft); a second implementation of key derivation and transaction building. |
| RPC through the ParanoID server | The server would vouch for the registry that the client is asked to verify. |
| An external wallet | Contrary to RFC-0026:178 (draft): no external wallet dependency. |

## Security and privacy

The [threat delta](../security/ios-identity-v3-threats.md) records the
details. In short:

- **New secret at rest.** The owner entropy, in a separate pair readable only
  while the phone is unlocked, never backed up or synchronised. The install
  marker defeats Keychain resurrection after a reinstall.
- **New trusted source.** The Devnet RPC, through one system-trust session.
  An interceptor with a certificate the trust store accepts can show a false
  registration or a false recovered name; the v3 server's own registry check
  stops it from creating a membership. A dishonest RPC provider can also
  create a false membership and pass a false directory add, because the
  servers read the same provider by default. Both see the phone's lookups.
- **New observers.**
  - The RPC operator sees the phone's IP address and which owner and nickname
    it looks up.
  - The chain makes the nickname-to-owner binding public and enumerable
    (RFC-0026:182); the deployed program has no rename, transfer or close
    (RFC-0026:131-132).
  - The v3 server sees the owner and the nickname, as well as everything the
    v2 server saw, and learns who searched for whom.
  - Other active members of the same server see a visible member's nickname,
    owner key, identity PDA, credential and contact card; members are visible
    by default.
- **Words on screen.** Screenshots cannot be prevented; capture and the app
  switcher are covered, with a window before the cover appears.
- **Replacement race.** Whoever holds the words or the old phone's key can
  take the login back, once per 24 hours. ADR-0016 records this as a
  private-alpha limit (`docs/decisions/0016-solana-server-authentication.md:28-35`);
  the owner accepted it for the local Devnet mode only (`:62-75`), not for any
  deployment (`:78`).
- **The sponsor.** The v3 server can front-run, withhold or delay a sponsored
  registration. Anyone who can reach it can spend its per-process caps
  (RFC-0026:32-35; `docs/security/threat-model.md`, section «Fresh Solana
  Devnet identity boundary»), and because the
  realms and pins are public in the repository, anyone can also fill its 128
  memberships.
- **Contacts by nickname.** Without QR, a contact's binding rests on the
  directory proof and the registry read through the RPC, not on a
  comparison in person.
- E2EE, the first-contact channel and the call channel are unchanged.

## Compatibility and migration

- **Existing iOS installs** keep their saved v2 trust and are never switched
  silently. With the v2 service stopped they cannot connect. The way forward
  is a clean reinstall: delete the app, install it, onboard on v3. The phone
  gets a new ID, and v2 contacts and history stay behind, because the pin is
  part of the contact transcript (`docs/rfcs/0021-ios-client.md:550`). The v2
  accounts stay on that server, which has no deletion path. Question 9 chooses
  between this and an in-app restart, and what a v2 install shows meanwhile.
- **Rollback.** An older build on a clean install creates a new v2 identity,
  which is itself a live registration, against a stopped service. The v3
  membership and the nickname remain on the server and on chain.
- **Downgrade over an installed v3 build.** An older build reads a v3 realm,
  refuses the health protocol and stops. Installing a v3-capable build over it
  restores service; deleting the app loses the identity and needs the words.
- **v2 and v3 users cannot pair** until a federation or a bridge exists.
- **Server.** No change. A v3 database reset makes active iPhones `absent`,
  and they log in again explicitly.

## Operations and observability

There is no server, deployment or configuration change. The client logs no
words, entropy, keys or signatures, only error codes.

Each of these is a permanent live action and needs the owner's go, with a
permalink in the evidence:

- a signed install of a v3-capable build on the contributor's iPhone;
- each Devnet nickname registration: on chain, and with the deployed program
  it cannot be renamed, transferred or closed (RFC-0026:131-132); an owner
  holds at most one name;
- each v3 enrollment, which takes one of 128 membership slots;
- each replacement, at most seven per membership and one per 24 hours;
- each joint test with the owner's Android phone.

Proposed budget for increment 9 (question 14):

- one nickname created on the iPhone, and its enrollment;
- one replacement from the iPhone to the iPhone itself through a clean
  reinstall, recovering the nickname from the words;
- a joint test with the owner's Android on the same server, each phone under
  its own nickname: each finds the other in the directory, then text and
  calls; each phone also publishes its directory card.

An Android leg of the replacement test needs a spare Android or a clean
reinstall of the owner's application, which loses that phone's identity and
contacts and spends one of his generations and a 24-hour cooldown. It is
included only if the owner chooses it.

Increment 9 starts with the owner confirming the state of the chosen v3
server: its build and schema, whether the sponsor is configured, and its
balance. The PR #67 schema initializes only an empty database
(`server/src/identity_v3.rs:83-87`).

Development builds should not replace the contributor's daily install, or
switching between heads can freeze it (question 17).

Any distribution beyond the contributor's phone reopens Apple questions that
this RFC does not answer:

- the export-compliance inventory (`docs/clients/ios/export-compliance.md:27-37`)
  gains BIP39 (PBKDF2-HMAC-SHA512), SLIP-0010 (HMAC-SHA512), Ed25519
  transaction signing and TLS to the RPC;
- App Review asks for in-app account deletion where accounts are created. The
  servers have no deletion path, and a Devnet nickname is permanent; this
  applies to the current v2 client already;
- the words import into ordinary Solana wallets, which App Review may treat
  as a wallet.

The two App Review points are guidelines 5.1.1(v) and 3.1.5(i), to be checked
against Apple's current text before any upload.

## Validation plan

### Done on 2026-10-06 (build Mac)

The [feasibility evidence](../project/evidence/ios-identity-v3-20261006/feasibility-mac.md)
records the commands and outputs, at `62e50e4`; the later commits on `main`,
through `2470dca`, change only Android files. None of it is phone evidence.

| Check | Result |
| --- | --- |
| `cargo check --locked --target aarch64-apple-ios` of `blockchain/solana/client` | compiles unchanged, including `jni` |
| `cargo test --locked --lib` of the same crate on the Mac | 10 passed |
| One static library with the core and the Devnet crate, release, `aarch64-apple-ios` | builds |
| That library linked into an iOS arm64 executable | links; not run |
| The existing bridge (built at `438c79e`) and a separate Devnet library linked together | links without duplicate symbols; not run |
| A Rust binary calling both crates directly, on the iOS simulator (iPhone 17 Pro, iOS 26.5) | passes: 12 words, recovery, the public vector `HAgk14…`, offline registration signing, core `create_identity` then `upgrade_v2` then `identity_credential_v3` |
| `cargo check --locked` of `server/` on macOS | fails on `O_TMPFILE` (`server/src/android_updates.rs:297`) |

### Per increment

- **[CI]** The iOS static gates, with the restated bridge-lock rule, notices
  and captions.
- **[Mac]** `swift test`, application tests and simulator runs against a local
  identity-v3 stand with a registry fixture, as Android's
  `clients/android/test_identity_login.py` does
  (`PARANOID_MODE=identity-v3-local`, `PARANOID_REGISTRY_FIXTURE`).
  - The server does not build on macOS. The stand needs either a small
    portability fix in the server (cfg-gating the Linux-only `O_TMPFILE`
    snapshot in `server/src/android_updates.rs:293-299`), as a separate pull
    request for the owner's agents, or a Linux container on the build Mac
    (question 15).
  - `clients/ios/local_stand.py` knows only `self-service-v2-local`
    (`:71-72`), and `clients/ios/test_android_compatibility.py` has no v3
    operation. Increment 3 adds the identity-v3 mode and a v3 scenario.
  - Every pull request that touches the profiles, health, transport or
    `ProofFlow` also runs the v2 path on the v2 stand.
  - RPC flows use an injected fake transport. Simulators never touch Devnet or
    a v3 server.
- **[device]** The live actions above, each with its go.

### Requirement-to-test mapping (proposal)

| Requirement or gate | iOS test | Status |
| --- | --- | --- |
| REQ-ID-001, REQ-ID-005 | onboarding asks for no phone number or email; keys are made on the phone | NOT RUN |
| REQ-ID-002 | recovery from 12 and 24 words; the public vector; no history restored | vector CLAIMED (feasibility check R, a simulator Rust binary); flow NOT RUN |
| REQ-ID-003, REQ-ID-004 | sponsored registration with a finalized paired readback; sponsor limits honoured | NOT RUN |
| REQ-ID-007 (as amended under question 18), REQ-MSG-005 | directory search and verified add with Android on the same v3 server: core `verify_directory_entry_v1`, Rust `lookup` and the finalized paired readback, «Добавить @nick?» with the fingerprint, `pair_directory_entry_v1`; then first contact and reply; the own card and visibility; a pasted link for this server and for another; a registry mismatch or an RPC failure adds nothing | NOT RUN |
| AUTH-02 | pins, PDA layout, RPC lies, outages and size limits | NOT RUN |
| AUTH-03, AUTH-04 | replay, expiry, restart, a lost commit reply retried with the same persisted intent | NOT RUN |
| AUTH-06 | E2EE first contact, reply, receipts, fresh-contact replacement, a retired recipient | NOT RUN |
| AUTH-07, iOS analogue | Keychain and marker restart, recovery, old auth rejected, hostile re-replacement disclosed, explicit confirmation | NOT RUN |
| AUTH-08 | generation 8 and the cooldown, with traffic still working | NOT RUN |
| REQ-SEC-001 | the threat delta reviewed | NOT RUN |

The AUTH gates are defined in `docs/protocol/identity-login-v3.md:442-458`.
The statuses follow `docs/clients/ios/verification.md:110-114`.

### Acceptance criteria (proposed; the owner confirms)

The setup is the contributor's iPhone and the owner's Android, each with its
own nickname, on the same v3 server.

- The iPhone creates and registers a nickname and logs in.
- The iPhone and the Android find each other by nickname in the directory,
  each add passing the registry check, and they exchange text with receipts,
  a voice call and a video call.
- After a clean reinstall, the iPhone recovers the nickname from the words and
  replaces its earlier device, with the disclosed consequences.
- Every iOS gate is green, with a Mac receipt on the exact head.

No two-phone exchange through a v3 server is recorded yet, even between two
Android phones. A failure is therefore attributed to iOS only if it reproduces
on the local stand, or if two Android phones succeed on the same server.

## Discrepancies found while preparing this RFC

These are reported, not resolved here (`AGENTS.md:49-50`). Each affects a
choice above. The follow-up owner is the owner's agents unless a decision
names another. Documentation drift that does not affect iOS is in
[the gap analysis](../project/evidence/ios-identity-v3-20261006/gap-analysis.md).

1. **The words screens.** RFC-0026:48-49 and 177-181 require screenshot
   protection and exclude the clipboard for the words, and
   `docs/security/threat-model.md` (section «Fresh Solana Devnet identity
   boundary») names `FLAG_SECURE` on the words screens as the only
   mitigation. Android clears the flag on its onboarding
   screens, the words included (`OnboardingActivity.java:604-607`), no longer
   sets it on the call window (`clients/android/src/org/paranoid/text/MainActivity.java:514`,
   a comment recording the removal), and adds «Скопировать слова»
   (`OnboardingActivity.java:166-171`). Its screens still say «Скриншот этого
   экрана запрещён.» (`:136`) and «Экран защищён от скриншотов.» (`:365`). It
   cites an owner decision of 2026-10-05 that has no permalink.
2. **The login intent.** `docs/protocol/identity-login-v3.md:127-128`,
   197-200 and 226-231 require a persisted, immutable login intent. Android
   creates a fresh operation UUID on every run (`IdentityLogin.java:19-25`).
3. **Replacement disclosure.** `docs/protocol/identity-login-v3.md:392-393`
   and 419-421 require the remaining replacements, a clear capacity error and
   the peer-cap disclosure. Android's dialog says only that the old phone is
   disconnected (`OnboardingActivity.java:465-473`).
4. **Devnet disclosure and confirmation.** RFC-0026:72 and 226 require the
   app to say "Devnet" and to confirm the canonical name before signing.
   Android's onboarding avoids those words (`OnboardingActivity.java:21`),
   unlike its «Ник в Devnet» screen, and «Занять ник» signs without a
   confirmation (`:268-276`).
5. **The own-SOL fallback.** RFC-0026:36 allows it only when the sponsor
   reports `limit` or `empty`. Android falls back on any non-200 answer except
   `sponsor_used` (`OnboardingActivity.java:303-309`).
6. **The program pins.** RFC-0026:196 makes Rust `program_info` the only
   source of the pins. `IdentityLogin.java:14` carries `GENESIS` and `PROGRAM`
   literals again.
7. **The sponsor blockhash.** RFC-0026:22-24 says the server rebuilds the
   bytes with its own recent blockhash; `server/src/sponsor.rs:194-195`
   accepts the caller's. iOS uses the blockhash from `/v3/sponsor/prepare`,
   as Android does: a forced exception to goal 5 until the server or
   RFC-0026 is changed.
8. **Stale protocol status.** `docs/protocol/identity-login-v3.md:14-22` says
   Android login is not implemented and that only `identity-v3-local` exists.
   Android implements it (`IdentityLogin.java:71-99`), and the remote
   `identity-v3` mode exists (`server/src/main.rs:137-142`).
9. **Admission and deployment.** `docs/protocol/identity-login-v3.md:40-42`
   requires an admission policy decision before any non-local mode. The code
   has none, and the owner's own logins are recorded on the test VPS, so
   admission there is open. Identity v3 now also runs on the production host
   (commit `b488331`), and ADR-0016's approvals leave "any deployment"
   unauthorized (`docs/decisions/0016-solana-server-authentication.md:78`).
   No owner permalink covers either server, or the stop of v2.
10. **Permitted surfaces.** `docs/protocol/identity-login-v3.md:299-318` lists
    the only permitted surfaces in v3 mode without `/v3/sponsor/`, which the
    server mounts (`server/src/sponsor.rs:301-307`; `server/src/main.rs:305-320`).
11. **Sponsor answer.** Android maps `409 sponsor_used` to a taken name
    (`OnboardingActivity.java:304-305`). It means that the key has tried three
    distinct names through this server process (`server/src/sponsor.rs:210-219`).
12. **Generations.** The owner's approval allows "до 8 смен телефона на
    человека" (`docs/decisions/0016-solana-server-authentication.md:58-59`);
    the protocol and server allow seven replacements, because the eight
    generations include the enrollment (`docs/protocol/identity-login-v3.md:387-392`;
    `server/src/identity_v3.rs:26,408-412`).
13. **The servers and the nickname line.** Android's sponsor goes to the
    production host and its login to the test VPS
    (`OnboardingActivity.java:513-516`; `TextEngine.java:289-290`). The v44 to
    v46 commits change only the version code: the server-choice screen named
    in v44's message is not in the repository, and the «Мой ID» changes named
    by v45 and v46 arrived with v47. Its nickname line reads `solana_nick`,
    which nothing sets; the view carries `directory_name`
    (`MainActivity.java:956-964`; `TextEngine.java:436`), so the line stays
    empty and v48 shows «Нет ника». Open PR #70 fixes that.
14. **Verified QR bindings.** REQ-ID-007 asks to add contacts through
    explicitly verified public QR key bindings (`docs/product/requirements.md:34`).
    Android v47 removed its own QR and the contact fingerprint from «Мой ID»
    (`MainActivity.java:205-208,226`), citing an owner decision of 2026-10-05
    without a permalink, and changed its UI contract test to match
    (`clients/android/test_ui_contract.py:234-236`). iOS keeps its QR and
    fingerprint until the owner records a decision.

## Amended statements

None of these documents is edited in this pull request. Editing RFC-0021 or
ADR-0014 would move their "exact review revision" gate
(`docs/rfcs/0021-ios-client.md:530-532`;
`docs/decisions/0014-ios-client.md:23-26`).

| Document (status) | Statement | Proposed change |
| --- | --- | --- |
| RFC-0021 (proposed) `:92-100` | the existing hosted alpha; "no new key material format and no new trust anchor" | identity v3 servers; the owner entropy, further pins and one system-trust session |
| RFC-0021 `:151-152`; ADR-0014 (proposed) `:44-47` | the identity reference is Android v15 against the same hosted alpha | Android's current client for identity v3, contracts first |
| RFC-0021 `:188-190` | non-goals: identity recovery, a second realm, blockchain naming, server selection UX | recovery and blockchain naming added; a second compiled profile for fresh installs added; two realms in one install still excluded; server selection limited to confirming compiled profiles; multi-device still excluded |
| RFC-0021 `:200-203`; ADR-0014 `:86-93` | the bridge depends on the core alone and exports `paranoid_core_command` and `paranoid_core_free` | plus the Devnet crate and two Devnet exports |
| RFC-0021 `:281-283`; ADR-0014 `:112-119,138-147`; `docs/security/ios-client-threats.md:30,77` | leaf-SPKI pinning, "not by delegating to system trust", "never on a CA chain" | unchanged for every ParanoID server; one system-trust session to the Devnet RPC |
| RFC-0021 `:306-313`; `clients/ios/README.md:1904-1912` | "Not touched: identity derivation, key material"; one realm and pin, no second pin | iOS gains owner key material and a list of compiled profiles; saved trust still wins |
| RFC-0021 `:376-377` | no migration: no previous iOS state | existing v2 installs move only by a clean reinstall |
| RFC-0021 `:513-526`; ADR-0014 `:33-35,52-55` | closed-alpha scope: hosted self-registration, QR exchange in both directions, the existing hosted endpoint only; four protected domains | nickname registration, the directory add, the v3 servers and the Devnet RPC; the domains in the rationale above |
| `docs/product/requirements.md:34` (REQ-ID-007) | add contacts through explicitly verified public QR key bindings | contacts added by nickname through the directory and the registry if question 18 is answered that way |
| ADR-0014 `:266-269`; `clients/ios/test_app_bundle.py:10,70` | one bundle identifier, `global.paranoid.messenger` | a development-only second App ID if question 17 is taken; Release unchanged |
| `clients/ios/test_bridge_lock.py:2-11`; `docs/security/ios-client-threats.md:121` | the bridge lock equals the core lock | the restated two-lock rule |
| `docs/security/ios-client-threats.md:70-71` (draft) | no change to realm/pin, and no automatic recovery, authorized | a second compiled profile and explicit recovery; automatic recovery still excluded |
| RFC-0027 (draft) `:23-24`; ADR-0016 (proposed) approvals | iOS excluded; the approvals cover Android's local mode | an iOS-specific disposition |

ADR-0014's driver of zero changes to the core, the key protocol, the server
and deployment (`docs/decisions/0014-ios-client.md:59-60`) still holds,
because a path dependency is not an edit.

## Ordering with RFC-0021 and ADR-0014

RFC-0021 (decision deadline 2026-10-15) and ADR-0014 (proposed, without a
deadline of its own) are still proposed. Proposed order: the owner disposes
of RFC-0021 and this RFC together. RFC-0021's acceptance is retargeted to a
v3 server, since v2 is stopped: hosted self-registration becomes nickname
registration, and the QR exchange in both directions becomes the directory
add. The resulting ADR records the identity-v3 decision for iOS, and
ADR-0014 gets a pointer to it when both are disposed.

## Open questions

The decision owner is `martadvix-web` for every item. Items 1 and 2 block
`proposed`.

| # | Question (proposed answer) | Needed by |
| --- | --- | --- |
| 1 | Product scope: does iOS adopt identity v3 for fresh installs, and which v3 profiles does it compile: production `157.180.49.125:38444`, the test VPS `138.16.180.53:38444`, or both? The joint test needs the server the owner's Android logs in to; in the repository that is the test VPS (`TextEngine.java:289-290`). | `proposed`; 2026-10-15 |
| 2 | Confirm `decision_deadline` 2026-10-15, aligned with RFC-0021, or set another. | `proposed` |
| 3 | A permanent approval of the exact closed-alpha scope above, and a separate go for each live action. | increment 2 |
| 4 | Admission policy and bounded deployment authorization (isolation, rollback) for the chosen v3 servers: for example, open self-admission accepted for this alpha with the Sybil residual of ADR-0016:39-46, extending the REQ-ID-006 exception. | increment 3 |
| 5 | The bridge: one static library with the restated lock rule (proposed), two libraries, or owner operations over `key-protocol`. | increment 2 |
| 6 | The Devnet RPC through the system trust store for one host (proposed), optionally with a CA-set pin or a second provider. | increment 4 |
| 7 | Owner signing behind a device-owner prompt (proposed) or a tap; and, on a phone without a passcode, a tap with a stated weaker guarantee or refusal. | increment 5 |
| 8 | The owner entropy at rest as specified, readable only while unlocked (proposed). | increment 4 |
| 9 | The words screens: the recorded rule (proposed) or the 2026-10-05 decision with a copy action, confirmed on GitHub, with RFC-0026 and the threat model aligned for Android too; and what an existing v2 install shows while v2 is stopped (clean reinstall only, proposed, or an in-app restart). | increments 4 and 8 |
| 10 | The server screen: both v3 profiles to choose from, or one confirmation. | increment 5 |
| 11 | The sponsor only (proposed), or also the own-SOL and faucet fallback. | increment 7 |
| 12 | Wording: say "Devnet" and confirm the canonical name before signing (RFC-0026:72, 226; proposed), or Android's wording. | increment 7 |
| 13 | The login intent persisted as the protocol requires (proposed for iOS), and whether Android follows. | increment 5 |
| 14 | The live-action budget for increment 9, whether it includes an Android leg of the replacement test, and the confirmed state of the chosen v3 server. | increment 9 |
| 15 | The local identity-v3 stand: the server portability fix, or a Linux container on the build Mac. | increment 3 |
| 16 | The call screen: keep covering video during capture, which is stricter than Android since 2026-10-05 (proposed), or follow Android. The iOS documents that describe Android's call window as protected are corrected either way. | increment 1 |
| 17 | Development builds under a separate bundle identifier (proposed), which needs a new App ID in team `5RPGVC566Q` and a development exception in `clients/ios/test_app_bundle.py`, or one install with a clean reinstall at each change of realm. | increment 9 |
| 18 | Contact exchange: by nickname through the directory only, with QR removed on both clients (proposed: the direction relayed by the contributor on 2026-10-06), or QR kept alongside; REQ-ID-007 amended to match either way. | increment 6 |

## Decision and follow-up

- Disposition: pending.
- Decision-owner approval permalink: pending.
- Delegation evidence permalink:
  <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919>
  (technical authority only).
- Required-review evidence permalinks: pending, namely the independent AI
  review of the exact revision.
- Resulting ADR: to be drafted after question 1, with the next free number.
- Closure rationale for `completed`, `rejected`, `withdrawn`, or `superseded`:
  none yet.
- Replacement RFC for `superseded`: none.
- Implementation issues: increments 1 to 9 above.
