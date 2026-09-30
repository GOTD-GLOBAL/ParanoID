# paranoid.global static files (RFC-0028) — NOT deployed

Templates for the contact-link domain. Nothing here is served yet; publishing requires
an explicit, separately authorized deployment.

| Path | Purpose |
|------|---------|
| `.well-known/assetlinks.json` | Android App Links verification for `https://paranoid.global/c/...` |
| `c/index.html` | Landing page shown when the app is not installed; serve it for every `/c/*` path |

## Signing certificate fingerprint

`assetlinks.json` carries the SHA-256 fingerprint of the APK **signing certificate**
(public data, not key material). The value was computed on 2026-09-30 with
`apksigner verify --print-certs` from the published v35 APK
(`paranoid-0.0.35-solana-id-arm64-a81c7d30ec05.apk`):

```
Signer #1 certificate DN: CN=ParanoID Text Disposable Test
Signer #1 certificate SHA-256 digest: 82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926
```

The certificate is the closed-alpha **disposable test** signing key. If the release key
changes, recompute the fingerprint from the new signed APK and replace it (or list both
during a transition). Never place private key material in this directory.

## Serving requirements (for the future deployment)

- `https://paranoid.global/.well-known/assetlinks.json` with `Content-Type: application/json`,
  HTTP 200, no redirect (Android verification rejects redirects).
- Every `https://paranoid.global/c/<server-id>/<nick>` answers with `c/index.html`.
- Replace `APK_DOWNLOAD_URL_PLACEHOLDER` with the published APK URL.
- The page is static: no analytics, cookies or scripts; the web server log still records
  the requested path (server id + nickname) and the client IP — see the threat model.
