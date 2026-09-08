# Development Android text client

Package `org.paranoid.devtext`, ARM64, API 26+. This is a development build, not
an accepted production identity system or a completed hosted two-phone test.
Java is the small native UI/storage adapter; the separate Rust core owns Olm
state. This does not accept a future iOS UI or change the proposed production stack.

## Build and actual checks

```sh
export ANDROID_SDK_ROOT=/path/to/android-sdk
bash clients/android/build.sh
python3 scripts/check-pinned-tls.py
```

Requires Rust with aarch64-linux-android target, JDK, SDK platform/build-tools 35
and NDK 28.2.13676358. Build runs Rust client tests, Linux JVM JNI smoke and
AES-GCM codec smoke, cross-compiles native code, then signs and checks the APK.
Output: `clients/android/out/paranoid-text.apk`. Test key and build output are
ignored, not committed. The development signature is not a release identity.
A fresh checkout generates a different signing key; it cannot silently update
an earlier differently signed APK. Never uninstall a data-bearing app merely to
bypass signature verification: this development client has no recovery.

Packaging/JVM tests do NOT prove Android Keystore, filesystem durability, UI,
networking or native loading on the actual OPPO devices. Only test data is allowed.

## IP and pinned HTTPS

A domain is optional. The operator generates a self-signed IP certificate on the
intended host using `scripts/create-test-tls.py`, after authorizing that action.
That script creates files only: it does not install a service, open a port or
make the printed URL reachable. Existing destinations are refused, never replaced.
The private key stays on the server. The public descriptor contains the planned
HTTPS URL and 64-hex SHA-256 of leaf SubjectPublicKeyInfo DER.

The tester must verify that public pin out of band with the operator, separately
from the private bearer credential and the peer's public Olm code. Do not obtain
an unverified pin from the endpoint being authenticated. The app requires matching
SPKI, dates, self-signature, server-auth usage, adequate key strength and exact SAN;
platform hostname verification remains enabled. Only TLS 1.2/1.3, no redirects,
no trust-all fallback or process-global TLS changes. Key mismatch fails before HTTP.

The pin is saved in the encrypted client snapshot and cannot silently change.
Certificate renewal with the same key is possible; a key change needs an explicit
future re-enrollment procedure. Pinless snapshots from earlier unreleased test
builds fail closed, not a silent reset. This is not a data-migration promise.

## Device test sequence once reviewed and authorized

1. Install the reviewed exact APK on both OPPO phones; do not disable Play Protect.
2. Use the same approved HTTPS URL and verified public server pin on both phones.
   Configure separate server credentials and roles alice/bob. Never share private
   credentials as part of a public pairing code.
3. Exchange the public codes and compare directly on the other phone's screen.
   Confirm explicitly. Existing peer keys cannot silently be replaced.
4. First validate local configure/pair/queue/reopen and Keystore behavior with test
   data. Connecting to a hosted instance is a later, separately authorized step.
5. After runtime/host readiness, test text both ways, single/double checks,
   receiver offline, reconnect, app/process restart and no duplicate display.

One check means server acceptance; two require a peer-authenticated receipt after
local storage. Receipt, message, ratchet, cursor and retryable outbox changes share
one candidate snapshot. Android encrypts it with a Keystore AES-GCM key and performs
an AtomicFile write, fsync, readback and parent-directory sync before network effects.
A storage error freezes operations rather than reusing uncertain state. Key loss
is not repaired by generating a new identity over existing ciphertext.

## Known blockers and limits

The two identified synchronization defects are corrected in this development
revision. Classified bad payloads and capacity-deferred text record progress and
an explicit rejection notice, without committing failed crypto/history/outbox
changes or generating a delivery receipt. The last 64 notices, total count and
earliest rejected sequence survive snapshot reload; the UI shows the count.
Existing messages/server ciphertext are not removed. No automatic replay/recovery
UI or later-decryption guarantee is provided for deferred events. Structural
transport/order/replay conflicts and local-state failures still fail closed.
Old v0 snapshots without these additive notice fields load with empty notice state,
not new keys; an older client may reject the newer snapshot on downgrade.

Outbound failures no longer skip the inbound phase. HTTP 409/507 entries retain
their exact bytes while other entries (including receipts) are attempted; failures
are reported, not deleted. Auth/network failures stop that outbound batch but do
not make receiving conditional on successful sending. Frozen local state or
cancellation stops the cycle; inbound failure prevents further work in that cycle.
Rust and real-loopback-HTTP JVM regressions exercise these paths. This is not
Android runtime/Keystore evidence or authorization for connected two-phone tests.

The development core caps local history at 200 messages and has no seed/root-device
recovery, QR scanner, iOS build or production account migration. No hosted TLS
instance has been deployed by these changes. The loopback server must not be
exposed through a proxy as a shortcut around missing adoption/runtime gates.
No sensitive messages, private keys or credentials belong in screenshots or logs.
