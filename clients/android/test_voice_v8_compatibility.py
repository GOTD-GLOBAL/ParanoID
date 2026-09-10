"""Actual old/new JNI compatibility through private JVM pipes; no network/phone action."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'
BASE = '366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f'
RETAINED_SHA256 = 'e0b02ac5d90abebdec2d25fcc5d5067fe0dba0a9e313a8bddec354ccf1aebdcc'
JSON_SHA256 = '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'
REALM = 'https://127.0.0.2:38443'
PIN = 'a' * 64
JAVA = ['CoreBridge', 'SelfServiceClient', 'SnapshotCodec', 'KeyClient', 'KeyTransport', 'PinnedTls', 'SyncCycle']


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Bridge:
    def __init__(self, classes, dependency, native):
        self.process = subprocess.Popen(['java', '-Djava.library.path=' + str(native), '-cp',
                                         str(classes) + ':' + str(dependency), 'VoiceCoreBridge'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def request(self, request):
        self.process.stdin.write(json.dumps(request, separators=(',', ':')) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        require(bool(line), 'JNI bridge exited without a result')
        result = json.loads(line)
        require('fixture_error' not in result, 'JNI bridge failed without exposing private input')
        return result

    def core(self, prior, request, allow_error=False):
        state = json.dumps(prior['state'], separators=(',', ':')) if prior else ''
        result = self.request({'kind': 'core', 'state': state, 'request': request})
        require(allow_error or 'error' not in result, 'Native command rejected fixture operation: ' + request['op'])
        return result

    def sealed(self, prior):
        snapshot = {'version': 4, 'realm': REALM, 'tls_pin': PIN, 'token': '', 'state': prior['state']}
        result = self.request({'kind': 'sealed_reopen', 'snapshot': snapshot})
        require(result['unchanged'] and result['writes'] == 0, 'Sealed4 reopening changed saved bytes')
        require(result['view']['account'] == account(prior), 'Sealed4 reopening changed identity')
        require(result['view']['dialogs'] == prior['dialogs'], 'Sealed4 reopening changed dialogs')

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def account(peer):
    return peer['request']['credential']['account']


def ready(bridge):
    peer = bridge.core(None, {'op': 'create_identity', 'realm': REALM, 'pin': PIN})
    peer = bridge.core(peer, {'op': 'upgrade_v2'})
    c = peer['request']['credential']
    fields = ['paranoid-credential-v1'] + [c[k] for k in ['root', 'account', 'device', 'auth', 'realm', 'pin', 'olm']]
    transcript = b''.join(len(f.encode()).to_bytes(4, 'big') + f.encode() for f in fields)
    peer = bridge.core(peer, {'op': 'server_status_v2', 'status': {'mode': 'active', 'account': c['account'],
                        'device': c['device'], 'credential': hashlib.sha256(transcript).hexdigest()}})
    return bridge.core(peer, {'op': 'prepare_contact_v2'})


def pair(bridge, a, b):
    return bridge.core(a, {'op': 'pair_contact_v2', 'text': json.dumps(b['contact'], separators=(',', ':')), 'verified': True})


def deliver(sender_bridge, recipient_bridge, a, b, sequence):
    pending = a['outbox'][0]
    message = {k: pending[k] for k in ['id', 'ciphertext']}
    message.update(sender=account(a), sequence=sequence)
    received = recipient_bridge.core(b, {'op': 'receive_v2', 'message': message})
    accepted = sender_bridge.core(a, {'op': 'accepted_v2', 'id': pending['id']})
    return accepted, received


def knock():
    now = int(time.time() * 1000)
    return {'v': 1, 'kind': 'knock', 'call_id': str(uuid.uuid4()), 'caller_nonce': '1' * 64,
            'callee_nonce': '', 'seq': 0, 'sent_ms': now, 'expires_ms': now + 45000,
            'sdp': '', 'fingerprint': '', 'ice_ufrag': '', 'ice_pwd': '', 'offer_digest': '', 'reason': ''}


def run(args):
    os.umask(0o077)
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    dependency = ANDROID / 'out/deps/json-20240303.jar'
    require(dependency.is_file() and sha(dependency) == JSON_SHA256, 'Verified fixture JSON dependency required')
    old_jni = args.old_jni_dir.resolve()
    new_jni = args.new_jni_dir.resolve()
    require(sha(old_jni / 'libparanoid_client_core.so') == RETAINED_SHA256, 'Old JNI is not exact retained v8')
    record = {'base': BASE, 'old_jni_sha256': RETAINED_SHA256, 'new_jni_sha256': sha(new_jni / 'libparanoid_client_core.so'),
              'java_source_sha256': {}, 'checks': [], 'result': 'RUNNING', 'physical_phone': 'NOT RUN', 'network': 'NOT RUN'}
    classes = {}
    for label in ['old', 'new']:
        source = evidence / (label + '-source')
        output = evidence / (label + '-classes')
        output.mkdir(exist_ok=True)
        sources = []
        for name in JAVA:
            relative = 'clients/android/src/org/paranoid/text/' + name + '.java'
            raw = subprocess.check_output(['git', 'show', BASE + ':' + relative], cwd=ROOT) if label == 'old' else (ROOT / relative).read_bytes()
            target = source / ('org/paranoid/text/' + name + '.java')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            sources.append(str(target))
            record['java_source_sha256'][label + ':' + relative] = hashlib.sha256(raw).hexdigest()
        command = ['javac', '--release', '8', '-cp', str(dependency), '-d', str(output), *sources,
                   str(ANDROID / 'test/VoiceCoreBridge.java')]
        compiled = subprocess.run(command, capture_output=True, text=True)
        (evidence / (label + '-compile.log')).write_text(compiled.stdout + '\n' + compiled.stderr)
        require(compiled.returncode == 0, label + ' Java fixture compilation failed')
        classes[label] = output
    old = Bridge(classes['old'], dependency, old_jni)
    new = Bridge(classes['new'], dependency, new_jni)
    try:
        a, b = ready(old), ready(old)
        a, b = pair(old, a, b), pair(old, b, a)
        initial = [a['state']['legacy'], b['state']['legacy']]
        new.sealed(a)
        new.sealed(b)
        record['checks'].append('Actual v8 core3/sealed4 opens unchanged with new JNI/facade')
        # New sender consumes a real ratchet step; old receiver rejects the call
        # candidate transactionally and must still decrypt the following text.
        a = new.core(a, {'op': 'send_call_v1', 'account': account(b), 'body': knock()})
        old.sealed(a)
        reopened = old.core(a, {'op': 'view'})
        require(reopened['state'] == a['state'], 'Old core changed new pending call state')
        require(reopened['outbox'] == a['outbox'], 'Old core changed immutable call retry bytes')
        a, rejected = deliver(new, old, a, b, 1)
        require(rejected['acceptance'] == 'rejected' and 'call_event' not in rejected, 'Old v8 did not reject call')
        original = b['state']
        copy = dict(rejected['state'])
        for key in ['cursor', 'rejected_events', 'rejected_count']:
            copy[key] = original[key]
        require(copy == original, 'Old v8 call rejection mutated crypto/contact/history')
        b = rejected
        record['checks'].append('New pending call snapshot reopens in actual v8; v8 rejects call with entire crypto rollback')
        a = new.core(a, {'op': 'send_v2', 'account': account(b), 'text': 'new-to-v8 after rejected call'})
        a, b = deliver(new, old, a, b, 2)
        require(b['acceptance'] == 'accepted', 'Old v8 failed ratchet-gap text after call rejection')
        b, a = deliver(old, new, b, a, 3)
        require(a['dialogs'][0]['messages'][0]['delivered'], 'Old-to-new receipt failed')
        b = old.core(b, {'op': 'send_v2', 'account': account(a), 'text': 'v8-to-new after rejected call'})
        b, a = deliver(old, new, b, a, 4)
        require(a['acceptance'] == 'accepted', 'New core rejected v8 reply')
        a, b = deliver(new, old, a, b, 5)
        require(b['dialogs'][0]['messages'][-1]['delivered'], 'New-to-old receipt failed')
        record['checks'].append('Actual old/new text and authenticated delivery receipts work in both directions after ratchet gap')
        # Upgrade receiver to new native, accept a real control, then reopen that
        # ratchet/cursor snapshot using the old core and old sealed facade.
        a = new.core(a, {'op': 'send_call_v1', 'account': account(b), 'body': knock()})
        a, b = deliver(new, new, a, b, 6)
        require(b['acceptance'] == 'accepted' and 'call_event' in b, 'New receiver did not emit authenticated control')
        require(len(b['state']['events']) == 2, 'Call consumed an ordinary text/receipt Event slot')
        for peer in [a, b]:
            old.sealed(peer)
            view = old.core(peer, {'op': 'view'})
            require(view['state'] == peer['state'] and 'call_event' not in view, 'Old reopen changed accepted-call snapshot')
        require(a['state']['legacy'] == initial[0] and b['state']['legacy'] == initial[1], 'Compatibility flow replaced identity')
        record['checks'].append('New accepted-call state reopens unchanged in old core3/sealed4; no call event resumes')
        record['result'] = 'PASS'
    finally:
        old.close()
        new.close()
        (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--old-jni-dir', type=Path, required=True)
    parser.add_argument('--new-jni-dir', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    run(parser.parse_args())
