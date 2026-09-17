#!/usr/bin/env python3
"""The seven answers the iOS TURN lane can meet, over a real pinned socket.

`VoiceRelayLane` is the port of `RealtimeLoop.requestVoiceRelay` /
`runVoiceRequest` (`clients/android/src/org/paranoid/text/RealtimeLoop.java:105-168`)
and of `docs/protocol/voice-turn-v1.md`. What it decides is a protocol rule —
which status grants media authority, which one permits the disclosed direct-ICE
mode and which one grants nothing — so nothing here is mocked:

1. `scripts/create-test-tls.py` issues a throw-away EC identity for `127.0.0.1`
   in a private temporary directory (deleted at the end);
2. `clients/ios/test/turn_stub.py` serves it over TLS 1.2+ on loopback and
   **verifies the client's Ed25519 signature itself**: it rebuilds the whole
   `paranoid-session-request-v1` transcript from the public session context and
   the device's public key, so a client that signed a different method, path,
   body digest or session is refused rather than served
   (`key-protocol/src/session_v2.rs:45-59`). It runs in the git-ignored
   virtualenv `clients/ios/out/venv-turn`, the only thing in this repository
   that needs a third-party Python package;
3. `voice-lane-probe` is the shipped client: the real Rust core signs each
   request, `StateOwner` owns the state, `ProofFlow` brings the session up and
   `VoiceRelayTransport` carries the bytes over the real `URLSession` stack and
   the real pinned trust.

Each scenario is then decided **twice**: by what the client reported and by
what the stub saw — how many attempts it took, whether each one was a fresh
nonce over a valid signature, and what the request looked like on the wire.

=================  ============================================================
`relay`            a valid document grants relay authority in one attempt
`retry`            the first ambiguous 401 is signed again once, and only once
`unauthorized`     a second 401 grants nothing and never becomes direct mode
`not_found`        a valid authenticated 404 permits the disclosed direct mode
`busy`             429 fails; capacity is not capability
`unavailable`      503 fails; a broken issuer is not an absent one
`malformed`        a 200 that is not this document fails on the schema
=================  ============================================================

Usage:
  python3 clients/ios/test_voice_relay_lane.py --evidence-dir out/checks/voice-lane
  python3 clients/ios/test_voice_relay_lane.py --skip-build   # reuse the probe

Exit status: 0 when all seven hold and every signature verified, 1 when one
does not, 2 when the run could not decide (no Swift, no virtualenv, a stub that
could not start). Evidence is one JSON document of counts, statuses and
verdicts: no credential, no nonce, no session identifier, no account and no
address of this machine appear in it. No hosted server is contacted: every
socket is loopback.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'out'
LOG = OUT / 'logs/test-voice-relay-lane.log'
VENV = OUT / 'venv-turn'
REQUIREMENTS = HERE / 'requirements-test.txt'
STUB = HERE / 'test/turn_stub.py'
PACKAGE = HERE / 'ParanoidKit'
SCRATCH = OUT / 'spm'
CREATE_TLS = ROOT / 'scripts/create-test-tls.py'
HOST = '127.0.0.1'
PROBE = 'voice-lane-probe'
PROBE_TIMEOUT = 300
READY_TIMEOUT = 60

# The seven stories: the script the stub answers, what the client must decide,
# and how many signed attempts that may take.
SCENARIOS = [
    {'name': 'relay',
     'rule': 'a valid document grants relay authority in one attempt',
     'responses': [{'status': 200, 'body': 'config'}],
     'outcome': 'relay', 'attempts': 1},
    {'name': 'retry',
     'rule': 'the first ambiguous 401 is signed again once, and only once',
     'responses': [{'status': 401, 'code': 'unauthorized'},
                   {'status': 200, 'body': 'config'}],
     'outcome': 'relay', 'attempts': 2},
    {'name': 'unauthorized',
     'rule': 'a second 401 grants nothing and never becomes direct mode',
     'responses': [{'status': 401, 'code': 'unauthorized'},
                   {'status': 401, 'code': 'unauthorized'}],
     'outcome': 'failed', 'attempts': 2},
    {'name': 'not_found',
     'rule': 'a valid authenticated 404 permits the disclosed direct mode',
     'responses': [{'status': 404, 'code': 'turn_disabled'}],
     'outcome': 'direct', 'attempts': 1},
    {'name': 'busy',
     'rule': '429 fails; capacity is not capability',
     'responses': [{'status': 429, 'code': 'rate_limited'}],
     'outcome': 'failed', 'attempts': 1},
    {'name': 'unavailable',
     'rule': '503 fails; a broken issuer is not an absent one',
     'responses': [{'status': 503, 'code': 'unavailable'}],
     'outcome': 'failed', 'attempts': 1},
    {'name': 'malformed',
     'rule': 'a 200 that is not this document fails on the schema',
     'responses': [{'status': 200, 'body': 'malformed'}],
     'outcome': 'failed', 'attempts': 1},
]


class CheckError(Exception):
    """An environment problem: the run cannot decide anything (exit 2)."""


def log(message):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('a', encoding='utf-8') as handle:
        handle.write(message + '\n')


# ---------------------------------------------------------------- virtualenv


def interpreter(skip_build):
    """The virtualenv of `requirements-test.txt`, created once and reused.

    It lives under `clients/ios/out/`, which is git-ignored, so nothing it
    holds can reach the repository. The system interpreter is never modified.
    """
    python = VENV / 'bin/python'
    if python.is_file() and _has_cryptography(python):
        return python
    if skip_build and python.is_file():
        raise CheckError(f'{VENV} has no cryptography; run without --skip-build')
    log(f'$ {sys.executable} -m venv {VENV}')
    VENV.parent.mkdir(parents=True, exist_ok=True)
    created = subprocess.run([sys.executable, '-m', 'venv', str(VENV)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log(created.stdout or '')
    if created.returncode != 0 or not python.is_file():
        raise CheckError(f'python -m venv failed; see {LOG}')
    log(f'$ {python} -m pip install -r {REQUIREMENTS}')
    installed = subprocess.run([str(python), '-m', 'pip', 'install',
                                '--disable-pip-version-check', '-r', str(REQUIREMENTS)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log(installed.stdout or '')
    if installed.returncode != 0 or not _has_cryptography(python):
        raise CheckError(f'pip install -r {REQUIREMENTS} failed; see {LOG}')
    return python


def _has_cryptography(python):
    probe = subprocess.run([str(python), '-c', 'import cryptography'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return probe.returncode == 0


# --------------------------------------------------------------------- probe


def build_probe(skip_build):
    """`swift build --product voice-lane-probe`; the path of the executable."""
    swift = shutil.which('swift')
    if swift is None:
        raise CheckError('swift is not on PATH (Xcode 26.6 expected)')
    command = [swift, 'build', '--package-path', str(PACKAGE),
               '--scratch-path', str(SCRATCH), '--product', PROBE]
    if not skip_build:
        log('$ ' + ' '.join(command))
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open('a', encoding='utf-8') as handle:
            if subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT).returncode != 0:
                raise CheckError(f'swift build --product {PROBE} failed; see {LOG}')
    where = subprocess.run([swift, 'build', '--package-path', str(PACKAGE),
                            '--scratch-path', str(SCRATCH), '--show-bin-path'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if where.returncode != 0:
        raise CheckError('swift build --show-bin-path failed')
    binary = Path(where.stdout.strip()) / PROBE
    if not binary.is_file():
        raise CheckError(f'{binary} does not exist; run without --skip-build')
    return binary


# ------------------------------------------------------------------ fixture


def issue_certificate(directory):
    """One throw-away identity for `127.0.0.1`, and its SPKI pin."""
    output = directory / 'tls'
    result = subprocess.run([sys.executable, str(CREATE_TLS), '--ip', HOST,
                             '--output', str(output)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise CheckError(f'create-test-tls.py failed: {detail[-1] if detail else result.returncode}')
    descriptor = json.loads((output / 'public-connection.json').read_text())
    return output / 'server.crt', output / 'server.key', descriptor['tls_spki_sha256']


def start_stub(python, directory, certificate, key):
    """The signature-verifying issuer; its process, its port and its files."""
    script = directory / 'script.json'
    script.write_text(json.dumps({'responses': [response
                                                for scenario in SCENARIOS
                                                for response in scenario['responses']]}))
    identity = directory / 'identity.json'
    record = directory / 'record.jsonl'
    record.write_text('')
    ready = directory / 'ready.json'
    command = [str(python), str(STUB), '--cert', str(certificate), '--key', str(key),
               '--host', HOST, '--script', str(script), '--identity', str(identity),
               '--record', str(record), '--ready', str(ready)]
    log('$ ' + ' '.join(command))
    errors = (directory / 'stub.log').open('w', encoding='utf-8')
    process = subprocess.Popen(command, stdout=errors, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + READY_TIMEOUT
    while time.monotonic() < deadline:
        if ready.is_file():
            port = json.loads(ready.read_text())['port']
            return process, port, identity, record
        if process.poll() is not None:
            raise CheckError('turn_stub.py exited before it was ready: '
                             + (directory / 'stub.log').read_text().strip().splitlines()[-1:][0]
                             if (directory / 'stub.log').read_text().strip() else 'no output')
        time.sleep(0.05)
    process.terminate()
    raise CheckError(f'turn_stub.py did not bind within {READY_TIMEOUT} s')


def run_probe(binary, directory, realm, pin, identity):
    """One probe run; its report."""
    state = directory / 'device'
    state.mkdir(parents=True, exist_ok=True)
    plan = json.dumps({'realm': realm, 'pin': pin, 'directory': str(state),
                       'identity': str(identity),
                       'scenarios': [scenario['name'] for scenario in SCENARIOS]})
    finished = subprocess.run([str(binary)], input=plan, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=PROBE_TIMEOUT)
    if finished.returncode != 0 or not finished.stdout.strip():
        raise CheckError(f'{PROBE} could not run: '
                         + (finished.stderr.strip() or f'exit {finished.returncode}'))
    try:
        return json.loads(finished.stdout)
    except json.JSONDecodeError as broken:
        raise CheckError(f'{PROBE} printed no report ({broken})') from broken


def read_record(path):
    """What the stub saw, in the order it saw it."""
    entries = []
    for line in path.read_text().splitlines():
        if line.strip():
            entries.append(json.loads(line))
    return sorted(entries, key=lambda entry: entry['n'])


def group(entries):
    """The credential requests of each scenario, split by the markers."""
    grouped = {}
    current = None
    for entry in entries:
        if entry.get('route') == 'marker':
            current = int(entry['path'].split('=')[-1])
            grouped.setdefault(current, [])
        elif entry.get('route') == 'turn' and current is not None:
            grouped.setdefault(current, []).append(entry)
    return grouped


# ------------------------------------------------------------------- checks


class Verdict:
    """One check: its failures, the line it prints and the row it stores."""

    def __init__(self, name, rule):
        self.name = name
        self.rule = rule
        self.failures = []
        self.detail = {}

    def require(self, condition, complaint):
        if not condition:
            self.failures.append(f'{self.name}: {complaint}')
        return condition

    @property
    def passed(self):
        return not self.failures


def verify(report, entries):
    """Every scenario, from both sides."""
    grouped = group(entries)
    reported = {entry['name']: entry for entry in report.get('scenarios', [])}
    connections = [entry['connection'] for entry in entries if entry.get('route') == 'turn']
    verdicts = []

    for index, scenario in enumerate(SCENARIOS):
        check = Verdict(scenario['name'], scenario['rule'])
        seen = reported.get(scenario['name'])
        attempts = grouped.get(index, [])
        if not check.require(seen is not None,
                             'the probe reported nothing for this scenario'):
            verdicts.append(check)
            continue

        check.require(seen['outcome'] == scenario['outcome'],
                      f'the client decided {seen["outcome"]}, expected {scenario["outcome"]}')
        check.require(seen['authorized'] == (scenario['outcome'] != 'failed'),
                      f'the client reported authorized={seen["authorized"]} '
                      f'for {scenario["outcome"]}')
        check.require(len(attempts) == scenario['attempts'],
                      f'the stub counted {len(attempts)} signed attempts, '
                      f'expected {scenario["attempts"]}')
        for attempt in attempts:
            check.require(attempt['signature_verified'],
                          'the stub could not verify the signature of an attempt')
            check.require(attempt['nonce_fresh'], 'a nonce was reused')
            check.require(not attempt['problems'], f'the stub refused: {attempt["problems"]}')
            check.require(attempt['method'] == 'GET' and not attempt['query']
                          and attempt['body_bytes'] == 0,
                          'the request was not GET /v2/voice/turn with no query and no body')
            check.require(attempt['authorization_headers'] == 1,
                          f'{attempt["authorization_headers"]} Authorization headers')
        check.require([attempt['status'] for attempt in attempts]
                      == [response['status'] for response in scenario['responses']],
                      'the stub did not answer this scenario with its script')

        detail = seen.get('detail') or {}
        if scenario['outcome'] == 'relay':
            check.require(detail.get('urls_bound_to_realm') is True,
                          'the two relay URLs are not the exact forms on the retained origin')
            check.require(detail.get('urls') == 2, 'the document did not carry two URLs')
            check.require(detail.get('usable_before_media') is True,
                          'the credential was not usable at the moment media would be created')
            check.require(detail.get('absent_from_snapshot') is True,
                          'the credential reached the durable snapshot')
        else:
            check.require(not detail, 'a non-relay outcome carried credentials')

        check.detail = {'outcome': seen['outcome'], 'attempts': len(attempts),
                        'statuses': [attempt['status'] for attempt in attempts],
                        'signatures_verified': sum(1 for attempt in attempts
                                                   if attempt['signature_verified']),
                        'ms': seen.get('ms'), 'credential': detail}
        verdicts.append(check)

    # The properties that belong to the whole run rather than to one scenario
    # are folded into the first check, so that the count stays seven.
    whole = verdicts[0]
    whole.require(report.get('session_kept') is True,
                  'the optional voice route discarded the text session')
    whole.require(report.get('discovery_due') is False,
                  'the optional voice route forced legacy text rediscovery')
    whole.require(report.get('authorization_losses') == 0,
                  'a voice failure claimed lost authorization')
    whole.require(report.get('notifications') == 0,
                  'a voice failure published a connection status')
    whole.require(len(connections) == len(set(connections)),
                  'two credential requests shared one connection')
    whole.detail['run'] = {'session_kept': report.get('session_kept'),
                           'discovery_due': report.get('discovery_due'),
                           'authorization_losses': report.get('authorization_losses'),
                           'notifications': report.get('notifications'),
                           'connections': len(set(connections))}
    return verdicts


def signatures(entries):
    """How many credential requests there were, and how many verified."""
    turns = [entry for entry in entries if entry.get('route') == 'turn']
    return len(turns), sum(1 for entry in turns if entry.get('signature_verified'))


# ------------------------------------------------------------------ evidence


def write_evidence(directory, verdicts, report, entries, elapsed):
    directory.mkdir(parents=True, exist_ok=True)
    total, verified = signatures(entries)
    document = {
        'tool': 'clients/ios/test_voice_relay_lane.py',
        'stub': 'clients/ios/test/turn_stub.py',
        'probe': 'clients/ios/ParanoidKit/Sources/voice-lane-probe/main.swift',
        'lane': 'clients/ios/ParanoidKit/Sources/ParanoidKit/Voice/VoiceRelayLane.swift',
        'transport': 'clients/ios/ParanoidKit/Sources/ParanoidKit/Voice/VoiceRelayTransport.swift',
        'source': 'docs/protocol/voice-turn-v1.md',
        # The realm is loopback and a throw-away port; it is recorded as a
        # shape, not as an address, so this file can travel into a pull
        # request unchanged.
        'realm': 'https://<loopback>:<ephemeral>',
        'swift': version(['swift', '--version']),
        'python': version([sys.executable, '--version']),
        'signed_requests': total,
        'signatures_verified': verified,
        'elapsed_s': round(elapsed, 1),
        'checks': [{'name': verdict.name, 'rule': verdict.rule,
                    'passed': verdict.passed, 'detail': verdict.detail,
                    'failures': verdict.failures} for verdict in verdicts],
        'probe_report': report,
        'stub_record': entries,
    }
    path = directory / 'voice-relay-lane.json'
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return path


def version(command):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'
    return result.stdout.strip().splitlines()[0] if result.stdout.strip() else 'unknown'


# ---------------------------------------------------------------------- main


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--evidence-dir', default='out/checks/voice-lane',
                        help='where the evidence JSON goes; a relative path is '
                             'taken under clients/ios/ (default: out/checks/voice-lane)')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse the already built voice-lane-probe')
    parser.add_argument('--keep', action='store_true',
                        help='keep the generated certificate and records')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    evidence = Path(args.evidence_dir)
    if not evidence.is_absolute():
        evidence = HERE / evidence
    stub, temporary = None, None
    try:
        python = interpreter(args.skip_build)
        binary = build_probe(args.skip_build)
        temporary = tempfile.mkdtemp(prefix='paranoid-ios-voice-lane-')
        directory = Path(temporary)
        directory.chmod(0o700)
        certificate, key, pin = issue_certificate(directory)
        stub, port, identity, record = start_stub(python, directory, certificate, key)
        realm = f'https://{HOST}:{port}'
        started = time.monotonic()
        report = run_probe(binary, directory, realm, pin, identity)
        elapsed = time.monotonic() - started
        entries = read_record(record)
        verdicts = verify(report, entries)
    except CheckError as problem:
        print(f'ERROR: {problem}', file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired:
        print(f'ERROR: {PROBE} did not finish within {PROBE_TIMEOUT} s', file=sys.stderr)
        return 2
    finally:
        if stub is not None:
            stub.terminate()
            try:
                stub.wait(timeout=10)
            except subprocess.TimeoutExpired:
                stub.kill()
        if temporary is not None:
            if args.keep:
                print(f'fixture kept in {temporary}')
            else:
                shutil.rmtree(temporary, ignore_errors=True)

    path = write_evidence(evidence, verdicts, report, entries, elapsed)
    for verdict in verdicts:
        mark = 'PASS' if verdict.passed else 'FAIL'
        print(f'  {verdict.name:<14} {mark}  {verdict.rule}')
    total, verified = signatures(entries)
    passed = sum(1 for verdict in verdicts if verdict.passed)
    print(f'evidence: {path}')
    if passed != len(verdicts) or total == 0 or verified != total:
        for verdict in verdicts:
            for failure in verdict.failures:
                print(f'  FAIL {failure}', file=sys.stderr)
        if verified != total:
            print(f'  FAIL {total - verified} of {total} signatures did not verify',
                  file=sys.stderr)
        print(f'VoiceRelayLane (iOS): {passed}/{len(verdicts)} PASS', file=sys.stderr)
        return 1
    print(f'VoiceRelayLane (iOS): {passed}/{len(verdicts)} PASS, signature verified '
          f'({verified}/{total} requests, {elapsed:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
