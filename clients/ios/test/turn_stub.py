#!/usr/bin/env python3
"""A pinned HTTPS TURN issuer that verifies the client's Ed25519 signature itself.

This is the server half of ``clients/ios/test_voice_relay_lane.py`` and the
port of the fixture inside
``clients/android/test/VoiceRelayLaneSmoke.java:40-102``. It is deliberately
**not** a mock of the client's expectations: it re-derives the whole
``paranoid-session-request-v1`` transcript from the public session context and
verifies the signature with the device's public key before it answers anything
at all (``key-protocol/src/session_v2.rs:45-59``). A client that signed a
different method, a different path, a different body digest or a different
session would be refused here rather than quietly served.

What it enforces on every ``GET /v2/voice/turn``
(``docs/protocol/voice-turn-v1.md``, "Request and authority"):

* exactly ``GET``, exactly ``/v2/voice/turn``, no query, zero body bytes;
* exactly one ``Authorization: ParanoidSessionV2 <session>.<nonce>.<sig>``;
* the session identifier is the one this device holds;
* the nonce is a canonical UUIDv4 and has never been used before;
* the Ed25519 signature verifies over the full transcript;
* ``Accept: application/json`` and ``Cache-Control: no-store`` are present.

``Connection: close`` is not checked as a header. Foundation reserves that
name and drops it from a ``URLRequest``, so the iOS lane expresses it as one
``URLSession`` per call which is invalidated when the call returns; the
``connection`` number in the record is what states that property instead, and
no two credential requests may share one.

What it answers is a **script**: one entry per request, in order, so the
harness decides which story each request belongs to and a client that made one
request too many or too few is visible immediately. Every answer carries
``Cache-Control: no-store`` and closes its connection.

It also serves the two unauthenticated routes the run needs: ``GET /health``
(the self-service v2 capability answer) and ``GET /v2/marker?scenario=N``,
which is how the record says where one story ended and the next began.

Everything it saw is appended to ``--record`` as JSON lines. No line carries a
credential, a nonce, a session identifier, an account or an address.

Usage (the virtualenv of ``clients/ios/requirements-test.txt``; this file is
the only thing in the repository that needs ``cryptography``):

  clients/ios/out/venv-turn/bin/python clients/ios/test/turn_stub.py \\
      --cert <crt> --key <key> --script <json> --identity <json> \\
      --record <jsonl> --ready <json>

``--ready`` is written once the socket is bound and carries ``{"port": N}``.
The process serves until it is terminated. It binds loopback only and never
contacts anything.
"""
import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import sys
import threading
import time
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

# The protocol constants, written out rather than imported from the client, so
# that a client which moved one of them fails this check instead of redefining
# it (`docs/protocol/voice-turn-v1.md`).
TURN_PATH = '/v2/voice/turn'
HEALTH_PATH = '/health'
MARKER_PREFIX = '/v2/marker'
CREDENTIAL_PREFIX = 'ParanoidSessionV2 '
TRANSCRIPT_LABEL = 'paranoid-session-request-v1'
RELAY_PORT = 34781
TTL = 1200
VERSION = 1
# The issuer's coturn REST secret is 64 lowercase hex ASCII characters and the
# HMAC key is those characters, not their decoded bytes (`voice-turn-v1.md`,
# "Success and validation"). SHA-1 appears here only because it is the coturn
# REST interoperability mechanism; it is never identity, signature or media
# cryptography.
SECRET = secrets.token_hex(32)


# ------------------------------------------------------------------ transcript


def transcript(fields):
    """`paranoid_key_protocol::transcript` (`key-protocol/src/lib.rs:14-21`)."""
    out = bytearray()
    for field in fields:
        value = field.encode('utf-8')
        out += len(value).to_bytes(4, 'big')
        out += value
    return bytes(out)


def unpad(value):
    """Base64 as vodozemac writes it: standard alphabet, padding optional."""
    return base64.b64decode(value + '=' * (-len(value) % 4))


def canonical_uuid4(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return False
    return parsed.version == 4 and str(parsed) == value


# ------------------------------------------------------------------- the stub


class Issuer:
    """The script, the identity it verifies against and everything it saw."""

    def __init__(self, script, identity_path, record_path, host):
        self.lock = threading.Lock()
        self.responses = list(script)
        self.identity_path = Path(identity_path)
        self.record_path = Path(record_path)
        self.host = host
        self.identity = None
        self.nonces = set()
        self.requests = 0
        self.sequence = 0
        self.connections = 0

    # -- identity -----------------------------------------------------------

    def load_identity(self):
        """The public session context and device key the probe wrote.

        It is read lazily because the stub has to be listening before the
        client can create the identity that names its realm.
        """
        if self.identity is not None:
            return self.identity
        document = json.loads(self.identity_path.read_text())
        session = document['session']
        key = Ed25519PublicKey.from_public_bytes(unpad(document['auth']))
        self.identity = (session, key)
        return self.identity

    # -- verification -------------------------------------------------------

    def verify(self, method, path, authorization, body_bytes):
        """Every rule of "Request and authority"; the problems it found."""
        problems = []
        session, key = self.load_identity()
        if method != 'GET':
            problems.append(f'method {method}')
        if path != TURN_PATH:
            problems.append('path is not the fixed route')
        if body_bytes != 0:
            problems.append(f'{body_bytes} body bytes')
        if authorization is None or not authorization.startswith(CREDENTIAL_PREFIX):
            problems.append('missing native session authorization')
            return problems, False, False
        parts = authorization[len(CREDENTIAL_PREFIX):].split('.')
        if len(parts) != 3:
            problems.append('malformed credential')
            return problems, False, False
        identifier, nonce, signature = parts
        if identifier != session['id']:
            problems.append('wrong session binding')
        if not canonical_uuid4(nonce):
            problems.append('nonce is not a canonical UUIDv4')
        fresh = nonce not in self.nonces
        if not fresh:
            problems.append('nonce reused')
        self.nonces.add(nonce)
        signed = transcript([
            TRANSCRIPT_LABEL, session['id'], session['epoch'], str(session['expires']),
            session['realm'], session['pin'], session['account'], session['device'],
            session['credential'], nonce, method, path,
            hashlib.sha256(b'').hexdigest(),
        ])
        try:
            key.verify(unpad(signature), signed)
            verified = True
        except (InvalidSignature, ValueError):
            verified = False
            problems.append('the signature does not bind this HTTP operation')
        return problems, verified, fresh

    # -- answers ------------------------------------------------------------

    def new_connection(self):
        """One number per accepted connection, in the order they arrive."""
        with self.lock:
            self.connections += 1
            return self.connections

    def next_response(self):
        with self.lock:
            self.requests += 1
            if not self.responses:
                return {'status': 599, 'body': 'error', 'code': 'script_exhausted'}
            return self.responses.pop(0)

    def config(self):
        """One valid issuer document for this realm, minted now."""
        expires = int(time.time()) + TTL
        username = f'{expires}:{secrets.token_hex(16)}'
        credential = base64.b64encode(
            hmac.new(SECRET.encode('ascii'), username.encode('utf-8'), hashlib.sha1).digest()
        ).decode('ascii')
        return {
            'v': VERSION,
            'urls': [f'turn:{self.host}:{RELAY_PORT}?transport=udp',
                     f'turn:{self.host}:{RELAY_PORT}?transport=tcp'],
            'username': username,
            'credential': credential,
            'expires': expires,
            'ttl': TTL,
        }

    def body_for(self, response):
        kind = response.get('body', 'config' if response.get('status') == 200 else 'error')
        if kind == 'config':
            return json.dumps(self.config()).encode('utf-8')
        if kind == 'malformed':
            # A well-formed JSON object that is not this document: the client
            # must refuse it on the schema, never on the parser alone.
            return b'{"v":1}'
        if kind == 'oversized':
            return json.dumps({'v': VERSION, 'pad': 'x' * 4096}).encode('utf-8')
        return json.dumps({'error': response.get('code', 'synthetic_fault')}).encode('utf-8')

    # -- record -------------------------------------------------------------

    def note(self, entry):
        with self.lock:
            self.sequence += 1
            entry['n'] = self.sequence
            with self.record_path.open('a', encoding='utf-8') as record:
                record.write(json.dumps(entry, sort_keys=True) + '\n')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    issuer = None

    def log_message(self, *args):  # noqa: D102  (the stub is silent)
        pass

    def setup(self):
        super().setup()
        # Which connection this request arrived on. A negotiation-only lane
        # leaves no socket behind, so no two credential requests may share one
        # (`VoiceRelayTransport.java:39`, expressed on iOS as a one-shot
        # `URLSession`; `docs/protocol/voice-turn-v1.md`, "Consent, transport
        # and compatibility").
        self.connection_number = Handler.issuer.new_connection()

    # -- the three routes ---------------------------------------------------

    def do_GET(self):  # noqa: N802  (BaseHTTPRequestHandler's name)
        path = self.path
        if path == HEALTH_PATH:
            self.issuer.note({'route': 'health', 'connection': self.connection_number})
            return self.reply(200, json.dumps({
                'status': 'ok',
                'protocol': 'paranoid-self-service-v2',
                'realtime': 'signed-long-poll-v1',
            }).encode('utf-8'))
        if path.startswith(MARKER_PREFIX):
            self.issuer.note({'route': 'marker', 'path': path,
                              'connection': self.connection_number})
            return self.reply(200, b'{}')
        if path.split('?')[0] != TURN_PATH:
            return self.reply(404, json.dumps({'error': 'not_found'}).encode('utf-8'))
        return self.issue(path)

    def do_POST(self):  # noqa: N802
        self.issuer.note({'route': 'unexpected_post', 'connection': self.connection_number})
        self.reply(405, json.dumps({'error': 'method_not_allowed'}).encode('utf-8'))

    def issue(self, path):
        """One credential request: verified first, answered second."""
        length = self.headers.get('Content-Length')
        body_bytes = int(length) if length and length.isdigit() else 0
        if body_bytes:
            self.rfile.read(body_bytes)
        credentials = [value for name, value in self.headers.items()
                       if name.lower() == 'authorization']
        try:
            problems, verified, fresh = self.issuer.verify(
                self.command, path, credentials[0] if credentials else None, body_bytes)
        except (OSError, ValueError, KeyError) as unavailable:
            self.issuer.note({'route': 'turn', 'connection': self.connection_number,
                              'problems': [f'identity unavailable: {unavailable}']})
            return self.reply(500, json.dumps({'error': 'stub_identity'}).encode('utf-8'))

        if len(credentials) != 1:
            problems.append(f'{len(credentials)} Authorization headers')
        # `Connection: close` is not checked as a header: Foundation reserves
        # that name and drops it from a `URLRequest`, so the iOS lane expresses
        # it as one `URLSession` per call, invalidated when the call returns.
        # The `connection` number below is what states that property instead.
        for name, expected in (('Accept', 'application/json'),
                               ('Cache-Control', 'no-store')):
            if (self.headers.get(name) or '').lower() != expected:
                problems.append(f'{name} is {self.headers.get(name)!r}')

        response = self.issuer.next_response()
        status = 500 if problems else int(response.get('status', 200))
        body = (json.dumps({'error': 'stub_refused'}).encode('utf-8') if problems
                else self.issuer.body_for(response))
        self.issuer.note({
            'route': 'turn', 'connection': self.connection_number, 'method': self.command,
            'query': '?' in path, 'body_bytes': body_bytes,
            'authorization_headers': len(credentials),
            'signature_verified': verified, 'nonce_fresh': fresh,
            'status': status, 'response_bytes': len(body),
            'scripted': response.get('body', 'config' if response.get('status') == 200 else 'error'),
            'problems': problems,
        })
        self.reply(status, body)

    # -- one answer ---------------------------------------------------------

    def reply(self, status, body):
        self.close_connection = True
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        # "Responses use `Cache-Control: no-store`" (`voice-turn-v1.md`).
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
            # A cancelled request can close before the answer is written.
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    # A refused pin closes the connection during the handshake; that is the
    # client's answer, not an error of this process.
    def handle_error(self, request, address):
        pass


# ---------------------------------------------------------------------- main


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--script', required=True,
                        help='JSON: {"responses": [{"status":200,"body":"config"}, ...]}')
    parser.add_argument('--identity', required=True,
                        help='where the probe writes {"session":…, "auth":…}')
    parser.add_argument('--record', required=True, help='JSON lines, appended')
    parser.add_argument('--ready', required=True, help='written once the socket is bound')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    script = json.loads(Path(args.script).read_text())['responses']
    issuer = Issuer(script, args.identity, args.record, args.host)
    Handler.issuer = issuer

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=args.cert, keyfile=args.key)

    Server.address_family = socket.AF_INET
    server = Server((args.host, args.port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    port = server.socket.getsockname()[1]

    ready = Path(args.ready)
    temporary = ready.with_suffix('.partial')
    temporary.write_text(json.dumps({'port': port}))
    temporary.replace(ready)

    try:
        server.serve_forever(poll_interval=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
