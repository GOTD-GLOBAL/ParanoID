# Combined receipt and Devnet source verification

Fresh independent Claude Opus5 review of PR51 `57e326e` merged into PR54
`398a7bb`. Only CHANGELOG/current-state conflicted: disjoint-intent sections
from both sides retained, no design choice discarded. Four shared code/build
files auto-merged; all fifty-six unique changed files were byte-identical to
their contributing side, and every added line in the six shared files was
present from both histories before the final documentation note.

Actual combined checks: receipt JVM PASS; Devnet integration1 PASS; Android
UI12 PASS; CI wiring7 PASS; full Android35 SDK compile PASS; Markdown217/0.
No signed combined APK exists. The issued v28 remains a historical artifact,
not a byte-for-byte build of this combined source; a later release needs a new
version code and its own artifact checks. G1 and final CI remain merge gates.

## Integration Review — APPROVE (source-only; G1 still blocks the merge)

Scope: only the combined tree's shared-file merge and cross-wiring. Runtime already reviewed on each side; not re-reviewed.

### Shared files: both behaviors preserved

| File | PR51 side | PR54 side | Combined `head` |
|---|---|---|---|
| `.github/workflows/server.yml` | `test_receipt_presentation.py` added to the android step | `blockchain/**` path triggers + new `devnet-client` job | both present in `8e99d3c`; receipt line sits inside the existing job, devnet is an additive job — no step displaced |
| `clients/android/build.sh` | `test_receipt_presentation.py` after `test_message_presentation.py` | `test_devnet_integration.py` before `test_sdk_compile.py`, devnet cargo test/build, `notices.py`→`test_devnet_notices.py`, `android-devnet/src` added to `javac`, devnet `.so` into the APK zip | both present in `adb494d`, disjoint regions; receipt classes are picked up by the unchanged `src/org/paranoid/text/*.java` glob |
| `MainActivity.java` | `ReceiptMark` in chat-list `side` slot + bubble footer, `ReceiptHint.isPending` in the repaint signature, `receiptHintCard()` | identity-panel Devnet block + `openDevnet()` | disjoint — PR54 touches only the identity panel (~l.199) and a new method near `showAbout` (~l.302); nothing between `renderHistory`, `receiptHintCard` and `empty` moved |
| `test_ui_contract.py` | new receipt-hint contract (hint sentence + `"Понятно"`) | `versionCode 27→28` / `0.0.28-devnet` | both retained; count 12 matches PR51's 11+1 |

Documentation conflicts (`CHANGELOG.md`, `docs/project/current-state.md`) keep both sides' sections verbatim; nothing from either history was dropped.

### No incorrect wiring found

- No new architecture: `ReceiptMark`/`ReceiptHint` remain presentation-only; `MessagePresentation` stays Android-free, so the host JVM smoke still really executes. The Devnet button's `startActivity` path is unchanged by PR51.
- No phone/data/server mutation introduced by the merge: the only new persistence is the one app-private boolean; the emulator probe's `targetPackage` is still its own UUID package; `PARANOID_ANDROID_KEYSTORE` usage is unchanged.
- Repaint signature and the `blocked`/`Проверен` precedence chain are intact after PR54's edits.
- PR51's iOS doc edit ("Android still spells the marks as characters" → link) is not shared with PR54.

### Non-blocking (unchanged from the individual reviews, or cosmetic and merge-induced)

1. `CHANGELOG.md` / `current-state.md` are no longer reverse-chronological: the `2026-09-18` receipt entry now sits above the `2026-09-22`/`2026-09-21` Devnet entries. Cheap to reorder while the resolution is fresh.
2. `docs/clients/android/receipt-presentation.md` records its local artifact as versionCode 27 / `0.0.27-timeout`; the integrated manifest is 28 / `0.0.28-devnet`. Correct as a historical artifact record, but a one-line note would avoid reading it as the current build.
3. PR51's carried findings (no `onMeasure` on `ReceiptMark`, `installed=True` set after `adb install`, "authenticated" javadoc overclaim) are untouched by the merge and remain non-blocking.

### Gate status

APPROVE for the combined **source-only** integration. This says nothing about G1: PR54's durable owner approval is still OPEN and independently blocks merge, as does fresh CI on the integrated head. No deployment, release, publication or device action is authorized by this approval.
