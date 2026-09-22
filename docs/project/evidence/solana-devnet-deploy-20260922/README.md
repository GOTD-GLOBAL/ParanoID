# Authorized Solana Devnet deployment — 2026-09-22

## Authority and exact scope

Sergey Maltsev explicitly instructed **«Деплой в девнет»** in Telegram after the
B1-B5 closure report and request for deployment authorization. No Telegram
permalink is available. This authorizes this bounded test-data Devnet deployment,
not Mainnet, merge, architecture acceptance, phone reset or APK publication.
RFC-0026 remains draft; ADR-0001/0003 gates remain. The prior independent
[code/artifact and documentation reviews](../solana-devnet-20260921/README.md)
approved this exact SBF for bounded Devnet deployment and chain verification.

Source revision: `1867e54e061a5daf07e98c7bfc4052003d035d21`.
Deployment was performed using Agave4.3.0; live node reported4.3.0-rc.0.
Devnet genesis matched `EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG`.
SIMD-0500 was inactive at preflight, so the reviewed SBFv0 remained deployable.

## Actual result

- Program: `C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas`.
- ProgramData: `3WzWMcWhaZtbCGubaJHUfVRm5edgkr4amWLWdHVkQLFr`.
- Upgrade authority: `5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm`.
- Deployment slot: `502240101`, transaction **finalized**, `err: null`.
- [Public program](https://explorer.solana.com/address/C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas?cluster=devnet).
- [Deployment transaction](https://explorer.solana.com/tx/4dFfANwtzdq6iEwBM1GTd2iYLFowe3xXQBrBPYdjqxPSAwVPT6VNP3EnCuLwuHzhdJDc6NT3tywRYrCxyMk6PH1a?cluster=devnet).

The exact73800-byte SBF was deployed with `--max-len 73800`,
`--no-auto-extend`, explicit Devnet URL/signers/buffer, `--use-rpc`, priority
price0 and `--max-sign-attempts 1` per invocation. No skip-preflight,
feature-bypass, finalization-of-authority or implicit default signer was used
for transactions. No global Solana config was changed.

Finalized ProgramData length is73845 bytes and Program account length36.
The unchanged reviewed Java/JNI client trust gate passed on **live RPC**:
paired loader accounts, canonical PDA linkage, authority, size and bytecode hash.
The separate CLI program dump was byte-for-byte equal to the local reviewed SBF:
`ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa`.
Both methods use the official Devnet RPC; this is not an independent-provider
consensus check or a light-client proof.

## Interrupted upload and reconciliation

Public RPC stopped the first three invocations with
`Data writes to account failed: Custom error: Max retries exceeded`.
This was **not** treated as a failed/absent transaction or a reason to start over.
Each attempt was reconciled at finalized commitment: the same private-authority
buffer retained the deposit and partial bytecode, the program was still absent,
and balance/confirmed successful writes matched the bounded budget.

The owner was informed before the bounded continuations. Initial attempt plus
three separately reconciled resumes used **one buffer**:
`AYhz3V94wriUXnfzrVZEuEgpJodqjoodgnLx6iJdx8db`.
The fourth invocation completed deployment. All79 listed buffer transactions
are finalized and have no error. The buffer is now absent: its deposit was
reused for ProgramData, not left stranded or counted as a second deposit.
The per-invocation sign-attempt/priority settings were unchanged; no new program,
new buffer, faucet request, IP rotation or unlimited retry loop was used.

A read-only `program show` initially requested a default signer despite the
explicit address; repeating it with the existing explicit Devnet signer returned
the expected metadata. It created no key and signed/sent no transaction.

## Actual costs (test SOL only)

- Initial payer balance:1 SOL.
- Rent locked in ProgramData+Program: **0.37661596 SOL**.
- Total transaction fees: **0.000405 SOL** (derived from reconciled balance
  delta less the two retained rent balances).
- Total balance reduction: **0.37702096 SOL**, within the0.4 SOL initial cap.
- Remaining payer balance: **0.62297904 SOL**, finalized slot502240905.

## Evidence and remaining gates

- [Preflight](preflight.json), [final receipt](receipt.json),
  [actual client gate](client-gate.json), [transaction history](buffer-transactions.json).
- Initial and each resumed invocation's start/result JSON files record exact
  public scope; raw CLI logs and all private keys remain outside the repository.
- [Read-only Java probe](LiveProgramCheck.java) uses the unchanged compiled
  `DevnetRpc`, `ProgramPin` and JNI; its host execution is not phone execution.
- [Post-deploy APK rebuild](post-deploy-android-build.json): unchanged pins and
  native payload; signature v2/v3, retained signer and16KiB alignment passed.
  The rebuilt APK is not published or delivered as accepted.

**Not performed:** registration transaction, recovery against a registered
on-chain identity, physical-phone Keystore/restart/reconciliation acceptance,
Mainnet action, server update, merge or APK feed publication. I2/I3 and Android
runtime coverage remain before phone acceptance. Deploying the program does not
close issue52 or those client gates. Any later destructive program closing,
repinning or phone reset requires separate authorization.
