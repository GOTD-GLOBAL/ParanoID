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
* **The local contact name.** A name typed on this phone stands wherever the
  contact does — the dialogs list, the contacts list, the chat title, the
  details sheet — no screen derives a title from the account any more, the
  rename sits where Android puts it, and the name reaches no core, no
  snapshot and no request (`ContactNames`, Android v22).
* **The call.** The privacy sentence stands *before* «Позвонить» and *before*
  «Ответить» and nowhere after them; the microphone is asked for only from an
  explicit Call or Answer, and a refusal says so and offers Настройки; the
  audio session is running before the first `knock` and the wait for a
  connection is the ten seconds Android waits, after which «Нет подключения
  для звонка…»; the camera is opened by «Включить камеру» and by an explicit
  video-call intent and by nothing else, and a refused camera downgrades the
  call to audio — it never ends it and it never changes a section's direction,
  because camera state travels as a `media` control (`call-v2.md`, Android
  v22). The proximity sensor is armed only once the call is `connected`, as on
  Android, so a ringing phone lying face down cannot hide «Ответить»; and
  because iOS has no `FLAG_SECURE`, the video stage covers itself while the
  screen is being recorded or mirrored.
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
NAMES = 'ParanoidKit/Sources/ParanoidKit/Presentation/ContactNames.swift'
DETAILS = 'App/ParanoID/Screens/ContactDetails.swift'
CHAT = 'App/ParanoID/Screens/Chat.swift'
CALL = 'App/ParanoID/Screens/CallScreen.swift'
COORDINATOR = 'App/ParanoID/Voice/CallCoordinator.swift'
AUDIO = 'App/ParanoID/Voice/AudioSessionController.swift'
ENGINE = 'App/ParanoID/Voice/WebRtcAudioEngine.swift'
EXTRACT = 'ParanoidKit/Sources/ParanoidKit/Voice/SdpExtract.swift'

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
        # Release answers `nil` from both channels without reading either.
        self.present('arguments: [String] = []', release, f'{FIXTURE} #else')
        self.present('environment: [String: String] = [:]', release, f'{FIXTURE} #else')
        self.present('throws -> ServiceTrust? { nil }', release, f'{FIXTURE} #else')
        # The environment is the second channel, and only DEBUG reads its names:
        # `devicectl` relays no launch argument to a build on a phone.
        for variable in ('"PARANOID_REALM"', '"PARANOID_PIN"'):
            self.present(variable, debug, f'{FIXTURE} #if DEBUG')
            self.absent(variable, release, f'{FIXTURE} #else')
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

    def test_the_local_contact_name_stands_wherever_the_contact_does(self):
        # The iOS half of `clients/android/test_ui_contract.py:98-109`: every
        # title site goes through the local table, «Переименовать» is where
        # Android puts it, and the name is stored outside everything that
        # leaves the phone. The behaviour — an empty value restores the
        # default, a stored name is local to this installation — is measured
        # by `ParanoidKitTests/ContactNamesTests`.
        names = self.sources[NAMES]
        model = self.sources[MODEL]
        details = self.sources[DETAILS]
        app = self.sources[ENTRY]
        application = {name: text for name, text in self.sources.items()
                       if not name.startswith('ParanoidKit/')}

        # 1. No screen names a contact by its account any more. The five sites
        #    are the dialogs list, the contacts list, the chat title, the
        #    details sheet and the call screen (`MainActivity.java:521` names a
        #    call the same way), and each of them asks the model.
        for name, text in application.items():
            self.absent('MessagePresentation.title(', text, name)
        self.assertEqual(sum(text.count('model.title(for: ') for text in application.values()), 5,
                         'the title sites are dialogs, contacts, chat, details and the call')
        self.present('func title(for account: String) -> String {\n'
                     '        contactNames.title(for: account)', model, MODEL)
        self.present('private(set) var contactNames = ContactNames()', model, MODEL)

        # 2. The way in is Android's positive button, above «Проверить QR»,
        #    and it opens the field with the current name in it.
        self.present('Text(Strings.Details.rename)', details, DETAILS)
        self.assertLess(details.index('details-rename'), details.index('details-verify'),
                        '«Переименовать» stands after «Проверить QR»')
        self.present('.alert(Strings.Rename.title, isPresented: $renaming)', details, DETAILS)
        self.present('TextField(Strings.Rename.title, text: $draftName)', details, DETAILS)
        self.present('Button(Strings.Rename.save) { onRename(draftName) }', details, DETAILS)
        self.present('Text(Strings.Rename.body)', details, DETAILS)
        self.present('onRename: { model.rename(account: account, to: $0) }', app, ENTRY)

        # 3. An empty value clears the name rather than storing a blank one.
        self.present('if clean.isEmpty {\n            names.removeValue(forKey: account)',
                     names, NAMES)

        # 4. It is local: app-private defaults under one versioned key, and
        #    nothing of the state, the core or the network is reachable from
        #    the type or from the action.
        self.present('"paranoid.contact-names.v1"', names, NAMES)
        for token in ('SnapshotStore', 'SnapshotCodec', 'Keychain', 'CoreBridge',
                      'SelfServiceClient', 'StateOwner', 'URLSession', 'RealtimeTransport'):
            self.absent(token, names, NAMES)
        rename = model[model.index('    func rename(account: String, to name: String) {'):
                       model.index('    /// «Копировать контакт»')]
        for forbidden in ('owner.perform', 'loop.wake', 'runtime', 'lastStatus'):
            self.absent(forbidden, rename, 'AppModel.rename(account:to:)')

    # ------------------------------------------------------------------
    # The call (`MainActivity.java:361-441,443-545`, `docs/protocol/call-v2.md`)

    def before(self, first, second, text, where):
        """`first` stands before `second` in `text`; both must be there."""
        self.present(first, text, where)
        self.present(second, text, where)
        self.assertLess(text.index(first), text.index(second),
                        f'{where}: {first!r} does not stand before {second!r}')

    def test_the_privacy_sentence_stands_before_the_call_and_before_the_answer(self):
        # `clients/android/test_ui_contract.py:57-58` and the mock-up's
        # `call-in`: the sentence is the last thing read before a microphone is
        # opened, so it is above the button in both places and below neither.
        model = self.sources[MODEL]
        app = self.sources[ENTRY]
        screen = self.sources[CALL]

        # 1. The confirmation: its message is the privacy sentence and its
        #    positive button is «Позвонить» / «Видеозвонок».
        self.present('var privacy: String { video ? Strings.videoPrivacy : Strings.voicePrivacy }',
                     model, MODEL)
        self.present('var title: String { video ? Strings.Call.videoPrompt '
                     ': Strings.Call.audioPrompt }', model, MODEL)
        self.present('var confirm: String { video ? Strings.Call.videoConfirm '
                     ': Strings.Call.audioConfirm }', model, MODEL)
        self.before('message: Text(prompt.privacy)',
                    'primaryButton: .default(Text(prompt.confirm))', app, ENTRY)
        # Neither call button does anything but open it.
        self.present('callPrompt = CallPrompt(account: account, video: video)', model, MODEL)
        for text in (self.sources[CHAT], screen):
            self.absent('requestRecordPermission', text, 'a screen asks for the microphone')

        # 2. The ringing screen: the sentence, the foreground rule, «Ответить»,
        #    in that order and only while the call is ringing.
        self.before('Text(Strings.voicePrivacy)', 'Text(Strings.callForegroundHint)',
                    screen, CALL)
        self.before('Text(Strings.callForegroundHint)', 'Text(Strings.Call.answer)',
                    screen, CALL)
        self.present('private var isRinging: Bool { state == .incoming }', screen, CALL)
        self.present('if isRinging { ringing }', screen, CALL)
        # The sentence and the button exist in that block and nowhere else, so
        # a connected call cannot show either of them.
        self.assertEqual(screen.count('Strings.voicePrivacy'), 1,
                         f'{CALL}: the privacy sentence is shown twice')
        self.assertEqual(screen.count('Strings.Call.answer'), 1,
                         f'{CALL}: «Ответить» is shown twice')

    def test_the_microphone_is_asked_for_by_the_two_intents_and_by_nothing_else(self):
        model = self.sources[MODEL]
        # `MainActivity.requestMicrophone` is reached from «Позвонить» and from
        # «Ответить», and both of those go through one place here.
        self.assertEqual(model.count('AppModel.requestMicrophone()'), 1,
                         'the microphone is asked for in more than one place')
        self.assertEqual(model.count('beginCallIntent('), 3,
                         'an intent is started somewhere other than «Позвонить» and «Ответить»')
        # The confirmation carries its own prompt: `.alert(item:)` clears the
        # binding before the button's action runs, so a `confirmCall()` that
        # read `callPrompt` back would place no call at all.
        self.present('func confirmCall(_ prompt: CallPrompt) {', model, MODEL)
        self.present('model.confirmCall(prompt)', self.sources[ENTRY], ENTRY)
        self.present('func answerCall() {', model, MODEL)
        # Ringing never asks: the incoming path reaches `beginCallIntent` only
        # from «Ответить», with the call already in `incoming`.
        answer = model[model.index('    func answerCall() {'):model.index('    /// «Отклонить»')]
        self.present('guard let call, call.state == .incoming else { return }', answer,
                     'AppModel.answerCall()')
        # Nothing in the client requests the microphone outside the model.
        for name, text in self.sources.items():
            if name == MODEL:
                continue
            self.absent('requestRecordPermission', text, name)

    def test_a_refused_microphone_tells_the_user_the_peer_and_nobody_else(self):
        model = self.sources[MODEL]
        app = self.sources[ENTRY]
        intent = model[model.index('    private func beginCallIntent('):
                       model.index('    /// Drops the pending intent')]
        # The refusal: the peer is told (so a refused Answer stops ringing on
        # the other phone), the audio session is given back, the alert is
        # shown. Nothing is sent for an outgoing intent — there is no call yet.
        # The refusal carries the identifier of the call it was raised for: a
        # permission dialog can outlive its ring (the first expires at 45 s and
        # the peer rings again), and a refusal that reached the newer call
        # would reject a ring the user has not seen. Android re-checks it the
        # same way (`MainActivity.java:600`).
        self.present('if answer, call?.callId == callId { await calls?.answer(microphone: false) }',
                     intent, 'AppModel.beginCallIntent')
        self.before('await calls?.answer(microphone: false)', 'microphoneRefused = true',
                    intent, 'AppModel.beginCallIntent')
        self.present('if(permissionAnswer&&engine.calls().snapshot().optString("call_id")'
                     '.equals(permissionCall))engine.calls().answer(false);',
                     self.java['MainActivity.java'], 'MainActivity.java')
        self.present('calls?.releaseAudio()', intent, 'AppModel.beginCallIntent')
        # The alert is Android's sentence, and Настройки is the only page this
        # client ever opens. It is attached twice — the root and the call
        # screen — with a gate that makes one of them the presenter, because an
        # alert under a full-screen cover never reaches the screen and a
        # refused Answer happens with that cover up.
        self.present('content.alert(Strings.Notice.microphoneDenied,', app, ENTRY)
        self.present('get: { model.microphoneRefused && model.showsCall == overCall }',
                     app, ENTRY)
        self.present('Button(Strings.openSettings) { model.openSettings() }', app, ENTRY)
        self.present('.modifier(MicrophoneRefusal(model: model, overCall: false))', app, ENTRY)
        self.present('.modifier(MicrophoneRefusal(model: model, overCall: true))',
                     self.sources[CALL], CALL)
        self.present('URL(string: UIApplication.openSettingsURLString)', model, MODEL)

    def test_the_audio_session_runs_before_the_first_knock_and_stops_with_the_call(self):
        model = self.sources[MODEL]
        audio = self.sources[AUDIO]
        coordinator = self.sources[COORDINATOR]
        intent = model[model.index('    private func beginCallIntent('):
                       model.index('    /// Drops the pending intent')]
        # The order of the intent: microphone, camera, **session**, the wait,
        # and only then the first control.
        self.before('await AppModel.requestMicrophone()', 'calls?.prepareAudio()',
                    intent, 'AppModel.beginCallIntent')
        self.before('calls?.prepareAudio()', 'await waitForCallConnection()',
                    intent, 'AppModel.beginCallIntent')
        for control in ('await calls?.answer(microphone: true)', 'await calls?.start(account:'):
            self.assertLess(intent.index('calls?.prepareAudio()'), intent.index(control),
                            f'{control!r} runs before the audio session')
        # An incoming ring gets its session when it is shown.
        self.present('if presentation.state == .incoming, previous != .incoming { audio.begin() }',
                     coordinator, COORDINATOR)
        # A live call keeps the lanes it is signalled over: every published
        # call state reaches the foreground policy, including `ended`, which
        # opens its teardown window (`LifecyclePolicy`).
        self.present('runner.post(.callChanged(CallActivity(rawValue: '
                     'presentation.state.rawValue) ?? .idle))', coordinator, COORDINATOR)
        self.present('let coordinator = CallCoordinator(owner: owner, loop: lanes, runner: queue,',
                     model, MODEL)
        # libwebrtc is in manual audio and silent until the call is connected.
        self.present('session.useManualAudio = true', audio, AUDIO)
        self.present('session.isAudioEnabled = false', audio, AUDIO)
        self.present('RTCAudioSession.sharedInstance().isAudioEnabled = true', audio, AUDIO)
        enable = audio[audio.index('    func enableAudio() {'):audio.index('    /// «Громкая связь»')]
        self.present('guard held, !audible else { return }', enable,
                     'AudioSessionController.enableAudio()')
        # `connected` is the only thing that arms the proximity sensor, so the
        # route is re-applied from here too.
        self.present('applyRoute()', enable, 'AudioSessionController.enableAudio()')
        self.present('case .connected:\n            // Only here does libwebrtc get the audio unit',
                     coordinator, COORDINATOR)
        # The category is the one a call needs, and the silent loop holds the
        # `audio` background mode until media flows.
        self.present('static let category = AVAudioSession.Category.playAndRecord', audio, AUDIO)
        self.present('static let mode = AVAudioSession.Mode.voiceChat', audio, AUDIO)
        self.present('static let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]',
                     audio, AUDIO)
        self.present('player.numberOfLoops = -1', audio, AUDIO)
        self.present('player.volume = 0', audio, AUDIO)
        # No ringtone: Android rings from a notification this client has not
        # got, so there is no tone player anywhere here.
        for name, text in self.sources.items():
            for token in ('AVAudioPlayer(contentsOf:', 'RingtoneManager', 'CallTones',
                          'AudioServicesPlaySystemSound'):
                self.absent(token, text, name)
        # An interruption or a media-services reset ends the call; a route
        # change does not.
        self.present('controller.mediaState(generation, .failed)', coordinator, COORDINATOR)
        self.present('queue.async { self.applyRoute() }', audio, AUDIO)
        # An interruption that **ends** gives the session back. A ringing call
        # has no media to lose, so nothing ends it on `began`; without this,
        # «Ответить» after a cellular call would hand libwebrtc the audio unit
        # of a session the system had already deactivated.
        self.present('case .ended: resume()', audio, AUDIO)
        resume = audio[audio.index('    private func resume() {'):
                       audio.index('    /// Releases the session')]
        self.present('guard held else { return }', resume, 'AudioSessionController.resume()')
        self.present('try session.setActive(true)', resume, 'AudioSessionController.resume()')
        self.present('if !audible { resumeKeepAlive() }', resume,
                     'AudioSessionController.resume()')
        self.present('try? session.overrideOutputAudioPort(wantsSpeaker ? .speaker : .none)',
                     audio, AUDIO)
        self.present('UIDevice.current.isProximityMonitoringEnabled = proximity', audio, AUDIO)
        # The proximity sensor is local-only and **connected-only**, as on
        # Android (`WebRtcAudioEngine.java:401`,
        # `!speaker && connected && !videoEnabled`): a ringing call must never
        # blank the screen, or a phone lying face down would hide «Ответить»
        # from the person it is ringing for. (The one deliberate difference —
        # this client keeps the sensor through a reconnection, Android releases
        # it — is written down in `AudioSessionController.audible` and in the
        # README.) The screen, on the other hand, is awake for
        # **either** camera: the stage is drawn for either one, and a one-way
        # video call must not dim halfway through (`call-v2.md`, owner request
        # 2026-09-12; `MainActivity.java:533-537`).
        self.present('let proximity = held && audible && !video && !speaker && !isHeadsetRoute',
                     audio, AUDIO)
        self.present('boolean earpiece = !speaker && connected && !videoEnabled;',
                     (ANDROID / 'WebRtcAudioEngine.java').read_text(), 'WebRtcAudioEngine.java')
        self.present('let awake = held && (video || remoteVideo)', audio, AUDIO)
        self.present('UIApplication.shared.isIdleTimerDisabled = awake', audio, AUDIO)
        self.present('audio.setRemoteVideo(presentation.remoteVideo)', coordinator, COORDINATOR)
        self.present('boolean showStage=live&&(localVideo||remoteVideo);',
                     self.java['MainActivity.java'], 'MainActivity.java')
        # Cleanup hands the route back before it hands the session back.
        end = audio[audio.index('    func end() {'):audio.index('    /// Whether a wired')]
        self.before('try? session.overrideOutputAudioPort(.none)', 'try? session.setActive(false)',
                    end, 'AudioSessionController.end()')

    def test_ten_seconds_of_waiting_and_then_the_connection_sentence(self):
        model = self.sources[MODEL]
        self.present('static let callIntentWindow = Duration.seconds(10)', model, MODEL)
        self.present('static let callIntentPoll = Duration.milliseconds(100)', model, MODEL)
        wait = model[model.index('    private func waitForCallConnection('):
                     model.index('    /// The call view changed')]
        self.present('while !isConnected {', wait, 'AppModel.waitForCallConnection()')
        self.present('ContinuousClock.now < deadline', wait, 'AppModel.waitForCallConnection()')
        intent = model[model.index('    private func beginCallIntent('):
                       model.index('    /// Drops the pending intent')]
        self.present('showNotice(Strings.Notice.callOffline)', intent, 'AppModel.beginCallIntent')
        # A missed window gives the session back and sends nothing.
        offline = intent[intent.index('guard await waitForCallConnection() else {'):]
        self.before('calls?.releaseAudio()', 'showNotice(Strings.Notice.callOffline)',
                    offline, 'AppModel.beginCallIntent')

    def test_a_cancelled_intent_never_takes_the_session_of_the_one_after_it(self):
        # Cancelling a task does not stop it at the next line: an abandoned
        # intent runs on to its cleanup, and the audio session it gives back is
        # process-wide. Every release inside the intent therefore carries the
        # generation token Android re-checks at each deferred step
        # (`MainActivity.java:392-395,427,435`), or a second «Позвонить» would
        # deactivate the session the new intent is waiting on and the call that
        # follows would be silent for its whole life.
        model = self.sources[MODEL]
        intent = model[model.index('    private func beginCallIntent('):
                       model.index('    /// Drops the pending intent')]
        self.present('let generation = callIntentGeneration', intent, 'AppModel.beginCallIntent')
        guarded = intent.count('if ownsCallAudio(generation) { await calls?.releaseAudio() }')
        self.assertEqual(intent.count('calls?.releaseAudio()'), guarded,
                         'AppModel.beginCallIntent: a release that is not the owner\'s')
        self.assertGreaterEqual(guarded, 4,
                                'AppModel.beginCallIntent: an exit that gives nothing back')
        rest = model[model.index('    private func cancelCallIntent('):]
        self.present('callIntentGeneration &+= 1', rest, 'AppModel.cancelCallIntent()')
        owns = rest[rest.index('    private func ownsCallAudio('):]
        self.present('callIntent == nil || generation == callIntentGeneration',
                     owns, 'AppModel.ownsCallAudio()')

    def test_the_camera_is_opened_by_an_explicit_action_and_by_nothing_else(self):
        model = self.sources[MODEL]
        engine = self.sources[ENGINE]
        # `AVCaptureDevice.requestAccess` for video exists in exactly one place
        # in the call path, and that place is reached from «Включить камеру»
        # and from an explicit video-call intent only (`call-v2.md:62-64`).
        self.assertEqual(model.count('AVCaptureDevice.requestAccess(for: .video)'), 1,
                         'the camera is asked for in more than one place')
        self.assertEqual(model.count('AppModel.requestCamera()'), 2,
                         'the camera is asked for somewhere other than the toggle and the intent')
        toggle = model[model.index('    func toggleCamera() {'):
                       model.index('    /// «Сменить камеру»')]
        self.present('guard await AppModel.requestCamera() else {', toggle,
                     'AppModel.toggleCamera()')
        self.present('guard let call, call.state == .connecting || call.state == .connected '
                     'else { return }', toggle, 'AppModel.toggleCamera()')
        # The action carries the call it was taken in. Everything after the
        # first line of the toggle crosses a suspension — the permission
        # dialog, the hop onto the state owner — and the call on the screen can
        # end and be replaced by a call with another peer before either
        # completes. A platform grant lets this application see a camera; it
        # never says which call the user meant. So the generation is read from
        # the call that was tapped, before the first `await`, and the owner
        # re-checks it against the live call (`CallController.video(_:generation:)`).
        self.before('let generation = call.generation', 'await AppModel.requestCamera()',
                    toggle, 'AppModel.toggleCamera()')
        for carried in ('setVideo(false, generation: generation)',
                        'setVideo(true, generation: generation)'):
            self.present(carried, toggle, 'AppModel.toggleCamera()')
        self.assertEqual(model.count('setVideo('), 2,
                         'a camera action reaches the call machinery without naming its call')
        # «Сменить камеру» names its call too. It cannot open a camera — only
        # `setVideo(true, …)` starts a capture — but it crosses the same hop,
        # and a tap that lands after its own call ended would turn the picture
        # of whichever call replaced it. The coordinator checks the call the
        # engine belongs to before the flip reaches the capturer.
        switch = model[model.index('    /// «Сменить камеру»'):
                       model.index('    /// Where a call\'s video is drawn.')]
        self.present('guard let generation = call?.generation else { return }', switch,
                     'AppModel.switchCamera()')
        self.present('switchCamera(generation: generation)', switch, 'AppModel.switchCamera()')
        coordinator = self.sources[COORDINATOR]
        self.before('guard self.engineGeneration == generation else { return }',
                    'self.engine?.switchCamera()',
                    coordinator[coordinator.index('    func switchCamera(generation:'):],
                    'CallCoordinator.switchCamera(generation:)')
        # And nothing above the state owner remembers a camera across a
        # background: a flag here could record only *that* one was on, never
        # whose, and the call it was on may end while the application is away
        # (`call-v2.md:67-69`, `CallController.foreground(_:phase:)`). What is
        # kept here instead is which report of the screen this is: one trip to
        # the background posts four of them through unstructured tasks that
        # nothing orders, and whether the application is on the screen is state
        # that stays, so the owner sorts them by a number minted on this actor
        # before the first suspension — exactly as the toggle reads its
        # generation there.
        background = model[model.index('    func setBackground('):
                           model.index('    /// «Открыть Настройки»')]
        self.before('screenPhase += 1', 'Task {', background, 'AppModel.setBackground()')
        self.present('Task { await calls?.setForeground(!background, phase: phase) }', background,
                     'AppModel.setBackground()')
        self.absent('setVideo', background, 'AppModel.setBackground()')
        self.absent('cameraPaused', model, MODEL)
        # The call screen asks for nothing; it calls the model.
        self.absent('requestCamera', self.sources[CALL], CALL)
        self.absent('AVCaptureDevice', self.sources[CALL], CALL)
        # In the engine the capture session is started by `applyVideo` alone,
        # which only an explicit `setVideo(true)` reaches: creating the tracks
        # never touches a camera device.
        self.assertEqual(engine.count('.startCapture(with: device'), 1,
                         f'{ENGINE}: capture starts in more than one place')
        create = engine[engine.index('    private func create() throws {'):
                        engine.index('    static func configuration(')]
        for token in ('startCapture', 'RTCCameraVideoCapturer(', 'AVCaptureDevice'):
            self.absent(token, create, 'WebRtcAudioEngine.create()')
        # The video track exists from the first description and starts off.
        self.present('videoTrack?.isEnabled', engine, ENGINE)

    def test_a_denied_camera_downgrades_the_call_and_changes_no_section(self):
        coordinator = self.sources[COORDINATOR]
        engine = self.sources[ENGINE]
        extract = self.sources[EXTRACT]
        model = self.sources[MODEL]
        # The port refuses before the engine is reached, with the one error
        # the controller answers by keeping the call.
        self.present('throw CallMediaError.cameraDenied', coordinator, COORDINATOR)
        self.present('AVCaptureDevice.authorizationStatus(for: .video) == .authorized',
                     coordinator, COORDINATOR)
        # A camera that cannot run is announced and the call continues.
        self.present('controller.videoUnavailable(generation)', coordinator, COORDINATOR)
        self.present('announce(Strings.Notice.cameraDenied)', coordinator, COORDINATOR)
        self.present('showNotice(Strings.Notice.cameraDenied)', model, MODEL)
        # Nothing anywhere writes a direction other than `sendrecv`: the two
        # sections are `a=sendrecv` from the first description to the last, and
        # the only mention of the other three is the count that refuses them.
        for name, text in self.sources.items():
            if name == EXTRACT:
                continue
            for literal in literals({name: text}):
                for token in ('a=recvonly', 'a=sendonly', 'a=inactive'):
                    self.assertNotIn(token, literal, f'{name} writes {token!r}')
        self.present('line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive"',
                     extract, EXTRACT)
        self.present('extract.blockedDirectionCount == 0', engine, ENGINE)
        self.present('audio.sendrecvCount == 1, video.sendrecvCount == 1', engine, ENGINE)
        # Camera state travels as a `media` control, never as a renegotiation.
        self.absent('RTCSdpType.rollback', engine, ENGINE)
        self.absent('restartIce', engine, ENGINE)

    def test_the_call_screen_is_androids_call_screen(self):
        screen = self.sources[CALL]
        model = self.sources[MODEL]
        chat = self.sources[CHAT]
        app = self.sources[ENTRY]
        # The four controls of the mock-up's `call-on`, plus Android v22's two
        # camera controls, each addressable.
        for identifier in ('call', 'call-answer', 'call-end', 'call-mute', 'call-speaker',
                           'call-camera', 'call-switch-camera', 'call-back', 'call-status'):
            self.present(f'.accessibilityIdentifier("{identifier}")', screen,
                         f'{CALL}: no {identifier}')
        # The two ways in, from the chat, by Android's own labels.
        for identifier, label in (('call-audio', 'Strings.Call.audioAction'),
                                  ('call-video', 'Strings.Call.videoAction')):
            self.present(f'.accessibilityIdentifier("{identifier}")', chat, CHAT)
            self.present(f'.accessibilityLabel({label})', chat, CHAT)
        self.present('.disabled(!model.canCall)', chat, CHAT)
        # The red button says what it does in each of the three situations
        # (`MainActivity.java:541`).
        self.present('Text(isRinging ? Strings.Call.reject\n'
                     '                 : model.isCallActive ? Strings.Call.hangup '
                     ': Strings.Call.close)', screen, CALL)
        # The two audio controls follow media authority, not signaling.
        self.present('private var isLive: Bool { call?.mediaActive == true '
                     '|| state == .authorizing }', screen, CALL)
        # Every branch of Android's `callLabel` is here, in its order.
        for caption in ('reconnecting', 'starting', 'authorizing', 'outgoing', 'incoming',
                        'connecting', 'video', 'connected', 'busy', 'rejected', 'timeout',
                        'failed', 'cancelled', 'ended'):
            self.present(f'Strings.Call.{caption}', model, f'{MODEL}: callLabel')
        # The video stage exists only while a camera is actually on.
        self.present('isLive && (call?.localVideo == true || call?.remoteVideo == true)',
                     screen, CALL)
        # Android takes its call window out of screenshots, recordings and
        # mirroring with `FLAG_SECURE`, and puts that flag on no other window
        # (`MainActivity.java:478`). iOS has no such flag, so the stage covers
        # itself while the screen is captured — the one part of it the platform
        # allows. It covers rather than removes the surfaces, so a recording
        # that starts and stops does not attach a second renderer to a track.
        self.present('callDialog.getWindow().addFlags(android.view.WindowManager'
                     '.LayoutParams.FLAG_SECURE);', self.java['MainActivity.java'],
                     'MainActivity.java')
        self.present('.overlay { if captured { curtain } }', screen, CALL)
        self.present('UIScreen.capturedDidChangeNotification', screen, CALL)
        self.present('captured = CallScreen.isScreenCaptured', screen, CALL)
        self.present('.contains { $0.screen.isCaptured }', screen, CALL)
        self.present('Text(Strings.Call.captured)', screen, CALL)
        self.present('.accessibilityIdentifier("call-captured")', screen, CALL)
        # The screen is over everything, and it is the only full-screen cover.
        self.present('.fullScreenCover(isPresented: $model.showsCall)', app, ENTRY)
        self.assertEqual(app.count('.fullScreenCover('), 1,
                         f'{ENTRY}: a second full-screen cover')

    def test_info_plist_declares_camera_and_microphone_and_no_delivery_path(self):
        raw = (APP / 'Info.plist').read_text()
        plist = plistlib.loads(raw.encode())
        for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
            self.assertTrue(plist.get(key, '').strip(), f'{key} must carry a reason')
        self.assertEqual(plist.get('UIBackgroundModes'), ['audio'],
                         'the only background mode is the one a live call needs')
        for key in ('voip', 'aps-environment'):
            self.absent(key, raw, 'Info.plist')
        # App Transport Security is switched off on purpose, and the reason is
        # bound to a fact this test enforces at the same time. ATS blocks a
        # self-signed leaf on a public IP address before any delegate is asked
        # (measured on a device: -1200 / -9802 against the hosted server), and
        # its exception list does not accept IP literals, so a pinned server
        # without a domain name cannot be reached with it on. ATS would only
        # have added a CA-chain check this client deliberately does not rely
        # on: every session is built by PinnedSessionDelegate, which enforces
        # the SPKI pin, the TLS 1.2 floor, no proxies and no redirects. The
        # second half of the assertion is what makes the first half safe.
        ats = plist.get('NSAppTransportSecurity')
        self.assertEqual(ats, {'NSAllowsArbitraryLoads': True},
                         'ATS is off exactly and only as documented; no per-domain exceptions')
        unpinned = ('URLSession.shared', 'URLSession(configuration: .default',
                    'URLSession(configuration: .ephemeral', 'URLSessionConfiguration.default')
        for path, source in self.sources.items():
            for needle in unpinned:
                self.assertNotIn(needle, source,
                                 f'{path}: a session outside PinnedSessionDelegate would rely on ATS')
        self.absent('aps-environment', (APP / 'ParanoID.entitlements').read_text(),
                    'ParanoID.entitlements')


if __name__ == '__main__':
    program = unittest.main(exit=False)
    sys.exit(0 if program.result.wasSuccessful() else 1)
