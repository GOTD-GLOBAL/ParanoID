#!/usr/bin/env python3
"""The iOS realtime lanes under bounded synthetic network faults.

Nothing here is a mock. The client is the shipped Swift code — `StateOwner`
over `SelfServiceClient` and the real Rust core, `SnapshotStore`, `ProofFlow`,
`SessionCall` and the two lanes over the pinned TLS stack — driven through the
`service-bridge` executable of `ParanoidKit` with its lanes **running**
(`start` / `stop` / `kick`, the operations of
`clients/android/test/RealtimeBridge.java:75-78`). The server is the
**unchanged** binary on a private PostgreSQL 16 cluster started by
`clients/ios/local_stand.py`, and between the two stands `FaultProxy`, which
is **imported** from `clients/android/test_realtime.py` and never copied: it is
a verified-TLS forwarder that can block one sender's POST, drop an answer the
server already committed, or replay a consumed authorization so that the
backend itself returns a genuine 401.

Because that class hard-codes port 38443 for both its front and its back
address (`clients/android/test_realtime.py:103,182,253`), the stand needs two
addresses of this Mac: the certificate, the realm and the pin name the front
address the client dials (127.0.0.22), and the server binds the back address
(127.0.0.23). Both are `lo0` aliases and the user adds them once:

    sudo ifconfig lo0 alias 127.0.0.22 up
    sudo ifconfig lo0 alias 127.0.0.23 up

Without them nothing is faked: the run prints `NOT RUN: lo0 alias missing` and
records that reason in the evidence. The realm is therefore a literal IPv4
origin, `https://127.0.0.22:38443`, and the hosted server is never contacted.

The stand, the executable builder, the `<phone>\\t<op>\\t<base64>` client and
the `psql` reader are `test_clean_self_service.py`'s and are imported from it,
so both fixtures drive the same tool the same way and only the stories differ.

One run does, in order:

1. `swift build --product service-bridge` (skipped with `--skip-build`; the
   build log is the shared `out/logs/test-clean-self-service.log`);
2. the stand: the unchanged server on the back address, the private cluster,
   and a throw-away identity issued for the front address;
3. `FaultProxy` on the front address, and one `service-bridge` process whose
   three synthetic phones share that one proxy, exactly as the Java fixture's
   peers share one JVM — which is what makes the monotonic instants of two
   phones comparable;
4. the scenarios, each one a protocol story:

`blocked receipt`
    The receiver's receipt POST is held on the wire while the message it
    acknowledges is already durable: the publication precedes the receipt
    (`docs/protocol/realtime-v1.md:97-99`), the sender sees no delivery mark,
    the server holds no receipt row, and the state owner of the blocked phone
    still answers a local send in a few milliseconds.

`latency`
    24 warm foreground samples, alternating direction: from the instant the
    sending phone was handed the text to the instant the receiving phone
    published it out of its **durable** snapshot. P50 ≤ 500 ms and
    P95 ≤ 1500 ms.

`lost answer` (`drop_sender`)
    The server commits an envelope and the answer never arrives. The one
    identical repeat of `RealtimeTransport.send` meets a genuine 401 (the nonce
    was consumed), `SessionCall` re-signs once, and the row keeps its
    `sequence`: the same bytes, no duplicate, no authority lost.

`consumed nonce` (`consume_401_sender`)
    The proxy replays the exact authorization the backend already consumed, so
    the 401 is the server's own. One retry with a freshly signed nonce carries
    the unchanged ciphertext through, and no `authorizationLost` is published.

`rolled session` (`before_session_challenge`)
    At the genuine session-open boundary of a fresh phone the server is rolled:
    the same binary is stopped and started again on the same data, with no
    database reset and no client restart. The in-memory sessions
    (`server/src/self_service_http.rs:28`) are gone, so every established phone
    meets a real 401 twice, drops the session, rediscovers the capability
    (`docs/protocol/realtime-v1.md:172-177`) and opens a new one, while the
    fresh phone registers across the boundary and its first message crosses
    with its receipt.

Usage:
  python3 clients/ios/test_realtime.py --evidence-dir out/checks/realtime
  python3 clients/ios/test_realtime.py --pg-bin /opt/homebrew/opt/postgresql@16/bin \\
      --evidence-dir out/checks/realtime

Exit status: 0 when every scenario holds, 1 when one does not, 2 when the run
could not decide (no Swift, no core xcframework, no `lo0` alias, a stand that
did not start). The evidence is one JSON document of counts, digests and
verdicts beside the proxy's own request timings: no account, no fingerprint,
no realm, no pin, no message text and no snapshot bytes.
"""
import argparse
import base64
import http.client
import ipaddress
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ANDROID = ROOT / 'clients/android'
ANDROID_FIXTURE = ANDROID / 'test_realtime.py'
OUT = HERE / 'out'
DEFAULT_EVIDENCE_DIR = 'out/checks/realtime'
RESULT = 'realtime-fixture-result.json'
TIMINGS = 'network-timings.json'
SAMPLES = 'latency-samples.json'

# The two addresses the front/back split needs. `FaultProxy` listens on the
# front one and dials the back one, both on 38443, because that port is
# hard-coded in it (`clients/android/test_realtime.py:103,182,253`).
FRONT_IP = '127.0.0.22'
BACK_IP = '127.0.0.23'
PROXY_PORT = 38443
# The synthetic phones of this run; `service-bridge` accepts the same five
# names as the Java fixture and no real telephone number. `three` is the one
# that opens a session across the server roll.
PHONES = ('one', 'two', 'three')
# How long one line of the protocol may take to come back. The point of the
# bound is the assertion itself: a state-owner command that waits behind
# another lane's network is the defect this fixture exists to catch.
RPC_TIMEOUT = 8
# How long a local command may spend on the state owner while another lane's
# I/O is blocked (`clients/android/test_realtime.py:423`).
OWNER_BUDGET_MS = 1500
# How long a message, a receipt or a registration may take. The server notifies
# its waiters on every committed POST (`docs/protocol/realtime-v1.md:105-108`),
# so these are ceilings on a failure and not expected waits.
DELIVERY_TIMEOUT = 40
REGISTRATION_TIMEOUT = 60
RECOVERY_TIMEOUT = 90
# How long the receipt of the blocked phone may take to reach the wire. The
# proxy itself refuses to hold it for more than ten seconds
# (`clients/android/test_realtime.py:99`), and the client's own bound on a POST
# is eight (`RealtimeTransport.readTimeout`), so the block is released as soon
# as the assertions are made.
BLOCKED_TIMEOUT = 10
# The warm foreground measurement and its targets.
LATENCY_SAMPLES = 24
SAMPLE_PACING = 0.25
TARGET_P50_MS = 500
TARGET_P95_MS = 1500
# The introduction frame every v2 envelope starts with
# (`clients/core/src/intro_v2.rs:120`).
FRAME2 = 2
# The texts this run sends. They are the only plaintext in it, which is what
# makes the `psql` scan meaningful: none of them may appear anywhere in the
# cluster. They are synthetic identifiers, not UI strings.
FIRST = 'synthetic-first-contact'
REPLY = 'synthetic-reply-while-receipt-blocked'
LOST = 'synthetic-lost-acceptance'
CONSUMED = 'synthetic-consumed-nonce-recovery'
ROLLED = 'synthetic-session-open-roll'

sys.path.insert(0, str(HERE))
import local_stand  # noqa: E402  (the path is set up right above)
import test_clean_self_service as harness  # noqa: E402

CheckError = harness.CheckError
Failure = harness.Failure
require = harness.require
digest = harness.digest

# `FaultProxy` is imported from the Android fixture and never copied, so the
# faults this run injects are the ones the Android client was measured under.
# That module is named `test_realtime` as well, so its directory goes in front
# of this one on the path for the import and comes straight back off; the file
# that was actually imported is then checked, because a copy of this file
# imported under that name would otherwise answer instead. The module has a
# `__main__` guard, so importing it runs nothing.
sys.path.insert(0, str(ANDROID))
try:
    import test_realtime as android_realtime  # noqa: E402
finally:
    sys.path.remove(str(ANDROID))
if Path(android_realtime.__file__).resolve() != ANDROID_FIXTURE:
    print(f'ERROR: imported {android_realtime.__file__} instead of {ANDROID_FIXTURE}',
          file=sys.stderr)
    sys.exit(2)
FaultProxy = android_realtime.FaultProxy


class NotRun(Exception):
    """The environment cannot carry the run; the reason is recorded (exit 2)."""


# ------------------------------------------------------------------- the stand


class ProxiedStand(local_stand.Stand):
    """`local_stand.Stand` whose identity names the fault proxy.

    Everything about the stand is the shipped one — the unchanged server
    binary, the private cluster on a Unix socket, `create-test-tls.py` — and one
    thing differs: the certificate, the realm and the pin are issued for the
    **front** address the client dials, while the server binds the **back**
    address. That is the split of `clients/android/test_realtime.py:248-253`,
    and it is what lets a proxy stand on the realm the client has pinned
    without the server ever seeing a second identity.
    """

    def __init__(self, args, front):
        super().__init__(args)
        self.front = front

    def create_tls(self, port):
        """The identity is issued for the front address, not for the bind."""
        back, self.bind_ip = self.bind_ip, self.front
        try:
            super().create_tls(port)
        finally:
            self.bind_ip = back

    def start_server(self):
        """Starts the server and waits for `/health` over the back socket.

        The proxy is not listening yet, so the realm itself cannot be dialled;
        the front certificate and its chain are still verified in full, over a
        socket opened to the back address. It is the connection
        `clients/android/test_realtime.py:103-104` makes, for the same reason.
        """
        local_stand.log_line(f'starting {self.server_binary.name} ({local_stand.MODE})')
        self.server = subprocess.Popen([str(self.server_binary)], env=self.env,
                                       stdout=self.log, stderr=self.log)
        context = ssl.create_default_context(cafile=self.descriptor['tls_cert'])
        for _ in range(200):
            if self.server.poll() is not None:
                raise local_stand.StandError(
                    f'server exited before readiness (exit {self.server.returncode}); see the log')
            try:
                body = self.health(context)
            except (OSError, ValueError):
                time.sleep(0.05)
                continue
            if body != local_stand.HEALTH:
                raise local_stand.StandError(f'unexpected /health body: {body}')
            return
        raise local_stand.StandError('server did not answer /health within 10 s; see the log')

    def health(self, context):
        """`GET /health` on the back socket, authenticating the front identity."""
        connection = http.client.HTTPSConnection(str(self.front), PROXY_PORT,
                                                 context=context, timeout=2)
        back = (str(self.bind_ip), PROXY_PORT)
        connection._create_connection = (
            lambda address, timeout, source_address=None:
            socket.create_connection(back, timeout, source_address))
        try:
            connection.request('GET', '/health')
            return json.loads(connection.getresponse().read(4096))
        finally:
            connection.close()

    def roll(self):
        """Stops the server and starts the same binary again on the same data.

        No database reset, no new identity and no client restart: what the
        clients lose is the server's in-memory session table
        (`server/src/self_service_http.rs:28`), which is exactly the authority
        boundary this fixture wants them to cross.
        """
        self.stop_process('server', self.server, signal.SIGTERM, 10)
        self.server = None
        self.start_server()


def reserve(address):
    """Whether `address:38443` can be bound on this Mac right now."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind((address, PROXY_PORT))
    except OSError:
        return False
    return True


def addresses():
    """The front and back address, or a `NotRun` naming what is missing."""
    missing = [address for address in (FRONT_IP, BACK_IP) if not reserve(address)]
    if missing:
        raise NotRun(f'lo0 alias missing: {", ".join(missing)}:{PROXY_PORT} cannot be bound '
                     '(sudo ifconfig lo0 alias <address> up, and nothing else may hold that '
                     'port); nothing is faked')
    return FRONT_IP, BACK_IP


# ------------------------------------------------------------------ the phones


class Peers(harness.Bridge):
    """One `service-bridge` process, with a bounded wait for every answer.

    `Bridge` already speaks the `<phone>\\t<op>\\t<base64>` protocol; the one
    thing this run needs on top is the assertion of
    `clients/android/test_realtime.py:296`: an answer that does not come back
    within `RPC_TIMEOUT` means a state-owner command queued behind the network,
    which is the defect the whole fixture exists to catch. Every phone of this
    run lives in this one process, as the Java fixture's peers live in one JVM,
    so the monotonic instants two phones report are readings of one clock.
    """

    def response(self, phone, op, expect_error=False):
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        ready = selector.select(RPC_TIMEOUT)
        selector.close()
        if not ready:
            raise Failure(f'{phone}/{op}: no answer within {RPC_TIMEOUT} s; a state-owner '
                          'command waited behind the network')
        return super().response(phone, op, expect_error=expect_error)


def eventually(predicate, label, timeout=DELIVERY_TIMEOUT, interval=0.05):
    """The first true value of `predicate`, or a `Failure` naming the wait."""
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise Failure(f'timed out after {timeout} s: {label}')
        time.sleep(interval)


def conversation(view, account):
    """The one conversation with `account`, or `None` while there is none."""
    matches = [entry for entry in view.get('dialogs', []) if entry['account'] == account]
    require(len(matches) <= 1, 'the view holds two conversations with one peer')
    return matches[0] if matches else None


def shown(peers, phone, account, text, delivered=False):
    """The view of `phone` once it shows `text` (and its delivery mark)."""
    view = peers.rpc(phone, 'view')
    entry = conversation(view, account)
    matches = [message for message in entry['messages']
               if message['text'] == text] if entry else []
    require(len(matches) <= 1, 'the view holds the same message twice')
    if matches and (not delivered or matches[0]['delivered']):
        return view
    return None


def published(peers, phone, text):
    """The view of `phone` once it has published `text` out of its snapshot."""
    view = peers.rpc(phone, 'view')
    return view if text in view['seen'] else None


def queued(peers, phone):
    """The one envelope in the outbox of `phone`."""
    outbox = peers.rpc(phone, 'pending')['pending']
    require(len(outbox) == 1, f'{phone}: the outbox holds {len(outbox)} envelopes, expected 1')
    return outbox[0]


def register(peers, phone):
    """A phone with nothing on it registers itself over the running lanes.

    It is the automatic registration of
    `clients/android/test_realtime.py:332-337`: `create` is the user's local
    step and everything after it is the client's own — `ProofFlow.connect()`
    registers, discovers the realtime capability and opens a session the core
    validated before it was adopted, all from the receive lane's task.
    """
    created = peers.rpc(phone, 'create')
    require(created['identity'] and not created['active'],
            f'{phone}: create must leave an unregistered identity')
    require(created['lanes'] is False, f'{phone}: create started a lane')
    peers.rpc(phone, 'start')
    view = eventually(
        lambda: (lambda answer: answer if answer['active'] and answer.get('contact') else None)(
            peers.rpc(phone, 'view')),
        f'{phone}: registration over the running lanes', REGISTRATION_TIMEOUT)
    require(view['account'] == created['account'], f'{phone}: registration moved the account')
    require(view['dialogs'] == [], f'{phone}: registration installed a conversation')
    require(view['lanes'] is True, f'{phone}: the lanes are not running')
    eventually(lambda: peers.rpc(phone, 'view')['session'],
               f'{phone}: a session of its own', REGISTRATION_TIMEOUT)
    return view


def sessions_of(proxy, account):
    """Every session identifier the proxy saw this account open."""
    with proxy.lock:
        return sorted(identifier for identifier, holder in proxy.sessions.items()
                      if holder == account)


def attempts_on(proxy, identifier):
    """Every POST of one envelope the proxy forwarded, oldest first."""
    with proxy.lock:
        return [dict(row) for row in proxy.posts if row['id'] == identifier]


def statuses_after(proxy, first, paths):
    """The statuses the proxy recorded on `paths` from `first` onwards."""
    with proxy.lock:
        return [row['status'] for row in proxy.timings[first:] if row['path'] in paths]


# --------------------------------------------------------------- the scenarios


def blocked_receipt(peers, proxy, database, accounts):
    """A receipt held on the wire while what it acknowledges is already durable.

    "Renderer publication follows successful full native candidate persistence
    and precedes receipt network completion"
    (`docs/protocol/realtime-v1.md:97-99`) is one sentence with two halves, and
    this is the only way to see both: the receipt POST of the receiving phone is
    stopped inside the proxy, and while it is stopped the message it
    acknowledges must already be on that phone's disk and published from there.
    Meanwhile the sender may not show a delivery mark, the server may hold no
    receipt row, and the receiving phone's state owner must still answer a local
    send at once — its receipt lane is blocked, not its ratchet
    (`clients/android/test_realtime.py:412-429`).
    """
    proxy.block_sender = accounts['two']
    peers.rpc('one', 'send', json.dumps({'account': accounts['two'], 'text': FIRST}))
    peers.rpc('one', 'kick')
    received = eventually(lambda: shown(peers, 'two', accounts['one'], FIRST),
                          'the first contact reaches a phone that scanned nothing')
    entry = conversation(received, accounts['one'])
    require(entry['trust'] == 'network_unverified' and not entry['identity_verified'],
            f'an unscanned peer is not network_unverified: {entry["trust"]}')
    require(not entry['blocked'], 'a first contact arrived blocked')
    require(proxy.blocked.wait(BLOCKED_TIMEOUT),
            'the receipt never reached the network while it was blocked')
    witness = peers.rpc('two', 'view')
    require(FIRST in witness['seen'],
            'the durable publication did not precede the blocked receipt')
    require(not shown(peers, 'one', accounts['two'], FIRST, delivered=True),
            'a receipt that never left the device claimed a delivery')
    require([row for row in database.messages() if row['sender'] == accounts['two']] == [],
            'the blocked receipt reached the server')
    probe = peers.rpc('two', 'send', json.dumps({'account': accounts['one'], 'text': REPLY}))
    owner_ms = (probe['owner_completed_ns'] - probe['command_start_ns']) / 1e6
    require(owner_ms < OWNER_BUDGET_MS,
            f'the blocked receipt held the state owner for {owner_ms:.0f} ms')
    proxy.block_sender = None
    proxy.release.set()
    peers.rpc('two', 'kick')
    eventually(lambda: shown(peers, 'one', accounts['two'], FIRST, delivered=True),
               'the released receipt double-checks the message it acknowledges')
    eventually(lambda: shown(peers, 'one', accounts['two'], REPLY),
               'the reply of a phone that paired nothing arrives')
    return {'receipt_reached_the_wire': True,
            'published_before_the_receipt_completed': True,
            'delivery_mark_before_the_receipt': False,
            'receipt_rows_while_blocked': 0,
            'owner_milliseconds_while_blocked': round(owner_ms, 3),
            'owner_budget_milliseconds': OWNER_BUDGET_MS,
            'trust_of_the_unscanned_peer': entry['trust']}


def latency(peers, accounts):
    """Warm foreground samples, from the sending command to the durable page.

    The boundary is the one Android measures
    (`clients/android/test_realtime.py:431-452`) and it is deliberately wider
    than a socket round trip: the start is the instant the sending phone was
    handed the text, before its own commit, and the end is the instant the
    receiving phone published it — and it publishes out of the file it has
    already sealed, renamed and read back. The pacing between two samples is
    the fixture's definition of a low-load healthy network, not a measurement.
    """
    measured = []
    for index in range(LATENCY_SAMPLES):
        sender, receiver = ('one', 'two') if index % 2 == 0 else ('two', 'one')
        text = f'synthetic-latency-{index:02d}'
        sent = peers.rpc(sender, 'send',
                         json.dumps({'account': accounts[receiver], 'text': text}))
        peers.rpc(sender, 'kick')
        eventually(lambda p=receiver, a=accounts[sender], t=text: shown(peers, p, a, t),
                   f'{text} arrives')
        view = eventually(lambda p=receiver, t=text: published(peers, p, t),
                          f'{text} is published from the durable snapshot')
        elapsed = (view['seen'][text] - sent['command_start_ns']) / 1e6
        require(elapsed >= 0, f'{text} was published before it was sent')
        measured.append({'sample': index, 'direction': f'{sender}->{receiver}',
                         'milliseconds': round(elapsed, 3),
                         'owner_milliseconds': round(
                             (sent['owner_completed_ns'] - sent['command_start_ns']) / 1e6, 3)})
        eventually(lambda p=sender, a=accounts[receiver], t=text:
                   shown(peers, p, a, t, delivered=True), f'the receipt of {text}')
        time.sleep(SAMPLE_PACING)
    ordered = sorted(sample['milliseconds'] for sample in measured)
    p50 = ordered[(len(ordered) - 1) // 2]
    p95 = ordered[int(0.95 * len(ordered))]
    facts = {'samples': len(measured), 'p50_ms': p50, 'p95_ms': p95,
             'target_p50_ms': TARGET_P50_MS, 'target_p95_ms': TARGET_P95_MS,
             'pacing_seconds': SAMPLE_PACING,
             'environment': 'one Mac: generated pinned TLS fault proxy, the unchanged Rust '
                            'server, PostgreSQL 16 and the shipped Swift lanes; no imposed '
                            'latency',
             'boundary': 'the send command on the sending phone to the receiving phone\'s '
                         'publication out of its committed snapshot; not simulator pixels'}
    require(p50 <= TARGET_P50_MS and p95 <= TARGET_P95_MS,
            f'the latency target was missed: P50={p50:.1f} ms, P95={p95:.1f} ms')
    print(f'{len(measured)} warm samples P50={p50:.1f} ms P95={p95:.1f} ms', flush=True)
    return facts, measured


def lost_answer(peers, proxy, database, accounts):
    """The answer is lost after the server committed the envelope.

    The proxy lets the POST through, the backend commits it, and the response
    never reaches the client. What the client owes the protocol is exactness:
    `RealtimeTransport.send` repeats the **identical** request once — the same
    bytes and the same one-shot authorization, so the server can refuse it as a
    replay rather than store a second message — and when it does refuse it with
    a genuine 401, `SessionCall` re-signs the operation once
    (`docs/protocol/realtime-v1.md:150-151`). The stored row must keep its
    sequence and its ciphertext, the outbox must empty, and no authority may be
    declared lost (`clients/android/test_realtime.py:471-488`).
    """
    peers.rpc('two', 'stop')
    proxy.dropped.clear()
    proxy.drop_sender = accounts['one']
    peers.rpc('one', 'send', json.dumps({'account': accounts['two'], 'text': LOST}))
    envelope = queued(peers, 'one')
    peers.rpc('one', 'kick')
    require(proxy.dropped.wait(BLOCKED_TIMEOUT * 2),
            'the answer the server had already committed was not dropped')
    dropped = proxy.last_dropped
    require(dropped['id'] == envelope['id'],
            'the dropped answer belongs to another envelope than the one that was queued')
    stored = eventually(lambda: [row for row in database.messages()
                                 if row['id'] == envelope['id']] or None,
                        'the server committed the envelope whose answer was lost')
    require(len(stored) == 1, 'the server stored the envelope twice')
    sequence = stored[0]['sequence']
    require(stored[0]['ciphertext'] == envelope['ciphertext'],
            'the stored bytes are not the bytes the core signed')
    eventually(lambda: len(attempts_on(proxy, envelope['id'])) >= 2,
               'the lost answer is answered by a repeat of the same envelope')
    eventually(lambda: not [frame for frame in peers.rpc('one', 'pending')['pending']
                            if frame['id'] == envelope['id']],
               'the repeat is accepted durably')
    again = [row for row in database.messages() if row['id'] == envelope['id']]
    require(len(again) == 1, 'the repeat stored a second row')
    require(again[0]['sequence'] == sequence, 'the repeat moved the sequence of its own row')
    require(again[0]['ciphertext'] == envelope['ciphertext'], 'the repeat rewrote the ciphertext')
    posts = attempts_on(proxy, envelope['id'])
    require(all(row['ciphertext'] == envelope['ciphertext'] for row in posts),
            'a repeat changed the ciphertext')
    require(posts[0]['status'] == 200, 'the dropped attempt was not committed by the server')
    identical = [row for row in posts[1:]
                 if row['authorization_sha256'] == posts[0]['authorization_sha256']]
    require([row['status'] for row in identical] == [401],
            'the identical repeat of the lost request was not refused as a replay')
    resigned = [row for row in posts
                if row['authorization_sha256'] != posts[0]['authorization_sha256']]
    require(len(resigned) == 1 and resigned[0]['status'] == 200,
            'the envelope was not carried through by exactly one re-signed request')
    require([row['status'] for row in posts] == [200, 401, 200],
            'the recovery was not commit, replay, re-signed acceptance: '
            f'{[row["status"] for row in posts]}')
    view = peers.rpc('one', 'view')
    require(view['authorization_failures'] == 0,
            'a recoverable replay 401 was reported as a lost authority')
    peers.rpc('two', 'start')
    eventually(lambda: shown(peers, 'one', accounts['two'], LOST, delivered=True),
               'the receipt of the exactly repeated envelope', RECOVERY_TIMEOUT)
    return {'attempts': len(posts), 'statuses': [row['status'] for row in posts],
            'identical_repeats': len(identical), 're_signed_requests': len(resigned),
            'rows_for_the_envelope': 1, 'sequence_unchanged': True, 'ciphertext_unchanged': True,
            'authorization_lost_callbacks': view['authorization_failures']}


def consumed_nonce(peers, proxy, database, accounts):
    """The server consumed the nonce and the proxy replays it.

    The 401 is the backend's own: the first POST is committed, and its exact
    authorization is sent again, which the server refuses because that nonce is
    spent (`clients/android/test_realtime.py:115-134`). The client must retry
    the unchanged ciphertext with a **freshly signed** nonce once, and it must
    not tell the application that its authority is gone — the session is still
    good and the message still crosses (`RealtimeLoop.java:197-213`).
    """
    before = len(database.messages())
    proxy.consumed_401.clear()
    proxy.consume_401_sender = accounts['one']
    peers.rpc('one', 'send', json.dumps({'account': accounts['two'], 'text': CONSUMED}))
    envelope = queued(peers, 'one')
    peers.rpc('one', 'kick')
    require(proxy.consumed_401.wait(BLOCKED_TIMEOUT * 2),
            'the backend never refused the consumed authorization')
    require(proxy.consumed_401_id == envelope['id'],
            'the replay hit another envelope than the one that was queued')
    eventually(lambda: shown(peers, 'one', accounts['two'], CONSUMED, delivered=True),
               'the re-signed envelope is delivered and acknowledged', RECOVERY_TIMEOUT)
    posts = attempts_on(proxy, envelope['id'])
    statuses = [row['status'] for row in posts]
    require(statuses[:2] == [401, 200],
            f'the replay and its retry are not 401 then 200: {statuses}')
    require(posts[0]['authorization_sha256'] != posts[1]['authorization_sha256'],
            'the retry reused the authorization the server had consumed')
    require(all(row['ciphertext'] == envelope['ciphertext'] for row in posts),
            'the retry changed the ciphertext')
    rows = [row for row in database.messages() if row['id'] == envelope['id']]
    require(len(rows) == 1, 'the replayed envelope is stored twice')
    view = peers.rpc('one', 'view')
    require(view['authorization_failures'] == 0,
            'a recoverable consumed-nonce 401 was reported as a lost authority')
    require(view['session'] is True, 'the recoverable 401 dropped the session')
    require(len(database.messages()) >= before + 1, 'the message never reached the server')
    return {'statuses': statuses, 'retries': 1, 'fresh_signed_nonce': True,
            'ciphertext_unchanged': True, 'rows_for_the_envelope': len(rows),
            'authorization_lost_callbacks': view['authorization_failures'],
            'session_kept': True}


def rolled_session(peers, proxy, stand, accounts):
    """The server is rolled at the genuine session-open boundary.

    `FaultProxy.before_session_challenge` is called inside the handler that is
    about to forward a fresh phone's session-purpose challenge
    (`clients/android/test_realtime.py:93-96`), which is the one instant at
    which a client is opening a session. The Android fixture rolls the server
    binary back there; without a second binary this one rolls the **same**
    binary on the same data, which costs the server its in-memory session table
    (`server/src/self_service_http.rs:28`) and nothing else: no database reset,
    no new identity, no client restart.

    What the established phones then meet is a real 401 on a session route,
    twice — the one repeat of `SessionCall` with a freshly signed nonce is
    refused too, because the session itself is gone — so the session is
    dropped, the capability is rediscovered and a new session is opened
    (`docs/protocol/realtime-v1.md:172-177`). The fresh phone registers across
    the boundary and its first message crosses with its receipt.
    """
    created = peers.rpc('three', 'create')
    accounts['three'] = created['account']
    held = sessions_of(proxy, accounts['one'])
    require(len(held) >= 1, 'the established phone holds no session to lose')
    with proxy.lock:
        mark = len(proxy.timings)
        health_before = proxy.protocol_requests.get('/health', 0)
    rolled = []

    def roll(challenge):
        if challenge.get('account') != accounts['three']:
            return
        proxy.before_session_challenge = None
        stand.roll()
        rolled.append(True)

    proxy.before_session_challenge = roll
    peers.rpc('three', 'start')
    eventually(lambda: rolled, 'the session-open boundary of the fresh phone', RECOVERY_TIMEOUT)
    view = eventually(
        lambda: (lambda answer: answer if answer['active'] and answer.get('contact') else None)(
            peers.rpc('three', 'view')),
        'the fresh phone registers across the roll', RECOVERY_TIMEOUT)
    require(view['account'] == accounts['three'], 'the roll moved the account')
    peers.rpc('three', 'pair', json.dumps(accounts['contact_one']))
    peers.rpc('three', 'send', json.dumps({'account': accounts['one'], 'text': ROLLED}))
    peers.rpc('three', 'kick')
    eventually(lambda: shown(peers, 'one', accounts['three'], ROLLED),
               'the first message of the fresh phone crosses the roll', RECOVERY_TIMEOUT)
    eventually(lambda: shown(peers, 'three', accounts['one'], ROLLED, delivered=True),
               'its receipt comes back', RECOVERY_TIMEOUT)
    reopened = eventually(lambda: [identifier for identifier in sessions_of(proxy, accounts['one'])
                                   if identifier not in held] or None,
                          'the established phone opens a new session after the roll',
                          RECOVERY_TIMEOUT)
    denied = statuses_after(proxy, mark, ('/v2/events', '/v2/messages'))
    require(denied.count(401) >= 2,
            f'the rolled server did not refuse the retired session twice: {denied}')
    with proxy.lock:
        health_after = proxy.protocol_requests.get('/health', 0)
    require(health_after > health_before, 'the capability was not rediscovered after the roll')
    require(peers.rpc('one', 'pending')['pending'] == [],
            'the roll left an envelope stuck in the outbox')
    return {'boundary': 'the fresh phone\'s session-purpose challenge, inside the proxy handler',
            'roll': 'the same server binary stopped and started on the same data; no database '
                    'reset, no client restart',
            'sessions_lost': len(held), 'sessions_reopened': len(reopened),
            'genuine_401_on_session_routes': denied.count(401),
            'health_requests_added': health_after - health_before,
            'fresh_phone_registered_across_the_roll': True,
            'message_and_receipt_crossed': True}


def server_state(database, texts):
    """Every stored envelope is frame 2, and no plaintext of this run is there."""
    rows = database.messages()
    frame2 = sum(1 for row in rows if base64.b64decode(row['ciphertext'])[0] == FRAME2)
    require(frame2 == len(rows),
            f'{len(rows) - frame2} of {len(rows)} stored envelopes are not frame 2')
    leaked = {text: database.rows_carrying(text) for text in texts}
    total = sum(leaked.values())
    require(total == 0, f'{total} rows of the cluster carry plaintext this run sent')
    return {'envelopes': len(rows), 'frame2': frame2, 'plaintext_rows': total,
            'tables_scanned': list(harness.TABLES)}


# ------------------------------------------------------------------- evidence


ALLOWED_EVIDENCE = {
    'result', 'reason', 'boundary', 'elapsed_seconds', 'server_binary', 'server_sha256',
    'core_slice_sha256', 'bridge', 'proxy', 'phones', 'blocked_receipt', 'latency',
    'lost_answer', 'consumed_nonce', 'rolled_session', 'server_state',
    'front_tls_connections', 'requests_by_path', 'proxy_errors', 'checks',
}
BOUNDARY = ('local stand only: the unchanged server binary, a private PostgreSQL 16, a '
            'throw-away loopback TLS identity and the imported Android fault proxy on two lo0 '
            'aliases; no hosted server, no phone, no live action')
BRIDGE = ('one ParanoidKit service-bridge process with the lanes running: StateOwner over '
          'SelfServiceClient, SnapshotStore, ProofFlow, SessionCall, ReceiveLane and SendLane')
PROXY = ('FaultProxy imported from clients/android/test_realtime.py (never copied): verified '
         'TLS forwarding with block_sender, drop_sender, consume_401_sender and '
         'before_session_challenge')


def write_evidence(directory, payload, secrets, samples=None, timings=None):
    directory.mkdir(parents=True, exist_ok=True)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True) + '\n'
    for secret in secrets:
        require(secret and secret not in text,
                'evidence carries account, contact, message or trust material')
    (directory / RESULT).write_text(text)
    if samples is not None:
        (directory / SAMPLES).write_text(json.dumps(samples, indent=2) + '\n')
    if timings is not None:
        (directory / TIMINGS).write_text(json.dumps(timings, indent=2) + '\n')
    return directory / RESULT


# ------------------------------------------------------------------------ run


def scenarios(peers, proxy, stand, database, facts):
    """Every story of this run, in the order the phones can act them out."""
    accounts = {}
    for phone in ('one', 'two'):
        view = register(peers, phone)
        accounts[phone] = view['account']
        accounts['contact_' + phone] = view['contact']
    require(accounts['one'] != accounts['two'], 'the two phones share an account')
    paired = peers.rpc('one', 'pair', json.dumps(accounts['contact_two']))
    peer = conversation(paired, accounts['two'])
    require(peer['trust'] == 'out_of_band_verified' and peer['identity_verified'],
            f'a scanned contact is not verified: {peer["trust"]}')
    require(peers.rpc('two', 'view')['dialogs'] == [],
            'the receiving phone has a contact before anything arrived')

    facts['blocked_receipt'] = blocked_receipt(peers, proxy, database, accounts)
    print('PASS a receipt held on the wire after its message was already durable', flush=True)
    facts['latency'], samples = latency(peers, accounts)
    facts['lost_answer'] = lost_answer(peers, proxy, database, accounts)
    print('PASS an answer lost after the commit: one identical repeat, one re-signed request',
          flush=True)
    facts['consumed_nonce'] = consumed_nonce(peers, proxy, database, accounts)
    print('PASS a consumed authorization replayed by the proxy: one fresh-nonce retry', flush=True)
    facts['rolled_session'] = rolled_session(peers, proxy, stand, accounts)
    print('PASS the server rolled at the session-open boundary: 401, drop, rediscovery, session',
          flush=True)
    texts = [FIRST, REPLY, LOST, CONSUMED, ROLLED]
    texts += [f'synthetic-latency-{sample["sample"]:02d}' for sample in samples]
    facts['server_state'] = server_state(database, texts)
    facts['phones'] = len(PHONES)
    facts['checks'] = [
        'three phones register themselves over the running lanes, each with its own session',
        'a receipt blocked on the wire: the message it acknowledges is already durable and '
        'published, the sender shows no delivery mark, the server holds no receipt row and the '
        'state owner still answers a local send',
        f'{LATENCY_SAMPLES} warm foreground samples from the send command to the receiving '
        f'phone\'s durable publication: P50 <= {TARGET_P50_MS} ms, P95 <= {TARGET_P95_MS} ms',
        'an answer lost after the server committed: the identical repeat is refused as a replay, '
        'one re-signed request carries the same bytes through, the row keeps its sequence and no '
        'authority is declared lost',
        'a consumed authorization replayed by the proxy: one retry with a freshly signed nonce, '
        'unchanged ciphertext, no authorizationLost and the session kept',
        'the server rolled on the same data at the session-open boundary: a real 401 twice, the '
        'session dropped, the capability rediscovered, a new session opened, and a fresh phone '
        'registering and messaging across the boundary',
        'every stored envelope is frame 2 and no plaintext this run sent appears in any table',
    ]
    secrets = [accounts[key] for key in ('one', 'two', 'three') if key in accounts]
    secrets += [json.dumps(accounts['contact_' + phone], sort_keys=True)
                for phone in ('one', 'two') if 'contact_' + phone in accounts]
    secrets += texts
    return samples, secrets


def run(args):
    os.umask(0o077)
    evidence = Path(args.evidence_dir or DEFAULT_EVIDENCE_DIR)
    if not evidence.is_absolute():
        evidence = HERE / evidence
    front, back = addresses()
    binary = harness.build_bridge(args.skip_build)

    stand_argv = ['--work-dir', str(OUT), '--bind', back, '--port', str(PROXY_PORT)]
    if args.pg_bin:
        stand_argv += ['--pg-bin', args.pg_bin]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    stand = ProxiedStand(local_stand.parse_args(stand_argv), ipaddress.ip_address(front))
    facts = {}
    started = time.monotonic()
    proxy = peers = None
    samples = None
    with tempfile.TemporaryDirectory(prefix='paranoid-ios-realtime-') as temporary:
        try:
            try:
                stand.start()
            except local_stand.StandError as error:
                raise CheckError(f'local stand: {error}')
            realm = stand.descriptor['server_url']
            require(realm == f'https://{front}:{PROXY_PORT}',
                    f'the realm is not the literal front address: {realm}')
            print(f'stand: server on {back}:{PROXY_PORT}, realm {realm} '
                  f'(log {stand.log_path})', flush=True)
            proxy = FaultProxy(front, back, Path(stand.descriptor['tls_cert']),
                               Path(stand.env['PARANOID_TLS_KEY']))
            peers = Peers('peers', binary, Path(temporary) / 'phones', realm,
                          stand.descriptor['tls_spki_sha256'], harness.Pacer(0.0))
            samples, secrets = scenarios(peers, proxy, stand, harness.Database(stand), facts)
            require(not proxy.errors, f'the proxy recorded {proxy.errors}')
            facts['proxy_errors'] = len(proxy.errors)
            facts['front_tls_connections'] = proxy.front_connections
            with proxy.lock:
                facts['requests_by_path'] = dict(proxy.protocol_requests)
            facts.update(result='PASS', boundary=BOUNDARY, bridge=BRIDGE, proxy=PROXY,
                         server_binary=str(stand.server_binary),
                         server_sha256=digest(Path(stand.server_binary)),
                         core_slice_sha256=digest(harness.CORE_SLICE),
                         elapsed_seconds=round(time.monotonic() - started, 1))
            secrets = secrets + [stand.descriptor['tls_spki_sha256']]
            with proxy.lock:
                timings = [dict(row) for row in proxy.timings]
            path = write_evidence(evidence, facts, secrets, samples, timings)
        finally:
            if peers is not None:
                peers.close()
            if proxy is not None:
                proxy.close()
            stand.stop()
    print('result: PASS', flush=True)
    print('checks: ' + '; '.join(facts['checks']), flush=True)
    print(f'evidence: {path}', flush=True)
    print(f'timings: {evidence / TIMINGS}', flush=True)
    return 0


def not_run(evidence, reason):
    """An honest NOT RUN: the reason on stdout and in the evidence."""
    if not evidence.is_absolute():
        evidence = HERE / evidence
    write_evidence(evidence, {'result': 'NOT RUN', 'reason': reason, 'boundary': BOUNDARY,
                              'proxy': PROXY, 'bridge': BRIDGE}, [])
    print(f'NOT RUN: {reason}', flush=True)
    print(f'evidence: {evidence / RESULT}', flush=True)
    return 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--evidence-dir',
                        help='where the evidence JSON and the proxy timings go; a relative path '
                             f'is resolved against clients/ios (default: {DEFAULT_EVIDENCE_DIR})')
    parser.add_argument('--pg-bin', metavar='DIR',
                        help='PostgreSQL 16 bin directory (default: toolchain.json pg_bin)')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='use this paranoid-server instead of building the working tree')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse the service-bridge executable already built')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except NotRun as reason:
        return not_run(Path(args.evidence_dir or DEFAULT_EVIDENCE_DIR), str(reason))
    except Failure as failure:
        print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    except CheckError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
