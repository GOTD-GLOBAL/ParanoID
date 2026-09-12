---
status: proposed
owner: protocol
decision_owner: martadvix-web
last_reviewed: 2026-09-11
---

# Call control v2 (audio + camera video)

Versioned successor of [voice-v1](voice-v1.md) for [RFC-0019](../rfcs/0019-video-calls.md)
and proposed [ADR-0013](../decisions/0013-video-calls.md). Everything in voice-v1
(authentication, delivery, freshness, consent, heartbeat, relay authorization,
resource limits, network boundary) remains in force unless this document says
otherwise. Only the deltas are listed.

## Version and compatibility

- `v` is the integer **2**. A v2 client rejects `v: 1` bodies; a v1 client (v15
  and earlier) rejects v2 bodies as unknown call bodies while its text path
  remains usable. **There is no mixed v1/v2 call.** Both phones of the private
  alpha update through the in-app channel; this is an owner-accepted alpha
  break, not a production compatibility claim.
- Exactly fifteen fields: the fourteen v1 fields plus `video`. Unknown,
  duplicate, missing or non-boolean `video` is rejected.

## New field and new kind

| Field / kind | Rule |
| --- | --- |
| `video` (boolean) | `knock`/`ready`/`offer`/`answer`: sender supports negotiating a camera section (always true for this client). `media`: sender's current local camera state. `heartbeat`/`end`: must be `false`. |
| `kind: "media"` | `seq >= 2`, both nonces, exact offer digest, empty SDP/ICE/reason. Informative camera-on/off announcement; accepted only in `connecting`/`connected`, monotonic per sender, refreshes the heartbeat deadline. Lower or equal sequence is ignored. |

`media` never grants, changes or revokes media authority. The receiving UI
shows what the peer *claims*; actual frames come only from the authenticated
DTLS-SRTP transport. A forged `media` cannot open a camera.

## SDP

- Limit rises to **12288** UTF-8 bytes (frame2 stays at most 16384 bytes;
  after Olm and base64 overhead the effective SDP ceiling through frame2 is
  roughly 9–10 KB, which is the real bound). At most 512 SDP lines.
- Complete SDP must contain exactly one `m=audio` section (unchanged rules)
  followed by exactly one `m=video` section, both `UDP/TLS/RTP/SAVPF`,
  `a=sendrecv`, bundled on the audio section's single fingerprint/ICE context.
  Each transport attribute (`fingerprint`, `ice-ufrag`, `ice-pwd`, `setup`) may
  appear once at session level or once in the audio section, and at most once
  more in the video section with the identical value (an answer cannot mix
  `setup:active` and `setup:passive` across sections). `a=rtcp-mux` is required
  in the audio section and allowed once in the video section. The video port
  may be `0` (bundle-only) or non-zero.
- Video payload types map only to `H264/90000`, `VP8/90000` and the helper
  formats `rtx`, `red`, `ulpfec`, `flexfec-03`; at least one of H.264 or VP8 is
  mandatory. Owner decision (Telegram, 2026-09-11): the client offers H.264
  (hardware, constrained baseline) first and VP8 as the mandatory fallback.
  VP9/AV1 and any other codec are rejected.
- Video direction is always `sendrecv` in signaling; **camera on/off is a
  track-enable flag plus a `media` control, never a renegotiation**. Trickle
  and renegotiation remain rejected.

## Consent and lifecycle deltas

- The camera never starts on knock, ready, ring or Answer. Only an explicit
  local "camera on" action (or an explicit "video call" start intent, after
  media authority is granted) may request `CAMERA` and start capture.
- Camera on routes audio to the speakerphone unless a wired or Bluetooth
  headset is the active route; camera off restores the previous route.
- The app leaving the foreground disables the camera (audio continues) and
  re-enables it on return if the user had it on. A permission dialog is not
  "leaving the foreground".
- While any video is shown (local or remote) the call window keeps the screen
  on and the proximity sensor does not blank it; audio-only calls keep the
  system screen timeout and the earpiece proximity behaviour (owner request,
  2026-09-12).
- A camera failure (no permission, no device, capture error, foreground-type
  promotion refused) stops capture, restores the audio route, downgrades the
  call to audio and sends `media: false`; it never ends the call.
- A `media` control is sent only after the sender's own offer/answer (seq 1);
  a camera toggled by the callee while answering is announced right after its
  answer. An explicit "video call" start intent applies only once the media
  engine for that call generation exists.
- Terminal paths additionally stop/dispose the capturer, surface helper,
  video tracks/sources, renderers and EGL context.
- The foreground service adds `camera` to its type only while the local camera
  is on; it is never started for video alone.

## Metadata

The server and relay additionally learn that a call carries a second RTP
stream and its bitrate profile. IP/timing exposure is unchanged. The
[threat delta](../security/video-v1-threats.md) owns the test plan.
