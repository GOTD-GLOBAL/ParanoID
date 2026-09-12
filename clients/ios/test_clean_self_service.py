#!/usr/bin/env python3
"""Clean-install text messaging of the iOS client against a local stand.

Nothing here is a mock. The client is the shipped Swift code — `SnapshotStore`
over a real file, `SelfServiceClient` over the real Rust core through
`ParanoidCore.xcframework`, `ProofFlow`, `StateOwner` and the two realtime
lanes over the pinned TLS stack — driven through the `service-bridge`
executable of `ParanoidKit`
(`clients/ios/ParanoidKit/Sources/service-bridge/main.swift`), which speaks the
line protocol of `clients/android/test/CleanSelfServiceBridge.java`. The server
is the **unchanged** binary built from the working tree, on a private
PostgreSQL 16 cluster and a throw-away TLS identity, started by
`clients/ios/local_stand.py`. The hosted server is never contacted and no phone
is touched.

One run does, in order:

1. `swift build --product service-bridge` (skipped with `--skip-build`);
2. `local_stand.py` brings up the server and the cluster on loopback;
3. one `service-bridge` process per synthetic phone is started with the stand's
   realm and pin and its own state directory in a temporary directory that is
   removed at the end — two of them for the messaging scenario, because a phone
   parked in a five-minute long poll cannot answer a line while it waits, and
   because two processes are two devices that share nothing but the server;
4. the scenario runs over those processes, with the cluster read through `psql`
   for what only the server side can show: stored ciphertext.

Scenarios are functions, one per protocol story:

`registration` (`--registration-only`)
    The `create` story of `clients/android/test_clean_self_service.py:106-110`:
    a phone with nothing on it creates an identity, registers with the stand
    and ends up with an active enrollment, contact material and a validated
    realtime session — and repeating both operations writes nothing.

`local-text` (the default)
    The messaging stories of `clients/android/test_clean_self_service.py`:
    one phone pairs the other's contact and writes to it, the receiver — which
    scanned nothing — shows the conversation as `network_unverified` and
    replies without pairing, both directions end up double-checked, and the
    server rows are ciphertext and nothing else. Then the failure stories that
    matter: an answer lost after the server committed the envelope (the exact
    retry keeps its sequence and adds no row), a blocked contact (the send is
    refused and an incoming message from it is acknowledged with nothing) and
    a storage fault on an incoming plaintext-and-receipt candidate (nothing is
    transmitted, the retained snapshot does not move, the client freezes).

`longpoll` (`--longpoll`, part of `local-text`)
    Five minutes of the real lanes, which is what crosses the server's
    eight-second idle header timeout, its 120-second absolute socket lifetime
    and the 240-second session renewal
    (`docs/protocol/realtime-v1.md:148-151,179-181`). It is off by default so
    that the ordinary run of this file stays under two minutes, and it is the
    last story the two phones act out: the storage fault that follows it
    freezes one of them for good, so nothing that needs a live pair of devices
    can come after it.

Usage:
  python3 clients/ios/test_clean_self_service.py --evidence-dir out/checks/local-text
  python3 clients/ios/test_clean_self_service.py --longpoll \\
      --evidence-dir out/checks/local-text
  python3 clients/ios/test_clean_self_service.py --registration-only \\
      --evidence-dir out/checks/registration

Exit status: 0 when the scenario holds, 1 when it does not, 2 when the run
could not decide (no Swift, no core xcframework, a stand that did not start).
Evidence is one JSON document with counts, digests and verdicts in it: no
account, no fingerprint, no message text, no snapshot bytes, no realm.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'out'
PACKAGE = HERE / 'ParanoidKit'
SCRATCH = OUT / 'spm'
XCFRAMEWORK = PACKAGE / 'Binaries/ParanoidCore.xcframework'
CORE_SLICE = XCFRAMEWORK / 'macos-arm64/libparanoid_ios_bridge.a'
LOG = OUT / 'logs/test-clean-self-service.log'
EVIDENCE = {'registration': 'registration-result.json', 'local-text': 'clean-fixture-result.json'}
DEFAULT_EVIDENCE_DIR = {'registration': 'out/checks/registration',
                        'local-text': 'out/checks/local-text'}
# The synthetic phones these scenarios need; `service-bridge` accepts the same
# five names as the Java fixture and no real telephone number.
PHONE = 'one'
PHONES = {'a': 'one', 'b': 'two'}
FINGERPRINT = re.compile(r'\A[0-9a-f]{64}\Z')
# `SnapshotStore.fileName`.
STATE_FILE = 'text-state.enc'
BRIDGE_TIMEOUT = 300
# The introduction frame every v2 envelope starts with
# (`clients/core/src/intro_v2.rs:120`).
FRAME2 = 2
# How long the realtime lanes run in one `longpoll`, and how many pages that
# run must have published. One event wait is at most twenty seconds
# (`docs/protocol/realtime-v1.md:97-99`), so a page every thirty-five seconds
# is a floor even with a dropped socket and a re-signed request between two of
# them — and a lane that stalled cannot reach it.
LONGPOLL_SECONDS = 300
LONGPOLL_PAGE_SECONDS = 35
# How long the peer's message and this device's receipt may take to cross
# during a long-poll run. The server notifies its waiters on every committed
# POST (`docs/protocol/realtime-v1.md:105-108`), so this is a ceiling on a
# failure, not an expected wait.
DELIVERY_TIMEOUT = 120
# How long one request of the harness is spaced from the next; see `Pacer`.
REQUEST_SPACING = 1.0
# Every table of the self-service schema (`server/self-service-schema.sql`).
TABLES = ('ss_meta', 'ss_accounts', 'ss_devices', 'ss_conversations', 'ss_messages')
# The messages this run sends. They are the only plaintext in it, which is what
# makes the `psql` scan meaningful: none of them may appear anywhere in the
# cluster. Quoted UI strings are the one place Russian belongs.
TEXTS = {
    'first': 'Первое сообщение',
    'reply': 'Ответ без сканирования',
    'retried': 'Потерянный ответ сервера',
    'polled': 'Во время долгого опроса',
    'blocked': 'Заблокированное',
    'lost': 'Несохранённое',
}

sys.path.insert(0, str(HERE))
import local_stand  # noqa: E402  (the path is set up right above)


class CheckError(Exception):
    """An environment problem: the run cannot decide anything (exit 2)."""


class Failure(Exception):
    """A rule of the protocol did not hold (exit 1)."""


def require(condition, message):
    if not condition:
        raise Failure(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ------------------------------------------------------------------ the bridge


def build_bridge(skip_build):
    """`swift build --product service-bridge`; returns the executable."""
    if not CORE_SLICE.is_file():
        raise CheckError(f'{CORE_SLICE} is missing; run bash clients/ios/build-core.sh first')
    if shutil.which('swift') is None:
        raise CheckError('swift not found; Xcode 26.6 with the pinned toolchain is required')
    common = ['swift', 'build', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH)]
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('w') as log:
        if not skip_build:
            built = subprocess.run(common + ['--product', 'service-bridge'],
                                   cwd=ROOT, stdout=log, stderr=log, check=False)
            if built.returncode != 0:
                raise CheckError(f'swift build failed (exit {built.returncode}); see {LOG}')
        shown = subprocess.run(common + ['--show-bin-path'], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=log, text=True, check=False)
    if shown.returncode != 0:
        raise CheckError(f'swift build --show-bin-path failed (exit {shown.returncode}); see {LOG}')
    binary = Path(shown.stdout.strip()) / 'service-bridge'
    if not binary.is_file():
        raise CheckError(f'{binary} was not built; drop --skip-build')
    return binary


class Pacer:
    """Keeps the harness itself under the stand's global ingress budget.

    The server allows twenty requests per second across every account, route
    and mode and answers 429 `alpha_rate_limit` above that
    (`server/src/main.rs:255-273`, "20 total requests/second" of
    `docs/protocol/realtime-v1.md:136-137`). One `sync` is two signed requests
    in steady state and seven while a phone registers — challenge and commit,
    `/health`, challenge and session, then the two lane operations — so a
    script that drives two devices as fast as it can write lines reaches a rate
    no user can. The client does handle that 429: the lanes publish
    `RealtimeStatus.busy` and back off (`Backoff`), and `ReceiveLane` answers a
    `waiter_busy` 429 by reading the inbox instead of queueing. Spacing the
    harness keeps this scenario's verdicts about the protocol rather than about
    that backoff, and the delay is the fixture's, never the client's.
    """

    def __init__(self, spacing):
        self.spacing = spacing
        self.last = 0.0

    def wait(self, weight=1):
        due = self.last + self.spacing * weight - time.monotonic()
        if due > 0:
            time.sleep(due)
        self.last = time.monotonic()


class Bridge:
    """One `service-bridge` process and the `<phone>\\t<op>\\t<base64>` protocol.

    `rpc` is one request and its answer, which is all a scenario needs until it
    has to keep a phone busy: `request` and `response` are the same exchange in
    two halves, so one device can be parked in a long poll while the other
    keeps talking to the same server.

    `weight` is how many requests the operation is about to make, for the
    shared `Pacer`; every device of one run shares one, because the budget the
    pacer respects is the server's and not an account's.
    """

    def __init__(self, name, binary, phones, realm, pin, pacer):
        self.name = name
        self.phones = phones
        self.pacer = pacer
        self.process = subprocess.Popen([str(binary), str(phones), realm, pin],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, bufsize=1)

    def request(self, phone, op, value='', weight=1):
        if self.process.poll() is not None:
            raise CheckError(f'{self.name}: service-bridge exited '
                             f'(status {self.process.returncode})')
        self.pacer.wait(weight)
        encoded = base64.b64encode(value.encode()).decode()
        self.process.stdin.write(f'{phone}\t{op}\t{encoded}\n')
        self.process.stdin.flush()

    def response(self, phone, op, expect_error=False):
        line = self.process.stdout.readline()
        if not line:
            raise CheckError(f'{self.name}: service-bridge closed its output')
        result = json.loads(base64.b64decode(line))
        if expect_error:
            require('error' in result, f'{phone}/{op}: expected a rejection, got a view')
        else:
            require('error' not in result,
                    f'{phone}/{op}: {result.get("error")}: {result.get("detail")}')
        return result

    def rpc(self, phone, op, value='', expect_error=False, weight=1):
        self.request(phone, op, value, weight=weight)
        return self.response(phone, op, expect_error=expect_error)

    def snapshot(self, phone):
        return self.phones / phone / STATE_FILE

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=BRIDGE_TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


# ---------------------------------------------------------------- the cluster


class Database:
    """Read-only `psql` against the stand's private cluster.

    It exists for the one thing no client can be asked about: what the server
    actually stored. Every row of `ss_messages` must be the exact frame-2
    ciphertext the sending core produced, and no plaintext this run sent may
    appear anywhere in the cluster.
    """

    ROWS = ("SELECT coalesce(json_agg(json_build_object("
            "'sequence',sequence,'sender',sender,'recipient',recipient,'id',message_id,"
            "'ciphertext',replace(encode(ciphertext,'base64'),E'\\n','')) ORDER BY sequence),"
            "'[]'::json) FROM ss_messages")

    def __init__(self, stand):
        self.psql = stand.pg_bin / 'psql'
        self.socket = stand.socket_dir
        self.env = stand.env

    def query(self, sql):
        completed = subprocess.run([str(self.psql), '-X', '-h', str(self.socket), '-d', 'postgres',
                                    '-At', '-c', sql],
                                   env=self.env, capture_output=True, text=True, check=False)
        if completed.returncode != 0:
            raise CheckError(f'psql failed (exit {completed.returncode}): '
                             f'{completed.stderr.strip()}')
        return completed.stdout.strip()

    def messages(self):
        """Every stored envelope, oldest first."""
        return json.loads(self.query(self.ROWS))

    def rows_carrying(self, needle):
        """How many rows of the whole schema carry `needle` as text or bytes.

        A `bytea` column renders as hexadecimal in `t::text`, so the ciphertext
        is searched for the UTF-8 bytes of the needle as well; between the two
        there is no column of this schema a plaintext could hide in.
        """
        require(not set(needle) & set("'%_\\"), f'{needle!r} is not a safe SQL literal')
        counts = [f"(SELECT count(*) FROM {table} t WHERE t::text LIKE '%{needle}%')"
                  for table in TABLES]
        counts.append("(SELECT count(*) FROM ss_messages "
                      f"WHERE position('\\x{needle.encode().hex()}'::bytea in ciphertext)>0)")
        return int(self.query('SELECT ' + '+'.join(counts)))

    def wait_for(self, rows, timeout):
        """Waits until the cluster holds at least `rows` envelopes."""
        deadline = time.monotonic() + timeout
        while True:
            stored = self.messages()
            if len(stored) >= rows:
                return stored
            if time.monotonic() >= deadline:
                raise Failure(f'only {len(stored)} of {rows} envelopes reached the server '
                              f'within {timeout} s')
            time.sleep(1)


# ------------------------------------------------------------ reading a view


def dialog(view, account):
    """The one conversation with `account`, or a failure."""
    matches = [entry for entry in view['dialogs'] if entry['account'] == account]
    require(len(matches) == 1,
            f'expected exactly one dialog with the peer; found {len(matches)}')
    return matches[0]


def texts(entry):
    return [message['text'] for message in entry['messages']]


def mine(entry):
    """The messages this device wrote (`dialogs[].own` is its own account)."""
    return [message for message in entry['messages'] if message['author'] == entry['own']]


# ---------------------------------------------------------------- the scenarios


def register(bridge, phone):
    """A phone with nothing on it becomes an enrolled, session-carrying device.

    It is the `create` story of `clients/android/test_clean_self_service.py`
    lines 106-110, with what the iOS connection cycle adds to it: on Android
    `sync()` registers, here `ProofFlow.connect()` does, and it goes on to
    discover the realtime capability and to open a session that the **core**
    accepts (`ProofFlow.connect()` returns `.session` only after
    `sign_session_v2` signed that session's context, `ProofFlow.swift:243-246`;
    a session minted for another identity, realm or account is refused there
    and never adopted).

    Every state transition is committed before it is used, so the commit
    counter is also a statement about ordering: two commits to have an identity
    and a clean schema, two more for the server's answer and the contact
    material, and none at all for anything that changed nothing.

    - Returns: the registered view, the enrollment and the facts about it.
    """
    snapshot = bridge.snapshot(phone)
    require(not snapshot.exists(), 'the phone directory is not clean')

    created = bridge.rpc(phone, 'create')
    require(created['identity'] and not created['active'],
            f'create must leave an unregistered identity: {created}')
    require(created['configured'] and created['dialogs'] == [], f'create left dialogs: {created}')
    require(created['contact_fingerprint'] == '',
            'contact material exists before the server answered')
    require(created['enrollment'] is None, 'an enrollment exists before registration')
    require(created['connection'] == 'none' and created['session'] is False,
            'create opened a connection')
    # `create_identity` and `upgrade_v2`, each its own candidate and its own
    # commit (`SelfServiceClient.swift` `createIdentity()`).
    require(created['commits'] == 2, f'create made {created["commits"]} commits, expected 2')
    require(snapshot.is_file(), 'the identity is not on disk')
    account = created['account']
    require(account, 'create produced no account')

    # Seven requests: challenge and commit, `/health`, challenge and session,
    # and the two operations of the first send-page-send cycle.
    registered = bridge.rpc(phone, 'sync', weight=7)
    require(registered['account'] == account, 'registration changed the account')
    require(registered['active'], f'the device is not enrolled: {registered}')
    enrollment = registered['enrollment']
    require(isinstance(enrollment, dict) and enrollment.get('mode') == 'active',
            f'enrollment.mode is not "active": {enrollment}')
    require(enrollment.get('account') == account, 'the enrollment names another account')
    require(enrollment.get('device'), 'the enrollment names no device')
    require(FINGERPRINT.match(str(enrollment.get('credential', ''))),
            'the enrolled credential is not a 64-digit fingerprint')
    fingerprint = registered['contact_fingerprint']
    require(FINGERPRINT.match(fingerprint),
            f'contact_fingerprint is not 64 lowercase hexadecimal digits: {fingerprint!r}')
    require(isinstance(registered['contact'], dict), 'there is no contact material')
    require(registered['dialogs'] == [], 'registration installed a dialog')
    require(registered['realtime'] is True, 'the stand did not offer the realtime capability')
    require(registered['connection'] == 'session' and registered['session'] is True,
            f'no session was issued: {registered["connection"]}')
    # `server_status_v2` and `prepare_contact_v2`; the session itself is
    # derived from the state and commits nothing, and the empty first page
    # commits nothing either.
    require(registered['commits'] == 4,
            f'registration made {registered["commits"] - 2} commits, expected 2')
    committed = digest(snapshot)

    repeated_create = bridge.rpc(phone, 'create')
    repeated_sync = bridge.rpc(phone, 'sync', weight=3)
    require(repeated_create['commits'] == 4 and repeated_sync['commits'] == 4,
            'a repeated create/sync wrote a snapshot that changed nothing')
    require(digest(snapshot) == committed, 'the retained snapshot changed on a repeated run')
    require(repeated_sync['account'] == account, 'the account moved')
    require(repeated_sync['contact_fingerprint'] == fingerprint, 'the contact material moved')
    require(repeated_sync['enrollment'] == enrollment, 'the enrollment moved')
    require(repeated_sync['connection'] == 'session' and repeated_sync['session'] is True,
            'the held session was not reused')

    facts = {
        'enrollment_mode': enrollment['mode'],
        'enrollment_members': sorted(enrollment),
        'contact_fingerprint_hex_digits': len(fingerprint),
        'commits': {'after_create': created['commits'],
                    'after_registration': registered['commits'],
                    'after_repeat': repeated_sync['commits']},
        'snapshot': {'bytes': snapshot.stat().st_size,
                     'sha256': committed,
                     'sha256_after_repeat': digest(snapshot),
                     'unchanged_by_repeat': digest(snapshot) == committed},
        'session': {'issued': True, 'validated_by_core': True,
                    'reused_on_repeat': True, 'realtime': True},
        'dialogs': 0,
    }
    secrets = {account, str(enrollment.get('device')), str(enrollment.get('credential')),
               fingerprint, json.dumps(registered['contact'], sort_keys=True),
               json.dumps(registered['request'], sort_keys=True),
               base64.b64encode(snapshot.read_bytes()).decode(),
               snapshot.read_bytes().hex()}
    return registered, facts, secrets


def scenario_registration(bridge):
    """The clean-install registration of one phone, and nothing else."""
    _, facts, secrets = register(bridge, PHONE)
    facts['checks'] = [
        'clean phone: create_identity and upgrade_v2 are two durable commits, identity not enrolled',
        'registration: enrollment.mode active, server status and contact material two more commits',
        'contact_fingerprint is 64 lowercase hexadecimal digits',
        'session issued and validated by the core before it is adopted',
        'repeated create/sync commit nothing and leave the snapshot byte for byte',
    ]
    return facts, sorted(secrets)


def scenario_local_text(alice, bob, database, seconds):
    """Two phones, their texts and receipts, and every failure story.

    The order below is the Android scenario's
    (`clients/android/test_clean_self_service.py:119-215`) reduced to two
    devices, and every step is checked on both sides and in the cluster:
    nothing is taken from the sender's own view alone.

    - Parameter seconds: how long the long-poll story runs, or `None` to leave
      that story out of this run (`--longpoll`).
    """
    a, b = PHONES['a'], PHONES['b']
    # Every text this run gets the server to commit. The receipts are counted
    # against it at the end, so the tally holds whether or not the long-poll
    # story ran.
    posted_texts = 0
    view_a, registration_a, secrets = register(alice, a)
    view_b, registration_b, more = register(bob, b)
    secrets = secrets | more
    account_a, account_b = view_a['account'], view_b['account']
    require(account_a != account_b, 'the two phones share an account')
    secrets |= set(TEXTS.values())

    # -- 1. only the sender scans; the receiver stays empty ---------------------
    paired = alice.rpc(a, 'pair', json.dumps(view_b['contact']))
    peer = dialog(paired, account_b)
    require(peer['trust'] == 'out_of_band_verified' and peer['identity_verified'],
            f'a scanned contact is not verified: {peer["trust"]}')
    require(peer['messages'] == [], 'pairing installed a message')
    require(bob.rpc(b, 'view')['dialogs'] == [],
            'the receiver has a contact before anything arrived')
    channel = peer['channel']

    # -- 2. the first text, frame 2 before the network -------------------------
    queued = alice.rpc(a, 'send', json.dumps({'account': account_b, 'text': TEXTS['first']}))
    entry = dialog(queued, account_b)['messages']
    require(len(entry) == 1 and not entry[0]['accepted'] and not entry[0]['delivered'],
            f'an enqueued text is already acknowledged: {entry}')
    outbox = alice.rpc(a, 'pending')['pending']
    require(len(outbox) == 1, f'the outbox holds {len(outbox)} envelopes, expected 1')
    first = outbox[0]
    require(base64.b64decode(first['ciphertext'])[0] == FRAME2,
            'a queued envelope is not frame 2 before it reaches the network')

    sent = alice.rpc(a, 'sync')
    posted_texts += 1
    mark = dialog(sent, account_b)['messages'][0]
    require(mark['accepted'], 'the server acceptance did not commit')
    require(not mark['delivered'], 'a message is double-checked before any receipt arrived')
    require(alice.rpc(a, 'pending')['pending'] == [], 'the accepted envelope stayed in the outbox')
    rows = database.messages()
    require(len(rows) == 1, f'the cluster holds {len(rows)} envelopes, expected 1')
    require(rows[0]['sender'] == account_a and rows[0]['recipient'] == account_b,
            'the stored envelope names another pair of accounts')
    require(rows[0]['ciphertext'] == first['ciphertext'],
            'the stored bytes are not the bytes the core signed')

    # -- 3. the receiver scanned nothing and answers anyway --------------------
    received = bob.rpc(b, 'sync')
    theirs = dialog(received, account_a)
    require(texts(theirs) == [TEXTS['first']], 'the first contact did not arrive as one message')
    require(theirs['trust'] == 'network_unverified' and not theirs['identity_verified'],
            f'an unscanned peer is not network_unverified: {theirs["trust"]}')
    require(not theirs['blocked'], 'a first contact arrived blocked')
    require(theirs['channel'] == channel, 'the two devices derived different channels')
    require(bob.rpc(b, 'pending')['pending'] == [],
            'the receipt did not leave the device in the cycle that queued it')
    rows = database.messages()
    require(len(rows) == 2 and rows[1]['sender'] == account_b,
            'the receipt of the first text is not on the server')

    marked = alice.rpc(a, 'sync')
    require(dialog(marked, account_b)['messages'][0]['delivered'],
            'the receipt did not double-check the message it acknowledges')

    bob.rpc(b, 'send', json.dumps({'account': account_a, 'text': TEXTS['reply']}))
    bob.rpc(b, 'sync')
    posted_texts += 1
    answered = alice.rpc(a, 'sync')
    require(texts(dialog(answered, account_b)) == [TEXTS['first'], TEXTS['reply']],
            'the unverified reply did not arrive')
    replied = bob.rpc(b, 'sync')
    require([message['delivered'] for message in mine(dialog(replied, account_a))] == [True],
            'the reply was never double-checked')

    # -- 4. the answer the caller lost after the server committed --------------
    alice.rpc(a, 'send', json.dumps({'account': account_b, 'text': TEXTS['retried']}))
    outbox = alice.rpc(a, 'pending')['pending']
    require(len(outbox) == 1, 'the outbox does not hold exactly the text to lose the answer to')
    lost = outbox[0]
    alice.rpc(a, 'post_without_accept')
    posted_texts += 1
    committed = {row['id']: row for row in database.messages()}
    require(lost['id'] in committed, 'the server did not commit the envelope whose answer was lost')
    require(committed[lost['id']]['ciphertext'] == lost['ciphertext'],
            'the committed bytes are not the bytes the core signed')
    require(alice.rpc(a, 'pending')['pending'] == [lost],
            'the lost answer changed the queued envelope')
    retried = alice.rpc(a, 'sync')
    again = {row['id']: row for row in database.messages()}
    require(len(again) == len(committed), 'the exact retry duplicated a server row')
    require(again[lost['id']]['sequence'] == committed[lost['id']]['sequence'],
            'the exact retry moved the sequence of the row it repeats')
    require(again[lost['id']]['ciphertext'] == committed[lost['id']]['ciphertext'],
            'the exact retry rewrote the stored ciphertext')
    require(dialog(retried, account_b)['messages'][-1]['accepted'],
            'the repeated envelope was not acknowledged locally')
    bob.rpc(b, 'sync')
    acknowledged = alice.rpc(a, 'sync')
    require(dialog(acknowledged, account_b)['messages'][-1]['delivered'],
            'the repeated text was never double-checked')

    # -- 5. a blocked contact -------------------------------------------------
    before_block = dialog(alice.rpc(a, 'view'), account_b)
    alice.rpc(a, 'block', json.dumps({'account': account_b, 'blocked': True}))
    refused = alice.rpc(a, 'send', json.dumps({'account': account_b, 'text': TEXTS['blocked']}),
                        expect_error=True)
    require(refused['error'] == 'CoreError' and refused['detail'] == 'contact_blocked',
            f'sending to a blocked contact was not refused as contact_blocked: {refused}')
    bob.rpc(b, 'send', json.dumps({'account': account_a, 'text': TEXTS['blocked']}))
    bob.rpc(b, 'sync')
    posted_texts += 1
    before_rows = database.messages()
    suppressed = alice.rpc(a, 'sync')
    require(suppressed['rejected_count'] == 1,
            f'the blocked message was not refused once: {suppressed["rejected_count"]}')
    require(texts(dialog(suppressed, account_b)) == texts(before_block),
            'a message from a blocked contact reached the conversation')
    require(len(database.messages()) == len(before_rows),
            'a message from a blocked contact produced a receipt')
    unaware = bob.rpc(b, 'sync')
    blocked = [message for message in mine(dialog(unaware, account_a))
               if message['text'] == TEXTS['blocked']]
    require(len(blocked) == 1 and blocked[0]['accepted'] and not blocked[0]['delivered'],
            f'the blocked message is not accepted-but-undelivered: {blocked}')
    alice.rpc(a, 'block', json.dumps({'account': account_b, 'blocked': False}))
    require(dialog(alice.rpc(a, 'view'), account_b)['channel'] == channel,
            'block and unblock moved the channel')

    # -- 6. the real lanes, for as long as this run asks ----------------------
    # Last of the stories the two live phones act out, and the only one this
    # file leaves out by default: it costs `seconds` of wall clock, and the
    # storage fault below freezes one of the two devices for good.
    if seconds is None:
        longpoll = {'run': False, 'requested_seconds': None}
    else:
        posted = len(database.messages())
        alice.request(a, 'longpoll', json.dumps({'seconds': seconds}))
        # The other process keeps working while that one waits: this is why the
        # scenario needs two of them.
        bob.rpc(b, 'send', json.dumps({'account': account_a, 'text': TEXTS['polled']}))
        bob.rpc(b, 'sync')
        posted_texts += 1
        database.wait_for(posted + 2, DELIVERY_TIMEOUT)
        polled = alice.response(a, 'longpoll')
        measured = polled['longpoll']
        require(measured['seconds'] >= seconds,
                f'the lanes ran {measured["seconds"]} s of the requested {seconds} s')
        require(measured['offline'] == 0 and measured['offline_statuses'] == [],
                f'the lanes reported {measured["offline"]} failures: '
                f'{measured["offline_statuses"]}')
        require(measured['authorization_lost'] == 0,
                'the lanes lost authorization during the run')
        pages = max(1, seconds // LONGPOLL_PAGE_SECONDS)
        require(measured['online'] >= pages,
                f'the lanes published {measured["online"]} pages, '
                f'expected at least {pages} in {seconds} s')
        require(measured['superseded'] is True,
                'stopping the lanes did not supersede their generation')
        require(measured['session_held'] is True, 'the run ended without a session')
        require(texts(dialog(polled, account_b))[-1] == TEXTS['polled'],
                'the message sent during the run did not arrive through the long poll')
        require(alice.rpc(a, 'pending')['pending'] == [],
                'the receipt of that message did not leave the device during the run')
        reading = bob.rpc(b, 'sync')
        checked = [message for message in mine(dialog(reading, account_a))
                   if message['text'] == TEXTS['polled']]
        require(len(checked) == 1 and checked[0]['accepted'] and checked[0]['delivered'],
                f'the message sent during the run was never double-checked: {checked}')
        longpoll = {'run': True,
                    'requested_seconds': seconds, 'measured_seconds': measured['seconds'],
                    'online_publications': measured['online'],
                    'offline_publications': measured['offline'],
                    'offline_statuses': measured['offline_statuses'],
                    'authorization_lost': measured['authorization_lost'],
                    'session_held': measured['session_held'],
                    'session_renewed': measured['session_renewed'],
                    # The documented server bounds this run spans, so the
                    # measurement above can be read against them.
                    'server_idle_header_timeout_seconds': 8,
                    'server_socket_lifetime_seconds': 120,
                    'session_renewal_seconds': 240,
                    'delivered_during_the_run': 1, 'receipt_sent_during_the_run': True}

    # -- 7. the storage fault -------------------------------------------------
    bob.rpc(b, 'send', json.dumps({'account': account_a, 'text': TEXTS['lost']}))
    bob.rpc(b, 'sync')
    posted_texts += 1
    final_a = alice.rpc(a, 'view')
    before_rows = database.messages()
    before_snapshot = digest(alice.snapshot(a))
    alice.rpc(a, 'fail_next_commit')
    failed = alice.rpc(a, 'sync', expect_error=True)
    require(failed['detail'] == 'local commit failed',
            f'the injected fault was not reported as a failed commit: {failed}')
    require(digest(alice.snapshot(a)) == before_snapshot,
            'the failed commit changed the retained snapshot')
    require(database.messages() == before_rows,
            'the candidate that failed to commit transmitted bytes')
    frozen = alice.rpc(a, 'view', expect_error=True)
    require(frozen['error'] == 'SelfServiceError' and frozen['detail'] == 'local state frozen',
            f'the client did not freeze after the failed commit: {frozen}')

    # -- 8. what the cluster holds --------------------------------------------
    final_b = bob.rpc(b, 'view')
    rows = database.messages()
    frame2 = 0
    for row in rows:
        if base64.b64decode(row['ciphertext'])[0] == FRAME2:
            frame2 += 1
        require(row['sender'] in (account_a, account_b)
                and row['recipient'] in (account_a, account_b),
                'the cluster holds an envelope of another account')
    require(frame2 == len(rows),
            f'{len(rows) - frame2} of {len(rows)} stored envelopes are not frame 2')
    plaintext = {text: database.rows_carrying(text) for text in TEXTS.values()}
    leaked = sum(plaintext.values())
    require(leaked == 0, f'{leaked} rows of the cluster carry plaintext this run sent')

    delivered_a = [message for message in mine(dialog(final_a, account_b)) if message['delivered']]
    delivered_b = [message for message in mine(dialog(final_b, account_a)) if message['delivered']]
    delivered = len(delivered_a) + len(delivered_b)
    # Every text but two is double-checked: the one the recipient blocked and
    # the one whose receipt the storage fault took down with it.
    expected = posted_texts - 2
    require(delivered == expected,
            f'{delivered} messages were double-checked, expected {expected}')
    # Everything on the server that is not one of those texts is a receipt,
    # one per double check.
    receipts = len(rows) - posted_texts
    require(receipts == delivered,
            f'{len(rows)} stored envelopes are {posted_texts} texts and {receipts} '
            f'receipts, but {delivered} messages are double-checked')

    facts = {
        'phones': 2,
        'registration': {'a': registration_a, 'b': registration_b},
        'messages': {'texts_posted': posted_texts,
                     'texts_double_checked': delivered, 'receipts': receipts,
                     'texts_refused_by_the_recipient': 1,
                     'texts_lost_to_the_storage_fault': 1},
        'server_state': {'envelopes': len(rows), 'frame2': frame2,
                         'plaintext_rows': leaked,
                         'tables_scanned': list(TABLES),
                         'stored_bytes_are_the_signed_bytes': True},
        'lost_answer': {'rows_added_by_the_exact_retry': 0, 'sequence_unchanged': True},
        'blocked_contact': {'send_refused_as': refused['detail'],
                            'rejected_count': suppressed['rejected_count'],
                            'receipts_added': 0, 'channel_unchanged': True},
        'storage_fault': {'snapshot_sha256_unchanged': True, 'envelopes_added': 0,
                          'frozen': True, 'reported_as': failed['detail']},
        'longpoll': longpoll,
        'checks': [
            'two clean phones register themselves, each with four durable commits and a session',
            'only the sender scans: the receiver shows the conversation as network_unverified '
            'and replies without pairing',
            'both directions end double-checked, and one check never precedes the acceptance',
            'every stored envelope is frame 2 and byte for byte what the core signed',
            'no plaintext this run sent appears in any table of the cluster',
            'an answer lost after the server committed: the exact retry keeps the sequence '
            'and adds no row',
            'a blocked contact: the send is refused as contact_blocked and an incoming message '
            'is acknowledged with nothing',
            f'{seconds} s of the real lanes across the eight-second idle header timeout and '
            'the 120-second socket lifetime: no failure published, the page kept arriving, and '
            'a message sent during the run was delivered and acknowledged'
            if seconds is not None else
            'the long-poll story was not part of this run (--longpoll)',
            'a storage fault on an incoming plaintext-and-receipt candidate transmits nothing, '
            'leaves the snapshot byte for byte and freezes the client',
        ],
    }
    return facts, sorted(secrets)


# ------------------------------------------------------------------- evidence


ALLOWED_EVIDENCE = {
    'result', 'scenario', 'boundary', 'server_binary', 'server_sha256', 'core_slice_sha256',
    'bridge', 'enrollment_mode', 'enrollment_members', 'contact_fingerprint_hex_digits',
    'commits', 'snapshot', 'session', 'dialogs', 'checks',
    'phones', 'registration', 'messages', 'server_state', 'lost_answer', 'blocked_contact',
    'storage_fault', 'longpoll',
}
BOUNDARY = ('local stand only: unchanged server binary, private PostgreSQL 16, '
            'throw-away loopback TLS; no hosted server, no phone, no live action')
BRIDGES = {
    'registration': 'ParanoidKit service-bridge over SelfServiceClient, SnapshotStore, '
                    'ProofFlow and RealtimeTransport',
    'local-text': 'two ParanoidKit service-bridge processes over SelfServiceClient, '
                  'SnapshotStore, StateOwner, ProofFlow, ReceiveLane and SendLane',
}


def write_evidence(directory, scenario, facts, secrets, server_binary):
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        'result': 'PASS',
        'scenario': scenario,
        'boundary': BOUNDARY,
        'server_binary': str(server_binary),
        'server_sha256': digest(server_binary),
        'core_slice_sha256': digest(CORE_SLICE),
        'bridge': BRIDGES[scenario],
    }
    payload.update(facts)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True) + '\n'
    for secret in secrets:
        require(secret and secret not in text,
                'evidence carries account, contact, message or snapshot material')
    path = directory / EVIDENCE[scenario]
    path.write_text(text)
    return path


# ------------------------------------------------------------------------ run


def run(args):
    os.umask(0o077)
    scenario = 'registration' if args.registration_only else 'local-text'
    evidence = Path(args.evidence_dir or DEFAULT_EVIDENCE_DIR[scenario])
    if not evidence.is_absolute():
        evidence = HERE / evidence
    seconds = args.longpoll_seconds if args.longpoll else None
    binary = build_bridge(args.skip_build)

    stand_argv = ['--work-dir', str(OUT)]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    stand = local_stand.Stand(local_stand.parse_args(stand_argv))
    pacer = Pacer(REQUEST_SPACING)
    bridges = []
    with tempfile.TemporaryDirectory(prefix='paranoid-ios-clean-') as temporary:
        devices = Path(temporary)
        try:
            try:
                stand.start()
            except local_stand.StandError as error:
                raise CheckError(f'local stand: {error}')
            print(f'stand: {stand.descriptor["server_url"]} (log {stand.log_path})', flush=True)

            def device(name):
                bridge = Bridge(name, binary, devices / name, stand.descriptor['server_url'],
                                stand.descriptor['tls_spki_sha256'], pacer)
                bridges.append(bridge)
                return bridge

            if scenario == 'registration':
                facts, secrets = scenario_registration(device('device-a'))
            else:
                facts, secrets = scenario_local_text(device('device-a'), device('device-b'),
                                                     Database(stand), seconds)
            secrets = secrets + [stand.descriptor['tls_spki_sha256'],
                                 stand.descriptor['server_url']]
            path = write_evidence(evidence, scenario, facts, secrets, Path(stand.server_binary))
        finally:
            for bridge in bridges:
                bridge.close()
            stand.stop()
    if scenario == 'registration':
        print('PASS clean-install registration on the local stand: '
              + '; '.join(facts['checks']), flush=True)
    else:
        print('PASS: {phones} phones, {texts} texts, {receipts} receipts, '
              '{plaintext} plaintext rows, {longpoll}'.format(
                  phones=facts['phones'],
                  texts=facts['messages']['texts_double_checked'],
                  receipts=facts['messages']['receipts'],
                  plaintext=facts['server_state']['plaintext_rows'],
                  longpoll=f'longpoll {seconds} s OK' if seconds is not None
                  else 'longpoll skipped (--longpoll)'), flush=True)
        print('checks: ' + '; '.join(facts['checks']), flush=True)
    print(f'evidence: {path}', flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--registration-only', action='store_true',
                        help='the clean-install registration scenario alone, on one phone')
    parser.add_argument('--evidence-dir',
                        help='where the evidence JSON goes; a relative path is resolved '
                             'against clients/ios (default: out/checks/local-text, or '
                             'out/checks/registration with --registration-only)')
    parser.add_argument('--longpoll', action='store_true',
                        help='also run the long-poll story, the last and slowest one: the real '
                             'lanes across the server socket lifetime and the session renewal '
                             f'(default: left out, so an ordinary run does not cost '
                             f'{LONGPOLL_SECONDS} s)')
    parser.add_argument('--longpoll-seconds', type=int, default=LONGPOLL_SECONDS,
                        help=f'how long the realtime lanes run under --longpoll (default '
                             f'{LONGPOLL_SECONDS}; the documented check uses the default)')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='use this paranoid-server instead of building the working tree')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse the service-bridge executable already built')
    args = parser.parse_args(argv)
    if not 0 <= args.longpoll_seconds <= 1800:
        parser.error('--longpoll-seconds must be 0..1800')
    if args.registration_only and args.longpoll:
        parser.error('--longpoll belongs to the local-text scenario, not to --registration-only')
    try:
        return run(args)
    except Failure as failure:
        print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    except CheckError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
