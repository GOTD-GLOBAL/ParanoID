---
status: draft
owner: identity
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-21
---

# RFC-0026: Fresh Solana Devnet nickname registration

## Owner scope and non-goals

Sergey Maltsev directed starting Solana Devnet and explicitly stated that current
accounts/messages are disposable test data and need not be preserved. This removes
legacy-account linking/migration as a gate for THIS Devnet transition only. It is
not a global deletion/backup exception or an instruction to wipe the hosted DB,
phones, signing keys or TLS. Telegram provenance has no available permalink.

The prior proposal to preserve/link existing accounts is superseded for this
slice. Mainnet, real funds, existing wallets, tokens/NFTs, name transfers, server
login, multi-server messaging and automatic phone/server reset are NOT in this
first registration increment. The completed target is a real registration from
Android, a finalized registry lookup and seed recovery of the same test authority.
The app must say Devnet; its names are not reserved on Mainnet. No permanent
architecture acceptance or production security claim is made.

REQ-ID-001/002/003/004/005, REQ-CLIENT-001, REQ-SEC-001 apply. ADR-0001/0003
retain documentation/review gates. Historical PR1/RFC0002 is research, not accepted
code to merge. The owner's public blockchain identity direction is retained:
servers can correlate a public identity; no on-chain social/device/server graph.

## Minimal registry contract

A native Rust Solana program, no token/NFT dependency. Initial instruction:
`RegisterV1 = [1, name_length, canonical_name_bytes]`, exact input length only.
Reject unknown instruction tags (anything except 1).
Names: 3..24 ASCII bytes, first character a-z, remaining a-z/0-9/underscore.
The client normalizes ASCII case visibly; the program rejects noncanonical input.

Accounts in exact order: payer (writable signer), owner (signer), identity PDA
(writable), nickname PDA (writable), System Program (exact ID). Payer and owner
may be the same wallet. All other aliases are rejected by exact PDA/owner checks.
Both payer and owner must authorize the transaction; a sponsor cannot seize a name.

PDA seeds (program ID is part of the address derivation):

- identity: `['paranoid-identity-v1', owner_public_key]`;
- nickname: `['paranoid-name-v1', canonical_name_bytes]`.

Registration binds one name to one owner, and one identity to one name. No rename,
transfer, close, authority rotation or epoch change is exposed in this increment.
Recovery regenerates this same owner; later rotation/revocation needs a new reviewed
contract and cannot be claimed from registration alone. Identity address must not
later be silently re-derived from a changed controller.

State layouts use fixed bytes, no dynamic strings:

Both records are 128 bytes: magic (8), version=1 (1), canonical bump (1), owner
(32), other-record PDA (32), name length (1), zero-padded name (24), reserved
zero bytes (29). Identity magic is `PNDID001`; nickname magic is `PNDNAME1`.
Readers/retry validate all fields and zero padding, not only the name.

The program derives each canonical PDA with `find_program_address`, validates
its supplied key, and uses the returned canonical bump in `invoke_signed`.
The caller does NOT select a bump or an alternative valid address. State stores
the canonical bump; retry verifies it. No bump field in instruction is necessary.

Both records are created in ONE atomic transaction. Exact repeat with both records
valid is an idempotent success; occupied name/identity, partial or malformed state
is rejected without mutation. Existing zero-data System-owned prefunded PDA accounts
are supported by rent top-up, signed allocate and assign, not rejected merely for
having lamports. Require System owner and empty data; transfer only the rent
shortfall from payer, then allocate and assign under the canonical PDA seeds.
Rent comes from the runtime Rent sysvar for 128 bytes; excess is not refunded.
Non-System foreign owners or unexpected data fail closed.
Rent and transaction costs are measured, not hardcoded as a monetary promise.

## Client and transaction boundaries

The registration key is NEW and Devnet-only, not the installed messenger root,
Olm key, APK signer or any real-money wallet. Recovery uses a standard reviewed
BIP39/SLIP-0010 construction with explicit derivation path and public vectors;
no custom cryptographic primitive or reuse of historical experimental salts.
The selected path is `m/44'/501'/0'/0'`, hardened-only ed25519 SLIP-0010,
24 English BIP39 words and empty BIP39 passphrase. Pin `bip39=3.0.0` and
`ed25519-dalek-bip32=0.3.0`; verify published SLIP-0010 vectors and an independent
public 32-byte-entropy BIP39/path reproduction before generating phone keys.
This is a Devnet-only construction, not adoption of historical HKDF salts.
Derivation, transaction construction/validation and signing live in shared Rust
behind JNI. Java owns Android Keystore wrapping/unwrapping and passes transient
entropy to native code; mnemonic text necessarily crosses JNI for explicit backup
or recovery UI. Managed-memory copies cannot be guaranteed zeroized; no seed
logging/clipboard/backup is permitted. No UniFFI or external wallet dependency.
Android storage uses authenticated encryption and its Keystore, with no backup,
plaintext logging or automatic recreation after ambiguous loss. Seed display
requires explicit user action and screenshot protection; seed recovery is not
chat-history recovery. Public nickname and owner are inherently enumerable.

RPC access must verify the configured Devnet genesis identity before requesting
airdrop, building/signing or submitting a transaction. Dedicated hardcoded approved
program ID/cluster; no user-supplied arbitrary transaction signing or Mainnet URL.
The new program keypair is generated privately before the first deployment;
its public ID is pinned in tests and the client. Keep this key and a separate
Devnet upgrade authority outside Git/APK. Losing the program key before initial
creation can force choosing a new ID; after deployment, upgrade authority is
separate and program-key loss does not by itself change the deployed address.
Record explicit upgrade authority and verify program dump against the SBF.
The candidate program ID is `C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas`;
its generated keypair exists outside Git/APK, verified by public-key readback.
Upgrade authority is `5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm`.
Rust `program_info` is the sole source of the Android program/network/authority
pins, canonical ProgramData PDA, SBF size and SHA256. Android obtains both loader
accounts in one finalized `getMultipleAccounts` response and validates exact
loader ownership, executable flags, state tags, canonical PDA linkage, present
expected authority, exact allocation length and bytecode SHA256 before signing.
The release does not reserve extra program bytes. A bytecode/authority/size change
requires explicit review and updated client pins; never learn new pins from RPC.
Before delivery, deploy that exact artifact, independently dump/read back its
hash and authority, and rebuild/verify the signed APK against those same pins.
An RPC lie or upgrade between verification and execution remains possible: these
checks are not a light client or an atomic on-chain bytecode lock.
Program code cannot by itself attest its cluster; deployment/client safeguards
are therefore mandatory. Every deployment CLI operation names Devnet explicitly;
no global Solana default or production keys. Deployment authority is a separate
private Devnet test key, never included in APK or Git.

Client validates the entire locally built transaction: program, instruction,
accounts, signer set, fee payer, blockhash and bounded fee/rent before signing.
Lost submission response means UNKNOWN/PENDING, not failure or name success.
After finalized confirmation read BOTH PDA records; require exact owner program,
magic/size/name/owner and mutual references. Signature acknowledgement alone is
not registration success. Persist signed transactions and the signature SET for
all attempts before sending; reconcile every outstanding attempt.
Poll signature status with history search. If finalized success, verify both
records; if finalized error, reconcile both records before reporting conflict.
While the blockhash is valid an unknown response remains pending. Rebuild only
after finalized block height exceeds lastValidBlockHeight, with both PDA reads
at finalized commitment. After that finalized expiry,
our exact mutually-consistent records mean success; both absent permit a rebuilt
transaction; conflicting/malformed/partial records are terminal, not blind retry.
The nickname is shown in canonical form for explicit confirmation before signing.

For deployment, query actual rent for the built program-data allocation and
fees; record required lamports before requesting funds. Funding source is the
official Devnet faucet (RPC or owner-mediated faucet UI), with at most three
bounded RPC attempts, respecting rate-limit responses, and no paid SOL. A failed
faucet is a deployment blocker, not permission to fabricate a transaction.
Use a small bounded test-SOL faucet allowance; do not retry faucet rate limits
indefinitely, ask for paid SOL or embed a faucet/sponsor private key in the app.
If public Devnet RPC/faucet/deployment is blocked, report the real blocker and
retain executable local tests rather than fabricating a program ID/transaction.

## Threats and limitations

Replay/cross-name writes: exact derivations, owner signature and idempotent state.
Substitution: exact System Program, program ownership, PDA and fixed layouts.
Squatting/front-running remain a known limitation of this bounded test-only slice;
mainnet/public registration requires reviewed anti-front-running/economic policy.
A copied signed transaction cannot change its owner. RPC responses remain a trust
boundary; HTTPS/finalized RPC is not a light-client proof of chain correctness.
Upgradeable Devnet program authority can change program behavior; independent
review and a separate governance decision precede any Mainnet deployment.

No device list, server membership, endpoint, contact, plaintext or private material
is stored on-chain. Losing the seed loses control; no operator recovery promise.
Full device revocation/server challenge authentication is a later stage, not
implicitly implemented by wallet registration. Existing TLS/E2EE are not weakened.

## Acceptance

TDD: invalid name/length/version/trailing data; missing payer/owner signatures;
wrong System Program/PDA/readonly/foreign ownership; occupied name, second name;
prefunding; malformed/partial state; exact retry; transaction rollback on failure.
Run the built SBF under LiteSVM 0.16.0 (Agave runtime), not a hand-written
model. Toolchain: verified Agave 4.3.0, platform-tools v1.57, SBF architecture v0.
The resolved LiteSVM lockfile pins Agave runtime 4.2.2; record this older-runtime coverage explicitly,
not as identical to CLI4.3.0 or to the independently queried Devnet node version.
Build an SBF artifact; retain tool/dependency versions and artifact hashes.
Independent design and code/artifact review before Devnet deployment/client use.
Real Devnet deployment/registration must have readable public program/transaction
handles and verified state. Android compilation/host checks are not phone evidence.

Local implementation and checks are recorded in the
[review evidence](../project/evidence/solana-devnet-20260921/README.md).
This remains a draft proposal, not an accepted architecture. Chain deployment,
real registration and physical-phone storage/lifecycle acceptance remain separate
unperformed gates at the time of the local review packet.
