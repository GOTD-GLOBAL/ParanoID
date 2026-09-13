---
status: draft
owner: ios
decision_owner: martadvix-web
last_reviewed: 2026-09-13
---

# Export compliance inventory (iOS client, RFC-0021)

This document records what cryptography the iOS client contains, what the
`Info.plist` declaration means, and what is still undecided. It is an inventory
and a gate, not a legal classification: the classification and any filing belong
to the publishing entity and its specialist, and nothing here authorises an
upload.

## The declaration in the bundle

`clients/ios/App/ParanoID/Info.plist` sets
`ITSAppUsesNonExemptEncryption = YES`. This is the conservative candidate: the
key does not mean "the application uses encryption", it means the application
uses encryption that is **not exempt**, and answering YES normally also requires
an `ITSEncryptionExportComplianceCode` issued after Apple has reviewed the
documentation. That review has not happened, so the declaration is prepared, not
satisfied. Apple applies the same requirement to TestFlight distribution, not
only to a public release.

## What the application actually contains

| Component | Where | Purpose |
| --- | --- | --- |
| vodozemac (Olm/Megolm primitives, Curve25519, Ed25519, AES-256-CBC, HMAC-SHA-256) | `clients/core`, `key-protocol` through the bridge | end-to-end message and call-signalling encryption |
| SHA-256 (`sha2`) | `clients/core`, `key-protocol` | transcripts, digests, the leaf-SPKI pin |
| AES-256-GCM (CryptoKit) | `ParanoidKit/Storage/SnapshotCodec.swift` | the local state snapshot at rest |
| Keychain and Data Protection | `ParanoidKit/Storage` | the wrapping key and file protection classes |
| TLS 1.2+ with a pinned leaf SPKI (`Security.framework`) | `ParanoidKit/Tls` | transport to the self-service server |
| DTLS-SRTP inside WebRTC 150.7871.01 | `ParanoidKit/Binaries/WebRTC.xcframework` | call media |

The inventory is deliberately wider than "our own E2EE": transport, media and
storage all carry cryptography and all belong in a classification.

## What is not established

- **The publicly-available-source route is not available today.** The
  repository is private (`gh api repos/GOTD-GLOBAL/ParanoID` returns
  `private: true`, `license: null`), so its address cannot support a claim that
  the source is publicly available. Publishing the repository is a separate
  owner decision about the product, never a side effect of preparing a
  TestFlight build, and adding a `LICENSE` file alone would not change the
  visibility.
- **A licence is still needed for its own reasons** (the notices in this client
  name third-party terms while the project itself states none), but it should be
  chosen on its merits, not as a shortcut through an export procedure.
- **Whether any component counts as non-standard cryptography** is not settled
  here. Published, standard algorithms and a proprietary protocol built from
  them are treated differently, and the assessment covers the concrete
  algorithms and protocols, not the presence of end-to-end encryption as such.
- **Who exports and who files** is unrecorded. This document names no entity and
  assumes none.

## Gate before the first upload

Before any TestFlight upload, the owner records in the client pull request:

1. the applicable export regime for the product as it exists at that moment;
2. the classification path chosen, and whether a formal review is required;
3. the entity acting as publisher and exporter, and who files;
4. the resulting Apple compliance code or the reason none is needed.

Until those four lines exist, the upload step stays `NOT RUN`, and this document
says so rather than implying that a single `Info.plist` key settles the matter.
