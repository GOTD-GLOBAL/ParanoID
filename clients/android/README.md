# Android realtime private-alpha candidate

Package `org.paranoid.devtext`, versionCode **8**, `0.0.8-realtime`, ARM64, API26+.
The native messenger uses real chat lists/bubbles, a stable keyboard-aware
composer, genuine delivered indicators, own-ID QR/share and explicit contact
verification/blocking. Unknown senders remain visibly unverified and replyable.
No simulated calls, read receipts or message timestamps are shown.

Reused pinned TLS and five-minute signed sessions support bounded long polling.
Network waits use separate lanes; native state remains single-owner and durable
receive publication precedes receipt network work. Saved origin/SPKI, core3/
sealed4 state, identity, contacts, history and exact outbox bytes remain unchanged
from delivered v7. Actual populated-v7 upgrade passes without rewriting the state
on open. Unsupported pre-v7 state remains preserved and refused, with historical
failures recorded separately.

An optional user-visible background connection requires notification permission,
shows a stop control and uses generic content-free notifications. It has no
Google dependency or provider keys. Doze, force-stop, battery and physical OPPO
behavior are not certified by emulator tests. A second realm, invitations by
role, blockchain and voice are not implemented in this candidate.

- [Exact realtime contract](../../docs/protocol/realtime-v1.md)
- [First-contact E2EE contract](../../docs/protocol/first-contact-v1.md)
- [Actual tests, build/review/deployment gates and limits](../../docs/operations/overnight-realtime.md)
- [Core compatibility](../../docs/clients/core/self-service.md)
- [User-triggered updates](../../docs/clients/android/in-app-updates.md)

The new server accepts retained v7 requests. The new client rediscovers pinned
health and falls back to retained proof requests on old v2 servers. Neither
compatibility path changes E2EE or trusts a replacement pin.

## Build

```sh
export ANDROID_SDK_ROOT=/path/to/existing/android-sdk
export PARANOID_ANDROID_KEYSTORE=/absolute/path/to/retained/test.keystore
read -r -s -p 'Existing signing password: ' PARANOID_ANDROID_KS_PASSWORD
export PARANOID_ANDROID_KS_PASSWORD
bash clients/android/build.sh
unset PARANOID_ANDROID_KS_PASSWORD
```

Requires Rust Android ARM64 target, JDK, SDK platform/build-tools 35.0.0 and NDK
28.2.13676358. Build refuses to generate a signing key and verifies established
certificate SHA256
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
Output: `clients/android/out/paranoid-text.apk`; build output and secrets are not
committed. Never uninstall a data-bearing application to work around signing.

`text-state.enc`, SnapshotCodec and `paranoid-text-state-v0` Keystore alias remain
the storage boundary. Saved HTTPS origin/SPKI override defaults. Missing,
corrupt or incompatible storage freezes rather than creating a replacement ID.
No automatic reset or historical-state migration is authorized.

## Real local interoperability (no hosted action)

```sh
python3 clients/android/test_clean_self_service.py \
  --server-binary /home/codex/paranoid-self-service-evidence/server-build-zeu65f67/release/paranoid-server \
  --evidence-dir /path/to/new/private/fixture-evidence
```

The fixture runs actual Android Java/JNI against its own generated pinned TLS
certificate and private PostgreSQL cluster. Clean acceptance starts with zero
receiver contacts and requires real text/reply/receipts, encrypted persistence
and restart/deduplication. Historical tests remain separately present with their
actual exits. The stable evidence README records exact retained-bundle invocation
and complete test output; mocks cannot replace that integration evidence.

One device/account, finite budgets, reusable fallback initial-secrecy limitations,
transferable signatures, relay metadata, unverified Doze/force-stop delivery and absent account
recovery remain explicit. JVM/packaging checks are not Android Keystore/camera
or physical-phone acceptance. No commit, push, merge, upload or deployment occurs.
