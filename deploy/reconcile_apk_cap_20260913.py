#!/usr/bin/env python3
"""Exact, one-off maintenance adoption; not a generic drift bypass or updater.
See docs/rfcs/apk-cap-maintenance-reconciliation.md. Default mode is read-only.
"""
import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import sys

CHANGED_FIELDS = ('config_sha256', 'tls_cert_sha256', 'unit_sha256')
IDENTITY_FIELDS = (*CHANGED_FIELDS, 'release', 'manifest_sha256', 'pg_system_id', 'tls_key_sha256', 'tls_spki')
STATE_SHA = '8f068561a1e370597eb072a6ea5c03aaf72d847bc0771517d7c09612f55d21f4'
TARGETS = {'config_sha256': 'cbace7fe18899905ee5a685f9644448bb3bf8eada4a9632fbbd9fb19fcfb1b3a',
           'tls_cert_sha256': 'bdf0a677a2bef2c1b7a2f8ede654dd0edc87b89501ab627ab25890c7fbfb40d4',
           'unit_sha256': '75cb1158a21f1e249b4cd14ddfb28119a7e72ee5b3ecec1b974a5b7c00c10e6f'}
ROOT = Path('/home/paranoid/paranoid-alpha')
STATE = Path('/var/lib/paranoid-single-host')
KIT = Path('/opt/paranoid-single-host/7f3a77154f6568d3bc34')
AUDIT = STATE / 'reconciliations/apk-cap-20260913'
PUSH_LINE = b'LoadCredential=push-fcm-credential:/home/paranoid/paranoid-alpha/push/fcm-service-account.json\n'


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def annotate(old, live, targets, proof_sha):
    require(old.get('phase') == 'active' and not old.get('maintenance_adoptions'), 'exact unadopted active state required')
    before = old['message_result']['identity']
    require(set(before) == set(live) == set(IDENTITY_FIELDS), 'identity shape')
    require({k for k in before if before[k] != live[k]} == set(CHANGED_FIELDS), 'unexpected drift')
    require(all(live[k] == targets[k] for k in CHANGED_FIELDS), 'unapproved target')
    after = copy.deepcopy(old)
    after['message_result']['identity'] = dict(live)
    after['maintenance_adoptions'] = [{'operation': 'apk-cap-20260913', 'proof_sha256': proof_sha,
                                     'original_state_sha256': sha(canonical(old)),
                                     'reason': 'owner-authorized exact FCM enable and same-key TLS renewal reconciliation',
                                     'original_acceptance_reinterpreted': False}]
    return after


def directory(path):
    s = path.lstat()
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.geteuid() and s.st_mode & 0o077 == 0, 'private owned directory required')


def read_checked(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        s = os.fstat(f.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_uid == os.geteuid() and s.st_nlink == 1 and s.st_mode & 0o077 == 0, 'private single-link file required')
        raw = f.read(512 * 1024 + 1)
        require(len(raw) <= 512 * 1024, 'metadata too large')
        return raw


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish_noreplace(source, destination):
    # Linux atomic publication: never overwrite an existing audit image and never
    # expose a partially written final name. Unsupported kernels fail closed.
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def select_before(audit, current, journal, expected_sha):
    if os.path.lexists(audit):
        directory(audit.parent); directory(audit)
        if os.path.lexists(audit/'current.before'):
            raw = read_checked(audit/'current.before')
            require(sha(raw) == expected_sha, 'before-image does not match audited original')
            return raw
    # A directory or a private staging file may survive interruption before the
    # first atomic image publication. Only untouched, exact original live files
    # allow preparation to resume; never infer an original from an adopted state.
    raw = read_checked(current)
    require(sha(raw) == expected_sha and read_checked(journal) == raw, 'incomplete preparation with non-original metadata')
    return raw


def immutable(path, raw):
    if os.path.lexists(path):
        require(read_checked(path) == raw and path.stat().st_mode & 0o777 == 0o400, 'foreign or modified before-image')
        return
    temp = path.parent / ('.image-' + secrets.token_hex(12))
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
        with os.fdopen(fd, 'wb') as f:
            f.write(raw); f.flush(); os.fsync(f.fileno())
        publish_noreplace(temp, path)
        sync_dir(path.parent)
    finally:
        temp.unlink(missing_ok=True)


def replace_exact(path, before, after):
    require(read_checked(path) in (before, after), 'foreign metadata replacement')
    if read_checked(path) == after:
        return
    temp = path.parent / ('.reconcile-' + secrets.token_hex(12))
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(after); f.flush(); os.fsync(f.fileno())
        require(read_checked(path) == before, 'concurrent metadata change')
        os.replace(temp, path)
        sync_dir(path.parent)
    finally:
        temp.unlink(missing_ok=True)


def persist(audit, current, journal, before, after, proof_sha, after_journal=None):
    for path in (current.parent, journal.parent, audit.parent):
        directory(path)
    require(read_checked(current) in (before, after) and read_checked(journal) in (before, after), 'unknown partial state')
    if not os.path.lexists(audit):
        audit.mkdir(mode=0o700); sync_dir(audit.parent)
    directory(audit)
    immutable(audit / 'current.before', before)
    immutable(audit / 'journal.before', before)
    immutable(audit / 'state.after', after)
    immutable(audit / 'proof.sha256', (proof_sha+'\n').encode())
    replace_exact(journal, before, after)
    if after_journal:
        after_journal()
    replace_exact(current, before, after)
    require(read_checked(current) == read_checked(journal) == after, 'metadata readback')


def inspect(k, before):
    require(sha(before) == STATE_SHA, 'not the audited original transaction')
    old = k.decode_json(before)
    require(old['transaction'] == 'cb52e2ed5f6ff678998cb26eb7fa0725' and old['kit_path'] == str(KIT), 'unexpected transaction/kit')
    k.verify_root_kit(KIT); k.verify_kit(KIT)
    live = k.worker(old['intent'], KIT, 'status')['identity']
    # All unchanged fields and precisely these targets are mandatory, not advisory.
    annotate(old, live, TARGETS, '0'*64)
    uid = old['intent']['message']['uid']
    before_dir = ROOT / 'single-host-state' / old['message_result']['transaction']
    old_config = k.read_file(before_dir/'config.before', owner=uid, private=True)
    old_unit = k.read_file(before_dir/'unit.before', owner=uid, private=True)
    config_raw = k.read_file(ROOT/'config.json', owner=uid, private=True)
    unit = k.read_file(ROOT/'paranoid-alpha.service', owner=uid, private=True)
    config = k.decode_json(config_raw)
    require(config.pop('push', None) == {'v': 1, 'provider': 'fcm'}, 'unexpected push settings')
    require(config == k.decode_json(old_config), 'config delta beyond exact push')
    identity = old['message_result']['identity']
    require(sha(old_config) == identity['config_sha256'] and sha(old_unit) == identity['unit_sha256'], 'before snapshots do not match original receipt')
    require(unit.count(PUSH_LINE) == 1 and unit.replace(PUSH_LINE, b'') == old_unit, 'unit delta beyond exact FCM credential')
    old_cert = k.read_file(Path('/home/paranoid/tls-renewal-20260913/old.crt'), owner=uid, private=True)
    new_cert = k.read_file(ROOT/'tls/server.crt', owner=uid, private=True)
    require(sha(old_cert) == identity['tls_cert_sha256'] and sha(new_cert) == TARGETS['tls_cert_sha256'], 'not the recorded same-key renewal')
    require(sha(config_raw) == live['config_sha256'] and sha(unit) == live['unit_sha256'], 'runtime changed during audit')
    intent = copy.deepcopy(old['intent']); intent['expected'] = live
    result = k.worker(intent, KIT, 'preflight')
    require(result['identity'] == live, 'original worker preflight mismatch')
    # Run unchanged non-message status checks explicitly, without spoofing identity.
    network = k.network_module(KIT)
    spec = k.network_spec(old['intent'])
    receipt = k.decode_json(k.read_file(STATE/'network-receipt.json', private=True))
    network.classify_ownership(spec, network.observe(spec), receipt)
    k.require_network_active(old['intent'], KIT, k.coordinated_network(STATE, old, 'check'))
    k.verify_system_artifacts(old)
    require(k.require_message_ingress(old['intent'], network.observe(spec)) == old['message_ingress_sha256'], 'ingress drift')
    k.wait_relay_active(old)
    require(k.worker(old['intent'], KIT, 'status')['identity'] == live, 'runtime changed after checks')
    proof = {'original_state_sha256': STATE_SHA, 'identity_after': live,
             'original_kit_sha256': old['intent']['kit_sha256'],
             'checks': ['exact-push-config', 'exact-push-unit', 'exact-authorized-certificate',
                        'unchanged-key-pin-pg-release-manifest', 'original-worker-preflight',
                        'original-system-artifacts-network-ingress-relay']}
    return old, live, sha(canonical(proof))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--expect-proof')
    args = p.parse_args()
    require(os.geteuid() == 0, 'root required; fixed production paths only')
    os.umask(0o077)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(KIT))
    import single_host as k
    k.trusted_directory(STATE, 0, private=True)
    with k.exclusive_lock(STATE/'operator.lock'):
        fd = os.open(ROOT/'operation.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            s = os.fstat(fd)
            require(stat.S_ISREG(s.st_mode) and s.st_uid == 1003 and s.st_nlink == 1 and s.st_mode & 0o077 == 0, 'unsafe message operation lock')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            current = STATE/'current.json'
            journal = STATE/'transactions/cb52e2ed5f6ff678998cb26eb7fa0725/journal.json'
            before = select_before(AUDIT, current, journal, STATE_SHA)
            old, live, proof_sha = inspect(k, before)
            after = canonical(annotate(old, live, TARGETS, proof_sha))
            journal = STATE/'transactions'/old['transaction']/'journal.json'
            require(read_checked(current) in (before, after) and read_checked(journal) in (before, after), 'transaction changed')
            if args.apply:
                require(args.expect_proof == proof_sha, 'reviewed proof required')
                if not os.path.lexists(AUDIT.parent):
                    AUDIT.parent.mkdir(mode=0o700); sync_dir(STATE)
                persist(AUDIT, current, journal, before, after, proof_sha)
                require(k.status(STATE)['verified'], 'original coordinator status not verified')
            print(json.dumps({'mode': 'applied' if args.apply else 'read-only',
                              'proof_sha256': proof_sha, 'before_sha256': sha(before),
                              'after_sha256': sha(after), 'changed_identity_fields': list(CHANGED_FIELDS),
                              'runtime_modified': False, 'original_status_verified': bool(args.apply)}))
        finally:
            os.close(fd)


if __name__ == '__main__':
    main()
