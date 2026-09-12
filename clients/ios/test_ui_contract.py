#!/usr/bin/env python3
"""UI contract of the iOS client: captions, the stand guard and the Info.plist.

Offline and source-only; it opens no simulator, builds nothing and reaches no
network. It is the iOS sibling of ``clients/android/test_ui_contract.py`` and
it answers four questions about the working tree:

* **Captions.** Every line of ``test/captions.txt`` is present, character for
  character, inside a Swift string literal, and a caption with an Android
  origin is present in that Android source too. A caption cannot drift from
  the phone a fingerprint is compared against, and a screen cannot quietly
  lose one. The three Android blocks this client has no counterpart for —
  «Получать в фоне», «Проверить обновления», «Доступна версия …» — must stay
  absent.
* **The stand guard.** ``DebugFixture`` understands exactly two launch
  arguments, both declared under ``#if DEBUG``; a Debug launch that names no
  stand and no ``-paranoid-allow-hosted`` shows ``NoStand``, creates no
  identity and opens no connection.
* **The two guards on a tap.** The composer is captured and cleared, and
  «Создать ID» is disabled, synchronously — before the first ``await`` — so a
  second tap in the same run loop turn does nothing.
* **The Info.plist.** Camera and microphone are declared with a reason,
  ``UIBackgroundModes`` is exactly ``[audio]``, and nothing claims a delivery
  path this client does not have: no ``voip`` mode, no push environment, no
  relaxed transport security.

Run: ``python3 clients/ios/test_ui_contract.py`` → ``OK``.
"""
import plistlib
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANDROID = HERE.parent / 'android/src/org/paranoid/text'
APP = HERE / 'App/ParanoID'
KIT = HERE / 'ParanoidKit/Sources/ParanoidKit'
CAPTIONS = HERE / 'test/captions.txt'

# The four sources the rules below are read out of, named once.
MODEL = 'App/ParanoID/AppModel.swift'
ENTRY = 'App/ParanoID/ParanoIDApp.swift'
FIXTURE = 'App/ParanoID/DebugFixture.swift'
SNAPSHOT = 'ParanoidKit/Sources/ParanoidKit/Service/Snapshot.swift'

# Where a caption may claim to come from. 'ios' is a screen Android does not
# have, or the foreground rule of this client.
ANDROID_ORIGINS = ('MainActivity.java', 'TextEngine.java', 'DialogPolicy.java',
                   'MessagePresentation.java', 'QrScanActivity.java')

# Android blocks this client does not have: builds arrive through TestFlight
# and the App Store, and there is no background delivery to offer.
ABSENT = ('Проверить обновления', 'Доступна версия ', 'Получать в фоне',
          'Включить фоновое подключение', 'Отключить фоновое подключение',
          'Входящие в фоне отключены')

# The operator-approval workflow and the bearer credential of the pre-v2
# protocol. None of these may reach a caption, a request field or a fixture
# account (`clients/android/test_ui_contract.py:41`).
FORBIDDEN_IN_CAPTIONS = ('operator', 'grant', 'alice', 'bob', 'Bearer ')
FORBIDDEN_IN_SOURCE = ('Запросить доступ у оператора', 'одобрени', 'importGrant',
                       'peerCode', 'descriptor.toString()', '"Bearer "')

# A Swift string literal on one line. Every check below reads these rather than
# the raw file, so a caption in a doc comment never stands in for a caption on
# a screen.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def swift_sources(*roots):
    """Every Swift file under `roots`, as {relative path: text}."""
    found = {}
    for root in roots:
        for path in sorted(root.rglob('*.swift')):
            found[str(path.relative_to(HERE))] = path.read_text()
    return found


def literals(sources):
    """Every Swift string literal in `sources`, exactly as it is written."""
    return [match.group(1) for text in sources.values()
            for match in LITERAL.finditer(text)]


def parse_captions(text):
    """`<origin> "<caption>"` lines; comments and blank lines are ignored."""
    parsed = []
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        origin, _, quoted = stripped.partition(' ')
        if not quoted.startswith('"') or not quoted.endswith('"') or len(quoted) < 2:
            raise ValueError(f'{CAPTIONS.name}:{number}: expected `<origin> "<caption>"`')
        parsed.append((origin, quoted[1:-1], number))
    return parsed


class UiContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A missing tree is a failure, never a vacuous pass.
        missing = [str(path) for path in (CAPTIONS, APP, KIT, ANDROID) if not path.exists()]
        if missing:
            raise AssertionError('missing: ' + ', '.join(missing))
        cls.sources = swift_sources(APP, KIT)
        cls.literals = literals(cls.sources)
        cls.captions = parse_captions(CAPTIONS.read_text())
        cls.java = {name: (ANDROID / name).read_text() for name in ANDROID_ORIGINS}

    # ------------------------------------------------------------------
    # `assertIn` against a whole source file prints the file on failure, which
    # buries the one line that matters. These two say what is missing instead.

    def present(self, needle, haystack, where):
        self.assertTrue(needle in haystack, f'{where}: missing {needle!r}')

    def absent(self, needle, haystack, where):
        self.assertFalse(needle in haystack, f'{where}: still carries {needle!r}')

    def shown(self, caption, where):
        """The caption is inside a Swift string literal somewhere."""
        self.assertTrue(any(caption in literal for literal in self.literals),
                        f'{where}: no Swift literal contains {caption!r}')

    # ------------------------------------------------------------------

    def test_every_caption_is_shown_by_a_screen_and_matches_its_android_origin(self):
        self.assertGreater(len(self.captions), 100, 'the caption contract is nearly empty')
        for origin, caption, number in self.captions:
            where = f'{CAPTIONS.name}:{number}'
            with self.subTest(caption=caption, line=number):
                self.assertIn(origin, ANDROID_ORIGINS + ('ios',),
                              f'{where}: unknown origin {origin!r}')
                self.shown(caption, where)
                if origin != 'ios':
                    self.present(caption, self.java[origin], f'{where}: differs from {origin}')

    def test_the_voice_privacy_sentence_is_androids_word_for_word(self):
        # `clients/android/test_ui_contract.py:57-58`. The screen that shows it
        # is built in the voice step; the caption is pinned here.
        for fragment in ('оператор ретранслятора видит ваш IP-адрес, время и объём трафика',
                         'собеседник может видеть ваш IP-адрес'):
            self.shown(fragment, 'the voice-privacy sentence')
            self.present(fragment, self.java['MainActivity.java'], 'MainActivity.java')

    def test_no_update_check_and_no_background_delivery_are_offered(self):
        # Literals only: prose may explain why a block is absent, but no screen
        # may show its caption.
        for caption in ABSENT:
            offered = [literal for literal in self.literals if caption in literal]
            self.assertEqual(offered, [], f'a screen offers {caption!r}')

    def test_no_operator_approval_grant_or_bearer_workflow(self):
        for literal in self.literals:
            for token in FORBIDDEN_IN_CAPTIONS:
                self.assertNotIn(token.lower(), literal.lower(),
                                 f'{token!r} in a string literal: {literal[:60]!r}')
        for name, text in self.sources.items():
            for token in FORBIDDEN_IN_SOURCE:
                self.absent(token, text, name)

    def test_a_debug_launch_with_no_stand_shows_nostand_and_creates_nothing(self):
        model = self.sources[MODEL]
        app = self.sources[ENTRY]
        screen = self.sources['App/ParanoID/Screens/NoStand.swift']
        # The stage exists, is reached from both refusals, and is drawn.
        self.present('case noStand(String?)', model, MODEL)
        self.present('try DebugFixture.trust()', model, MODEL)
        self.present('catch let problem as DebugFixtureProblem {\n'
                     '            stage = .noStand(problem.reason)', model, MODEL)
        self.present('catch SelfServiceError.trustUnavailable {\n            stage = .noStand(nil)',
                     model, MODEL)
        self.present('case .noStand(let reason):', app, ENTRY)
        self.present('NoStandScreen(reason: reason)', app, ENTRY)
        self.present('struct NoStandScreen: View', screen, 'Screens/NoStand.swift')
        self.present('Strings.NoStand.title', screen, 'Screens/NoStand.swift')
        # That stage touches nothing at all: the stand is decided from the
        # launch arguments, the compiled default and a plain `fileExists`,
        # before the install marker, before any Keychain item and before the
        # runtime that would open a connection.
        self.present('guard snapshotExists || fixture != nil '
                     '|| ServiceTrust.hostedDefault() != nil else {', model, MODEL)
        decision = model.index('stage = .noStand(nil)\n                return')
        for later in ('StorageGuard.start(', 'KeychainKey.standard.loadOrCreate(',
                      'SnapshotStore(directory: directory, key: key)',
                      'try SelfServiceClient(', 'Runtime(client: client, model: self)'):
            self.assertLess(decision, model.index(later),
                            f'{later!r} runs before the stand is known')
        self.assertLess(model.index('try DebugFixture.trust()'), decision,
                        'the stand is decided before the launch arguments are read')
        self.present('guard !isCreating, !isBroken, !view.hasIdentity, let runtime else { return }',
                     model, MODEL)
        self.present('guard let runtime, let account = chatAccount else { return }', model, MODEL)

    def test_debug_fixture_understands_exactly_two_launch_arguments(self):
        fixture = self.sources[FIXTURE]
        named = {literal for literal in literals({FIXTURE: fixture})
                 if literal.startswith('-paranoid')}
        self.assertEqual(named, {'-paranoid-realm', '-paranoid-pin'},
                         f'{FIXTURE} understands other launch arguments')
        # No other file of the application reads the command line for a stand.
        for name, text in self.sources.items():
            if name == FIXTURE:
                continue
            for literal in literals({name: text}):
                self.assertFalse(literal.startswith('-paranoid-realm')
                                 or literal.startswith('-paranoid-pin'),
                                 f'{name} names a launch argument of its own')
        # Both constants stand inside the `#if DEBUG` branch, and Release
        # answers `nil` without looking at the command line.
        debug = fixture[fixture.index('#if DEBUG'):fixture.index('#else')]
        release = fixture[fixture.index('#else'):fixture.index('#endif')]
        for argument in ('"-paranoid-realm"', '"-paranoid-pin"'):
            self.present(argument, debug, f'{FIXTURE} #if DEBUG')
            self.absent(argument, release, f'{FIXTURE} #else')
        self.present('static func trust(arguments: [String] = []) throws -> ServiceTrust? { nil }',
                     release, f'{FIXTURE} #else')
        # A fixture is validated exactly as a shipped build validates its own.
        self.present('try ServiceTrust(realm: realm, pin: pin)', debug, FIXTURE)
        # The hosted opt-in is the kit's, not a third argument of the app.
        self.present('"-paranoid-allow-hosted"', self.sources[SNAPSHOT], SNAPSHOT)

    def test_both_taps_are_guarded_before_the_first_await(self):
        model = self.sources[MODEL]
        send = model[model.index('    func send() {'):model.index('    /// A contact arrived')]
        # Capture, clear, and only then the actor call.
        self.assertLess(send.index('drafts.begin('), send.index('draft = ""'),
                        'the composer is cleared before the text is captured')
        self.assertLess(send.index('draft = ""'), send.index('Task {'),
                        'the composer is cleared after the first await')
        self.present('drafts.finished(ticket, committed: false)', send, 'AppModel.send()')
        create = model[model.index('    func createIdentity() {'):
                       model.index('    /// The composer changed')]
        self.assertLess(create.index('isCreating = true'), create.index('Task {'),
                        '«Создать ID» is disabled after the first await')
        self.assertLess(create.index('await runtime.owner.perform'),
                        create.index('isCreating = false'),
                        '«Создать ID» is re-enabled before the owner has answered')
        # The button and the composer read those two guards.
        self.present('.disabled(model.isCreating || model.isBroken || model.view.hasIdentity)',
                     self.sources['App/ParanoID/Screens/Welcome.swift'], 'Screens/Welcome.swift')
        self.present('.disabled(!model.canSend)',
                     self.sources['App/ParanoID/Screens/Chat.swift'], 'Screens/Chat.swift')
        # `canSend` asks the same policy, with the in-flight send as an input,
        # so the disabled button and the refused tap cannot disagree.
        self.present('sending: drafts.isSending', model, MODEL)

    def test_the_contact_refusal_is_modal_inside_the_sheet_it_happened_in(self):
        app = self.sources[ENTRY]
        model = self.sources[MODEL]
        # The scanner, the paste sheet and the confirmation each carry it; the
        # status line behind them does not.
        self.assertEqual(app.count('.modifier(ContactRefusal(model: model))'), 3,
                         'a sheet of the contact flow shows no refusal')
        self.present('Button(ContactFlowError.dismiss) { model.contactAlert = nil }', app, ENTRY)
        self.present('contactAlert = ContactFlowError.classify(error)', model, MODEL)
        # Cancelling touches no identity, no snapshot and no request.
        cancel = model[model.index('    func cancelContact() {'):
                       model.index('    /// «Заблокировать контакт»')]
        for forbidden in ('owner.perform', 'loop.wake', 'createIdentity'):
            self.absent(forbidden, cancel, 'AppModel.cancelContact()')

    def test_the_banner_hides_itself_and_is_addressable(self):
        model = self.sources[MODEL]
        banner = self.sources['App/ParanoID/Screens/NoticeBanner.swift']
        self.present('static let noticeDuration = Duration.seconds(3)', model, MODEL)
        self.present('try? await Task.sleep(for: AppModel.noticeDuration)', model, MODEL)
        self.present('.accessibilityIdentifier("notice")', banner, 'Screens/NoticeBanner.swift')

    def test_info_plist_declares_camera_and_microphone_and_no_delivery_path(self):
        raw = (APP / 'Info.plist').read_text()
        plist = plistlib.loads(raw.encode())
        for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
            self.assertTrue(plist.get(key, '').strip(), f'{key} must carry a reason')
        self.assertEqual(plist.get('UIBackgroundModes'), ['audio'],
                         'the only background mode is the one a live call needs')
        for key in ('voip', 'aps-environment', 'NSAllowsArbitraryLoads',
                    'NSAppTransportSecurity'):
            self.absent(key, raw, 'Info.plist')
        self.absent('aps-environment', (APP / 'ParanoID.entitlements').read_text(),
                    'ParanoID.entitlements')


if __name__ == '__main__':
    program = unittest.main(exit=False)
    sys.exit(0 if program.result.wasSuccessful() else 1)
