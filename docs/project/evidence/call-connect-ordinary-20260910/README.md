# CALL-CONNECT01 ordinary incoming comparison — 2026-09-10

One baseline arm failed naturally; one fixed arm connected with actual decoded
relay/relay Opus and normal cleanup. **CALL-CONNECT01 remains OPEN.** This narrows
the observed terminal path, without establishing the underlying native cause or
retroactively identifying the historical failure. No further arm was run.

## Scope and provenance

The direct task in `call-connect-ordinary-task.md` authorized this bounded local
comparison, fresh Fable observer review, test-only changes and sanitized issue19 /
PR20 updates. It explicitly excluded the separately denied TURN security tests,
production changes, live/public network or phone actions, deploy and merge.
REQ-CALL-002–006, RFC-0017/0018 and proposed ADR-0011/0012 retain their existing
scope; accepted ADR-0001/0003 govern documentation and bounded independent review.
Human risk owner remains martadvix-web; no permanent ADR approval is inferred.

External evidence directory:
`/home/codex/paranoid-self-service-evidence/voice-calls-20260909T220516Z/call-connect-ordinary-20260910T021708664835Z`.
The [summary](ordinary-summary.json), [complete safe timeline](ordinary-comparison-result.json)
and [preservation record](preservation-cleanup.json) distinguish actual results
from missing measurements. Source base is `958791d3bcf2c7a3e81ee95547988fcd31735718`.

Fresh Fable [initial observer review](fable-observer-review.txt) and
[extended observer/host review](fable-extended-review.txt) both returned APPROVE.
Their provenance records include Fable and Haiku usage; these are independent AI
reviews, not human audits. The extended review did not inspect the subsequently
completed driver. Its exact runtime source is retained as
[driver evidence](run_ordinary_comparison.py.txt), with root inspection and actual
execution distinguished from independent review. The subsequent
[final Fable evidence review](fable-final-review.txt) approved publishing this
test-only change and independently kept CALL-CONNECT01 OPEN. Its two documentation
nits were resolved: manifest scope and committed RED/GREEN log names are explicit.

## Actual observations

All Answer-relative values below use the Android observer's monotonic delivery
clock. They are neither original UI tap timestamps nor microphone capture lifetime.

| Observation | Baseline | Fixed |
| --- | --- | --- |
| Before Answer | No media; zero active recordings | No media; zero active recordings |
| Original setup budget at accepted Answer | 39.854 s remaining | 42.440 s remaining |
| Early SDK condition | Relay candidate, GATHERING / CHECKING / CONNECTING, unpublished | Same early sampled condition, publication timer scheduled |
| Publication callback count | 0 | 1, at 0.762449 s after Answer |
| First SDK safe error | `connection`, at 16.496318 s after Answer | None observed |
| Budget at error delivery | Setup 23.357 s; silence 13.541 s; auth-online true | Not applicable |
| First controller terminal caller | `mediaState`, reason `failed` | `received`, reason `hangup` after normal host hangup |
| Host committed-answer IPC / setRemote success | 0 / 0 | 1 / 1 |
| Connected callback | Absent | 0.903942 s after Answer |
| Actual media | Zero host decoded frames; no answer installed | Opus, DTLS connected, relay/relay; Android 251040 sample frames, energy 0.087369; host 259 decoded frames / 248640 sample frames |
| Cleanup | Complete | Complete |

The host PCM energy was measured, approximately `5.11e-10` mean normalized frame
energy: near-silent emulator microphone input, not a synthetic reverse tone or an
acoustic-quality result. Android received the actual host tone. Both sides closed
media; Android returned to audio mode0 with zero recordings/media/closing count,
and the host had no media object or receiver tasks. No sampler or event truncation,
observer errors or observer censoring were reported during either arm.

For this baseline, `connection` delivery precedes `mediaState` termination by
approximately 0.182 ms. The source maps that safe category to the aggregate SDK
PeerConnection FAILED path. This is a source-supported interpretation of the
observed callback, not a captured native failure-time state transition. Last native
samples were still gathering/checking with two relay candidates and no publication.
The retained controller budgets rule out setup expiry as this observed terminal
path. A full auth/lifecycle stream and underlying native ICE failure cause remain
unmeasured. The host subsequently observed controller `ended/failed`, consistent
with receipt of Android's end; exact accepted remote-end metadata was not
separately observed. No host SDK failure preceded it in this observation.

## Comparison limits and preserved failures

The same relay, server, PostgreSQL and bridge processes and relay configuration
survived both arms unchanged. Fresh test APKs differ in exactly one product source,
the reviewed publication engine; the observer source and observer DEX are identical.
[Independent verification](independent-source-observer-verification.json) covers
59 product inputs. Its first overbroad comparison also found differing generated
Python cache paths; those files are absent from APKs and not product inputs.
The shared `product_source_manifest_sha256` identifies the worktree before fixture
realm/pin and baseline-engine substitution; per-arm copied inputs are attested by
the independent comparison, not by that shared manifest hash.

Installed product and observer APK bytes were read back and hashed before and
after each arm. PIDs were measured and equal within each arm. Android `run-as`
reads of process start ticks/maps exited unsuccessfully; those remain
**NOT_MEASURED**, with no alternate privileged read attempted. The raw
`same_process_association: false` means insufficient start-time evidence, not an
observed process replacement. File hashes alone are not loaded-code attestation.

The arms were sequential. Pre-Answer UI timing and permission state differed;
both had ample original budget. The early relay/gathering condition matched,
but its prolonged duration was not controlled. No fault profile, forwarding pause,
relay restart, deadline reset, packet capture or security probe was used.
Missing source-time SDK callbacks, final-listener attachment visibility, sampled
auth and host commit source time remain explicit. The host's initial controller
state was sanitized to `unknown` because its allowlist omitted `starting`; the
unretained raw value is not retrospectively reconstructed.

One setup-only correction was consumed before either arm: the new PostgreSQL
socket lacked the server's required private parent/subdirectory layout, causing
`self-service-init` exit1. Its processes stopped and data was preserved. A new
corrected fixture then ran both arms once. The old AVD/PG fixtures were untouched;
both newly created PG directories and the new AVD are retained. All owned runtime
children and the new emulator stopped after comparison. No successful rerun
replaces either the setup failure or the natural baseline failure.

## Changes, checks and next step

Only test instrumentation, sampler, host observer, tests and documentation changed.
The sampler retains controller data before media, keeps integer `media_closing`,
and separates observer errors/censoring. Safe SDK summaries expose enums and
numeric decoded-media metrics without SDP, addresses, media fingerprints, secrets
or PCM. Public contact setup stays private and in memory. No production protocol,
authorization, identity, storage or deployment boundary changed; no migration or
new threat-model decision follows from this observer extension.

Actual all28 product Java plus instrumentation compilation passed against the
existing SDK35. Both fixture APK builds/signature/alignment checks passed. Fourteen
offline observer tests passed after retained RED failures, including the real
integer cleanup-count regression. These offline tests are not media evidence.
The reviewed ARM64 APK and all production source hashes remain unchanged.

Exact next step: the parent's decision on any separately scoped diagnostic work,
using the completed independent Fable review and its OPEN disposition. This bounded
experiment is finished; no additional runtime arm or production fix is proposed
as part of it. Rollout is test-only; rollback is reverting the test/docs change.
TURN expiry/cache-race/drain, ACL packets, CLI and systemd acceptance gates remain
NOT RUN, as do physical-phone gates. Acceptance, deployment and merge stay blocked.
