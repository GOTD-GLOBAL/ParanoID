# PR53 merge-check followup — 2026-09-22

Independent Fable review of `cf97c6a` found no source security/correctness merge
blocker for the isolated Devnet candidate. Verdict remains REQUEST_CHANGES until
CI and permanent human owner-scope evidence are complete. The full AI report is
published as a PR comment, not represented as human approval. The owner was asked
to confirm scope directly on GitHub under the documentation policy's
closed-alpha review and durable approval rules. Human owner `martadvix-web`
(Sergey Maltsev) [confirmed the exact scope, deployment and conditional merge](https://github.com/GOTD-GLOBAL/ParanoID/pull/53#issuecomment-5771635821).
The authenticated GitHub API returned that author and exact approval text. The
permalink is recorded in RFC0026, requirements and deployment README. Issue52
remains open (`Refs`, no closing words); this is not phone/Mainnet release.

## Actual CI diagnosis and bounded correction

- `markdown`: Markdown lint passed (CLI2 version0.18.1). Lychee failed only on the
  two new Solana Explorer URLs, each returning429 from the browser frontend.
  One rerun reproduced both errors. This is not a missing on-chain object.
- `client-core-and-tls`: assertions passed up to downloading a public Maven jar;
  Maven returned403. One rerun passed without source or workflow changes.
- Historical legacy failure names were compared against main `02baeb2`: the exact
  same14 archived tests fail. That explicitly informational lane stays red.

`check-devnet-receipt.py` replaces HTML link probing for **only those two exact
Explorer URLs** with a mandatory read-only RPC gate before Lychee. It checks live
Devnet genesis, paired finalized Program/ProgramData ownership/flags/layout,
canonical pinned linkage/authority, exact reviewed SBF SHA256, and the recorded
successful finalized deployment signature/slot. No wallet, key, signing,
airdrop, submission, configuration mutation or Mainnet endpoint exists in it.
Redirects, oversize responses and RPC errors fail; there is no retry loop or
acceptance of429. All other Lychee links and existing private-source exceptions
remain unchanged. HTTP200 from a browser frontend would prove less than this gate.

Offline fixtures explicitly use synthetic account payloads and a patched test
hash; they are not chain evidence. RED was observed for absent finality, authority,
network, account checks, missing status lookup, forbidden submission, response
validation and CI wiring before each corresponding change. The full offline test
suite and separate real read-only Devnet check passed locally. CI must run these
same commands and still pass the general link checker before merge:

```sh
python3 scripts/test-devnet-receipt.py
python3 scripts/check-devnet-receipt.py
```

Devnet resets, upgrades, RPC outage or pruning can fail this live gate in future.
That is an explicit failure, not evidence the historical receipt was fabricated;
an operator must investigate and update the current-state evidence under review,
not silently learn new pins or turn the gate off. This change does not deliver the
Android prototype, close phone-test followups, or adopt a permanent architecture.
