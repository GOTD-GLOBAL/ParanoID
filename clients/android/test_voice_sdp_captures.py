"""Check exact private real-media SDP captures through actual JNI and Olm/frame2.

Capture files stay outside the repository; output contains hashes and results,
never SDP, ICE credentials, private identities, or serialized native state.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from test_voice_v8_compatibility import (
    ANDROID, JAVA, JSON_SHA256, ROOT, Bridge, account, deliver, knock, pair,
    ready, require, sha,
)


def control(sdp, kind, offer_digest):
    result = knock()
    result.update(kind=kind, callee_nonce='2' * 64, seq=1, sdp=sdp,
                  offer_digest=offer_digest)
    for field, prefix in [('fingerprint', 'a=fingerprint:sha-256 '),
                          ('ice_ufrag', 'a=ice-ufrag:'), ('ice_pwd', 'a=ice-pwd:')]:
        values = [line[len(prefix):] for line in sdp.splitlines() if line.startswith(prefix)]
        require(len(values) == 1, 'Capture must have exactly one ' + field)
        result[field] = values[0].replace(':', '').lower() if field == 'fingerprint' else values[0]
    return result


def run(args):
    os.umask(0o077)
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    classes = evidence / 'classes'
    classes.mkdir()
    dependency = ANDROID / 'out/deps/json-20240303.jar'
    require(sha(dependency) == JSON_SHA256, 'Verified JSON dependency required')
    sources = [ANDROID / ('src/org/paranoid/text/' + name + '.java') for name in JAVA]
    sources.append(ANDROID / 'test/VoiceCoreBridge.java')
    result = subprocess.run(['javac', '--release', '8', '-cp', str(dependency), '-d', str(classes),
                             *map(str, sources)], capture_output=True, text=True)
    (evidence / 'compile.log').write_text(result.stdout + '\n' + result.stderr)
    require(result.returncode == 0, 'JNI bridge compilation failed')
    native = args.jni_dir.resolve()
    record = {'result': 'RUNNING', 'jni_sha256': sha(native / 'libparanoid_client_core.so'),
              'captures': [], 'checks': [], 'network': 'NOT RUN; captured successful media SDP only'}
    bridge = Bridge(classes, dependency, native)
    try:
        for directory in args.capture_directory:
            offer_bytes = (directory / 'android-offer.sdp').read_bytes()
            answer_bytes = (directory / 'aiortc-answer.sdp').read_bytes()
            offer_digest = hashlib.sha256(offer_bytes).hexdigest()
            a, b = ready(bridge), ready(bridge)
            a, b = pair(bridge, a, b), pair(bridge, b, a)
            for sequence, (kind, raw) in enumerate([('offer', offer_bytes), ('answer', answer_bytes)], 1):
                value = control(raw.decode('utf-8'), kind, offer_digest)
                sender, recipient = (a, b) if kind == 'offer' else (b, a)
                sender = bridge.core(sender, {'op': 'send_call_v1', 'account': account(recipient), 'body': value})
                sender, recipient = deliver(bridge, bridge, sender, recipient, sequence)
                require(recipient['acceptance'] == 'accepted', kind + ' capture rejected after real encryption')
                require(recipient['call_event']['body'] == value, kind + ' capture changed in authenticated event')
                require(recipient['call_event']['account'] == account(sender), 'Wrong authenticated sender')
                require(not recipient['dialogs'][0]['messages'], 'Media control created a text message')
                require(not recipient['outbox'], 'Media control generated a receipt')
                require(not recipient['state']['events'], 'Media control consumed durable text ledger')
                if kind == 'offer':
                    a, b = sender, recipient
                else:
                    b, a = sender, recipient
                rejected_fields = ['fingerprint', 'ice_ufrag', 'ice_pwd'] + (['offer_digest'] if kind == 'offer' else [])
                for field in rejected_fields:
                    wrong = dict(value)
                    wrong[field] = ('a' if value[field][0] != 'a' else 'b') + value[field][1:]
                    rejected = bridge.core(sender, {'op': 'send_call_v1', 'account': account(recipient), 'body': wrong}, allow_error=True)
                    require('error' in rejected, 'Native accepted substituted SDP binding: ' + field)
                record['captures'].append({'directory': str(directory.resolve()), 'kind': kind,
                                            'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                                            'candidate_count': sum(line.startswith(b'a=candidate:') for line in raw.splitlines()),
                                            'result': 'PASS', 'binding_substitutions_rejected': rejected_fields})
        record['checks'] = ['Exact M150 offer and aiortc answer bytes accepted by native outgoing parser',
                            'Real Olm/frame2 recipient accepted exact same SDP as authenticated transient event',
                            'Fingerprint, ICE credentials and offer digest substitutions rejected',
                            'No text/history, delivery receipt, or durable text Event rows created']
        record['result'] = 'PASS'
    finally:
        bridge.close()
        (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture-directory', type=Path, action='append', required=True)
    parser.add_argument('--jni-dir', type=Path, default=ROOT / 'clients/core/target/release')
    parser.add_argument('--evidence-dir', type=Path, required=True)
    run(parser.parse_args())
