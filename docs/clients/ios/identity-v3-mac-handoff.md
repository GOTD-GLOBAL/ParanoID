---
status: draft
owner: ios
last_reviewed: 2026-10-13
---

# Identity-v3 candidate: exact-head Mac handoff

The current task selected Yaroslav's local Mac agent for Xcode/native execution.
The coordinator is on Linux, has neither Swift/Xcode nor an attached macOS runner,
and cannot claim a native build. No paid runner, Apple-account change or phone
installation is part of this handoff. See [draft ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md).

## Scope of the first handoff

The initial source candidate contains implementation prerequisites, not the full
working identity-v3 application. A Devnet C ABI and isolated identity-v3 stand
must pass their component checks; Swift owner storage/login UI, dual-runtime
integration and MR device acceptance are not implied by a successful old-app
regression build. Report each gate separately and do not distribute the bundle
as a working v3 client before its actual onboarding/text/call path passes.

## Safe build entry point

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
explicit simulator UUID. It then invokes the existing complete `build.sh` with
archive/provisioning environment variables removed. The canonical toolchain
wrapper still runs. A failed command remains failed; no cleanup/reset is used
as a workaround. The archive gate intentionally stays skipped, not passed.

`build.sh` rebuilds the C bridge/xcframework, runs the package and simulator
checks (including separate ad-hoc signed simulator Keychain tests) and produces
an **unsigned** device bundle. This is not an installable signed IPA, phone
execution, TestFlight upload or native proof of unimplemented v3 flows.

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
