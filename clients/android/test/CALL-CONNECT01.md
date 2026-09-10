# CALL-CONNECT01 — diagnostic observer (test only)

## Current-build acceptance plan — 2026-09-10

CALL-CONNECT01 remains **OPEN**: the retained evidence does not establish the
historical native first cause. The owner's [existing-host and one-touch authority](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5613364943)
is conditional on acceptance and fresh review. Initial genuine Fable design
review C permits a separate **CALL-CURRENT01**, currently **NOT RUN**, against
the coordinated installer in an owned disposable environment after the relay
gates pass. The [review and provenance record](../../../docs/project/evidence/voice-single-host-client-20260910/README.md)
preserves the distinction and the exact conditions.

Freeze these three cases before execution on the same candidate:

| Case | Required observation | Status |
| --- | --- | --- |
| Fresh synthetic install, first microphone grant, incoming call | At least 30 seconds connected with sustained decoded audio | NOT RUN |
| Retained microphone permission, incoming redial | At least 30 seconds connected with sustained decoded audio | NOT RUN |
| Outgoing call | Connected and decoded media, with clean teardown | NOT RUN |

Use the product deadlines without synthetic 15/20-second cutoffs or consent-clock
resets. Preserve every outcome and stop the matrix on any real unexplained
failure. Retain connected callbacks, host committed-answer/setRemote success,
decoded-sample/energy growth and clean teardown, with full source, artifact,
driver and observer provenance and explicit installed-identity limits. File
hashes do not attest loaded code. A successful matrix would establish only its
current-build scope; it cannot turn CALL-CONNECT01 into PASS.

The source-time seam is deferred unless such a failure makes it necessary. No
new runtime instrumentation or APK build is justified or performed here; retain
the reviewed v10 candidate. A later credential-design review requested Fable but
reported Opus 5/4.8 and Haiku, with no Fable in actual model usage; the one no-tool
capability probe likewise reported no Fable. Those responses cannot satisfy the
required fresh Fable review. The initial conditional design disposition remains
distinct from final code/artifact approval. Another identical short A/B is
declined; denied TURN tests have not been repeated.

## Bounded ordinary comparison — 2026-09-10

The later direct task authorized one ordinary baseline and one fixed incoming arm
after fresh Fable review. Both observer reviews returned APPROVE; actual Java
compilation and fixture builds passed. The [dated evidence](../../../docs/project/evidence/call-connect-ordinary-20260910/README.md)
records a natural baseline SDK `connection` error 16.496 seconds after accepted
Answer with 23.357 seconds of setup budget remaining, followed by `mediaState`
termination. The fixed arm published once, installed its answer at the host,
decoded relay/relay Opus and cleaned up after normal hangup. CALL-CONNECT01 stays
OPEN after final independent Fable evidence review; native pre-cleanup cause and complete loaded-process provenance remain
unknown. No further arm, production change or denied TURN test was run.

The original offline scope and proposed gates below are historical. The later
task superseded only the ordinary-run authorization gate; it did not authorize a
product diagnostic seam, deployment, merge or missing security tests.

## Historical offline scope and executed evidence

REQ-CALL-003/004/005/006 are preserved: no authority/consent, immutable controls,
deadlines, relay configuration, product flags or runtime source changes. No
media/network/DB/emulator/phone/systemd/deployment/APK build is part of this work.
ADR-0001/0003 apply; proposed voice ADRs are not newly accepted. CALL-CONNECT01
remains **OPEN**. VOICE-PUB01 closure is a different finding.

`call_connect_sampler.py` is an import-safe pure sampling step, not a runnable
external fixture. `test_call_connect_sampler.py` extracts only four AST statements
from the old driver's sampling loop; it never imports/executes its top-level
process setup, forwarding-helper pauses, installs or cleanup. The initial test
actually failed because an already obtained ended controller sample was lost.
The corrected step saves controller first, skips media after ended, preserves
bounded observer enums, performs at most one fresh controller read after a media
observer error, and never converts observer failure/censoring to product failure.
Anonymous fake values test diagnostic control flow only, not SDK/audio behavior.

Offline commands (from this directory):

```sh
SAMPLER_BASELINE=1 BASELINE_DRIVER=/absolute/path/run-incoming-sdk-comparison.py \
  python -m unittest -v test_call_connect_sampler.SamplerTests.test_ended_survives_observer_failure
python -m unittest -v test_call_connect_sampler test_call_connect_instrumentation
```

The first command is intentionally RED (exit 1), not an acceptance gate. Source
contract checks are explicitly lexical checks, not Android callback/race tests.
No Android compilation or instrumentation execution is claimed by these tests.

## Ready diagnostic integration

Use **one identical** sampler and `VoiceAppInstrumentation.java` source for both
engines. Do not reuse the old comparison scripts as executable drivers: they
contain operations outside the ordinary-call scope. Do not arm the existing
publication observer or use raw `view`, `media_stats`, owner holds, clipboard,
stale-stop or forwarding-helper commands for this diagnostic path.

After separate authorization and harness compilation/verification, the adapter is:

```python
sampler = Sampler(capacity=256)
def observation(command='view'):
    return bounded_existing_app_request('controller_view' if command == 'view' else command)
# Existing call controller's observed original deadline determines the run bound.
sampler.step(observation)
# At authorized run cutoff / failed observation transport:
sampler.censor()
```

The injected request must have a finite transport timeout. Do not extend the
call's product deadline. Persist the safe timeline, `result`,
`observation_incomplete`, `controller_error`, and `truncated_count`, not `vars()`
of arbitrary harness objects. The sampler does not claim connected/decoded media.
Once censored, subsequent step calls do nothing; there is no after-censor inference.

New test commands:

- `controller_view`: main-owner safe state/reason/generation/auth-online and
  remaining original budgets, independent of the native text worker/private view.
- `arm_terminal_observer`: once per instrumentation instance, before the one call
  (or before explicit Answer). Reflection wraps existing `CallController.Port`
  and the first SDK listener; exact original arguments/return values/exceptions
  are delegated. No timers, consent, product state or config fields are written.
- `terminal_events`: bounded 256-entry monotonic delivery buffer, safe event enums,
  truncation count and separately retained first **controller caller method**.
  `mediaClose` interception records before calling original disposal, after the
  controller has cleared its Call; last preterminal budgets carry their own sample
  time/generation and must NOT be portrayed as terminal-time measurements.
- `media_settings`: success schema unchanged; stopped owner/deadline/internal
  return `observation_error` with bounded enum, never raw exception text.
- Existing `finish`: stops observation attachment polling/recording. Transparent
  proxies remain until the test process ends; no restoration of product state is
  performed. Use a fresh test instance for another arm.

The attachment poll lasts at most 45 seconds **for observer attachment only**, not
for call authority; it ends on first terminal. An attached listener remains useful
after attachment polling ends. It observes only the first media instance. Event
ring truncation means incomplete causal coverage, even if terminal is retained.

## Exact coverage gap — do not declare a complete causal observer

The patch intentionally reports `partial_no_sdk_precleanup_hook`:

1. `WebRtcAudioEngine.fail` closes/cleans the SDK **before** main-thread onError.
   Wrapped onError retains its safe category before TextEngine collapses it, but
   cannot report source-time ICE/gathering state before cleanup. Initial creation
   failures can precede the 5 ms listener attachment. This gap must remain explicit.
2. `new Observer()` is passed directly into native PeerConnection creation. The
   object is not exposed as a replaceable stored listener; ICE connection callback
   is currently empty. Reflection cannot reliably intercept all native callbacks.
3. `CallController.finish` clears Call/increments generation before Port.mediaClose.
   The synchronous stack whitelist records e.g. `tick` or `mediaState`, not an
   inferred specific timer/SDK cause. Lambda callers can legitimately be `unknown`.
4. Online/auth is sampled, not a complete auth-event stream. Admission is visible
   as controller media_active/state transition, not an issuer-response trace.
   `user_answer_accepted` is controller acceptance, not original UI tap time.
   `signal_enqueue_requested` is NOT durable enqueue/server acceptance.
   `peer_answer_install_requested` is NOT successful remote SDK installation.
   Host-side committed-answer and setRemote success are not observed here.
5. Source timestamp is null; delivery timestamp is monotonic. No claims about
   queue delay, transport/request generation, first ICE failure or capture lifetime
   follow from missing source timestamps. ICE/gather states remain bounded sampled
   settings; they are not a retained native state-transition history.

**Proposed minimal instrumentability seam, NOT IMPLEMENTED:** a no-op-by-default,
reviewed diagnostic sink at (a) `CallController.finish` before clearing Call with
an explicit call-site origin enum and original budgets, (b) `WebRtcAudioEngine.fail`
before cleanup plus Observer state callbacks and SDP set/create success callbacks,
and (c) immutable commit/actual send acceptance and peer setRemote-success seams.
Only enums/numeric generations/times may be passed; never objects carrying SDP,
ICE addresses/secrets, credentials or payloads. This would change product source,
so stop for explicit scope approval and independent review rather than doing it
in this task. A test-only native listener replacement cannot guarantee this
coverage from the existing exposed fields. The currently prepared patch is useful
partial observability, **not ready to close the causal coverage gap**.

## Exact remaining ordinary-call experiment gate

First obtain review of this patch and decide whether the above minimal source
seam is authorized; otherwise accept that a run may still be inconclusive. Before
any run, separately approve the bounded ordinary incoming comparison and compile
and verify the same test observer against baseline and current SDK. A compiled
observer is not an installed/running-observer attestation.

For each arm independently retain product/fixture APK file hash, engine source
hash, observer source/compiled artifact hash and driver hash, plus separately
measured installed artifact/loaded-code provenance and process start association.
Mark installed identities **NOT_MEASURED** when inaccessible; a disk file hash
alone is never evidence of the executing binary. Keep the reviewed ARM64
`a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`
unchanged; test harness work does not authorize rebuilding/shipping that product.

Then only: one normal host caller -> one Android recipient, existing authenticated
handshake, explicit user Answer, one admitted configuration, no extra UI/mute/text
walkthrough. Observe original remaining setup budget through terminal/cleanup; do
not manufacture a 15/20-second failure cutoff. Bound successful-call observation
and normal user hangup separately. Record no-media-before-Answer and cleanup using
safe booleans/counts only. Do not restart/change TURN, pause helpers, manipulate
allocations, probe expiry/ACL/cache races, generate special packets, or perform
systemd operations. Natural failure absent => **NOT_REPRODUCED**, not forced RED.

A causal RED requires post-Answer terminal plus first cause and its preceding
chain. Conditional GREEN requires the engine publication delta alone, observed
committed/delivered/installed answer, matching prior condition, actual relay/relay
DTLS and decoded Opus plus cleanup. Offline fake samples and a connected label
prove none of those media conditions. CALL-CONNECT01 stays OPEN until the causal
chain and independent closure are captured. No merge/deploy authorization follows.

## Ordinary-call observer extension — 2026-09-10

The separately authorized ordinary comparison adds `safe_media_summary`. Its
main-owner precondition is an active, connected controller with current media.
The SDK owner checks closed state before requesting actual SDK statistics; the
result is associated again with the current connected call/generation. A teardown
race can invalidate that association and is observation loss, not product failure.
The driver must persist controller first and never request this command after
observing ended. In-memory references resolve the selected transport/candidate
pair to candidate **types** only. Output is bounded to eight inbound audio
summaries containing Opus/unknown, DTLS enum, selected local/remote candidate types
and available decoded-sample/audio-energy totals. Unknown or missing data is not
zero. No stats IDs, addresses, SDP, credentials or raw reports are emitted.
`safe_media_summary(raw)` adds a Python allowlist before persistence; neither
helper declares that media worked. Actual totals and their validity must be
assessed by the ordinary driver.

`controller_view` also projects media presence/closing and platform audio mode/
active-recording count without querying native text state. Optional cleanup
observation failure preserves the controller and remains explicit. The sampler
retains these fields together with `media_active` and `auth_online_observed`.

`setup_public_contact` is restricted to one successful read before observer arm,
idle generation zero, no media and zero dialogs. It returns only the fresh
synthetic public account/contact for pairing. The driver keeps this setup material
in memory; it is excluded from diagnostic evidence. Existing clipboard insertion,
if needed for normal UI pairing, is setup only and never a diagnostic command.

Connected/disconnected delivery callbacks remain incomplete: product code uses
bound listener method references and the listener field is final. Reflective
replacement cannot prove interception of each SDK callback on every runtime.
Sampled controller/ICE/aggregate peer state is separate evidence; missing observer
callbacks cannot establish that no transition occurred. The previously documented
`partial_no_sdk_precleanup_hook` gap remains unchanged.

Actual SDK35 `javac --release 8` compilation of all 28 product Java files plus this
instrumentation **PASS**, exit zero, on 2026-09-10. Product file hashes were unchanged.
This supersedes the earlier absence of a compile result, without changing the
historical lexical-only scope. Three added offline sanitizer/preservation cases
were RED before implementation; all 14 sampler/source-contract tests then passed.
Evidence: external ordinary-run `safe-stats-javac.json` and the committed
[compile log](../../../docs/project/evidence/call-connect-ordinary-20260910/safe-stats-javac.log),
[original three-case RED](../../../docs/project/evidence/call-connect-ordinary-20260910/safe-extension-red.log),
[integer cleanup-count RED](../../../docs/project/evidence/call-connect-ordinary-20260910/safe-extension-closing-red.log)
and [final 14-test GREEN](../../../docs/project/evidence/call-connect-ordinary-20260910/safe-extension-final-green.log).
These are compilation and offline observer results; actual media evidence is
recorded separately in the dated ordinary comparison above.
