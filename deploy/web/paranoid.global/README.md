# paranoid.global static files (RFC-0028)

Published 2026-09-30 to `/var/www/paranoid.global` on the paranoid.global web host with
the owner's explicit authorization (ParanoID Telegram thread, «Можно и файл привязки»).
No APK is published on the site: the closed-alpha build is not distributed publicly.

- `.well-known/assetlinks.json`: Android App Links verification for
  `https://paranoid.global/c/...`.
- `c/index.html`: landing page shown when the app is not installed; serve it for every
  `/c/*` path.

## Signing certificate fingerprint

`assetlinks.json` carries the SHA-256 fingerprint of the APK **signing certificate**
(public data, not key material). The value was computed on 2026-09-30 with
`apksigner verify --print-certs` from the published v35 APK
(`paranoid-0.0.35-solana-id-arm64-a81c7d30ec05.apk`):

```text
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
- The page is static: no analytics, cookies or scripts. `/c/` has `access_log off`, so
  the web server does not record which nickname was opened (error log still applies).

nginx (inside the existing `server_name paranoid.global` TLS block):

```nginx
location /c/ { access_log off; default_type text/html; try_files /c/index.html =404; }
location = /.well-known/assetlinks.json { default_type application/json; try_files $uri =404; }
```
