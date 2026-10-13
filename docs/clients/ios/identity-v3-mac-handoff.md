---
status: draft
owner: ios
last_reviewed: 2026-10-13
---

# Identity-v3 candidate: exact-head Mac handoff

The current task selected Yaroslav's local Mac agent for Xcode/native execution.
The coordinator is on Linux, has no Xcode/Apple SDK or attached macOS runner,
and cannot claim a native Apple build. No paid runner, Apple-account change or phone
installation is part of this handoff. See [draft ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md).

## Scope of the first handoff

The initial source candidate contains implementation prerequisites, not the full
working identity-v3 application. The Devnet C ABI must pass its component
checks; Swift owner storage/login UI, dual-runtime
integration and MR device acceptance are not implied by a successful old-app
regression build. Report each gate separately and do not distribute the bundle
as a working v3 client before its actual onboarding/text/call path passes.

## Application acceptance target — owner clarification

The iOS app must connect to the **existing configured identity-v3 servers**
and interoperate with other clients, including Android, on the same instance.
No new test-server deployment or separate local-stand workstream is required.
The compiled Finland and Russia profiles remain in scope; this does not add
cross-server federation or make peers on different realms one conversation.

Acceptance means actual login, contact discovery/pairing, text and delivery
receipts, and voice/video calls with the other client on the existing instance.
Local unit/negative checks may support development but never substitute for
that result. Do not reset/recreate either server, change its configuration/schema
or wipe its data to make the client pass. Ordinary client registration/message
operations are distinguished from infrastructure or database-administration
changes; no such client session has been executed by this handoff yet.

## Safe build entry point

### Known limitation and receipt already received

The [integrated-head receipt for 4aac29c](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150129691)
has now arrived. All focused native checks passed; full-wrapper gate 11 still
stopped, and the supplementary QR gate was flaky (1 PASS / 3 FAIL). Do not
request another full unchanged-app run for this documentation-only update.
The next Mac request must identify new feature code and its targeted tests.
Yaroslav's [technical basis disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664)
is separate from these receipts; phone acceptance requires an explicit go per
action and follows the VDSina-first [D5 order](../../rfcs/0030-ios-identity-v3.md#d5-order-and-external-dependencies).

The [Mac receipt for 7a39897](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6147113616)
reports native C ABI checks, regenerated xcframework slices and ParanoidKit
389/0. Its wrapper stopped at gate 9. Supplementary simulator 117/0,
signed-simulator Keychain 11/0 and unsigned device build results were obtained
individually, not by completing that wrapper.

[PR #76](https://github.com/GOTD-GLOBAL/ParanoID/pull/76) is now merged and
integrated into this candidate. It fixes the Java inventory, TLS report parsing,
timeout expectations and Android-only view-field comparison. It does **not**
fix gate 11: `test_android_compatibility.py` still tries to build the server
on macOS. [Issue #37](https://github.com/GOTD-GLOBAL/ParanoID/issues/37#issuecomment-5728208805)
records the Linux-only server direction and is closed as not planned. Do not
port, replace or redeploy the server to make this gate pass. The old separately
supplied macOS server binary proves only the historical artifact's scenarios.
Expect the full wrapper to stop there until a separately reviewed correction
of that test dependency; do not label a partial run green or weaken the gate.

### Exact-source wrapper

Use a dedicated clean worktree at the exact full SHA in the candidate PR.
Preserve other worktrees and simulator accounts; do not reset/clean them to make
this worktree pass. Select a newly created disposable simulator with the pinned
runtime; the agent may create one locally, but must not erase an existing one.
Read `clients/ios/toolchain.json` and `test_toolchain.py` for the actual pins.
Do not change a pin or silence a gate to fit another installed Xcode version.

From that worktree, with `EXPECTED_SHA` set to the PR's full commit and
`SIMULATOR_UUID` to the dedicated test simulator:

```bash
export PARANOID_IOS_SIMULATOR="platform=iOS Simulator,id=$SIMULATOR_UUID"
bash clients/ios/run-candidate-mac.sh "$EXPECTED_SHA"
```

The runner checks a full lowercase SHA, Darwin, exact HEAD, clean source and an
explicit simulator UUID. Any failure to read Git status refuses the build,
including a corrupt/unreadable index; empty stdout is not proof of cleanliness.
It then invokes the existing complete `build.sh` with
archive/provisioning environment variables removed. The canonical toolchain
wrapper still runs. A failed command remains failed; no cleanup/reset is used
as a workaround. The archive gate intentionally stays skipped, not passed.

When all preceding gates pass, `build.sh` rebuilds the C bridge/xcframework,
runs the package and simulator checks (including separate ad-hoc signed
simulator Keychain tests) and produces an **unsigned** device bundle.
The known gate 11 stop prevents the later steps from running in the wrapper.
An unsigned bundle is not an installable signed IPA, phone
execution, TestFlight upload or native proof of unimplemented v3 flows.

### Focused native checks without building a server

In the same exact-head clean worktree, these are individually reported component
checks, not a substitute for a successful full wrapper or phone acceptance:

```sh
bash clients/ios/toolchain.sh bash clients/ios/bridge/check.sh
bash clients/ios/build-core.sh
bash clients/ios/toolchain.sh python3 clients/ios/webrtc_dependency.py --offline
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
bash clients/ios/toolchain.sh bash clients/ios/java_deps.sh
bash clients/ios/toolchain.sh swift build \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm \
  --product core-bridge
bash clients/ios/toolchain.sh python3 clients/ios/test_android_compatibility.py \
  --skip-stand --evidence-dir out/checks/compat-no-stand
bash clients/ios/toolchain.sh python3 clients/ios/check-pinned-tls.py
bash clients/ios/toolchain.sh python3 clients/ios/test_realtime_transport.py \
  --evidence-dir out/checks/transport
```

The pinned WebRTC archive must already be cached for `--offline`; do not reuse
an extracted framework without verification or change its pin. The extraction
step is required before standalone SwiftPM tests in a fresh worktree. The
`--skip-stand` result omits server scenarios explicitly; it is never the full
compatibility receipt. Loopback TLS/transport fixtures are not hosted instances.

Those two relative evidence paths are resolved by the scripts against
`clients/ios`, not the caller's current directory. Do not prefix them with
`clients/ios/`: that creates an untracked nested directory and the exact-source
wrapper correctly refuses it as a dirty tree.

## Required receipt

Return the exact HEAD and clean status; macOS/Xcode/Swift/Rust/SDK versions;
actual commands, return codes, counts, skips and first failure if any; source-
regenerated bridge/header/notices evidence; simulator test identity; and the
canonical `clients/ios/out/evidence/build-manifest.json` / build logs when
produced. Keep local paths private when they contain account information.
Do not include words, entropy, keys, credential files or real message content.

The Linux runner unit tests fake only Darwin discovery and the build subprocess
in an isolated temporary Git repository, to exercise dispatch/safety guards.
Their PASS is **not** Xcode, Swift, simulator, signature or device evidence.
The non-Mac refusal was also exercised on the actual Linux host.

After component/native evidence and the appropriate reviews, the next work is
the candidate's Swift storage/login/directory/runtime path. Any live test needs
an explicit scenario and synthetic account budget; this build entry point does
not register anything on either hosted server or touch the owner's phones.
