#!/usr/bin/env python3
"""Offline host adapter + real local pinned TLS; never production TLS/installer evidence.
Fixtures stream in 64 KiB blocks. Disposable TLS keys are not Android signing keys.
"""
from pathlib import Path
from typing import cast
import argparse
import datetime
import hashlib
import http.server
import ipaddress
import json
import os
import ssl
import subprocess
import tempfile
import threading
import traceback
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

ROOT = Path(__file__).resolve().parent
CP = os.pathsep.join(str(ROOT / p) for p in ['out/update-host', 'out/host', 'out/deps/json-20240303.jar'])
BLOCK = 65536
LARGE_SIZE = 65 * 1024 * 1024 + 17


def checked_process(result, marker):
    if result.returncode != 0 or marker not in result.stdout:
        raise AssertionError(f'JVM failed or missing {marker!r}: exit={result.returncode}\n{result.stdout}')
    return result.stdout


def run(*args, marker='PASS'):
    result = subprocess.run(['java', '-Xmx32m', '-Dhttps.proxyHost=127.0.0.23', '-Dhttps.proxyPort=1',
                             '-Djava.library.path=' + str(ROOT.parent / 'core/target/debug'), '-cp', CP, *args],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    return checked_process(result, marker)


class Payload:
    def __init__(self, path=None, size=None):
        self.path = path
        self.size = path.stat().st_size if path else size
        digest = hashlib.sha256()
        for block in self.chunks():
            digest.update(block)
        self.digest = digest.hexdigest()

    def chunks(self, size=None):
        left = self.size if size is None else size
        if self.path:
            with self.path.open('rb') as stream:
                while left:
                    block = stream.read(min(BLOCK, left))
                    if not block:
                        raise AssertionError('fixture truncated on disk')
                    left -= len(block)
                    yield block
        else:
            block = b'\x00' * BLOCK
            while left:
                count = min(BLOCK, left)
                yield block[:count]
                left -= count


def assert_server(errors, paths, expected):
    assert not errors, '\n'.join(errors)
    assert paths == expected, (paths, expected)


def harness_selftest():
    for result in [subprocess.CompletedProcess([], 1, 'REJECT test'),
                   subprocess.CompletedProcess([], 0, 'arbitrary output')]:
        try:
            checked_process(result, 'REJECT test')
        except AssertionError:
            pass
        else:
            raise AssertionError('harness accepted arbitrary JVM failure/output')
    for errors, paths in [(['handler exploded'], []), ([], ['/wrong-route'])]:
        try:
            assert_server(errors, paths, [])
        except AssertionError:
            pass
        else:
            raise AssertionError('harness accepted handler error/wrong route')
    print('Harness self-tests PASS: handler error, wrong route, JVM failure and missing marker fail closed')


class Server(http.server.ThreadingHTTPServer):
    # Define the initial mode BEFORE any constructor probe or request.
    mode = 'ok'

    def __init__(self, payload):
        super().__init__(('127.0.0.23', 0), Handler)
        self.payload = payload
        self.paths, self.errors = [], []
        self.condition = threading.Condition()
        self.active = 0

    def handle_error(self, request, client_address):
        self.errors.append(traceback.format_exc())

    def verify(self, expected):
        with self.condition:
            assert self.condition.wait_for(lambda: self.active == 0, timeout=5), 'handler did not finish'
        assert_server(self.errors, self.paths, expected)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        server = cast(Server, self.server)
        with server.condition:
            server.active += 1
        try:
            self.serve()
        except Exception:
            server.errors.append(traceback.format_exc())
        finally:
            self.close_connection = True
            with server.condition:
                server.active -= 1
                server.condition.notify_all()

    def serve(self):
        server = cast(Server, self.server)
        server.paths.append(self.path)
        assert not self.headers.get('Authorization') and not self.headers.get('Cookie')
        mode, payload = server.mode, server.payload
        metadata = dict(schema=1, package='global.paranoid.messenger', version_code=6,
                        version_name='0.0.6-update', min_sdk=26, abi='arm64-v8a',
                        apk_sha256=payload.digest, apk_size=payload.size)
        status, chunked, unknown = 200, False, False
        if self.path == '/v2/updates/android':
            if mode == 'bad-hash':
                metadata['apk_sha256'] = 'b' * 64
            if mode in ('size-small', 'size-large'):
                metadata['apk_size'] = payload.size + (-1 if mode == 'size-small' else 1)
            if mode == 'disk-space':
                metadata['apk_size'] = 9223372036854775807
            body = json.dumps(metadata).encode()
            if mode == 'absent':
                status, body = 404, b''
            elif mode == 'redirect':
                status, body = 302, b''
            elif mode == 'metadata-big':
                body = b' ' * 8193
            elif mode == 'metadata-invalid':
                body = b'{"schema":1,"schema":1}'
            elif mode == 'metadata-utf8':
                body = b'\xc3('
            if mode in ('metadata-chunked', 'metadata-unknown'):
                # Huge but bounded-fixture-memory stream, not an allocated giant string.
                body_length = 16 * 1024 * 1024
                blocks = (b' ' * BLOCK for _ in range(body_length // BLOCK))
                chunked, unknown = mode == 'metadata-chunked', mode == 'metadata-unknown'
            else:
                body_length, blocks = len(body), iter([body])
        else:
            expected_digest = 'b' * 64 if mode == 'bad-hash' else payload.digest
            assert self.path == '/v2/updates/android/apk/' + expected_digest, 'unexpected route: ' + self.path
            body_length = payload.size
            blocks = payload.chunks(payload.size - 1 if mode == 'truncated' else None)
            if mode == 'overflow':
                import itertools
                blocks = itertools.chain(blocks, [b'x'])
            chunked = mode in ('chunked', 'overflow')
            if mode == 'apk-redirect':
                status, body_length, blocks = 307, 0, iter([])
        self.send_response(status)
        if status in (302, 307):
            self.send_header('Location', 'https://127.0.0.23:1/never')
        if mode == 'encoding':
            self.send_header('Content-Encoding', 'gzip')
        if chunked:
            self.send_header('Transfer-Encoding', 'chunked')
        elif not unknown:
            self.send_header('Content-Length', str(body_length))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            for block in blocks:
                if not block:
                    continue
                if chunked:
                    self.wfile.write(f'{len(block):x}\r\n'.encode())
                    self.wfile.write(block)
                    self.wfile.write(b'\r\n')
                else:
                    self.wfile.write(block)
            if chunked:
                self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
            # Expected only when the client deliberately refuses a response early.
            if mode not in ('redirect', 'apk-redirect', 'metadata-big', 'metadata-chunked',
                            'metadata-unknown', 'encoding', 'size-small', 'size-large', 'overflow'):
                raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', help='one local TLS regression (for RED/GREEN)')
    parser.add_argument('--synthetic', action='store_true', help='CI transport bytes only; no prebuilt APK required')
    args = parser.parse_args()
    sources = [ROOT / 'src/org/paranoid/text' / f'{name}.java' for name in
               ['UpdateManifest', 'UpdatePolicy', 'UpdateClient', 'PinnedTls', 'KeyClient',
                'CoreBridge', 'KeyTransport', 'SyncCycle', 'SelfServiceClient', 'IdentityPorts']]
    sources += sorted((ROOT / 'test').glob('Update*Smoke.java'))
    (ROOT / 'out/update-host').mkdir(exist_ok=True, parents=True)
    subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-cp', str(ROOT / 'out/deps/json-20240303.jar'),
                    '-d', str(ROOT / 'out/update-host'), *map(str, sources)], check=True)
    harness_selftest()
    if not args.case:
        for name in ['UpdateCopySmoke', 'UpdateLargeSmoke', 'UpdateSmoke', 'UpdatePolicySmoke',
                     'UpdateTrustSmoke', 'UpdateTransportSmoke']:
            print(run('org.paranoid.text.' + name).strip())
    # Existing artifact is transport input only; CI explicitly uses synthetic bytes.
    payload = (Payload(size=65537) if args.synthetic else
               Payload(Path(os.environ.get('PARANOID_UPDATE_FIXTURE', str(ROOT / 'out/paranoid-text.apk')))))
    if args.synthetic:
        print('Synthetic CI transport fixture: NOT a signed APK or installation test')
    large = Payload(size=LARGE_SIZE)
    errors = {'redirect': 'metadata unavailable', 'apk-redirect': 'APK unavailable',
              'metadata-big': 'response size', 'metadata-chunked': 'size exceeded declared 8192',
              'metadata-unknown': 'size exceeded declared 8192', 'metadata-invalid': 'duplicate/extra field',
              'metadata-utf8': 'Input length = 1', 'bad-hash': 'APK download checksum/size mismatch',
              'size-small': 'response size', 'size-large': 'APK length header',
              'disk-space': 'insufficient update cache space', 'truncated': 'APK download checksum/size mismatch',
              'overflow': 'size exceeded declared ' + str(payload.size), 'encoding': 'encoded response forbidden',
              'reject-apk': 'APK rejected', 'wrong-pin': 'TLS:server key mismatch',
              'cookie': 'ambient HTTP credentials forbidden'}
    metadata_only = {'absent', 'redirect', 'metadata-big', 'metadata-chunked', 'metadata-unknown',
                     'metadata-invalid', 'metadata-utf8', 'disk-space', 'encoding'}
    modes = ['ok', 'chunked', 'absent', *errors, 'large']
    if args.case and args.case not in modes:
        parser.error('unknown TLS case')
    with tempfile.TemporaryDirectory(prefix='paranoid-update-tls-') as tmp:
        tmp = Path(tmp)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        keyfile = tmp / 'tls.key'
        keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                             serialization.NoEncryption()))
        keyfile.chmod(0o600)
        pin = hashlib.sha256(key.public_key().public_bytes(serialization.Encoding.DER,
                                                          serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()
        for kind in (['valid'] if args.case else ['valid', 'expired', 'san', 'ca']):
            now = datetime.datetime.now(datetime.timezone.utc)
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Disposable update fixture')])
            cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                    .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=2))
                    .not_valid_after(now + datetime.timedelta(days=1) if kind != 'expired' else now - datetime.timedelta(days=1))
                    .add_extension(x509.BasicConstraints(ca=kind == 'ca', path_length=None), True)
                    .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(
                        '127.0.0.24' if kind == 'san' else '127.0.0.23'))]), False)
                    .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), True)
                    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False))
            certfile = tmp / 'tls.pem'
            certfile.write_bytes(cert.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(certfile, keyfile)
            server = Server(payload)
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            realm = f'https://127.0.0.23:{server.server_port}'
            try:
                if kind == 'valid' and not args.case:
                    for invalid in [realm.replace('https:', 'http:'), realm + '/', realm + '?file=x', realm + '#x',
                                    realm.replace('https://', 'https://user:secret@')]:
                        print(run('org.paranoid.text.UpdateNetworkSmoke', invalid, pin, 'origin', marker='REJECT origin').strip())
                        server.verify([])
                    print('Malformed constructors PASS: checked rejection, ZERO requests; explicit unusable proxy ignored')
                for mode in ([args.case] if args.case else modes if kind == 'valid' else ['ok']):
                    server.mode = mode
                    server.payload = large if mode == 'large' else payload
                    server.paths.clear()
                    expected = errors.get(mode, '') if kind == 'valid' else {
                        'expired': 'TLS:CertificateExpiredException', 'san': 'TLS:invalid server key or address',
                        'ca': 'TLS:unsupported leaf certificate'}[kind]
                    routes = [] if kind != 'valid' or mode in ('wrong-pin', 'cookie') else ['/v2/updates/android']
                    if routes and mode not in metadata_only:
                        routes += ['/v2/updates/android/apk/' + ('b' * 64 if mode == 'bad-hash' else server.payload.digest)]
                    try:
                        out = run('org.paranoid.text.UpdateNetworkSmoke', realm, '0' * 64 if mode == 'wrong-pin' else pin,
                                  mode, expected, marker='REJECT ' + mode if expected else 'PASS')
                    finally:
                        server.verify(routes)  # Handler exceptions/wrong paths always fail, even on JVM failure.
                    print(f'TLS {kind}/{mode}: {out.strip()}')
                    if mode == 'large':
                        assert f'download PASS {LARGE_SIZE}' in out
                        print(f'Real local TLS >64MiB: {LARGE_SIZE} synthetic bytes; Java -Xmx32m, fixture block {BLOCK}; NOT APK installation evidence')
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
    print('RFC0013 host/local TLS PASS (no public-CA handshake, Android PackageManager, installer or device evidence)')


if __name__ == '__main__':
    main()
