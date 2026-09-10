# ParanoID TURN local acceptance — 2026-09-10T14:50:24+00:00

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

turnserver sha256: `e13597df18552665aa445c86c2b2ec111b19ea62a56adc774b2d7a9271ea368c`
harness sha256: `5540ce7ca81648ce1088c48de97e0b47978f2b9b66ca5ee36e8e7c4585ad7faa`
git HEAD: `4974bdd78a64ddecb8eeced5c60b0da2a656e2d0`

NOT covered: public-network reachability, physical phones/real clients, systemd secret delivery, TLS, IPv6.
