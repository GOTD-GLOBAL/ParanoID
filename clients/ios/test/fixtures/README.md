# Test fixtures

This directory holds protocol vectors and nothing else. No certificate and no
key is committed here, and none ever will be: every certificate the iOS tests
need is generated while the test runs and deleted when it ends.

## Committed vectors

- [`voice-relay-vectors.json`](voice-relay-vectors.json) — the issuer documents
  of [voice TURN v1](../../../../docs/protocol/voice-turn-v1.md), transcribed
  from `clients/android/test/VoiceRelaySmoke.java`: six accepted documents, the
  49 the Android smoke refuses, and the nine `usable` probes that walk the
  admission window on both clocks. Each vector names the line of the Java smoke
  it comes from, and each rejection names the reason the parser must give, so
  `VoiceRelayConfigTests` compares reasons rather than counting refusals. Its
  `credential` is Base64 of twenty zero bytes — the canonical encoding of a
  20-byte HMAC and the same placeholder the Java smoke uses, never an issued
  credential.

- [`call-v2-sdp.json`](call-v2-sdp.json) — the two
  [call-v2](../../../../docs/protocol/call-v2.md) descriptions libwebrtc
  `150.7871.01` produced in the simulator spike
  (`clients/ios/App/ParanoIDTests/SdpCompatibilityTests.swift`, recorded in the
  git-ignored `clients/ios/out/evidence/sdp-spike.json`), line for line. The
  spike masks five kinds of per-run transport identifier out of its evidence —
  the session and connection addresses, the candidate foundations, addresses
  and ports, and the ICE credentials — and this file replaces each of them with
  the synthetic value its `substitutions` member names; nothing else is
  changed, so the section order, every `m=` line, every `a=rtpmap` and every
  codec are what libwebrtc wrote. `spike_survey` is what the spike measured on
  the unmasked text, which is how `test_android_compatibility.py` can see a
  transcription that lost a line. The DTLS fingerprints are the spike's own
  certificates — public values that authenticate nothing without the matching
  private key, which was never here.

A vector file may be committed because it is a description of the wire, not a
secret and not a thing that expires. A certificate is neither.

## Why no certificate is committed here

A committed certificate would be a committed key pair. `scripts/create-test-tls.py`
writes `server.key` next to `server.crt`, and even a throw-away private key in
git is a key in git (see the secrets rule in
[`clients/ios/README.md`](../../README.md)). A frozen certificate would also
expire: the script issues for 90 days, so a blob checked in today makes the
validity check of the pinned trust evaluator pass for three months and then fail
forever. Generating instead pins the tests to what OpenSSL 3 actually emits.

## How the tests get a certificate

`ParanoidKit/Tests/ParanoidKitTests/X509LeafTests.swift` creates a private
directory under the per-user temporary directory (mode `0700`, which is what the
script demands of its output parent), runs

```sh
python3 scripts/create-test-tls.py --ip 127.0.0.1 --output <tmp>/tls
```

and reads three things out of `<tmp>/tls`:

- `server.crt` — the PEM the test base64-decodes into the DER that
  `X509Leaf(der:)` walks.
- `public-connection.json` — `tls_spki_sha256`, OpenSSL's own SHA-256 over the
  DER of `subjectPublicKeyInfo`, which is the server pin the walker's SPKI must
  reproduce, and `server_url`.
- `server.key` — never read, never copied, removed with the directory in the
  test's teardown block.

The identity names `127.0.0.1` with `CA:FALSE` critical, `keyUsage` critical
`digitalSignature` and `extendedKeyUsage` `serverAuth`; those are the extensions
the leaf checks look at. `clients/ios/local_stand.py` calls the same script for
the local server stand, so the tests and the stand see the same shape of
certificate.

## Running the checks

The certificate fixture needs OpenSSL 3 (LibreSSL has no `-addext`) and
`python3` on `PATH`; `python3 clients/ios/test_toolchain.py` is what verifies
those pins. The relay vectors need neither.

```sh
swift test --package-path clients/ios/ParanoidKit --filter X509LeafTests
swift test --package-path clients/ios/ParanoidKit --filter VoiceRelayConfigTests
python3 clients/ios/test_android_compatibility.py --skip-stand
```

If a generated certificate ever has to be inspected by hand, run the script into
a directory under `clients/ios/out/` (git-ignored) and delete it afterwards —
never into this one.
