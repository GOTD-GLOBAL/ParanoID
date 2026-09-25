#!/usr/bin/env python3
"""The shipped application in the simulator, against a local stand and a real peer.

Nothing here is a mock. The application is the `ParanoID` target as it is
built for a phone — the same `AppModel`, the same `StateOwner` over the real
Rust core, the same pinned transport and the same two realtime lanes — driven
through `ParanoIDUITests/TextFlowUITests` on `iPhone 17 Pro (26.5)`. The other
side of every message is a second `service-bridge` process: the same Swift
classes over the same core, with its own snapshot and its own account. The
server is the **unchanged** binary on a private PostgreSQL 16 cluster started
by `clients/ios/local_stand.py`, and the stand's `-paranoid-realm` /
`-paranoid-pin` pair is always passed to the application, so a simulator run
can never reach the hosted alpha.

One run does, in order:

1. `swift build --product service-bridge` and `xcodebuild build-for-testing`
   (`--skip-build` / `--skip-app-build` reuse what is already there). The
   application is built **with** the default simulator signature, not with
   `CODE_SIGNING_ALLOWED=NO`: without it the process carries no
   `application-identifier`, every `SecItem` call answers -34018 and the
   client freezes before it can open its state (`clients/ios/README.md`,
   `KeychainStoreTests`).
2. the stand, and one peer phone on it — `create`, then the registration that
   issues its account, its contact material and its session;
3. `xcrun simctl uninstall <udid> global.paranoid.messenger`. The container
   goes and the simulator's Keychain stays — the fixture counts this
   application's items in the device's own keychain database on both sides of
   the uninstall, and refuses to call the run a reinstall if the item is gone
   — which is the reinstall of D-004: every run of this fixture starts from
   it, and the `reinstall` scenario runs it a second time to compare the two
   identities;
4. `text`: «Создать ID» → «Мой ID» with the QR and the account → «Вставить
   контакт» with the peer's contact → «Отпечаток совпадает» → the chat → one
   tap on «Отправить» → «Сохранено сервером» → the peer answers → its bubble
   and «Доставлено» → a
   double tap on «Отправить» → exactly one bubble, one envelope on the server
   and one «Доставлено» → «Заблокировать контакт» and back;
5. `reinstall`: uninstall again, launch again, «Создать ID» again — no freeze
   over the retained Keychain key, and an account that is not the first one's.

The test and this script meet in a rendezvous directory rather than on a
clock: the test writes a request and blocks, this script answers it. That is
what makes `xcrun simctl io <udid> screenshot` photograph the screen the
assertion was just made about, and what lets the test wait for the peer's own
core to hold a message rather than for a fixed number of seconds.

Usage:
  python3 clients/ios/test_sim_text.py --evidence-dir out/evidence/sim-text
  python3 clients/ios/test_sim_text.py --scenario text --keep

Exit status: 0 when every scenario holds, 1 when one does not, 2 when the run
could not decide (no Xcode, no core xcframework, no simulator, a stand that
did not start). The evidence is one JSON document of counts, digests and
verdicts beside the screenshots: no account, no fingerprint, no contact, no
realm, no pin and no snapshot bytes.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'out'
PROJECT = HERE / 'App/ParanoID.xcodeproj'
SCHEME = 'ParanoID'
DERIVED = OUT / 'DerivedData-sim-text'
LOG_DIR = OUT / 'logs'
BUILD_LOG = LOG_DIR / 'test-sim-text-build.log'
DEFAULT_EVIDENCE_DIR = 'out/evidence/sim-text'
RESULT = 'sim-text-result.json'

# The one simulator this scenario is documented on, and the identity of the
# application on it (`App/Config/Bundle.xcconfig`).
DEVICE = 'iPhone 17 Pro'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
RUNTIME_NAME = 'iOS 26.5'
BUNDLE_ID = 'global.paranoid.messenger'
# The peer, one of the five synthetic names `service-bridge` allows.
PEER = 'two'
SUITE = 'ParanoIDUITests/TextFlowUITests'
SCENARIOS = {'text': SUITE + '/testTextFlowOnTheLocalStand',
             'reinstall': SUITE + '/testReinstallStartsANewIdentity'}

# The texts this run sends. They are synthetic identifiers rather than
# UI strings: they are typed on a simulator keyboard, and they are what the
# `psql` scan looks for in every column of the cluster, so they stay ASCII and
# stay free of the characters a SQL literal cannot hold.
FIRST = 'sim-text-first-message'
REPLY = 'sim-text-peer-reply'
DOUBLE = 'sim-text-double-tap'
# «Новые сообщения» (`SeenMarks`): one text the peer sends while the chat is open
# at its bottom — seen at once — twelve it sends while «Чаты» is on screen, more
# than one screen of history, and one while the reader is scrolled up.
SEEN = 'sim-text-seen-while-open'
UNSEEN = tuple(f'sim-text-unseen-{n:02d}' for n in range(1, 13))
DRAG = 'sim-text-while-scrolled-up'
PEER_TEXTS = (REPLY, SEEN) + UNSEEN + (DRAG,)

ACCOUNT = re.compile(r'\A[0-9a-f]{64}\Z')
# How long one `xcodebuild test-without-building` may take. How long the test
# waits for an answer to one request is its own bound (`Timeout.answer` in
# `TextFlowUITests.swift`), and it is the smaller of the two.
RUN_TIMEOUT = 1800
# How long the peer may take to hold a message the application has sent, and
# how many further cycles confirm that no second copy follows.
PEER_TIMEOUT = 120
PEER_SETTLE = 2
# How long one request of the harness is spaced from the next (`Pacer`).
REQUEST_SPACING = 1.0

sys.path.insert(0, str(HERE))
import local_stand  # noqa: E402  (the path is set up right above)
import test_clean_self_service as harness  # noqa: E402

CheckError = harness.CheckError
Failure = harness.Failure
require = harness.require
digest = harness.digest


# ------------------------------------------------------------------ simulator


def xcrun(*arguments, check=True, timeout=300):
    """One `xcrun` command; the stdout is returned, the stderr is the failure."""
    completed = subprocess.run(['xcrun', *arguments], capture_output=True, text=True,
                               check=False, timeout=timeout)
    if check and completed.returncode != 0:
        raise CheckError(f'xcrun {" ".join(arguments)} failed (exit '
                         f'{completed.returncode}): {completed.stderr.strip()}')
    return completed.stdout


def simulator(name, runtime):
    """The UDID of `name` on `runtime`, booted."""
    if shutil.which('xcrun') is None:
        raise CheckError('xcrun not found; Xcode 26.6 is required')
    try:
        listed = json.loads(xcrun('simctl', 'list', 'devices', '--json'))
    except (ValueError, subprocess.TimeoutExpired) as error:
        raise CheckError(f'simctl list devices failed: {error}')
    devices = [device for device in listed['devices'].get(runtime, [])
               if device['name'] == name and device.get('isAvailable', True)]
    if not devices:
        raise CheckError(f'no available "{name}" on {runtime}; '
                         'create it in Xcode > Window > Devices and Simulators')
    device = devices[0]
    if device['state'] != 'Booted':
        log(f'booting {name} ({device["udid"]})')
        xcrun('simctl', 'boot', device['udid'])
    xcrun('simctl', 'bootstatus', device['udid'], '-b', timeout=600)
    return device['udid']


def uninstall(udid):
    """`xcrun simctl uninstall`: the container goes, the Keychain stays."""
    xcrun('simctl', 'uninstall', udid, BUNDLE_ID)


def keychain_items(udid):
    """How many Keychain items of this application the simulator holds.

    It is the one way to observe from outside the application that the item
    under `paranoid-text-state-v0` survived an uninstall, which is the premise
    the reinstall scenario rests on. The account itself cannot be looked for by
    name: a data-protection item stores its queryable attributes as digests
    (`acct` and `svce` are twenty bytes of hash in `genp`), and only the access
    group is plain — and nothing but this application lives in
    `…global.paranoid.messenger`.

    The database is copied with its write-ahead log and the **copy** is opened,
    so the simulator's own file is neither locked nor written; no key material
    is read, only a count.

    - Returns: the number of rows, or `None` when the database cannot be read.
    """
    keychains = (Path.home() / 'Library/Developer/CoreSimulator/Devices' / udid
                 / 'data/Library/Keychains')
    databases = sorted(keychains.glob('keychain-2*.db'))
    if not databases:
        return None
    source = databases[0]
    with tempfile.TemporaryDirectory(prefix='paranoid-keychain-') as temporary:
        copy = Path(temporary) / source.name
        try:
            for suffix in ('', '-wal', '-shm'):
                beside = Path(str(source) + suffix)
                if beside.is_file():
                    shutil.copy(beside, str(copy) + suffix)
            connection = sqlite3.connect(str(copy))
            try:
                return connection.execute(
                    'SELECT count(*) FROM genp WHERE agrp = ? OR agrp LIKE ?',
                    (BUNDLE_ID, '%.' + BUNDLE_ID)).fetchone()[0]
            finally:
                connection.close()
        except (OSError, sqlite3.Error):
            return None


def log(message):
    print(f'test_sim_text: {message}', file=sys.stderr, flush=True)


# ---------------------------------------------------------------------- build


def build_application(skip):
    """`xcodebuild build-for-testing` with the default simulator signature."""
    if shutil.which('xcodebuild') is None:
        raise CheckError('xcodebuild not found; Xcode 26.6 is required')
    products = DERIVED / 'Build/Products'
    if skip:
        require(products.is_dir(), f'{products} does not exist; drop --skip-app-build')
        return
    argv = ['xcodebuild', 'build-for-testing', '-project', str(PROJECT), '-scheme', SCHEME,
            '-destination', f'platform=iOS Simulator,name={DEVICE},OS={RUNTIME_NAME[4:]}',
            '-derivedDataPath', str(DERIVED)]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log('building the application: ' + ' '.join(argv[:3]))
    with BUILD_LOG.open('w') as sink:
        built = subprocess.run(argv, cwd=ROOT, stdout=sink, stderr=sink, check=False)
    if built.returncode != 0:
        raise CheckError(f'xcodebuild build-for-testing failed (exit {built.returncode}); '
                         f'see {BUILD_LOG}')


# ----------------------------------------------------------------- the peer


class Peer:
    """The phone on the other side of every message.

    It is one `service-bridge` phone driven by `sync`, which is the shipped
    connection cycle: the outbox, one page and the pass that carries the
    receipts the page queued. Nothing about it is special to this fixture —
    the application meets exactly what an Android or a second iPhone would be.
    """

    def __init__(self, bridge, phone):
        self.bridge = bridge
        self.phone = phone
        self.account = ''
        self.contact = ''
        self.fingerprint = ''
        #: The application's account, learnt from the first message it sends.
        self.peer_account = ''

    def register(self):
        """`create` and the registration; answers the facts about both."""
        view, facts, secrets = harness.register(self.bridge, self.phone)
        self.account = view['account']
        self.fingerprint = view['contact_fingerprint']
        # The contact travels as the object the core published. Its signature
        # is over a transcript of the members, not over the JSON text
        # (`clients/core/src/contact_v2.rs`), and `deny_unknown_fields` keeps
        # the member set exact, so the compact re-encoding the application is
        # given is the same contact its core verifies.
        self.contact = json.dumps(view['contact'], separators=(',', ':'), ensure_ascii=False)
        require(ACCOUNT.match(self.account), 'the peer has no account')
        require(len(self.contact) <= 4096, 'the peer contact is above the text-import bound')
        return facts, secrets

    def sync(self):
        return self.bridge.rpc(self.phone, 'sync', weight=3)

    def dialog(self, view):
        entries = view.get('dialogs') or []
        if self.peer_account:
            entries = [entry for entry in entries if entry['account'] == self.peer_account]
        require(len(entries) <= 1, f'the peer holds {len(entries)} conversations, expected one')
        return entries[0] if entries else None

    def expect(self, text, timeout=PEER_TIMEOUT):
        """Waits until this phone's own committed history holds `text`.

        It answers how many copies of it are there, and it keeps cycling for
        `PEER_SETTLE` rounds after the first one arrives: a duplicate that the
        double-tap guard failed to stop would land a moment later, and a count
        taken at the first sight of the text would miss it.
        """
        deadline = time.monotonic() + timeout
        count = 0
        while True:
            entry = self.dialog(self.sync())
            if entry is not None:
                if not self.peer_account:
                    self.peer_account = entry['account']
                count = sum(1 for message in entry['messages'] if message['text'] == text)
            if count:
                break
            if time.monotonic() >= deadline:
                raise Failure(f'the peer never received {text!r} within {timeout} s')
            time.sleep(1)
        for _ in range(PEER_SETTLE):
            entry = self.dialog(self.sync())
            count = sum(1 for message in entry['messages'] if message['text'] == text)
        return count

    def send(self, text):
        """One reply, and the cycle that puts it on the wire."""
        require(self.peer_account, 'the peer does not know who to answer yet')
        self.bridge.rpc(self.phone, 'send',
                        json.dumps({'account': self.peer_account, 'text': text}))
        self.sync()

    def history(self):
        entry = self.dialog(self.sync())
        return entry['messages'] if entry else []


# ------------------------------------------------------------ the rendezvous


class Rendezvous(threading.Thread):
    """Answers the requests `TextFlowUITests` writes, while it waits on them.

    The directory is the whole protocol: `req-<n>` carries one verb and one
    base64 argument, `ans-<n>` carries `ok [payload]` or `error <detail>`, and
    both are renamed into place so that neither side can read half a line.

    Five verbs exist, and every one of them is something the test cannot do
    for itself: take a screenshot of the simulator it is driving, record a
    fact for the evidence, and make the peer phone receive, answer or cycle.
    """

    def __init__(self, directory, peer, udid, evidence):
        super().__init__(daemon=True)
        self.directory = directory
        self.peer = peer
        self.udid = udid
        self.evidence = evidence
        self.answered = set()
        self.notes = {}
        self.shots = []
        self.failure = None
        self._stop = threading.Event()
        self.verbs = {'shot': self._shot, 'note': self._note, 'peer-expect': self._expect,
                      'peer-send': self._send, 'peer-sync': self._sync}

    def stop(self):
        self._stop.set()

    def run(self):
        while not self._stop.is_set():
            self.serve()
            self._stop.wait(0.05)
        self.serve()

    def serve(self):
        for request in sorted(self.directory.glob('req-[0-9]*')):
            if request.suffix == '.tmp' or request.name in self.answered:
                continue
            self.answered.add(request.name)
            self._answer(request)

    def _answer(self, request):
        name = request.name[len('req-'):]
        try:
            verb, _, encoded = request.read_text().strip().partition(' ')
            argument = base64.b64decode(encoded).decode() if encoded else ''
            handler = self.verbs.get(verb)
            if handler is None:
                raise Failure(f'unknown request {verb!r}')
            reply = ('ok ' + str(handler(argument))).rstrip()
        except Exception as error:  # noqa: BLE001 - every failure becomes an answer
            reply = f'error {type(error).__name__}: {error}'
            if self.failure is None:
                self.failure = reply[len('error '):]
        staging = self.directory / f'ans-{name}.tmp'
        staging.write_text(reply + '\n')
        os.replace(staging, self.directory / f'ans-{name}')

    # -- the verbs

    def _shot(self, name):
        require(re.fullmatch(r'[0-9a-z-]{1,48}', name), f'{name!r} is not a screenshot name')
        path = self.evidence / f'{name}.png'
        xcrun('simctl', 'io', self.udid, 'screenshot', '--type=png', str(path))
        require(path.is_file() and path.stat().st_size > 0, f'{path} was not written')
        self.shots.append(path.name)
        return path.name

    def _note(self, argument):
        key, _, value = argument.partition(' ')
        require(re.fullmatch(r'[a-z_]{1,32}', key), f'{key!r} is not a note')
        self.notes[key] = value
        return 'noted'

    def _expect(self, text):
        return self.peer.expect(text)

    def _send(self, text):
        self.peer.send(text)
        return 'sent'

    def _sync(self, _):
        self.peer.sync()
        return 'synced'


# ----------------------------------------------------------------- one run


def run_scenario(scenario, peer, udid, evidence, environment, keep):
    """One `xcodebuild test-without-building`, with the rendezvous alive.

    - Returns: what the test recorded — its notes, and the screenshots this
      script took for it.
    """
    # The rendezvous lives under `out/`, where a simulator process is already
    # known to write (`ParanoIDTests/SdpCompatibilityTests` writes its
    # evidence there), and it is removed with the run unless `--keep`.
    directory = OUT / f'rendezvous-{scenario}'
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    directory.chmod(0o755)
    try:
        server = Rendezvous(directory, peer, udid, evidence)
        server.start()
        argv = ['xcodebuild', 'test-without-building', '-project', str(PROJECT),
                '-scheme', SCHEME, '-destination', f'platform=iOS Simulator,id={udid}',
                '-derivedDataPath', str(DERIVED),
                f'-only-testing:{SCENARIOS[scenario]}']
        run_log = LOG_DIR / f'test-sim-text-{scenario}.log'
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        child_environment = dict(os.environ)
        child_environment.update({f'TEST_RUNNER_{key}': value
                                  for key, value in environment.items()})
        child_environment['TEST_RUNNER_PARANOID_SIM_RENDEZVOUS'] = str(directory)
        log(f'{scenario}: {SCENARIOS[scenario]}')
        with run_log.open('w') as sink:
            completed = subprocess.run(argv, cwd=ROOT, env=child_environment, stdout=sink,
                                       stderr=sink, check=False, timeout=RUN_TIMEOUT)
        server.stop()
        server.join(timeout=10)
    finally:
        if keep:
            shutil.copytree(directory, evidence / f'rendezvous-{scenario}', dirs_exist_ok=True)
        else:
            shutil.rmtree(directory, ignore_errors=True)
    if server.failure is not None:
        raise Failure(f'{scenario}: the harness could not answer the test: {server.failure}')
    if completed.returncode != 0:
        raise Failure(f'{scenario}: xcodebuild test failed (exit {completed.returncode}); '
                      f'see {run_log}')
    return server.notes, server.shots


# ------------------------------------------------------------------ evidence


ALLOWED_EVIDENCE = {
    'result', 'scenarios', 'device', 'runtime', 'bundle_id', 'server_binary', 'server_sha256',
    'core_slice_sha256', 'screenshots', 'peer', 'messages', 'server_state', 'reinstall',
    'checks',
}


#: What each scenario states, in the order it states it. Only the scenarios
#: that ran are written, so the evidence never claims a check that was skipped.
CHECKS = {
    'text': [
        'the application talks only to the local stand: -paranoid-realm/-paranoid-pin are passed '
        'on every launch and the stand guard is not shown',
        '«Создать ID» registers and «Мой ID» shows the contact QR and a 64-digit account',
        'the pasted contact is the peer\'s own text and the fingerprint on «Проверка контакта» is '
        'the one that peer\'s core published',
        'the bubble carries the time this phone wrote it and the chat names the day («Сегодня»); '
        'one tap on «Отправить» is one envelope: «Сохранено сервером» after the server stored it, '
        '«Доставлено» after the peer '
        'acknowledged it',
        'a double tap on «Отправить» draws one bubble, reaches the peer once and carries one «Доставлено»',
        '«Заблокировать контакт» disables the composer and «Разблокировать контакт» restores it',
        '«Переименовать» names the contact on this phone only: the local name replaces the '
        'default label and an empty field restores it',
        '«Новые сообщения»: a message that arrives while the chat is open at its bottom is not '
        'counted; twelve that arrive while «Чаты» is on screen show «12 новых сообщений» on the '
        'row; the chat opens with the «Новые сообщения» divider on the screen and the newest '
        'message below it, «↓» leads down and the count clears after the bottom was shown; a '
        'message that arrives while the reader is scrolled up leaves the history where it is and '
        'brings up «↓»',
    ],
    'reinstall': [
        'xcrun simctl uninstall leaves the Keychain item and takes the container: the next launch '
        'starts a new identity instead of freezing over the retained key',
    ],
}
#: What holds however many scenarios ran.
ALWAYS = ['no plaintext of this run appears in any column of the cluster']


def checks_for(scenarios):
    return [line for scenario in scenarios for line in CHECKS[scenario]] + ALWAYS


def write_evidence(directory, payload, secrets):
    directory.mkdir(parents=True, exist_ok=True)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    for secret in secrets:
        require(secret and secret not in text,
                'evidence carries account, contact, fingerprint, realm or pin material')
    path = directory / RESULT
    path.write_text(text)
    return path


# ------------------------------------------------------------------------ run


def run(args):
    os.umask(0o077)
    evidence = Path(args.evidence_dir or DEFAULT_EVIDENCE_DIR)
    if not evidence.is_absolute():
        evidence = HERE / evidence
    evidence.mkdir(parents=True, exist_ok=True)
    scenarios = list(SCENARIOS) if args.scenario == 'all' else [args.scenario]

    binary = harness.build_bridge(args.skip_build)
    build_application(args.skip_app_build)
    udid = simulator(args.device, RUNTIME)

    stand_argv = ['--work-dir', str(OUT)]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    if args.pg_bin:
        stand_argv += ['--pg-bin', args.pg_bin]
    stand = local_stand.Stand(local_stand.parse_args(stand_argv))
    pacer = harness.Pacer(REQUEST_SPACING)
    bridge = None
    facts = {}
    with tempfile.TemporaryDirectory(prefix='paranoid-sim-peer-') as temporary:
        try:
            try:
                stand.start()
            except local_stand.StandError as error:
                raise CheckError(f'local stand: {error}')
            log(f'stand: {stand.descriptor["server_url"]} (log {stand.log_path})')
            bridge = harness.Bridge('peer', binary, Path(temporary) / 'peer',
                                    stand.descriptor['server_url'],
                                    stand.descriptor['tls_spki_sha256'], pacer)
            peer = Peer(bridge, PEER)
            peer_facts, peer_secrets = peer.register()
            database = harness.Database(stand)
            common = {
                'PARANOID_SIM_REALM': stand.descriptor['server_url'],
                'PARANOID_SIM_PIN': stand.descriptor['tls_spki_sha256'],
                'PARANOID_SIM_PEER_CONTACT': base64.b64encode(peer.contact.encode()).decode(),
                'PARANOID_SIM_PEER_ACCOUNT': peer.account,
                'PARANOID_SIM_PEER_FINGERPRINT': peer.fingerprint,
                'PARANOID_SIM_FIRST_TEXT': FIRST,
                'PARANOID_SIM_REPLY_TEXT': REPLY,
                'PARANOID_SIM_DOUBLE_TEXT': DOUBLE,
                'PARANOID_SIM_SEEN_TEXT': SEEN,
                'PARANOID_SIM_UNSEEN_TEXTS': ','.join(UNSEEN),
                'PARANOID_SIM_DRAG_TEXT': DRAG,
            }
            shots = []
            notes = {}
            outcome = {}

            if 'text' in scenarios:
                uninstall(udid)
                written, taken = run_scenario('text', peer, udid, evidence, dict(common),
                                              args.keep)
                notes.update(written)
                shots += taken
                outcome['text'] = 'PASS'
                require(ACCOUNT.match(notes.get('account', '')),
                        'the text scenario recorded no account')
                require(notes.get('flow') == 'complete', 'the text scenario did not run to its end')

            if 'reinstall' in scenarios:
                require('account' in notes,
                        'the reinstall scenario needs the account the text scenario recorded; '
                        'run --scenario all')
                facts['keychain_before'] = keychain_items(udid)
                uninstall(udid)
                facts['keychain_after'] = keychain_items(udid)
                require(facts['keychain_before'] == 1,
                        'the text scenario left no Keychain item of this application: '
                        f'{facts["keychain_before"]} rows')
                require(facts['keychain_after'] == 1,
                        'the Keychain item did not survive xcrun simctl uninstall '
                        f'({facts["keychain_after"]} rows), so this is no longer the reinstall '
                        'StorageGuard decides about')
                environment = dict(common)
                environment['PARANOID_SIM_PREVIOUS_ACCOUNT'] = notes['account']
                written, taken = run_scenario('reinstall', peer, udid, evidence, environment,
                                              args.keep)
                shots += taken
                outcome['reinstall'] = 'PASS'
                require(ACCOUNT.match(written.get('reinstall_account', '')),
                        'the reinstall produced no account')
                require(written['reinstall_account'] != notes['account'],
                        'the reinstall kept the previous identity')
                notes.update(written)

            # What the peer and the cluster hold, once both scenarios are over.
            history = peer.history()
            texts = [message['text'] for message in history]
            rows = database.messages()
            plaintext = sum(database.rows_carrying(text) for text in (FIRST, DOUBLE) + PEER_TEXTS)
            require(texts.count(FIRST) == 1, f'the peer holds {texts.count(FIRST)} first messages')
            require(texts.count(DOUBLE) == 1,
                    f'a double tap reached the peer {texts.count(DOUBLE)} times')
            for text in PEER_TEXTS:
                require(texts.count(text) == 1, f'the peer does not hold its own {text!r} once')
            require(plaintext == 0, f'{plaintext} rows of the cluster carry a plaintext of this run')

            payload = {
                'result': 'PASS',
                'scenarios': outcome,
                'device': args.device,
                'runtime': RUNTIME_NAME,
                'bundle_id': BUNDLE_ID,
                'server_binary': str(stand.server_binary),
                'server_sha256': digest(Path(stand.server_binary)),
                'core_slice_sha256': digest(harness.CORE_SLICE),
                'screenshots': shots,
                'peer': {'registered': True,
                         'enrollment_mode': peer_facts['enrollment_mode'],
                         'session': peer_facts['session']['issued'],
                         'contact_bytes': len(peer.contact)},
                'messages': {'sent_by_application': 2,
                             'sent_by_peer': len(PEER_TEXTS),
                             'copies_of_the_double_tap': texts.count(DOUBLE),
                             'peer_history': len(history)},
                'server_state': {'stored_envelopes': len(rows),
                                 'plaintext_rows': plaintext},
                'checks': checks_for(scenarios),
            }
            if 'reinstall' in outcome:
                payload['reinstall'] = {
                    'keychain_items_before_uninstall': facts['keychain_before'],
                    'keychain_items_after_uninstall': facts['keychain_after'],
                    'identity_kept': False,
                    'accounts_differ': notes['reinstall_account'] != notes['account'],
                }
            secrets = sorted(set(peer_secrets) | {
                peer.account, peer.fingerprint, peer.contact,
                notes.get('account', ''), notes.get('reinstall_account', ''),
                stand.descriptor['server_url'], stand.descriptor['tls_spki_sha256'],
            } - {''})
            path = write_evidence(evidence, payload, secrets)
        finally:
            if bridge is not None:
                bridge.close()
            stand.stop()
            # The simulator is shared with every other check on this Mac, and
            # an application left behind with an identity in it is a state the
            # next one did not ask for: `ParanoIDUITests` expects the stand
            # guard, which a retained snapshot would never show. The Keychain
            # item stays, as it does after any uninstall. A failure to clean up
            # is never allowed to replace the failure that is on its way out.
            try:
                uninstall(udid)
            except CheckError as error:
                log(f'the application could not be uninstalled: {error}')

    print('PASS: {shots} screenshots, {rows} stored envelopes, {plaintext} plaintext rows, '
          'one bubble per tap'.format(shots=len(shots), rows=len(rows), plaintext=plaintext),
          flush=True)
    for scenario in scenarios:
        print(f'{scenario}: {outcome[scenario]}', flush=True)
    print('checks: ' + '; '.join(payload['checks']), flush=True)
    print(f'evidence: {path}', flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--evidence-dir',
                        help='where the JSON and the screenshots go; a relative path is resolved '
                             f'against clients/ios (default: {DEFAULT_EVIDENCE_DIR})')
    parser.add_argument('--scenario', choices=['all', *SCENARIOS], default='all',
                        help='which scenario to run (default: all; "reinstall" alone needs the '
                             'account the text scenario records)')
    parser.add_argument('--device', default=DEVICE,
                        help=f'the simulator to run on (default: {DEVICE})')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='use this paranoid-server instead of building the working tree')
    parser.add_argument('--pg-bin', metavar='DIR',
                        help='PostgreSQL 16 bin directory (default: clients/ios/toolchain.json)')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse the service-bridge executable already built')
    parser.add_argument('--skip-app-build', action='store_true',
                        help='reuse the application and test bundles already built into '
                             'out/DerivedData-sim-text')
    parser.add_argument('--keep', action='store_true',
                        help='copy the rendezvous directory of each scenario into the evidence '
                             'directory')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Failure as failure:
        print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    except CheckError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired as error:
        print(f'ERROR: {error.cmd[0]} did not finish within {error.timeout} s', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
