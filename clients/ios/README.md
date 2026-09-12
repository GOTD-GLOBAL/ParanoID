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
[RFC-0020](../../docs/rfcs/0020-ios-client.md) and recorded as
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
tests) that holds everything above the bridge in the RFC-0020 design:
storage, TLS, transport, realtime, calls and the UI model. `Package.swift`
declares the `ParanoidCoreFFI` binary target at
`Binaries/ParanoidCore.xcframework` (git-ignored, produced by `build-core.sh`,
which must run first) and the `WebRTC` binary target at
`Binaries/WebRTC.xcframework` (git-ignored, produced by
`webrtc_dependency.py`), and no package dependency at all; `service-bridge` is
the host-only registration fixture described below, and the `core-bridge` and
`tls-smoke` executables named in RFC-0020 arrive with their own pull-request
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
  that the core cross-checks against the text (`voice_v1.rs:126-152`), plus
  the survey that validator cares about: byte count, `a=setup`, every
  `a=rtpmap`, and the `a=candidate` / `a=crypto` counts. It is Android's
  `TextEngine.java:138-144` line scan, cut on UTF-8 bytes like `str::lines()`
  because Swift folds a CRLF pair into one `Character`. It never rewrites the
  description.
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
  `outbound` semaphore and its `kick()`.
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
  `NSAppTransportSecurity` / `NSAllowsArbitraryLoads`.
  `ParanoID/ParanoID.entitlements` is empty: no `aps-environment`, because
  there is no push (see the component documentation).
- The application and `ParanoIDTests` depend on the local package
  `../ParanoidKit` (`XCLocalSwiftPackageReference`) and nothing else;
  `ParanoIDTests` additionally links that package's `WebRTC` product, so it
  also carries `LD_RUNPATH_SEARCH_PATHS` (`@executable_path/Frameworks`,
  `@loader_path/Frameworks`) for the dynamic `WebRTC.framework` Xcode embeds
  in the test bundle. Run `build-core.sh` and `webrtc_dependency.py` first so
  that both xcframeworks exist.
- `ParanoIDTests/BridgeSmokeTests.swift` runs `create_identity` ->
  `upgrade_v2` inside the application process on the simulator and prints
  one `state.version=3` line (never the snapshot), which proves that the
  `ios-arm64-simulator` slice links and executes. `ParanoIDUITests` only
  launches the shell; screen tests arrive with the screens.
- `ParanoIDTests/SdpCompatibilityTests.swift` is the voice go/no-go gate. It
  builds an `RTCPeerConnectionFactory` configured exactly like
  `WebRtcAudioEngine.java:195-202` (unified plan, max-bundle, RTCP mux
  required, TCP candidates disabled, gather-once, candidate pool 0, no ICE
  servers), adds one audio track, restricts the sender to `audio/opus` with
  `setCodecPreferences`, waits for gather-once and then pushes the resulting
  offer and answer through the core between two synthetic identities
  (`send_call_v1` -> `receive_v2`, as `clients/core/tests/voice_calls.rs`
  does). The SDP is never rewritten: anything the core refuses is fixed
  through WebRTC configuration. The survey lands in
  `out/evidence/sdp-spike.json` with the ICE credentials masked; measured on
  the simulator the offer is 1776 B with 7 candidates, one
  `a=rtpmap:111 opus/48000/2`, no `a=crypto` and `a=setup:actpass`, the
  answer 1735 B and `a=setup:active`, both accepted by the core.
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

## Clean-install registration (`test_clean_self_service.py`)

`ParanoidKit/Sources/service-bridge` is the host-only fixture that drives the
shipped client classes from a pipe: it reads `<phone>\t<op>\t<base64 value>`
lines and answers one base64-encoded public view per line, the line protocol of
`clients/android/test/CleanSelfServiceBridge.java`, with the same five
synthetic phone names and the same `create` / `sync` / `pair` / `send` /
`block` / `pending` / `fail_next_commit` / `post_without_accept` / `view`
operations. Behind it are the real `StateOwner` over `SelfServiceClient`,
`SnapshotStore`, `ProofFlow` and `RealtimeTransport`; every operation runs one
closure on the owner and the tool awaits the network once, at the top level of
`main.swift`, because it has no lanes of its own. Two things only are the
fixture's own, because a command-line tool has neither: the AES-256 wrapping
key lives **in memory** instead of the Keychain
(`StorageGuard.requireContinuity` is still evaluated against it, so a state
file whose key died with the process freezes) and the state file lives under
the directory given as the first argument. The compiled hosted default is
passed as `nil`, so the tool can dial only the realm and pin on its own
command line.

`test_clean_self_service.py` builds that executable, brings up the stand above
and runs the scenario over one bridge process. `--registration-only` is the
`create` story of `clients/android/test_clean_self_service.py:106-110`: a phone
with nothing on it creates an identity (`create_identity` then `upgrade_v2`,
two durable commits, no enrollment yet), registers against the stand and ends
up with `enrollment.mode == "active"`, a 64-digit `contact_fingerprint` (two
more commits) and a realtime session that the core validated before it was
adopted; repeating both operations commits nothing and leaves the snapshot byte
for byte. The messaging stories need the iOS sync cycle, so today `sync`
performs `ProofFlow.connect()` only — register, discover, open a session — and
the run refuses anything but `--registration-only`.

```sh
python3 clients/ios/test_clean_self_service.py --registration-only --evidence-dir out/checks/registration
jq '.enrollment_mode,.session.issued,.snapshot.unchanged_by_repeat' \
  clients/ios/out/checks/registration/registration-result.json   # "active" true true
```

The evidence names counts, digests and verdicts only: no account, no
fingerprint, no realm, no pin and no snapshot bytes.

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
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App CODE_SIGNING_ALLOWED=NO \
  -only-testing:ParanoIDTests/SdpCompatibilityTests                           # libwebrtc SDP against the core validator
jq '.offer.accepted,.answer.accepted' clients/ios/out/evidence/sdp-spike.json # true true
swift test --package-path clients/ios/ParanoidKit --filter SnapshotStoreTests  # commit order, injected faults, continuity
swift test --package-path clients/ios/ParanoidKit --filter SelfServiceClientTests # v4 wrapper, opening rules, persist before adopt
swift test --package-path clients/ios/ParanoidKit --filter ProofFlowTests    # challenge spacing, discovery, session issuance
swift test --package-path clients/ios/ParanoidKit --filter StateOwnerTests   # owner executor, generations, session ownership, backoff
swift test --package-path clients/ios/ParanoidKit --filter ReceiveLaneTests  # messages first, page limit, cursor recheck, persist before publish
swift test --package-path clients/ios/ParanoidKit --filter RealtimeLoopTests # outbox order, 401 once, deferred 409/507, renewal, legacy window
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath clients/ios/out/DerivedData-App-signed \
  -only-testing:ParanoIDTests/KeychainStoreTests                              # Keychain and install marker (needs the simulator signature)
python3 clients/ios/test_clean_self_service.py --registration-only \
  --evidence-dir out/checks/registration                                      # clean-install registration on the local stand
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
  [voice v1](../../docs/protocol/voice-v1.md),
  [voice TURN v1](../../docs/protocol/voice-turn-v1.md)
- [Android client](../android/README.md) (behavioural reference, not a
  dependency) and [component boundaries](../../docs/project/component-boundaries.md)
- [Verification mapping](../../docs/clients/ios/verification.md) with the
  `NOT RUN` rows that gate any acceptance claim
