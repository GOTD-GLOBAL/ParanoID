#!/usr/bin/env python3
"""Isolated alpha lifecycle; replace-v2 explicitly discards only the old server data cluster."""
import argparse
import contextlib
import fcntl
import functools
import hashlib
import ipaddress
import json
import os
import re
import secrets
import selectors
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import time
import tempfile
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
    initialize_data(root)


def initialize_data(root):
    root_path(root)
    private(root)
    if not stat.S_ISDIR(root.lstat().st_mode) or os.path.lexists(root / 'data'):
        raise FileExistsError('fresh data directory required; never adopt existing storage')
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
    if (not isinstance(c, dict) or set(c) not in ({'ip', 'alice', 'bob'},
            {'ip', 'alice', 'bob', 'deployment'}, {'ip', 'alice', 'bob', 'deployment', 'voice_turn'},
            {'ip', 'alice', 'bob', 'deployment', 'push'}, {'ip', 'alice', 'bob', 'deployment', 'voice_turn', 'push'})
            or ('deployment' in c and c['deployment'] not in ('key-v1', 'self-service-v2'))):
        raise ValueError('exact configuration keys required')
    canonical_ipv4(c['ip'])
    turn_settings(c)
    push_settings(c)
    for name in ('alice', 'bob'):
        if not isinstance(c[name], str) or not re.fullmatch(r'[0-9a-fA-F]{64}', c[name]):
            raise ValueError('256-bit hex admission tokens required')
    if c['alice'].lower() == c['bob'].lower():
        raise ValueError('distinct admission tokens required')
    return c


def turn_settings(c):
    settings = c.get('voice_turn')
    if 'voice_turn' not in c:
        return None
    if (c.get('deployment') != 'self-service-v2' or not isinstance(settings, dict)
            or set(settings) != {'v', 'relay_ip'} or type(settings['v']) is not int
            or settings['v'] != 1 or settings['relay_ip'] != c['ip']):
        raise ValueError('exact v2 TURN configuration required')
    reviewed_v2_ip(settings['relay_ip'], settings['relay_ip'])
    return settings


def turn_environment(c):
    settings = turn_settings(c)
    if settings is None:
        return {}
    directory = os.environ.get('CREDENTIALS_DIRECTORY', '')
    if (not re.fullmatch(r'/[A-Za-z0-9_./-]+', directory)
            or '..' in Path(directory).parts or str(Path(directory)) != directory):
        raise ValueError('explicit systemd credential directory required')
    path = Path(directory) / 'voice-turn-secret'
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid not in (0, os.geteuid())
                or stat.S_IMODE(meta.st_mode) not in (0o400, 0o600)
                or not re.fullmatch(b'[0-9a-f]{64}', stream.read(65))):
            raise ValueError('private exact TURN credential required')
    return {'PARANOID_TURN_SECRET_FILE': str(path), 'PARANOID_TURN_RELAY_IP': settings['relay_ip']}


def push_settings(c):
    # RFC-0020: like voice_turn, the gateway is enabled by an exact config key that the
    # journaled update flips together with the unit, never by a file appearing on disk.
    settings = c.get('push')
    if 'push' not in c:
        return None
    if c.get('deployment') != 'self-service-v2' or settings != {'v': 1, 'provider': 'fcm'}:
        raise ValueError('exact v2 push configuration required')
    return settings


def push_environment(root, c):
    # The FCM service-account JSON reaches the process only as a systemd credential.
    if push_settings(c) is None:
        return {}
    directory = os.environ.get('CREDENTIALS_DIRECTORY', '')
    if (not re.fullmatch(r'/[A-Za-z0-9_./-]+', directory)
            or '..' in Path(directory).parts or str(Path(directory)) != directory):
        raise ValueError('explicit systemd credential directory required')
    path = Path(directory) / 'push-fcm-credential'
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        raw = stream.read(65537)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid not in (0, os.geteuid())
                or stat.S_IMODE(meta.st_mode) not in (0o400, 0o600)
                or len(raw) > 65536):
            raise ValueError('private push credential required')
        try:
            c = json.loads(raw, object_pairs_hook=unique_object)
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError('private push credential required') from error
        if (not isinstance(c, dict) or c.get('type') != 'service_account'
                or not isinstance(c.get('private_key'), str) or not isinstance(c.get('client_email'), str)
                or c.get('token_uri') != 'https://oauth2.googleapis.com/token'):
            raise ValueError('private push credential required')
    return {'PARANOID_PUSH_CREDENTIAL_FILE': str(path)}


def sql(root, query, database='postgres'):
    return command([PG / 'psql', '-X', '-h', root / 'socket', '-U', 'paranoid_alpha',
                    '-d', database, '-v', 'ON_ERROR_STOP=1', '-Atc', query])


@contextlib.contextmanager
def database(root):
    config(root)
    current_release(root)
    if os.path.lexists(root / 'data/postmaster.pid'):
        raise RuntimeError('existing or stale postmaster state; refuse adoption')
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


def require_capability(root, manifest, release):
    if config(root).get('deployment') == 'self-service-v2':
        v2_capability(manifest, release)
        if manifest.get('voice_turn_controller') is not None:
            voice_turn_capability(release)
        if (turn_settings(config(root)) is not None
                and manifest.get('voice_turn_controller') != 'self-service-v2-turn-file-v1'):
            raise ValueError('TURN-enabled config requires versioned controller package')
    if config(root).get('deployment') == 'key-v1':
        key_capability(manifest)
        runtime_capability(release)


def voice_turn_capability(release):
    server = command([release / 'paranoid-server', 'voice-turn-capabilities'], timeout=10)
    controller = command(['python3', release / 'alpha.py', 'voice-turn-capabilities'], timeout=10)
    if (json.loads(server, object_pairs_hook=unique_object) != {'api': 1, 'issuer': 'signed-session-turn-v1'}
            or json.loads(controller, object_pairs_hook=unique_object) != TURN_CONTROLLER_CAPABILITY):
        raise ValueError('matching TURN server and controller capabilities required')


def environment(root):
    c = config(root)
    require_capability(root, verify(current_release(root)), current_release(root))
    env = clean_env()
    env.update(PARANOID_MODE='closed-alpha-v0', PARANOID_BIND=f"{c['ip']}:38443",
               PARANOID_TLS_CERT=str(root / 'tls/server.crt'),
               PARANOID_TLS_KEY=str(root / 'tls/server.key'),
               PARANOID_ALICE_TOKEN=c['alice'], PARANOID_BOB_TOKEN=c['bob'],
               PARANOID_DATABASE_URL=f'postgresql://paranoid_alpha@localhost/postgres?host={root}/socket')
    if c.get('deployment') == 'key-v1':
        env.update(PARANOID_MODE='closed-alpha-key-v1', PARANOID_REVIEWED_KEY_IP=c['ip'])
    if c.get('deployment') == 'self-service-v2':
        reviewed_v2_ip(c['ip'], c['ip'])
        env.update(PARANOID_MODE='self-service-v2', PARANOID_REVIEWED_SELF_SERVICE_IP=c['ip'])
        env['PARANOID_ANDROID_UPDATE_ROOT'] = str(root / 'updates')
        env.pop('PARANOID_ALICE_TOKEN')
        env.pop('PARANOID_BOB_TOKEN')
        env.update(turn_environment(c))
        env.update(push_environment(root, c))
    return env


def health(root):
    c = config(root)
    context = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    key_mode = c.get('deployment') in ('key-v1', 'self-service-v2')
    if c.get('deployment') == 'self-service-v2':
        require_capability(root, verify(current_release(root)), current_release(root))
        v2_readiness(root)
        req = urllib.request.Request(f"https://{c['ip']}:38443/health")
    elif key_mode:
        require_capability(root, verify(current_release(root)), current_release(root))
        realm, pin = public_realm(root)
        if sql(root, 'SELECT version,realm,pin FROM key_meta ORDER BY id').strip() != f'1|{realm}|{pin}'.encode():
            raise ValueError('key metadata readiness mismatch')
        if sql(root, 'SELECT count(*) FROM room_state WHERE id=1').strip() != b'1':
            raise ValueError('room readiness mismatch')
        req = urllib.request.Request(f"https://{c['ip']}:38443/health")
    else:
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
    if (key_mode and result.get('status') != 'ok') or (not key_mode and not isinstance(result.get('messages'), list)):
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
    with regular_file(release / 'manifest.json') as stream:
        manifest = json.load(stream, object_pairs_hook=unique_object)
    if not isinstance(manifest, dict):
        raise ValueError('invalid release manifest')  # noqa: TRY004 - uniform invalid-input contract
    if manifest.get('schema_contract') in ('paranoid-key-v1', 'paranoid-self-service-v2'):
        if manifest.get('deployment_api') != 1:
            raise ValueError('unsupported deployment capability')
        files += ('key-schema.sql',)
        if manifest['schema_contract'] == 'paranoid-self-service-v2':
            files += ('self-service-schema.sql',)
            capability = manifest.get('voice_turn_controller')
            if capability is not None:
                if capability != 'self-service-v2-turn-file-v1':
                    raise ValueError('unsupported TURN controller capability')
                files += ('voice-turn-controller.json',)
    elif manifest.get('deployment_api') is not None:
        raise ValueError('unsupported deployment capability')
    if {p.name for p in release.iterdir()} != {*files, 'manifest.json'}:
        raise ValueError('unexpected release members')
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
    require_capability(root, manifest, release)
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
    require_capability(root, verify(target), target)
    temporary = root / 'next'
    temporary.symlink_to(target)
    temporary.replace(root / 'current')


def backup(root):
    """Caller holds lifecycle lock with server stopped and private PG running."""
    if config(root).get('deployment') == 'self-service-v2':
        raise ValueError('v2 backup/update/restore is outside this fresh-only controller')
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
    tables = [('envelopes', 'sequence'), ('room_state', 'id')]
    if sql(root, "SELECT to_regclass('public.key_meta') IS NOT NULL").strip() == b't':
        tables += [('key_meta', 'id'), ('key_grants', 'slot')]
    for table, order in tables:
        probe = f"SELECT row_to_json(t) FROM (SELECT * FROM {table} ORDER BY {order}) t"
        if sql(root, probe) != sql(root, probe, restored):
            raise RuntimeError('restore differs; release not switched')
    identity = destination / 'identity'
    (identity / 'tls').mkdir(parents=True, mode=0o700)
    identity.chmod(0o700)
    identity_hashes = {}
    for name in ('config.json', 'tls/server.key', 'tls/server.crt'):
        with regular_file(root / name, restricted=True) as source, \
                regular_file(identity / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as out:
            os.write(out.fileno(), source.read())
            os.fsync(out.fileno())
        if digest(root / name) != digest(identity / name):
            raise RuntimeError('identity backup comparison failed')
        identity_hashes[name] = digest(identity / name)
    # Keep verification DB for evidence; no automatic destructive cleanup.
    (destination / 'manifest.json').write_text(json.dumps({
        'tables': [name for name, _ in tables], 'identity_sha256': identity_hashes,
        'sha256': digest(dump), 'bytes': dump.stat().st_size,
        'restore_database': restored, 'verified': True,
        'pg_version': command([PG / 'pg_dump', '--version']).decode().strip()}))
    return destination


V0_SCHEMA = '28035059271b03fe7f05f012effb16087c326381d23eb1ac5542e2935b1bb23a'
KEY_SCHEMA = 'f50a37b3b91bdd7b5d74114be58600cae86293881b12cf88909b36d33cb65ee9'


def key_capability(manifest):
    if (manifest.get('schema_contract') != 'paranoid-key-v1'
            or manifest.get('deployment_api') != 1
            or manifest['sha256'].get('schema.sql') != V0_SCHEMA
            or manifest['sha256'].get('key-schema.sql') != KEY_SCHEMA):
        raise ValueError('exact reviewed key migration capability required')


def runtime_capability(release):
    expected = {'deployment_api': 1, 'runtime': 'key-v1-local-lock-close-v1',
                'schema': V0_SCHEMA, 'key_schema': KEY_SCHEMA}
    try:
        output = command([release / 'paranoid-server', 'deployment-capabilities'], timeout=10)
        if json.loads(output, object_pairs_hook=unique_object) != expected:
            raise ValueError('incompatible runtime capability')
        controller = command(['python3', release / 'alpha.py', 'deployment-capabilities'], timeout=10)
        if json.loads(controller, object_pairs_hook=unique_object) != {'deployment_api': 1, 'controller': 'key-v1-sticky-offline-v1'}:
            raise ValueError('incompatible controller capability')
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise ValueError('incompatible runtime capability') from error


V2_SCHEMA = 'ff401a462710aa8433db65a72b723460cd2be966805ded61bae6c145dd970d10'
TURN_CONTROLLER_CAPABILITY = {'deployment_api': 1, 'controller': 'self-service-v2-turn-file-v1',
                             'config': {'voice_turn': {'v': 1, 'relay_ip': 'same-config-ip'}},
                             'credential': 'LoadCredential:voice-turn-secret'}
REVIEWED_V2_IP = '157.180.49.125'


def reviewed_v2_ip(ip, reviewed):
    canonical_ipv4(ip)
    if ip != reviewed or (ip != REVIEWED_V2_IP and not ipaddress.IPv4Address(ip).is_loopback):
        raise ValueError('exact reviewed self-service IPv4 required')


def v2_capability(manifest, release):
    if (manifest.get('schema_contract') != 'paranoid-self-service-v2'
            or manifest.get('deployment_api') != 1
            or manifest['sha256'].get('schema.sql') != V0_SCHEMA
            or manifest['sha256'].get('key-schema.sql') != KEY_SCHEMA
            or manifest['sha256'].get('self-service-schema.sql') != V2_SCHEMA):
        raise ValueError('exact fresh self-service package required')
    expected = {'deployment_api': 1, 'runtime': 'self-service-v2-exact-ip-v1', 'self_service_schema': V2_SCHEMA}
    output = command([release / 'paranoid-server', 'self-service-capabilities'], timeout=10)
    if json.loads(output, object_pairs_hook=unique_object) != expected:
        raise ValueError('incompatible self-service runtime')
    output = command(['python3', release / 'alpha.py', 'self-service-capabilities'], timeout=10)
    if json.loads(output, object_pairs_hook=unique_object) != {'deployment_api': 1, 'controller': 'self-service-v2-fresh-v1'}:
        raise ValueError('incompatible self-service controller')


def v2_readiness(root):
    realm, pin = public_realm(root)
    if sql(root, 'SELECT version,realm,pin FROM ss_meta ORDER BY id').strip() != f'2|{realm}|{pin}'.encode():
        raise ValueError('self-service metadata readiness mismatch')
    # Resolve all routing/storage columns even on an empty fresh database.
    sql(root, 'SELECT account,root,mode FROM ss_accounts LIMIT 0; '
              'SELECT account,device,auth,fingerprint,credential FROM ss_devices LIMIT 0; '
              'SELECT first_account,second_account FROM ss_conversations LIMIT 0; '
              'SELECT sequence,sender,recipient,message_id,ciphertext,first_account,second_account FROM ss_messages LIMIT 0; '
              'SELECT sequence,registration_window,registrations FROM ss_meta LIMIT 0')
    if sql(root, "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.room_state'::regclass AND tgname='key_schema_startup_guard' AND tgenabled='O')").strip() != b't':
        raise ValueError('self-service downgrade marker missing')


def v2_operation(operation):
    @functools.wraps(operation)
    def wrapped(*args, **kwargs):
        try:
            return operation(*args, **kwargs)
        except KeyboardInterrupt:
            # No raw exception/config data, rollback, retry or service activation.
            print('Fresh v2 operation interrupted; completion unconfirmed. '
                  'Keep the dedicated unit stopped and verify service state. '
                  'Old server data may already be discarded; no automatic rollback.', file=sys.stderr)
            raise SystemExit(130) from None
    return wrapped


@v2_operation
def fresh_v2(root, release, ip):
    """Offline EMPTY database only. Never drops, imports, backs up or restarts."""
    c = config(root)
    reviewed_v2_ip(c['ip'], ip)
    manifest = verify(release)
    v2_capability(manifest, release)
    target = root / 'releases' / manifest['release']
    if os.path.lexists(target):
        confined_release(root, target)
        if verify(target) != manifest:
            raise ValueError('release id collision')
    with regular_file(root / 'operation.lock', os.O_RDWR | os.O_CREAT, restricted=True) as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with lock(root):
            initialize_v2_locked(root, release, target, c)


def initialize_v2_locked(root, release, target, c):
    with database(root):
        # Never route legacy data into the migration helper; this is fresh-only.
        if sql(root, "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'").strip() != b'0':
            raise ValueError('fresh-v2 requires an empty database; no migration or deletion')
        realm, pin = public_realm(root)
        if not target.exists():
            shutil.copytree(release, target)
            target.chmod(0o700)
        confined_release(root, target)
        atomic_config(root, {**c, 'deployment': 'self-service-v2'})
        env = clean_env()
        env.update(PARANOID_DATABASE_URL=f'postgresql://paranoid_alpha@localhost/postgres?host={root}/socket',
                   PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin)
        subprocess.run([str(target / 'paranoid-server'), 'self-service-init'],
                       env=env, capture_output=True, check=True, timeout=30)
        v2_readiness(root)
        point(root, target)


def cluster_identifier(root):
    with regular_file(root / 'data/PG_VERSION', restricted=True) as stream:
        if stream.read().strip() != b'16':
            raise ValueError('PG16 cluster required')
    output = subprocess.check_output([str(PG / 'pg_controldata'), str(root / 'data')],
                                     env={**clean_env(), 'LC_ALL': 'C'}, stderr=subprocess.DEVNULL).decode()
    identifier = re.search(r'^Database system identifier:\s+(\d+)$', output, re.MULTILINE)
    if not identifier:
        raise ValueError('cluster identity unavailable')
    return identifier.group(1)


def validate_discard_tree(root):
    """Fail closed on redirection, hard links and mounts before removing data only."""
    installation(root)
    data = root / 'data'
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('fd-based no-follow removal required')
    with Path('/proc/self/mountinfo').open() as mounts:
        for line in mounts:
            mount = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), line.split()[4])
            if Path(mount) == data or data in Path(mount).parents:
                raise ValueError('mount inside discard boundary')
    device = root.stat().st_dev
    for directory, dirs, files in os.walk(data, followlinks=False):
        for path in (Path(directory), *(Path(directory) / n for n in dirs + files)):
            info = path.lstat()
            if (info.st_uid != os.geteuid() or info.st_dev != device
                    or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))
                    or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)):
                raise ValueError('same-owner regular no-follow unmounted data tree required')


@v2_operation
def replace_v2(root, release, ip, expected_identifier, discard):
    """Explicit one-shot stopped SERVER CLUSTER discard, not a migration/backup."""
    c = config(root)
    reviewed_v2_ip(c['ip'], ip)
    if not discard or c.get('deployment') != 'key-v1':
        raise ValueError('explicit discard of existing key-v1 server cluster required')
    if ip == REVIEWED_V2_IP and root != Path('/home/paranoid/paranoid-alpha'):
        raise ValueError('reviewed hosted root required')
    manifest = verify(release)
    v2_capability(manifest, release)
    target = root / 'releases' / manifest['release']
    if os.path.lexists(target):
        confined_release(root, target)
        if verify(target) != manifest:
            raise ValueError('release id collision')
    if not isinstance(expected_identifier, str) or not re.fullmatch(r'[0-9]{1,20}', expected_identifier):
        raise ValueError('explicit inventoried PG system identifier required')
    # Validate existing certificate/key/SAN/expiry before irreversible state change.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'tls/server.crt', root / 'tls/server.key')
    command(['openssl', 'verify', '-CAfile', root / 'tls/server.crt', '-verify_ip', ip, root / 'tls/server.crt'])
    if ip == REVIEWED_V2_IP and public_realm(root)[1] != '8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba':
        raise ValueError('saved hosted TLS pin differs from reviewed trust')
    with regular_file(root / 'operation.lock', os.O_RDWR | os.O_CREAT, restricted=True) as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with lock(root):
            if os.path.lexists(root / 'data/postmaster.pid'):
                raise RuntimeError('running or stale PG state; refuse discard')
            with regular_file(root / 'socket/paranoid-key-worker.lock', os.O_RDWR | os.O_CREAT, restricted=True) as worker:
                fcntl.flock(worker, fcntl.LOCK_EX | fcntl.LOCK_NB)
                validate_discard_tree(root)
                if cluster_identifier(root) != expected_identifier:
                    raise ValueError('cluster identity differs from explicit inventory')
                status = subprocess.run([str(PG / 'pg_ctl'), 'status', '-D', str(root / 'data')],
                                        env=clean_env(), capture_output=True, check=False)
                if status.returncode != 3:
                    raise RuntimeError('PG not confirmed stopped')
                if not target.exists():
                    shutil.copytree(release, target)
                    target.chmod(0o700)
                confined_release(root, target)
                # Sticky v2 BEFORE destruction: old controllers cannot initialize
                # a new legacy DB after failure. No repeat discard once this lands.
                atomic_config(root, {**c, 'deployment': 'self-service-v2'})
                validate_discard_tree(root)
                shutil.rmtree(root / 'data')
                initialize_data(root)
            initialize_v2_locked(root, release, target, config(root))


def atomic_config(root, value):
    # Exclusive temporary file; crashes leave evidence and fail closed, not overwrite.
    temporary = root / 'config.pending'
    with regular_file(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as stream:
        os.write(stream.fileno(), json.dumps(value).encode())
        os.fsync(stream.fileno())
    temporary.replace(root / 'config.json')
    fd = os.open(root, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def public_realm(root):
    c = config(root)
    pem = command(['openssl', 'x509', '-in', root / 'tls/server.crt', '-pubkey', '-noout'])
    der = command(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=pem)
    return f"https://{c['ip']}:38443", hashlib.sha256(der).hexdigest()


def schema_snapshot(root, database):
    output = command([PG / 'pg_dump', '-h', root / 'socket', '-U', 'paranoid_alpha',
                      '-d', database, '--schema-only', '--no-owner', '--no-privileges'])
    # PG security restrict keys are random per dump, not schema content.
    return b'\n'.join(line for line in output.splitlines()
                      if not line.startswith((b'\\restrict ', b'\\unrestrict ')))


def verify_database_schema(root, release, key_mode):
    reference = 'schema_' + secrets.token_hex(8)
    sql(root, 'CREATE DATABASE ' + reference)
    with regular_file(release / 'schema.sql') as source:
        sql(root, source.read().decode(), reference)
    if key_mode:
        with regular_file(release / 'key-schema.sql') as source:
            sql(root, source.read().decode(), reference)
    if schema_snapshot(root, 'postgres') != schema_snapshot(root, reference):
        raise ValueError('actual schema differs from exact reviewed transition')


def serialized(operation):
    @functools.wraps(operation)
    def wrapped(root, release, *args, **kwargs):
        if config(root).get('deployment') == 'self-service-v2':
            raise ValueError('v2 legacy migration/update/switch is outside this fresh-only controller')
        candidate(root, release)  # Invalid input still causes no lifecycle writes.
        with regular_file(root / 'operation.lock', os.O_RDWR | os.O_CREAT, restricted=True) as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return operation(root, release, *args, **kwargs)
    return wrapped


@serialized
def migrate_key(root, release):
    """Explicit OFFLINE one-way transition; failure never restarts old code."""
    _, manifest = candidate(root, release)
    key_capability(manifest)
    runtime_capability(release)
    if verify(current_release(root))['sha256']['schema.sql'] != V0_SCHEMA:
        raise ValueError('unknown source schema')
    with lock(root), database(root):
        c = config(root)
        realm, pin = public_realm(root)
        present = sql(root, "SELECT to_regclass('public.key_meta') IS NOT NULL").strip() == b't'
        verify_database_schema(root, release, present)
        if present:
            if c.get('deployment') != 'key-v1':
                raise ValueError('key database without sticky configuration')
            expected = f'1|{realm}|{pin}'.encode()
            if sql(root, 'SELECT version,realm,pin FROM key_meta ORDER BY id').strip() != expected:
                raise ValueError('key metadata mismatch')
        backup(root)
        target = stage(root, release)
        if not present:
            # Capture initialization env before sticky config blocks the old release.
            env = clean_env()
            env.update(PARANOID_DATABASE_URL=f'postgresql://paranoid_alpha@localhost/postgres?host={root}/socket',
                       PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin)
            if c.get('deployment') != 'key-v1':
                atomic_config(root, {**c, 'deployment': 'key-v1'})
            subprocess.run([str(target / 'paranoid-server'), 'key-admin-init'],
                           env=env, capture_output=True, check=True, timeout=30)
        point(root, target)


@serialized
def switch(root, release):
    return switch_offline(root, release)


def switch_offline(root, release):
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
    c = config(root)
    current_release(root)
    credential = (f'LoadCredential=voice-turn-secret:{root}/voice-turn/issuer.secret\n'
                  if turn_settings(c) is not None else '')
    if push_settings(c) is not None:
        credential += f'LoadCredential=push-fcm-credential:{root}/push/fcm-service-account.json\n'
    return f'''[Unit]
Description=ParanoID isolated private test-data alpha
StartLimitIntervalSec=0

[Service]
Type=simple
{credential}ExecStart=/usr/bin/python3 {root}/current/alpha.py run --root {root}
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
        except (OSError, ValueError, TypeError, RuntimeError, subprocess.CalledProcessError):
            time.sleep(.2)
    raise RuntimeError('TLS/database readiness failed')


@v2_operation
def install_v2(root, ip, release, name='paranoid-alpha.service'):
    reviewed_v2_ip(ip, ip)
    v2_capability(verify(release), release)
    install(root, ip, release, name, self_service_v2=True)


def install(root, ip, release, name='paranoid-alpha.service', self_service_v2=False):
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
    if self_service_v2:
        fresh_v2(root, release, ip)
    unit_path = root / name
    unit_path.write_text(unit(root))
    command(['systemd-analyze', '--user', 'verify', unit_path])
    command(['systemctl', '--user', 'enable', '--now', unit_path])
    wait_health(root)


@serialized
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
        switch_offline(root, release)
        command(['systemctl', '--user', 'start', name])
        wait_health(root)
    except Exception:  # noqa: BLE001 - any failed update must attempt safe code rollback
        command(['systemctl', '--user', 'stop', name])
        try:
            with lock(root):
                point(root, previous)
            command(['systemctl', '--user', 'start', name])
            wait_health(root)
        except Exception:  # noqa: BLE001 - unsafe recovery must remain stopped
            command(['systemctl', '--user', 'stop', name])
            raise RuntimeError('update and compatible rollback failed; stopped with data retained') from None
        raise RuntimeError('update failed; previous release restarted, history retained') from None


V2_BACKUP_MAGIC = b'PARANOID-V2-BACKUP\x00\x01'
V2_BACKUP_LIMIT = 512 * 1024 * 1024
V2_TABLES = {'room_state': 'id', 'ss_meta': 'id', 'ss_accounts': 'account',
             'ss_devices': 'account', 'ss_conversations': 'first_account,second_account',
             'ss_messages': 'sequence'}


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def point_v2(root, target):
    """Same-schema pointer only; fsync the directory after atomic rename (OR-M5)."""
    config(root)
    confined_release(root, target)
    v2_capability(verify(target), target)
    temporary = root / ('current-v2-' + secrets.token_hex(8) + '.pending')
    temporary.symlink_to(target)
    temporary.replace(root / 'current')
    fsync_directory(root)


def v2_backup_key(root, create=False):
    path = root / 'backup.key'
    if not os.path.lexists(path):
        if not create:
            return None
        with regular_file(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as out:
            os.write(out.fileno(), secrets.token_bytes(32))
            os.fsync(out.fileno())
        fsync_directory(root)
    with regular_file(path, restricted=True) as source:
        key = source.read(33)
    if len(key) != 32:
        raise ValueError('existing backup key invalid; never regenerate')
    return key


def v2_preflight(root, release, expected_identifier):
    # Import before stopping service, without imposing a new legacy runtime dependency.
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes  # noqa: F401
    if config(root).get('deployment') != 'self-service-v2':
        raise ValueError('existing self-service-v2 installation required')
    if (not isinstance(expected_identifier, str) or not re.fullmatch(r'[0-9]{1,20}', expected_identifier)
            or cluster_identifier(root) != expected_identifier):
        raise ValueError('expected private PostgreSQL identity mismatch')
    previous = current_release(root)
    v2_capability(verify(previous), previous)
    candidate(root, release)
    v2_backup_key(root)
    return previous


@contextlib.contextmanager
def v2_operation_lock(root):
    with regular_file(root / 'operation.lock', os.O_RDWR | os.O_CREAT, restricted=True) as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


# Optional RFC-0020 schema created by the enabled gateway, not a base-v2 migration.
# Keep identical to server/src/self_service_http.rs; tests check exact schema and
# preserved encrypted row verification. No production schema DDL is executed here.
PUSH_TABLE_SQL = "CREATE TABLE ss_push_tokens(account TEXT PRIMARY KEY REFERENCES ss_accounts(account),device TEXT NOT NULL REFERENCES ss_devices(device),platform TEXT NOT NULL CHECK(platform='fcm'),token TEXT NOT NULL CHECK(octet_length(token) BETWEEN 1 AND 4096),updated BIGINT NOT NULL CHECK(updated>0))"


def v2_tables(root, database='postgres'):
    tables = dict(V2_TABLES)
    if sql(root, "SELECT to_regclass('public.ss_push_tokens') IS NOT NULL", database).strip() == b't':
        tables['ss_push_tokens'] = 'account'
    return tables


def v2_schema_check(root):
    """Initialize only a new empty reference DB, never the application database."""
    reference = 'schema_v2_' + secrets.token_hex(8)
    sql(root, 'CREATE DATABASE ' + reference)
    realm, pin = public_realm(root)
    env = clean_env()
    env.update(PARANOID_DATABASE_URL=f'postgresql://paranoid_alpha@localhost/{reference}?host={root}/socket',
               PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin)
    subprocess.run([str(current_release(root) / 'paranoid-server'), 'self-service-init'],
                   env=env, capture_output=True, check=True, timeout=30)
    if 'ss_push_tokens' in v2_tables(root):
        # Only the disposable schema-reference DB gains the exact known optional
        # extension. Full schema comparison still rejects foreign tables/columns.
        sql(root, PUSH_TABLE_SQL, reference)
    if schema_snapshot(root, 'postgres') != schema_snapshot(root, reference):
        raise ValueError('actual v2 schema differs from exact reviewed runtime')


def v2_rows(root, database='postgres'):
    # Ordered digest-of-SHA256-row-digests plus counts; no application rows leave PG.
    result = {}
    for table, order in v2_tables(root, database).items():
        query = ("SELECT count(*),encode(sha256(convert_to(coalesce(string_agg("
                 "encode(sha256(convert_to(row_to_json(t)::text,'UTF8')),'hex'),'' ORDER BY "
                 + order + "),''),'UTF8')),'hex') FROM " + table + " t")
        result[table] = sql(root, query, database).decode().strip()
    return result


def encrypt_v2_dump(root, path, context, key):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    aad = json.dumps(context, sort_keys=True, separators=(',', ':')).encode()
    nonce = secrets.token_bytes(12)
    encryptor = Cipher(algorithms.AES256(key), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(aad)
    process = subprocess.Popen([str(PG / 'pg_dump'), '-h', str(root / 'socket'), '-U',
                                'paranoid_alpha', '-d', 'postgres', '-Fc'], env=clean_env(),
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        with regular_file(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as out, selectors.DefaultSelector() as ready:
            os.write(out.fileno(), V2_BACKUP_MAGIC + len(aad).to_bytes(4, 'big') + aad + nonce)
            ready.register(process.stdout, selectors.EVENT_READ)
            size, deadline = 0, time.monotonic() + 180
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError('bounded backup deadline exceeded')
                if not ready.select(timeout=min(1, deadline - time.monotonic())):
                    continue
                block = os.read(process.stdout.fileno(), 65536)
                if not block:
                    break
                size += len(block)
                if size > V2_BACKUP_LIMIT:
                    raise ValueError('backup size limit')
                os.write(out.fileno(), encryptor.update(block))
            if process.wait(timeout=10) != 0:
                raise RuntimeError('database dump failed')
            os.write(out.fileno(), encryptor.finalize() + encryptor.tag)
            os.fsync(out.fileno())
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@contextlib.contextmanager
def decrypted_v2_dump(root, archive):
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    if archive.parent != root / 'backups' or not archive.name.startswith('v2-'):
        raise ValueError('confined v2 backup required')
    private(archive)
    if not stat.S_ISDIR(archive.lstat().st_mode):
        raise ValueError('real backup directory required')
    key = v2_backup_key(root)
    if key is None:
        raise ValueError('retained backup key unavailable')
    with regular_file(archive / 'history.enc', restricted=True) as source, \
            tempfile.TemporaryFile(dir=root / 'backups') as plain:
        size = os.fstat(source.fileno()).st_size
        if size > V2_BACKUP_LIMIT + 16384 or source.read(len(V2_BACKUP_MAGIC)) != V2_BACKUP_MAGIC:
            raise ValueError('invalid bounded encrypted backup')
        length = int.from_bytes(source.read(4), 'big')
        if not 1 <= length <= 8192:
            raise ValueError('invalid backup context')
        aad = source.read(length)
        context = json.loads(aad, object_pairs_hook=unique_object)
        realm, pin = public_realm(root)
        if (not isinstance(context, dict) or set(context) != {'format', 'release', 'pg_system_id', 'realm', 'pin', 'schema', 'created'}
                or context['format'] != 'paranoid-v2-backup-aes256gcm-v1'
                or context['schema'] != V2_SCHEMA or context['realm'] != realm or context['pin'] != pin
                or context['pg_system_id'] != cluster_identifier(root)
                or not isinstance(context['created'], int)
                or aad != json.dumps(context, sort_keys=True, separators=(',', ':')).encode()):
            raise ValueError('backup context mismatch')
        release_id(context['release'])
        nonce = source.read(12)
        remaining = size - source.tell() - 16
        if len(nonce) != 12 or remaining < 1:
            raise ValueError('truncated encrypted backup')
        position = source.tell()
        source.seek(-16, os.SEEK_END)
        tag = source.read(16)
        source.seek(position)
        decryptor = Cipher(algorithms.AES256(key), modes.GCM(nonce, tag)).decryptor()
        decryptor.authenticate_additional_data(aad)
        try:
            while remaining:
                block = source.read(min(65536, remaining))
                if not block:
                    raise ValueError('truncated encrypted backup')
                remaining -= len(block)
                plain.write(decryptor.update(block))
            plain.write(decryptor.finalize())
        except InvalidTag:
            raise ValueError('backup authentication failed') from None
        # Plaintext is never given to pg_restore before full GCM authentication.
        plain.flush()
        plain.seek(0)
        yield plain, context


def verify_v2_backup(root, archive):
    """Caller holds lifecycle lock; restore into a NEW DB, never live postgres."""
    with decrypted_v2_dump(root, archive) as (plain, context):
        restored = 'verify_v2_' + secrets.token_hex(8)
        sql(root, 'CREATE DATABASE ' + restored)
        command([PG / 'pg_restore', '-h', root / 'socket', '-U', 'paranoid_alpha',
                 '-d', restored, '--exit-on-error'], stdin=plain, timeout=180)
        expected = v2_rows(root)
        if (schema_snapshot(root, 'postgres') != schema_snapshot(root, restored)
                or expected != v2_rows(root, restored)):
            raise RuntimeError('restored v2 schema or rows differ; no release switch')
    return {**context, 'tables': list(expected), 'row_digests': expected,
            'restore_database': restored, 'verified': True,
            'sha256': digest(archive / 'history.enc'), 'bytes': (archive / 'history.enc').stat().st_size}


def backup_v2(root):
    """Offline DB-only encrypted backup; original TLS/config remain in place."""
    if config(root).get('deployment') != 'self-service-v2':
        raise ValueError('v2 backup requires v2 installation')
    v2_capability(verify(current_release(root)), current_release(root))
    v2_backup_key(root)  # Reject a redirected/invalid retained key before any backup.
    v2_readiness(root)
    v2_schema_check(root)
    key = v2_backup_key(root, create=True)
    realm, pin = public_realm(root)
    context = {'format': 'paranoid-v2-backup-aes256gcm-v1', 'release': verify(current_release(root))['release'],
               'pg_system_id': cluster_identifier(root), 'realm': realm, 'pin': pin,
               'schema': V2_SCHEMA, 'created': int(time.time())}
    destination = root / 'backups' / ('v2-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + secrets.token_hex(8))
    destination.mkdir(mode=0o700)
    encrypt_v2_dump(root, destination / 'history.enc', context, key)
    result = verify_v2_backup(root, destination)
    with regular_file(destination / 'manifest.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as out:
        os.write(out.fileno(), (json.dumps(result, indent=2) + '\n').encode())
        os.fsync(out.fileno())
    fsync_directory(destination)
    fsync_directory(root / 'backups')
    return destination


def switch_v2_locked(root, release, expected_identifier):
    v2_preflight(root, release, expected_identifier)
    identity = {name: digest(root / name) for name in ('config.json', 'tls/server.crt', 'tls/server.key')}
    with lock(root), database(root):
        backup_v2(root)
        target = stage(root, release)
        # A durable pointer must not outrun freshly copied code on power loss.
        for member in target.iterdir():
            with regular_file(member) as source:
                os.fsync(source.fileno())
        fsync_directory(target)
        fsync_directory(root / 'releases')
        if identity != {name: digest(root / name) for name in identity}:
            raise RuntimeError('identity/config changed; refuse cutover')
        if cluster_identifier(root) != expected_identifier:
            raise ValueError('private PostgreSQL identity changed')
        point_v2(root, target)


def switch_v2_offline(root, release, expected_identifier):
    v2_preflight(root, release, expected_identifier)
    with v2_operation_lock(root):
        switch_v2_locked(root, release, expected_identifier)


def v2_unit(root, name):
    name = service_name(name)
    output = command(['systemctl', '--user', 'show', name, '-p', 'FragmentPath',
                      '-p', 'ActiveState', '-p', 'UnitFileState']).decode()
    fields = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
    actual = fields.get('FragmentPath', '')
    if (not actual or Path(actual).resolve() != root / name
            or fields.get('ActiveState') != 'active' or fields.get('UnitFileState') != 'enabled'):
        raise ValueError('active enabled dedicated unit belonging to this root required')
    with regular_file(root / name, restricted=True) as source:
        if source.read() != unit(root).encode():
            raise ValueError('dedicated unit contents differ from reviewed service')


def update_v2(root, release, expected_identifier, name='paranoid-alpha.service'):
    previous = v2_preflight(root, release, expected_identifier)
    v2_unit(root, name)
    with v2_operation_lock(root):
        v2_preflight(root, release, expected_identifier)
        v2_unit(root, name)
        try:
            command(['systemctl', '--user', 'stop', name])
            switch_v2_locked(root, release, expected_identifier)
            command(['systemctl', '--user', 'start', name])
            wait_health(root)
        except BaseException as error:  # Interruptions must also retain data and return failure.
            try:
                command(['systemctl', '--user', 'stop', name])
                with lock(root):
                    v2_preflight(root, previous, expected_identifier)
                    point_v2(root, previous)
                command(['systemctl', '--user', 'start', name])
                wait_health(root)
            except BaseException:
                command(['systemctl', '--user', 'stop', name])
                raise RuntimeError('v2 update and same-data recovery failed; keep dedicated unit stopped') from None
            if isinstance(error, KeyboardInterrupt):
                raise
            raise RuntimeError('v2 update failed; previous release ready on retained current data') from None


def enable_push_v2(root, name='paranoid-alpha.service'):
    """RFC-0020: turn the FCM gateway on for an existing v2 installation on the current release.
    Requires the operator-placed credential; flips config + unit together under the operation lock,
    restarts the dedicated unit and restores the exact previous config/unit on any failure."""
    name = service_name(name)
    c = config(root)
    if c.get('deployment') != 'self-service-v2':
        raise ValueError('push requires an active self-service v2 installation')
    if push_settings(c) is not None:
        raise ValueError('push already enabled')
    credential = root / 'push/fcm-service-account.json'
    with regular_file(credential, restricted=True) as stream:
        meta = os.fstat(stream.fileno())
        raw = stream.read(65537)
        if meta.st_nlink != 1 or stat.S_IMODE(meta.st_mode) != 0o400 or len(raw) > 65536:
            raise ValueError('private 0400 push credential required')
        s = json.loads(raw, object_pairs_hook=unique_object)
        if (not isinstance(s, dict) or s.get('type') != 'service_account' or not isinstance(s.get('private_key'), str)
                or not isinstance(s.get('client_email'), str) or s.get('token_uri') != 'https://oauth2.googleapis.com/token'):
            raise ValueError('service-account credential required')
    release = current_release(root)
    with v2_operation_lock(root):
        v2_unit(root, name)
        old_config = (root / 'config.json').read_bytes()
        old_unit = (root / name).read_bytes()
        new_config = {**c, 'push': {'v': 1, 'provider': 'fcm'}}
        try:
            command(['systemctl', '--user', 'stop', name])
            atomic_config(root, new_config)
            config(root)
            unit_path = root / name
            unit_path.write_text(unit(root))
            command(['systemd-analyze', '--user', 'verify', unit_path])
            command(['systemctl', '--user', 'daemon-reload'])
            command(['systemctl', '--user', 'start', name])
            wait_health(root)
        except BaseException:
            try:
                command(['systemctl', '--user', 'stop', name])
                (root / 'config.pending').unlink(missing_ok=True)
                atomic_config_bytes(root, old_config)
                (root / name).write_bytes(old_unit)
                command(['systemctl', '--user', 'daemon-reload'])
                command(['systemctl', '--user', 'start', name])
                wait_health(root)
            except BaseException:
                command(['systemctl', '--user', 'stop', name])
                raise RuntimeError('push enable and recovery failed; keep dedicated unit stopped') from None
            raise RuntimeError('push enable failed; previous exact config/unit restored on retained data') from None
    return release


def atomic_config_bytes(root, data):
    temporary = root / 'config.pending'
    with regular_file(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, restricted=True) as stream:
        os.write(stream.fileno(), data)
        os.fsync(stream.fileno())
    temporary.replace(root / 'config.json')
    fsync_directory(root)


def safe_v2_cli(action, root, release, expected_identifier, name):
    def interrupted(*_):
        raise KeyboardInterrupt
    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    try:
        if action == 'update-v2':
            update_v2(root, release, expected_identifier, name)
        else:
            v2_preflight(root, current_release(root), expected_identifier)
            with v2_operation_lock(root), lock(root), database(root):
                backup_v2(root)
    except KeyboardInterrupt:
        print('V2 maintenance interrupted; completion unconfirmed. Data retained; verify dedicated service state.', file=sys.stderr)
        raise SystemExit(130) from None
    finally:
        signal.signal(signal.SIGTERM, previous_handler)


def main():
    os.umask(0o077)
    if sys.argv[1:] == ['self-service-capabilities']:
        print(json.dumps({'deployment_api': 1, 'controller': 'self-service-v2-fresh-v1'}))
        return
    if sys.argv[1:] == ['self-service-update-capabilities']:
        print(json.dumps({'deployment_api': 1, 'controller': 'self-service-v2-encrypted-same-data-v1', 'self_service_schema': V2_SCHEMA}))
        return
    if sys.argv[1:] == ['deployment-capabilities']:
        print(json.dumps({'deployment_api': 1, 'controller': 'key-v1-sticky-offline-v1'}))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'update', 'init', 'stage', 'run', 'health', 'backup', 'switch', 'unit', 'migrate-key', 'fresh-v2', 'install-v2', 'replace-v2', 'update-v2', 'backup-v2', 'enable-push-v2'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--ip')
    parser.add_argument('--expected-pg-system-id')
    parser.add_argument('--discard-server-database', action='store_true')
    parser.add_argument('--unit-name', default='paranoid-alpha.service')
    parser.add_argument('--release', type=Path)
    args = parser.parse_args()
    root = args.root.absolute()
    if args.action in ('update-v2', 'backup-v2'):
        safe_v2_cli(args.action, root, args.release.absolute() if args.release else None, args.expected_pg_system_id, args.unit_name)
        print('PASS: encrypted v2 restore verified; same-data lifecycle completed')
    elif args.action == 'install-v2':
        install_v2(root, args.ip, args.release.absolute(), args.unit_name)
        print('PASS: fresh self-service v2 unit enabled and TLS/database ready; no operator grants')
    elif args.action == 'install':
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
    elif args.action == 'replace-v2':
        replace_v2(root, args.release.absolute(), args.ip, args.expected_pg_system_id, args.discard_server_database)
        print('PASS: old SERVER cluster discarded without backup; fresh self-service v2 ready offline; start dedicated unit')
    elif args.action == 'fresh-v2':
        fresh_v2(root, args.release.absolute(), args.ip)
        print('PASS: empty database initialized for self-service v2; no operator grants or backup; start dedicated unit')
    elif args.action == 'migrate-key':
        migrate_key(root, args.release.absolute())
        print('PASS: verified offline key-v1 migration; start and health-check dedicated unit')
    elif args.action == 'switch':
        switch(root, args.release.absolute())
        print('PASS: verified backup and same-schema release switch; start and health-check unit')
    elif args.action == 'unit':
        config(root)
        print(unit(root), end='')
    elif args.action == 'enable-push-v2':
        enable_push_v2(root, args.unit_name)
        print('PASS: push gateway enabled on the current release; credential loaded by systemd only')


if __name__ == '__main__':
    if sys.argv[1:] == ['voice-turn-capabilities']:
        print(json.dumps(TURN_CONTROLLER_CAPABILITY))
        raise SystemExit(0)
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:  # noqa: BLE001 - redact all driver/config errors at the CLI boundary
        # Child/DB/config exceptions may contain secrets; never print raw errors.
        if sys.argv[1:2] == ['replace-v2']:
            raise SystemExit('Fresh replacement failed; remain stopped. Old server data may already be discarded; no automatic rollback.') from None
        raise SystemExit('Alpha operation failed; no automatic data deletion. Check private configuration and service state.')
