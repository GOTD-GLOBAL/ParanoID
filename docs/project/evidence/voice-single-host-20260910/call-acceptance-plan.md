# CALL-CONNECT01: bounded acceptance proposal and retained capability inventory

2026-09-10. Read-only investigation by the delegated Codex agent. This file is a
proposal for fresh Fable design review, not acceptance, a runtime result, a source
change or permission to repeat denied TURN operations. CALL-CONNECT01 remains OPEN.

## Evidence already established

- Client worktree is clean on `feat/voice-calls-20260909`; retained product engine
  hash is `41662f877cf9743b10d12510f408e69c3d4eac66d825fc2ea4463b40eeebcbf8`.
- `docs/project/evidence/call-connect-ordinary-20260910/README.md` and its fresh
  `fable-final-review.txt` accurately separate the baseline's natural SDK safe
  `connection` error at 16.496318 seconds after accepted Answer (23.357 seconds
  setup budget still remaining) from the fixed arm's connection at 0.903942
  seconds and normal hangup. Fixed observation ended after about 6.219 seconds
  after Answer; this particular arm is not a long connected-call observation.
- The earlier exact-current-engine `publication-regression.json` provides real
  additional evidence: recipient decoded-media check at 59.7869 seconds, mute/
  two-way text check at 79.4069, actual COMPLETE/no-republication at 80.6299 and
  cleanup at 89.9062 on the same run clock. Thus an incoming connected call was
  actually observed for more than the historical 16.5-second window. This is
  existing evidence, not a new run and not proof of universal reliability.
- Fable closed VOICE-PUB-01 for the 500 ms immutable publication change. Do not
  repeat that suite as a substitute for CALL-CONNECT01 disposition.
- The latest observer records delivery time, not native callback source time.
  `WebRtcAudioEngine.fail()` at current source lines 382–385 closes and cleans
  the peer before invoking the listener. Native `peerObserver` callbacks at
  lines 340–360 are not replaceable by the test listener proxy; ICE connection
  callback is empty. Listener attachment can miss early creation errors. These
  are structural observation gaps, not an absent SDK or a harness compile issue.
- The previous A/B's installed APK readback and within-arm PIDs matched. Failed
  `run-as` process-start/maps reads remain NOT_MEASURED. Do not retry those reads
  using a privileged or alternative access path to manufacture attestation.

## Recommended decision before more product code

Ask the required fresh Fable design review to distinguish two questions explicitly:

1. Historical causal research: the missing historical first-cause trace cannot be
   recreated retrospectively. It remains an explicit unknown; no finite number
   of successful calls proves the historical cause or that failure never occurs.
2. Current-build delivery acceptance: define and review bounded actual supported
   call scenarios with clear pass/fail observations and exact source/artifact
   correspondence. Do not silently waive the prior blocker. Fable must expressly
   disposition whether this evidence plus the retained A/B supports current-build
   acceptance while historical attribution remains open, or name the particular
   further observable event it needs. A repeated identical short A/B cannot close
   the source-time gap and should not be run without that reason.

The smallest useful new functional matrix, if Fable agrees, is incoming calls in
two actual consent states (fresh synthetic installation with first microphone
grant, then retained permission/redial), each observed through at least 30 seconds
of connected decoded audio and normal cleanup, and one outgoing integration call
on the same current candidate. Use the existing product deadline when setup fails;
never impose a synthetic 15/20-second failure cutoff or reset consent clocks.
Freeze the finite scenario count before execution, preserve every outcome, and
stop on a real unexplained failure rather than run until convenient success.
This is bounded functional coverage, not a statistical service-level guarantee.
The same scenario matrix should be run against the coordinated installer in an
owned disposable environment when that environment and its relay gates are ready,
so it establishes new integration value rather than repeating the old fixture.

For each call: no media/recording before explicit consent; ample original setup
budget; accepted authenticated answer at the host; successful setRemote; selected
relay/relay pair, connected DTLS, increasing real Opus decode counts/energy on
both endpoints; safe terminal reason; zero active recordings/media/closing count
and restored audio route after normal hangup. Preserve source/artifact/driver/
observer hashes and installed readback without representing file hashes as loaded
native-code attestation. Synthetic reverse-tone energy requires the existing
explicitly instrumented tone path; actual silent emulator microphone frames must
continue to be labelled silent, not invented bidirectional tone.

## Minimal source-time seam, only if the review needs it

This would be a new product-source delta and requires Fable design review BEFORE
implementation, then genuine RED/GREEN, a fresh same-signer versionCode greater
than the actual latest 10, and final source/artifact review. No change is made here.

Prefer one package-private typed diagnostic interface with enum/primitive-only
arguments, a final per-engine sink captured at construction, and null/no-op as the
production default. Add a private, normally-null test injection field in
`TextEngine`; separately packaged instrumentation sets it before Call/Answer and
`createMedia()` passes its captured sink into a package-private engine constructor.
This avoids the current post-construction listener-attachment race without any
public intent, app setting, network command, exported component or global product
logging facility. The normal constructor continues to supply no sink. Fable must
review this exact injection surface rather than infer that reflection is enough.

Capture only:

- monotonic source callback time and owner-delivery time for native aggregate PC,
  ICE connection and gathering state enums; bounded candidate type/count if needed;
- local/remote description set/create success or safe failure enum, never their
  SDP argument, native error text or any SDK report object;
- a typed safe error category immediately before `fail()` cleanup and bounded
  cleanup start/end milestones, independent of the later listener delivery.

The sink must receive no credentials, account/call identifiers, SDP, candidates,
addresses/ports, fingerprints, PCM or arbitrary strings/objects. Its test-only
implementation writes to a bounded in-memory ring, performs no I/O/waits, catches
its own failure, and cannot change arguments, product state, timing authority,
callback order, success/failure propagation or cleanup. Truncation and observer
failure are explicit incomplete-observation states. Even this seam exposes SDK
state/error categories, not the inaccessible internal native ICE causal reason.

Keep the already reviewed controller proxy and host observer for this bounded
seam. A new `CallController.finish` origin API and a full auth/signaling event bus
are unnecessary for the already observed `connection` → `mediaState` path unless
a fresh failure demonstrates that additional ambiguity. Source-level enums before
cleanup plus the host's existing committed-answer/setRemote observations are the
smallest increment with a concrete causal benefit.

Meaningful RED must show the current observer missing a deliberately exercised
pre-cleanup source callback in an isolated callback-contract test; GREEN retains
the enum/times before teardown while original listener arguments/results/errors
and cleanup remain unchanged. A lexical source assertion alone is not callback
or race coverage. Compile against the actual SDK35 and verify the test sink class
and diagnostic evidence are absent from the production APK. Any ordinary runtime
comparison then uses the same reviewed seam and observer for both arms; no relay
restart, network fault injection, expired allocation manipulation or ACL probe is
part of CALL-CONNECT01.

## Available local capability (read-only verified)

- SDK35 `android.jar` exists at
  `/home/codex/.local/share/paranoid-android-sdk/platforms/android-35/android.jar`.
  `adb`, emulator, aapt, apksigner, d8 and zipalign executables exist under that SDK.
- `clients/android/out/deps` contains `webrtc-classes.jar`,
  `json-20240303.jar` and `zxing-core-3.5.3.jar`.
- Retained x86_64 Android JNI exists at external evidence
  `voice-calls-20260909T220516Z/x86-target/x86_64-linux-android/release/`.
- Local host JNI exists with SHA256
  `94a49abd960e3f35a08450e948c5de30e5ae3e8f550d192ca74bc0b4dd9941ce`.
- Retained server exists, SHA256
  `ade6c8353833977cfedd0f5a90463783a7acca55e4058ad615c14c3d2a79a099`;
  retained patched relay exists, SHA256
  `b7f34eb1dd25f919b737e93cf672ad617fd27b6f57386bbb0f571cd64120f551`.
  Neither file's existence establishes runtime security acceptance.
- `/usr/lib/postgresql/16/bin/{postgres,initdb}` exist. The retained aiortc virtual
  environment at `voice-calls-media-discovery-20260909T220410Z/aiortc-venv` exists;
  installed distribution metadata says aiortc 1.15.0.
- The ordinary comparison AVD config and both test APKs remain in its original
  external evidence directory. Fixed fixture APK SHA256 is
  `25200da72b9a9a09cfcfcac1e285d8b209ff789eb7d686e620e76f68f526f032`;
  observer APK is `13ecd54f83f7bb49db472218f0b45a4dd060256633ba5e8108ac399165a4709d`.
  These are x86_64 fixture artifacts, not the ARM64 delivery package.
- Delivery ARM64 APK exists, 15,712,851 bytes; independently rehashed here to
  `a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`.
  Prior verified version/signing identity remain 10 and
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- A process-name-only inventory showed no emulator or turnserver currently
  running. Other local PostgreSQL/Java/ADB processes exist; no ownership is
  inferred and no process was started, stopped or inspected for secret arguments.

## Exact present status and next step

No repository or runtime change, no runtime/media/security test, no reviewer call,
no SSH/network action and no denied-operation retry was performed by this agent.
The only new file is this external review proposal. Fresh Fable should review it
alongside the coordinated installer/network plan and explicitly decide whether the
seam provides necessary evidence before spending a product version on it.
TURN-RT01/TURN-ACL02, actual CLI/systemd credential/lifecycle gates and final review
remain independent mandatory gates. This proposal cannot authorize relay exposure.
