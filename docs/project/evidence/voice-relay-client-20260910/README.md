# Voice relay client evidence — 2026-09-10

REQ-CALL-006 depends on the exact server foundation923e11b in draft PR21;
draft PR20 adds the client and the reviewed publication fix after811e084.
[The canonical contract](../../../protocol/voice-turn-v1.md)
and [server evidence](../voice-turn-20260910/README.md) remain separate.
These are actual local results, not deployment authorization or release readiness.

- [Parser](parser-validation.json):49 negative vectors and positive/time checks.
- [HTTPS/JNI RED→GREEN](voice-lane-tdd.json) and [source review](voice-lane-source-review.json):
  stale401 isolation, strict relay/direct response behavior, bounded replacements
  and text/state progress during held voice I/O. Ten scenarios pass.
- [V10 checkpoint APK](v10-checkpoint-apk.json), [independent artifact audit](v10-checkpoint-artifact-audit.json)
  and [44-input correspondence](rebase-artifact-correspondence.json): actual
  retained-signer ARM64 artifact, exact runtime sources and isolated app fixture.
- [Actual relay integration](app-relay-integration.json): selected relay/relay,
  decoded Opus, Android mute/unmute/routes, text during audio, background and cleanup.
  Host injects a known tone toward Android; reverse frames come from the actual
  emulator microphone and are not a physical acoustic-quality measurement.
- [Android outgoing](app-relay-outgoing.json) passes actual relay/relay audio but
  connects in43.05seconds, leaving little time within the45-second setup deadline.
  Earlier incoming failures around15seconds remain unexplained; later successes
  do not prove them fixed. [Corrected diagnosis](interop-source-diagnosis.json)
  preserves the distinction between static timeout possibilities and observation.
- [UI/peer source review](ui-peer-source-review.json) and actual screenshots:
  [before Answer](incoming-consent.png), [connected](relay-connected.png),
  [muted](relay-muted.png), [text during audio](text-during-relay.png).
- [Direct checkpoint final Fable report](direct-checkpoint-fable-review.txt) and
  [invocation](direct-checkpoint-fable-invocation.json) cover the earlier direct-ICE
  implementation only. [Fresh extension review](relay-final-fable-review.txt)
  and [verified invocation](relay-final-fable-invocation.json) found one functional
  publication blocker and approved the bounded relay-only correction conditionally.

The bounded relay SDP publication change is implemented after that review:

- [Current APK](current-apk.json) SHA256
  `a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`
  supersedes the f1bcb6 checkpoint. [Independent audit](current-artifact-audit.json)
  verifies all44 product inputs, retained signer/trust,1055 DEX classes without
  instrumentation, native/ZIP16 KiB alignment and notices.
- [Actual latency RED](publication-latency-red.json) and
  [full application GREEN](publication-regression.json) establish the reviewed
  correction: the recipient publishes while actual gathering continues, within
  a0.545-second conservative bound after a relay candidate. Both caller and
  recipient decode Opus over selected relay/relay pairs, preserve mute and two-way
  text, and release microphone/SDK resources on local/remote hangup.
- Actual later COMPLETE preserves publication count1 and fingerprint/ICE context.
  Cancelling a pending timer produces0 callbacks; redial produces1 in its new
  generation. [Timeline](publication-timeline.json),
  [bounded owned UDP transport fault](owned-udp-fault.json) and
  [driver](actual-regression-driver.py.txt) retain the exact scope. The paused
  guest forwarding helper was resumed; TCP relay/authentication remained real.
- [Direct regression](current-direct-media.json) uses the exact product engine
  with440/880 Hz bidirectional synthetic tone:367 decoded host frames, zero
  received forward frames during mute, tone recovery and teardown/redial pass.
  Its first fixture launch failure is retained in the sanitized record.
- [Independent source/readiness review](publication-source-review.json) and the
  [unchanged compiled oracle](readiness-oracle.java.txt) retain26 passing assertions
  after malformed-address RED/GREEN. The first [UI driver failure](publication-ui-driver-failure.json)
  occurred before any scenario checks and was corrected by case-insensitive UI
  matching. The two fast-COMPLETE GREEN runs alone do not prove the timer branch.
- [Preceding exact-head CI](preceding-heads-ci.json) passes all supported gates;
  the14 exact historical failures remain visible in the separate legacy job.

Fresh [Fable closure](publication-fable-closure.txt) succeeded in8 turns within its
bound; [actual invocation/model evidence](publication-fable-closure-invocation.json)
closes VOICE-PUB-01 on the exact corrected source/APK. CALL-CONNECT-01 remains open:
the earlier15-second incoming failures lack a demonstrated cause. The reviewer
also requested committing the reviewed delta and refreshing CI/artifact
correspondence (PUB-COMMIT-01); the build itself requires no change when those
product bytes match. The report's approximately17-second caller figure is elapsed
test-script time, including UI setup; it is not an instrumented call setup latency.
Retained-allocation expiry/race/drain and ACL packet gates remain NOT RUN after a
platform worker rejection; none was retried. Physical OPPO/AEC/Bluetooth/Doze/
handover/public network tests are NOT RUN. No live endpoint or phone was changed.

[Copy hashes](copy-sha256.json) bind allowlisted reports and synthetic screenshots.
Private snapshots, keys, full SDP, PCM, TURN credentials, private relay logs and
signing material are excluded. The APK stays in private evidence, outside Git.
