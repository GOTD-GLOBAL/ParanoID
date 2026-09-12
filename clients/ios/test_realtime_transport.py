#!/usr/bin/env python3
"""Eight socket rules of the iOS `RealtimeTransport`, checked against a real edge.

The transport is the port of
`clients/android/src/org/paranoid/text/RealtimeTransport.java` and of the
client half of `docs/protocol/realtime-v1.md:135-151`. Every rule in it is a
rule about a socket, so nothing here is mocked:

1. `scripts/create-test-tls.py` issues a throw-away EC identity for
   `127.0.0.1` in a private temporary directory (deleted at the end);
2. `clients/ios/test/fake_server.py` serves it over TLS 1.2+ on loopback — a
   hand-written HTTP/1.1 server that keeps connections alive, **closes an idle
   one after eight seconds** and **resets a connection in the middle of a
   request**;
3. `clients/ios/test/realtime_probe.swift` is compiled together with the
   shipped `ParanoidKit/Sources/ParanoidKit/{Net,Tls}` sources and dials that
   server through the real `URLSession` stack and the real pinned trust.

Each check is then decided **twice**: by what the client reported and by what
the server saw. The second half is what makes the interesting ones provable —
an oversized POST that never arrived, a redirect that was never followed, a
long poll that was attempted exactly twice.

===================  ===========================================================
`redirect`           302 is an answer, never a hop (`RealtimeTransport.java:35`)
`request_limit`      a 70 000-byte POST is refused before a socket is used
                     (`:41`)
`response_limit`     a 3 MiB 200 body is abandoned at 2 MiB (`:50-51`)
`read_timeout`       8 s everywhere, 30 s on `/v2/events?…` (`:36`), and a
                     timeout is never repeated
`error_body`         an error body is cut at 4096 bytes and the status survives
                     (`:50-56`)
`capacity`           two requests at a time; the third waits (`:18`, `:30`)
`idle_close`         the server closes an idle socket after 8 s and the next
                     call still succeeds; a one-shot lane leaves none open
`retry_once`         a connection lost mid-request repeats the identical
                     operation exactly once — never twice
===================  ===========================================================

Usage:
  python3 clients/ios/test_realtime_transport.py --evidence-dir out/checks/transport
  python3 clients/ios/test_realtime_transport.py --skip-build   # reuse the probe

Exit status: 0 when all eight hold, 1 when one does not, 2 when the run could
not decide (no Swift, no OpenSSL 3, a probe that could not start). Evidence is
written as one JSON document with counts, statuses and sizes in it and no
request or response body anywhere. No hosted server is contacted: every socket
is loopback.
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
LOG = OUT / 'logs/test-realtime-transport.log'
PROBE_SOURCE = HERE / 'test/realtime_probe.swift'
PROBE_BINARY = OUT / 'realtime-probe'
SOURCES = [HERE / 'ParanoidKit/Sources/ParanoidKit/Net',
           HERE / 'ParanoidKit/Sources/ParanoidKit/Tls']
CREATE_TLS = ROOT / 'scripts/create-test-tls.py'
HOST = '127.0.0.1'
# The server's own idle rule; the probe waits longer than this on purpose.
IDLE_TIMEOUT = 8.0
PROBE_TIMEOUT = 300
# The rules themselves, as `RealtimeTransport.java` and
# `docs/protocol/realtime-v1.md:135-151` state them. They are written out here
# rather than read from the client, so that a client which moved one of them
# fails this check instead of redefining it.
REQUEST_LIMIT = 65536          # `RealtimeTransport.java:41`
RESPONSE_LIMIT = 2 * 1024 * 1024  # `:50`
ERROR_LIMIT = 4096             # `:50`
CAPACITY = 2                   # `:18`, `docs/protocol/realtime-v1.md:150`
READ_TIMEOUT_S = 8             # `:36`
EVENTS_READ_TIMEOUT_S = 30     # `:36`

sys.path.insert(0, str(HERE / 'test'))
import fake_server  # noqa: E402  (the path is set up right above)


class CheckError(Exception):
    """An environment problem: the run cannot decide anything (exit 2)."""


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


# -------------------------------------------------------------------- probe


def build_probe(skip_build):
    """Compiles the probe over the shipped transport sources.

    The transport depends on `Foundation` and `Security` only — not on the
    core xcframework and not on any other target of the package — so it is
    compiled directly instead of through SwiftPM. That keeps this check
    independent of `build-core.sh` and of every other source file in
    `ParanoidKit`.
    """
    if skip_build and PROBE_BINARY.is_file():
        return PROBE_BINARY
    swiftc = shutil.which('swiftc')
    if swiftc is None:
        raise CheckError('swiftc is not on PATH (Xcode 26.6 / Swift 6.3.3 expected)')
    files = sorted(str(path) for directory in SOURCES for path in directory.glob('*.swift'))
    if not files:
        raise CheckError(f'no Swift sources under {", ".join(str(p) for p in SOURCES)}')
    LOG.parent.mkdir(parents=True, exist_ok=True)
    PROBE_BINARY.parent.mkdir(parents=True, exist_ok=True)
    command = [swiftc, '-swift-version', '6', '-parse-as-library',
               '-module-name', 'RealtimeProbe', '-o', str(PROBE_BINARY),
               str(PROBE_SOURCE)] + files
    with LOG.open('w', encoding='utf-8') as log:
        log.write('$ ' + ' '.join(command) + '\n')
        log.flush()
        if subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode != 0:
            raise CheckError(f'swiftc failed; see {LOG}')
    return PROBE_BINARY


def run_probe(binary, url, pin):
    """One probe run; returns its report."""
    plan = json.dumps({'url': url, 'pin': pin})
    finished = subprocess.run([str(binary)], input=plan, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=PROBE_TIMEOUT)
    if finished.returncode == 2 or not finished.stdout.strip():
        raise CheckError('realtime-probe could not run: '
                         + (finished.stderr.strip() or f'exit {finished.returncode}'))
    try:
        report = json.loads(finished.stdout)
    except json.JSONDecodeError as broken:
        raise CheckError(f'realtime-probe printed no report ({broken})') from broken
    report['exit_status'] = finished.returncode
    return report


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


def scenario(report, name):
    for entry in report.get('scenarios', []):
        if entry.get('name') == name:
            return entry
    raise CheckError(f'realtime-probe reported no "{name}" scenario')


def connection_of(record, op):
    """The connection that served one operation, as the server saw it."""
    snapshot = record.snapshot()
    numbers = [entry['connection'] for entry in snapshot['requests'] if entry['op'] == op]
    if not numbers:
        return None
    return next((state for state in snapshot['connections']
                 if state['connection'] == numbers[0]), None)


def identical_attempts(record, op):
    """Every attempt of one operation was byte for byte the same request.

    "The same immutable operation" is what makes one repeat safe
    (`RealtimeLoop.java:203-205`): the same method, the same target, the same
    body size and the same single credential. A client that re-signed or
    rebuilt the request between attempts would show up here.
    """
    entries = [entry for entry in record.snapshot()['requests'] if entry['op'] == op]
    shapes = {(entry['method'], entry['query'], entry['body_bytes'],
               entry['authorization_headers'], entry['content_type']) for entry in entries}
    return len(entries) >= 1 and len(shapes) == 1, {
        'attempts': len(entries),
        'method': entries[0]['method'] if entries else None,
        'body_bytes': entries[0]['body_bytes'] if entries else None,
        'authorization_headers': entries[0]['authorization_headers'] if entries else None,
        'identical': len(shapes) == 1,
    }


def header_rules(record, op):
    """`Accept: application/json` and exactly one `Authorization` (`:37-38`)."""
    snapshot = record.snapshot()
    entries = [entry for entry in snapshot['requests'] if entry['op'] == op]
    accept = all(entry['accept'] == 'application/json' for entry in entries)
    single = all(entry['authorization_headers'] == 1 for entry in entries)
    return bool(entries) and accept and single


def verify(report, record):
    """Every check, from both sides."""
    verdicts = []

    # 1 -------------------------------------------------------- redirect
    check = Verdict('redirect', 'a 302 is an answer, never a hop')
    seen = scenario(report, 'redirect')
    outcome = seen['outcome']
    check.require(outcome['kind'] == 'rejected' and outcome.get('status') == 302,
                  f'the client reported {outcome["kind"]} {outcome.get("status")}, expected a 302 rejection')
    check.require(record.count(path='/v2/redirect') == 1,
                  f'the server counted {record.count(path="/v2/redirect")} requests on /v2/redirect')
    followed = record.count(op='redirect_followed')
    check.require(followed == 0, f'the client followed the redirect ({followed} requests on its target)')
    check.require(header_rules(record, 'redirect'),
                  'the request did not carry Accept: application/json and exactly one Authorization')
    check.detail = {'status': outcome.get('status'), 'code': outcome.get('code'),
                    'requests_on_target': followed}
    verdicts.append(check)

    # 2 --------------------------------------------------- request limit
    check = Verdict('request_limit', 'a 70 000-byte POST never reaches a socket')
    seen = scenario(report, 'request_limit')
    outcome = seen['outcome']
    check.require(outcome['kind'] == 'refused' and outcome.get('error') == 'request_limit',
                  f'the client reported {outcome.get("error") or outcome["kind"]}, expected request_limit')
    check.require(outcome.get('bytes') == seen['body_bytes'] > REQUEST_LIMIT,
                  'the refusal did not report the size that was refused')
    arrived = record.count(path='/v2/sink')
    check.require(arrived == 0, f'the server counted {arrived} requests on /v2/sink')
    check.require(record.bytes_received('/v2/sink') == 0,
                  'body bytes reached /v2/sink')
    check.require(seen['next_call']['kind'] == 'ok',
                  'the lane was unusable after the refusal (a capacity slot was lost)')
    check.detail = {'refused_bytes': outcome.get('bytes'), 'requests_on_sink': arrived,
                    'limit': REQUEST_LIMIT}
    verdicts.append(check)

    # 3 -------------------------------------------------- response limit
    check = Verdict('response_limit', 'a 3 MiB 200 body is abandoned at 2 MiB')
    seen = scenario(report, 'response_limit')
    outcome = seen['outcome']
    check.require(outcome['kind'] == 'refused' and outcome.get('error') == 'response_limit',
                  f'the client reported {outcome.get("error") or outcome["kind"]}, expected response_limit')
    check.require(record.count(path='/v2/huge') == 1,
                  'the server did not serve exactly one oversized body')
    check.require(seen['limit'] == RESPONSE_LIMIT,
                  f'the client limits a 200 body to {seen["limit"]} bytes, expected {RESPONSE_LIMIT}')
    check.detail = {'limit': seen['limit'], 'aborted_writes': record.snapshot()['aborted_writes']}
    verdicts.append(check)

    # 4 ----------------------------------------------------- read timeout
    check = Verdict('read_timeout', '8 s everywhere, 30 s on /v2/events, never repeated')
    seen = scenario(report, 'read_timeout')
    bounded, poll = seen['bounded'], seen['long_poll']
    check.require(bounded['kind'] == 'failed' and bounded.get('error') == 'timed_out',
                  f'a silent server gave {bounded.get("error") or bounded["kind"]}, expected timed_out')
    check.require(7000 <= bounded['ms'] < 12000,
                  f'the bounded request failed after {bounded["ms"]} ms, expected about 8000')
    check.require(poll['kind'] == 'ok' and poll['ms'] >= 9000,
                  f'the long poll ended as {poll["kind"]} after {poll["ms"]} ms, '
                  'expected a reply past the eight-second bound')
    attempts = record.count(path='/v2/sleep')
    check.require(attempts == 1, f'a timeout was repeated ({attempts} attempts)')
    check.require(seen['read_timeout_s'] == READ_TIMEOUT_S
                  and seen['events_read_timeout_s'] == EVENTS_READ_TIMEOUT_S,
                  f'the client uses {seen["read_timeout_s"]} s / '
                  f'{seen["events_read_timeout_s"]} s, expected '
                  f'{READ_TIMEOUT_S} s / {EVENTS_READ_TIMEOUT_S} s')
    check.detail = {'bounded_ms': bounded['ms'], 'long_poll_ms': poll['ms'],
                    'attempts_after_timeout': attempts,
                    'read_timeout_s': seen['read_timeout_s'],
                    'events_read_timeout_s': seen['events_read_timeout_s']}
    verdicts.append(check)

    # 5 -------------------------------------------------------- error body
    check = Verdict('error_body', 'an error body is cut at 4096 bytes, the status survives')
    seen = scenario(report, 'error_body')
    small, large = seen['small'], seen['large']
    check.require(small['kind'] == 'rejected' and small.get('status') == 404
                  and small.get('code') == 'turn_disabled',
                  f'a short error gave {small.get("status")}/{small.get("code")!r}, '
                  'expected 404/turn_disabled')
    check.require(large['kind'] == 'rejected' and large.get('status') == 429,
                  f'a 5000-byte error gave {large["kind"]} {large.get("status")}, expected 429')
    check.require(large.get('bytes') == ERROR_LIMIT and large.get('truncated') is True,
                  f'the 5000-byte error body was kept as {large.get("bytes")} bytes, '
                  f'expected {ERROR_LIMIT} and a truncation flag')
    check.require(large.get('code') == '',
                  f'a truncated body yielded the code {large.get("code")!r}, expected none')
    check.detail = {'short': {'status': small.get('status'), 'code': small.get('code'),
                              'bytes': small.get('bytes')},
                    'long': {'status': large.get('status'), 'bytes': large.get('bytes'),
                             'truncated': large.get('truncated'), 'code': large.get('code')}}
    verdicts.append(check)

    # 6 ---------------------------------------------------------- capacity
    check = Verdict('capacity', 'two requests at a time; the third waits')
    seen = scenario(report, 'capacity')
    check.require(seen['served'] == 3, f'{seen["served"]} of 3 concurrent calls succeeded')
    concurrent = record.concurrency('/v2/slow')
    check.require(concurrent == CAPACITY,
                  f'the server had {concurrent} of those requests in flight at once, '
                  f'expected {CAPACITY}')
    check.require(seen['capacity'] == CAPACITY,
                  f'the client allows {seen["capacity"]} requests at a time, expected {CAPACITY}')
    check.require(record.count(path='/v2/slow') == 3,
                  'the server did not receive all three requests')
    check.require(seen['passed'], 'the third call did not wait for a free slot')
    check.detail = {'max_in_flight': concurrent, 'slots': seen['slots']}
    verdicts.append(check)

    # 7 -------------------------------------------------------- idle close
    check = Verdict('idle_close', 'an idle socket is closed after 8 s; the next call works')
    seen = scenario(report, 'idle_close')
    snapshot = record.snapshot()
    check.require(seen['health_realtime'] is True,
                  'the client did not read realtime=signed-long-poll-v1 out of /health')
    check.require(snapshot['idle_closes'] >= 1,
                  'the server never closed an idle connection')
    check.require(seen['after_idle']['kind'] == 'ok',
                  f'the call after {seen["idle_wait_s"]} s idle ended as '
                  f'{seen["after_idle"]["kind"]}')
    check.require(record.count(path='/health') == 2,
                  f'the server saw {record.count(path="/health")} /health requests, expected 2')
    one_shot = connection_of(record, 'one_shot')
    check.require(seen['one_shot']['kind'] == 'ok', 'the one-shot lane call failed')
    check.require(one_shot is not None and one_shot['requests'] == 1
                  and one_shot['closed_by'] == 'client',
                  f'the one-shot lane left its connection as {one_shot}')
    check.detail = {'idle_closes': snapshot['idle_closes'],
                    'idle_wait_s': seen['idle_wait_s'],
                    'after_idle_ms': seen['after_idle']['ms'],
                    'one_shot_connection': one_shot}
    verdicts.append(check)

    # 8 -------------------------------------------------------- retry once
    check = Verdict('retry_once', 'a lost connection repeats the same operation exactly once')
    seen = scenario(report, 'retry_once')
    attempts = {name: record.count(op=name)
                for name in ('retry_post', 'retry_poll', 'retry_broken')}
    check.require(seen['post']['kind'] == 'ok',
                  f'the POST cut mid-request ended as {seen["post"]["kind"]}')
    check.require(seen['long_poll']['kind'] == 'ok',
                  f'the long poll cut mid-request ended as {seen["long_poll"]["kind"]}')
    check.require(seen['never_answers']['kind'] == 'failed',
                  'a route that resets every attempt still returned a reply')
    shapes = {}
    for name, count in attempts.items():
        check.require(count == 2, f'{name} was attempted {count} times, expected exactly 2')
        same, shapes[name] = identical_attempts(record, name)
        check.require(same, f'{name} was repeated as a different request')
        check.require(header_rules(record, name),
                      f'{name} did not carry Accept: application/json and exactly one '
                      'Authorization on every attempt')
    check.require(snapshot['resets'] >= 3, 'the server did not reset three connections')
    check.detail = {'attempts': attempts, 'resets': snapshot['resets'],
                    'repeats': shapes,
                    'post': seen['post'], 'long_poll': seen['long_poll'],
                    'never_answers': seen['never_answers']}
    verdicts.append(check)

    return verdicts


# ------------------------------------------------------------------ evidence


def strip(snapshot):
    """The server's record, without the monotonic clock and without bodies."""
    requests = []
    for entry in snapshot['requests']:
        row = {key: value for key, value in entry.items() if key != 'at'}
        requests.append(row)
    stripped = dict(snapshot)
    stripped['requests'] = requests
    return stripped


def write_evidence(directory, verdicts, report, record, url):
    directory.mkdir(parents=True, exist_ok=True)
    document = {
        'tool': 'clients/ios/test_realtime_transport.py',
        'server': 'clients/ios/test/fake_server.py',
        'probe': 'clients/ios/test/realtime_probe.swift',
        'transport': 'clients/ios/ParanoidKit/Sources/ParanoidKit/Net/RealtimeTransport.swift',
        'realm': url,
        'swift': version(['swift', '--version']),
        'idle_timeout_s': IDLE_TIMEOUT,
        'checks': [{'name': verdict.name, 'rule': verdict.rule,
                    'passed': verdict.passed, 'detail': verdict.detail,
                    'failures': verdict.failures} for verdict in verdicts],
        'probe_report': report,
        'server_record': strip(record.snapshot()),
    }
    path = directory / 'realtime-transport.json'
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
    parser.add_argument('--evidence-dir', default='out/checks/transport',
                        help='where the evidence JSON goes; a relative path is '
                             'taken under clients/ios/ (default: out/checks/transport)')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse an already compiled clients/ios/out/realtime-probe')
    parser.add_argument('--keep', action='store_true',
                        help='keep the generated certificate and print its directory')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    evidence = Path(args.evidence_dir)
    if not evidence.is_absolute():
        evidence = HERE / evidence
    server, temporary = None, None
    try:
        binary = build_probe(args.skip_build)
        temporary = tempfile.mkdtemp(prefix='paranoid-ios-transport-')
        directory = Path(temporary)
        directory.chmod(0o700)
        certificate, key, pin = issue_certificate(directory)
        server = fake_server.FakeServer(certificate, key, host=HOST,
                                        idle_timeout=IDLE_TIMEOUT).start()
        started = time.monotonic()
        report = run_probe(binary, server.url, pin)
        elapsed = time.monotonic() - started
        verdicts = verify(report, server.record)
    except CheckError as problem:
        print(f'ERROR: {problem}', file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired:
        print(f'ERROR: realtime-probe did not finish within {PROBE_TIMEOUT} s', file=sys.stderr)
        return 2
    finally:
        if server is not None:
            server.stop()
        if temporary is not None:
            if args.keep:
                print(f'certificate kept in {temporary}')
            else:
                shutil.rmtree(temporary, ignore_errors=True)

    path = write_evidence(evidence, verdicts, report, server.record, server.url)
    for verdict in verdicts:
        mark = 'PASS' if verdict.passed else 'FAIL'
        print(f'  {verdict.name:<15} {mark}  {verdict.rule}')
    passed = sum(1 for verdict in verdicts if verdict.passed)
    print(f'evidence: {path}')
    if passed != len(verdicts) or report.get('exit_status') not in (0, 1):
        for verdict in verdicts:
            for failure in verdict.failures:
                print(f'  FAIL {failure}', file=sys.stderr)
        print(f'RealtimeTransport (iOS): {passed}/{len(verdicts)} PASS', file=sys.stderr)
        return 1
    print(f'RealtimeTransport (iOS): {passed}/{len(verdicts)} PASS ({elapsed:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
