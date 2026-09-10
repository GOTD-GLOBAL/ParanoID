# One-host client acceptance handoff — 2026-09-10

The [owner authority](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5613364943)
records the owner's Telegram confirmation through `goryanya-deploy[bot]`:
use the existing host and provide one coordinated installation, retaining TLS,
data, identity and neighboring services. Deployment is conditional on the
mandatory acceptance tests, fresh independent review and rollback readiness.
This is bounded operational authority; proposed ADR-0011/0012 remain proposed.
REQ-CALL-003/004/005/006 and accepted ADR-0001/0003 remain unchanged.

CALL-CONNECT01 remains **OPEN**. The [ordinary comparison](../call-connect-ordinary-20260910/README.md)
retains the baseline's natural SDK `connection` failure 16.496 seconds after
accepted Answer with 23.357 seconds remaining, and the fixed arm's successful
relay/relay DTLS Opus call and teardown. The [publication regression](../voice-relay-client-20260910/README.md)
also retains longer decoded-media evidence on the current engine. These records
do not establish the historical native first cause; current success cannot
retroactively identify it. No claim that future evidence can never clarify a
cause is needed for the distinct current-build acceptance scope.

The initial genuine Fable design review's [exact C disposition](initial-fable-call-disposition.txt)
permits a finite **CALL-CURRENT01** after the relay gates pass, against the
coordinated installer in an owned disposable environment. It is a conditional
test design disposition, not final artifact or deployment approval.

| Frozen case | Acceptance observation | Actual status |
| --- | --- | --- |
| Fresh synthetic install, first microphone grant, incoming call | At least 30 seconds connected with sustained decoded audio | NOT RUN |
| Retained microphone permission, incoming redial | At least 30 seconds connected with sustained decoded audio | NOT RUN |
| Outgoing call on the same candidate | Connected and decoded media, with clean teardown | NOT RUN |

The [test plan](../../../../clients/android/test/CALL-CONNECT01.md#current-build-acceptance-plan--2026-09-10)
requires original product deadlines, no synthetic cutoffs or consent resets,
all outcomes preserved, and a stop on any real unexplained failure. Connected
callbacks, host committed-answer/setRemote success, decoded-sample/energy growth
and clean teardown must be retained. Source/artifact/driver/observer provenance
must distinguish file hashes from loaded-code attestation. A PASS would apply
only to CALL-CURRENT01; CALL-CONNECT01 stays OPEN.

The source-time seam is deferred. If a real unexplained matrix failure occurs,
stop before further diagnostic runs and follow the review's seam conditions:
genuine RED/GREEN, fresh same-signer versionCode above 10 and verification that
the diagnostic sink is absent from the production APK. No such failure has been
observed in this unrun matrix, so no runtime instrumentation or new APK build is
justified here. The retained reviewed v10 APK SHA256 is
`a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`;
its existing [artifact record](../voice-relay-client-20260910/README.md) remains
the artifact evidence. Another identical short A/B is declined.

## Required reviewer capability remains unavailable

The [sanitized provenance](review-provenance.json) is derived from the retained
raw command, result and process records, with their SHA256 bindings:

- The initial design result reports `claude-fable-5` and Haiku in actual
  `modelUsage`, process exit 0, result subtype `success`, and `is_error: false`.
  Its C disposition is the conditional design evidence cited above.
- The later credential-design request also selected `claude-fable-5`, but actual
  `modelUsage` reports `claude-opus-5`, `claude-opus-4-8` and Haiku, with no Fable.
  A successful process/result does not make that response a Fable review.
- The single subsequent no-tool capability probe requested Fable and reported
  Opus 5 and Haiku, again with no Fable. No additional probe is implied or needed
  by this handoff.

The later response is supplemental only and cannot satisfy the required fresh
Fable approval. No additional client test or review ran for this documentation
handoff. Missing relay security/lifecycle acceptance, the current-call matrix and
final exact code/artifact review remain outstanding; the authority and initial
design review do not establish a tested deployment or authorize relay exposure.
