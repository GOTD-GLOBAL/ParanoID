#!/usr/bin/env python3
"""Negative TLS checks for the iOS client: OpenSSL fixtures, real loopback handshakes.

The counterpart of ``scripts/check-pinned-tls.py`` (which drives the Java
``TlsSmoke``) for ``ParanoidKit``. Nothing is mocked: OpenSSL 3 issues eight
throw-away certificates on two keys, this script serves each identity from its
own ``http.server`` on ``127.0.0.1`` with its own request counter, and the
``tls-smoke`` executable of ``clients/ios/ParanoidKit`` dials every one of them
through the shipped ``PinnedSessionDelegate`` / ``PinnedTrustEvaluator``.

The fixtures, and the rule each of them is there to break
(``clients/android/src/org/paranoid/text/PinnedTls.java:51-70``):

===============  =========================================================
``valid``        IP:127.0.0.1, ``CA:FALSE``, ``digitalSignature``,
                 ``serverAuth`` — the only certificate that must be accepted
``wrong-pin``    the same server, dialled with ``00..00`` (check 2)
``wrong-ip``     IP:127.0.0.2 on the pinned key (check 8)
``expired``      the pinned key, validity in the past (check 3)
``ca-chain``     CA plus leaf, two certificates on the pinned key (check 1)
``dns-san-only`` ``DNS:paranoid.invalid`` on the pinned key, dialled by IP
                 (check 8)
``no-eku``       the pinned key without ``extendedKeyUsage`` (check 6)
``rsa-1024``     a 1024-bit RSA key, pinned to its own SPKI (check 7)
===============  =========================================================

A ninth server, offered only when the local OpenSSL still speaks TLS 1.1 at
``@SECLEVEL=0``, presents the valid certificate over TLS 1.1 (check 9); when it
does not, the line says ``SKIPPED`` instead of quietly passing.

Every rejection is also checked from the server's side: the fixture counts HTTP
requests, and a refused peer must have counted **zero**, which is what "rejected
before HTTP" means — the synthetic ``Authorization`` header ``tls-smoke`` sends
(``TlsSmoke.java:29``) never reached it.

The certificates and their keys are generated into a private temporary
directory (mode 0700) and deleted when the run ends; nothing is written into
the repository except the log and the evidence JSON under ``clients/ios/out/``.
No hosted server is contacted: every socket is loopback.

Usage:
  python3 clients/ios/check-pinned-tls.py
  python3 clients/ios/check-pinned-tls.py --keep          # leave the fixtures on disk
  python3 clients/ios/check-pinned-tls.py --skip-build    # reuse the built tls-smoke
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import warnings

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'clients/ios/ParanoidKit'
XCFRAMEWORK = PACKAGE / 'Binaries/ParanoidCore.xcframework'
OUT = ROOT / 'clients/ios/out'
DEFAULT_SCRATCH = OUT / 'spm'
LOG = OUT / 'logs/check-pinned-tls.log'
EVIDENCE = OUT / 'evidence/pinned-tls.json'
SUBJECT = '/CN=ParanoID TLS fixture'
# The address every fixture server binds and every certificate but `wrong-ip`
# and `dns-san-only` names.
HOST = '127.0.0.1'
HANDSHAKE_TIMEOUT = 10
ZERO_PIN = '00' * 32


class CheckError(Exception):
    """An environment problem: the run cannot decide anything (exit 2)."""


# ---------------------------------------------------------------- fixtures


def openssl(binary, arguments, cwd):
    """One OpenSSL command, with its output kept out of the console."""
    result = subprocess.run([binary] + arguments, cwd=str(cwd),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        detail = result.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise CheckError(f'openssl {" ".join(arguments[:2])} failed: '
                         f'{detail[-1] if detail else result.returncode}')
    return result.stdout


def leaf_extensions(san):
    """The extensions of a server leaf: `PinnedTls.java` checks 4, 6 and 8."""
    return ['-addext', f'subjectAltName={san}',
            '-addext', 'basicConstraints=critical,CA:FALSE',
            '-addext', 'keyUsage=critical,digitalSignature',
            '-addext', 'extendedKeyUsage=serverAuth']


def generate_fixtures(binary, directory):
    """Every certificate the run needs, next to one shared EC key.

    ``valid``, ``wrong-ip``, ``expired``, ``ca-chain``, ``dns-san-only`` and
    ``no-eku`` all carry the same ``subjectPublicKeyInfo``, so the pin of
    ``valid`` matches every one of them and each refusal is the check the
    fixture is named after rather than check 2. ``rsa-1024`` has a key of its
    own and is pinned to it, for the same reason.
    """
    key = directory / 'key.pem'
    openssl(binary, ['req', '-x509', '-sha256', '-days', '1', '-subj', SUBJECT,
                     '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                     '-nodes', '-keyout', str(key)]
            + leaf_extensions(f'IP:{HOST}') + ['-out', 'valid.crt'], directory)
    for name, san in [('wrong-ip', 'IP:127.0.0.2'),
                      ('dns-san-only', 'DNS:paranoid.invalid')]:
        openssl(binary, ['req', '-x509', '-sha256', '-days', '1', '-subj', SUBJECT,
                         '-key', str(key)]
                + leaf_extensions(san) + ['-out', f'{name}.crt'], directory)
    # No extendedKeyUsage at all, so check 6 has nothing to find.
    openssl(binary, ['req', '-x509', '-sha256', '-days', '1', '-subj', SUBJECT,
                     '-key', str(key),
                     '-addext', f'subjectAltName=IP:{HOST}',
                     '-addext', 'basicConstraints=critical,CA:FALSE',
                     '-addext', 'keyUsage=critical,digitalSignature',
                     '-out', 'no-eku.crt'], directory)
    # Validity in the past. OpenSSL 3.6 refuses the `-days -1` of
    # `scripts/check-pinned-tls.py`("end date before start date"), so the two
    # dates are given explicitly; `openssl x509` keeps the extensions.
    openssl(binary, ['x509', '-in', 'valid.crt', '-signkey', str(key),
                     '-not_before', '20240101000000Z', '-not_after', '20240102000000Z',
                     '-out', 'expired.crt'], directory)
    # A two-certificate chain on the same key: check 1 sees two certificates
    # before any of the later checks can look at the leaf.
    openssl(binary, ['req', '-x509', '-sha256', '-days', '1',
                     '-subj', '/CN=ParanoID TLS fixture CA', '-key', str(key),
                     '-addext', 'basicConstraints=critical,CA:TRUE',
                     '-addext', 'keyUsage=critical,digitalSignature,keyCertSign',
                     '-out', 'ca.crt'], directory)
    openssl(binary, ['req', '-new', '-sha256', '-subj', '/CN=ParanoID TLS fixture leaf',
                     '-key', str(key), '-out', 'leaf.csr'], directory)
    (directory / 'leaf.ext').write_text(
        f'subjectAltName=IP:{HOST}\nbasicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n',
        encoding='utf-8')
    openssl(binary, ['x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.crt',
                     '-CAkey', str(key), '-set_serial', '2', '-days', '1',
                     '-sha256', '-extfile', 'leaf.ext', '-out', 'ca-leaf.crt'], directory)
    (directory / 'ca-chain.crt').write_bytes((directory / 'ca-leaf.crt').read_bytes()
                                             + (directory / 'ca.crt').read_bytes())
    # An RSA key below the 2048-bit floor of check 7, pinned to its own SPKI.
    openssl(binary, ['req', '-x509', '-sha256', '-days', '1', '-subj', SUBJECT,
                     '-newkey', 'rsa:1024', '-nodes', '-keyout', 'rsa-1024.key']
            + leaf_extensions(f'IP:{HOST}') + ['-out', 'rsa-1024.crt'], directory)
    return key


def spki_pin(binary, certificate, directory):
    """SHA-256 over the DER of `subjectPublicKeyInfo`, the pin of every realm.

    The same value Java takes as ``getPublicKey().getEncoded()``
    (``TlsSmoke.java:14``) and ``scripts/create-test-tls.py`` writes as
    ``tls_spki_sha256``.
    """
    pem = openssl(binary, ['x509', '-in', certificate.name, '-noout', '-pubkey'],
                  directory).decode('ascii')
    body = ''.join(line for line in pem.splitlines() if not line.startswith('-----'))
    return hashlib.sha256(base64.b64decode(body)).hexdigest()


# ----------------------------------------------------------------- servers


class CountingHandler(http.server.BaseHTTPRequestHandler):
    """Answers ``200 ok`` and counts what reached it."""

    # HTTP/1.0 so that no connection is kept alive after the answer and the
    # server can be shut down without waiting for an idle socket.
    protocol_version = 'HTTP/1.0'
    timeout = HANDSHAKE_TIMEOUT

    def do_GET(self):  # noqa: N802 - the name BaseHTTPRequestHandler dispatches to
        self.server.count_request()
        body = b'ok'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments):
        """No console output: a refused handshake is the normal case here."""


class FixtureServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """One TLS identity on loopback, with the request counter of `TlsSmoke.java:22`."""

    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, name, tls):
        self.name = name
        self.tls = tls
        self._lock = threading.Lock()
        self._requests = 0
        super().__init__((HOST, 0), CountingHandler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True,
                                       name=f'fixture-{name}')
        self.thread.start()

    @property
    def url(self):
        return f'https://{HOST}:{self.server_address[1]}/'

    def count_request(self):
        with self._lock:
            self._requests += 1

    @property
    def requests(self):
        with self._lock:
            return self._requests

    def get_request(self):
        """Accept, then hand-shake with a timeout, so no client can wedge the run."""
        connection, address = super().get_request()
        connection.settimeout(HANDSHAKE_TIMEOUT)
        try:
            return self.tls.wrap_socket(connection, server_side=True), address
        except OSError:
            connection.close()
            raise  # socketserver treats an OSError from get_request as "no request"

    def handle_error(self, request, client_address):
        """A refused handshake is the expected outcome of seven fixtures."""

    def stop(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


def server_context(certificate, key, seclevel_zero=False, legacy=False):
    """A server context for one fixture.

    ``seclevel_zero`` is what lets OpenSSL serve the 1024-bit RSA key at all;
    ``legacy`` caps the server at TLS 1.1 for the check-9 fixture.
    """
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    if seclevel_zero or legacy:
        context.set_ciphers('DEFAULT@SECLEVEL=0')
    if legacy:
        allow_legacy_versions(context)
    context.load_cert_chain(str(certificate), str(key))
    return context


def allow_legacy_versions(context):
    """TLS 1.0/1.1 on a context, without the deprecation notice on the console.

    Python deprecates the two enumerators themselves, and the whole point of
    this fixture is to offer a version the client must refuse, so the notice is
    suppressed here and nowhere else.
    """
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', DeprecationWarning)
        context.minimum_version = ssl.TLSVersion.TLSv1
        context.maximum_version = ssl.TLSVersion.TLSv1_1


def legacy_server(directory, key):
    """A TLS 1.1 server, or ``(None, reason)`` when this OpenSSL cannot be one.

    The probe is a plain handshake by Python itself — no HTTP request, so the
    fixture's counter stays at zero — and it is what keeps a missing TLS 1.1 an
    explicit ``SKIPPED`` rather than a rejection that proves nothing.
    """
    try:
        context = server_context(directory / 'valid.crt', key, legacy=True)
    except (ssl.SSLError, ValueError) as unsupported:
        return None, f'this OpenSSL refuses a TLS 1.1 server context ({unsupported})'
    server = FixtureServer('legacy-tls', context)
    client = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    client.check_hostname = False
    client.verify_mode = ssl.CERT_NONE
    try:
        client.set_ciphers('DEFAULT@SECLEVEL=0')
        allow_legacy_versions(client)
        with socket.create_connection((HOST, server.server_address[1]), timeout=5) as raw:
            with client.wrap_socket(raw) as negotiated:
                version = negotiated.version()
    except (ssl.SSLError, OSError, ValueError) as unsupported:
        server.stop()
        return None, f'this OpenSSL cannot complete a TLS 1.1 handshake ({unsupported})'
    if version != 'TLSv1.1':
        server.stop()
        return None, f'the probe negotiated {version}, not TLS 1.1'
    return server, None


# -------------------------------------------------------------- tls-smoke


def build_smoke(scratch, skip_build):
    """`swift build --product tls-smoke`, and the path of the binary."""
    swift = shutil.which('swift')
    if swift is None:
        raise CheckError('swift is not on PATH (Xcode 26.6 / Swift 6.3.3 expected)')
    if not XCFRAMEWORK.is_dir():
        raise CheckError(f'{XCFRAMEWORK} is missing; run bash clients/ios/build-core.sh first')
    LOG.parent.mkdir(parents=True, exist_ok=True)
    common = [swift, 'build', '--package-path', str(PACKAGE),
              '--scratch-path', str(scratch), '--product', 'tls-smoke']
    with LOG.open('w', encoding='utf-8') as log:
        if not skip_build:
            log.write('$ ' + ' '.join(common) + '\n')
            log.flush()
            if subprocess.run(common, stdout=log, stderr=subprocess.STDOUT).returncode != 0:
                raise CheckError(f'swift build failed; see {LOG}')
        located = subprocess.run(common[:-2] + ['--show-bin-path'],
                                 stdout=subprocess.PIPE, stderr=log, text=True)
    if located.returncode != 0:
        raise CheckError(f'swift build --show-bin-path failed; see {LOG}')
    binary = Path(located.stdout.strip()) / 'tls-smoke'
    if not binary.is_file():
        raise CheckError(f'{binary} was not built; see {LOG}')
    return binary


def run_smoke(binary, cases):
    """One ``tls-smoke`` run over every case; returns its report."""
    plan = json.dumps({'cases': [{'name': case['name'], 'host': HOST,
                                  'url': case['server'].url, 'pin': case['pin'],
                                  'expect': case['expect']} for case in cases]})
    finished = subprocess.run([str(binary)], input=plan, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if finished.returncode == 2 or not finished.stdout.strip():
        raise CheckError('tls-smoke could not run: '
                         + (finished.stderr.strip() or f'exit {finished.returncode}'))
    try:
        report = json.loads(finished.stdout)
    except json.JSONDecodeError as broken:
        raise CheckError(f'tls-smoke printed no report ({broken})') from broken
    report['exit_status'] = finished.returncode
    return report


# ----------------------------------------------------------------- checks


def short(reason):
    """The reason without the prefix every pinned failure repeats."""
    if reason is None:
        return 'no reason reported'
    prefix = 'pinned server verification failed'
    if not reason.startswith(prefix):
        return reason
    rest = reason[len(prefix):].lstrip()
    if rest.startswith('('):
        return rest[1:].replace('): ', ': ', 1)
    return rest.lstrip(': ')


def verify(cases, report):
    """Every expectation, as ``(failures, printable lines, evidence rows)``."""
    results = {entry['name']: entry for entry in report['results']}
    lines, rows, failures = [], [], []
    for case in cases:
        name = case['name']
        entry = results.get(name)
        counted = case['server'].requests
        if entry is None:
            failures.append(f'{name}: tls-smoke reported nothing')
            continue
        accepted = entry['accepted']
        if accepted != (case['expect'] == 'accept'):
            failures.append(f'{name}: expected {case["expect"]}, '
                            f'{"accepted" if accepted else "rejected"}')
        if case['expect'] == 'accept':
            if entry.get('status') != 200:
                failures.append(f'{name}: status {entry.get("status")}, expected 200')
            if counted != 1:
                failures.append(f'{name}: the server counted {counted} requests, expected 1')
            detail = f'HTTP {entry.get("status")}, {counted} request'
        else:
            # The rule of `TlsSmoke.java:33`: a refused peer never saw the
            # request, so no credential could have leaked to it.
            if counted != 0:
                failures.append(f'{name}: the server counted {counted} requests '
                                'after a refused handshake')
            reason = short(entry.get('reason'))
            if name == 'legacy-tls':
                # Check 9 is decided by the session floor, before any challenge
                # reaches the delegate, so the reason is a transport error.
                reason = f'the TLS 1.1 server never got a challenge ({reason})'
            detail = f'{counted} requests, {reason}'
        lines.append(f'  {name:<13} {"accepted" if accepted else "rejected"}  {detail}')
        rows.append({'name': name, 'expect': case['expect'], 'accepted': accepted,
                     'status': entry.get('status'), 'check': entry.get('check'),
                     'reason': entry.get('reason'), 'requests': counted})
    if not report.get('empty_pin_rejected'):
        failures.append('an empty pin was accepted by PinnedTrustEvaluator')
    if report.get('tls_minimum') != 'TLSv12' or report.get('tls_maximum') != 'TLSv13':
        failures.append(f'the pinned session offers {report.get("tls_minimum")}'
                        f'..{report.get("tls_maximum")}, expected TLSv12..TLSv13')
    if report.get('exit_status') not in (0, 1):
        failures.append(f'tls-smoke exited with {report.get("exit_status")}')
    return failures, lines, rows


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--openssl', default=os.environ.get('OPENSSL', '/opt/homebrew/bin/openssl'),
                        help='OpenSSL 3 binary (LibreSSL has no -addext)')
    parser.add_argument('--scratch-path', default=str(DEFAULT_SCRATCH),
                        help='SwiftPM scratch directory (default: clients/ios/out/spm)')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse an already built tls-smoke')
    parser.add_argument('--keep', action='store_true',
                        help='keep the generated certificates and print their directory')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    binary = shutil.which(args.openssl) or args.openssl
    try:
        version = subprocess.run([binary, 'version'], stdout=subprocess.PIPE,
                                 text=True).stdout.strip()
    except OSError as missing:
        print(f'ERROR: {args.openssl} cannot be run ({missing})', file=sys.stderr)
        return 2
    if not version.startswith('OpenSSL 3'):
        print(f'ERROR: {binary} is "{version}"; OpenSSL 3 is required for -addext',
              file=sys.stderr)
        return 2

    servers, temporary = [], None
    try:
        smoke = build_smoke(Path(args.scratch_path), args.skip_build)
        temporary = tempfile.mkdtemp(prefix='paranoid-ios-tls-')
        directory = Path(temporary)
        directory.chmod(0o700)
        key = generate_fixtures(binary, directory)
        pin = spki_pin(binary, directory / 'valid.crt', directory)
        weak_pin = spki_pin(binary, directory / 'rsa-1024.crt', directory)

        plan = [('valid', 'valid.crt', key, pin, 'accept', False),
                ('wrong-pin', 'valid.crt', key, ZERO_PIN, 'reject', False),
                ('wrong-ip', 'wrong-ip.crt', key, pin, 'reject', False),
                ('expired', 'expired.crt', key, pin, 'reject', False),
                ('ca-chain', 'ca-chain.crt', key, pin, 'reject', False),
                ('dns-san-only', 'dns-san-only.crt', key, pin, 'reject', False),
                ('no-eku', 'no-eku.crt', key, pin, 'reject', False),
                ('rsa-1024', 'rsa-1024.crt', directory / 'rsa-1024.key', weak_pin,
                 'reject', True)]
        cases = []
        for name, certificate, private_key, case_pin, expect, weak in plan:
            context = server_context(directory / certificate, private_key,
                                     seclevel_zero=weak)
            server = FixtureServer(name, context)
            servers.append(server)
            cases.append({'name': name, 'server': server, 'pin': case_pin,
                          'expect': expect})
        legacy, skipped = legacy_server(directory, key)
        if legacy is not None:
            servers.append(legacy)
            cases.append({'name': 'legacy-tls', 'server': legacy, 'pin': pin,
                          'expect': 'reject'})

        report = run_smoke(smoke, cases)
        failures, lines, rows = verify(cases, report)
    except CheckError as problem:
        print(f'ERROR: {problem}', file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired:
        print('ERROR: tls-smoke did not finish within 300 s', file=sys.stderr)
        return 2
    finally:
        for server in servers:
            server.stop()
        if temporary is not None:
            if args.keep:
                print(f'fixtures kept in {temporary}')
            else:
                shutil.rmtree(temporary, ignore_errors=True)

    for line in lines:
        print(line)
    if legacy is None:
        print(f'  legacy-tls    SKIPPED   {skipped}')
    accepted = sum(1 for row in rows if row['expect'] == 'accept' and row['accepted'])
    rejected = sum(1 for row in rows
                   if row['expect'] == 'reject' and not row['accepted']
                   and row['name'] != 'legacy-tls' and row['requests'] == 0)
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(json.dumps({
        'openssl': version,
        'accepted': accepted,
        'rejected_before_http': rejected,
        'legacy_tls_1_1': 'rejected' if legacy is not None else f'skipped: {skipped}',
        'empty_pin_rejected': report.get('empty_pin_rejected'),
        'tls_minimum': report.get('tls_minimum'),
        'tls_maximum': report.get('tls_maximum'),
        'cases': rows,
    }, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    if failures:
        for failure in failures:
            print(f'  FAIL {failure}', file=sys.stderr)
        print(f'Pinned TLS (iOS): FAIL ({len(failures)} broken expectations)',
              file=sys.stderr)
        return 1
    print(f'Pinned TLS (iOS): PASS ({accepted} accepted, '
          f'{rejected} rejected before HTTP)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
