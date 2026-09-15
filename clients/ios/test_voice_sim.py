#!/usr/bin/env python3
"""One call between two simulators, both of them the shipped application.

Nothing here is a mock and nothing here is a peer written for a test: both
sides are the `ParanoID` target as it is built for a phone — the same
`AppModel`, the same `CallController` over the real Rust core, the same
`WebRtcAudioEngine` over libwebrtc — driven through
`ParanoIDUITests/VoiceCallUITests` on `iPhone 17 Pro (26.5)` and
`iPhone 17e (26.5)` at the same time. The server is the **unchanged** binary on
a private PostgreSQL 16 cluster started by `clients/ios/local_stand.py`, which
starts no TURN: `/v2/voice/turn` answers an authenticated `404 turn_disabled`,
that is the disclosed direct-ICE compatibility mode, and the media therefore
goes straight from one simulator to the other with no relay in between.

One run does, in order:

1. `xcodebuild build-for-testing` with the default simulator signature — not
   `CODE_SIGNING_ALLOWED=NO`: without a signature the process carries no
   `application-identifier`, every `SecItem` call answers -34018 and the client
   freezes before it can open its state (`clients/ios/README.md`);
2. `xcrun simctl uninstall global.paranoid.messenger` on **both** simulators,
   so both sides start from the clean install of D-004, and
   `xcrun simctl privacy … grant microphone`, which is the one thing a
   simulator cannot be asked by hand in an unattended run;
3. the stand, and two `xcodebuild test-without-building` processes at once, one
   per simulator. They meet only through this script: `publish`/`fetch` carry
   each side's account, contact fingerprint and contact — the contact is read
   off the device's own pasteboard with `xcrun simctl pbpaste` after
   «Копировать контакт», never by the test process, which would raise the
   system's paste alert — and `sync` is a barrier;
4. the call, twice: `a` calls `b`, then `b` calls `a`. Each one is answered,
   both sides reach «Соединение установлено», which is
   `RTCPeerConnectionState.connected` and nothing weaker, the media summary of
   both sides shows `packetsReceived` above zero, and the call is then held for
   40 seconds — longer than `CallController.silenceMillis` (30 s), so a call
   still up afterwards has been carried over it by the peer's ten-second
   heartbeat, which is also visible as the envelopes the cluster stored while
   it went on;
5. «Завершить», and the same again in the other direction.

The media summary is the Debug-only `CallDiagnostics` sink: the application
samples `RTCPeerConnection.statistics` once a second while a call is up and
writes packet and byte counters, the transport state and the two candidate
**types** — never an address, a port or an identifier — where this script reads
them.

Usage:
  python3 clients/ios/test_voice_sim.py --evidence-dir out/evidence/voice-sim
  python3 clients/ios/test_voice_sim.py --skip-app-build --keep

Exit status: 0 when both calls hold, 1 when one does not, 2 when the run could
not decide (no Xcode, no simulator, a stand that did not start). The evidence is
one JSON document of counts and verdicts beside the screenshots: no account, no
fingerprint, no contact, no realm, no pin, no address of this machine and no
snapshot bytes.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
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
DERIVED = OUT / 'DerivedData-voice-sim'
LOG_DIR = OUT / 'logs'
BUILD_LOG = LOG_DIR / 'test-voice-sim-build.log'
DEFAULT_EVIDENCE_DIR = 'out/evidence/voice-sim'
RESULT = 'voice-sim-result.json'

sys.path.insert(0, str(HERE))
import local_stand  # noqa: E402  (the path is set up right above)
import test_clean_self_service as harness  # noqa: E402
import test_sim_text as sim  # noqa: E402  (the simulator helpers, imported not copied)

CheckError = harness.CheckError
Failure = harness.Failure
require = harness.require
digest = harness.digest
xcrun = sim.xcrun

BUNDLE_ID = sim.BUNDLE_ID
RUNTIME = sim.RUNTIME
RUNTIME_NAME = sim.RUNTIME_NAME
SUITE = 'ParanoIDUITests/VoiceCallUITests/testVoiceCallBetweenTwoSimulators'

#: The two simulators, by the side each of them plays. `a` calls first.
DEVICES = {'a': 'iPhone 17 Pro', 'b': 'iPhone 17e'}
#: Who places each of the two calls, in order.
DIRECTIONS = [('a', 'b'), ('b', 'a')]

#: How long a connected call is held before it is ended. It is the number
#: `VoiceCallUITests` holds for, and it is above `CallController.silenceMillis`
#: (30 s): a call that is still up afterwards has been receiving the peer's
#: ten-second heartbeat all along.
HOLD_SECONDS = 40
#: How many heartbeats each side must therefore have sent, at one every ten
#: seconds (`CallController.heartbeatMillis`). Four fit in the window; the
#: check asks for three, because the window's two ends are not a call's.
HEARTBEATS_PER_HOLD = 3
#: `CallController.silenceMillis`: how long a call may hear nothing from the
#: peer before it ends itself. Every call of a run outlives it.
SILENCE_SECONDS = 30
#: How long one `xcodebuild test-without-building` may take. How long a test
#: waits for one answer is its own bound (`Timeout.answer`), and it is smaller.
RUN_TIMEOUT = 2400
#: How long a side may wait for the other one at a barrier or a `fetch`.
MEET_TIMEOUT = 900

ACCOUNT = re.compile(r'\A[0-9a-f]{64}\Z')
#: A contact is one line of JSON the peer's core wrote. Nothing else may be
#: passed between the two sides.
CONTACT_LIMIT = 4096

#: Why the screen-lock story is not part of this run. `xcrun simctl` has no
#: lock verb at all (`xcrun simctl help` lists none), `XCUIDevice` has no lock
#: API, and the Simulator's own ⌘L is a host-window action that needs the
#: Accessibility permission this run does not take. It is a phone scenario, and
#: it belongs to the phone step.
LOCK_NOT_RUN = ('xcrun simctl exposes no lock verb and XCUIDevice has no lock API; '
                'the Simulator\'s ⌘L is a host-window action outside this harness. '
                'Deferred to the device run.')


def log(message):
    print(f'test_voice_sim: {message}', file=sys.stderr, flush=True)


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
            '-destination', f'platform=iOS Simulator,name={DEVICES["a"]},OS={RUNTIME_NAME[4:]}',
            '-derivedDataPath', str(DERIVED)]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log('building the application: ' + ' '.join(argv[:3]))
    with BUILD_LOG.open('w') as sink:
        built = subprocess.run(argv, cwd=ROOT, stdout=sink, stderr=sink, check=False)
    if built.returncode != 0:
        raise CheckError(f'xcodebuild build-for-testing failed (exit {built.returncode}); '
                         f'see {BUILD_LOG}')


def derived_for(side):
    """A per-side copy of the built products.

    Two `xcodebuild test-without-building` processes run at the same time, and
    a derived-data directory is not a place two of them may write at once: each
    one puts its own result bundle and its own logs there. Only
    `Build/Products` is needed to run a built test, so it is cloned — `cp -Rc`
    is a copy-on-write clone on APFS, so this costs neither the time nor the
    space of a second build — and the two runs never meet on a file.
    """
    products = DERIVED / 'Build/Products'
    target = OUT / f'DerivedData-voice-{side}'
    shutil.rmtree(target, ignore_errors=True)
    (target / 'Build').mkdir(parents=True)
    cloned = subprocess.run(['cp', '-Rc', str(products), str(target / 'Build/Products')],
                            capture_output=True, text=True, check=False)
    if cloned.returncode != 0:
        # Not every file system can clone; a plain copy is the same directory.
        shutil.copytree(products, target / 'Build/Products', symlinks=True)
    return target


# ------------------------------------------------------------------ the board


class Board:
    """What the two sides know about each other, and where they meet.

    Both simulators run the same test, and neither of them can see the other:
    the account, the fingerprint and the contact each one needs travel through
    here, and so does every barrier. It is one lock and one condition, because
    every wait in it is "until the other side gets there".
    """

    def __init__(self, udids):
        self.udids = udids
        self.condition = threading.Condition()
        self.published = {}
        self.arrived = {}
        #: Every hold of the run, in order, whichever side asked for it. It is
        #: what numbers the mid-call screenshots: the caller changes between
        #: the two directions, so a number taken from one side's own list would
        #: be `1` twice and the second pair of photographs would replace the
        #: first.
        self.holds = []
        #: Screenshots this script took of a side other than the one that
        #: asked for them: the mid-call photographs are of both screens at
        #: once, and the evidence names every file it wrote.
        self.shots = []

    def publish(self, side, key, value):
        with self.condition:
            self.published[(side, key)] = value
            self.condition.notify_all()
        return len(value)

    def fetch(self, side, key, timeout=MEET_TIMEOUT):
        """The **other** side's `key`, once it has published it."""
        other = 'b' if side == 'a' else 'a'
        deadline = time.monotonic() + timeout
        with self.condition:
            while (other, key) not in self.published:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Failure(f'side {other} never published {key!r}')
                self.condition.wait(remaining)
            return self.published[(other, key)]

    def sync(self, side, name, timeout=MEET_TIMEOUT):
        """A barrier of two. It returns when the second side arrives."""
        deadline = time.monotonic() + timeout
        with self.condition:
            self.arrived.setdefault(name, set()).add(side)
            self.condition.notify_all()
            while len(self.arrived[name]) < len(DEVICES):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Failure(f'side {side} waited for the barrier {name!r} alone')
                self.condition.wait(remaining)
        return name


# ------------------------------------------------------------ the rendezvous


class Rendezvous(threading.Thread):
    """Answers the requests one side's `VoiceCallUITests` writes.

    One of these runs per simulator, on that side's own directory, and both of
    them share the board above. The directory is the whole protocol, exactly as
    `test_sim_text.py` states it: `req-<n>` carries one verb and one base64
    argument, `ans-<n>` carries `ok [payload]` or `error <detail>`, and both are
    renamed into place so that neither side can read half a line.

    A handler here may block for minutes — `fetch`, `sync` and `hold` all do —
    and that is safe because the side whose thread it is, is itself blocked on
    the answer.
    """

    def __init__(self, side, directory, udid, evidence, board, database):
        super().__init__(daemon=True)
        self.side = side
        self.directory = directory
        self.udid = udid
        self.evidence = evidence
        self.board = board
        self.database = database
        self.answered = set()
        self.notes = {}
        self.stats = {}
        self.shots = []
        self.holds = []
        self.failure = None
        self._stop = threading.Event()
        self.verbs = {'shot': self._shot, 'note': self._note, 'copy': self._copy,
                      'publish': self._publish, 'fetch': self._fetch, 'sync': self._sync,
                      'hold': self._hold, 'stats': self._stats}

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
        return screenshot(self.udid, self.evidence, f'{self.side}-{name}', self.shots)

    def _note(self, argument):
        key, _, value = argument.partition(' ')
        require(re.fullmatch(r'[a-z0-9_]{1,48}', key), f'{key!r} is not a note')
        self.notes[key] = value
        return 'noted'

    def _copy(self, _):
        """The device's own pasteboard, which «Копировать контакт» just filled.

        It is read from the host, so no application reads a pasteboard it did
        not write and no paste alert is ever raised inside the simulator.
        """
        text = xcrun('simctl', 'pbpaste', self.udid).strip()
        require(text.startswith('{') and text.endswith('}'),
                'the pasteboard does not carry a contact')
        require(len(text) <= CONTACT_LIMIT, 'the contact is above the text-import bound')
        return text

    def _publish(self, argument):
        key, _, value = argument.partition(' ')
        require(re.fullmatch(r'[a-z_]{1,32}', key), f'{key!r} is not a published fact')
        require(value, f'{key!r} was published empty')
        if key in ('account', 'fingerprint'):
            require(ACCOUNT.match(value), f'{key!r} is not 64 hexadecimal digits')
        return self.board.publish(self.side, key, value)

    def _fetch(self, key):
        return self.board.fetch(self.side, key)

    def _sync(self, name):
        require(re.fullmatch(r'[a-z0-9-]{1,32}', name), f'{name!r} is not a barrier')
        return self.board.sync(self.side, name)

    def _hold(self, seconds):
        """Keeps a connected call up, and watches what the server stores.

        The heartbeat of a live call is one envelope every ten seconds from
        each side (`CallController.heartbeatMillis`), so what the cluster
        gained over this window is the measurement: the screen says the call
        survived, and the rows say what carried it.
        """
        held = int(seconds)
        require(0 < held <= 120, f'{seconds!r} is not a hold')
        before = self.database.by_sender()
        started = time.monotonic()
        number = len(self.board.holds) + 1
        # Both screens, mid-call, photographed at the same instant.
        for side, udid in sorted(self.board.udids.items()):
            screenshot(udid, self.evidence, f'{side}-{number}5-mid-call',
                       self.shots if side == self.side else self.board.shots)
        remaining = held - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)
        after = self.database.by_sender()
        record = {'seconds': held,
                  'envelopes_before': before,
                  'envelopes_after': after,
                  'stored_during_hold': {account: after[account] - before.get(account, 0)
                                         for account in after}}
        self.holds.append(record)
        self.board.holds.append(record)
        return held

    def _stats(self, label):
        """This side's media summary, as the application wrote it."""
        require(re.fullmatch(r'[a-z0-9-]{1,32}', label), f'{label!r} is not a reading')
        summary = read_diagnostics(self.directory / 'diagnostics.json')
        self.stats[label] = summary
        return ' '.join(f'{key}={value}' for key, value in sorted(summary.items()))


def screenshot(udid, evidence, name, collected):
    require(re.fullmatch(r'[0-9a-z-]{1,48}', name), f'{name!r} is not a screenshot name')
    path = evidence / f'{name}.png'
    xcrun('simctl', 'io', udid, 'screenshot', '--type=png', str(path))
    require(path.is_file() and path.stat().st_size > 0, f'{path} was not written')
    collected.append(path.name)
    return path.name


def read_diagnostics(path, attempts=20):
    """The `CallDiagnostics` file, which the application rewrites every second.

    It is written atomically, so a read can only fail by arriving between the
    write and the rename; a few attempts cover that without a lock.
    """
    for _ in range(attempts):
        try:
            summary = json.loads(path.read_text())
        except (OSError, ValueError):
            time.sleep(0.1)
            continue
        require(isinstance(summary, dict), 'the media summary is not an object')
        return summary
    raise Failure(f'the application wrote no media summary at {path.name}')


# -------------------------------------------------------------- the cluster


class CallDatabase(harness.Database):
    """The stand's cluster, asked the one question this run has for it."""

    def by_sender(self):
        """How many envelopes each account has stored, by its own account."""
        rows = self.query("SELECT coalesce(json_object_agg(sender, count), '{}'::json) FROM "
                          "(SELECT sender, count(*) AS count FROM ss_messages GROUP BY sender) s")
        return {account: int(count) for account, count in json.loads(rows).items()}


# ----------------------------------------------------------------- one side


def run_side(side, udid, directory, environment, results, keep_log):
    """One `xcodebuild test-without-building`, on one simulator."""
    argv = ['xcodebuild', 'test-without-building', '-project', str(PROJECT), '-scheme', SCHEME,
            '-derivedDataPath', str(derived_for(side)),
            '-destination', f'platform=iOS Simulator,id={udid}',
            f'-only-testing:{SUITE}']
    child_environment = dict(os.environ)
    child_environment.update({f'TEST_RUNNER_{key}': value
                              for key, value in environment.items()})
    child_environment['TEST_RUNNER_PARANOID_SIM_RENDEZVOUS'] = str(directory)
    child_environment['TEST_RUNNER_PARANOID_SIM_ROLE'] = side
    child_environment['TEST_RUNNER_PARANOID_SIM_DIAGNOSTICS'] = str(directory / 'diagnostics.json')
    log(f'{side}: {SUITE} on {DEVICES[side]}')
    with keep_log.open('w') as output:
        try:
            completed = subprocess.run(argv, cwd=ROOT, env=child_environment, stdout=output,
                                       stderr=output, check=False, timeout=RUN_TIMEOUT)
            results[side] = completed.returncode
        except subprocess.TimeoutExpired:
            results[side] = 'timeout'


# ------------------------------------------------------------------ evidence


ALLOWED_EVIDENCE = {
    'result', 'devices', 'runtime', 'bundle_id', 'server_binary', 'server_sha256',
    'core_slice_sha256', 'screenshots', 'calls', 'media', 'transport', 'screen_lock',
    'checks',
}

CHECKS = [
    'both simulators talk only to the local stand: -paranoid-realm/-paranoid-pin are passed on '
    'every launch and the stand guard is not shown',
    'both sides start from the clean install of D-004: xcrun simctl uninstall precedes the run on '
    'each simulator',
    'each side pairs the other by the fingerprint that side\'s own core published',
    'a call placed on one simulator rings on the other and both sides reach '
    'PeerConnectionState.connected',
    'the media carried RTP both ways: packetsReceived and packetsSent are above zero on both sides '
    'of both calls',
    'the stand starts no TURN, so the candidate pair that carried each call is a direct one and '
    'nothing was relayed',
    f'a connected call is held for {HOLD_SECONDS} s, which outlives the {SILENCE_SECONDS} s '
    'silence deadline, and the cluster stored the heartbeats that carried it',
    '«Завершить» ends the call on both sides',
    'the same call holds in the other direction',
]


def relative(path):
    """`path` as the repository sees it, never as this Mac does."""
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return resolved.name


def write_evidence(directory, payload, secrets):
    directory.mkdir(parents=True, exist_ok=True)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    for secret in secrets:
        require(secret and secret not in text,
                'evidence carries account, contact, fingerprint, realm or pin material')
    # Nothing of this Mac may travel either: the media summary is counters and
    # candidate kinds, and an address in it would be a bug in `CallDiagnostics`.
    require(not re.search(r'\b\d{1,3}(\.\d{1,3}){3}\b', text),
            'evidence carries an address of this machine')
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
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    build_application(args.skip_app_build)
    udids = {side: sim.simulator(DEVICES[side], RUNTIME) for side in DEVICES}
    require(len(set(udids.values())) == len(udids), 'both sides landed on one simulator')
    for side, udid in udids.items():
        log(f'{side}: {DEVICES[side]} ({udid})')
        # The clean install of D-004, and the one permission an unattended run
        # cannot be asked for by hand. Both are the simulator's, not the
        # application's: nothing of the client is relaxed here.
        xcrun('simctl', 'uninstall', udid, BUNDLE_ID)
        xcrun('simctl', 'privacy', udid, 'grant', 'microphone', BUNDLE_ID)

    stand_argv = ['--work-dir', str(OUT)]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    if args.pg_bin:
        stand_argv += ['--pg-bin', args.pg_bin]
    stand = local_stand.Stand(local_stand.parse_args(stand_argv))

    servers = {}
    results = {}
    directories = {}
    try:
        try:
            stand.start()
        except local_stand.StandError as error:
            raise CheckError(f'local stand: {error}')
        log(f'stand: {stand.descriptor["server_url"]} (log {stand.log_path})')
        database = CallDatabase(stand)
        board = Board(udids)
        common = {
            'PARANOID_SIM_REALM': stand.descriptor['server_url'],
            'PARANOID_SIM_PIN': stand.descriptor['tls_spki_sha256'],
        }
        threads = []
        for side, udid in udids.items():
            directory = OUT / f'rendezvous-voice-{side}'
            shutil.rmtree(directory, ignore_errors=True)
            directory.mkdir(parents=True)
            directory.chmod(0o755)
            directories[side] = directory
            servers[side] = Rendezvous(side, directory, udid, evidence, board, database)
            servers[side].start()
            threads.append(threading.Thread(
                target=run_side,
                args=(side, udid, directory, dict(common), results,
                      LOG_DIR / f'test-voice-sim-{side}.log'),
                daemon=True))
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=RUN_TIMEOUT + 120)
        for server in servers.values():
            server.stop()
            server.join(timeout=10)

        for side in sorted(servers):
            failure = servers[side].failure
            if failure is not None:
                raise Failure(f'{side}: the harness could not answer the test: {failure}')
        for side in sorted(udids):
            status = results.get(side)
            require(status is not None, f'{side}: the run never reported a status')
            if status != 0:
                raise Failure(f'{side}: xcodebuild test failed (exit {status}); see '
                              f'{LOG_DIR / f"test-voice-sim-{side}.log"}')

        payload = decide(servers, stand, board)
        secrets = sorted({stand.descriptor['server_url'], stand.descriptor['tls_spki_sha256']}
                         | {servers[side].notes.get('account', '') for side in servers}
                         | {value for server in servers.values()
                            for (_, key), value in server.board.published.items()
                            if key in ('account', 'fingerprint', 'contact')}
                         - {''})
        path = write_evidence(evidence, payload, secrets)
    finally:
        for server in servers.values():
            server.stop()
        if args.keep:
            for side, directory in directories.items():
                if directory.is_dir():
                    shutil.copytree(directory, evidence / f'rendezvous-{side}', dirs_exist_ok=True)
        else:
            for directory in directories.values():
                shutil.rmtree(directory, ignore_errors=True)
        stand.stop()
        # The simulators are shared with every other check on this Mac, and an
        # application left behind with an identity in it is a state the next one
        # did not ask for. A failure to clean up never replaces the failure that
        # is on its way out.
        for side, udid in udids.items():
            try:
                xcrun('simctl', 'uninstall', udid, BUNDLE_ID)
            except CheckError as error:
                log(f'{side}: the application could not be uninstalled: {error}')

    print('PASS: 2 calls, 2 simulators, direct ICE, {shots} screenshots'.format(
        shots=len(payload['screenshots'])), flush=True)
    for call in payload['calls']:
        print('{direction}: connected {connected}, held {held} s, '
              'packets received {received}'.format(
                  direction=call['direction'],
                  connected='/'.join(sorted(call['connected'])),
                  held=call['held_seconds'],
                  received=call['packets_received']), flush=True)
    print(f'screen lock during dialling: NOT RUN — {LOCK_NOT_RUN}', flush=True)
    print('Voice (two simulators, direct ICE): PASS', flush=True)
    print(f'evidence: {path}', flush=True)
    return 0


def decide(servers, stand, board):
    """What the two sides recorded, checked and turned into the evidence."""
    for side, server in servers.items():
        require(server.notes.get('flow') == 'complete',
                f'{side}: the scenario did not run to its end')
        require(ACCOUNT.match(server.notes.get('account', '')),
                f'{side}: no account was recorded')

    calls = []
    media = {}
    relayed = []
    for number, (caller, callee) in enumerate(DIRECTIONS, start=1):
        elapsed = {}
        received = {}
        sent = {}
        for side, role in ((caller, 'caller'), (callee, 'callee')):
            summary = servers[side].stats.get(f'held-{number}')
            require(summary is not None, f'{side}: no media summary of call {number}')
            require(summary.get('state') == 'connected',
                    f'{side}: call {number} was not connected when it was measured')
            received[side] = int(summary.get('audio_packets_received', 0))
            sent[side] = int(summary.get('audio_packets_sent', 0))
            require(received[side] > 0, f'{side}: no RTP reached it in call {number}')
            require(sent[side] > 0, f'{side}: it sent no RTP in call {number}')
            elapsed[side] = int(servers[side].notes.get(
                f'call{number}_{role}_elapsed', '0'))
            require(elapsed[side] > SILENCE_SECONDS,
                    f'{side}: call {number} lasted {elapsed[side]} s, which does not outlive the '
                    f'{SILENCE_SECONDS} s silence deadline')
            for end in ('local_candidate_type', 'remote_candidate_type'):
                kind = summary.get(end, '')
                if kind == 'relay':
                    relayed.append(f'{side}/{end}')
            media[f'{side}-call{number}'] = {
                key: value for key, value in summary.items()
                if key in ('state', 'samples', 'audio_packets_received', 'audio_bytes_received',
                           'audio_packets_sent', 'audio_bytes_sent', 'pair_packets_received',
                           'pair_packets_sent', 'pair_state', 'local_candidate_type',
                           'remote_candidate_type')}
        # The board's list, not the caller's: each side holds once, so a
        # per-side index would read the first hold twice.
        hold = board.holds[number - 1]
        stored = sorted(hold['stored_during_hold'].values(), reverse=True)
        require(len(stored) >= 2 and stored[1] >= HEARTBEATS_PER_HOLD,
                f'call {number}: the cluster stored {stored} envelopes over {HOLD_SECONDS} s, '
                f'below the {HEARTBEATS_PER_HOLD} heartbeats each side owes')
        calls.append({
            'direction': f'{caller}->{callee}',
            'caller': caller,
            'callee': callee,
            'connected': sorted([caller, callee]),
            'held_seconds': hold['seconds'],
            'elapsed_seconds': elapsed,
            'packets_received': received,
            'packets_sent': sent,
            'heartbeat_envelopes_per_side': stored,
        })
    require(not relayed, f'the media was relayed ({relayed}); the stand starts no TURN')

    shots = sorted({name for server in servers.values() for name in server.shots}
                   | set(board.shots))
    return {
        'result': 'PASS',
        'devices': {side: DEVICES[side] for side in sorted(DEVICES)},
        'runtime': RUNTIME_NAME,
        'bundle_id': BUNDLE_ID,
        # Relative to the repository: an absolute path would name this
        # machine's user, and the evidence travels into a pull request.
        'server_binary': relative(stand.server_binary),
        'server_sha256': digest(Path(stand.server_binary)),
        'core_slice_sha256': digest(harness.CORE_SLICE),
        'screenshots': shots,
        'calls': calls,
        'media': media,
        'transport': {'turn': 'none started by the stand; /v2/voice/turn answers 404 turn_disabled',
                      'mode': 'direct ICE',
                      'relayed_candidate_pairs': 0},
        'screen_lock': {'result': 'NOT RUN', 'reason': LOCK_NOT_RUN},
        'checks': CHECKS,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--evidence-dir',
                        help='where the JSON and the screenshots go; a relative path is resolved '
                             f'against clients/ios (default: {DEFAULT_EVIDENCE_DIR})')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='use this paranoid-server instead of building the working tree')
    parser.add_argument('--pg-bin', metavar='DIR',
                        help='PostgreSQL 16 bin directory (default: clients/ios/toolchain.json)')
    parser.add_argument('--skip-app-build', action='store_true',
                        help='reuse the application and test bundles already built into '
                             'out/DerivedData-voice-sim')
    parser.add_argument('--keep', action='store_true',
                        help='copy each side\'s rendezvous directory into the evidence directory')
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
