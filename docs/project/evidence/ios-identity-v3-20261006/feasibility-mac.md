---
status: draft
owner: ios
last_reviewed: 2026-10-06
---

# Identity v3 on iOS: feasibility on the build Mac

This records what was measured on 2026-10-06 for
[RFC-0030](../../../rfcs/0030-ios-identity-v3.md). The question was whether
the Rust crate that holds the nickname owner side,
`blockchain/solana/client` (`paranoid-devnet-client`), can be used by the iOS
client as it is.

Checks A, E and F ran the repository's own manifests; the other checks used
probe crates written outside the repository, whose sources are printed below.
Nothing in the repository was changed. None of this is phone evidence, and
none of it replaces the gates of an implementation pull request.

## Environment

| Item | Value |
| --- | --- |
| Source | `main` `62e50e4a1445f4499b61685150ebb22fdf4be664`, a clean detached worktree. The later commits on `main`, through `2470dca`, change only Android files, and no Rust, server or iOS file. |
| Host | Apple silicon (`arm64`), macOS 27.0.1 (26A434) |
| Rust | `rustc 1.98.1 (48a229cea 2026-09-01)`, `cargo 1.98.1 (797e8a9bc 2026-08-05)`, the repository pin |
| Xcode | 26.6 (17F113) |
| Simulator | iPhone 17 Pro, iOS 26.5 (23F77) |

## Checks

| # | Command (from the worktree root unless noted) | Result |
| --- | --- | --- |
| A | `cargo +1.98.1 check --locked --target aarch64-apple-ios --manifest-path blockchain/solana/client/Cargo.toml` | compiles unchanged, including `jni` 0.21.1; `Finished` in 12.12 s |
| F | `cargo +1.98.1 test --locked --lib --manifest-path blockchain/solana/client/Cargo.toml` | `test result: ok. 10 passed; 0 failed` |
| B | `cargo +1.98.1 build --release --target aarch64-apple-ios` of the probe crate `ios-combo-probe` | builds `libios_combo_probe.a`, 27 221 632 bytes |
| C | the same for `ios-devnet-wrap-probe` (the Devnet crate alone) | builds `libios_devnet_wrap_probe.a`, 23 413 008 bytes |
| D1 | `xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=17.0 main_combo.c libios_combo_probe.a -framework Security -framework CoreFoundation -framework SystemConfiguration -lresolv` | links, with one warning (below); the executable was not run |
| D2 | the same with the existing `libparanoid_ios_bridge.a`, built by `clients/ios/build-core.sh` at **`438c79e`**, and `libios_devnet_wrap_probe.a`, with `main_two.c` | links without duplicate symbols, with the same warning; not run |
| R | `IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo +1.98.1 build --release --target aarch64-apple-ios-sim` of the binary crate `ios-runtime-probe`, then `xcrun simctl spawn <iPhone 17 Pro> ios-runtime-probe` | all seven checks pass (output below) |
| E | `cargo +1.98.1 check --locked --manifest-path server/Cargo.toml` on macOS | fails: `error[E0425]: cannot find value O_TMPFILE in crate libc` (`server/src/android_updates.rs:297`) |

Check R is a Rust binary that calls both crates directly. It shows that the
code runs on the iOS simulator; it does not exercise the C ABI or any Swift.

The D1 and D2 warning:

```text
ld: warning: object file (...(a1edd97dd51cd48d-blake3_neon.o)) was built for newer 'iOS' version (26.5) than being linked (17.0)
```

`blake3` 1.8.7 compiles NEON C code with `cc` on `aarch64`, and x86-64
assembly on that host, unless its `pure` feature is set
(`blake3-1.8.7/build.rs:345-358,366-370`). Without `IPHONEOS_DEPLOYMENT_TARGET`
the NEON object takes the SDK's version. RFC-0030 proposes `pure`, which by
that build script compiles no C or assembly; a build with `pure` was not run.

### Runtime on the simulator (R)

```text
PASS devnet export_mnemonic (12 words) abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
PASS devnet recover {"entropy":"AAAAAAAAAAAAAAAAAAAAAA=="}
PASS devnet owner = public vector HAgk14... "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
PASS devnet register signs offline
PASS core create_identity
PASS core upgrade_v2 -> state v3 3
PASS core identity_credential_v3 "4fe37fe3b704fe179c261a25f0f1b41343359511299c9411d1118532d6484f13"
ALL PASS os=ios arch=aarch64
```

The 12-word vector is the public BIP39 vector (entropy of 16 zero bytes), and
the owner address is the one the crate's own test pins
(`blockchain/solana/client/src/lib.rs:646`). The credential fingerprint
belongs to a throwaway identity created in the run; it identifies nothing.

## Lock analysis

Parsed from `clients/core/Cargo.lock`, `blockchain/solana/client/Cargo.lock`,
`clients/ios/bridge/Cargo.lock` and the probe's combined lock, which was
seeded from the bridge lock (SHA-256 of the combined lock:
`edb111a05f7ea347e575c0f551e24258736e5608ef52f9a40487d361592cbcf7`):

| Lock | Registry entries | Distinct names |
| --- | --- | --- |
| core | 123 | 117 |
| Devnet crate | 181 | 167 |
| bridge | 123 | 117 |
| combined probe | 181 | 167 |

- Crates used only by the Devnet crate: 50 by name.
- Crates present in both Android locks at different versions: 13 —
  `block-buffer`, `cfg-if`, `cpufeatures`, `crypto-common`, `digest`, `rand`,
  `rand_chacha`, `rand_core`, `syn`, `toml_edit`, `unicode-ident`, `zerocopy`,
  `zerocopy-derive`.
- The combined resolution kept the core's version of `cfg-if` (1.0.4), `syn`
  (3.0.5), `toml_edit` (0.25.13), `unicode-ident` (1.0.24), `zerocopy` and
  `zerocopy-derive` (0.8.56), and both versions of the other seven.
- For two crates the bridge lock did not hold, the same seeded resolution
  picked versions that are in neither Android lock: `cc` 1.6.0 (the Devnet
  lock has 1.4.7) and `find-msvc-tools` 0.1.14 (0.1.13). An implementation
  pins them with `cargo update --precise`.

## Probe sources

The probe crates referred to the worktree by absolute path; `<repo>` stands
for it here. SHA-256 of the sources as run:

| File | SHA-256 |
| --- | --- |
| `combo/src/lib.rs` | `0719c2b9533017a5b78585295179f4b83b5b97abfd60bdf3b46571117cfc3006` |
| `devnetwrap/src/lib.rs` | `471ed6b74c6b54e77553965dd561e76212c346afbb22d5d95793897f9f470189` |
| `runtime/src/main.rs` | `138eb12a608265901979285688c6b30d1c9e9b2cb4a174f522c540ef3dcace6e` |
| `link/main_combo.c` | `fe7f1559fa2a663197207cd93f2a9db610350fadca52dec9507efdae6db5967a` |
| `link/main_two.c` | `9abcd046d0f9fecf610e814a4923ae7370a68cfed3f071562acf10b9c13d41c1` |

`combo/Cargo.toml` (B and D1):

```toml
[package]
name = "ios-combo-probe"
version = "0.0.0"
edition = "2021"
publish = false
[lib]
crate-type = ["staticlib"]
[dependencies]
paranoid-client-core = { path = "<repo>/clients/core" }
paranoid-devnet-client = { path = "<repo>/blockchain/solana/client" }
```

`combo/src/lib.rs`:

```rust
use std::ffi::{c_char, CStr, CString};
#[no_mangle]
pub unsafe extern "C" fn probe_core_command(state: *const c_char, request: *const c_char) -> *mut c_char {
    let s = unsafe { CStr::from_ptr(state) }.to_str().unwrap_or("");
    let r = unsafe { CStr::from_ptr(request) }.to_str().unwrap_or("");
    let out = match paranoid_client_core::command(s, r) { Ok(o) => o, Err(e) => format!("{{\"error\":\"{e}\"}}") };
    CString::new(out).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn probe_devnet_command(input: *const c_char) -> *mut c_char {
    let s = unsafe { CStr::from_ptr(input) }.to_str().unwrap_or("");
    CString::new(paranoid_devnet_client::command(s)).unwrap().into_raw()
}
```

`devnetwrap` (C and D2) has the manifest of `combo` without the core
dependency. Its `src/lib.rs`:

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
#[no_mangle]
pub extern "C" fn paranoid_devnet_command(input: *const c_char) -> *mut c_char {
    let s = unsafe { CStr::from_ptr(input) }.to_string_lossy().into_owned();
    CString::new(paranoid_devnet_client::command(&s)).unwrap().into_raw()
}
```

`runtime/src/main.rs` (R), with the manifest of `combo` plus `serde_json` and
no `[lib]` section:

```rust
use serde_json::{json, Value};
fn core(state: &str, req: Value) -> Value {
    match paranoid_client_core::command(state, &req.to_string()) {
        Ok(s) => serde_json::from_str(&s).unwrap(),
        Err(e) => json!({ "error": e }),
    }
}
fn devnet(req: Value) -> Value {
    serde_json::from_str(&paranoid_devnet_client::command(&req.to_string())).unwrap()
}
fn check(name: &str, ok: bool, detail: String) {
    println!("{} {} {}", if ok { "PASS" } else { "FAIL" }, name, detail);
    if !ok { std::process::exit(1) }
}
fn main() {
    let e16 = "AAAAAAAAAAAAAAAAAAAAAA==";
    let m = devnet(json!({"op":"export_mnemonic","entropy":e16}));
    let words = m["mnemonic"].as_str().unwrap_or("").to_string();
    check("devnet export_mnemonic (12 words)", words == format!("{} about", ["abandon"; 11].join(" ")), words.clone());
    let r = devnet(json!({"op":"recover","mnemonic":words}));
    check("devnet recover", r["entropy"] == e16, r.to_string());
    let id = devnet(json!({"op":"identity","entropy":e16}));
    check("devnet owner = public vector HAgk14...", id["owner"] == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", id["owner"].to_string());
    let tx = devnet(json!({"op":"register","entropy":e16,"name":"abc","blockhash":"11111111111111111111111111111111","genesis":paranoid_devnet_client::GENESIS}));
    check("devnet register signs offline", tx.get("error").is_none() && tx["owner"] == id["owner"], tx.get("error").map(|e| e.to_string()).unwrap_or_default());
    let created = core("", json!({"op":"create_identity","realm":"https://127.0.0.2:38444","pin":"a".repeat(64)}));
    check("core create_identity", created.get("error").is_none(), created.get("error").map(|e| e.to_string()).unwrap_or_default());
    let up = core(&created["state"].to_string(), json!({"op":"upgrade_v2"}));
    check("core upgrade_v2 -> state v3", up["state"]["version"] == 3, up["state"]["version"].to_string());
    let cred = core(&up["state"].to_string(), json!({"op":"identity_credential_v3"}));
    check("core identity_credential_v3", cred.get("error").is_none() && cred.get("fingerprint").is_some(), cred.get("fingerprint").map(|f| f.to_string()).unwrap_or(cred.to_string()));
    println!("ALL PASS os={} arch={}", std::env::consts::OS, std::env::consts::ARCH);
}
```

`link/main_combo.c` (D1); `main_two.c` (D2) is the same with the names
`paranoid_core_command` and `paranoid_devnet_command`:

```c
#include <stdio.h>
char *probe_core_command(const char *, const char *);
char *probe_devnet_command(const char *);
int main(void) { puts(probe_devnet_command("{}")); puts(probe_core_command("", "{}")); return 0; }
```

## NOT RUN

- Anything on a physical phone.
- The linked executables of D1 and D2, and the C ABI from Swift.
- A build with `blake3/pure`.
- `cargo check --target aarch64-apple-ios` of a combined bridge on Ubuntu,
  which is what the iOS static CI job runs.
- Any network call to Devnet or a v3 server, and any registration.
- A local identity-v3 stand: the server does not build on macOS (check E).
