# TLS test fixtures

This directory holds no fixture files, and it never will: every certificate the
iOS tests need is generated while the test runs and deleted when it ends.

## Why nothing is committed here

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

The fixture needs OpenSSL 3 (LibreSSL has no `-addext`) and `python3` on `PATH`;
`python3 clients/ios/test_toolchain.py` is what verifies those pins.

```sh
swift test --package-path clients/ios/ParanoidKit --filter X509LeafTests
```

If a generated certificate ever has to be inspected by hand, run the script into
a directory under `clients/ios/out/` (git-ignored) and delete it afterwards —
never into this one.
