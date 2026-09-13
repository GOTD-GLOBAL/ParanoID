"""Bounded private-alpha SAME-KEY certificate maintenance; never key rotation."""
import argparse
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import stat
import uuid
import socket
import ssl
import subprocess
import time


def command(args, timeout=60):
    try:
        return subprocess.check_output(list(map(str, args)), stderr=subprocess.PIPE,
                                       timeout=timeout).decode()
    except (subprocess.SubprocessError, OSError) as error:
        # Never emit command output: health/config diagnostics may contain secrets.
        raise RuntimeError('bounded external operation failed') from None


class SystemOps:
    def __init__(self, root, unit='paranoid-alpha.service', ip='157.180.49.125'):
        self.root, self.unit, self.ip = root, unit, ip

    def fields(self, properties):
        args = ['systemctl', '--user', 'show', self.unit]
        for prop in properties:
            args.extend(['-p', prop])
        return dict(line.split('=', 1) for line in command(args, timeout=5).splitlines() if '=' in line)

    def preflight(self):
        fields = self.fields(['ActiveState', 'MainPID', 'Job'])
        require(fields.get('ActiveState') == 'active' and fields.get('MainPID', '0') != '0'
                and fields.get('Job') in ('', '0'), 'unit is not stably active; respect operator stop')
        require(command(['timedatectl', 'show', '-p', 'NTPSynchronized', '--value'], timeout=5).strip() == 'yes',
                'synchronized system time required for issuance')

    def guard(self):
        fields = self.fields(['FragmentPath', 'DropInPaths', 'NeedDaemonReload',
                              'Environment', 'EnvironmentFiles', 'LoadCredential', 'Type', 'User'])
        fragment = Path(fields.get('FragmentPath', ''))
        require(fragment.resolve(strict=True) == (self.root/self.unit).resolve(strict=True)
                and fields.get('NeedDaemonReload') == 'no' and fields.get('DropInPaths') == '',
                'unexpected unit source, drop-in or pending daemon reload')
        require(read(fragment.resolve()) == read(self.root/self.unit), 'unit source mismatch')
        # Hash, never persist plaintext environment/credential settings.
        return {'loaded': sha(json.dumps(fields, sort_keys=True).encode()),
                'source': sha(command(['systemctl', '--user', 'cat', self.unit], timeout=5).encode())}

    def start(self):
        command(['systemctl', '--user', 'start', '--no-block', self.unit], timeout=5)

    def served(self, expected):
        context = ssl.create_default_context(cadata=expected.decode('ascii'))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        with socket.create_connection((self.ip, 38443), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=self.ip) as tls:
                require(tls.getpeercert(binary_form=True) == x509.load_pem_x509_certificate(expected).public_bytes(
                    serialization.Encoding.DER), 'served certificate differs from committed candidate')

    def stop(self):
        try:
            command(['systemctl', '--user', 'stop', '--no-block', self.unit])
        except RuntimeError:
            pass  # Confirmation, not the command exit code, is authoritative.
        for _ in range(20):
            fields = dict(line.split('=', 1) for line in command([
                'systemctl', '--user', 'show', self.unit, '-p', 'ActiveState',
                '-p', 'MainPID', '-p', 'Job'], timeout=5).splitlines() if '=' in line)
            if (fields.get('ActiveState') in ('inactive', 'failed')
                    and fields.get('MainPID') == '0' and fields.get('Job') in ('', '0')):
                return
            time.sleep(4)
        raise RuntimeError('unit did not stop or retains a manager job')

    def health(self):
        for _ in range(10):
            try:
                result = command(['/usr/bin/python3', self.root/'current/alpha.py',
                                  'health', '--root', self.root], timeout=10)
                if 'PASS: TLS authenticated database readiness' in result:
                    return
            except RuntimeError:
                pass
            time.sleep(1)
        raise RuntimeError('bounded authenticated readiness failed')

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path('/home/paranoid/paranoid-alpha')
STATE = Path('/home/paranoid/tls-renewal/state')
PIN = '8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba'
IP = '157.180.49.125'
UNIT = 'paranoid-alpha.service'

def require(ok, message):
    if not ok:
        raise ValueError(message)

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def public(key):
    return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)

def directory(path):
    s = path.lstat()
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid()
            and stat.S_IMODE(s.st_mode) == 0o700, 'unsafe directory')

def safe_fd(path, flags=os.O_RDONLY, private=True):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK)
    s = os.fstat(fd)
    if not (stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid()
            and s.st_nlink == 1 and (stat.S_IMODE(s.st_mode) == 0o600 if private
                                   else not s.st_mode & 0o022)):
        os.close(fd)
        raise ValueError('unsafe file')
    return fd

def read(path, private=True):
    with os.fdopen(safe_fd(path, private=private), 'rb') as stream:
        return stream.read()

def sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def atomic(path, raw):
    metadata = None
    if os.path.lexists(path):
        fd = safe_fd(path)
        try:
            metadata = os.fstat(fd)
        finally:
            os.close(fd)
    pending = path.with_name(path.name + '.' + uuid.uuid4().hex + '.pending')
    fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        if metadata is not None:
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pending, path)
    sync(path.parent)

def stamp(path):
    s = path.lstat()
    return [s.st_dev, s.st_ino, s.st_uid, s.st_gid, s.st_mode, s.st_size, s.st_mtime_ns]

class Renewal:
    def __init__(self, root, state, pin, ip, ops, now=None):
        self.root, self.state, self.pin, self.ip, self.ops = root, state, pin, ip, ops
        self.now = now or dt.datetime.now(dt.timezone.utc).replace(tzinfo=None, microsecond=0)
        self.cert_path = root/'tls/server.crt'
        self.key_path = root/'tls/server.key'

    def identity(self, raw):
        c = x509.load_pem_x509_certificate(raw)
        key = serialization.load_pem_private_key(read(self.key_path), password=None)
        require(isinstance(key, ec.EllipticCurvePrivateKey) and key.curve.name == 'secp256r1', 'expected P-256 key')
        require(public(c.public_key()) == public(key.public_key()) and sha(public(c.public_key())) == self.pin, 'TLS identity mismatch')
        require(c.subject == c.issuer and c.signature_hash_algorithm.name == 'sha256', 'unexpected certificate profile')
        c.public_key().verify(c.signature, c.tbs_certificate_bytes, ec.ECDSA(c.signature_hash_algorithm))
        san = c.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        require(san.get_values_for_type(x509.IPAddress) == [ipaddress.ip_address(self.ip)], 'unexpected SAN')
        require(not c.extensions.get_extension_for_class(x509.BasicConstraints).value.ca, 'CA certificate forbidden')
        require(dt.timedelta(0) < c.not_valid_after-c.not_valid_before <= dt.timedelta(days=90), 'implausible certificate lifetime')
        require(c.not_valid_before <= self.now < c.not_valid_after, 'certificate outside validity')
        return c, key

    def baseline(self):
        release = (self.root/'current').resolve(strict=True)
        require(release.parent == self.root/'releases', 'release outside installation')
        return {'release': str(release), 'alpha': sha(read(release/'alpha.py', private=False)),
                'config': sha(read(self.root/'config.json')),
                'unit': sha(read(self.root/UNIT)), 'manager': self.ops.guard(),
                'key_metadata': stamp(self.key_path),
                'data_identity': stamp(self.root/'data')[:5]}

    def guard(self, record, key_raw):
        require(self.baseline() == record['before'], 'environment drift')
        require(read(self.key_path) == key_raw, 'key bytes changed')
        require(sha(read(self.cert_path)) in (record['old_sha256'], record['new_sha256']), 'unknown certificate drift')

    def transition(self, target, record, key_raw):
        self.guard(record, key_raw)
        self.ops.stop()
        self.guard(record, key_raw)
        atomic(self.cert_path, target)
        self.ops.start()
        self.ops.health()
        self.ops.served(target)
        self.guard(record, key_raw)
        require(read(self.cert_path) == target, 'certificate changed after readiness')

    def renew(self, old_raw, old, key):
        self.ops.preflight()
        before = self.baseline()
        key_raw = read(self.key_path)
        self.ops.health()
        start = self.now - dt.timedelta(minutes=5)
        builder = (x509.CertificateBuilder().subject_name(old.subject).issuer_name(old.issuer)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(start).not_valid_after(start + dt.timedelta(days=90)))
        for ext in old.extensions:
            builder = builder.add_extension(ext.value, ext.critical)
        new_raw = builder.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM)
        self.identity(new_raw)
        tx = self.state/('tx-' + uuid.uuid4().hex)
        tx.mkdir(mode=0o700)
        sync(self.state)
        atomic(tx/'old.crt', old_raw)
        atomic(tx/'new.crt', new_raw)
        record = {'phase': 'pending', 'before': before, 'pin': self.pin,
                  'old_sha256': sha(old_raw), 'new_sha256': sha(new_raw)}
        atomic(tx/'journal.json', json.dumps(record, sort_keys=True).encode())
        require(read(tx/'old.crt') == old_raw and read(tx/'new.crt') == new_raw, 'certificate archive mismatch')
        try:
            self.transition(new_raw, record, key_raw)
            record['phase'] = 'committed'
            atomic(tx/'journal.json', json.dumps(record, sort_keys=True).encode())
        except Exception:
            # A hard kill cannot execute this block: durable pending journal is replayed.
            self.failure('renewal_failed', tx.name)
            self.identity(old_raw)
            self.transition(old_raw, record, key_raw)
            record['phase'] = 'rolled_back'
            atomic(tx/'journal.json', json.dumps(record, sort_keys=True).encode())
            raise
        return {'result': 'renewed', 'transaction': tx.name}

    def failure(self, result, tx):
        atomic(self.state/'failure.json', json.dumps({'result': result, 'transaction': tx,
               'utc': self.now.isoformat()+'Z'}).encode())

    def pending(self):
        pending = []
        for tx in sorted(self.state.glob('tx-*')):
            directory(tx)
            # Incomplete preparation cannot have reached the certificate rename.
            if not os.path.lexists(tx/'journal.json'):
                continue
            record = json.loads(read(tx/'journal.json'))
            require(record['phase'] in ('pending', 'committed', 'rolled_back'), 'unknown journal phase')
            if record['phase'] == 'pending':
                pending.append((tx, record))
        require(len(pending) <= 1, 'multiple pending transactions')
        return pending

    def recover(self, tx, record, check):
        old_raw, new_raw = read(tx/'old.crt'), read(tx/'new.crt')
        require(sha(old_raw) == record['old_sha256'] and sha(new_raw) == record['new_sha256']
                and record['pin'] == self.pin, 'journal identity mismatch')
        old, key = self.identity(old_raw)
        new, _ = self.identity(new_raw)
        require(old.subject == new.subject and old.issuer == new.issuer
                and list(old.extensions) == list(new.extensions)
                and old.serial_number != new.serial_number, 'journal profile mismatch')
        key_raw = read(self.key_path)
        self.guard(record, key_raw)
        if check:
            return {'result': 'recovery_required', 'transaction': tx.name}
        self.failure('interrupted_transaction', tx.name)
        self.transition(old_raw, record, key_raw)
        record['phase'] = 'rolled_back'
        atomic(tx/'journal.json', json.dumps(record, sort_keys=True).encode())
        raise RuntimeError('interrupted transaction recovered; inspect retained journal')

    def run(self, check=False):
        for p in [self.root, self.root/'tls', self.root/'data', self.state]:
            directory(p)
        fd = safe_fd(self.root/'operation.lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            pending = self.pending()
            if pending:
                return self.recover(*pending[0], check)
            old_raw = read(self.cert_path)
            c, key = self.identity(old_raw)
            due = c.not_valid_after - dt.timedelta(days=30)
            if self.now >= due and not check:
                return self.renew(old_raw, c, key)
            return {'result': 'due' if self.now >= due else 'not_due', 'next_due': due.isoformat()+'Z'}
        finally:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='read-only validation; never recover or renew')
    args = parser.parse_args()
    import pwd
    import sys
    try:
        require(os.getuid() == pwd.getpwnam('paranoid').pw_uid and os.getuid() != 0,
                'dedicated paranoid account required')
        directory(STATE.parent)
        result = Renewal(ROOT, STATE, PIN, IP, SystemOps(ROOT, UNIT, IP)).run(check=args.check)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Exception as error:
        # Class only: neither key material nor sensitive subprocess diagnostics.
        print('TLS renewal FAILED (' + type(error).__name__ + '); inspect retained state/journal', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
