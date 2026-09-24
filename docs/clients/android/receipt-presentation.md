---
status: draft
owner: android
last_reviewed: 2026-09-18
---

# Android drawn delivery marks and one-time explanation

REQ-MSG-003 and REQ-CLIENT-004. This UI-only candidate brings Android in line
with the existing iOS ReceiptMark/ReceiptHint, without changing the core, wire,
receipts, sender/recipient trust, encrypted snapshot or message timestamps.

## Integration note — 2026-09-22

The version27 APK described below is the historical PR51 review artifact, not
an update to install. PR54's combined source preserves these receipt changes and
Devnet registration, currently with version28 build metadata. That combined source
is NOT the already handed-out v28 APK: no new artifact was built or published by
source integration. Any later delivery requires a fresh build, artifact checks
and an appropriate newer version code; never replace an issued version silently.

## Presentation

`ReceiptMark` paints a clock, one check or two checks using Canvas paths at a
fixed dp size, not font characters/baselines. Both outgoing bubbles and the
existing chat-list receipt position use it. The existing precedence of blocked
and verified-contact badges in the list is unchanged. The contact-details
prose legend (also referenced by iOS captions) is unchanged; this patch replaces
the two dynamic state renderers, not every check character in explanatory text.
All three marks use the same theme-provided color; there is no read-state color
or extra state. Fixed dp geometry deliberately does not grow with fontScale;
this matches the requested icon behavior, but low-vision usability without
TalkBack still requires device-level visual acceptance.

The unchanged accessibility labels are `В очереди`, `Сохранено сервером`,
`Доставлено`. Message time remains visible independently of the glyph. As on
iOS, delivery words are the mark's accessibility description, not a text glyph
printed beside the message. Actual TalkBack navigation/speech on a phone is not
claimed by checking the View's contentDescription property.

`MessagePresentation.receiptHintEarned` requires an own message with delivered
true anywhere in the current chat. Incoming messages, server acceptance alone,
an empty chat or missing own identity cannot earn it. Existing delivered
history can earn the explanation on the first launch of this candidate.

The card reads exactly the iOS sentence:

> Две отметки — сообщение доставлено на телефон собеседника. Прочитал ли он его,
> ParanoID не показывает.

`Понятно` dismisses it for the whole installation. `ReceiptHint` stores only
`dismissed=true` in app-private `paranoid-receipt-hint-v1` preferences, with no
account IDs, message text or timeline. Nothing is sent and no core snapshot is
rewritten. Android's backup-disabled manifest is unchanged. Dismissal is part
of the history repaint signature so the card disappears immediately without
waiting for an unrelated message. SharedPreferences.apply is asynchronous;
normal persisted restart is tested, not arbitrary power-loss durability.

## Actual checks

- JVM smoke: all three existing states/words, null/empty dialogs, own vs incoming
  delivery, older own delivered message and non-mutation of the input view.
  The new helper test failed before implementation and passed afterwards.
- UI source regression failed before wiring, then all 12 UI contracts passed.
- Full `clients/android/build.sh` passed with the retained signer, including real
  Android35 compilation, native/JNI tests, R8/D8/APK and update TLS fixtures.
- `test_receipt_android_runtime.py` built a separate UUID-named, no-network probe
  APK on the local emulator, using the production ReceiptMark, ReceiptHint and
  MessagePresentation sources. Real Canvas bitmaps have nonempty, distinct
  drawings for the three states at 160/320 dpi. Their pixels are unchanged
  under fontScale1/2. Accessibility labels match the existing words. Dismissal
  stays hidden after a persisted write and an actual process stop/restart.
  Both instrumentation phases passed and the synthetic package was uninstalled.
  No installed messenger package, retained user data or physical phone touched.
- Initial probe harness expected raw instrumentation status from non-raw output;
  the production checks already reported PASS. The runner was corrected to use
  `am instrument -r`, and both phases were rerun successfully.

The probe does not launch MainActivity or establish a real conversation. Main
screen wiring is source-checked and SDK-compiled; whole-chat visual acceptance,
TalkBack speech and physical-phone behavior remain NOT RUN.

## Local review artifact

The locally built APK retains `global.paranoid.messenger`, versionCode27 /
`0.0.27-timeout` and signer SHA256
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
Its SHA256 is
`b9a47eba2743cb70fa4415aebfa7a6ad627cb412f2b742d3cecb0002a7ef2cf6`.
Fresh compiled receipt classes are present in its DEX and the embedded native
library matches this worktree's build. This is **not** the already published
v27 artifact and was not published or installed as a messenger update. A later
release needs its own version increment, artifact verification and authority.

## Reproduce

```sh
python3 clients/android/dependencies.py
python3 clients/android/test_receipt_presentation.py
python3 clients/android/test_ui_contract.py
python3 clients/android/test_sdk_compile.py
# Requires existing SDK and signing environment; local emulator only.
python3 clients/android/test_receipt_android_runtime.py --serial emulator-5591
```

The host smoke gates both canonical APK builds and client-core CI. The emulator
probe is opt-in: it rejects physical-device serials, creates only its disposable
package and cleans it up. No release number change, feed publication, install
of the messenger, server operation or merge is authorized by these checks.
