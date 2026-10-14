---
status: draft
owner: ios
decision_owner: Cooldom66671
created: 2026-10-14
last_reviewed: 2026-10-14
---

# RFC-0032 source probes: runtime entropy and projection bounds

Research evidence for [RFC-0032](../../../rfcs/0032-core-non-signing-state-validation.md),
not acceptance of its new operation. **`validate_state_v3` is not implemented;
V01–V14 and Apple/native memory gates remain NOT RUN.** All inputs below were
fresh synthetic in-memory fixtures; no user keys/state, server, network, phone
or Keychain item was used. No repository runtime/dependency source was modified.

## Source and toolchain correspondence

- Inspected runtime source is unchanged from `c66fcbc9961a29245bbbfbcd33ac1292a4338fae`.
- Initial RFC review used local `74a51c9f0546bece41f6d5298a93ec0dee9eee6f`.
  Rebase onto the published authority record produced initial doc commit
  `8f0bf79e1fa634de13d2e4dc60403475059a68f3` with identical RFC blob
  `e7c05858b59d3eb664bb2b8ef1b42b59bd4df478`; this is a correspondence record,
  not a claim that review had already covered the later correction.
- Rust **1.98.1**, locked/frozen/offline existing core dependencies;
  vodozemac **0.10.0**, serde_json **1.0.151** from
  [the core lock](../../../../clients/core/Cargo.lock). Linux host, not Apple.
- Parent rebuilt the existing core in Cargo debug and release profiles, then
  compiled the scratch probe with `-D warnings`, matching profile dependencies
  and probe `opt-level=0` / `opt-level=3`. Both compiled and exited successfully.
- Final probe source SHA-256: `47b461b22699e32bd67ebdd1f6cacf5279af7ab5d9a678810cacdb9cdd7e143f`.
  Debug binary: `583630beaad35781fc011cb4348e461496a3e46091b39efdf5dac7b1092ea3fa`;
  release binary: `c344fa2be3d1c8665eb19676908c91692fbe06e5e3a1c011d29804e89ab750f6`.
  These identify local probe artifacts, not shipped app binaries.

## Counterexample to an absolute zero-OS-RNG promise

The existing [legacy validation](../../../../clients/core/src/self_service.rs)
loads an Account through [the core helper](../../../../clients/core/src/lib.rs).
Pinned vodozemac `src/olm/account/mod.rs:628–634` converts `AccountPickle`;
`src/olm/account/one_time_keys.rs:157–169` creates a standard `HashMap` while
restoring reverse key lookup. Its randomized hashing may seed from OS entropy.
That is not protocol key generation or a signature.

The independent reviewer reproduced entropy inside `Account::from_pickle` and
the existing `identity_credential_v3` on fresh workers in debug and release.
The parent then ran the probe below independently, adding repeated warm-worker
controls. Actual `getrandom` calls **inside the named marker intervals** were:

| Existing-code build | Interval | Calls observed |
| --- | --- | --- |
| debug | `COLD_ACCOUNT` | 1 |
| debug | `WARM_ACCOUNT` | 0 |
| debug | `COLD_EXISTING_CREDENTIAL` | 1 |
| debug | `WARM_EXISTING_CREDENTIAL` | 0 |
| release | `COLD_ACCOUNT` | 1 |
| release | `WARM_ACCOUNT` | 0 |
| release | `COLD_EXISTING_CREDENTIAL` | 1 |
| release | `WARM_EXISTING_CREDENTIAL` | 0 |

The cold worker is new; fixture generation happens on the caller thread, before
the measured worker exists. Warm is a second call on that same worker. Each
profile ran as a separate process. Synthetic restored Account serialization
and the original core input string remained equal in the probe assertions.
These checks do not establish all possible state/byte preservation properties
of a future validator.

This is a concrete counterexample to the initial draft's absolute zero-OS-RNG
promise, and demonstrates why fixture warm-up can hide first-use entropy.
The trace captures syscall occurrence; attribution uses the inspected call
path. Syscall size/flags alone must never whitelist arbitrary protocol RNG.
This experiment did **not** instrument all signers or seeded RNGs and does not
prove zero signing/protocol generation for a new operation. Those remain V07
acceptance obligations, including cold and warm controls on supported builds.
Do not skip Account validation, disable randomized hashing or warm the test
worker to make an inaccurate assertion pass.

Raw trace collection used `-e raw=getrandom`, which prints argument addresses,
not returned entropy. Only fixed marker/result messages were written; no key,
pickle, core, projection or entropy bytes were logged. Final source, raw traces
and receipt are retained locally under the owning profile's
`tasks/evidence/rfc0032-entropy-20261014/`; the complete probe is included here
so reconstruction does not depend on a temporary scratch directory.

### Probe source (existing APIs only)

```rust
use paranoid_client_core::command;
use serde_json::{json, Value};
use std::io::Write;
use vodozemac::olm::Account;

fn mark(name: &str) {
    writeln!(std::io::stderr(), "{name}").unwrap_or_else(|_| panic!("marker failed"));
}
fn decode(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap_or_else(|_| panic!("synthetic fixture JSON failed"))
}
fn call(raw: &str, req: Value) -> Value {
    let response = command(raw, &req.to_string())
        .unwrap_or_else(|_| panic!("existing synthetic core call failed"));
    decode(&response)
}
fn main() {
    // All key generation is synthetic setup on this thread, outside measured intervals.
    // No key, pickle, state, projection or entropy bytes are printed or persisted.
    let account = Account::new();
    let saved = serde_json::to_string(&account.pickle())
        .unwrap_or_else(|_| panic!("fixture serialization failed"));
    std::thread::spawn(move || {
        for phase in ["COLD", "WARM"] {
            let pickle = serde_json::from_str(&saved)
                .unwrap_or_else(|_| panic!("fixture pickle decode failed"));
            mark(&format!("BEGIN_{phase}_ACCOUNT"));
            let restored = Account::from_pickle(pickle);
            std::hint::black_box(restored.curve25519_key());
            mark(&format!("END_{phase}_ACCOUNT"));
            let after = serde_json::to_string(&restored.pickle())
                .unwrap_or_else(|_| panic!("restored serialization failed"));
            assert!(after == saved, "restored synthetic account changed");
        }
    })
    .join()
    .unwrap_or_else(|_| panic!("account worker failed"));

    let fresh = call(
        "",
        json!({"op":"create_identity", "realm":"https://example.invalid", "pin":"a".repeat(64)}),
    );
    let upgraded = call(&fresh["state"].to_string(), json!({"op":"upgrade_v2"}));
    let raw = upgraded["state"].to_string();
    let before = raw.clone();
    std::thread::spawn(move || {
        for phase in ["COLD", "WARM"] {
            mark(&format!("BEGIN_{phase}_EXISTING_CREDENTIAL"));
            let result = command(&raw, r#"{"op":"identity_credential_v3"}"#);
            assert!(result.is_ok(), "existing credential projection failed");
            drop(std::hint::black_box(result));
            mark(&format!("END_{phase}_EXISTING_CREDENTIAL"));
            assert!(raw == before, "synthetic input changed");
        }
    })
    .join()
    .unwrap_or_else(|_| panic!("credential worker failed"));
    println!("existing_account_and_credential_cold_warm_probe=PASS; new_validator=NOT_IMPLEMENTED");
}
```

### Reproduction invocation shape

Run only in the approved local synthetic scope, with pinned toolchain and cached
locked dependencies. Missing cache/toolchain is a blocker, not a fabricated run.
`REPO`, `DEPS` and `PROBE` must name the checked source root and caller-owned
profile scratch directories. Write the probe above to `$PROBE/probe.rs` using
the normal file tooling; resolve each unique matching dependency rlib rather
than choose an arbitrary file from an ambiguous glob. No new dependency install,
source patch or network access is part of these commands.

```sh
set -eu
cargo +1.98.1 build --frozen --offline \
  --manifest-path "$REPO/clients/core/Cargo.toml" --target-dir "$DEPS"
cargo +1.98.1 build --frozen --offline --release \
  --manifest-path "$REPO/clients/core/Cargo.toml" --target-dir "$DEPS"
rustc +1.98.1 --edition=2021 -D warnings "$PROBE/probe.rs" \
  -L "dependency=$DEPS/debug/deps" \
  --extern "paranoid_client_core=$DEPS/debug/libparanoid_client_core.rlib" \
  --extern "serde_json=$SERDE_DEBUG_RLIB" --extern "vodozemac=$VODO_DEBUG_RLIB" \
  -C opt-level=0 -o "$PROBE/probe-debug"
strace -f -qq -e trace=getrandom,write -e raw=getrandom \
  -o "$PROBE/debug.trace" "$PROBE/probe-debug"
```

Repeat the rustc/strace leg with release dependencies and `opt-level=3`. The
actual host used explicit `RUSTUP_HOME=/home/codex/.rustup` and
`CARGO_HOME=/home/codex/.cargo`; these paths are host context, not project-wide
configuration requirements. Do not silently run live commands or substitute
this Linux probe for the required simulator/physical acceptance.

## Conservative public projection size calculation

This is executed **shape arithmetic**, not an actual response from the absent
operation or a valid credential fixture. Public key/signature encoded lengths
were calculated from 32/64-byte inputs: 43/86 unpadded Base64 characters.
The global [signature verifier](../../../../key-protocol/src/lib.rs) requires
`signature.to_base64() == sig`; padded/noncanonical spellings cannot enlarge an
admitted credential signature. The existing realm permits up to 512 UTF-8 bytes,
not a new ASCII-only value.

For the proposed fixed-key compact projection:

- Credential string caps: `43,64,36,43,512,64,64,86`.
- Fingerprint cap: `64`; enrollment caps: `6,64,36,64`.
- Total value-byte cap: **1146**; fixed-key/structure/version overhead:
  **229** bytes.
- Overapproximating every value byte with a six-byte JSON escape gives
  **229 + 6 × 1146 = 7105 bytes**, below the proposed 8192.
- Largest fixed error object under the proposed codes: **29 bytes**.

The parent executed this using deliberately invalid semantic dummy strings of
U+0000 to maximize serialized escaping; they are not fabricated successful API
responses. The independent reviewer reproduced the bound and additionally used
an existing-core-accepted synthetic 512-byte realm with control characters;
its **model of the proposed projection**, not a new-verb response, was 3895 bytes.
The parent reran that inspected probe in debug and release and confirmed 3895,
canonical-signature refusal and the absent verb's `invalid_request` result.
That model confirms why stricter new realm-metadata grammar must not be copied
into the global shared-core validator.

The bound excludes the C terminator and assumes the specified literal ASCII
keys, compact writer and fixed field set. Changing them needs a new proof and
real implementation tests. It is not a working-set, native peak, CPU deadline
or valid-state acceptance proof; V09/V12 remain NOT RUN.
