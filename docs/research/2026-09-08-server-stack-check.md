---
status: draft
owner: architecture
last_reviewed: 2026-09-08
---

# Bounded server stack check

No new ecosystem survey. This checks the existing Rust/Axum/PostgreSQL
recommendation for [RFC-0006](../rfcs/0006-single-server-text-contract.md).
It is not architecture adoption or a working messenger.

## Source and build evidence

Executed on the Linux build host with rustc 1.97.1 and Cargo 1.97.1:

- `cargo info axum@0.8.9`: MIT, declared Rust minimum 1.80.
- `cargo info tokio`: version 1.53.1, MIT, declared Rust minimum 1.71.
- `cargo info sqlx@0.9.0`: MIT OR Apache-2.0, Rust minimum 1.94.0.
- `cargo info vodozemac@0.10.0`: Apache-2.0, Rust minimum 1.85; a separate
  client crypto candidate, not a server dependency.
- `cargo generate-lockfile` then `cargo check --locked` for the dependency-only
  probe: exit 0; Axum/WebSocket, Tokio and SQLx/PostgreSQL/Rustls compiled together.

Reproduce using [the probe](../../spikes/003-server-dependency-check/README.md).
Cargo.lock pins the resolved graph. Selecting SQLx 0.9 raises the server toolchain
floor to Rust 1.94; do not accidentally impose it on mobile through a shared
server/client manifest. A lockfile may list inactive optional dependencies;
resolved runtime features, not downloaded crate names, define linked components.

These metadata/build checks do not establish legal suitability of the entire
transitive graph, audit completeness, PostgreSQL behavior or iOS support.
A complete dependency/security review remains a pre-adoption gate.

## Advisory check

Installed cargo-audit 0.22.2 in a temporary tool directory, fetched the RustSec
advisory database, then scanned the new server probe lockfile and the existing
Android native crypto spike lockfile. Both scans completed without reported
vulnerabilities (1242 advisories loaded). Commands:

```sh
cargo audit --file spikes/003-server-dependency-check/Cargo.lock
cargo audit --file <android-crypto-worktree>/spikes/002-android-bootstrap/native/Cargo.lock
```

The second scan covers the existing separate PR #9 lockfile, not a newly built
mobile client. A clean advisory scan is time-specific and does not establish
protocol safety, absence of unknown flaws or qualified human approval.

## Runtime and portability limits

- PostgreSQL client 16.15 is installed; this is not server-runtime evidence.
- `docker version` could not reach the local daemon: Docker socket permission
  denied. No privilege escalation, group change or host deployment was attempted.
- Installed Rust targets for this invocation: x86_64-unknown-linux-gnu only.
  This dependency graph was not cross-compiled for Android or iOS.
- Earlier Android native crypto evidence uses JNI and synthetic local participants;
  it proves neither inter-phone messaging nor Swift integration.
- Future iOS requires a macOS/Xcode build and device tests for the separate shared
  crypto core and C ABI, Keychain storage, crash consistency and network lifecycle.
  No Linux result is presented as an Apple-platform pass.

## Recommendation

Retain Rust/Tokio/Axum/PostgreSQL. The pinned server crates compile on the actual
host, and platform-neutral network contracts do not force an Android-only client.
Use separate native Kotlin and future Swift shells over a separate Rust client
core. This reduces protocol duplication, not platform testing requirements.
The first application remains blocked on human disposition of protected contracts,
not on another comparison of frameworks.
