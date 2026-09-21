# Devnet deployment and acceptance gates

This is a procedure, **not an executed deployment receipt**. Scope: RFC-0026,
private test-data Devnet registry; no Mainnet, wallet reuse, DB/phone wipe or APK
feed publication. Independent code review does not replace owner authorization.

## Preflight and bounded deployment

1. Record owner deployment authorization and approved source/artifact hashes.
   Use Agave4.3.0 explicitly, no default Solana CLI profile/network/key configuration.
   All private signers are dedicated locally retained0600 Devnet files outside Git.
   Never print their contents. A separate explicit buffer signer avoids a CLI
   failure printing a newly generated buffer seed; keep raw error logs private
   and sanitize before sharing. Do not use program/upgrade keys as buffer keys.
2. Read `getGenesisHash` from `https://api.devnet.solana.com` and require
   `EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG`. Record live `getVersion` and
   finalized slot; confirm the feature allowing this SBF architecture is active
   (in particular check whether SIMD-0500 has disabled v0 deployments).
3. Rehash the SBF and require `program_info`'s exact size/hash. The reviewed
   artifact is73800 bytes, SHA256
   `ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa`.
   Read public keys from the program and upgrade-authority files and compare
   against RFC0026; no silent regenerated program ID or repinning.
4. Query live rent for ProgramData73845, Program36 and Buffer73837 bytes plus
   expected transaction fees. Confirm Devnet balance; record a bounded fee and
   retry budget before signing. Never silently raise compute-unit price/retries.
5. On explicit owner authorization only, the deploy invocation must name:
   `--url https://api.devnet.solana.com`, explicit `--keypair`, `--fee-payer`,
   `--program-id`, `--upgrade-authority` and `--buffer` file paths;
   `--max-len 73800`, `--no-auto-extend`, `--use-rpc`,
   `--with-compute-unit-price 0`, and a bounded `--max-sign-attempts`.
   Do not use `--skip-preflight`, `--skip-feature-verify` or `--final`.
   Reconcile a timeout using the retained buffer/program state before any retry;
   never blindly create another program or treat a submission as a receipt.

## Independent post-deployment verification

- Record transaction signatures and finalized slots, cluster genesis/node version,
  program ID, ProgramData PDA, upgrade authority, allocation size and balance delta.
- Fetch both loader accounts in one finalized bank context, validate exact
  Program36 and ProgramData73845 byte layouts, authority and bytecode digest.
  Run the actual client gate; a CLI success alone is insufficient.
- Independently dump the deployed program using explicit Devnet settings and
  compare its size/SHA256 byte-for-byte with the reviewed SBF artifact.
- Rebuild and verify the APK/native payload against these SAME pins and the
  expected test signer. Never update pins from an unverified network response.
- Only then exercise a separate fresh test identity's registration and exact
  retry, finalized readback of BOTH registry records, and seed recovery. Record
  real public handles and costs; do not label local fixtures as chain evidence.

## Rollback, pin changes and phone acceptance

An incorrect allocation/program/authority is a stop condition. Do not reset
phones, change program ID, close on-chain accounts or spend more as automatic
recovery. A new ID requires reviewed repinning and a fresh signed artifact.
Retain receipts/buffer state; closing a deployed program is a separate explicit
operator action and would stop clients using it.

`DevnetStore` rejects persisted state from another program/network. Thus changing
the program ID is NOT a transparent application update. It requires a separately
approved fresh-install/recovery flow; recover the24 words to the same owner but
do not claim that registrations move between program IDs. No automatic wipe.

The current APK is ARM64-only (minAPI26); check the test phone ABI before use.
`MainActivity` and `DevnetStore` **are compiled by build.sh** into the signed APK,
but their lifecycle/reconciliation logic is NOT executed by host JNI tests.
The review's N4 wording that they were not compiled is incorrect; its substantive
runtime-test gap is valid. Before phone acceptance: fix exhausted-attempt UI and
bounded identical-wire rebroadcast; test save-before-send, interruption/restart,
Keystore loss and recovery with explicit preservation of unresolved attempts.
The storage freeze currently lasts only until process exit, not a durable latch;
this limitation is stated in code and evidence. No production guarantee follows.
