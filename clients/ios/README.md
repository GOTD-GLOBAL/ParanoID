# iOS client

Native iOS client of ParanoID. It reuses the shared Rust core
(`clients/core`) through a thin C ABI bridge; the Swift application, the
packaging and the tests live next to it. Pinned tools are listed in
[`toolchain.json`](toolchain.json); run every Rust command through
[`toolchain.sh`](toolchain.sh) from a non-interactive shell so that
`~/.cargo/bin` is on `PATH`. Build outputs and logs go to `out/` (ignored by
git).

## Status

This directory is a **candidate under development** proposed in
[RFC-0021](../../docs/rfcs/0021-ios-client.md) and recorded as
[draft ADR-0014](../../docs/decisions/0014-ios-client.md) for REQ-CLIENT-001.
Nothing in it is accepted architecture; no build has been installed on a phone,
no hosted account has been created and no TestFlight upload has happened unless
the [verification table](../../docs/clients/ios/verification.md) says `SHOWN`
with an evidence link. The Android v15 client (`main` `fe9c26c`) is the
behavioural reference; the [component documentation](../../docs/clients/ios/README.md)
lists the intended differences (no in-app updates, no background delivery,
no CallKit, reinstall is a clean install). A directory or script named in this
README exists only once its pull-request step has landed; the name alone is
not a claim that the code exists or works.

## Bridge crate (`bridge/`)

`paranoid-ios-bridge` exports two C symbols, declared in
[`bridge/include/paranoid_core.h`](bridge/include/paranoid_core.h) and exposed
to Swift as the `ParanoidCoreFFI` module:

- `char *paranoid_core_command(const char *state, const char *request)` wraps
  `paranoid_client_core::command`; it never returns NULL and reports
  `{"error":"invalid_request"}` for NULL/non-UTF-8 input and
  `{"error":"native_failure"}` for a caught panic.
- `void paranoid_core_free(char *text)` releases a reply; NULL is ignored.

Input limits (8 MiB state, 65536-byte request) and every state rule stay in
the core; the bridge holds no state and no network code. The crate is built as
a `staticlib` for the xcframework; the extra `rlib` exists only for
`bridge/tests/abi.rs`, `cargo clippy --all-targets` and the host `cargo test`.

```sh
cargo +1.98.1 build --locked --release --target aarch64-apple-ios \
  --manifest-path clients/ios/bridge/Cargo.toml --target-dir clients/ios/out/bridge-target
cargo +1.98.1 fmt --manifest-path clients/ios/bridge/Cargo.toml -- --check
cargo +1.98.1 clippy --locked --manifest-path clients/ios/bridge/Cargo.toml --all-targets -- -D warnings
cargo +1.98.1 test --locked --manifest-path clients/ios/bridge/Cargo.toml
```

### Lock-file rule

`bridge/Cargo.lock` is seeded from `clients/core/Cargo.lock`, so the iOS
build pins exactly the crate versions the Android build ships. The seeding is
the only cargo invocation that runs **without** `--locked`; it keeps every
pinned version and adds only the root `paranoid-ios-bridge` package:

```sh
cp clients/core/Cargo.lock clients/ios/bridge/Cargo.lock
cargo +1.98.1 build --release --target aarch64-apple-ios \
  --manifest-path clients/ios/bridge/Cargo.toml --target-dir clients/ios/out/bridge-target
git diff --no-index clients/core/Cargo.lock clients/ios/bridge/Cargo.lock   # only the paranoid-ios-bridge block
```

Every other command uses `--locked`. Whenever `clients/core/Cargo.lock` is
bumped, repeat the seeding; `python3 clients/ios/test_bridge_lock.py` catches
any divergence between the two lock files (`OK` or `FAIL: ...` lines).

## Core xcframework (`build-core.sh`)

`bash clients/ios/build-core.sh` builds the bridge three times with
`cargo +1.98.1 build --locked --release` (`aarch64-apple-ios`,
`aarch64-apple-ios-sim` and `aarch64-apple-darwin`; the macOS slice serves the
host-side Swift tests) into `out/bridge-target`, then combines the three
`libparanoid_ios_bridge.a` archives with `bridge/include` as headers through
`xcodebuild -create-xcframework` into
`ParanoidKit/Binaries/ParanoidCore.xcframework`. The bundle is git-ignored and
lives inside the package, so the SwiftPM `binaryTarget` path never contains
`..`; the `rlib` never enters it. The script re-executes itself through
`toolchain.sh`, checks that the bundle has exactly three slices and that every
archive is a single-architecture `arm64` file, and writes the SHA-256 of each
archive, of the exported headers and of `bridge/Cargo.lock` together with the
`rustc`, `cargo`, Xcode and iOS SDK versions to
`out/evidence/bridge-hashes.json`. Console output is short; the full cargo and
xcodebuild output is in `out/logs/build-core.log`.

```sh
bash clients/ios/build-core.sh
plutil -p clients/ios/ParanoidKit/Binaries/ParanoidCore.xcframework/Info.plist | grep -c LibraryIdentifier   # 3
lipo -info clients/ios/ParanoidKit/Binaries/ParanoidCore.xcframework/*/libparanoid_ios_bridge.a          # arm64 each
```

The archives keep rustc's default minimum OS versions (iOS 10.0, simulator
14.0, macOS 11.0); the `ios_deployment_target` pin in `toolchain.json` (17.0)
is applied by the application target, which links these older-minimum static
libraries without a warning.

## Swift package (`ParanoidKit/`)

`ParanoidKit` is the SwiftPM library (iOS 17; macOS 14 only for the host
tests) that holds everything above the bridge in the RFC-0021 design:
storage, TLS, transport, realtime, calls and the UI model. `Package.swift`
declares the `ParanoidCoreFFI` binary target at
`Binaries/ParanoidCore.xcframework` (git-ignored, produced by `build-core.sh`,
which must run first) and the `WebRTC` binary target at
`Binaries/WebRTC.xcframework` (git-ignored, produced by
`webrtc_dependency.py`), and no package dependency at all; `service-bridge` is
the host-only registration fixture described below, and the `core-bridge` and
`tls-smoke` executables named in RFC-0021 arrive with their own pull-request
steps. The `WebRTC` target is exported as
its own product and **no** target of the package depends on it: the
xcframework carries no macOS slice, so keeping `ParanoidKit` itself free of it
is what lets the host `swift test` run build. `Sources/ParanoidKit/Core/` is
the counterpart of `CoreBridge.java` plus the `nativeCall`/`apply` rules of
`SelfServiceClient.java`:

- `CoreBridge.command(state:request:) throws -> CoreReply` calls
  `paranoid_core_command`, releases the reply with `paranoid_core_free`
  (`defer`), maps a NULL or non-object reply to `CoreError.nativeFailure` and
  an `{"error":"<code>"}` reply to `CoreError.rejected(code)`
  (`SelfServiceClient.java:55-61`). An interior NUL in either argument is
  refused as `invalid_request` before the call, because a C string would
  silently truncate it. `CoreReply` carries the reply text, the decoded
  object (`org.json`-style member access) and the verbatim `state`.
- `JsonSpan.state(in:)` slices the top-level `"state"` member out of the
  reply byte for byte, without re-serialising it, so the persisted snapshot
  and the `next == current` comparison use exactly the text the core
  produced; that replaces the `org.json` round trip of
  `SelfServiceClient.java:73-76` and is sound because the core serialises
  through `serde_json::Value` (sorted keys, no insignificant whitespace).
  Anything that is not one well-formed top-level object yields `nil`.
- `Sources/ParanoidKit/Voice/SdpExtract.swift` reads the DTLS fingerprint
  (lowercase, colon-free) and the ICE credentials out of a session
  description, the three members a `call` control repeats beside its SDP and
  that the core cross-checks against the text (`voice_v1.rs:167-188`), plus
  the survey that validator cares about. A call-v2 description is two media
  sections, `m=audio` then `m=video`, bundled on one transport
  ([call-v2](../../docs/protocol/call-v2.md)), so each of `a=fingerprint`,
  `a=ice-ufrag`, `a=ice-pwd` and `a=setup` may sit once at session level **or**
  once in the audio section and at most once more in the video section with
  the identical value; the scan resolves that one value wherever it is
  repeated and returns `nil` for a second context or two different values,
  exactly as `voice_v1.rs:236-242` decides. The survey is per section (`m=`
  port, transport and payload types, the `a=rtpmap` mappings, the `a=sendrecv`
  and `a=rtcp-mux` counts, the candidates) and per description (byte count,
  line count, `a=candidate` / `a=crypto` / blocked-direction counts).
  `maxSdpBytes` is 9000: the core's own `MAX_SDP` is 12288, but a `call`
  control travels in one frame2 envelope whose measured ceiling is 10040
  bytes, so the description is checked against the smaller cap before it is
  handed to the core. It is Android's `TextEngine.java:138-144` line scan, cut
  on UTF-8 bytes like `str::lines()` because Swift folds a CRLF pair into one
  `Character`. It never rewrites the description; the reader itself is pinned
  on the core's own vector shape by `SdpExtractTests`.
- `Sources/ParanoidKit/Voice/VoiceRelayConfig.swift` is the answer to
  `GET /v2/voice/turn`, validated as
  [voice TURN v1](../../docs/protocol/voice-turn-v1.md) demands and the port of
  `VoiceRelayConfig.java:58-237`: at most 2048 bytes, exactly the six fields
  with no duplicate and no unknown name, `v` 1, `ttl` 1200, and `urls` exactly
  `turn:<realm IPv4>:34781?transport=udp` then the same with `tcp` — the two
  literal forms on the host of the **retained** origin, so no response can move
  media to another host or ask for a DNS lookup. `username` is the decimal
  `expires` plus `:` and 32 lowercase hex digits; `credential` is canonical
  padded Base64 of exactly 20 bytes, and it is the canonicality check that
  refuses a last character whose unused bits a tolerant decoder would ignore.
  The document carries its own bounded, non-recursive grammar rather than a
  general JSON reader, because `1.0`, `1e0`, `01`, a duplicate key and a `v`
  spelled `v` all have to be refused exactly the way Android refuses them;
  it runs over UTF-16 code units, like Java's, so `\uD800` alone is a rejection
  and not a replacement character. The remaining lifetime must be 1 000 000 to
  1 205 000 ms on receipt, and `usable(wallMilliseconds:monotonicNanoseconds:)`
  is called again immediately before the peer connection is created: it spends
  that same window on the monotonic clock, so neither an asynchronous disposal
  of an older engine nor a wall-clock rollback buys time. The credentials are
  volatile — the type is not `Codable` and its description is
  `VoiceRelayConfig[redacted]`. `VoiceRelayConfigTests` runs it against
  [`test/fixtures/voice-relay-vectors.json`](test/fixtures/voice-relay-vectors.json),
  the transcription of `clients/android/test/VoiceRelaySmoke.java`: six accepted
  documents, its 49 negatives — each compared by the reason the parser gives,
  not merely counted — and the nine `usable` probes on the window boundaries.
- `Sources/ParanoidKit/Qr/QrCodec.swift` is the two QR bounds of
  [key enrollment v1](../../docs/protocol/key-enrollment-v1.md) (lines 91-96)
  and the one local encoder, the counterpart of Android's `QrCodec.java`:
  2048 bytes for a QR payload, 4096 for a text import, and
  `CIQRCodeGenerator` at error-correction level `M` in place of ZXing
  (`QrCodec.java:12-16`). `checkedPayload` and `checkedImport` measure a
  string and hand back the string they were given, and `image(for:)` encodes
  exactly those bytes, so what a peer scans is the `contact` member
  `SelfServiceClient.contactText()` sliced out of the core's reply, byte for
  byte; Android re-serialises that member through `org.json` on the way
  (`MainActivity.java:612-614`), which this client does not need to do. The
  generator emits one pixel per module with one module of quiet zone; the
  other three modules of Android's `MARGIN` hint are added in white, and the
  result is multiplied by a whole number with nearest-neighbour sampling until
  it reaches 640 px, because the v15 add-contact bug was a dense ~900-byte
  contact code losing its modules at 480p (`QrScanActivity.java:42-47`,
  `QrDenseSmoke.java:3-6`). There is no
  decoder here: the scanner reads `AVCaptureMetadataOutput`, and a QR proves
  nothing on its own — the full fingerprint is still compared on the other
  phone ([first contact v1](../../docs/protocol/first-contact-v1.md), lines
  90-91).
- `Sources/ParanoidKit/Storage/` holds the at-rest rules of
  [first-contact v1](../../docs/protocol/first-contact-v1.md) (lines 173-178)
  and [the core contract](../../docs/clients/core/self-service.md) (lines
  97-100). `SnapshotStore.commit(_:)` is five durable steps in one order —
  write `text-state.enc.tmp`, `F_FULLFSYNC` it, `rename(2)` it over
  `text-state.enc`, read the committed file back and compare it byte for byte,
  `F_FULLFSYNC` the directory — and any failure sets `isBroken` for the rest of
  the process, so nothing derived from that candidate is adopted or sent
  (`TextEngine.java:226-237`). The candidate is excluded from backup **before**
  the rename, because the flag lives on the inode: setting it on the committed
  name alone would cover only the first commit, and a later iCloud restore
  would hand back a stale ratchet while the Keychain key still worked.
  `FileSystem` is the seam the host tests fail one step at a time;
  `DataProtectionFileSystem` is the real one (`Application Support/paranoid/`,
  owner-only, `completeUntilFirstUserAuthentication`, 9 MiB read ceiling).
  `KeychainKey` is the AES-256 wrapping key (`kSecClassGenericPassword`,
  account `paranoid-text-state-v0`, accessible after first unlock on this
  device only, not synchronizable), never regenerated over an existing file
  (`TextEngine.java:206-218`). `InstallMarker` (`paranoid.install.v1`, standard
  defaults) and `StorageGuard` carry the reinstall rule: with no marker the
  stale Keychain key is deleted and the marker is recorded, and only then is
  Android's exclusive-or (`StorageGuard.java:7-8`) evaluated — a key without a
  file, or a file without a key, freezes.
- `Sources/ParanoidKit/Service/` is the application adapter over the unchanged
  v2 opaque transport, the port of `SelfServiceClient.java`. `Snapshot` is the
  stored version-4 wrapper
  (`{"version":4,"realm":…,"tls_pin":…,"token":"","state":…}`) with the core
  state inlined verbatim; opening one follows `SelfServiceClient.java:23-44`:
  a wrapper version other than 4 is `unsupportedSnapshot` and the retained
  bytes are left exactly as they are, `token` is empty or 64 hexadecimal
  digits, a schema-0 state left by a crash is validated by running `upgrade_v2`
  as a dry run that commits nothing, and the realm of the wrapper must be the
  realm the core state was created for. Every state transition goes through one
  `apply`, which commits the candidate through `SnapshotSink` **before** it is
  adopted in memory, handed to a listener or acted on; a `receive_v2` reply
  without an authenticated disposition is dropped before it is written, and a
  failed commit freezes the client for the rest of the process. `updateTrust()`
  is the only source of the realm and the pin, so a frozen client also takes
  the application off the network — nothing here opens a connection itself.
  `createIdentity()` is `create_identity` and then `upgrade_v2`, each committed,
  before any request exists (`SelfServiceClient.java:186`). `ServiceTrust`
  carries the pair through the same checks the TLS layer uses: a saved pair
  always wins over a compiled one and a fixture that disagrees with it is
  refused, and the hosted defaults (`KeyClient.java:9-10`) apply only in a
  Release build or under `-paranoid-allow-hosted`, so a Debug build with no
  stand has no realm at all and creates no identity.
- `Sources/ParanoidKit/Realtime/` is the owner of that state and the lanes
  around it. `StateOwner` is an `actor` on its own serial queue — the port of
  the single-threaded `TextEngine.worker` — and it holds the client, every
  bridge call, every commit, the realtime session and the discovered
  capability. No member of it is `async`, so it cannot wait for a socket; a
  lane is a `Task` that awaits the network in its own task and hands the
  finished answer over through `perform`, which asserts at runtime that it is
  running on the owner. Only `Sendable` values cross: a signed request out, a
  `Reply` in, never a decoded core reply. `Generation` is the run counter of
  `RealtimeLoop.java:36-37,53-56`: `start()` on an enabled loop mints nothing,
  `stop()` moves the counter, and a result that returns under a superseded run
  is refused with `Superseded` before it can touch the state
  (`docs/protocol/realtime-v1.md:127-130`). The session belongs to the owner
  and not to a generation, because the account has two live-session slots
  (`server/src/self_service_http.rs:377-391`) and renewal needs the second: a
  pause keeps it, a new generation reuses one younger than 240 seconds by the
  monotonic clock, and it is dropped only on a second 401, a 404,
  `session_exhausted`, a server that stopped advertising the capability, or
  renewal (`:179-181`). `Backoff` is
  `min(30 s, 0.5 s · 2^min(n,5)) + rand(0…250 ms)`, and `PushHook` is the one
  seam a future background delivery would enter through; `NoPushHook` is what
  this foreground-only client installs.
- `ReceiveLane` is the first of those lanes, the port of
  `RealtimeLoop.receiveLoop()`. One cycle is one page and the order inside it
  is the specification: a page above twenty events is refused
  ([first-contact v1](../../docs/protocol/first-contact-v1.md) line 165), the
  receive cursor is read again **on the owner** and must still be the one the
  request was signed with, `changed(true, "Подключено")` is published *before*
  the page so that call signalling sees an online client when a `call` control
  arrives in it, and then every event goes through `receive_v2` one by one,
  each one sealed, renamed and read back before the notification that follows
  it — "renderer publication follows successful full native candidate
  persistence and precedes receipt network completion"
  ([realtime v1](../../docs/protocol/realtime-v1.md) lines 97-99). Only after
  the page is the send lane woken, so a receipt leaves the device after the
  message it acknowledges has been shown. The first cycle of a generation asks
  for `messages` and every later one for `events`, a 429 `waiter_busy` reads
  the inbox instead of queueing for the account's one wait slot, a client
  without a session fetches the same page through the retained challenge
  transport, and a polling cycle that came back short waits three seconds. The
  online flag carries no debounce, exactly as Android v15
  (`RealtimeLoop.java:237,261-263,280`): every failure publishes
  `changed(false, …)` as it happens and is followed by the shared backoff, and
  a failed commit stops the lane and says so once. `RealtimeListener` is
  `RealtimeLoop.Listener` and it is invoked on the state owner and nowhere
  else; `RealtimeStatus` holds the user-facing texts of
  `RealtimeLoop.errorMessage` plus the 404 of `TextEngine.userError`
  (`TextEngine.java:198-207`), which Android's lanes do not distinguish.
- `SendLane` is the other lane, the port of `RealtimeLoop.sendLoop()`. One
  cycle is one pass over the outbox, oldest first: the identifiers (and, with
  no session, the envelope bytes) are read **on the owner**, each entry is sent
  exactly as `sign_session_v2 {operation:"send", id}` described it — the core's
  method, path and body, never a route this lane composed — and the answer
  `{id, sequence >= 1}` is committed through `accepted_v2` before the delivery
  mark it produces is published ([self-service v2](../../docs/protocol/self-service-v2.md)
  lines 56-58). A 409 or a 507 defers that envelope and the rest of the batch
  still goes out, with the last deferred rejection thrown when the pass ends
  (`:80-81`); anything else ends the pass at once. Unlike the receive lane it
  does not spin: a pass runs when `WakeSignal` has been armed — by `start()`,
  by a page the receive lane has just delivered or by the user enqueueing a
  message — and a failed pass re-arms it after the backoff, which is Android's
  `outbound` semaphore and its `kick()`. An idle lane **waits** on that signal
  for at most a second instead of looking at it again later, so a wake resumes
  it at once: that is the other half of `outbound.tryAcquire(1, SECONDS)`
  (`RealtimeLoop.java:219`), and it is what keeps the message a user has just
  written from sitting out an interval nobody can see —
  `test_realtime.py` measures a P50 of about 70 ms where a polled wake
  measured 813 ms, against a 500 ms target.
- `SessionCall` is the shared `RealtimeLoop.sessionCall`, so both lanes repeat
  a first 401 exactly once with a freshly signed nonce (a pooled socket can
  lose the answer after the server consumed it) and treat a second 401, a 404
  or `session_exhausted` as the end of that session; a 401 or a 404 also
  rediscovers the capability. The rejections of `/v2/session` **itself** are
  mapped once, in `ProofFlow.connect`, because both lanes share that
  connection: 401 and 404 drop the session and rediscover, and a 429 leaves the
  route alone for `ProofFlow.legacyWindow` (5 s) while the retained challenge
  transport carries the traffic. `RealtimeLoop` is the object the application
  holds: it owns the two lanes and the signal, `start()`/`stop()` are the
  generation lifecycle on the owner, and `run()` drives both lanes in one task
  group until the generation they started under is superseded.
- `LifecyclePolicy` is when the lanes run, as pure logic with no platform in
  it: `didBecomeActive` on stopped lanes starts them and mints a generation,
  which is what makes the first cycle ask for `messages` rather than wait on
  `events`; `didBecomeActive` on running lanes does nothing at all, so a
  `willResignActive` that is not followed by `didEnterBackground` — a system
  permission alert, the Control Center, the app switcher — costs neither a
  generation nor a round trip; `didEnterBackground` stops them, **unless** a
  call is live, because a call is signalled over these very lanes
  (`CallActivity.isActive` is Android's `callActive`,
  `TextEngine.java:86,90,158-161`) and the `audio` background mode exists to
  keep it alive. A call that has ended keeps them for ten more seconds so that
  the last control and its receipt leave the device (`callTeardown`,
  Android's `callDraining`, `TextEngine.java:81-83`), and when that window
  elapses in the background the lanes stop. `LifecycleRunner` holds the policy,
  applies what it decides to a `LifecycleTarget` (`RealtimeLoop`), owns the
  task the lanes run in and takes the platform's posts through one ordered
  queue, because two tasks over an actor could apply a background and a
  foreground in the wrong order. Nothing else starts a lane: there is no
  background-task scheduling, no background app refresh and no VoIP push
  registration in this client, and `LifecycleTests` scans both the package and
  the application sources to keep it that way.

```sh
swift test --package-path clients/ios/ParanoidKit --filter CoreBridgeTests
```

The host run links the macOS slice and covers `create_identity` ->
`upgrade_v2` (schema 3), `view` on garbage (`invalid_state`), the core
`input_limit`, and byte-exact `JsonSpan` on replies with escaped quotes and
nested objects. SwiftPM writes its scratch directory to `ParanoidKit/.build/`
(git-ignored); add `--scratch-path clients/ios/out/spm` to keep it under
`out/`. The same tests run on the simulator with
`xcodebuild test -scheme ParanoidKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`
from the package directory.

## Application project (`App/`)

`App/ParanoID.xcodeproj` is a hand-written project (`objectVersion` 77, no
generator: ADR-0014 rejects XcodeGen) with three targets, listed by
`xcodebuild -project clients/ios/App/ParanoID.xcodeproj -list`: the `ParanoID`
application, the `ParanoIDTests` unit-test bundle hosted in the application
and the `ParanoIDUITests` UI-test bundle. Each target's sources are a
`PBXFileSystemSynchronizedRootGroup` over `App/ParanoID`, `App/ParanoIDTests`
and `App/ParanoIDUITests`, so a new file in one of those directories joins its
target without a project edit; `Info.plist` and `ParanoID.entitlements` are
excluded from the application's resources by an exception set because the
plist is processed, not copied. The one shared scheme `ParanoID`
(`xcshareddata/xcschemes`) builds the application and tests both bundles.

- `Config/Bundle.xcconfig`, the project-level base configuration, holds the
  identity and platform pins: `PRODUCT_BUNDLE_IDENTIFIER =
  global.paranoid.messenger` (the test bundles append `.tests` / `.uitests`
  in `project.pbxproj`), `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (the
  `toolchain.json` pin), `DEVELOPMENT_TEAM = $(PARANOID_IOS_TEAM_ID)` so the
  Apple team comes only from the environment and is never written into the
  repository, and `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` because the
  xcframework's simulator slice is arm64-only.
- `ParanoID/Info.plist` is explicit (`GENERATE_INFOPLIST_FILE = NO`): bundle
  identity from the build settings, portrait, iPhone only, no
  `NSAppTransportSecurity` / `NSAllowsArbitraryLoads`, and one purpose string
  — `NSCameraUsageDescription`, which says what the camera is for and that no
  picture is kept.
  `ParanoID/ParanoID.entitlements` is empty: no `aps-environment`, because
  there is no push (see the component documentation).
- The application and `ParanoIDTests` depend on the local package
  `../ParanoidKit` (`XCLocalSwiftPackageReference`) and nothing else. Both
  link that package's `WebRTC` product and carry `LD_RUNPATH_SEARCH_PATHS`
  (`@executable_path/Frameworks`, and `@loader_path/Frameworks` in the test
  bundle) for the dynamic `WebRTC.framework` Xcode embeds next to the binary.
  The copy inside `ParanoID.app/Frameworks` is what a phone would run, and in
  an unsigned build it is byte-for-byte the slice `webrtc_dependency.py`
  verified against the pinned archive — `test_app_bundle.py` weighs it.
  Run `build-core.sh` and `webrtc_dependency.py` first so that both
  xcframeworks exist.
- The application's resources phase carries exactly one file:
  `../out/THIRD_PARTY_NOTICES.txt`, written by [`notices.py`](notices.py).
  The reference is a path relative to the project, not a copy in the source
  tree, so the generated file is never committed and a build that runs before
  the packager fails on a missing input.
- `ParanoID/AppLifecycle.swift` is the only place where UIKit meets the
  realtime lanes: three `NotificationCenter` subscriptions
  (`didBecomeActive`, `willResignActive`, `didEnterBackground`) handed to
  `LifecycleRunner.post(_:)`, and one task draining that queue. It holds no
  rule of its own; every decision is `LifecyclePolicy`'s, in the package.
- `ParanoID/Qr/` is the contact in both directions, and the same string on
  both sides of it. `ContactQrView` draws the code for the exact `contact`
  text (regenerated only when that text changes, Android's `displayedQr`
  guard, `MainActivity.java:613`) and carries the two ways to hand it over as
  text: the share sheet (`UIActivityViewController` with the string itself,
  `MainActivity.java:175`) and the clipboard (`UIPasteboard`, local to this
  device, with Android's confirmation wording, `MainActivity.java:181,521`).
  `QrScannerView` is the port of `QrScanActivity.java`: it asks for the camera
  when the answer is not known yet, runs one `AVCaptureSession` with a single
  `AVCaptureMetadataOutput` restricted to `.qr` (set after `addOutput`) at
  `.hd1920x1080` — `.high` if the session refuses it — with `rectOfInterest`
  left alone and the lens told to look near, which is the dense-QR fix of v15
  in iOS terms. No photo, video-data or movie output exists, so a frame never
  reaches this process: what arrives is the decoded string, and the first
  accepted one stops the session and leaves verbatim. A payload above 2048
  bytes is refused and the session keeps scanning; cancelling touches neither
  the identity nor the snapshot nor the network. `.denied` and `.restricted`
  become `ScanDeniedView` (Настройки through `UIApplication.openSettingsURLString`,
  or the paste field), and `PasteContactSheet` is the 4096-byte text import of
  `MainActivity.pasteContact()` — trimmed of surrounding whitespace as Android
  trims it, and otherwise not touched, so duplicate and unknown members fail
  in Rust's strict parser rather than being collapsed on the way.
- `ParanoIDTests/QrTests.swift` is the round trip, with a contact the core
  itself produced: a freshly created identity is registered with the
  enrollment it would have received — `server_status_v2` only compares that
  enrollment against the local credential (`clean_service.rs:796-810`) and the
  credential fingerprint is a digest over public fields
  (`key-protocol/src/lib.rs:57-71`), so no server is involved — and
  `prepare_contact_v2` then builds the genuine ~900-byte
  `paranoid-contact-v2` text. That text through `CIQRCodeGenerator` and back
  through `CIDetector` is byte-identical; so is a 2048-byte boundary vector at
  level M; 2049 bytes are refused by this client although the encoder would
  have taken them; and a text with a non-ASCII member or a duplicated member
  reaches the core unchanged and is refused there as `invalid_contact`, which
  is the rule of `key-enrollment-v1.md:91-92`. Scanning a code off a real
  camera is a device action and stays `NOT RUN`
  ([verification](../../docs/clients/ios/verification.md), REQ-ID-007).
- `ParanoIDTests/BridgeSmokeTests.swift` runs `create_identity` ->
  `upgrade_v2` inside the application process on the simulator and prints
  one `state.version=3` line (never the snapshot), which proves that the
  `ios-arm64-simulator` slice links and executes. `ParanoIDUITests` only
  launches the shell; screen tests arrive with the screens.
- `ParanoIDTests/SdpCompatibilityTests.swift` is the call go/no-go gate, and
  it measures [call-v2](../../docs/protocol/call-v2.md), not voice v1. It
  builds an `RTCPeerConnectionFactory` with the bundled encoder/decoder
  factories and the configuration of `WebRtcAudioEngine.java:240-251`
  (unified plan, max-bundle, RTCP mux required, TCP candidates disabled,
  gather-once, candidate pool 0, no ICE servers), adds one audio track and one
  video track that starts disabled, and restricts the senders with
  `setCodecPreferences`: `audio/opus`, then H.264 first, VP8 as the mandatory
  fallback and the `rtx`/`red`/`ulpfec`/`flexfec-03` helpers on the video
  transceiver (`WebRtcAudioEngine.java:263-284`, owner decision 2026-09-11).
  VP9 and AV1 are in this libwebrtc build and are dropped here, in
  configuration. It then waits for gather-once and pushes the offer, the
  answer and one `media` camera-state control through the core between two
  synthetic identities (`send_call_v1` -> `receive_v2`, as
  `clients/core/tests/voice_calls.rs` does), with `v: 2` and a real boolean
  `video` in every body; a fourteen-member v1 body is refused as
  `invalid_request` before validation, which is the alpha break call-v2
  declares. The SDP is never rewritten: anything the core refuses is fixed
  through WebRTC configuration. The survey lands in
  `out/evidence/sdp-spike.json` with the ICE credentials masked; measured on
  the simulator (2026-09-13) the offer is 3768 B of the 9000-byte cap, 93
  lines, 6 candidates, sections `audio` then `video` with one `a=sendrecv`
  each, one `a=rtpmap:111 opus/48000/2` and H.264/VP8 with their helpers in
  the video section, no `a=crypto`, `a=setup:actpass`; the answer 3664 B and
  `a=setup:active`; offer, answer and `media` all accepted by the core.
- `ParanoIDTests/KeychainStoreTests.swift` is the half of the storage rules
  that needs a real platform: the item under `paranoid-text-state-v0` with the
  attributes it was asked for, the install-marker matrix (stale key with no
  marker is wiped and `create_identity` then works; marker with a key and no
  file, and marker with a file and no key, both freeze; marker with neither is
  a fresh install) and one commit driven through `open`/`F_FULLFSYNC`/
  `rename(2)` on a real file system. It runs with the **default** simulator
  signature, not `CODE_SIGNING_ALLOWED=NO`: without signing Xcode skips
  `ProcessProductPackaging`, the process carries no `application-identifier`,
  and every `SecItem` call returns `errSecMissingEntitlement` (-34018). A
  separate `-derivedDataPath` keeps that signed build apart from the unsigned
  ones. The test uses the real Keychain account and a scratch defaults suite,
  and deletes both in `setUp` and `tearDown`; its state file goes to a
  temporary directory, never to the application's own `Application Support`.
  The simulator has no Data Protection and reports no protection class, so the
  class the write asks for can only be observed on a device, which is a live
  action.

```sh
xcodebuild -project clients/ios/App/ParanoID.xcodeproj -list      # Targets: ParanoID, ParanoIDTests, ParanoIDUITests
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App CODE_SIGNING_ALLOWED=NO \
  -only-testing:ParanoIDTests/BridgeSmokeTests                    # ** TEST SUCCEEDED **, log line state.version=3
```

`CODE_SIGNING_ALLOWED=NO` keeps simulator runs independent of any signing
identity; an unsigned device build (`xcodebuild build -configuration Release
-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`) links the
`ios-arm64` slice the same way. Signed installs and TestFlight uploads are
live actions and wait for the owner's "go". `-derivedDataPath` keeps build
products under `out/`; Xcode's per-user state (`xcuserdata/`) is git-ignored.

## Local stand (`local_stand.py`)

The simulator and the local tests talk only to a stand on this Mac: the
**unchanged** server built from the working tree (`cargo +1.98.1 build
--locked --release --manifest-path server/Cargo.toml --target-dir
clients/ios/out/server-target`) plus a private PostgreSQL 16 cluster on a Unix
socket under `clients/ios/out/`. One run creates the cluster, a disposable
self-signed TLS identity (`scripts/create-test-tls.py`), runs
`paranoid-server self-service-init` and starts the server in
`PARANOID_MODE=self-service-v2-local`; TURN is not started, so
`/v2/voice/turn` answers an authenticated `404 turn_disabled` and calls use
direct ICE. Everything is stopped and removed on exit; the log stays in
`clients/ios/out/logs/`. The stand never contacts the hosted server or an
existing PostgreSQL cluster.

```sh
python3 clients/ios/local_stand.py --run 'curl -s --cacert $TLS_CRT $URL/health'
# {"protocol":"paranoid-self-service-v2","realtime":"signed-long-poll-v1","status":"ok"}
python3 clients/ios/local_stand.py --print-descriptor     # server_url, tls_spki_sha256, launch_arguments; Ctrl-C stops
python3 clients/ios/local_stand.py --bind 192.168.1.20    # LAN address for a phone on the same Wi-Fi
```

`--run CMD` executes `CMD` with `sh -c` once `/health` answers and exits with
its status; the command sees `URL`, `PIN`, `TLS_CRT`, `TLS_KEY`, `PG_SOCKET`,
`PG_BIN`, `DATABASE_URL`, `SERVER_BINARY`, `STAND_DIR` and `STAND_LOG`.
`--print-descriptor` prints one JSON line whose `launch_arguments` are the
`-paranoid-realm <url> -paranoid-pin <hex>` pair the app takes at launch. The
port is a free one unless `--port` is given. In `self-service-v2-local` mode
the server accepts loopback binds only (`server/src/main.rs`, `bind_allowed`),
so for a non-loopback `--bind` the server listens on `127.0.0.1:<port>` and
the script relays TCP from `<bind>:<port>`; TLS stays end to end (the
certificate names the LAN address), the same front/back split
`clients/android/test_realtime.py` uses.

## Clean-install text messaging (`test_clean_self_service.py`)

`ParanoidKit/Sources/service-bridge` is the host-only fixture that drives the
shipped client classes from a pipe: it reads `<phone>\t<op>\t<base64 value>`
lines and answers one base64-encoded public view per line, the line protocol of
`clients/android/test/CleanSelfServiceBridge.java`, with the same five
synthetic phone names and the same `create` / `sync` / `pair` / `send` /
`block` / `pending` / `fail_next_commit` / `post_without_accept` / `view`
operations, plus the `start` / `stop` / `kick` of
`clients/android/test/RealtimeBridge.java:75-78` and one of its own:
`longpoll` runs both lanes for a fixed number
of seconds, which is the only way to exercise the long-poll transport from a
tool that otherwise answers one line per request. `start` leaves the lanes
running between two lines instead of driving one cycle per line, which is what
the realtime fault fixture below needs, and every view
then also carries what those lanes published: the online flag, the
notification counts and the instant each incoming text became durable — read
back out of the committed file, so a publication that ran ahead of its commit
is recorded as a failure and refuses the next command
(`RealtimeBridge.java:36-49,80`). Behind it are the real
`StateOwner` over `SelfServiceClient`, `SnapshotStore`, `ProofFlow` and
`RealtimeTransport`; every operation runs one closure on the owner and the tool
awaits the network once, at the top level of `main.swift`, because it has no
lanes of its own. Two things only are the
fixture's own, because a command-line tool has neither: the AES-256 wrapping
key lives **in memory** instead of the Keychain
(`StorageGuard.requireContinuity` is still evaluated against it, so a state
file whose key died with the process freezes) and the state file lives under
the directory given as the first argument. The compiled hosted default is
passed as `nil`, so the tool can dial only the realm and pin on its own
command line.

`test_clean_self_service.py` builds that executable, brings up the stand above
and runs one of two scenarios over it. `--registration-only` is the `create`
story of `clients/android/test_clean_self_service.py:106-110`: a phone with
nothing on it creates an identity (`create_identity` then `upgrade_v2`, two
durable commits, no enrollment yet), registers against the stand and ends up
with `enrollment.mode == "active"`, a 64-digit `contact_fingerprint` (two more
commits) and a realtime session that the core validated before it was adopted;
repeating both operations commits nothing and leaves the snapshot byte for
byte.

The default scenario is the messaging one, and it runs over two bridge
processes: two devices that share nothing but the server, and a phone parked in
a long poll cannot answer a line while it waits. In order, each step checked on
both sides and in the cluster — one phone pairs the other's contact and writes
to it, which is one check after the server accepted the envelope and never
before; the receiver, which scanned nothing, shows the conversation as
`network_unverified` and replies without pairing, and both directions end up
double-checked; `psql` proves every stored row is frame-2 ciphertext, byte for
byte what the core signed, and that no text this run sent appears in any table
of the cluster; an answer lost after the server committed is retried exactly,
keeps its `sequence` and adds no row; a blocked contact refuses the send as
`contact_blocked` and acknowledges an incoming message from it with nothing;
and a storage fault on an incoming plaintext-and-receipt candidate transmits
nothing, leaves the retained snapshot byte for byte and freezes the client.

`--longpoll` adds the slowest story, which is also the last one the two live
phones can act out, because the storage fault above freezes one of them for
good: five minutes of the real lanes, which is what crosses the server's
eight-second idle header timeout, its 120-second absolute socket lifetime and
the 240-second session renewal
(`docs/protocol/realtime-v1.md:148-151,179-181`). The lanes must publish no
failure over that run, keep the page arriving, and carry a message the peer
sends in the middle of it together with its receipt. It is off by default, so
an ordinary run of the file costs about a minute instead of six.

```sh
python3 clients/ios/test_clean_self_service.py --registration-only --evidence-dir out/checks/registration
jq '.enrollment_mode,.session.issued,.snapshot.unchanged_by_repeat' \
  clients/ios/out/checks/registration/registration-result.json   # "active" true true
python3 clients/ios/test_clean_self_service.py --evidence-dir out/checks/local-text
# PASS: 2 phones, 3 texts, 3 receipts, 0 plaintext rows, longpoll skipped (--longpoll)
python3 clients/ios/test_clean_self_service.py --longpoll --evidence-dir out/checks/local-text
# PASS: 2 phones, 4 texts, 4 receipts, 0 plaintext rows, longpoll 300 s OK
jq '.server_state.plaintext_rows,.longpoll.offline_publications,.storage_fault.frozen' \
  clients/ios/out/checks/local-text/clean-fixture-result.json    # 0 0 true
```

The evidence names counts, digests and verdicts only: no account, no
fingerprint, no realm, no pin and no snapshot bytes. Both scenarios carry the
digest of the server binary they ran against and of the
`ParanoidCore.xcframework` slice the bridge linked.

## Realtime faults (`test_realtime.py`)

The same stand and the same fixture, with the lanes left running and one thing
between the client and the server: `FaultProxy`, **imported** from
`clients/android/test_realtime.py` and never copied, so the faults this client
is measured under are the ones Android was measured under. It is a
verified-TLS forwarder that can hold one sender's POST on the wire, drop an
answer the server has already committed, replay a consumed authorization so
that the *backend itself* answers 401, and call back at the instant a phone is
opening a session.

That class hard-codes port 38443 for both its front and its back address
(`clients/android/test_realtime.py:103,182,253`), so the run needs two
addresses of this Mac: the throw-away certificate, the realm and the pin name
the front address the client dials (`https://127.0.0.22:38443`, a literal
IPv4 origin) and the server binds the back address (127.0.0.23). Both are
`lo0` aliases, added once by the operator:

```sh
sudo ifconfig lo0 alias 127.0.0.22 up
sudo ifconfig lo0 alias 127.0.0.23 up
```

Without them nothing is faked: the run prints `NOT RUN: lo0 alias missing`,
records that reason in the evidence and exits 2. Three synthetic phones share
one `service-bridge` process — as the Java fixture's peers share one JVM,
which is what makes the monotonic instants of two phones readings of one
clock — and five stories run over them:

- **A receipt held on the wire.** The receiving phone's receipt POST is
  stopped inside the proxy while the message it acknowledges is already
  sealed, renamed, read back and published from that file: the two halves of
  "renderer publication follows successful full native candidate persistence
  and precedes receipt network completion"
  ([realtime v1](../../docs/protocol/realtime-v1.md) lines 97-99). Meanwhile
  the sender shows no delivery mark, the cluster holds no receipt row, and the
  blocked phone's state owner still answers a local send in about 13 ms
  against a budget of 1500 ms — its receipt lane is blocked, not its ratchet.
- **24 warm foreground samples**, alternating direction, from the instant the
  sending phone was handed the text to the instant the receiving phone
  published it out of its durable snapshot: P50 ≤ 500 ms and P95 ≤ 1500 ms
  (57 to 74 ms and 81 to 86 ms over repeated runs).
- **An answer lost after the server committed** (`drop_sender`). The one
  identical repeat of `RealtimeTransport.send` is refused as a replay by the
  server — the nonce is spent — `SessionCall` re-signs exactly once, and the
  row keeps its `sequence` and its ciphertext: `200, 401, 200` on the wire,
  one stored envelope, no authority declared lost.
- **A consumed authorization replayed** (`consume_401_sender`): the 401 is the
  server's own, one retry with a freshly signed nonce carries the unchanged
  ciphertext through, the session is kept and `authorizationLost` is never
  published.
- **The server rolled at the session-open boundary**
  (`before_session_challenge`). At the genuine instant a fresh phone opens a
  session, the same binary is stopped and started again on the same data — no
  database reset, no new identity, no client restart. The server's in-memory
  sessions (`server/src/self_service_http.rs:28`) are gone, so an established
  phone meets a real 401 twice, drops the session, rediscovers the capability
  ([realtime v1](../../docs/protocol/realtime-v1.md) lines 172-177) and opens
  a new one, while the fresh phone registers across the boundary and its first
  message crosses with its receipt. Android rolls a *second, older* binary in
  at that point (`--legacy-server-binary`); there is none to roll in here, so
  this is the same boundary with the same binary.

```sh
python3 clients/ios/test_realtime.py --pg-bin /opt/homebrew/opt/postgresql@16/bin \
  --evidence-dir out/checks/realtime
# 24 warm samples P50=57.4 ms P95=81.0 ms
# result: PASS
jq -c '.result,.lost_answer.statuses,.consumed_nonce.statuses,.rolled_session.sessions_reopened' \
  clients/ios/out/checks/realtime/realtime-fixture-result.json   # "PASS" [200,401,200] [401,200] 1
jq 'length' clients/ios/out/checks/realtime/network-timings.json  # every request the proxy forwarded
```

The evidence is counts, digests and verdicts, plus the proxy's own
`network-timings.json` (path, method, status, milliseconds) and
`latency-samples.json`: no account, no fingerprint, no realm, no pin, no
message text and no snapshot bytes. One run costs about twenty seconds.

## Application in the simulator (`test_sim_text.py`)

The two fixtures above drive the client's classes; this one drives the
**application**. `ParanoIDUITests/TextFlowUITests` taps its way through the
shipped screens on `iPhone 17 Pro (26.5)` while the other side of every
message is a second `service-bridge` phone on the same stand, so a `✓` on the
screen means the unchanged server stored that envelope and a `✓✓` means the
peer's own core acknowledged it.

The application is built **with** the default simulator signature — not with
`CODE_SIGNING_ALLOWED=NO`, which the rest of this README uses. Without a
signature the process carries no `application-identifier`, every `SecItem`
call answers `errSecMissingEntitlement` (-34018) and the client freezes before
it can open its state; `DerivedData-sim-text` keeps that signed build apart
from the unsigned ones, exactly as `DerivedData-App-signed` does for
`KeychainStoreTests`. The stand's `-paranoid-realm` / `-paranoid-pin` pair is
passed on every launch, so the run cannot reach the hosted alpha even by
accident, and the test asserts that the stand guard is *not* what it sees.

Two scenarios run, in this order:

`text`
    `xcrun simctl uninstall global.paranoid.messenger`, then «Создать ID» →
    «Мой ID» with the contact QR and a 64-digit account → «Вставить контакт»
    with the peer's own contact text → «Отпечаток совпадает» against the
    fingerprint that peer's core published → the chat → one tap on
    «Отправить» → `✓` → the peer answers → its bubble and `✓✓` → a **double**
    tap on «Отправить» → one bubble, one envelope at the peer and one `✓✓` →
    «Заблокировать контакт», which disables the composer, and
    «Разблокировать контакт», which restores it.

`reinstall`
    Uninstall again and launch again. The container is gone and the
    simulator's Keychain is not, which is the reinstall of `StorageGuard`
    (D-004): the launch must find no identity, must **not** freeze over the
    retained key, and «Создать ID» must produce an account that is not the
    previous one's. That the item really did survive is measured rather than
    assumed — the fixture counts this application's rows in the device's own
    `keychain-2*.db` on both sides of the uninstall and refuses to call the
    run a reinstall if the count drops. The account cannot be looked for by
    name there: a data-protection item stores `acct` and `svce` as digests,
    and only the access group is plain.

The test and the script meet in a rendezvous directory rather than on a clock.
The test writes one request and blocks; the script answers it. That is what
makes every `xcrun simctl io <udid> screenshot` a photograph of the screen the
assertion was just made about, and what lets the test wait for the peer's own
core to hold a message instead of for a fixed number of seconds. Five requests
exist — a screenshot, a note for the evidence, and the peer's `expect`, `send`
and `sync`.

```sh
python3 clients/ios/test_sim_text.py --evidence-dir out/evidence/sim-text
# PASS: 15 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap
# text: PASS
# reinstall: PASS
jq '.scenarios,.reinstall,.server_state' \
  clients/ios/out/evidence/sim-text/sim-text-result.json
```

The evidence is that JSON and the screenshots beside it. The JSON names
counts, digests and verdicts only: no account, no fingerprint, no contact, no
realm, no pin and no snapshot bytes. The screenshots are of the screens
themselves, so they do show this run's throw-away account — they are evidence
for the owner, not a document to quote from. Everything under `out/` is
git-ignored.

Two things this fixture found in the screens, both fixed in them rather than
worked around here:

- SwiftUI propagates an accessibility modifier to **every** element under the
  view it is applied to, so `.accessibilityIdentifier("chat")` on a screen's
  root stack replaced the identifier of every control inside it — the
  composer, the send button and the trust banner all answered to `chat`. The
  screens whose root is a stack now declare themselves accessibility
  containers (`.accessibilityElement(children: .contain)`), which is what a
  `ScrollView` already was: that is why «Мой ID» and «Контакты» were never
  affected.
- A message is two accessibility elements, not one: the combined bubble
  («<текст>, ✓ Сохранено сервером») and the selectable `Text` inside it.
  Counting bubbles counts the first of the two; counting both would count
  every message twice, which is the difference between a double-tap guard
  that holds and one that only looks as if it does.

## Third-party notices (`notices.py`)

Android's algorithm (`clients/android/notices.py`), rooted here at
`bridge/Cargo.toml` and filtered for `aarch64-apple-ios`: resolve the locked
graph once, walk it from the root so only crates that actually link are
counted, and copy every `license*`/`licence*`/`copying*`/`notice*`/
`copyright*` file those crates ship, verbatim, into
`out/THIRD_PARTY_NOTICES.txt` — 91 crates today, whatever the shared core
pulls in. A linked crate whose package carries no license text fails the
build with `Missing license text: <crate> <version>`; it is never skipped.
Three crates publish none upstream and are served from pinned copies:
`matrix-pickle` and `matrix-pickle-derive` from
`spikes/002-android-bootstrap/licenses/matrix-pickle-LICENSE`, `jni-sys-macros`
from `licenses/jni-sys-macros-LICENSE-{APACHE,MIT}` (byte-for-byte copies of
Android's, see [licenses/README.md](licenses/README.md)). `jni` itself stays
in the graph — the core depends on it unconditionally — so its notices ship
here too.

After the crates comes the pinned `WebRTC.xcframework`: its version, the
archive and slice digests that `webrtc_dependency.py` enforces, the upstream
source commit, and every file of `licenses/webrtc-150.7871.01/`. There is no
ZXing, org.json or Firebase block — this client scans QR with Vision, parses
JSON in Rust and has no push gateway — and no XcodeGen anywhere.

`--offline` forbids cargo the network (what CI uses, after `cargo check`
has populated the registry); `--manifest-path` and `--output` exist for the
tests. The packager writes `out/` and nothing else; the application picks the
file up from there — the `ParanoID` target's resources phase copies
`out/THIRD_PARTY_NOTICES.txt` into the bundle root, and
[`build.sh`](build.sh) regenerates it before every `xcodebuild`, so a build
that skipped `notices.py` fails on a missing input instead of shipping a
bundle without notices. No screen reads it yet.

```sh
python3 clients/ios/notices.py --offline   # -> clients/ios/out/THIRD_PARTY_NOTICES.txt
python3 clients/ios/test_notices.py        # graph walk, pinned copies, failure modes, the real graph
grep -c "vodozemac\|WebRTC\|jni 0.21.1" clients/ios/out/THIRD_PARTY_NOTICES.txt   # 23
```

## Build order (`build.sh`) and the bundle gate (`test_app_bundle.py`)

`bash clients/ios/build.sh` is the whole client in one command, in the order
`clients/android/build.sh` uses: pins first, then the shared code, then the
application, then what the application turned out to be. Every step runs
after the one before it, the script stops at the first failure and says which
step failed, and nothing in it contacts the hosted server. It re-executes
itself through [`toolchain.sh`](toolchain.sh), so a non-interactive shell
without `~/.cargo/bin` on `PATH` is fine.

1. `test_toolchain.py` — the pinned tool versions.
2. `webrtc_dependency.py`, `test_webrtc_dependency.py` — the pinned WebRTC
   archive, re-extracted into the SwiftPM binary target on every build.
3. `test_bridge_lock.py` — the bridge lock still equals `clients/core`'s.
4. `cargo test --release` of the shared core with the same test targets as
   `clients/android/build.sh:25` (`--lib`, `clean_first_contact`,
   `realtime_signing`, `voice_calls`), into `out/core-target` so the red-zone
   crate's own `target/` is left alone, and `cargo test` of the bridge on the
   host, where the `rlib` and `bridge/tests/abi.rs` live.
5. `build-core.sh` — the three release slices and `ParanoidCore.xcframework`.
6. `swift test` of `ParanoidKit` (scratch path `out/spm`).
7. The iOS ↔ Android cross-test of plan steps 33-34. It needs a JDK, which
   this Mac does not have, so the step prints `SKIP:` with that reason and
   the manifest records it as `skipped`. It is never a silent pass, and it
   becomes a real run as soon as `java_deps.sh` lands and `javac` exists.
8. `check-pinned-tls.py` and `test_realtime_transport.py` — the nine leaf
   checks and the eight socket rules, against real loopback servers.
9. `notices.py --offline` and `test_notices.py` — the notices that then ship
   inside the bundle.
10. `test_ui_contract.py`, `test_call_controller_parity.py` and
    `test_component_boundary.py` — the source contracts, the call scenarios
    this client shares with the Android smoke, and the branch boundary.
11. `xcodebuild test` on `iPhone 17 Pro (26.5)` with `CODE_SIGNING_ALLOWED=NO`,
    then a second run of `ParanoIDTests/KeychainStoreTests` alone **with** the
    simulator's own ad-hoc signature. An unsigned application owns no
    Keychain, so that one bundle of tests cannot say anything in the first
    run; the ad-hoc simulator signature involves no team, no identity and no
    owner gate. Splitting the run is the only way both halves are real.
12. `xcodebuild ... -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
    build` in `Release`, copied to `out/ParanoID.app`, and
    `test_app_bundle.py` on that copy.
13. The archive. Without `PARANOID_IOS_TEAM_ID` the script prints
    `Archive skipped: PARANOID_IOS_TEAM_ID unset` and exits 0 — signing is
    the owner's gate, not the build's. With it set, `xcodebuild archive
    -allowProvisioningUpdates` and `-exportArchive` run against
    [`App/ExportOptions.plist`](App/ExportOptions.plist): that template holds
    no `teamID`, and `build.sh` writes the resolved copy (template plus the
    one key, taken from the environment) to the git-ignored
    `out/ExportOptions.plist`. `PARANOID_ASC_KEY_ID`, `PARANOID_ASC_ISSUER_ID`
    and `PARANOID_ASC_KEY_PATH` are added as `-authenticationKey…` only when
    all three are set; the `.p8` itself is never copied into the repository.
    `destination` is `export`, so nothing is uploaded here.

The run then writes `out/evidence/build-manifest.json`: the commit, the tool
versions, every step with its status and duration (including the skipped
one), the bundle identity and version, and the SHA-256 of the executable, of
the embedded `WebRTC.framework`, of the notices on both sides and of both
lock files, with `out/evidence/bridge-hashes.json` folded in.

`test_app_bundle.py` is the iOS sibling of `clients/android/test_apk.py` and
the only thing in this directory that reads a finished bundle: bundle
identifier `global.paranoid.messenger`, the pinned
`CFBundleShortVersionString` / `CFBundleVersion` pair and the
`ios_deployment_target` of `toolchain.json`; `UIBackgroundModes` exactly
`[audio]` with no `voip`, no `aps-environment` in the plist or in the signed
entitlements and no `NSAppTransportSecurity` / `NSAllowsArbitraryLoads`; one
arm64 executable and exactly one embedded framework, whose binary is the
pinned slice; `THIRD_PARTY_NOTICES.txt` identical to what `notices.py` wrote,
naming the crates that link and none of the Android-only components; and no
`.p12`, `.p8`, `.env` or `.mobileprovision` anywhere inside. Two rules bend
for a *signed* bundle and say so on their own line rather than passing
quietly: the canonical `embedded.mobileprovision` iOS itself puts at the
bundle root is tolerated and reported, and the WebRTC digest is `SKIPPED`
because Xcode re-signs an embedded framework (the pin is enforced at
extraction). A signed bundle must report the Team ID in
`PARANOID_IOS_TEAM_ID`; a signed bundle with that variable unset is a
failure, and an unsigned one — all this repository can make without the
owner's gate — says `SKIPPED`, never `OK`.

```sh
bash clients/ios/build.sh                        # the whole chain; exit 0 and "Archive skipped: PARANOID_IOS_TEAM_ID unset"
python3 clients/ios/test_app_bundle.py out/ParanoID.app   # the built bundle (path relative to clients/ios or to the current directory)
jq '.steps[] | [.step, .status] | @tsv' clients/ios/out/evidence/build-manifest.json -r
```

## Checks

```sh
python3 clients/ios/test_toolchain.py           # pinned tool versions (--no-xcode skips Xcode/SDK/Swift/PostgreSQL)
python3 clients/ios/test_component_boundary.py  # committed changes stay inside the iOS allowlist
python3 clients/ios/test_bridge_lock.py         # bridge lock matches clients/core/Cargo.lock
swift test --package-path clients/ios/ParanoidKit --filter CoreBridgeTests   # Swift adapter over the bridge (needs build-core.sh)
xcodebuild -project clients/ios/App/ParanoID.xcodeproj -list                  # three targets
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App CODE_SIGNING_ALLOWED=NO \
  -only-testing:ParanoIDTests/BridgeSmokeTests                                # bridge smoke in the simulator
python3 clients/ios/webrtc_dependency.py        # re-extract the pinned WebRTC.xcframework (--offline uses the cached archive)
python3 clients/ios/test_webrtc_dependency.py   # digest, slice and re-extraction rules of that pin
python3 clients/ios/notices.py                  # bundle the locked crate and WebRTC license texts (--offline in CI)
python3 clients/ios/test_notices.py             # a linked crate without a license text fails the build
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App CODE_SIGNING_ALLOWED=NO \
  -only-testing:ParanoIDTests/SdpCompatibilityTests                           # libwebrtc call-v2 SDP against the core validator
jq '.offer.accepted,.answer.accepted' clients/ios/out/evidence/sdp-spike.json # true true
swift test --package-path clients/ios/ParanoidKit --filter SdpExtractTests  # transport context, per-section survey, 9000-byte cap
swift test --package-path clients/ios/ParanoidKit --filter VoiceRelayConfigTests # TURN metadata: 6 accepted, the 49 Android negatives, the admission window
swift test --package-path clients/ios/ParanoidKit --filter SnapshotStoreTests  # commit order, injected faults, continuity
swift test --package-path clients/ios/ParanoidKit --filter SelfServiceClientTests # v4 wrapper, opening rules, persist before adopt
swift test --package-path clients/ios/ParanoidKit --filter ProofFlowTests    # challenge spacing, discovery, session issuance
swift test --package-path clients/ios/ParanoidKit --filter StateOwnerTests   # owner executor, generations, session ownership, backoff
swift test --package-path clients/ios/ParanoidKit --filter ReceiveLaneTests  # messages first, page limit, cursor recheck, persist before publish
swift test --package-path clients/ios/ParanoidKit --filter RealtimeLoopTests # outbox order, 401 once, deferred 409/507, renewal, legacy window
swift test --package-path clients/ios/ParanoidKit --filter LifecycleTests   # foreground rule: an alert is not a pause, a call keeps the lanes
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App CODE_SIGNING_ALLOWED=NO \
  -only-testing:ParanoIDTests/QrTests                                         # QR round trip on the core's own contact, and both byte bounds
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App-signed \
  -only-testing:ParanoIDTests/KeychainStoreTests                              # Keychain and install marker (needs the simulator signature)
python3 clients/ios/test_clean_self_service.py --registration-only \
  --evidence-dir out/checks/registration                                      # clean-install registration on the local stand
python3 clients/ios/test_clean_self_service.py --longpoll \
  --evidence-dir out/checks/local-text                                        # two phones: texts, receipts, ciphertext and every failure story
python3 clients/ios/test_realtime.py --pg-bin /opt/homebrew/opt/postgresql@16/bin \
  --evidence-dir out/checks/realtime                                          # running lanes under the imported fault proxy (needs the two lo0 aliases)
python3 clients/ios/test_sim_text.py --evidence-dir out/evidence/sim-text     # the application itself in the simulator, plus the reinstall scenario
```

## Rules that apply to every change here

- **Red zones are read-only.** `server/`, `clients/core/src/`,
  `clients/android/`, `key-protocol/` and `deploy/` are never modified from
  this client. `test_component_boundary.py` rejects any diff outside
  `clients/ios/**`, `docs/**`, `README.md`, `CHANGELOG.md` and the client
  workflow; it is the single boundary gate locally and in CI. If the core
  does not build or link for iOS, or its SDP validator rejects iOS SDP, stop
  and report to the owner with a proposed fix; do not patch the core.
- **Pinned toolchain, no generators.** Xcode 26.6 (17F113), iOS SDK 26.5,
  Swift 6.3.3, Rust 1.98.1 with the `aarch64-apple-ios`,
  `aarch64-apple-ios-sim` and `aarch64-apple-darwin` targets, OpenSSL 3 for
  fixtures, PostgreSQL 16 for the local stand. No XcodeGen, no CocoaPods, no
  third-party Swift packages; the only binary dependency is
  `WebRTC.xcframework` `150.7871.01`, verified by digest before extraction.
  The lock-file rule above keeps the Rust graph identical to Android's.
- **Behaviour comes from the protocol and the core.** Write from
  `docs/protocol/*.md` and `clients/core`; use the Java client only as a
  cross-check and record every mismatch in
  [protocol-sources.md](../../docs/clients/ios/protocol-sources.md). Do not
  copy competing wire specifications into this directory.
- **Storage boundary.** Keychain-held AES key (`paranoid-text-state-v0`,
  this-device-only, not synchronizable) plus a Data Protection file, committed
  as temp file, `F_FULLFSYNC`, `rename`, byte-exact read-back; any failure
  freezes the application. An absent install marker means a fresh install and
  deletes a stale key; a present marker with a missing key or file freezes.
  Raw core snapshots hold private keys and plaintext: never log them.
- **Trust.** Same server pin as Android
  (`8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`) and the
  same nine leaf checks, evaluated on `Security.framework`. Saved trust wins
  over compiled defaults; no second pin, no rotation path (separate RFC).
- **Secrets and outputs.** Signing identities, `.p8`, `.p12`,
  `.mobileprovision`, keystores and `.env` never enter git; App Store Connect
  credentials come only from `PARANOID_ASC_KEY_PATH`, `PARANOID_ASC_KEY_ID`,
  `PARANOID_ASC_ISSUER_ID` and `PARANOID_IOS_TEAM_ID`. Build outputs, logs and
  evidence JSON go under `out/`.
- **Live actions need an owner "go".** Installing through the company Apple
  account, registering on the hosted alpha (`https://157.180.49.125:38443`,
  exactly one account, no reserve) and uploading to TestFlight happen only
  after an explicit owner authorization whose permalink is recorded in
  evidence. Simulators use only the local stand (unchanged server binary plus
  local PostgreSQL 16); they never contact the hosted server.
- **Language.** English in this README, under `docs/` and in evidence;
  Russian only inside quoted UI strings.

## Related documentation

- [Core contract](../../docs/clients/core/self-service.md) and
  [core voice controls](../../docs/clients/core/voice-calls.md)
- [Self-service v2](../../docs/protocol/self-service-v2.md),
  [realtime v1](../../docs/protocol/realtime-v1.md),
  [first-contact v1](../../docs/protocol/first-contact-v1.md),
  [voice v1](../../docs/protocol/voice-v1.md) with its
  [call-v2 deltas](../../docs/protocol/call-v2.md),
  [voice TURN v1](../../docs/protocol/voice-turn-v1.md)
- [Android client](../android/README.md) (behavioural reference, not a
  dependency) and [component boundaries](../../docs/project/component-boundaries.md)
- [Verification mapping](../../docs/clients/ios/verification.md) with the
  `NOT RUN` rows that gate any acceptance claim
