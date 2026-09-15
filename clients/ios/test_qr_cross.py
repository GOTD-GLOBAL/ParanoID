#!/usr/bin/env python3
"""QR cross-check between the iOS encoder and the ZXing build Android ships.

A contact travels between two phones as a QR code, so the two clients have to
agree on the pixels, not only on the text. This file puts the shipped iOS
encoder (`QrCodec.image(for:)`, `CIQRCodeGenerator` at correction level `M`)
opposite the ZXing 3.5.3 build the Android client ships
(`clients/android/src/org/paranoid/text/QrCodec.java`) and runs the code both
ways, over a **real contact** the core published — the dense
`paranoid-contact-v2` payload that broke the v15 scanner at 480p:

1. the iOS encoder draws it, ZXing reads it back;
2. ZXing draws it, the iOS side reads it back.

The string must come back byte for byte both times, and the text that came
back must then produce the same `contact_text_v2` fingerprint on **both**
cores and the same fingerprint this file computes in Python from the
transcript rule of `key-protocol` — a QR that decoded to a different contact
would pair the user with someone else, and only a fingerprint says so.

What the reverse direction does and does not prove
--------------------------------------------------
Step 2 reads the pixels with `Vision` inside the `core-bridge` fixture. The
application does **not** read codes that way: it takes the string out of an
`AVCaptureMetadataOutput` frame inside a live capture session, which no
command-line tool can drive. So step 2 says the ZXing pixels carry the
payload; it does not exercise the shipped scanner, and nothing here replaces
the camera check of `docs/clients/ios/verification.md`.

Nothing here confers trust. A QR carries public data only and the user still
compares the whole fingerprint on the other phone
(`docs/protocol/first-contact-v1.md:90-91`).

Usage: python3 clients/ios/test_qr_cross.py [--evidence-dir out/checks/qr-cross]
"""
import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import test_android_compatibility as compat  # noqa: E402  (the path is set up right above)

ROOT = compat.ROOT
OUT = compat.OUT
ZXING_JAR = OUT / 'host-java/zxing-core-3.5.3.jar'
DEFAULT_EVIDENCE_DIR = OUT / 'checks/qr-cross'
RESULT = 'result.json'

# Both bounds are protocol, not preference (`key-enrollment-v1.md:91-96`).
PAYLOAD_LIMIT = 2048
IMPORT_LIMIT = 4096
# The side the iOS encoder is asked for and the side the Android client
# renders at (`QrCodec.minimumSide`, `MainActivity.java:614`).
ANDROID_SIDE = 640

ANDROID_SOURCES = [
    'clients/android/src/org/paranoid/text/QrCodec.java',
    'clients/ios/test/java/QrCross.java',
]
IOS_SOURCES = [
    'clients/ios/ParanoidKit/Sources/ParanoidKit/Qr/QrCodec.swift',
    'clients/ios/ParanoidKit/Sources/core-bridge/main.swift',
]

COMMANDS = [
    'bash clients/ios/java_deps.sh',
    'swift build --package-path clients/ios/ParanoidKit '
    '--scratch-path clients/ios/out/spm --product core-bridge',
    'python3 clients/ios/test_qr_cross.py --evidence-dir out/checks/qr-cross',
]

PROVES = [
    'a real paranoid-contact-v2 payload survives both pixel paths unchanged: the iOS encoder '
    'to the ZXing reader Android ships, and the ZXing encoder back to a reader on this side',
    'the text that came back pairs to the same contact: both cores answer contact_text_v2 with '
    'one fingerprint, and it is the fingerprint this file computed from the transcript rule',
]
LIMITS = [
    'the reverse direction is read with Vision inside the fixture; the application reads a code '
    'from AVCaptureMetadataOutput in a live capture session, which no command-line tool drives',
    'no camera, no screen and no phone takes part: this is a PNG in memory, never a photograph '
    'of a screen, so it says nothing about focus, glare or distance',
    'nothing here confers trust; a QR carries public data and the user still compares the whole '
    'fingerprint on the other phone',
]

ALLOWED_EVIDENCE = {
    'generated', 'commit', 'script', 'result', 'commands', 'proves', 'does_not_prove',
    'toolchain', 'sources', 'round_trips', 'negatives', 'checks', 'facts',
}

require = compat.require
Failure = compat.Failure


def json_span(text, member):
    """The verbatim slice of a top-level member, the Python twin of `JsonSpan`.

    The contact a QR carries is the text the core wrote, byte for byte, not a
    re-encoding of it: re-serialising here would test this file's encoder
    rather than the client's. `raw_decode` gives the exact span.
    """
    needle = '"' + member + '":'
    start = text.index(needle) + len(needle)
    _, end = json.JSONDecoder().raw_decode(text, start)
    return text[start:end]


class CorePipe(compat.Pipe):
    """A `core-bridge`/`VoiceCoreBridge` pipe that also keeps the raw reply."""

    def __init__(self, label, argv, description):
        super().__init__(label, argv, description)
        self.state = ''
        self.raw = ''

    def raw_core(self, request, adopt=True):
        self.requests += 1
        self.process.stdin.write(
            json.dumps({'kind': 'core', 'state': self.state, 'request': request},
                       separators=(',', ':')) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        require(bool(line), f'{self.label} pipe exited without answering')
        text = line.rstrip('\n')
        reply = json.loads(text)
        require('fixture_error' not in reply,
                f'{self.label} pipe failed with {reply.get("fixture_error")}')
        if 'error' in reply:
            return text, reply
        if adopt:
            self.state = json.dumps(reply['state'], separators=(',', ':'))
            self.raw = text
        return text, reply

    def ready(self):
        """A registered identity with a published contact, as `identity` builds one."""
        self.raw_core({'op': 'create_identity', 'realm': compat.REALM, 'pin': compat.PIN})
        self.raw_core({'op': 'upgrade_v2'})
        credential = json.loads(self.raw)['request']['credential']
        self.raw_core({'op': 'server_status_v2', 'status': {
            'mode': 'active', 'account': credential['account'], 'device': credential['device'],
            'credential': compat.expected_credential_fingerprint(credential)}})
        text, reply = self.raw_core({'op': 'prepare_contact_v2'})
        return json_span(text, 'contact'), reply


def round_trip(name, draw, read, payload, facts):
    """One pixel path: `draw` renders the payload, `read` gives a string back."""
    drawn = draw(payload)
    png = base64.b64decode(drawn['png'])
    require(drawn['width'] == drawn['height'], f'{name}: the code is not square')
    require(drawn['width'] >= ANDROID_SIDE,
            f'{name}: the code is below the {ANDROID_SIDE}px the v15 scanner fix needs')
    back = read(drawn['png'])
    identical = back.get('text') == payload
    facts.append({'path': name, 'payload_bytes': len(payload.encode()),
                  'png_bytes': len(png), 'side': drawn['width'], 'identical': identical})
    return identical


def run(args):
    os.umask(0o077)
    evidence_dir = Path(args.evidence_dir)
    if not evidence_dir.is_absolute():
        evidence_dir = HERE / evidence_dir
    java_binary = compat.build(args)
    require(ZXING_JAR.is_file(),
            f'missing {compat.relative(ZXING_JAR)}; run `bash clients/ios/java_deps.sh`')
    classpath = f'{compat.JAVA_CLASSES}:{compat.JAVA_JSON_JAR}:{ZXING_JAR}'

    swift = CorePipe('ios', [str(compat.SWIFT_BRIDGE)],
                     'ParanoidKit core-bridge: the shipped QrCodec encoder, a Vision reader')
    java = CorePipe('android', [str(java_binary),
                                '-Djava.library.path=' + str(compat.JNI_LIBRARY.parent),
                                '-cp', classpath, 'VoiceCoreBridge'],
                    'clients/android/test/VoiceCoreBridge.java over the Android facade, JNI')
    zxing = compat.Pipe('zxing', [str(java_binary), '-cp', classpath, 'QrCross'],
                        'clients/ios/test/java/QrCross.java over the shipped ZXing 3.5.3')

    trips, negatives, checks, facts = [], [], [], {}
    secrets = {compat.REALM, compat.PIN}
    identical = 0
    result = 'RUNNING'
    try:
        contact, published = swift.ready()
        peer_contact, peer_published = java.ready()
        secrets.update({published['contact_fingerprint'], peer_published['contact_fingerprint'],
                        json.loads(contact)['credential']['account'],
                        json.loads(peer_contact)['credential']['account']})
        require(json.loads(contact) == published['contact'],
                'the verbatim contact slice is not the contact the core published')
        require(len(contact.encode()) <= PAYLOAD_LIMIT,
                'a published contact does not fit the 2048-byte QR bound')
        facts['contact_bytes'] = len(contact.encode())
        facts['payload_limit'] = PAYLOAD_LIMIT
        facts['import_limit'] = IMPORT_LIMIT

        def ios_draw(payload):
            return swift.request({'kind': 'qr_encode', 'text': payload})

        def ios_read(png):
            return swift.request({'kind': 'qr_decode', 'png': png}, allow_fixture_error=True)

        def zxing_draw(payload):
            return zxing.request({'op': 'encode', 'text': payload, 'size': ANDROID_SIDE})

        def zxing_read(png):
            return zxing.request({'op': 'decode', 'png': png}, allow_fixture_error=True)

        identical += round_trip('ios encoder -> zxing reader', ios_draw, zxing_read,
                                contact, trips)
        identical += round_trip('zxing encoder -> ios reader', zxing_draw, ios_read,
                                contact, trips)
        require(identical == len(trips),
                'a contact did not survive a pixel path: '
                + ', '.join(trip['path'] for trip in trips if not trip['identical']))
        checks.append(f'a {facts["contact_bytes"]}-byte paranoid-contact-v2 payload came back '
                      'byte for byte from both pixel paths')

        # The text that came back must pair to the same contact, and three
        # readings have to agree: the core that published it, the peer's core
        # reading it as a stranger's contact, and this file. `contact_text_v2`
        # is the preview a peer runs, so it is the peer's core that runs it —
        # a core refuses its own contact (`contact_binding_mismatch`).
        agreed = []
        for owner, owner_published, owner_contact, reader in (
                ('ios', published, contact, java), ('android', peer_published, peer_contact, swift)):
            expected = compat.expected_contact_fingerprint(json.loads(owner_contact))
            require(expected == owner_published['contact_fingerprint'],
                    f'the {owner} contact fingerprint is not the transcript digest')
            _, preview = reader.raw_core({'op': 'contact_text_v2', 'text': owner_contact},
                                         adopt=False)
            require('error' not in preview,
                    f'{reader.label} refused the {owner} contact: {preview.get("error")}')
            require(preview['fingerprint'] == expected,
                    f'{reader.label} read another fingerprint out of the {owner} contact')
            require(preview['account'] == json.loads(owner_contact)['credential']['account'],
                    f'{reader.label} read another account out of the {owner} contact')
            agreed.append({'published_by': owner, 'previewed_by': reader.label,
                           'matches_python_transcript': True})
        facts['fingerprint_agreement'] = agreed
        checks.append('for each contact three readings agree on one fingerprint: the core that '
                      'published it, the peer\'s core previewing it with contact_text_v2, and '
                      'the transcript this file computed in Python')

        # The peer's contact travels the other way, so neither direction is a
        # property of one particular contact.
        require(round_trip('android contact: ios encoder -> zxing reader',
                           ios_draw, zxing_read, peer_contact, []),
                'the Android contact did not survive the iOS encoder')
        checks.append('the contact the Android client published survives the iOS encoder too')

        # ---------------------------------------------------------- negatives
        def record(name, condition, detail):
            require(condition, f'{name}: {detail}')
            negatives.append(name)

        long_payload = 'x' * (PAYLOAD_LIMIT + 1)
        refused = swift.request({'kind': 'qr_encode', 'text': long_payload},
                                allow_fixture_error=True)
        record('a payload over 2048 bytes is refused by the iOS encoder',
               'png' not in refused and 'fixture_error' in refused,
               'the iOS encoder drew an over-long payload')
        refused = zxing.request({'op': 'encode', 'text': long_payload, 'size': ANDROID_SIDE},
                                allow_fixture_error=True)
        record('a payload over 2048 bytes is refused by the ZXing encoder',
               'png' not in refused and 'qr_error' in refused,
               'the ZXing encoder drew an over-long payload')

        # Each core reads the contact of the other one, as a peer would.
        readings = ((contact, java), (peer_contact, swift))

        codes = set()
        for text, reader in readings:
            # Whitespace before the closing brace: still one well-formed
            # contact, only longer than the import bound.
            padded = text[:-1] + ' ' * (IMPORT_LIMIT - len(text.encode()) + 2) + text[-1]
            require(len(padded.encode()) > IMPORT_LIMIT, 'the over-long import is not over-long')
            _, reply = reader.raw_core({'op': 'contact_text_v2', 'text': padded}, adopt=False)
            codes.add(reply.get('error'))
        record('a contact text over 4096 bytes is refused by both cores as qr_limit',
               codes == {'qr_limit'}, f'the cores answered {sorted(codes)}')

        codes = set()
        for text, reader in readings:
            marker = text.index('"signature":') + len('"signature":"')
            flipped = text[:marker] + ('A' if text[marker] != 'A' else 'B') + text[marker + 1:]
            require(flipped != text and len(flipped) == len(text),
                    'the flipped contact is not one byte away from the original')
            _, reply = reader.raw_core({'op': 'contact_text_v2', 'text': flipped}, adopt=False)
            codes.add(reply.get('error'))
        record('a contact with one byte of its signature changed is refused by both cores '
               'as invalid_signature',
               codes == {'invalid_signature'}, f'the cores answered {sorted(codes)}')
        facts['changed_signature_refusal'] = sorted(codes)[0]

        drawn = ios_draw(contact)
        png = base64.b64decode(drawn['png'])
        truncated = base64.b64encode(png[:len(png) // 2]).decode()
        record('a truncated PNG is refused by the ZXing reader',
               'text' not in zxing_read(truncated) and 'qr_error' in zxing_read(truncated),
               'the ZXing reader read a truncated PNG')
        record('a truncated PNG is refused by the reader on this side',
               'text' not in ios_read(truncated), 'the fixture reader read a truncated PNG')
        for refusal in (zxing_read(truncated), ios_read(truncated)):
            require(contact not in json.dumps(refusal),
                    'a refusal echoed the contact it was given')
        checks.append(f'{len(negatives)} refusals hold on both sides: the two byte bounds, a '
                      'contact whose signature moved, and a PNG that is not a code — and no '
                      'refusal echoes the payload')

        result = 'PASS'
    finally:
        for pipe in (swift, java, zxing):
            pipe.close()
        payload = {
            'generated': datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            'commit': compat.git('rev-parse', 'HEAD'),
            'script': 'clients/ios/test_qr_cross.py',
            'result': result,
            'commands': COMMANDS,
            'proves': PROVES,
            'does_not_prove': LIMITS,
            'toolchain': {
                'java': compat.tool_version([str(java_binary), '-version']),
                'swift': compat.tool_version(['swift', '--version']),
                'zxing': 'zxing-core-3.5.3.jar, the pin of clients/android/dependencies.py',
                'python': sys.version.split()[0],
            },
            'sources': {
                'android': {path: compat.sha256_file(ROOT / path) for path in ANDROID_SOURCES},
                'ios': {path: compat.sha256_file(ROOT / path) for path in IOS_SOURCES},
            },
            'round_trips': trips,
            'negatives': negatives,
            'checks': checks,
            'facts': facts,
        }
        written = write_evidence(evidence_dir, payload, sorted(secrets))
    print(f'evidence: {compat.relative(written)}')
    print(f'QR cross-check (iOS encoder <-> ZXing {ANDROID_SIDE}px): '
          f'{identical}/{len(trips)} identical')
    print(f'iOS/Android QR compatibility: {result} ({len(checks)} checks)')
    return 0 if result == 'PASS' else 1


def write_evidence(directory, payload, secrets):
    """`test_android_compatibility.write_evidence` with this file's member set."""
    allowed = compat.ALLOWED_EVIDENCE
    compat.ALLOWED_EVIDENCE = ALLOWED_EVIDENCE
    try:
        return compat.write_evidence(directory, payload, secrets)
    finally:
        compat.ALLOWED_EVIDENCE = allowed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--evidence-dir', default=str(DEFAULT_EVIDENCE_DIR),
                        help='where result.json is written (default: out/checks/qr-cross)')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Failure as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
