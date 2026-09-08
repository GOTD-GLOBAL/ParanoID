#!/usr/bin/env python3
"""Isolated alpha lifecycle. No SSH, sudo, package installation or deletion."""
import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import ssl
import stat
import subprocess
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PG = Path('/usr/lib/postgresql/16/bin')


def clean_env():
    return {k: v for k, v in os.environ.items()
            if not k.startswith(('PG', 'PARANOID_', 'RUST_LOG'))}


def command(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, env=clean_env(),
                          capture_output=True, **kwargs).stdout


def private(path):
    s = path.lstat()
    if path.is_symlink() or s.st_uid != os.geteuid() or s.st_mode & 0o077:
        raise ValueError('private same-owner path required')


def root_path(root):
    if (not root.is_absolute() or '..' in root.parts or os.geteuid() == 0
            or not root.name.startswith('paranoid-')
            or not re.fullmatch(r'[/A-Za-z0-9_.-]+', str(root))):
        raise ValueError('absolute simple paranoid-* root and unprivileged account required')
    for parent in root.parents:
        s = parent.lstat()
        # Root-owned sticky /tmp is safe for our exclusively created private root.
        sticky = s.st_uid == 0 and s.st_mode & stat.S_ISVTX
        if (not stat.S_ISDIR(s.st_mode) or s.st_uid not in (0, os.geteuid())
                or (s.st_mode & 0o022 and not sticky)):
            raise ValueError('real trusted non-writable ancestors required')


def initialize(root, ip):
    ip = canonical_ipv4(ip)
    root_path(root)
    os.umask(0o077)
    root.mkdir(mode=0o700)  # Never adopt or overwrite existing data.
    for name in ('socket', 'releases', 'backups'):
        (root / name).mkdir(mode=0o700)
    generator = HERE / 'create-test-tls.py'
    if not generator.exists():
        generator = HERE.parent / 'scripts/create-test-tls.py'
    command(['python3', generator, '--ip', ip, '--output', root / 'tls'])
    config = {'ip': ip, 'alice': secrets.token_hex(32), 'bob': secrets.token_hex(32)}
    with regular_file(root / 'config.json', os.O_RDWR | os.O_CREAT | os.O_EXCL, restricted=True) as stream:
        os.write(stream.fileno(), json.dumps(config).encode())
    command([PG / 'initdb', '-D', root / 'data', '-U', 'paranoid_alpha',
             '--auth-local=trust', '--auth-host=reject', '--no-locale', '-E', 'UTF8'])
    # Disable statement/error-statement logs: rejected SQL must not leak envelopes.
    with (root / 'data/postgresql.conf').open('a') as f:
        f.write("\nlisten_addresses = ''\nunix_socket_permissions = 0700\n"
                "max_connections = 20\nshared_buffers = '32MB'\n"
                "log_statement = 'none'\nlog_min_error_statement = 'panic'\n")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def canonical_ipv4(ip):
    if not isinstance(ip, str) or str(ipaddress.IPv4Address(ip)) != ip:
        raise ValueError('canonical IPv4 string required')
    return ip


def config(root):
    installation(root)
    with regular_file(root / 'config.json', restricted=True) as stream:
        c = json.load(stream, object_pairs_hook=unique_object)
    if not isinstance(c, dict) or set(c) != {'ip', 'alice', 'bob'}:
        raise ValueError('exact configuration keys required')
    canonical_ipv4(c['ip'])
    for name in ('alice', 'bob'):
        if not isinstance(c[name], str) or not re.fullmatch(r'[0-9a-fA-F]{64}', c[name]):
            raise ValueError('256-bit hex admission tokens required')
    if c['alice'].lower() == c['bob'].lower():
        raise ValueError('distinct admission tokens required')
    return c


def sql(root, query, database='postgres'):
    return command([PG / 'psql', '-X', '-h', root / 'socket', '-U', 'paranoid_alpha',
                    '-d', database, '-v', 'ON_ERROR_STOP=1', '-Atc', query])


@contextlib.contextmanager
def database(root):
    config(root)
    current_release(root)
    process = subprocess.Popen([str(PG / 'postgres'), '-D', str(root / 'data'),
                                '-k', str(root / 'socket')], env=clean_env(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if process.poll() is not None:
                raise RuntimeError('private database failed')
            try:
                if sql(root, 'SELECT 1').strip() == b'1':
                    break
            except subprocess.CalledProcessError:
                pass
            time.sleep(.05)
        else:
            raise RuntimeError('private database not ready')
        yield process
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def environment(root):
    c = config(root)
    env = clean_env()
    env.update(PARANOID_MODE='closed-alpha-v0', PARANOID_BIND=f"{c['ip']}:38443",
               PARANOID_TLS_CERT=str(root / 'tls/server.crt'),
               PARANOID_TLS_KEY=str(root / 'tls/server.key'),
               PARANOID_ALICE_TOKEN=c['alice'], PARANOID_BOB_TOKEN=c['bob'],
               PARANOID_DATABASE_URL=f'postgresql://paranoid_alpha@localhost/postgres?host={root}/socket')
    return env


def health(root):
    c = config(root)
    context = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    req = urllib.request.Request(f"https://{c['ip']}:38443/v0/messages?after=0&limit=1",
                                 headers={'Authorization': 'Bearer ' + c['bob']})
    # No proxy environment, no redirect credential forwarding.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                         urllib.request.HTTPSHandler(context=context))
    with opener.open(req, timeout=5) as response:
        result = json.load(response)
    if not isinstance(result.get('messages'), list):
        raise TypeError('invalid health response')


@contextlib.contextmanager
def lock(root):
    config(root)
    with regular_file(root / 'lifecycle.lock', os.O_RDWR | os.O_CREAT, restricted=True) as f:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def run(root):
    config(root)
    release = current_release(root)
    with lock(root), database(root) as pg:
        child = subprocess.Popen([str(release / 'paranoid-server')], env=environment(root),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def stop(*_):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, stop)
        try:
            while child.poll() is None and pg.poll() is None:
                time.sleep(.2)
            raise RuntimeError('alpha child stopped; supervisor restart required')
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=15)


@contextlib.contextmanager
def regular_file(path, flags=os.O_RDONLY, restricted=False):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            raise ValueError('single-link regular file required')
        if restricted and (s.st_uid != os.geteuid() or s.st_mode & 0o077):
            raise ValueError('private same-owner file required')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            yield stream
    finally:
        os.close(fd)


def digest(path):
    with regular_file(path) as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def release_id(version):
    if (not isinstance(version, str) or version in ('.', '..')
            or not re.fullmatch(r'[a-zA-Z0-9_.-]{1,128}', version)):
        raise ValueError('invalid release id')
    return version


def verify(release):
    for path in (release, *release.parents):
        if not stat.S_ISDIR(path.lstat().st_mode):
            raise ValueError('real release directory and ancestors required')
    files = ('paranoid-server', 'schema.sql', 'alpha.py', 'create-test-tls.py', 'README.md')
    if {p.name for p in release.iterdir()} != {*files, 'manifest.json'}:
        raise ValueError('unexpected release members')
    with regular_file(release / 'manifest.json') as stream:
        manifest = json.load(stream)
    if not isinstance(manifest, dict):
        raise ValueError('invalid release manifest')  # noqa: TRY004 - uniform invalid-input contract
    release_id(manifest.get('release'))
    if not isinstance(manifest.get('sha256'), dict) or set(manifest['sha256']) != set(files):
        raise ValueError('invalid release checksums')
    for name in files:
        if digest(release / name) != manifest['sha256'][name]:
            raise ValueError('release checksum mismatch')
    return manifest


def installation(root):
    root_path(root)
    private(root)
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError('real installation directory required')
    for name in ('data', 'socket', 'releases', 'backups', 'tls'):
        path = root / name
        private(path)
        if not stat.S_ISDIR(path.lstat().st_mode):
            raise ValueError('real persistent directory required')
    for name in ('config.json', 'tls/server.key', 'tls/server.crt'):
        with regular_file(root / name, restricted=True):
            pass
    if os.path.lexists(root / 'lifecycle.lock'):
        with regular_file(root / 'lifecycle.lock', restricted=True):
            pass
    if os.path.lexists(root / 'next'):
        raise ValueError('refuse preexisting next pointer')
    if os.path.lexists(root / 'current'):
        current_release(root)


def confined_release(root, target):
    if target.parent != root / 'releases':
        raise ValueError('release must be directly below installation releases')
    release_id(target.name)
    private(target)
    manifest = verify(target)
    if manifest['release'] != target.name:
        raise ValueError('release directory/id mismatch')
    return target


def current_release(root):
    pointer = root / 'current'
    if not pointer.is_symlink():
        raise ValueError('current must be a confined release symlink')
    target = pointer.readlink()
    if '..' in target.parts:
        raise ValueError('noncanonical current target')
    if not target.is_absolute():
        target = root / target
    return confined_release(root, target)


def candidate(root, release):
    config(root)
    manifest = verify(release)
    target = root / 'releases' / manifest['release']
    if os.path.lexists(target):
        confined_release(root, target)
        if verify(target) != manifest:
            raise ValueError('release id already exists with different content')
    return target, manifest


def stage(root, release):
    target, _ = candidate(root, release)
    if not target.exists():
        shutil.copytree(release, target)
        target.chmod(0o700)
    return confined_release(root, target)


def point(root, target):
    config(root)
    confined_release(root, target)
    temporary = root / 'next'
    temporary.symlink_to(target)
    temporary.replace(root / 'current')


def backup(root):
    """Caller holds lifecycle lock with server stopped and private PG running."""
    config(root)
    current_release(root)
    destination = root / 'backups' / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + secrets.token_hex(4))
    destination.mkdir(mode=0o700)
    dump = destination / 'history.dump'
    command([PG / 'pg_dump', '-h', root / 'socket', '-U', 'paranoid_alpha',
             '-d', 'postgres', '-Fc', '-f', dump])
    command([PG / 'pg_restore', '--list', dump])
    restored = 'verify_' + secrets.token_hex(8)
    sql(root, 'CREATE DATABASE ' + restored)
    command([PG / 'pg_restore', '-h', root / 'socket', '-U', 'paranoid_alpha',
             '-d', restored, '--exit-on-error', dump])
    probes = ["SELECT row_to_json(t) FROM (SELECT * FROM envelopes ORDER BY sequence) t",
              "SELECT row_to_json(t) FROM (SELECT * FROM room_state ORDER BY id) t"]
    for probe in probes:
        if sql(root, probe) != sql(root, probe, restored):
            raise RuntimeError('restore differs; release not switched')
    # Keep verification DB for evidence; no automatic destructive cleanup.
    (destination / 'manifest.json').write_text(json.dumps({
        'sha256': digest(dump), 'bytes': dump.stat().st_size,
        'restore_database': restored, 'verified': True,
        'pg_version': command([PG / 'pg_dump', '--version']).decode().strip()}))
    return destination


def switch(root, release):
    # Validate candidate/destination before even creating a lock or backup.
    _, new = candidate(root, release)
    previous = current_release(root)
    if verify(previous)['sha256']['schema.sql'] != new['sha256']['schema.sql']:
        raise ValueError('schema change requires separately reviewed migration')
    with lock(root):
        with database(root):
            backup(root)
        target = stage(root, release)
        point(root, target)


def unit(root):
    config(root)
    current_release(root)
    return f'''[Unit]
Description=ParanoID isolated private test-data alpha
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 {root}/current/alpha.py run --root {root}
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStopSec=60
UMask=0077
NoNewPrivileges=yes
LimitCORE=0
LimitNOFILE=1024
TasksMax=128
MemoryMax=512M
CPUQuota=100%
StandardOutput=null
StandardError=journal

[Install]
WantedBy=default.target
'''


def service_name(name):
    if not re.fullmatch(r'paranoid-alpha(?:-[a-z0-9-]+)?\.service', name):
        raise ValueError('dedicated alpha unit name required')
    return name


def wait_health(root):
    for _ in range(100):
        try:
            health(root)
            return
        except (OSError, ValueError, TypeError, RuntimeError):
            time.sleep(.2)
    raise RuntimeError('TLS/database readiness failed')


def install(root, ip, release, name='paranoid-alpha.service'):
    root_path(root)
    canonical_ipv4(ip)
    if os.path.lexists(root):
        raise FileExistsError('refuse existing installation root')
    verify(release)
    name = service_name(name)
    load = command(['systemctl', '--user', 'show', name, '-p', 'LoadState', '--value']).strip()
    if load != b'not-found':
        raise ValueError('refuse existing unit')
    verify(release)
    initialize(root, ip)
    with lock(root):
        point(root, stage(root, release))
    unit_path = root / name
    unit_path.write_text(unit(root))
    command(['systemd-analyze', '--user', 'verify', unit_path])
    command(['systemctl', '--user', 'enable', '--now', unit_path])
    wait_health(root)


def update(root, release, name='paranoid-alpha.service'):
    _, new = candidate(root, release)
    previous = current_release(root)
    if verify(previous)['sha256']['schema.sql'] != new['sha256']['schema.sql']:
        raise ValueError('schema change requires separately reviewed migration')
    name = service_name(name)
    actual = command(['systemctl', '--user', 'show', name, '-p', 'FragmentPath', '--value']).decode().strip()
    if not actual or Path(actual).resolve() != root / name:
        raise ValueError('unit does not belong to this installation')
    command(['systemctl', '--user', 'stop', name])
    try:
        switch(root, release)
        command(['systemctl', '--user', 'start', name])
        wait_health(root)
    except Exception:  # noqa: BLE001 - any failed update must attempt safe code rollback
        command(['systemctl', '--user', 'stop', name])
        with lock(root):
            point(root, previous)
        command(['systemctl', '--user', 'start', name])
        wait_health(root)
        raise RuntimeError('update failed; previous release restarted, history retained') from None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'update', 'init', 'stage', 'run', 'health', 'backup', 'switch', 'unit'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--ip')
    parser.add_argument('--unit-name', default='paranoid-alpha.service')
    parser.add_argument('--release', type=Path)
    args = parser.parse_args()
    root = args.root.absolute()
    if args.action == 'install':
        install(root, args.ip, args.release.absolute(), args.unit_name)
        print('PASS: isolated unit enabled and TLS/database ready')
    elif args.action == 'update':
        update(root, args.release.absolute(), args.unit_name)
        print('PASS: same-schema update/rollback, verified backup, TLS/database ready')
    elif args.action == 'init':
        initialize(root, args.ip)
    elif args.action == 'stage':
        candidate(root, args.release.absolute())
        if os.path.lexists(root / 'current'):
            raise ValueError('use switch for an existing installation')
        with lock(root):
            point(root, stage(root, args.release.absolute()))
    elif args.action == 'run':
        run(root)
    elif args.action == 'health':
        health(root)
        print('PASS: TLS authenticated database readiness')
    elif args.action == 'backup':
        config(root)
        current_release(root)
        with lock(root), database(root):
            backup(root)
        print('PASS: backup restored and compared in isolated database')
    elif args.action == 'switch':
        switch(root, args.release.absolute())
        print('PASS: verified backup and same-schema release switch; start and health-check unit')
    elif args.action == 'unit':
        config(root)
        print(unit(root), end='')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:  # noqa: BLE001 - redact all driver/config errors at the CLI boundary
        # Child/DB/config exceptions may contain secrets; never print raw errors.
        raise SystemExit('Alpha operation failed; no automatic data deletion. Check private configuration and service state.')
