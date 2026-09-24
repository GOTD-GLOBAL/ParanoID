#!/usr/bin/env python3
"""Independent public LP/Ed25519 fixtures; NOT valid registry/admission receipts."""
import base64
import hashlib
import json
import sys
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/protocol/identity-login-v3-vectors.json'
FIELDS = ('id nonce epoch expires realm pin purpose operation genesis program '
          'identity owner name account device credential_fingerprint '
          'expected_generation').split()


def lp(fields):
    return b''.join(len(s.encode()).to_bytes(4, 'big') + s.encode() for s in fields)


def b64(data):
    return base64.b64encode(data).decode().rstrip('=')


def generate():
    cases = []
    for purpose in ('inspect', 'status', 'enroll', 'replace'):
        c = dict(zip(FIELDS, [
            '11111111-1111-4111-8111-111111111111', base64.b64encode(bytes(32)).decode(),
            '22222222-2222-4222-8222-222222222222', '1800000060',
            'https://auth-fixture.invalid:38444', 'ab' * 32, purpose,
            '33333333-3333-4333-8333-333333333333', '11111111111111111111111111111111',
            'C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas',
            '11111111111111111111111111111111', '11111111111111111111111111111111',
            'fixture', 'cd' * 32, '44444444-4444-4444-8444-444444444444',
            'ef' * 32, '1' if purpose == 'replace' else '0']))
        path = '/v3/identity/' + (purpose if purpose in ('inspect', 'status') else 'commit')
        for role in (('device',) if purpose == 'status' else ('owner', 'device')):
            seed = bytes(range(32)) if role == 'owner' else bytes(range(32, 64))
            key = Ed25519PrivateKey.from_private_bytes(seed)
            raw = lp(['paranoid-identity-v3-' + role] + [c[x] for x in FIELDS] + ['POST', path])
            signature = key.sign(raw)
            key.public_key().verify(signature, raw)
            # Every byte mutation must invalidate the actual signature.
            for i in range(len(raw)):
                changed = bytearray(raw)
                changed[i] ^= 1
                try:
                    key.public_key().verify(signature, bytes(changed))
                except Exception:
                    continue
                raise AssertionError('mutated transcript accepted')
            cases.append(dict(purpose=purpose, role=role, challenge=c, path=path,
                              public_fixture_seed_hex=seed.hex(),
                              public_key=b64(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
                              transcript_hex=raw.hex(), sha256=hashlib.sha256(raw).hexdigest(),
                              signature=b64(signature)))
    return dict(scope='LP and signature primitive only: fake registry/PDA/credential values; not semantic acceptance or a live identity',
                fields=FIELDS, cases=cases)


if __name__ == '__main__':
    result = json.dumps(generate(), indent=2) + '\n'
    if '--check' in sys.argv:
        assert OUT.read_text() == result, 'public vectors differ'
        print('PASS: 7 role/purpose vectors and all single-byte transcript mutations')
    else:
        OUT.write_text(result)
        print(OUT)
