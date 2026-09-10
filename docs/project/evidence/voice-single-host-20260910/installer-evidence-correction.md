# Rehearsal receipt evidence correction — 2026-09-10

The targeted fresh-boundary rehearsal actually executed successfully and cleaned
up its own messaging/private-PG fixture, but its acceptance status is
**INVALID_RECEIPT**. Its offline-tests PASS claim hashes a retained failed test
report. The runtime result must not be retrospectively promoted to valid
acceptance by replacing that report with a later passing run. No runtime replay
was performed by this audit or requested to repair this historical record.

## Concrete mismatch

`installer/fresh-boundary-green.txt`, SHA256
`c3e5813d54843ca34311b6eb756e290ab2aa431ea1efd0ece90795029ce0e982`,
ends `FAILED (errors=1)`:24 tests were attempted and the network test module could
not import `single_host_network`. The filename did not describe its result.
`installer/fresh-boundary-rehearsal.py` supplied that path to `accepted_fixture`,
which unconditionally wrote `result=PASS` beside the file's hash without reading
its outcome or binding tested source.

The retained transaction
`/var/tmp/paranoid-fixture-b25a73ac5bfc854a-coordinator/transactions/7162430f60e9a9a3ec0d3b6cb18b4979/journal.json`
records acceptance SHA256
`ce404420797decde3b30cc32dc1e3465f28afccd73d94c2186d239835d602c28`.
Reconstructing the exact canonical receipt from its plan/kit identities, the
unchanged initial design report, and the failed report above produces exactly
that digest. This is a proved receipt/report mismatch, not speculation based on
a suggestive filename.

The actual result remains preserved at
`installer/message-fresh-boundary-1/result.json`: execution `PASS`, health and
loaded authority observed `PASS`, issuer `DISABLED`, relay runtime `NOT RUN`.
After cleanup its owned unit was `not-found`/`inactive`, MainPID0/ControlPID0,
and PostgreSQL postmaster absent. Those observations belong to coordinator
`0c5564208cd724ea5c4dec8e284d11641faacb80a054ca224262101465e55dab`
and worker
`cb40c3fba427e64e791bf2a10dc84373aad5a635cc9c2db1abb3190426cb6b32`.
They do not repair the prerequisite acceptance receipt. The correct paired
description is **runtime execution PASS; acceptance INVALID_RECEIPT**.

## Bounded audit of all three successful rehearsal records

For each retained coordinator transaction, this audit independently reconstructed
its canonical plan and receipt without importing or executing the kit. Every
reconstructed plan digest and acceptance digest matched the journal. All12
retained kit member hashes matched the corresponding manifest. The records are
in `installer-evidence-correction.json`, SHA256
`3b34c75e981837d6a058ec85918f79dfd00f519c24775c82d381da7653ec092c`.
It includes exact receipt objects labelled reconstructed, source hashes, journal
hashes, reports and dispositions; no private configuration values or secrets.

| Rehearsal/transaction | Actual receipt's offline report | Retained report result | Disposition |
| --- | --- | --- | --- |
| Existing message5, `c921ff12d68999164a1f496c642b2b33` | `installer/pre-native-offline-3.txt` | 49 tests, OK | Receipt matches a retained passing report; exact offline-tested-source binding UNKNOWN. |
| Fresh1 initial, `9f6f21976d335785ad0a8830ff47eea0` | `installer/pre-fresh-offline.txt` | 49 tests, OK | Receipt matches a retained passing report; exact offline-tested-source binding UNKNOWN. |
| Fresh1 update, `1df84d55288457037bf84cb776c36a2c` | `installer/pre-fresh-offline.txt` | 49 tests, OK | Receipt matches the same retained passing report; exact offline-tested-source binding UNKNOWN, including the distinct fixture-only update component. |
| Targeted fresh-boundary1, `7162430f60e9a9a3ec0d3b6cb18b4979` | `installer/fresh-boundary-green.txt` | 24 tests, FAILED(errors=1) | INVALID_RECEIPT; no retrospective credit. |

The earlier two passing report SHA256 values are respectively
`71a7b1fae640f551d9349e8c4d35458687d25bbde3d8b15d0dbb53ef769e94d9`
and `bef30d512df433ac8fd73115754a67f4d578119f337eb722cfe72dceeb1296ee`.
The exact earlier receipt digests are:

- Message5: `1ed95645f3ef8e59fe5fb4ac8923afd84b90ccff7131f491c5b580e9bc251065`.
- Fresh1 initial: `dfb8c9b551189d62198d294b538f612a3cae3946187ce17cfc540a50ad941505`.
- Fresh1 update: `be29c35f555a6433673c6176ba62f19c6548a5fc5d971401b21fa4ac4e0ad33d`.

All four receipts bind the same initial design report SHA256
`4262a5dbc0206810001bc2cd332b7e4852415518a2a53b15d13c03c532dca30e`.
This statement establishes which bytes were cited; it does not independently
approve reviewer identity, expand that design's scope, or substitute for the
currently missing named Fable review.

The historical offline logs contain only unittest output. They do not record
the command, module selection, source hashes or test hashes, and no matching
contemporaneous source descriptor was found in the bounded retained evidence.
Therefore their passing summaries and exact receipt binding are verified, while
correspondence to the exact runtime kit source is **UNKNOWN**. The retained kit
hashes establish what was staged and reported by the rehearsal, not which source
bytes an earlier offline test invocation exercised. No retrospective source
attestation is invented from timestamps or later files.

Content-addressed0400 copies of the three cited logs and design report are
preserved under `installer-receipt-audit/`; original files and journals remain
unchanged. Later `final-offline-4.txt` reports56 passing tests, but it is a separate
later observation and is not the third rehearsal's prior gate. Root assigned the
installer a structured PASS/source-bound report reader and corrected full-suite
invocation so future fixture receipts cannot repeat this mismatch. Neither fix
changes the status of an earlier receipt.

No production deployment, relay exposure, actual TURN/network acceptance or
current-call gate is satisfied by any of these message-only records. This audit
performed no code changes, test runs, unit/listener operations or network calls.

Subsequent evidence: `installer/final-structured-offline-1/report.json`, SHA256
`756ead82450cb4daf6b35bc7294e55bb639151d098ebbec5bc8284f228f57fc0`,
records59 tests/PASS/exit0 with an explicit unittest-discovery command and source
hashes. This audit verified its log digest and all ten current source/test hashes.
The later structured record is preserved as a new observation; the three
historical rehearsal dispositions above remain unchanged. In particular,
fresh-boundary1 remains runtime execution PASS and acceptance INVALID_RECEIPT.
