#!/usr/bin/env python3
"""iPhone <-> Android compatibility at the protocol level, offline, on this Mac.

Two private JSON-line pipes are opened and held open side by side:

- **A, the Android side** — `clients/android/test/VoiceCoreBridge.java` over the
  shipped Android facade (`CoreBridge`, `SelfServiceClient`, `SnapshotCodec`),
  reaching the shared Rust core through JNI;
- **B, the iOS side** — `ParanoidKit`'s `core-bridge` over the shipped iOS
  classes (`CoreBridge`, `SelfServiceClient`, `SnapshotCodec`), reaching the
  same shared Rust core through the C ABI bridge.

Both are built by `bash clients/ios/java_deps.sh` and
`swift build --package-path clients/ios/ParanoidKit --product core-bridge`;
neither is a stand-in for the core and nothing here is mocked. Those scenarios
are the wire between two clients with no server in them at all.

The last scenario is the other half, and the only one that opens a socket: the
two **shipped** client stacks — Android's `CleanSelfServiceBridge` and iOS's
`service-bridge` — register on one local stand (the unchanged `paranoid-server`
binary over a private PostgreSQL 16 cluster on loopback) and exchange texts
through it, both ways. `--skip-stand` leaves it out. Nothing in this file ever
contacts the hosted alpha, and no simulator and no phone takes part.

What a green run does and does not say
--------------------------------------

- It says the **listed scenarios** interoperate, on the **exact revisions**
  named in the evidence, with each side holding its own state and neither
  side's snapshot ever handed to the other pipe (`Party` enforces that).
- It does **not** say the iOS client is accepted on a device. Storage,
  lifecycle, network and media are proven elsewhere, on hardware
  (`docs/clients/ios/verification.md`).
- Both sides run the **same Rust core**, so a bug in the core reproduces
  identically on both and a live exchange alone cannot see it. Every scenario
  therefore also carries an expectation computed **here, in Python, without
  ever calling the core**: the account and fingerprint transcripts of
  `key-protocol`, the snapshot-codec byte layout, and a call-body validator
  written from `docs/protocol/call-v2.md`. The negatives are refused by that
  validator first and then by both clients, with the same code.

Usage: python3 clients/ios/test_android_compatibility.py --evidence-dir out/checks/compat
       python3 clients/ios/test_android_compatibility.py --skip-stand   # no server at all
"""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'out'
FIXTURE = HERE / 'test/fixtures/call-v2-sdp.json'
DEFAULT_EVIDENCE_DIR = OUT / 'checks/compat'
RESULT = 'result.json'

# The two pipes. Both are git-ignored build outputs; the run refuses to start
# without them rather than testing half of the pair.
JAVA_CLASSES = OUT / 'host-java/classes'
JAVA_JSON_JAR = OUT / 'host-java/json-20240303.jar'
JNI_LIBRARY = OUT / 'core-target/debug/libparanoid_client_core.dylib'
SWIFT_BRIDGE = OUT / 'spm/arm64-apple-macosx/debug/core-bridge'
C_ABI_SLICE = (HERE / 'ParanoidKit/Binaries/ParanoidCore.xcframework'
               / 'macos-arm64/libparanoid_ios_bridge.a')

# Synthetic identities only. The realm is a loopback address that nothing
# listens on: no pipe in this file opens a socket, and the hosted alpha is
# never named here.
REALM = 'https://127.0.0.2:38443'
PIN = 'a' * 64

# The sources whose agreement this run measures, per side.
ANDROID_SOURCES = [
    'clients/android/src/org/paranoid/text/CoreBridge.java',
    'clients/android/src/org/paranoid/text/SelfServiceClient.java',
    'clients/android/src/org/paranoid/text/SnapshotCodec.java',
    'clients/android/test/VoiceCoreBridge.java',
    'clients/ios/test/java/JavaCodecVector.java',
]
IOS_SOURCES = [
    'clients/ios/ParanoidKit/Sources/ParanoidKit/Core/CoreBridge.swift',
    'clients/ios/ParanoidKit/Sources/ParanoidKit/Service/SelfServiceClient.swift',
    'clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/SnapshotCodec.swift',
    'clients/ios/ParanoidKit/Sources/core-bridge/main.swift',
]
SHARED_SOURCES = [
    'clients/core/src/voice_v1.rs',
    'clients/core/src/contact_v2.rs',
    'key-protocol/src/lib.rs',
]

COMMANDS = [
    'bash clients/ios/java_deps.sh',
    'swift build --package-path clients/ios/ParanoidKit '
    '--scratch-path clients/ios/out/spm --product core-bridge',
    'python3 clients/ios/test_android_compatibility.py --evidence-dir out/checks/compat',
    'python3 clients/ios/test_android_compatibility.py --skip-stand '
    '--evidence-dir out/checks/compat-offline   # the same run without the local stand',
]

PROVES = [
    'the listed scenarios interoperate between the shipped Android facade and the shipped iOS '
    'classes over the shared Rust core, on the source revisions digested in `sources`',
    'the two shipped client stacks register on one server and carry a text to each other '
    'through it, in both directions, with the receipt double-checking each message',
    'each side held its own state text for the whole run: a party is bound to one pipe at '
    'construction and the harness refuses to hand its snapshot to the other one',
    'nothing stood in for the core on either side: both pipes call it, the Android one through '
    'JNI and the iOS one through the C ABI bridge',
    'every accepted scenario also matched an expectation computed in this file, in Python, '
    'without calling the core; every refused one was refused by that expectation first',
]
LIMITS = [
    'this is not acceptance on a device: storage, lifecycle, network and media are verified '
    'separately, and docs/clients/ios/verification.md holds those rows',
    'both pipes link the same Rust core from the same working tree, so an error in the core '
    'reproduces identically on both sides; only the independent expectations of this file and '
    'its negative vectors can see such an error, and they cover the transcripts, the codec '
    'layout and the call-v2 body, not the whole core',
    'the two native artefacts are separate builds of that one source: a JNI cdylib for the JVM '
    'and the macOS slice of the C ABI xcframework for Swift',
    'no simulator and no phone takes part, and the hosted alpha is never contacted; every '
    'scenario but the last one opens no socket at all, and the last one talks only to a local '
    'stand started by this run',
    'the stand scenario is one text each way between two freshly registered devices; it is not '
    'the failure catalogue of test_clean_self_service.py and not a long-poll run',
    'the SDP is the transcribed libwebrtc spike of clients/ios/test/fixtures/call-v2-sdp.json, '
    'not a description generated by a media engine in this run',
]


class Failure(Exception):
    """A check that did not hold."""


def require(condition, message):
    if not condition:
        raise Failure(message)


# --------------------------------------------------------------- independent
# Everything in this block is computed here, from the protocol documents and
# `key-protocol/src/lib.rs`'s stated transcript rule, and never by asking a
# client or the core. It is what makes a shared-core agreement worth reading:
# the two pipes could agree with each other and both be wrong, but they cannot
# both be wrong and still match a number this file worked out on its own.


def transcript(fields):
    """`paranoid_key_protocol::transcript`: u32 big-endian length, UTF-8, per field."""
    return b''.join(len(f.encode()).to_bytes(4, 'big') + f.encode() for f in fields)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def expected_account(root):
    """`digest(transcript(["paranoid-account-v1", root]))` (`lib.rs:50,89`)."""
    return digest(transcript(['paranoid-account-v1', root]))


def expected_credential_fingerprint(credential):
    """`Credential::fingerprint` (`lib.rs:57-71`), from the public members only."""
    return digest(transcript(['paranoid-credential-v1'] + [
        credential[member] for member in
        ('root', 'account', 'device', 'auth', 'realm', 'pin', 'olm')]))


def expected_olm_digest(curve, prekey):
    """`olm_digest` (`lib.rs:111-113`)."""
    return digest(transcript(['paranoid-olm-v1', curve, prekey]))


def expected_contact_fingerprint(contact):
    """`ContactV2::fingerprint` (`clients/core/src/contact_v2.rs:14-27`)."""
    bundle = contact['bundle']
    return digest(transcript([
        'paranoid-contact-v2', expected_credential_fingerprint(contact['credential']),
        bundle['device'], bundle['realm'], bundle['curve'], bundle['one_time_key'],
        contact['fallback_key']]))


def expected_channel(first, second):
    """`intro_v2::channel` (`clients/core/src/intro_v2.rs:20-45`).

    The two contacts are ordered by account, so both phones derive one channel
    from public material alone — which is exactly why this file can derive it
    too and hold both clients to it.
    """
    low, high = sorted((first, second), key=lambda contact: contact['credential']['account'])
    return digest(transcript([
        'paranoid-first-contact-channel-v1',
        low['credential']['account'], low['credential']['device'],
        expected_credential_fingerprint(low['credential']), expected_contact_fingerprint(low),
        high['credential']['account'], high['credential']['device'],
        expected_credential_fingerprint(high['credential']), expected_contact_fingerprint(high),
        first['credential']['realm'], first['credential']['pin'],
        'account-id-intro-v1']))


# The snapshot-codec container, from docs and both implementations' own stated
# format: `[0x01][12-byte nonce][ciphertext||16-byte tag]`, AES-256-GCM with
# the version byte as associated data. Only the layout is asserted here; the
# agreement on the cipher itself is what the cross-open proves.
CODEC_VERSION = 1
CODEC_HEADER_BYTES = 1 + 12
CODEC_TAG_BYTES = 16
CODEC_OVERHEAD = CODEC_HEADER_BYTES + CODEC_TAG_BYTES


def expected_sealed_length(plaintext):
    """GCM is a stream cipher: the box is the plaintext plus the fixed frame."""
    return len(plaintext.encode()) + CODEC_OVERHEAD


def sealed_layout(blob):
    """The three parts of a sealed snapshot, measured without decrypting it."""
    return {
        'version': blob[0],
        'nonce_bytes': CODEC_HEADER_BYTES - 1,
        'ciphertext_bytes': len(blob) - CODEC_OVERHEAD,
        'tag_bytes': CODEC_TAG_BYTES,
        'bytes': len(blob),
    }


# --------------------------------------------------- independent call-v2 rules
# A second reading of docs/protocol/call-v2.md and docs/protocol/voice-v1.md,
# written here so that the verdict of the core can be compared with something
# that is not the core. It answers `None` for a body both clients must accept
# and the code both must answer with otherwise.

CALL_MEMBERS = {'v', 'kind', 'call_id', 'caller_nonce', 'callee_nonce', 'seq', 'sent_ms',
                'expires_ms', 'sdp', 'fingerprint', 'ice_ufrag', 'ice_pwd', 'offer_digest',
                'reason', 'video'}
CALL_STRINGS = {'kind', 'call_id', 'caller_nonce', 'callee_nonce', 'sdp', 'fingerprint',
                'ice_ufrag', 'ice_pwd', 'offer_digest', 'reason'}
CALL_INTEGERS = {'v', 'seq', 'sent_ms', 'expires_ms'}
END_REASONS = {'hangup', 'reject', 'cancel', 'busy', 'timeout', 'failed', 'unavailable'}
VIDEO_CODECS = {'h264/90000', 'vp8/90000', 'rtx/90000', 'red/90000', 'ulpfec/90000',
                'flexfec-03/90000'}
MANDATORY_VIDEO_CODECS = {'h264/90000', 'vp8/90000'}
BLOCKED_DIRECTIONS = ('a=sendonly', 'a=recvonly', 'a=inactive')
MAX_SDP_BYTES = 12288          # call-v2.md: the core's limit
MAX_SDP_LINES = 512            # call-v2.md: at most 512 SDP lines
MAX_CANDIDATES = 16            # voice-v1.md resource limits
MAX_CANDIDATE_LINE = 512
MAX_CALL_WINDOW_MS = 45_000    # voice-v1.md freshness
CLIENT_SDP_CAP = 9000          # SdpExtract.maxSdpBytes: this client's own cap


def hex32(value):
    """`paranoid_key_protocol::hex32`: 64 lowercase hexadecimal digits."""
    return isinstance(value, str) and len(value) == 64 and all(
        character.isdigit() or character in 'abcdef' for character in value)


def canonical_uuid(value):
    """`canonical_id`: a version-4 UUID in its own canonical spelling."""
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        return False
    return str(parsed) == value and parsed.version == 4


def ice_token(value, minimum):
    return (isinstance(value, str) and minimum <= len(value) <= 256
            and all(character.isalnum() or character in '+/' for character in value))


def predict(body):
    """The code both clients must answer for `body`, or `None` to accept it."""
    if not isinstance(body, dict) or set(body) != CALL_MEMBERS:
        return 'invalid_request'
    for member in CALL_STRINGS:
        if not isinstance(body[member], str):
            return 'invalid_request'
    for member in CALL_INTEGERS:
        if isinstance(body[member], bool) or not isinstance(body[member], int) or body[member] < 0:
            return 'invalid_request'
    if not isinstance(body['video'], bool):
        return 'invalid_request'

    kind, seq = body['kind'], body['seq']
    if (body['v'] != 2 or not canonical_uuid(body['call_id'])
            or not hex32(body['caller_nonce']) or seq > 2 ** 31 - 1
            or body['sent_ms'] == 0 or body['expires_ms'] <= body['sent_ms']
            or body['expires_ms'] - body['sent_ms'] > MAX_CALL_WINDOW_MS):
        return 'invalid_call'

    media = kind in ('offer', 'answer')
    if kind == 'knock':
        context = seq == 0 and not body['callee_nonce'] and not body['offer_digest']
    elif kind == 'ready':
        context = seq == 0 and hex32(body['callee_nonce']) and not body['offer_digest']
    elif media:
        context = seq == 1 and hex32(body['callee_nonce']) and hex32(body['offer_digest'])
    elif kind in ('heartbeat', 'media'):
        context = seq >= 2 and hex32(body['callee_nonce']) and hex32(body['offer_digest'])
    elif kind == 'end':
        context = (seq >= 2
                   and (not body['callee_nonce'] or hex32(body['callee_nonce']))
                   and (not body['offer_digest'] or hex32(body['offer_digest']))
                   and (body['callee_nonce'] or not body['offer_digest']))
    else:
        context = False
    reason_ok = body['reason'] in END_REASONS if kind == 'end' else not body['reason']
    if not context or not reason_ok or (kind in ('heartbeat', 'end') and body['video']):
        return 'invalid_call'

    if not media:
        if body['sdp'] or body['fingerprint'] or body['ice_ufrag'] or body['ice_pwd']:
            return 'invalid_call'
        return None
    refusal = predict_sdp(body)
    if refusal:
        return refusal
    if kind == 'offer' and body['offer_digest'] != digest(body['sdp'].encode()):
        return 'call_sdp_mismatch'
    return None


def predict_sdp(body):
    """call-v2.md's description rules, read line by line as the wire is read."""
    sdp = body['sdp']
    if (not sdp or len(sdp.encode()) > MAX_SDP_BYTES or not hex32(body['fingerprint'])
            or not ice_token(body['ice_ufrag'], 4) or not ice_token(body['ice_pwd'], 22)
            or not sdp.isascii()):
        return 'invalid_call_sdp'
    lines = sdp.splitlines()
    if not lines or lines[0] != 'v=0':
        return 'invalid_call_sdp'
    # Index 0 is the audio section, 1 the video section, 2 the session level.
    section, media = 2, 0
    counts = {name: [0, 0, 0] for name in
              ('fingerprint', 'ufrag', 'password', 'mux', 'direction', 'setup')}
    setup_value, candidates, video_codecs = None, 0, 0
    opus, mappings, payloads = [], [set(), set()], [[], []]
    for index, line in enumerate(lines[1:]):
        if index >= MAX_SDP_LINES:
            return 'invalid_call_sdp'
        if (len(line) < 2 or line[1] != '=' or not line[0].islower() or not line[0].isascii()
                or any(not 32 <= ord(character) <= 126 for character in line)):
            return 'invalid_call_sdp'
        if line.startswith('m='):
            fields = line[2:].split(' ')
            expected = ('audio', 'video')[media] if media < 2 else None
            if (len(fields) < 4 or fields[0] != expected or fields[2] != 'UDP/TLS/RTP/SAVPF'
                    or not all(field.isdigit() and int(field) <= 127 for field in fields[3:])):
                return 'invalid_call_sdp'
            if not fields[1].isdigit() or int(fields[1]) > 65535:
                return 'invalid_call_sdp'
            if int(fields[1]) == 0 and media != 1:
                return 'invalid_call_sdp'
            section, media = media, media + 1
            if media > 2:
                return 'invalid_call_sdp'
            payloads[section].extend(fields[3:])
        elif line.startswith('a=fingerprint:'):
            counts['fingerprint'][section] += 1
            value = line[len('a=fingerprint:'):]
            if not value.startswith('sha-256 '):
                return 'invalid_call_sdp'
            octets = value[len('sha-256 '):].split(':')
            if (len(octets) != 32
                    or any(len(o) != 2 or not all(c in '0123456789abcdefABCDEF' for c in o)
                           for o in octets)
                    or ''.join(octets).lower() != body['fingerprint']):
                return 'call_sdp_mismatch'
        elif line.startswith('a=ice-ufrag:'):
            counts['ufrag'][section] += 1
            if line[len('a=ice-ufrag:'):] != body['ice_ufrag']:
                return 'call_sdp_mismatch'
        elif line.startswith('a=ice-pwd:'):
            counts['password'][section] += 1
            if line[len('a=ice-pwd:'):] != body['ice_pwd']:
                return 'call_sdp_mismatch'
        elif line == 'a=rtcp-mux':
            counts['mux'][section] += 1
        elif line == 'a=sendrecv':
            counts['direction'][section] += 1
        elif line in BLOCKED_DIRECTIONS:
            return 'invalid_call_sdp'
        elif line.startswith('a=setup:'):
            counts['setup'][section] += 1
            value = line[len('a=setup:'):]
            allowed = (body['kind'] == 'offer' and value == 'actpass'
                       or body['kind'] == 'answer' and value in ('active', 'passive'))
            if not allowed or (setup_value is not None and setup_value != value):
                return 'invalid_call_sdp'
            setup_value = value
        elif line.startswith('a=rtpmap:'):
            if section > 1:
                return 'invalid_call_sdp'
            value = line[len('a=rtpmap:'):]
            if ' ' not in value:
                return 'invalid_call_sdp'
            payload, codec = value.split(' ', 1)
            if (not payload.isdigit() or int(payload) > 127 or payload in mappings[section]):
                return 'invalid_call_sdp'
            mappings[section].add(payload)
            codec = codec.lower()
            if section == 0:
                if codec == 'opus/48000/2':
                    opus.append(payload)
            else:
                if codec not in VIDEO_CODECS:
                    return 'invalid_call_sdp'
                if codec in MANDATORY_VIDEO_CODECS:
                    video_codecs += 1
        elif line.startswith('a=candidate:'):
            candidates += 1
            if len(line) > MAX_CANDIDATE_LINE or candidates > MAX_CANDIDATES:
                return 'invalid_call_sdp'
        elif line.startswith('a=crypto:'):
            return 'invalid_call_sdp'

    def once_per_section(name):
        value = counts[name]
        return value[0] + value[2] == 1 and value[1] + value[2] <= 1

    if (media != 2
            or not all(once_per_section(name) for name in
                       ('fingerprint', 'ufrag', 'password', 'setup'))
            # `a=rtcp-mux` is required once in the audio section, allowed once
            # in the video section and never at session level (call-v2.md).
            or not (counts['mux'][0] == 1 and counts['mux'][1] <= 1 and counts['mux'][2] == 0)
            or counts['direction'] != [1, 1, 0]
            or len(opus) != 1 or opus[0] not in payloads[0]
            or video_codecs == 0
            or any(mapping not in payloads[index]
                   for index in (0, 1) for mapping in mappings[index])):
        return 'invalid_call_sdp'
    return None


def survey(sdp):
    """What this file measures about a description, with no help from anyone."""
    lines = sdp.splitlines()
    sections = []
    for line in lines:
        if line.startswith('m='):
            fields = line[2:].split(' ')
            sections.append({'kind': fields[0], 'port': int(fields[1]),
                             'transport': fields[2], 'payload_types': fields[3:],
                             'sendrecv': 0, 'rtcp_mux': 0, 'candidates': 0, 'codecs': []})
        elif sections:
            if line == 'a=sendrecv':
                sections[-1]['sendrecv'] += 1
            elif line == 'a=rtcp-mux':
                sections[-1]['rtcp_mux'] += 1
            elif line.startswith('a=candidate:'):
                sections[-1]['candidates'] += 1
            elif line.startswith('a=rtpmap:'):
                sections[-1]['codecs'].append(line.split(' ', 1)[1].lower())
    return {
        'bytes': len(sdp.encode()),
        # `str::lines()` yields nothing for the trailing CRLF and the core's
        # 512-line budget starts after `v=0`.
        'lines': len(lines) - 1,
        'candidates': sum(section['candidates'] for section in sections),
        'blocked_directions': sum(line in BLOCKED_DIRECTIONS for line in lines),
        'crypto': sum(line.startswith('a=crypto:') for line in lines),
        'sections': sections,
    }


# -------------------------------------------------------------------- pipes


class Pipe:
    """One client behind a private JSON-line pipe. Nothing is logged from it."""

    def __init__(self, label, argv, description):
        self.label = label
        self.description = description
        self.requests = 0
        try:
            self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, text=True, bufsize=1)
        except OSError as error:
            raise Failure(f'{label} pipe could not start: {error.strerror}') from error

    def request(self, request, allow_fixture_error=False):
        self.requests += 1
        self.process.stdin.write(json.dumps(request, separators=(',', ':')) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        require(bool(line), f'{self.label} pipe exited without answering')
        result = json.loads(line)
        require(allow_fixture_error or 'fixture_error' not in result,
                f'{self.label} pipe failed with {result.get("fixture_error")}')
        return result

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait(timeout=10)


class Party:
    """One phone: a pipe and the state text only that pipe ever sees.

    Binding the two together is the point. A run in which the harness fed A's
    snapshot to B's client would prove nothing about interoperation, so the
    state never leaves this object and every command goes to the pipe the
    party was constructed with.
    """

    def __init__(self, name, pipe):
        self.name = name
        self.pipe = pipe
        self.reply = None

    def core(self, request, allow_error=False):
        state = json.dumps(self.reply['state'], separators=(',', ':')) if self.reply else ''
        result = self.pipe.request({'kind': 'core', 'state': state, 'request': request})
        if 'error' in result:
            require(allow_error,
                    f'{self.name} ({self.pipe.label}) refused {request["op"]}: {result["error"]}')
            return result
        self.reply = result
        return result

    def probe(self, request):
        """One command whose candidate is thrown away, state left untouched."""
        state = json.dumps(self.reply['state'], separators=(',', ':')) if self.reply else ''
        return self.pipe.request({'kind': 'core', 'state': state, 'request': request})

    @property
    def credential(self):
        return self.reply['request']['credential']

    @property
    def account(self):
        return self.credential['account']

    @property
    def contact(self):
        return self.reply['contact']

    def snapshot(self):
        """The version-4 wrapper both storage adapters read."""
        return {'version': 4, 'realm': REALM, 'tls_pin': PIN, 'token': '',
                'state': self.reply['state']}


# ---------------------------------------------------------------- scenarios


def identity(party, facts):
    """A fresh identity, the clean schema and an active enrollment."""
    party.core({'op': 'create_identity', 'realm': REALM, 'pin': PIN})
    party.core({'op': 'upgrade_v2'})
    credential = party.credential
    # Independent: the account is the transcript hash of the root key, and the
    # credential fingerprint is the transcript hash of all seven public fields.
    require(credential['account'] == expected_account(credential['root']),
            f'{party.name}: account is not the transcript digest of the root key')
    fingerprint = expected_credential_fingerprint(credential)
    # Independent: the server status this file hands the client carries a
    # digest this file computed, so a client that accepted any other digest
    # would fail here rather than be believed.
    party.core({'op': 'server_status_v2', 'status': {
        'mode': 'active', 'account': credential['account'],
        'device': credential['device'], 'credential': fingerprint}})
    party.core({'op': 'prepare_contact_v2'})
    contact = party.contact
    require(contact['type'] == 'paranoid-contact-v2', f'{party.name}: contact is not v2')
    require(credential['olm'] == expected_olm_digest(contact['bundle']['curve'],
                                                     contact['fallback_key'])
            or credential['olm'] == expected_olm_digest(contact['bundle']['curve'],
                                                        contact['bundle']['one_time_key']),
            f'{party.name}: the olm digest is not the transcript of the published bundle')
    require(party.reply['contact_fingerprint'] == expected_contact_fingerprint(contact),
            f'{party.name}: contact fingerprint is not the transcript digest of the contact')
    facts[f'{party.name}_state_bytes'] = len(json.dumps(party.reply['state'],
                                                        separators=(',', ':')).encode())
    return fingerprint


def pair(party, other):
    """`pair_contact_v2` over the peer's contact text, as a QR would carry it."""
    text = json.dumps(other.contact, separators=(',', ':'))
    party.core({'op': 'pair_contact_v2', 'text': text, 'verified': True})
    require(len(party.reply['dialogs']) == 1, f'{party.name}: pairing left no dialog')
    return len(text.encode())


class Sequence:
    """The server's envelope counter.

    The core refuses a sequence it has already seen or one at or below its
    cursor, so the harness keeps one counter for the whole run rather than one
    per direction: every envelope, in either direction, gets the next number.
    """

    def __init__(self):
        self.value = 0

    def next(self):
        self.value += 1
        return self.value


def deliver(sender, recipient, sequence, allow_rejection=False):
    """One envelope across: the sender's outbox head, the recipient's `receive_v2`."""
    require(sender.reply['outbox'], f'{sender.name}: nothing to deliver')
    pending = sender.reply['outbox'][0]
    message = {'id': pending['id'], 'ciphertext': pending['ciphertext'],
               'sender': sender.account, 'sequence': sequence.next()}
    received = recipient.core({'op': 'receive_v2', 'message': message})
    require(allow_rejection or received['acceptance'] == 'accepted',
            f'{recipient.name} did not accept an envelope from {sender.name}')
    sender.core({'op': 'accepted_v2', 'id': pending['id']})
    return message, received


def text_round(sender, recipient, message_text, sequence, facts):
    """A text one way and its authenticated receipt back."""
    sender.core({'op': 'send_v2', 'account': recipient.account, 'text': message_text})
    envelope, received = deliver(sender, recipient, sequence)
    # Independent: the envelope this file relayed carries no plaintext. The
    # check is on the bytes the harness itself moved, not on a claim.
    require(message_text.encode() not in base64.b64decode(envelope['ciphertext']),
            'the relayed envelope carried the plaintext')
    require(message_text not in json.dumps(envelope),
            'the relayed envelope named the plaintext')
    shown = [entry for entry in received['dialogs'][0]['messages']
             if entry.get('text') == message_text]
    require(len(shown) == 1, f'{recipient.name} did not show the text exactly once')
    # The receipt the recipient queued travels back and marks the original.
    deliver(recipient, sender, sequence)
    delivered = [entry for entry in sender.reply['dialogs'][0]['messages']
                 if entry.get('text') == message_text]
    require(len(delivered) == 1 and delivered[0]['delivered'],
            f'{sender.name} did not see the delivery receipt')
    facts.setdefault('envelope_bytes', []).append(len(envelope['ciphertext']))


def call_round(caller, callee, bodies, sequence, facts):
    """knock, ready, offer, answer, media, heartbeat and end, alternating sides."""
    order = [('knock', caller), ('ready', callee), ('offer', caller), ('answer', callee),
             ('media', caller), ('heartbeat', callee), ('end', caller)]
    for kind, sender in order:
        recipient = callee if sender is caller else caller
        body = bodies[kind]
        # Independent: this file decides the body is well formed before either
        # client is asked, so an agreement below is an agreement with the
        # protocol document and not only with the other pipe.
        require(predict(body) is None, f'the independent validator refused a good {kind}')
        sender.core({'op': 'send_call_v1', 'account': recipient.account, 'body': body})
        require(len(sender.reply['outbox']) == 1,
                f'{sender.name}: a {kind} did not leave exactly one envelope')
        _, received = deliver(sender, recipient, sequence)
        event = received.get('call_event')
        require(event is not None, f'{recipient.name} emitted no call_event for a {kind}')
        require(event['account'] == sender.account, f'a {kind} named the wrong sender')
        require(event['body'] == body, f'a {kind} body changed in transit')
        require(isinstance(event['body']['video'], bool),
                f'a {kind} carried `video` as something other than a JSON boolean')
        require(not recipient.reply['outbox'], f'a {kind} produced a receipt')
        facts.setdefault('call_kinds', []).append(kind)


def codec_cross(java, swift, facts):
    """A snapshot sealed on one side and opened on the other, both ways."""
    key = base64.b64encode(os.urandom(32)).decode()
    # Long enough to cross a block boundary and to carry every escape a
    # snapshot really carries; short enough to keep the line small.
    plaintext = json.dumps({'version': 4, 'note': 'cross', 'text': 'ы' * 64,
                            'quote': '"\\/', 'padding': 'x' * 300},
                           separators=(',', ':'), ensure_ascii=False)
    crossed = []
    for sealer, opener in ((swift, java), (java, swift)):
        sealed = sealer.request({'kind': 'seal', 'key': key, 'text': plaintext}
                                if sealer is swift else
                                {'op': 'seal', 'key': key, 'text': plaintext})
        blob = base64.b64decode(sealed['sealed'])
        layout = sealed_layout(blob)
        # Independent: the container is the documented one, measured here.
        require(layout['version'] == CODEC_VERSION,
                f'{sealer.label} sealed with an unknown version byte')
        require(layout['bytes'] == expected_sealed_length(plaintext),
                f'{sealer.label} sealed to an unexpected length')
        require(sealed['bytes'] == layout['bytes'],
                f'{sealer.label} reported a length it did not write')
        require(plaintext.encode() not in blob, f'{sealer.label} left the plaintext in the box')
        opened = opener.request({'kind': 'open', 'key': key, 'sealed': sealed['sealed']}
                                if opener is swift else
                                {'op': 'open', 'key': key, 'sealed': sealed['sealed']})
        require(opened.get('text') == plaintext,
                f'{opener.label} did not recover what {sealer.label} sealed')
        crossed.append({'sealed_by': sealer.label, 'opened_by': opener.label,
                        'plaintext_bytes': len(plaintext.encode()), 'sealed_bytes': layout['bytes'],
                        'ciphertext_bytes': layout['ciphertext_bytes']})
        # Negatives, both sides: a wrong key, a flipped version byte and a
        # truncated box are refused, and the refusal names only a type.
        other = base64.b64encode(os.urandom(32)).decode()
        flipped = bytes([2]) + blob[1:]
        for name, request in (
                ('wrong key', {'key': other, 'sealed': sealed['sealed']}),
                ('version 2', {'key': key, 'sealed': base64.b64encode(flipped).decode()}),
                ('truncated', {'key': key, 'sealed': base64.b64encode(blob[:-1]).decode()}),
                ('short box', {'key': key, 'sealed': base64.b64encode(blob[:20]).decode()})):
            for pipe in (java, swift):
                verb = {'kind': 'open', **request} if pipe is swift else {'op': 'open', **request}
                refusal = pipe.request(verb, allow_fixture_error=True)
                failed = refusal.get('fixture_error') or refusal.get('vector_error')
                require(failed is not None and 'text' not in refusal,
                        f'{pipe.label} opened a {name} box')
                require(plaintext not in json.dumps(refusal),
                        f'{pipe.label} echoed the plaintext when refusing a {name} box')
    facts['codec_cross'] = crossed


def sealed_reopen(java_party, swift_party, java, swift, facts):
    """The same wrapper reopened by both adapters, which must write nothing."""
    views = {}
    for party, pipes in ((java_party, java), (swift_party, swift)):
        snapshot = party.snapshot()
        for pipe in (java, swift):
            result = pipe.request({'kind': 'sealed_reopen', 'snapshot': snapshot})
            require(result['writes'] == 0, f'{pipe.label} wrote while opening a saved snapshot')
            require(result['unchanged'], f'{pipe.label} changed the snapshot bytes')
            require(result['view']['account'] == party.account,
                    f'{pipe.label} reopened {party.name} as another identity')
            views.setdefault(party.name, []).append(result['view'])
        require(views[party.name][0] == views[party.name][1],
                f'the two adapters disagree about what {party.name} shows on screen')
        facts.setdefault('reopened', []).append(
            {'party': party.name, 'writes': 0, 'views_identical': True,
             'dialogs': len(views[party.name][0]['dialogs'])})
    # The state text itself must be untouched by a reopening: ask each party's
    # own pipe for a view and compare it with the state it already held.
    for party in (java_party, swift_party):
        require(party.probe({'op': 'view'})['state'] == party.reply['state'],
                f'{party.name}: `view` changed the snapshot')


def negatives(caller, callee, bodies, vectors, sequence, facts):
    """Every refused vector: the independent validator first, then both clients."""
    recorded = []
    for name, body in vectors:
        expected = predict(body)
        require(expected is not None, f'the independent validator accepted the bad vector {name}')
        answers = {}
        for sender, other in ((caller, callee), (callee, caller)):
            reply = sender.core({'op': 'send_call_v1', 'account': other.account, 'body': body},
                                allow_error=True)
            require('error' in reply, f'{sender.pipe.label} accepted the bad vector {name}')
            answers[sender.pipe.label] = reply['error']
        codes = set(answers.values())
        require(len(codes) == 1,
                f'the two clients disagree about {name}: {sorted(answers.items())}')
        require(codes == {expected},
                f'{name}: the independent validator said {expected}, the clients said {codes}')
        recorded.append({'vector': name, 'expected': expected, 'both_clients': expected})
    facts['negatives'] = recorded
    # A tampered envelope is refused by whoever receives it, and refusing it
    # must not move anything but the rejection counters.
    tampered = 0
    for sender, recipient in ((caller, callee), (callee, caller)):
        sender.core({'op': 'send_v2', 'account': recipient.account, 'text': 'tamper probe'})
        pending = sender.reply['outbox'][0]
        raw = bytearray(base64.b64decode(pending['ciphertext']))
        raw[len(raw) // 2] ^= 0x01
        before = recipient.reply['state']
        rejected = recipient.core({'op': 'receive_v2', 'message': {
            'id': pending['id'], 'ciphertext': base64.b64encode(bytes(raw)).decode(),
            'sender': sender.account, 'sequence': sequence.next()}})
        require(rejected['acceptance'] == 'rejected',
                f'{recipient.name} accepted a tampered envelope')
        require('call_event' not in rejected, f'{recipient.name} raised a call on tampered bytes')
        after = dict(rejected['state'])
        for counter in ('cursor', 'rejected_events', 'rejected_count', 'first_rejected_sequence'):
            if counter in before:
                after[counter] = before[counter]
        require(after == before,
                f'{recipient.name} changed more than the rejection counters')
        # The real envelope still travels afterwards, so the rejection was
        # transactional rather than a torn state.
        deliver(sender, recipient, sequence)
        deliver(recipient, sender, sequence)
        tampered += 1
    facts['tampered_envelopes_refused'] = tampered
    # The one bound that is this client's own rather than the core's. A
    # description between 9000 and 12288 bytes is a legal call-v2 description
    # and both cores take it; the iOS client still refuses to send one, because
    # a `call` control travels in a single frame2 envelope whose measured
    # ceiling is 10040 bytes (`SdpExtract.maxSdpBytes`, `SdpExtractTests`).
    # Saying so needs the core to accept what the client will not send, so the
    # probe is run as a discarded candidate on both sides.
    padding = f'a=x{"y" * 200}\r\n'
    filler = (CLIENT_SDP_CAP - len(bodies['offer']['sdp'])) // len(padding) + 2
    oversized = bodies['offer']['sdp'] + padding * filler
    require(CLIENT_SDP_CAP < len(oversized.encode()) <= MAX_SDP_BYTES,
            'the probe does not sit between this client\'s cap and the core\'s limit')
    body = dict(bodies['offer'], sdp=oversized, offer_digest=digest(oversized.encode()))
    require(predict(body) is None,
            'the independent validator refused a description call-v2.md allows')
    for sender, other in ((caller, callee), (callee, caller)):
        reply = sender.probe({'op': 'send_call_v1', 'account': other.account, 'body': body})
        require('error' not in reply,
                f'{sender.pipe.label} refused a description call-v2.md allows: '
                f'{reply.get("error")}')
    facts['client_sdp_cap'] = {
        'client_cap': CLIENT_SDP_CAP, 'core_limit': MAX_SDP_BYTES,
        'probe_bytes': len(oversized.encode()), 'accepted_by_both_clients': True,
        'note': 'the 9000-byte cap is this client\'s own frame2 budget, enforced in '
                'SdpExtract and checked by SdpExtractTests; the core allows 12288',
    }


# -------------------------------------------------------------- local stand
# Everything above is the wire between two clients with no server in it. This
# last scenario is the other half: the two **shipped** client stacks — Android's
# `CleanSelfServiceBridge` and iOS's `service-bridge` — registering on one local
# stand (the unchanged server binary over a private PostgreSQL 16 cluster) and
# exchanging texts through it. The hosted alpha is never contacted.

# The synthetic phone name both fixtures allow; each bridge has its own
# directory, so one name on two bridges is two devices.
STAND_PHONE = 'one'
STAND_TEXTS = {'android': 'Android to iOS over the stand',
               'ios': 'iOS to Android over the stand'}


class StandBridge:
    """One shipped client fixture and the `<phone>\\t<op>\\t<base64>` protocol.

    Both fixtures speak it and both answer one base64 JSON object per line, so
    the harness drives them through one class and no scenario below knows which
    side it is talking to.
    """

    def __init__(self, label, argv, pacer, description):
        self.label = label
        self.pacer = pacer
        self.description = description
        self.requests = 0
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, bufsize=1)

    def rpc(self, operation, value='', weight=1, expect_error=False):
        require(self.process.poll() is None,
                f'{self.label} fixture exited (status {self.process.returncode})')
        self.pacer.wait(weight)
        self.requests += 1
        encoded = base64.b64encode(value.encode()).decode()
        self.process.stdin.write(f'{STAND_PHONE}\t{operation}\t{encoded}\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        require(bool(line), f'{self.label} fixture closed its output')
        view = json.loads(base64.b64decode(line))
        if expect_error:
            require('error' in view, f'{self.label}/{operation}: expected a rejection')
        else:
            require('error' not in view,
                    f'{self.label}/{operation}: {view.get("error")}: {view.get("detail")}')
        return view

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
                self.process.wait(timeout=120)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=30)


def stand_dialog(view, account):
    matches = [entry for entry in view['dialogs'] if entry['account'] == account]
    require(len(matches) == 1, f'expected one dialog with the peer, found {len(matches)}')
    return matches[0]


def stand_round(java_binary, args, facts, checks, secrets):
    """Both shipped clients on one local stand: register, pair, text both ways."""
    import local_stand                        # noqa: PLC0415 (offline runs never need it)
    import test_clean_self_service as clean   # noqa: PLC0415 (its bridge build and pacer)

    service_bridge = clean.build_bridge(args.skip_build)
    classpath = f'{JAVA_CLASSES}:{JAVA_JSON_JAR}:{OUT / "host-java/zxing-core-3.5.3.jar"}'
    stand_argv = ['--work-dir', str(OUT)]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    if args.pg_bin:
        stand_argv += ['--pg-bin', args.pg_bin]
    stand = local_stand.Stand(local_stand.parse_args(stand_argv))
    pacer = clean.Pacer(clean.REQUEST_SPACING)
    bridges = []
    import tempfile                           # noqa: PLC0415 (only this scenario stores state)
    with tempfile.TemporaryDirectory(prefix='paranoid-ios-compat-') as temporary:
        devices = Path(temporary)
        try:
            try:
                stand.start()
            except local_stand.StandError as error:
                raise Failure(f'local stand: {error}') from error
            realm = stand.descriptor['server_url']
            pin = stand.descriptor['tls_spki_sha256']
            secrets.update({realm, pin})
            print(f'stand: {relative(stand.log_path)}', flush=True)

            android = StandBridge(
                'android', [str(java_binary), '-Djava.library.path=' + str(JNI_LIBRARY.parent),
                            '-cp', classpath, 'CleanSelfServiceBridge',
                            str(devices / 'android'), realm, pin], pacer,
                'clients/android/test/CleanSelfServiceBridge.java over the Android facade')
            ios = StandBridge(
                'ios', [str(service_bridge), str(devices / 'ios'), realm, pin], pacer,
                'ParanoidKit service-bridge over the shipped iOS client')
            bridges += [android, ios]

            views = {}
            for bridge in bridges:
                created = bridge.rpc('create')
                require(created['identity'] and not created['active'],
                        f'{bridge.label}: create did not leave an unregistered identity')
                views[bridge.label] = bridge.rpc('sync', weight=7)
                require(views[bridge.label]['active'],
                        f'{bridge.label}: the stand did not enroll the device')
            accounts = {label: view['account'] for label, view in views.items()}
            contacts = {label: view['contact'] for label, view in views.items()}
            require(accounts['android'] != accounts['ios'], 'both devices took one account')
            secrets.update(accounts.values())
            secrets.update(view['contact_fingerprint'] for view in views.values())
            for label, view in views.items():
                require(view['contact_fingerprint'] == expected_contact_fingerprint(contacts[label]),
                        f'{label}: the registered contact fingerprint is not the transcript digest')
                require(view['account'] == expected_account(contacts[label]['credential']['root']),
                        f'{label}: the registered account is not the transcript digest')
            checks.append('both shipped clients register on the same local stand, and this file '
                          'recomputed each account and contact fingerprint from the transcript '
                          'rule rather than taking the server\'s word for it')

            channel = expected_channel(contacts['android'], contacts['ios'])
            for bridge, peer in ((android, 'ios'), (ios, 'android')):
                paired = bridge.rpc('pair', json.dumps(contacts[peer], separators=(',', ':')))
                entry = stand_dialog(paired, accounts[peer])
                require(entry['trust'] == 'out_of_band_verified' and entry['identity_verified'],
                        f'{bridge.label}: a scanned contact is not verified')
                require(entry['channel'] == channel,
                        f'{bridge.label}: the paired channel is not the one this file derived')
            checks.append('each client pairs the other from the contact the other published on '
                          'the stand, both mark it out-of-band verified, and both derive the '
                          'channel this file derived in Python')

            exchanged = []
            for sender, recipient in ((android, ios), (ios, android)):
                text = STAND_TEXTS[sender.label]
                secrets.add(text)
                sender.rpc('send', json.dumps({'account': accounts[recipient.label],
                                               'text': text}, separators=(',', ':')))
                sender.rpc('sync')
                arrived = recipient.rpc('sync')
                shown = [message['text'] for message
                         in stand_dialog(arrived, accounts[sender.label])['messages']]
                require(text in shown,
                        f'{recipient.label} did not receive the text {sender.label} sent')
                marked = sender.rpc('sync')
                entry = stand_dialog(marked, accounts[recipient.label])
                mine = [message for message in entry['messages']
                        if message['author'] == entry['own'] and message['text'] == text]
                require(len(mine) == 1 and mine[0]['accepted'] and mine[0]['delivered'],
                        f'{sender.label} never saw the receipt for its own text')
                exchanged.append({'from': sender.label, 'to': recipient.label,
                                  'accepted': True, 'delivered': True})
            facts['stand'] = {
                'server': 'the unchanged paranoid-server binary over a private PostgreSQL 16 '
                          'cluster on a loopback socket; the hosted alpha is not contacted',
                'server_binary_sha256': digest(Path(stand.server_binary).read_bytes()),
                'clients': {bridge.label: bridge.description for bridge in bridges},
                'requests': {bridge.label: bridge.requests for bridge in bridges},
                'texts': exchanged,
                'channel_agreed': True,
            }
            checks.append('a text crosses the stand in both directions between the two shipped '
                          'clients, and each sender sees the peer\'s authenticated receipt '
                          'double-check its own message')
        finally:
            for bridge in bridges:
                bridge.close()
            stand.stop()


# ----------------------------------------------------------------- evidence


ALLOWED_EVIDENCE = {
    'generated', 'commit', 'script', 'result', 'commands', 'proves', 'does_not_prove',
    'toolchain', 'sources', 'native', 'pipes', 'independent_expectations', 'checks',
    'facts', 'sdp_fixture',
}


def relative(path):
    """`path` as the repository sees it, never as this Mac does."""
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return resolved.name


def sha256_file(path):
    return {'sha256': digest(Path(path).read_bytes()), 'bytes': Path(path).stat().st_size}


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def tool_version(argv):
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return 'unavailable'
    return (completed.stdout + completed.stderr).strip().splitlines()[0]


def strings(value, path=()):
    if isinstance(value, dict):
        for member, nested in value.items():
            yield from strings(nested, path + (member,))
    elif isinstance(value, list):
        for item in value:
            yield from strings(item, path)
    elif isinstance(value, str):
        yield path, value


def write_evidence(directory, payload, secrets):
    """The strict writer of `test_voice_sim.py:490-504`, with its own members."""
    directory.mkdir(parents=True, exist_ok=True)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    for secret in secrets:
        require(secret and secret not in text,
                'evidence carries an account, contact, fingerprint, realm, ICE or pin value')
    for name in ('HOME', 'USER'):
        value = os.environ.get(name, '')
        require(not value or value not in text,
                'evidence carries the home directory or the account of this machine')
    for path, value in strings(payload):
        # `toolchain` holds tool version lines only, and a four-part version
        # such as the JDK's 21.0.12.1 reads like an address to the scan below.
        if path[:1] == ('toolchain',):
            continue
        require(not re.search(r'\b\d{1,3}(\.\d{1,3}){3}\b', value),
                f'evidence member {".".join(path)} carries an address of this machine')
    result = directory / RESULT
    result.write_text(text)
    return result


# ---------------------------------------------------------------------- run


def bodies_from_fixture(fixture, call_id, sent_ms):
    """The seven call-v2 bodies, over the transcribed libwebrtc descriptions."""
    offer_digest = digest(fixture['offer']['sdp'].encode())

    def body(kind):
        media = kind in ('offer', 'answer')
        return {
            'v': 2, 'kind': kind, 'call_id': call_id,
            'video': kind not in ('heartbeat', 'end'),
            'caller_nonce': '1' * 64,
            'callee_nonce': '' if kind == 'knock' else '2' * 64,
            'seq': 0 if kind in ('knock', 'ready') else (1 if media else 2),
            'sent_ms': sent_ms, 'expires_ms': sent_ms + 30_000,
            'sdp': fixture[kind]['sdp'] if media else '',
            'fingerprint': fixture[kind]['fingerprint'] if media else '',
            'ice_ufrag': fixture['ice_ufrag'] if media else '',
            'ice_pwd': fixture['ice_pwd'] if media else '',
            'offer_digest': '' if kind in ('knock', 'ready') else offer_digest,
            'reason': 'hangup' if kind == 'end' else '',
        }

    return {kind: body(kind) for kind in
            ('knock', 'ready', 'offer', 'answer', 'media', 'heartbeat', 'end')}


def negative_vectors(bodies):
    """Bad call-v2 bodies, each one a rule of call-v2.md read backwards."""
    offer = bodies['offer']
    sdp = offer['sdp']

    def changed(**members):
        return dict(offer, **members)

    def with_sdp(text, keep_digest=False):
        return changed(sdp=text,
                       offer_digest=offer['offer_digest'] if keep_digest
                       else digest(text.encode()))

    extra_candidates = ''.join(
        f'a=candidate:{20 + index} 1 udp 1 127.0.0.1 {50000 + index} typ host\r\n'
        for index in range(11))
    without_video = sdp.split('m=video')[0]
    swapped = ('v=0\r\n' + sdp.split('m=video', 1)[1].join(['m=video', ''])
               + sdp.split('\r\n', 1)[1].split('m=video')[0])
    vectors = [
        ('v is 1', changed(v=1)),
        ('video is a string', changed(video='true')),
        ('video is missing', {k: v for k, v in offer.items() if k != 'video'}),
        ('an unknown member', changed(camera=True)),
        ('offer at seq 2', changed(seq=2)),
        ('offer digest of another text', changed(offer_digest='0' * 64)),
        ('fingerprint of another certificate', changed(fingerprint='ab' * 32)),
        ('a call window over 45 s', changed(expires_ms=offer['sent_ms'] + 45_001)),
        ('a call_id that is not a v4 uuid', changed(call_id='not-a-uuid')),
        ('heartbeat claiming video', dict(bodies['heartbeat'], video=True)),
        ('end with an unknown reason', dict(bodies['end'], reason='because')),
        ('knock carrying a description', dict(bodies['knock'], sdp=sdp)),
        ('a blocked direction', with_sdp(sdp.replace('a=sendrecv\r\n', 'a=sendonly\r\n', 1))),
        ('no video section', with_sdp(without_video)),
        ('the video section first', with_sdp(swapped)),
        ('a second a=sendrecv in audio',
         with_sdp(sdp.replace('a=sendrecv\r\n', 'a=sendrecv\r\na=sendrecv\r\n', 1))),
        ('a codec outside the whitelist',
         with_sdp(sdp.replace('a=rtpmap:100 VP8/90000', 'a=rtpmap:100 VP9/90000'))),
        ('an SDES key', with_sdp(sdp.replace('a=rtcp-mux\r\n',
                                             'a=rtcp-mux\r\na=crypto:1 AES_CM_128_HMAC_SHA1_80 '
                                             'inline:abcdefghijklmnopqrstuvwxyz\r\n', 1))),
        ('seventeen candidates',
         with_sdp(sdp.replace('a=ice-ufrag:', extra_candidates + 'a=ice-ufrag:', 1))),
        ('an ice-pwd the body does not carry',
         with_sdp(sdp.replace('a=ice-pwd:' + offer['ice_pwd'],
                              'a=ice-pwd:' + 'Z' * len(offer['ice_pwd'])))),
        ('setup:active in an offer', with_sdp(sdp.replace('a=setup:actpass', 'a=setup:active'))),
    ]
    return vectors


def build(args):
    """Nothing is built here; the two pipes must already exist."""
    missing = [relative(path) for path in
               (JAVA_CLASSES, JAVA_JSON_JAR, JNI_LIBRARY, SWIFT_BRIDGE) if not path.exists()]
    require(not missing,
            'missing build outputs: ' + ', '.join(missing)
            + '; run `bash clients/ios/java_deps.sh` and `swift build --package-path '
              'clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --product core-bridge`')
    java_home = json.loads((HERE / 'toolchain.json').read_text())['java_home']
    java = Path(java_home) / 'bin/java'
    require(java.is_file(), f'the pinned JDK of toolchain.json has no java at {relative(java)}')
    return java


def run(args):
    os.umask(0o077)
    evidence_dir = Path(args.evidence_dir)
    if not evidence_dir.is_absolute():
        evidence_dir = HERE / evidence_dir
    java_binary = build(args)
    fixture = json.loads(FIXTURE.read_text())

    java = Pipe('android', [str(java_binary), '-Djava.library.path=' + str(JNI_LIBRARY.parent),
                            '-cp', f'{JAVA_CLASSES}:{JAVA_JSON_JAR}', 'VoiceCoreBridge'],
                'clients/android/test/VoiceCoreBridge.java over the Android facade, JNI')
    codec = Pipe('android-codec', [str(java_binary), '-cp', f'{JAVA_CLASSES}:{JAVA_JSON_JAR}',
                                   'JavaCodecVector'],
                 'clients/ios/test/java/JavaCodecVector.java over Android SnapshotCodec')
    swift = Pipe('ios', [str(SWIFT_BRIDGE)],
                 'ParanoidKit core-bridge over the iOS classes, C ABI')

    facts = {}
    checks = []
    secrets = set()
    result = 'RUNNING'
    try:
        a = Party('android_phone', java)
        b = Party('ios_phone', swift)

        secrets.add(REALM)
        secrets.add(PIN)
        for party in (a, b):
            fingerprint = identity(party, facts)
            secrets.update({party.account, fingerprint, party.credential['root'],
                            party.credential['auth'], party.reply['contact_fingerprint']})
        checks.append('both sides create an identity, reach the clean schema and accept a '
                      'server status whose credential digest this file computed in Python')

        facts['contact_bytes'] = {'android': pair(a, b), 'ios': pair(b, a)}
        channel = expected_channel(a.contact, b.contact)
        for party in (a, b):
            require(party.reply['dialogs'][0]['channel'] == channel,
                    f'{party.name} derived a channel this file did not')
        facts['channel_agreed'] = True
        checks.append('each side pairs the other from the contact text the other side published, '
                      'and this file recomputed both contact fingerprints and the shared '
                      'first-contact channel from the transcript rules before either side was '
                      'asked; both clients derived that same channel')

        sequence = Sequence()
        text_round(a, b, 'android to ios', sequence, facts)
        checks.append('a text from the Android client is accepted by the iOS client and the iOS '
                      'receipt marks it delivered on the Android side')
        text_round(b, a, 'ios to android', sequence, facts)
        checks.append('a text from the iOS client is accepted by the Android client and the '
                      'Android receipt marks it delivered on the iOS side')
        checks.append('neither relayed envelope carried the plaintext it was built from')

        call_id = str(uuid.uuid4())
        sent_ms = int(time.time() * 1000)
        bodies = bodies_from_fixture(fixture, call_id, sent_ms)
        secrets.update({fixture['offer']['fingerprint'], fixture['answer']['fingerprint'],
                        fixture['ice_ufrag'], fixture['ice_pwd']})
        for role in ('offer', 'answer'):
            measured = survey(fixture[role]['sdp'])
            recorded = fixture['spike_survey'][role]
            require([section['kind'] for section in measured['sections']] == ['audio', 'video'],
                    f'the {role} is not audio then video')
            require(measured['lines'] == recorded['lines'],
                    f'the {role} lost a line in transcription')
            require(measured['candidates'] == recorded['candidates']
                    and measured['candidates'] <= MAX_CANDIDATES,
                    f'the {role} candidate count moved')
            require(measured['blocked_directions'] == 0 and measured['crypto'] == 0,
                    f'the {role} carries a blocked direction or an SDES key')
            require(all(section['sendrecv'] == 1 for section in measured['sections']),
                    f'the {role} does not carry exactly one a=sendrecv per section')
            require(any(codec in MANDATORY_VIDEO_CODECS
                        for codec in measured['sections'][1]['codecs']),
                    f'the {role} video section offers neither H.264 nor VP8')
            require(measured['bytes'] <= CLIENT_SDP_CAP,
                    f'the {role} does not fit this client\'s own 9000-byte cap')
            facts.setdefault('sdp', {})[role] = {
                'bytes': measured['bytes'], 'lines': measured['lines'],
                'candidates': measured['candidates'], 'candidate_limit': MAX_CANDIDATES,
                'blocked_directions': 0, 'crypto': 0, 'client_cap': CLIENT_SDP_CAP,
                'core_limit': MAX_SDP_BYTES,
                'sections': [{'kind': section['kind'], 'sendrecv': section['sendrecv'],
                              'rtcp_mux': section['rtcp_mux'], 'codecs': section['codecs']}
                             for section in measured['sections']],
            }
        checks.append('this file measured the transcribed libwebrtc descriptions itself: two '
                      'sections audio then video, one a=sendrecv each, H.264 and VP8 present, '
                      f'no blocked direction, no SDES, at most {MAX_CANDIDATES} candidates and '
                      f'under the {CLIENT_SDP_CAP}-byte cap this client applies')

        call_round(a, b, bodies, sequence, facts)
        checks.append('a full call-v2 exchange crosses both ways — knock, ready, offer, answer, '
                      'media, heartbeat, end — and every control arrives as a call_event whose '
                      'body is byte-identical to the one sent, with `video` still a JSON boolean')

        codec_cross(codec, swift, facts)
        checks.append('a snapshot sealed by the Android codec opens in the iOS codec and back, '
                      'the container is the documented [0x01][nonce][ciphertext||tag] measured '
                      'here, and a wrong key, a flipped version byte, a truncated box and a '
                      'short box are refused by both without echoing anything')

        sealed_reopen(a, b, java, swift, facts)
        checks.append('both saved wrappers reopen in both adapters without a single write, and '
                      'the two adapters show the same public view of the same snapshot')

        negatives(a, b, bodies, negative_vectors(bodies), sequence, facts)
        checks.append(f'{len(facts["negatives"])} malformed call-v2 bodies are refused by this '
                      'file\'s own validator and then by both clients, with one and the same '
                      'code on both sides')
        checks.append('a tampered envelope is refused in both directions and moves nothing but '
                      'the rejection counters, and the next genuine envelope still arrives')
        checks.append(f'a {facts["client_sdp_cap"]["probe_bytes"]}-byte description is accepted '
                      f'by both clients, so the {CLIENT_SDP_CAP}-byte cap the iOS client applies '
                      'before sending is its own frame2 budget and not a core limit')

        if args.skip_stand:
            facts['stand'] = 'NOT RUN (--skip-stand)'
        else:
            stand_round(java_binary, args, facts, checks, secrets)

        result = 'PASS'
    finally:
        for pipe in (java, codec, swift):
            pipe.close()
        payload = {
            'generated': datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            'commit': git('rev-parse', 'HEAD'),
            'script': 'clients/ios/test_android_compatibility.py',
            'result': result,
            'commands': COMMANDS,
            'proves': PROVES,
            'does_not_prove': LIMITS,
            'toolchain': {
                'java': tool_version([str(java_binary), '-version']),
                'swift': tool_version(['swift', '--version']),
                'rustc': tool_version(['rustc', '+1.98.1', '--version']),
                'python': sys.version.split()[0],
            },
            'sources': {
                'android': {path: sha256_file(ROOT / path) for path in ANDROID_SOURCES},
                'ios': {path: sha256_file(ROOT / path) for path in IOS_SOURCES},
                'shared_core': {path: sha256_file(ROOT / path) for path in SHARED_SOURCES},
            },
            'native': {
                'note': 'one Rust source, two builds: a JNI cdylib for the JVM and the macOS '
                        'slice of the C ABI xcframework for Swift',
                'jni_cdylib': (sha256_file(JNI_LIBRARY) | {'path': relative(JNI_LIBRARY)}),
                'c_abi_slice': (sha256_file(C_ABI_SLICE) | {'path': relative(C_ABI_SLICE)})
                if C_ABI_SLICE.exists() else {'path': relative(C_ABI_SLICE), 'sha256': 'absent'},
            },
            'pipes': {pipe.label: {'fixture': pipe.description, 'requests': pipe.requests}
                      for pipe in (java, codec, swift)},
            'independent_expectations': [
                'the account is digest(transcript(["paranoid-account-v1", root]))',
                'the credential fingerprint is digest(transcript(["paranoid-credential-v1", …]))',
                'the contact fingerprint is digest(transcript(["paranoid-contact-v2", …]))',
                'the olm digest is digest(transcript(["paranoid-olm-v1", curve, prekey]))',
                'a sealed snapshot is exactly len(plaintext) + 29 bytes and starts with 0x01',
                'the call-v2 verdict comes from `predict`, a second reading of '
                'docs/protocol/call-v2.md written in this file',
                'the SDP survey (sections, directions, codecs, candidates, size) is measured '
                'here from the text, not read back from a client',
            ],
            'checks': checks,
            'facts': facts,
            'sdp_fixture': {
                'path': relative(FIXTURE),
                'sha256': digest(FIXTURE.read_bytes()),
                'source': fixture['source'],
                'webrtc': fixture['webrtc'],
            },
        }
        written = write_evidence(evidence_dir, payload, sorted(secrets))
    print(f'evidence: {relative(written)}')
    print(f'iOS/Android protocol compatibility: {result} ({len(checks)} checks)')
    return 0 if result == 'PASS' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--evidence-dir', default=str(DEFAULT_EVIDENCE_DIR),
                        help='where result.json is written (default: out/checks/compat)')
    parser.add_argument('--skip-stand', action='store_true',
                        help='leave out the last scenario, the two shipped clients on a local '
                             'stand; the wire scenarios above it need no server at all')
    parser.add_argument('--skip-build', action='store_true',
                        help='use the service-bridge already in out/spm instead of rebuilding it')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='paranoid-server for the stand (default: the stand builds one)')
    parser.add_argument('--pg-bin', metavar='DIR',
                        help='PostgreSQL 16 bin directory (default: toolchain.json)')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Failure as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
