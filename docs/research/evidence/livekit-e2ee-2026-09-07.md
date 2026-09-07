---
status: draft
owner: architecture
last_reviewed: 2026-09-07
---

# LiveKit encryption documentation: retrieved excerpts

Source: <https://docs.livekit.io/home/client/tracks/encryption/>

Retrieved 2026-09-07. This preserves two relevant excerpts from the mutable page,
not the entire page or a claim that its advice meets ParanoID requirements.
Full extracted-text snapshot SHA-256: `cad224621f7dca9a75e2334304e7d65e13242979d4119ba35aa56c1136b1ce5c`.

> It is your responsibility to securely generate, store, and distribute encryption keys to your application at runtime. LiveKit does not (and cannot) store or transport encryption keys for you.
>
> Signaling messages (control messages used to coordinate a WebRTC session) and API calls are not end-to-end encrypted — they're encrypted in transit using TLS, but the LiveKit server can still read them.
