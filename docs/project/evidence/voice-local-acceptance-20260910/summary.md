# ParanoID TURN local acceptance — 2026-09-10T13:28:30+00:00

Gates: TURN-RT01, TURN-ACL02. Loopback-only (127.0.0.1:34781, relay 40000-40015).

| Case | Result |
|---|---|
| TURN-RT01-1 valid REST credential Allocate | PASS |
| TURN-RT01-2 expired-timestamp credential rejected | PASS |
| TURN-RT01-3 wrong-HMAC credential rejected | PASS |
| TURN-RT01-4 user-quota=4 enforced | PASS |
| TURN-ACL02-5 peer ACL: denied 10.0.0.1 (403), loopback relay echo works | PASS |
| TURN-RT01-6 lifetime<=60 and expired-credential Refresh rejected | PASS |

Overall: **PASS**

turnserver sha256: `b7f34eb1dd25f919b737e93cf672ad617fd27b6f57386bbb0f571cd64120f551`
harness sha256: `9e55d05e8dff207cc8d81c5cbbbd04b822128df1a258672fb30b0672f8374b97`
git HEAD: `ad966cb920761adcc8a293fc2c7df519a4c6430b`

NOT covered: public-network reachability, physical phones/real clients, systemd secret delivery, TLS, IPv6.
