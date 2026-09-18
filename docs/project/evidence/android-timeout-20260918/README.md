# Android response timeout evidence — 2026-09-18

Base: `c9ca067bf747b7b3046fcfdf1986a46c0418ff21`; issue #39.
Scope: ordinary self-service v2 reads 15 seconds, connect 8 seconds, realtime
GET events 30 seconds. Legacy v1 KeyTransport remains 8 seconds.
REQ-MSG-006, REQ-CLIENT-004 and RFC-0015; ADR-0010 remains proposed.

## Actual local execution

- `python3 clients/android/dependencies.py`: pinned Maven hashes verified.
- `python3 clients/android/test_realtime_transport.py --evidence-dir /tmp/paranoid-timeout-red`:
  **RED**, four premature read timeouts with the old production values (realtime,
  key/auth, voice TURN, updates). Existing pool/independent-lane/redirect checks
  passed. Captured stdout is in `red.log`.
- Same command after the production correction: **GREEN**, four delayed replies
  at 9 seconds and four delayed HTTP 408 responses at 10 seconds, plus existing
  pooling/independent-lane/redirect checks. Captured stdout is in `green.log`.
  The HTTPS fixture emits 404 for an absent update, 200 JSON on other paths and
  synthetic 408 errors; it is not the real Rust handler or a hosted-server test.
- `python3 scripts/check-pinned-tls.py`: real TLS positive, wrong pin, SAN and
  expiry checks PASS.
- WebRTC and Firebase dependency verifiers passed; `test_sdk_compile.py` compiled
  all current application sources against Android SDK 35.
- `cargo +1.98.1 build --locked --manifest-path clients/core/Cargo.toml`: PASS.
- `test_updates.py` with the retained PR46 APK as a transport fixture: PASS,
  including update trust/policy, integrity, redirect, size and TLS negatives.
  Initial run lacked the new worktree's JNI library; after the actual locked
  core build, the complete suite passed. This does not build/install a new APK.
- `test_voice_relay_lane.py`: ten real pinned HTTPS/JNI scenarios PASS, including
  cancellation/replacement, strict failures, fresh proofs and text progress.
- `test_voice_relay.py`, `test_call_controller.py`, `test_ui_contract.py` and
  `scripts/test-ci-wiring.py`: PASS.
- `git diff --check`: PASS.
- `markdownlint-cli2@0.18.1`: all 198 documents at that run passed. Newer 0.23.2
  reports ten MD060 findings in two untouched historical documents; the exact
  same findings reproduce on the unmodified base tree. They were not suppressed.

## Boundaries

No server, crypto, native state, wire transcript, identity, trust or retry change.
No phone run, new signed APK, publication, live SSH/firewall change or deployment.
No claim that raising a read timeout fixes hosted issue #38. Tests above do not
prove a total-operation deadline or real-phone timing under Android scheduling.
An unsuccessful ordinary socket read can now occupy its existing worker longer.
CI and independent review are reported separately on the PR, not inferred here.
