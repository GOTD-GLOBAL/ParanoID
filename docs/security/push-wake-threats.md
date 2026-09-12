# Push wake threat delta (RFC-0020, proposed)

Scope: `POST /v2/push`, `ss_push_tokens`, the FCM gateway in `server/src/push_fcm.rs`.

| Threat | Mitigation | Check |
|---|---|---|
| Message content or metadata leaves through Google | Payload is the constant `{"t":"wake"}`; no notification block; no sender/recipient/size | `push_fcm.rs` test asserts payload and absence of account/device/ciphertext strings |
| Forged registration binds a victim's account to an attacker token | Registration only over the signed session of the active device; one row per account keyed by the authenticated account | server test: unsigned → 401 |
| Sender spams wakes to drain a peer's battery | Per-account 10 s minimum interval, suppressed while the peer long-polls, 4096 tracked accounts | server test: second message within 10 s sends nothing |
| Service-account key on many servers | Key only on the gateway host as a systemd credential; environment carries the path; alpha host is the single gateway | deployment review; `PARANOID_PUSH_CREDENTIAL_FILE` |
| Local test endpoint override abused in production | Override accepted only for loopback/https and refused in `self-service-v2` public mode | `main.rs` startup check |
| Stale token keeps a device reachable after re-install | `UNREGISTERED` from FCM deletes the row; client sends empty token on identity reset | server test |
| Google-side correlation of wake timing | Accepted residual for devices with Google services; UnifiedPush follow-up for others | RFC-0020 |

Not changed: E2EE, session signing, message storage, TURN.
