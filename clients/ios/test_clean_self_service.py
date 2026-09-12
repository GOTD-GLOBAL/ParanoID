#!/usr/bin/env python3
"""Clean-install registration of the iOS client against a local stand.

Nothing here is a mock. The client is the shipped Swift code — `SnapshotStore`
over a real file, `SelfServiceClient` over the real Rust core through
`ParanoidCore.xcframework`, `ProofFlow` over `RealtimeTransport` and the pinned
TLS stack — driven through the `service-bridge` executable of `ParanoidKit`
(`clients/ios/ParanoidKit/Sources/service-bridge/main.swift`), which speaks the
line protocol of `clients/android/test/CleanSelfServiceBridge.java`. The server
is the **unchanged** binary built from the working tree, on a private
PostgreSQL 16 cluster and a throw-away TLS identity, started by
`clients/ios/local_stand.py`. The hosted server is never contacted and no phone
is touched.

One run does, in order:

1. `swift build --product service-bridge` (skipped with `--skip-build`);
2. `local_stand.py` brings up the server and the cluster on loopback;
3. one `service-bridge` process is started with the stand's realm and pin and
   a phones directory in a temporary directory that is removed at the end;
4. the scenario runs over that one process.

Scenarios are functions, one per protocol story. Today there is one:

`registration` (`--registration-only`)
    The `create` story of `clients/android/test_clean_self_service.py:106-110`:
    a phone with nothing on it creates an identity, registers with the stand
    and ends up with an active enrollment, contact material and a validated
    realtime session — and repeating both operations writes nothing.

The messaging stories (pairing, sending, receipts, the injected commit fault,
the lost-response retry) need the iOS sync cycle, which has not landed yet;
they arrive in this file with their own step. Until then the run refuses
anything but `--registration-only` instead of pretending to check it.

Usage:
  python3 clients/ios/test_clean_self_service.py --registration-only \\
      --evidence-dir out/checks/registration

Exit status: 0 when the scenario holds, 1 when it does not, 2 when the run
could not decide (no Swift, no core xcframework, a stand that did not start).
Evidence is one JSON document with counts, digests and verdicts in it: no
account, no fingerprint, no snapshot bytes, no key, no realm.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'out'
PACKAGE = HERE / 'ParanoidKit'
SCRATCH = OUT / 'spm'
XCFRAMEWORK = PACKAGE / 'Binaries/ParanoidCore.xcframework'
CORE_SLICE = XCFRAMEWORK / 'macos-arm64/libparanoid_ios_bridge.a'
LOG = OUT / 'logs/test-clean-self-service.log'
EVIDENCE_NAME = 'registration-result.json'
# The one synthetic phone this scenario needs; `service-bridge` accepts the
# same five names as the Java fixture and no real telephone number.
PHONE = 'one'
FINGERPRINT = re.compile(r'\A[0-9a-f]{64}\Z')
# `SnapshotStore.fileName`.
STATE_FILE = 'text-state.enc'
BRIDGE_TIMEOUT = 300

sys.path.insert(0, str(HERE))
import local_stand  # noqa: E402  (the path is set up right above)


class CheckError(Exception):
    """An environment problem: the run cannot decide anything (exit 2)."""


class Failure(Exception):
    """A rule of the protocol did not hold (exit 1)."""


def require(condition, message):
    if not condition:
        raise Failure(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ------------------------------------------------------------------ the bridge


def build_bridge(skip_build):
    """`swift build --product service-bridge`; returns the executable."""
    if not CORE_SLICE.is_file():
        raise CheckError(f'{CORE_SLICE} is missing; run bash clients/ios/build-core.sh first')
    if shutil.which('swift') is None:
        raise CheckError('swift not found; Xcode 26.6 with the pinned toolchain is required')
    common = ['swift', 'build', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH)]
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('w') as log:
        if not skip_build:
            built = subprocess.run(common + ['--product', 'service-bridge'],
                                   cwd=ROOT, stdout=log, stderr=log, check=False)
            if built.returncode != 0:
                raise CheckError(f'swift build failed (exit {built.returncode}); see {LOG}')
        shown = subprocess.run(common + ['--show-bin-path'], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=log, text=True, check=False)
    if shown.returncode != 0:
        raise CheckError(f'swift build --show-bin-path failed (exit {shown.returncode}); see {LOG}')
    binary = Path(shown.stdout.strip()) / 'service-bridge'
    if not binary.is_file():
        raise CheckError(f'{binary} was not built; drop --skip-build')
    return binary


class Bridge:
    """One `service-bridge` process and the `<phone>\\t<op>\\t<base64>` protocol."""

    def __init__(self, binary, phones, realm, pin):
        self.phones = phones
        self.process = subprocess.Popen([str(binary), str(phones), realm, pin],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, bufsize=1)

    def rpc(self, phone, op, value='', expect_error=False):
        if self.process.poll() is not None:
            raise CheckError(f'service-bridge exited (status {self.process.returncode})')
        encoded = base64.b64encode(value.encode()).decode()
        self.process.stdin.write(f'{phone}\t{op}\t{encoded}\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise CheckError('service-bridge closed its output')
        result = json.loads(base64.b64decode(line))
        if expect_error:
            require('error' in result, f'{phone}/{op}: expected a rejection')
        else:
            require('error' not in result,
                    f'{phone}/{op}: {result.get("error")}: {result.get("detail")}')
        return result

    def snapshot(self, phone):
        return self.phones / phone / STATE_FILE

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=BRIDGE_TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


# ---------------------------------------------------------------- the scenarios


def scenario_registration(bridge):
    """A phone with nothing on it becomes an enrolled, session-carrying device.

    It is the `create` story of `clients/android/test_clean_self_service.py`
    lines 106-110, with what the iOS connection cycle adds to it: on Android
    `sync()` registers, here `ProofFlow.connect()` does, and it goes on to
    discover the realtime capability and to open a session that the **core**
    accepts (`ProofFlow.connect()` returns `.session` only after
    `sign_session_v2` signed that session's context, `ProofFlow.swift:243-246`;
    a session minted for another identity, realm or account is refused there
    and never adopted).

    Every state transition is committed before it is used, so the commit
    counter is also a statement about ordering: two commits to have an identity
    and a clean schema, two more for the server's answer and the contact
    material, and none at all for anything that changed nothing.
    """
    snapshot = bridge.snapshot(PHONE)
    require(not snapshot.exists(), 'the phone directory is not clean')

    created = bridge.rpc(PHONE, 'create')
    require(created['identity'] and not created['active'],
            f'create must leave an unregistered identity: {created}')
    require(created['configured'] and created['dialogs'] == [], f'create left dialogs: {created}')
    require(created['contact_fingerprint'] == '',
            'contact material exists before the server answered')
    require(created['enrollment'] is None, 'an enrollment exists before registration')
    require(created['connection'] == 'none' and created['session'] is False,
            'create opened a connection')
    # `create_identity` and `upgrade_v2`, each its own candidate and its own
    # commit (`SelfServiceClient.swift` `createIdentity()`).
    require(created['commits'] == 2, f'create made {created["commits"]} commits, expected 2')
    require(snapshot.is_file(), 'the identity is not on disk')
    account = created['account']
    require(account, 'create produced no account')

    registered = bridge.rpc(PHONE, 'sync')
    require(registered['account'] == account, 'registration changed the account')
    require(registered['active'], f'the device is not enrolled: {registered}')
    enrollment = registered['enrollment']
    require(isinstance(enrollment, dict) and enrollment.get('mode') == 'active',
            f'enrollment.mode is not "active": {enrollment}')
    require(enrollment.get('account') == account, 'the enrollment names another account')
    require(enrollment.get('device'), 'the enrollment names no device')
    require(FINGERPRINT.match(str(enrollment.get('credential', ''))),
            'the enrolled credential is not a 64-digit fingerprint')
    fingerprint = registered['contact_fingerprint']
    require(FINGERPRINT.match(fingerprint),
            f'contact_fingerprint is not 64 lowercase hexadecimal digits: {fingerprint!r}')
    require(isinstance(registered['contact'], dict), 'there is no contact material')
    require(registered['dialogs'] == [], 'registration installed a dialog')
    require(registered['realtime'] is True, 'the stand did not offer the realtime capability')
    require(registered['connection'] == 'session' and registered['session'] is True,
            f'no session was issued: {registered["connection"]}')
    # `server_status_v2` and `prepare_contact_v2`; the session itself is
    # derived from the state and commits nothing.
    require(registered['commits'] == 4,
            f'registration made {registered["commits"] - 2} commits, expected 2')
    committed = digest(snapshot)
    stored_bytes = snapshot.stat().st_size

    repeated_create = bridge.rpc(PHONE, 'create')
    repeated_sync = bridge.rpc(PHONE, 'sync')
    require(repeated_create['commits'] == 4 and repeated_sync['commits'] == 4,
            'a repeated create/sync wrote a snapshot that changed nothing')
    require(digest(snapshot) == committed, 'the retained snapshot changed on a repeated run')
    require(repeated_sync['account'] == account, 'the account moved')
    require(repeated_sync['contact_fingerprint'] == fingerprint, 'the contact material moved')
    require(repeated_sync['enrollment'] == enrollment, 'the enrollment moved')
    require(repeated_sync['connection'] == 'session' and repeated_sync['session'] is True,
            'the held session was not reused')

    secrets = sorted({account, str(enrollment.get('device')), str(enrollment.get('credential')),
                      fingerprint, json.dumps(registered['contact'], sort_keys=True),
                      json.dumps(registered['request'], sort_keys=True),
                      base64.b64encode(snapshot.read_bytes()).decode(),
                      snapshot.read_bytes().hex()})
    facts = {
        'enrollment_mode': enrollment['mode'],
        'enrollment_members': sorted(enrollment),
        'contact_fingerprint_hex_digits': len(fingerprint),
        'commits': {'after_create': created['commits'],
                    'after_registration': registered['commits'],
                    'after_repeat': repeated_sync['commits']},
        'snapshot': {'bytes': stored_bytes,
                     'sha256': committed,
                     'sha256_after_repeat': digest(snapshot),
                     'unchanged_by_repeat': digest(snapshot) == committed},
        'session': {'issued': True, 'validated_by_core': True,
                    'reused_on_repeat': True, 'realtime': True},
        'dialogs': 0,
        'checks': [
            'clean phone: create_identity and upgrade_v2 are two durable commits, identity not enrolled',
            'registration: enrollment.mode active, server status and contact material two more commits',
            'contact_fingerprint is 64 lowercase hexadecimal digits',
            'session issued and validated by the core before it is adopted',
            'repeated create/sync commit nothing and leave the snapshot byte for byte',
        ],
    }
    return facts, secrets


# ------------------------------------------------------------------- evidence


ALLOWED_EVIDENCE = {
    'result', 'scenario', 'boundary', 'server_binary', 'server_sha256', 'core_slice_sha256',
    'bridge', 'enrollment_mode', 'enrollment_members', 'contact_fingerprint_hex_digits',
    'commits', 'snapshot', 'session', 'dialogs', 'checks',
}


def write_evidence(directory, facts, secrets, server_binary):
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        'result': 'PASS',
        'scenario': 'registration-only',
        'boundary': 'local stand only: unchanged server binary, private PostgreSQL 16, '
                    'throw-away loopback TLS; no hosted server, no phone, no live action',
        'server_binary': str(server_binary),
        'server_sha256': digest(server_binary),
        'core_slice_sha256': digest(CORE_SLICE),
        'bridge': 'ParanoidKit service-bridge over SelfServiceClient, SnapshotStore, '
                  'ProofFlow and RealtimeTransport',
    }
    payload.update(facts)
    unexpected = sorted(set(payload) - ALLOWED_EVIDENCE)
    require(not unexpected, f'evidence carries unexpected members: {unexpected}')
    text = json.dumps(payload, indent=2, sort_keys=True) + '\n'
    for secret in secrets:
        require(secret and secret not in text, 'evidence carries account, contact or snapshot material')
    path = directory / EVIDENCE_NAME
    path.write_text(text)
    return path


# ------------------------------------------------------------------------ run


def run(args):
    os.umask(0o077)
    if not args.registration_only:
        raise CheckError('only --registration-only is implemented; the messaging scenarios '
                         'arrive with the iOS sync cycle')
    evidence = Path(args.evidence_dir)
    if not evidence.is_absolute():
        evidence = HERE / evidence
    binary = build_bridge(args.skip_build)

    stand_argv = ['--work-dir', str(OUT)]
    if args.server_binary:
        stand_argv += ['--server-binary', str(Path(args.server_binary).resolve())]
    stand = local_stand.Stand(local_stand.parse_args(stand_argv))
    bridge = None
    with tempfile.TemporaryDirectory(prefix='paranoid-ios-clean-') as temporary:
        phones = Path(temporary) / 'phones'
        try:
            try:
                stand.start()
            except local_stand.StandError as error:
                raise CheckError(f'local stand: {error}')
            print(f'stand: {stand.descriptor["server_url"]} (log {stand.log_path})', flush=True)
            bridge = Bridge(binary, phones, stand.descriptor['server_url'],
                            stand.descriptor['tls_spki_sha256'])
            facts, secrets = scenario_registration(bridge)
            secrets = secrets + [stand.descriptor['tls_spki_sha256'], stand.descriptor['server_url']]
            path = write_evidence(evidence, facts, secrets, Path(stand.server_binary))
        finally:
            if bridge is not None:
                bridge.close()
            stand.stop()
    print('PASS clean-install registration on the local stand: ' + '; '.join(facts['checks']),
          flush=True)
    print(f'evidence: {path}', flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--registration-only', action='store_true',
                        help='the clean-install registration scenario, the only one implemented')
    parser.add_argument('--evidence-dir', default='out/checks/registration',
                        help='where the evidence JSON goes; a relative path is resolved '
                             'against clients/ios (default: out/checks/registration)')
    parser.add_argument('--server-binary', metavar='PATH',
                        help='use this paranoid-server instead of building the working tree')
    parser.add_argument('--skip-build', action='store_true',
                        help='reuse the service-bridge executable already built')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Failure as failure:
        print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    except CheckError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
