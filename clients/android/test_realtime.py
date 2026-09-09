#!/usr/bin/env python3
"""Actual async Java/JNI + generated pinned TLS + isolated PostgreSQL/server fixture.
All identities/messages are synthetic; never touches the compiled public endpoint.
"""
import argparse
import base64
import getpass
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'
PG = Path('/usr/lib/postgresql/16/bin')


class FaultProxy:
    """Real verified TLS forwarding with bounded, explicit synthetic network faults."""
    def __init__(self, front_ip, back_ip, certificate, key):
        self.front_ip, self.back_ip = front_ip, back_ip
        self.sessions = {}
        self.lock = threading.Lock()
        self.block_sender = None
        self.drop_sender = None
        self.blocked = threading.Event()
        self.release = threading.Event()
        self.dropped = threading.Event()
        self.last_dropped = None
        self.posts = []
        self.errors = []
        self.context = ssl.create_default_context(cafile=str(certificate))
        self.front_connections = 0
        self.protocol_requests = {}
        self.timings = []
        self.before_session_challenge = None
        self.challenge_observations = []
        proxy = self

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            block_on_close = False
            def get_request(self):
                request, address = super().get_request()
                with proxy.lock:
                    proxy.front_connections += 1
                return request, address

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args):
                pass  # Never log Authorization, request bodies or TLS material.
            def do_POST(self):
                self.forward()
            def do_GET(self):
                self.forward()
            def forward(self):
                connection = None
                request_start = time.monotonic_ns()
                response_status = None
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                    if length > 65536 or length < 0:
                        raise AssertionError('fixture request exceeds bounded frame')
                    body = self.rfile.read(length)
                    authorization = self.headers.get('Authorization', '')
                    session = authorization.split(' ', 1)[-1].split('.', 1)[0]
                    with proxy.lock:
                        sender = proxy.sessions.get(session)
                        proxy.protocol_requests[self.path.split('?', 1)[0]] = proxy.protocol_requests.get(self.path.split('?', 1)[0], 0) + 1
                    envelope = json.loads(body) if self.command == 'POST' and self.path == '/v2/messages' else None
                    challenge = json.loads(body) if self.command == 'POST' and self.path == '/v2/auth/challenge' else None
                    if challenge is not None and challenge.get('purpose') == 'session':
                        hook = proxy.before_session_challenge
                        if hook is not None:
                            hook(challenge)
                    if envelope is not None and proxy.block_sender is not None and sender == proxy.block_sender:
                        proxy.blocked.set()
                        if not proxy.release.wait(10):
                            raise AssertionError('test failed to release blocked receipt')
                    # Connect to the private backend address while authenticating the
                    # exact generated front-IP SAN/chain. Verification remains enabled.
                    connection = http.client.HTTPSConnection(proxy.front_ip, 38443, context=proxy.context, timeout=32)
                    connection._create_connection = lambda address, timeout, source_address=None: socket.create_connection((proxy.back_ip, 38443), timeout, source_address)
                    headers = {'Content-Type': 'application/json', 'Connection': 'close'}
                    if authorization:
                        headers['Authorization'] = authorization
                    connection.request(self.command, self.path, body=body if self.command == 'POST' else None, headers=headers)
                    response = connection.getresponse()
                    response_status = response.status
                    data = response.read(2 * 1024 * 1024 + 1)
                    if challenge is not None and challenge.get('purpose') == 'session':
                        with proxy.lock:
                            proxy.challenge_observations.append({'account': challenge.get('account'), 'purpose': 'session', 'status': response.status})
                    if len(data) > 2 * 1024 * 1024:
                        raise AssertionError('fixture response exceeds bound')
                    if response.status == 200 and self.path == '/v2/session':
                        context = json.loads(data)
                        with proxy.lock:
                            proxy.sessions[context['id']] = context['account']
                    if envelope is not None:
                        with proxy.lock:
                            proxy.posts.append({'sender': sender, 'id': envelope['id'], 'ciphertext': envelope['ciphertext'], 'status': response.status})
                            drop = response.status == 200 and proxy.drop_sender is not None and sender == proxy.drop_sender
                            if drop:
                                proxy.drop_sender = None
                                proxy.last_dropped = envelope
                        if drop:
                            # Backend genuinely committed; caller gets no acceptance.
                            proxy.dropped.set()
                            self.close_connection = True
                            self.connection.shutdown(socket.SHUT_RDWR)
                            self.connection.close()
                            return
                    self.send_response(response.status)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    self.close_connection = True  # Expected stop/disconnect paths.
                except (ConnectionRefusedError, TimeoutError, OSError):
                    self.close_connection = True  # Deliberate exact-server outage.
                except BaseException as error:
                    with proxy.lock:
                        proxy.errors.append(type(error).__name__ + ': ' + str(error))
                    self.close_connection = True
                finally:
                    with proxy.lock:
                        proxy.timings.append({'path': self.path.split('?', 1)[0], 'method': self.command, 'status': response_status, 'milliseconds': (time.monotonic_ns() - request_start) / 1e6})
                    if connection is not None:
                        connection.close()

        self.server = Server((front_ip, 38443), Handler)
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.minimum_version = ssl.TLSVersion.TLSv1_2
        server_context.load_cert_chain(str(certificate), str(key))
        self.server.socket = server_context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, name='synthetic-fault-proxy', daemon=True)
        self.thread.start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def run(server_binary, evidence_dir, jni_library_dir, legacy_server_binary=None):
    os.umask(0o077)
    server_binary = server_binary.resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    jni_library_dir = jni_library_dir.resolve()
    server_digest = hashlib.sha256(server_binary.read_bytes()).hexdigest()
    jni_digest = hashlib.sha256((jni_library_dir / 'libparanoid_client_core.so').read_bytes()).hexdigest()
    source_paths = [ANDROID / f'src/org/paranoid/text/{name}.java' for name in ['CoreBridge','PinnedTls','SnapshotCodec','StorageGuard','SyncCycle','KeyClient','KeyTransport','SelfServiceClient','RealtimeLoop','RealtimeTransport']]
    source_paths += [ANDROID / 'test/RealtimeBridge.java', Path(__file__).resolve()]
    source_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}
    (evidence_dir / 'source-start-sha256.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    classes = evidence_dir / 'fixture-classes' 
    classes.mkdir(exist_ok=True)
    dependencies = [ANDROID / 'out/deps/json-20240303.jar', ANDROID / 'out/deps/zxing-core-3.5.3.jar']
    assert all(path.is_file() for path in dependencies), 'Run the existing dependency preparation first'
    cp = ':'.join(str(path) for path in [classes, *dependencies])
    subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8', '-cp', cp,
                    '-sourcepath', str(ANDROID / 'src'), '-d', str(classes), str(ANDROID / 'test/RealtimeBridge.java')], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'PARANOID_'))}
    result = {'result': 'RUNNING', 'server_binary': str(server_binary), 'server_sha256': server_digest,
              'jni_sha256': jni_digest, 'physical_phone_benchmark': 'NOT RUN', 'ui_render': 'JVM durable publicView listener, not phone pixels'}
    samples = []
    with tempfile.TemporaryDirectory(prefix='paranoid-realtime-fixture-') as tmp:
        root = Path(tmp)
        sock = root / 'socket'
        sock.mkdir(mode=0o700)
        pg = server = bridge = proxy = None
        log = (root / 'server.log').open('w')
        bridge_log = (evidence_dir / 'bridge-stderr.log').open('w')
        started = time.monotonic()
        try:
            subprocess.run([str(PG / 'initdb'), '-D', str(root / 'pg'), '--auth-local=trust', '--auth-host=scram-sha-256', '--no-locale', '-E', 'UTF8'], check=True, env=env, stdout=log, stderr=log)
            pg = subprocess.Popen([str(PG / 'postgres'), '-D', str(root / 'pg'), '-k', str(sock), '-c', 'listen_addresses=', '-c', 'unix_socket_permissions=0700', '-c', 'log_statement=none', '-c', 'log_min_error_statement=panic', '-c', 'log_parameter_max_length_on_error=0'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                if subprocess.run([str(PG / 'pg_isready'), '-h', str(sock)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    break
                if pg.poll() is not None:
                    raise AssertionError('own PostgreSQL exited')
                time.sleep(.05)
            else:
                raise AssertionError('own PostgreSQL not ready')
            addresses = []
            for candidate in ['127.0.0.22', '127.0.0.23', '127.0.0.24', '127.0.0.25']:
                try:
                    with socket.socket() as probe:
                        probe.bind((candidate, 38443))
                    addresses.append(candidate)
                except OSError:
                    pass
            assert len(addresses) >= 2, 'Need two free private fixture addresses; never kill unrelated process'
            front_ip, back_ip = addresses[:2]
            subprocess.run(['python3', str(ROOT / 'scripts/create-test-tls.py'), '--ip', front_ip, '--output', str(root / 'tls')], check=True, stdout=log)
            public = json.loads((root / 'tls/public-connection.json').read_text())
            realm, pin = public['server_url'], public['tls_spki_sha256']
            env.update(PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={sock}',
                       PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin, PARANOID_MODE='self-service-v2-local',
                       PARANOID_BIND=f'{back_ip}:38443', PARANOID_TLS_CERT=str(root / 'tls/server.crt'), PARANOID_TLS_KEY=str(root / 'tls/server.key'))
            subprocess.run([str(server_binary), 'self-service-init'], env=env, check=True, stdout=log, stderr=log)
            proxy = FaultProxy(front_ip, back_ip, root / 'tls/server.crt', root / 'tls/server.key')
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(root / 'tls/server.crt'))))

            def start_server(binary=server_binary):
                process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError('exact candidate server exited')
                        try:
                            with opener.open(realm + '/health', timeout=1) as response:
                                if response.status == 200:
                                    return process
                        except OSError:
                            time.sleep(.05)
                    raise AssertionError('exact TLS candidate not ready')
                except BaseException:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                    raise

            def start_bridge():
                return subprocess.Popen(['java', '-Djava.library.path=' + str(jni_library_dir), '-cp', cp,
                                         'RealtimeBridge', str(root / 'phones'), realm, pin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=bridge_log, text=True, bufsize=1)

            server = start_server()
            with opener.open(realm + '/health', timeout=3) as response:
                health = json.load(response)
            assert health.get('realtime') == 'signed-long-poll-v1', 'fixture requires actual candidate realtime transport'
            bridge = start_bridge()

            def rpc(phone, operation, value='', error=False):
                if not isinstance(value, str):
                    value = json.dumps(value, ensure_ascii=False)
                bridge.stdin.write(phone + '\t' + operation + '\t' + base64.b64encode(value.encode()).decode() + '\n')
                bridge.stdin.flush()
                selector = selectors.DefaultSelector()
                selector.register(bridge.stdout, selectors.EVENT_READ)
                ready = selector.select(8)
                selector.close()
                assert ready, f'{phone}/{operation}: state-owner command blocked behind network'
                line = bridge.stdout.readline()
                assert line, 'real JNI bridge exited'
                view = json.loads(base64.b64decode(line))
                assert ('error' in view) == error, f'{phone}/{operation}: {view.get("error")}: {view.get("detail")}'
                return view

            def eventually(predicate, label, timeout=35):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    value = predicate()
                    if value:
                        return value
                    time.sleep(.03)
                raise AssertionError('Timed out: ' + label)

            def dialog(view, account):
                matching = [entry for entry in view.get('dialogs', []) if entry['account'] == account]
                assert len(matching) <= 1, 'duplicate displayed conversation'
                return matching[0] if matching else None

            def has_text(phone, account, text, delivery=False):
                view = rpc(phone, 'view')
                entry = dialog(view, account)
                matching = [m for m in entry['messages'] if m['text'] == text] if entry else []
                assert len(matching) <= 1, 'duplicate displayed message'
                if matching and (not delivery or matching[0]['delivered']):
                    return view
                return None

            def stored_messages():
                response = subprocess.run([str(PG / 'psql'), '-X', '-h', str(sock), '-d', 'postgres', '-At', '-c',
                    "SELECT coalesce(json_agg(json_build_object('sender',sender,'recipient',recipient,'id',message_id,'ciphertext',replace(encode(ciphertext,'base64'),E'\\n','')) ORDER BY sequence),'[]'::json) FROM ss_messages"], env=env, check=True, capture_output=True, text=True)
                return json.loads(response.stdout)

            users = {}
            for phone in ['one', 'two', 'three']:
                created = rpc(phone, 'create')
                assert created['identity'] and not created['active']
                rpc(phone, 'start')
                users[phone] = eventually(lambda p=phone: (lambda v: v if v['active'] and v.get('contact') else None)(rpc(p, 'view')), phone + ' auto registration')
                assert users[phone]['account'] == created['account'] and users[phone]['dialogs'] == []
            rpc('one', 'pair', users['two']['contact'])
            assert rpc('two', 'view')['dialogs'] == [], 'receiver must begin with zero contacts'
            proxy.block_sender = users['two']['account']
            first = rpc('one', 'send', {'account': users['two']['account'], 'text': 'synthetic-first-contact'})
            rpc('one', 'kick')
            received = eventually(lambda: has_text('two', users['one']['account'], 'synthetic-first-contact'), 'zero-contact committed incoming plaintext')
            assert dialog(received, users['one']['account'])['trust'] == 'network_unverified'
            assert proxy.blocked.wait(5), 'receipt must genuinely attempt network while blocked'
            assert 'synthetic-first-contact' in received['seen'], 'durable listener publication must precede blocked receipt completion'
            assert not has_text('one', users['two']['account'], 'synthetic-first-contact', True), 'blocked receipt cannot claim peer delivery'
            assert len([r for r in stored_messages() if r['sender'] == users['two']['account']]) == 0
            # Owner remains responsive with real receipt I/O blocked on another lane.
            probe = rpc('two', 'send', {'account': users['one']['account'], 'text': 'synthetic-reply-while-receipt-blocked'})
            assert (probe['owner_completed_ns'] - probe['command_start_ns']) / 1e6 < 1500, 'blocked receipt I/O delayed local send owner'
            proxy.block_sender = None
            proxy.release.set()
            rpc('two', 'kick')
            eventually(lambda: has_text('one', users['two']['account'], 'synthetic-first-contact', True), 'genuine authenticated delivery after receipt release')
            eventually(lambda: has_text('one', users['two']['account'], 'synthetic-reply-while-receipt-blocked'), 'unverified immediate reply')
            print('PASS zero-contact reply and durable publication while real receipt POST blocked', flush=True)

            # Warm alternating messages: nanoTime start before local state-owner submit
            # through actual receiver listener after durable encrypted snapshot commit.
            for sample in range(24):
                sender, receiver = ('one', 'two') if sample % 2 == 0 else ('two', 'one')
                text = f'synthetic-latency-{sample:02d}'
                sent = rpc(sender, 'send', {'account': users[receiver]['account'], 'text': text})
                rpc(sender, 'kick')
                view = eventually(lambda p=receiver, a=users[sender]['account'], t=text: has_text(p, a, t), text)
                view = eventually(lambda p=receiver, t=text: (lambda v: v if t in v['seen'] else None)(rpc(p, 'view')), 'listener ' + text)
                elapsed = (view['seen'][text] - sent['command_start_ns']) / 1e6
                assert elapsed >= 0
                samples.append({'sample': sample, 'direction': sender + '->' + receiver, 'milliseconds': elapsed, 'sender_owner_ms': (sent['owner_completed_ns'] - sent['command_start_ns']) / 1e6})
                eventually(lambda p=sender, a=users[receiver]['account'], t=text: has_text(p, a, t, True), 'real receipt ' + text)
                time.sleep(.25)  # Defined low-load healthy-network cadence, not measured latency.
            ordered = sorted(sample['milliseconds'] for sample in samples)
            p50 = ordered[(len(ordered) - 1) // 2]
            p95 = ordered[int(.95 * len(ordered))]
            result['latency'] = {'samples': len(samples), 'p50_ms': p50, 'p95_ms': p95, 'target_p50_ms': 500, 'target_p95_ms': 1500,
                                 'environment': 'same-host generated pinned TLS proxy + exact Rust server + PostgreSQL + Java/JNI; 250ms pacing after actual receipt, no imposed latency',
                                 'boundary': 'send call before local commit to receiver durable publicView listener; not Android screen pixels'}
            (evidence_dir / 'latency-samples.json').write_text(json.dumps(samples, indent=2) + '\n')
            print(f'ACTUAL warm foreground {len(samples)} samples P50={p50:.2f}ms P95={p95:.2f}ms', flush=True)

            # Crossing burst queues exact local messages before network kicks.
            for phone in ['one', 'two']:
                rpc(phone, 'stop')
            burst = []
            for n in range(4):
                for sender, receiver in [('one', 'two'), ('two', 'one')]:
                    text = f'synthetic-crossing-{sender}-{n}'
                    rpc(sender, 'send', {'account': users[receiver]['account'], 'text': text})
                    burst.append((sender, receiver, text))
            for phone in ['one', 'two']:
                rpc(phone, 'start')
            for sender, receiver, text in burst:
                eventually(lambda p=receiver, a=users[sender]['account'], t=text: has_text(p, a, t), text, 50)
                eventually(lambda p=sender, a=users[receiver]['account'], t=text: has_text(p, a, t, True), 'receipt ' + text, 50)
            assert dialog(rpc('one', 'view'), users['two']['account'])['channel'] == dialog(rpc('two', 'view'), users['one']['account'])['channel']
            print('PASS crossing burst on one deterministic retained channel', flush=True)

            # Real response loss AFTER backend commit; native outbox bytes must retry unchanged.
            rpc('two', 'stop')
            proxy.dropped.clear()
            proxy.drop_sender = users['one']['account']
            lost_text = 'synthetic-lost-acceptance'
            rpc('one', 'send', {'account': users['two']['account'], 'text': lost_text})
            rpc('one', 'kick')
            assert proxy.dropped.wait(10), 'actual server acceptance response was not dropped'
            dropped = proxy.last_dropped
            eventually(lambda: len([row for row in proxy.posts if row['id'] == dropped['id']]) >= 2, 'actual lost-response POST retry before receiver resumes', 50)
            eventually(lambda: not [frame for frame in rpc('one', 'pending')['pending'] if frame['id'] == dropped['id']], 'durable local acceptance of retry', 50)
            matching = [row for row in stored_messages() if row['sender'] == users['one']['account'] and row['id'] == dropped['id']]
            assert len(matching) == 1 and matching[0]['ciphertext'] == dropped['ciphertext'], 'retry changed ciphertext or duplicated stored message'
            attempts = [row for row in proxy.posts if row['id'] == dropped['id']]
            assert len(attempts) >= 2 and all(row['ciphertext'] == dropped['ciphertext'] for row in attempts), 'lost response must retry exact immutable bytes'
            rpc('two', 'start')
            eventually(lambda: has_text('one', users['two']['account'], lost_text, True), 'genuine receipt after exact lost-response retry', 50)
            print('PASS real post-commit response loss with exact immutable retry', flush=True)

            # Server down cannot block a local send; queued bytes persist across JVM/server reopen.
            server.terminate()
            server.wait(timeout=10)
            server = None
            offline = rpc('one', 'send', {'account': users['two']['account'], 'text': 'synthetic-offline-restart'})
            assert (offline['owner_completed_ns'] - offline['command_start_ns']) / 1e6 < 1500
            pending = rpc('one', 'pending')['pending']
            assert pending and all(base64.b64decode(frame['ciphertext'])[0] == 2 for frame in pending)
            before = {phone: rpc(phone, 'view') for phone in users}
            bridge.stdin.close()
            assert bridge.wait(timeout=15) == 0
            bridge = start_bridge()
            for phone in users:
                reopened = rpc(phone, 'view')
                assert reopened['account'] == before[phone]['account']
                assert reopened['dialogs'] == before[phone]['dialogs'], 'v7 schema4/core3 snapshot changed on reopen'
            assert rpc('one', 'pending')['pending'] == pending
            server = start_server()
            for phone in users:
                rpc(phone, 'start')
            eventually(lambda: has_text('two', users['one']['account'], 'synthetic-offline-restart'), 'server and JVM restart queue', 50)
            eventually(lambda: has_text('one', users['two']['account'], 'synthetic-offline-restart', True), 'server and JVM restart receipt', 50)
            print('PASS offline owner progress and exact schema4/core3 encrypted snapshot/server/JVM restart', flush=True)

            # Rejection/freeze: incoming save failure must publish no plaintext or receipt.
            rpc('one', 'pair', users['three']['contact'])
            rpc('three', 'stop')
            before_disk = hashlib.sha256((root / 'phones/three.enc').read_bytes()).hexdigest()
            rpc('three', 'fail_next_commit')
            rpc('one', 'send', {'account': users['three']['account'], 'text': 'synthetic-save-failure'})
            rpc('one', 'kick')
            rpc('three', 'start')
            frozen = eventually(lambda: (lambda v: v if v.get('broken') else None)(rpc('three', 'view')), 'incoming-save freeze', 50)
            assert 'synthetic-save-failure' not in frozen['seen']
            assert hashlib.sha256((root / 'phones/three.enc').read_bytes()).hexdigest() == before_disk
            assert not [row for row in stored_messages() if row['sender'] == users['three']['account']], 'failed save emitted a receipt'
            rpc('three', 'send', {'account': users['one']['account'], 'text': 'must-not-send'}, error=True)
            print('PASS incoming save failure freezes without plaintext publication, state replacement or receipt', flush=True)

            if legacy_server_binary is not None:
                # Same-data binary rollback, no DB restore/reset and no app restart.
                server.terminate()
                server.wait(timeout=10)
                server = start_server(legacy_server_binary.resolve())
                rpc('one', 'send', {'account': users['two']['account'], 'text': 'synthetic-live-v7-rollback'})
                rpc('one', 'kick')
                eventually(lambda: has_text('two', users['one']['account'], 'synthetic-live-v7-rollback'), 'old-v2 server rediscovery', 70)
                eventually(lambda: has_text('one', users['two']['account'], 'synthetic-live-v7-rollback', True), 'old-v2 genuine receipt', 70)
                result['legacy_server_sha256'] = hashlib.sha256(legacy_server_binary.read_bytes()).hexdigest()
                print('PASS live same-data old-v2 server rollback without app restart', flush=True)

                # Discover the candidate, then roll the actual binary back BEFORE
                # forwarding a fresh peer's session-purpose auth challenge. The
                # retained v2 server itself returns 401; no synthesized responses.
                server.terminate()
                server.wait(timeout=10)
                server = start_server()
                fourth = rpc('four', 'create')
                rolled_back = threading.Event()
                def rollback_on_challenge(challenge):
                    nonlocal server
                    if challenge.get('account') != fourth['account']:
                        return
                    proxy.before_session_challenge = None
                    server.terminate()
                    server.wait(timeout=10)
                    server = start_server(legacy_server_binary.resolve())
                    rolled_back.set()
                proxy.before_session_challenge = rollback_on_challenge
                rpc('four', 'start')
                assert rolled_back.wait(10), 'did not reach actual session-open rollback boundary'
                fourth = eventually(lambda: (lambda v: v if v['active'] and v.get('contact') else None)(rpc('four', 'view')), 'fourth genuine registration')
                assert not [account for account in proxy.sessions.values() if account == fourth['account']], 'new peer unexpectedly acquired a realtime session'
                rpc('four', 'pair', users['one']['contact'])
                rpc('four', 'send', {'account': users['one']['account'], 'text': 'synthetic-session-open-401-rollback'})
                rpc('four', 'kick')
                eventually(lambda: has_text('one', fourth['account'], 'synthetic-session-open-401-rollback'), 'session-open 401 rediscovery before 60s periodic discovery', 20)
                eventually(lambda: has_text('four', users['one']['account'], 'synthetic-session-open-401-rollback', True), 'session-open 401 genuine old-v2 receipt', 20)
                rejected = [entry for entry in proxy.challenge_observations if entry['account'] == fourth['account'] and entry['status'] == 401]
                assert rejected, 'retained old-v2 binary did not return the actual session-purpose 401'
                assert not [account for account in proxy.sessions.values() if account == fourth['account']], 'session-open rollback used events/session fallback instead'
                result['session_open_401_rollback'] = {'actual_old_v2_rejections': len(rejected), 'new_peer_ever_acquired_session': False, 'sent_and_received_receipt': True}
                print('PASS actual session-open 401 same-data rollback rediscovery, without new-peer events/404', flush=True)
            assert not proxy.errors, proxy.errors
            assert hashlib.sha256(server_binary.read_bytes()).hexdigest() == server_digest
            result.update(result='PASS', elapsed_seconds=time.monotonic() - started, checks=[
                'three automatic registrations, zero initial receiver contacts', 'durable listener matches actual encrypted snapshot',
                'blocked receipt network independent of state owner/publication', 'immediate unverified reply and genuine receipts',
                '24 actual warm latency samples', 'crossing burst', 'exact lost-response retry',
                'offline send and server/JVM snapshot4/core3 reopen', 'incoming save-failure freeze without receipt'],
                frontend_tls_connections=proxy.front_connections, real_requests_by_path=proxy.protocol_requests,
                target_met=p50 <= 500 and p95 <= 1500)
            print('PASS actual realtime JVM/JNI functional fixture; latency target met=' + str(result['target_met']), flush=True)
            assert result['target_met'], f'Actual latency missed target: P50={p50:.2f}ms P95={p95:.2f}ms'
        except BaseException as error:
            result.update(result='FAIL', error=type(error).__name__ + ': ' + str(error), elapsed_seconds=time.monotonic() - started)
            raise
        finally:
            source_end = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}
            (evidence_dir / 'source-end-sha256.json').write_text(json.dumps(source_end, indent=2) + '\n')
            result['changed_source_during_run'] = [path for path in source_hashes if source_hashes[path] != source_end[path]]
            result['jni_end_sha256'] = hashlib.sha256((jni_library_dir / 'libparanoid_client_core.so').read_bytes()).hexdigest()
            if proxy is not None:
                result['real_requests_by_path'] = proxy.protocol_requests
                (evidence_dir / 'network-timings.json').write_text(json.dumps(proxy.timings, indent=2) + '\n')
                (evidence_dir / 'synthetic-post-attempts.json').write_text(json.dumps(proxy.posts, indent=2) + '\n')
                (evidence_dir / 'session-challenge-observations.json').write_text(json.dumps(proxy.challenge_observations, indent=2) + '\n')
            (evidence_dir / 'realtime-fixture-result.json').write_text(json.dumps(result, indent=2) + '\n')
            if samples:
                (evidence_dir / 'latency-samples.json').write_text(json.dumps(samples, indent=2) + '\n')
            if bridge is not None:
                if bridge.poll() is None:
                    bridge.stdin.close()
                    try:
                        bridge.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        bridge.terminate()
                        bridge.wait(timeout=10)
            if proxy is not None:
                proxy.close()
            if server is not None and server.poll() is None:
                server.terminate()
                server.wait(timeout=10)
            if pg is not None and pg.poll() is None:
                pg.send_signal(signal.SIGINT)
                pg.wait(timeout=20)
            log.close()
            bridge_log.close()
            shutil.copyfile(root / 'server.log', evidence_dir / 'server.log')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--server-binary', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--jni-library-dir', type=Path, required=True, help='Explicit already-built JNI; never builds in shared output')
    parser.add_argument('--legacy-server-binary', type=Path, help='Optional exact v7-compatible binary for live same-data rollback test')
    args = parser.parse_args()
    run(args.server_binary, args.evidence_dir, args.jni_library_dir, args.legacy_server_binary)
