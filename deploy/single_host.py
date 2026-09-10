#!/usr/bin/env python3
"""REQ-DEPLOY-003: coordinated offline host kit; production acceptance is mandatory."""
import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
PRODUCTION = 'paranoid-single-host-v1'
FIXTURE = 'paranoid-single-host-fixture-v1'
VM_FIXTURE = 'paranoid-single-host-vm-fixture-v1'
PUBLIC_IP = '157.180.49.125'
# Availability stays closed until the exact full runner and artifacts are reviewed.
# The candidate verifier additionally rejects profile-name/hash-only PASS receipts.
FULL_REHEARSAL_PROFILES = frozenset()
STATE = Path('/var/lib/paranoid-single-host')
GATES = {
    FIXTURE: ('design-review', 'offline-tests', 'artifact-verification'),
    VM_FIXTURE: ('design-review', 'offline-tests', 'artifact-verification', 'current-boot-isolation'),
    # Owner decision 2026-09-10: the VM full-rehearsal programme is frozen.
    # Production binds the executed local loopback TURN acceptance instead;
    # the physical two-phone owner call is post-install product acceptance.
    PRODUCTION: ('design-review', 'offline-tests', 'artifact-verification',
                 'issuer-interoperability', 'turn-rt01', 'turn-acl02', 'relay-cli',
                 'relay-credentials-lifecycle', 'local-loopback-acceptance',
                 'final-review'),
}
IDENTITY = {'release', 'manifest_sha256', 'pg_system_id', 'config_sha256',
            'tls_cert_sha256', 'tls_key_sha256', 'tls_spki', 'unit_sha256'}
MAX_FILE = 128 * 1024 * 1024
BASE_FILES = {'single_host.py', 'single_host_message.py', 'README.md'}
RELAY_FILES = {'single_host_network.py', 'single_host_vm.py'}
VM_FILES = {'single_host_vm_runner.py', 'single_host_vm_packets.py'}


class FullRehearsalUnavailable(ValueError):
    """Fixed pre-mutation capability refusal; no transaction exists yet."""


def relay_profile(profile):
    return profile in (PRODUCTION, VM_FIXTURE)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def decode_json(data):
    return json.loads(data, object_pairs_hook=unique)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def is_hash(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def simple_path(value):
    if (not isinstance(value, str) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', value)
            or '..' in Path(value).parts or str(Path(value)) != value):
        raise ValueError('canonical absolute simple path required')
    return Path(value)


def trusted_directory(path, owner=None, private=False, allow_sticky=False):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('absolute directory required')
    allowed = {0, os.geteuid()} if owner is None else {0, owner}
    for parent in (*reversed(path.parents), path):
        meta = parent.lstat()
        sticky = meta.st_uid == 0 and bool(meta.st_mode & stat.S_ISVTX) and (parent != path or allow_sticky)
        if (not stat.S_ISDIR(meta.st_mode) or meta.st_uid not in allowed
                or (meta.st_mode & 0o022 and not sticky)):
            raise ValueError('trusted real directory required')
    meta = path.lstat()
    if private and (stat.S_IMODE(meta.st_mode) != 0o700 or meta.st_uid != (os.geteuid() if owner is None else owner)):
        raise ValueError('private owned directory required')
    return path


def read_file(path, limit=MAX_FILE, owner=None, private=False):
    path = Path(path)
    trusted_directory(path.parent, owner)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        allowed = {0, os.geteuid()} if owner is None else {owner}
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1 or meta.st_uid not in allowed
                or meta.st_mode & 0o022 or meta.st_size > limit
                or (private and stat.S_IMODE(meta.st_mode) not in (0o400, 0o600))):
            raise ValueError('trusted bounded single-link regular file required')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('file exceeds bound')
        return data


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, data, mode=0o600, exclusive=False):
    path = Path(path)
    trusted_directory(path.parent, os.geteuid())
    if os.path.lexists(path):
        if exclusive:
            raise FileExistsError('refuse existing destination')
        read_file(path, owner=os.geteuid())
    fd, temporary = tempfile.mkstemp(prefix='.single-host-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if exclusive:
            # link+unlink provides O_EXCL semantics even if a destination appeared.
            os.link(temporary, path, follow_symlinks=False)
            os.unlink(temporary)
        else:
            os.replace(temporary, path)
        fsync_dir(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def exclusive_lock(path):
    path = Path(path)
    trusted_directory(path.parent, os.geteuid(), private=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1 or meta.st_uid != os.geteuid()
                or stat.S_IMODE(meta.st_mode) != 0o600):
            raise ValueError('private owned lock required')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)  # Lock inode is never unlinked.


def validate_intent(value):
    if not isinstance(value, dict) or value.get('profile') not in GATES:
        raise ValueError('known profile required')
    fixture = value['profile'] == FIXTURE
    required = {'v', 'profile', 'mode', 'ip', 'kit_sha256', 'message', 'expected'}
    if not fixture:
        required |= {'interface', 'relay'}
    if set(value) != required or type(value['v']) is not int or value['v'] != 1:
        raise ValueError('exact v1 intent fields required')
    if value['mode'] not in ('fresh', 'existing-v8') or not is_hash(value['kit_sha256']):
        raise ValueError('explicit mode and kit digest required')
    ip = ipaddress.IPv4Address(value['ip'])
    if str(ip) != value['ip'] or (fixture and not ip.is_loopback) or (not fixture and str(ip) != PUBLIC_IP):
        raise ValueError('profile address boundary')
    message = value['message']
    if not isinstance(message, dict) or set(message) != {'user', 'uid', 'gid', 'root', 'unit'}:
        raise ValueError('exact messaging identity required')
    for field in ('uid', 'gid'):
        if type(message[field]) is not int or not 1 <= message[field] <= 2**31 - 1:
            raise ValueError('explicit non-root numeric identity required')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', message['user']):
        raise ValueError('safe account required')
    root = simple_path(message['root'])
    if fixture:
        if (not re.fullmatch(r'paranoid-fixture-[a-z0-9-]{8,64}', root.name)
                or not re.fullmatch(r'paranoid-alpha-fixture-[a-z0-9-]{8,64}\.service', message['unit'])
                or message['user'] in ('paranoid', 'paranoid-turn')):
            raise ValueError('distinct fixture paths and identity required')
    else:
        if (message['user'] != 'paranoid' or str(root) != '/home/paranoid/paranoid-alpha'
                or message['unit'] != 'paranoid-alpha.service'
                or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,14}', value['interface'])
                or (value['profile'] == VM_FIXTURE and value['interface'] != 'vr-relay')):
            raise ValueError('exact approved host layout required')
        relay = value['relay']
        if (not isinstance(relay, dict) or set(relay) != {'user', 'uid', 'gid'}
                or relay['user'] != 'paranoid-turn'
                or any(type(relay[f]) is not int or not 1 <= relay[f] <= 2**31 - 1 for f in ('uid', 'gid'))
                or relay['uid'] == message['uid'] or relay['gid'] == message['gid']):
            raise ValueError('distinct exact relay identity required')
    expected = value['expected']
    if value['mode'] == 'fresh':
        if expected is not None:
            raise ValueError('fresh mode does not adopt retained identity')
    else:
        if not isinstance(expected, dict) or set(expected) != IDENTITY:
            raise ValueError('complete retained identity required')
        if (not re.fullmatch(r'[0-9a-f]{20}', expected['release'])
                or not re.fullmatch(r'[0-9]{1,20}', expected['pg_system_id'])
                or any(not is_hash(expected[k]) for k in IDENTITY - {'release', 'pg_system_id'})):
            raise ValueError('invalid retained identity')
    return decode_json(canonical(value))


LOOPBACK_EVIDENCE_LIMIT = 1024 * 1024
LOOPBACK_BOUND_GATES = ('turn-rt01', 'turn-acl02')


def verify_loopback_acceptance(result, gates):
    """Owner-simplified gate (2026-09-10): bind an actually executed loopback
    TURN acceptance report covering TURN-RT01/TURN-ACL02. The report must be a
    real readable structured file whose digest matches the receipt; a bare hash
    or a failed/partial report cannot authorize production."""
    path = simple_path(result['evidence_path'])
    data = read_file(path, LOOPBACK_EVIDENCE_LIMIT)
    if sha(data) != result['evidence_sha256']:
        raise ValueError('loopback acceptance evidence must match its digest')
    report = decode_json(data)
    if not isinstance(report, dict):
        raise ValueError('structured loopback acceptance report required')
    binding = report.get('binding')
    cases = report.get('cases')
    if (report.get('overall') != 'PASS'
            or sorted(report.get('gates') or []) != ['TURN-ACL02', 'TURN-RT01']
            or 'loopback' not in str(report.get('scope', ''))
            or not isinstance(cases, list) or len(cases) < 6
            or any(not isinstance(case, dict) or case.get('result') != 'PASS'
                   or not case.get('name') or 'observed' not in case for case in cases)
            or not isinstance(binding, dict)
            or not is_hash(binding.get('turnserver_sha256') or '')
            or not re.fullmatch(r'[0-9a-f]{40}', binding.get('git_head') or '')):
        raise ValueError('complete executed loopback acceptance report required')
    for name in LOOPBACK_BOUND_GATES:
        if gates[name]['evidence_sha256'] != result['evidence_sha256']:
            raise ValueError('turn gates must reference the loopback acceptance evidence')


def validate_acceptance(value, profile, kit_sha256, plan_sha256, kit_root=None, intent=None):
    if (not isinstance(value, dict) or set(value) != {'v', 'profile', 'kit_sha256', 'plan_sha256', 'gates'}
            or type(value['v']) is not int or value['v'] != 1 or value['profile'] != profile
            or value['kit_sha256'] != kit_sha256 or not is_hash(plan_sha256)
            or value['plan_sha256'] != plan_sha256 or not isinstance(value['gates'], dict)
            or set(value['gates']) != set(GATES[profile])):
        raise ValueError('exact artifact-bound profile acceptance required')
    for name, result in value['gates'].items():
        required = {'result', 'evidence_sha256'}
        if name == 'local-loopback-acceptance':
            required.add('evidence_path')
        if name == 'current-boot-isolation':
            required.add('boot_id')
        if (not isinstance(result, dict) or set(result) != required or result['result'] != 'PASS'
                or not is_hash(result['evidence_sha256'])):
            raise ValueError('mandatory actual acceptance incomplete')
        if name == 'local-loopback-acceptance':
            verify_loopback_acceptance(result, value['gates'])
        if name == 'current-boot-isolation' and (not isinstance(result['boot_id'], str)
                or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', result['boot_id'])):
            raise ValueError('exact current guest boot required')
    return value


def build_directory(path):
    # Development source workspaces may have a same-owner group-writable ancestor.
    # This unprivileged BUILD input path is never used for installation/state.
    if os.geteuid() == 0:
        raise ValueError('builder source snapshot requires unprivileged account')
    for parent in (*Path(path).parents, Path(path)):
        meta = parent.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid not in (0, os.geteuid()):
            raise ValueError('real owned build source directory required')


def read_build_file(path, limit=MAX_FILE):
    path = Path(path)
    build_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid not in (0, os.geteuid()) or meta.st_size > limit):
            raise ValueError('bounded regular owned build input required')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('build input too large')
        return data


def component_id(hashes):
    return sha(json.dumps(hashes, sort_keys=True).encode())[:20]


def tree_files(root, building=False):
    (build_directory if building else trusted_directory)(root)
    names = []
    for path in sorted(Path(root).rglob('*')):
        meta = path.lstat()
        if stat.S_ISDIR(meta.st_mode):
            (build_directory if building else trusted_directory)(path)
        elif stat.S_ISREG(meta.st_mode):
            names.append(path.relative_to(root).as_posix())
        else:
            raise ValueError('regular package members only')
    if len(names) > 128:
        raise ValueError('package member bound')
    return names


def verify_component(root, building=False):
    root = Path(root)
    reader = read_build_file if building else read_file
    manifest = decode_json(reader(root / 'manifest.json', 256 * 1024))
    hashes = manifest.get('sha256') if isinstance(manifest, dict) else None
    if not isinstance(hashes, dict) or manifest.get('release') != component_id(hashes):
        raise ValueError('invalid component identity')
    if set(tree_files(root, building)) != {'manifest.json', *hashes}:
        raise ValueError('unexpected component membership')
    total = 0
    for name, expected in hashes.items():
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_./-]*', name)
                or '..' in Path(name).parts or not is_hash(expected)):
            raise ValueError('unsafe component member')
        data = reader(root / name)
        total += len(data)
        if total > 256 * 1024 * 1024 or sha(data) != expected:
            raise ValueError('component checksum or size mismatch')
    return manifest


def verify_kit(root):
    root = Path(root)
    manifest = decode_json(read_file(root / 'manifest.json', 256 * 1024))
    if (not isinstance(manifest, dict) or set(manifest) != {'v', 'profile', 'release', 'sha256', 'components'}
            or manifest['v'] != 1 or manifest['profile'] not in GATES
            or not isinstance(manifest['sha256'], dict)):
        raise ValueError('invalid coordinated kit manifest')
    hashes = manifest['sha256']
    if manifest['release'] != sha(canonical({'profile': manifest['profile'], 'sha256': hashes}))[:20]:
        raise ValueError('kit identity mismatch')
    production = relay_profile(manifest['profile'])
    components = {'message', 'relay'} if production else {'message'}
    if set(manifest['components']) != components:
        raise ValueError('profile component boundary')
    allowed = set(BASE_FILES)
    if production:
        allowed |= RELAY_FILES
    if manifest['profile'] == VM_FIXTURE:
        allowed |= VM_FILES
    for name in components:
        component = verify_component(root / name)
        if production and component.get('fixture_only'):
            raise ValueError('fixture component cannot enter production kit')
        expected = {'release': component['release'], 'manifest_sha256': sha(read_file(root / name / 'manifest.json'))}
        if manifest['components'][name] != expected:
            raise ValueError('component manifest binding differs')
        allowed |= {name + '/' + file for file in tree_files(root / name)}
    if set(hashes) != allowed or set(tree_files(root)) != allowed | {'manifest.json'}:
        raise ValueError('unknown or profile-forbidden kit member')
    for name, expected in hashes.items():
        if not is_hash(expected) or sha(read_file(root / name)) != expected:
            raise ValueError('kit member checksum differs')
    return manifest


def copy_tree(source, destination, public=False, building=False):
    source, destination = Path(source), Path(destination)
    names = tree_files(source, building)
    destination.mkdir(mode=0o755 if public else 0o700)
    for name in names:
        target = destination / name
        target.parent.mkdir(mode=0o755 if public else 0o700, parents=True, exist_ok=True)
        data = (read_build_file if building else read_file)(source / name)
        executable = (source / name).lstat().st_mode & 0o111
        mode = (0o755 if executable else 0o644) if public else (0o700 if executable else 0o600)
        atomic_write(target, data, mode, exclusive=True)
    for path in sorted((p for p in destination.rglob('*') if p.is_dir()), reverse=True):
        fsync_dir(path)
    fsync_dir(destination)


def build_kit(profile, message, relay, output, code_root=None):
    if profile not in GATES or relay_profile(profile) != (relay is not None):
        raise ValueError('exact profile component selection required')
    code_root = Path(__file__).resolve().parent if code_root is None else Path(code_root)
    output = Path(output)
    trusted_directory(output.parent)
    components = {'message': Path(message)}
    if relay is not None:
        components['relay'] = Path(relay)
    for source in components.values():
        verify_component(source, building=True)
    selected = set(BASE_FILES)
    if relay_profile(profile):
        selected |= RELAY_FILES
    if profile == VM_FIXTURE:
        selected |= VM_FILES
    sources = {name: read_build_file(code_root / ('single_host_README.md' if name == 'README.md' and code_root == Path(__file__).resolve().parent else name)) for name in selected}
    output.mkdir(mode=0o700)  # Existing output is never reused or removed.
    for name, data in sources.items():
        atomic_write(output / name, data, exclusive=True)
    identities = {}
    for name, source in components.items():
        copy_tree(source, output / name, building=True)
        component = verify_component(output / name)
        identities[name] = {'release': component['release'], 'manifest_sha256': sha(read_file(output / name / 'manifest.json'))}
    hashes = {name: sha(read_file(output / name)) for name in tree_files(output)}
    manifest = {'v': 1, 'profile': profile,
                'release': sha(canonical({'profile': profile, 'sha256': hashes}))[:20],
                'sha256': hashes, 'components': identities}
    atomic_write(output / 'manifest.json', canonical(manifest), exclusive=True)
    verify_kit(output)
    return manifest


def extract_kit(archive_path, destination, expected_sha256):
    import tarfile
    archive_path, destination = Path(archive_path), Path(destination)
    if not is_hash(expected_sha256) or sha(read_file(archive_path, 384 * 1024 * 1024)) != expected_sha256:
        raise ValueError('exact reviewed archive digest required')
    trusted_directory(destination.parent, os.geteuid(), allow_sticky=True)
    with tarfile.open(archive_path, 'r:') as archive:
        entries = archive.getmembers()
        if len(entries) > 160:
            raise ValueError('archive entry bound')
        names, total = set(), 0
        for entry in entries:
            path = Path(entry.name)
            if (entry.name in names or not path.parts or path.parts[0] != 'release'
                    or any(p in ('.', '..') for p in path.parts)
                    or not re.fullmatch(r'release(?:/[A-Za-z0-9_.-]+)*', entry.name)
                    or not (entry.isfile() or entry.isdir()) or entry.size > MAX_FILE):
                raise ValueError('unsafe coordinated archive member')
            names.add(entry.name)
            total += entry.size
        if total > 384 * 1024 * 1024:
            raise ValueError('archive size bound')
        with archive.extractfile('release/manifest.json') as stream:
            header = decode_json(stream.read(256 * 1024 + 1))
        production = relay_profile(header.get('profile'))
        if header.get('profile') not in GATES or (production and os.geteuid() != 0):
            raise ValueError('production extraction requires root-owned files')
        destination.mkdir(mode=0o755 if production else 0o700)
        for entry in entries:
            relative = Path(*Path(entry.name).parts[1:])
            target = destination / relative
            if entry.isdir():
                if target != destination:
                    target.mkdir(mode=0o755 if production else 0o700, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o755 if production else 0o700, parents=True, exist_ok=True)
            with archive.extractfile(entry) as stream:
                content = stream.read(MAX_FILE + 1)
            mode = (0o755 if entry.mode & 0o111 else 0o644) if production else (0o700 if entry.mode & 0o111 else 0o600)
            atomic_write(target, content, mode, exclusive=True)
        manifest = verify_kit(destination)
        fsync_dir(destination)
        fsync_dir(destination.parent)
        return {'release': manifest['release'], 'profile': manifest['profile'],
                'kit_sha256': sha(read_file(destination / 'manifest.json')), 'path': str(destination)}


def command(argv, data=None, timeout=90):
    result = subprocess.run([str(part) for part in argv], input=data, capture_output=True,
                            env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C',
                                 'PYTHONDONTWRITEBYTECODE': '1'}, timeout=timeout)
    if result.returncode:
        raise RuntimeError('required subprocess failed; private details suppressed')
    return result.stdout


def network_module(kit_root):
    import importlib.util
    spec = importlib.util.spec_from_file_location('single_host_network', Path(kit_root) / 'single_host_network.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def vm_module(kit_root):
    if kit_root is None:
        raise ValueError('verified kit path required for full rehearsal')
    import importlib.util
    spec = importlib.util.spec_from_file_location('single_host_vm', Path(kit_root) / 'single_host_vm.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def vm_boundary(intent, kit_root):
    return vm_module(kit_root).boundary(sys.modules[__name__], intent, kit_root)


def network_spec(intent):
    if not relay_profile(intent['profile']):
        raise ValueError('fixture has no network operation')
    return {'v': 1, 'profile': PRODUCTION, 'ip': intent['ip'],
            'interface': intent['interface'], 'relay_uid': intent['relay']['uid']}


def coordinator_state(intent):
    return STATE if relay_profile(intent['profile']) else Path(intent['message']['root'] + '-coordinator')


def plan(intent, kit_root):
    intent = validate_intent(intent)
    kit_root = simple_path(str(kit_root))
    manifest = verify_kit(kit_root)
    if manifest['profile'] != intent['profile'] or sha(read_file(kit_root / 'manifest.json')) != intent['kit_sha256']:
        raise ValueError('intent/kit profile or digest mismatch')
    result = {'v': 1, 'intent': intent, 'kit_release': manifest['release'],
              'kit_sha256': intent['kit_sha256'], 'components': manifest['components'],
              'state': str(coordinator_state(intent)), 'required_gates': list(GATES[intent['profile']]),
              'full_rehearsal_profiles': sorted(FULL_REHEARSAL_PROFILES),
              'phases': ['preflight', 'stage', 'message-same-data', 'postflight']}
    if relay_profile(intent['profile']):
        network = network_module(kit_root)
        policy = network_spec(intent)
        result['network_policy_sha256'] = sha(network.render_nft(policy))
        result['phases'] = ['preflight', 'stage', 'message-same-data', 'egress',
                            'relay-start', 'ingress-last', 'postflight']
    result['plan_sha256'] = sha(canonical(result))
    return result


def account(intent, name, must_exist=True):
    desired = intent[name]
    try:
        found = pwd.getpwnam(desired['user'])
    except KeyError:
        if must_exist:
            raise ValueError('required dedicated account absent') from None
        try:
            pwd.getpwuid(desired['uid'])
        except KeyError:
            return None
        raise ValueError('planned numeric UID belongs to another account') from None
    if found.pw_uid != desired['uid'] or found.pw_gid != desired['gid']:
        raise ValueError('dedicated account identity mismatch')
    return found


def fixture_boundary(intent):
    if intent['profile'] != FIXTURE or os.geteuid() == 0:
        raise ValueError('fixture requires its unprivileged profile')
    if intent['message']['uid'] != os.geteuid() or intent['message']['gid'] != os.getegid():
        raise ValueError('fixture uses only the current existing identity')
    for marker in (STATE, Path('/etc/paranoid-turn'), Path('/etc/systemd/system/paranoid-turn.service')):
        if os.path.lexists(marker):
            raise ValueError('production marker forbids fixture execution')
    account(intent, 'message')


def worker(intent, kit_root, operation, transaction=None, secret=None):
    message = intent['message']
    payload = {'operation': operation, 'intent': intent, 'release': str(Path(kit_root) / 'message'),
               'transaction': transaction, 'secret': None if secret is None else secret.decode('ascii')}
    user = account(intent, 'message')
    env = ['env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'LANG=C',
           'HOME=' + user.pw_dir, 'USER=' + user.pw_name, 'LOGNAME=' + user.pw_name,
           'XDG_RUNTIME_DIR=/run/user/' + str(user.pw_uid), 'PYTHONDONTWRITEBYTECODE=1']
    args = env + ['/usr/bin/python3', '-I', '-B', str(Path(kit_root) / 'single_host_message.py')]
    if os.geteuid() == 0:
        args = ['runuser', '--user', user.pw_name, '--'] + args
    elif os.geteuid() != user.pw_uid:
        raise ValueError('cannot assume messaging identity')
    return decode_json(command(args, canonical(payload), timeout=300))


def verify_root_kit(kit_root):
    trusted_directory(kit_root, 0)
    for name in tree_files(kit_root):
        read_file(Path(kit_root) / name, owner=0)


def require_message_ingress(intent, observation):
    # Supported production host prerequisite: retain exactly the already authorized
    # message rule. This coordinator never creates/deletes/adopts TCP38443 rules.
    matches = []
    address = ipaddress.IPv4Address(intent['ip'])
    for rule in observation.get('ufw', []):
        if (rule['direction'] != 'in' or rule['interface'] not in ('any', intent['interface'])
                or rule['proto'] not in ('any', 'tcp')
                or not rule['dst_port'][0] <= 38443 <= rule['dst_port'][1]):
            continue
        if rule['dst'] != 'any' and address not in ipaddress.ip_network(rule['dst']):
            continue
        matches.append(rule)
    if len(matches) != 1:
        raise ValueError('one exact retained TCP38443 ingress prerequisite required')
    found = matches[0]
    exact = {'action': 'allow', 'direction': 'in', 'interface': intent['interface'],
             'proto': 'tcp', 'src': 'any', 'src_port': [1, 65535],
             'dst': intent['ip'] + '/32', 'dst_port': [38443, 38443], 'log': ''}
    if any(found[key] != expected for key, expected in exact.items()):
        raise ValueError('retained message ingress has unsupported scope or conflict')
    return sha(canonical(found))


def preflight(intent, kit_root):
    result = plan(intent, kit_root)
    if intent['profile'] == VM_FIXTURE:
        vm_boundary(intent, kit_root)
    if intent['profile'] == FIXTURE:
        fixture_boundary(intent)
        result['message'] = worker(intent, kit_root, 'preflight')
        return result
    if os.geteuid() != 0:
        raise ValueError('production preflight requires root read access')
    verify_root_kit(kit_root)
    # Run isolated Python as the declared numeric UID, even for a not-yet-created account.
    command(['setpriv', '--reuid', str(intent['message']['uid']), '--regid', str(intent['message']['gid']),
             '--clear-groups', '/usr/bin/python3', '-I', '-c',
             'from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes; '
             'from cryptography.hazmat.primitives.ciphers.aead import AESGCM'], timeout=15)
    for executable in ('nft', 'ufw', 'systemctl', 'systemd-analyze', 'runuser', 'useradd', 'groupadd', 'loginctl'):
        if shutil.which(executable, path='/usr/sbin:/usr/bin:/sbin:/bin') is None:
            raise ValueError('required runtime executable absent')
    command(['/usr/lib/postgresql/16/bin/postgres', '--version'], timeout=10)
    command(['systemctl', 'show', '--property=Version', '--value'], timeout=10)
    command(['openssl', 'version'], timeout=10)
    root = Path(intent['message']['root'])
    if intent['mode'] == 'fresh':
        for name in ('message', 'relay'):
            if account(intent, name, must_exist=False) is not None:
                raise ValueError('fresh mode requires new dedicated accounts')
        if os.path.lexists(root) or os.path.lexists(root.parent):
            raise ValueError('fresh home/root already exists')
        result['message'] = {'mode': 'fresh', 'identity': None}
    else:
        account(intent, 'message')
        account(intent, 'relay', must_exist=False)
        result['message'] = worker(intent, kit_root, 'preflight')
    # Local address/interface/listener inventory; never connect to a neighbor.
    addresses = decode_json(command(['ip', '-j', '-4', 'address', 'show', 'dev', intent['interface']], timeout=10))
    if not any(a.get('local') == intent['ip'] for link in addresses for a in link.get('addr_info', [])):
        raise ValueError('approved IPv4 is not on selected interface')
    listeners = command(['ss', '-H', '-lntu'], timeout=10).decode()
    state = coordinator_state(intent)
    recognized = os.path.lexists(state / 'current.json')
    if not recognized:
        for line in listeners.splitlines():
            fields = line.split()
            if len(fields) >= 5:
                port = fields[4].rsplit(':', 1)[-1]
                if port.isdigit() and (int(port) == 34781 or 40000 <= int(port) <= 40015):
                    raise ValueError('approved relay port already in use')
        for path in (Path('/etc/paranoid-turn'), Path('/opt/paranoid-turn'),
                     Path('/etc/systemd/system/paranoid-turn.service'),
                     Path('/etc/systemd/system/paranoid-voice-policy.service')):
            if os.path.lexists(path):
                raise ValueError('unrecognized relay installation path exists')
    network = network_module(kit_root)
    policy = network_spec(intent)
    observation = network.observe(policy)
    receipt_path = state / 'network-receipt.json'
    receipt = decode_json(read_file(receipt_path, private=True)) if recognized else None
    network.classify_ownership(policy, observation, receipt)
    result['message_ingress_sha256'] = require_message_ingress(intent, observation)
    if recognized:
        status(state)
    result['network_observation'] = observation
    return result


def state_record(state):
    trusted_directory(state, os.geteuid(), private=True)
    value = decode_json(read_file(state / 'current.json', 256 * 1024, os.geteuid(), private=True))
    if not isinstance(value, dict) or value.get('v') != 1:
        raise ValueError('invalid coordinator state')
    validate_intent(value['intent'])
    if str(coordinator_state(value['intent'])) != str(state):
        raise ValueError('coordinator state path differs')
    return value


def status(state):
    value = state_record(state)
    if value['intent']['profile'] == FIXTURE:
        fixture_boundary(value['intent'])
    elif value['intent']['profile'] == VM_FIXTURE:
        vm_boundary(value['intent'], value['kit_path'])
    elif os.geteuid() != 0:
        raise ValueError('production status requires root read access')
    result = {'v': 1, 'phase': value['phase'], 'transaction': value['transaction'],
              'kit_sha256': value['intent']['kit_sha256'], 'state_sha256': sha(read_file(state / 'current.json'))}
    if value['phase'] == 'active':
        found = worker(value['intent'], value['kit_path'], 'status')
        if found['identity'] != value['message_result']['identity']:
            raise ValueError('installed message identity drift')
        result['identity'] = found['identity']
        if relay_profile(value['intent']['profile']):
            network = network_module(value['kit_path'])
            spec = network_spec(value['intent'])
            receipt = decode_json(read_file(state / 'network-receipt.json', private=True))
            actual_network = coordinated_network(state, value, 'check')
            require_network_active(value['intent'], value['kit_path'], actual_network)
            verify_system_artifacts(value)
            baseline = require_message_ingress(value['intent'], network.observe(spec))
            if baseline != value['message_ingress_sha256']:
                raise ValueError('retained message ingress changed')
            result['relay_runtime'] = wait_relay_active(value)
        result['verified'] = True
    else:
        result['verified'] = False
    return result


def make_private(path):
    path = Path(path)
    if not os.path.lexists(path):
        trusted_directory(path.parent, os.geteuid(), allow_sticky=True)
        path.mkdir(mode=0o700)
        fsync_dir(path.parent)
    trusted_directory(path, os.geteuid(), private=True)


def save_state(state, value):
    atomic_write(state / 'current.json', canonical(value))
    atomic_write(state / 'transactions' / value['transaction'] / 'journal.json', canonical(value))


def create_account(desired, message=False):
    import grp
    try:
        grp.getgrgid(desired['gid'])
    except KeyError:
        pass
    else:
        raise ValueError('planned group already belongs to another identity')
    try:
        grp.getgrnam(desired['user'])
    except KeyError:
        pass
    else:
        raise ValueError('planned group name already exists')
    command(['groupadd', '--gid', str(desired['gid']), desired['user']])
    args = ['useradd', '--uid', str(desired['uid']), '--gid', str(desired['gid']),
            '--shell', '/usr/sbin/nologin', '--no-user-group']
    if message:
        args += ['--create-home', '--home-dir', '/home/paranoid']
    else:
        args += ['--no-create-home', '--home-dir', '/nonexistent']
    command(args + [desired['user']])
    if message:
        command(['loginctl', 'enable-linger', desired['user']])
        command(['systemctl', 'start', 'user@' + str(desired['uid']) + '.service'])


def installed_kit(source, state, manifest, production):
    parent = Path('/opt/paranoid-single-host') if production else state / 'releases'
    if not os.path.lexists(parent):
        trusted_directory(parent.parent, os.geteuid())
        parent.mkdir(mode=0o755 if production else 0o700)
        fsync_dir(parent.parent)
    trusted_directory(parent, os.geteuid())
    target = parent / manifest['release']
    if os.path.lexists(target):
        if verify_kit(target) != manifest:
            raise ValueError('installed kit release collision')
    else:
        copy_tree(source, target, public=production)
    verify_kit(target)
    return target


def coordinated_network(state, value, operation):
    network = network_module(value['kit_path'])
    spec = network_spec(value['intent'])
    # CLI takes its independent network lock. Do not hold that lock while starting
    # the policy unit, which calls this same helper during boot/startup.
    args = ['/usr/bin/python3', '-I', '-B', str(Path(value['kit_path']) / 'single_host_network.py'),
            operation, '--spec', str(state / 'network-spec.json'), '--expected-policy-sha',
            sha(network.render_nft(spec)), '--receipt', str(state / 'network-receipt.json')]
    return decode_json(command(args, timeout=45))


def require_network_active(intent, kit_root, observed):
    network = network_module(kit_root)
    expected = [r['id'] for r in network.desired_ufw_rules(network_spec(intent))]
    if (observed.get('egress') != 'present' or observed.get('ingress') != expected
            or observed.get('pending') is not None):
        raise ValueError('actual egress and all exact ingress rules required')


def properties(raw):
    result = {}
    for line in raw.decode().splitlines():
        if '=' not in line:
            raise ValueError('malformed unit properties')
        key, value = line.split('=', 1)
        if key in result:
            raise ValueError('duplicate unit property')
        result[key] = value
    return result


def validate_loaded_unit(raw, path, argv, user=None, group=None):
    found = properties(raw)
    if (set(found) != {'FragmentPath', 'DropInPaths', 'NeedDaemonReload', 'ExecStart', 'User', 'Group'}
            or not found['FragmentPath'] or Path(found['FragmentPath']).resolve() != path
            or found['DropInPaths'] or found['NeedDaemonReload'] != 'no'
            or re.findall(r'argv\[\]=(.*?) ;', found['ExecStart']) != [' '.join(map(str, argv))]
            or (user is not None and found['User'] != user)
            or (group is not None and found['Group'] != group)):
        raise ValueError('loaded unit authority differs or has unreviewed drop-ins')
    return found


def system_loaded(name, argv, user, group):
    raw = command(['systemctl', 'show', name,
                   '--property=FragmentPath,DropInPaths,NeedDaemonReload,ExecStart,User,Group'], timeout=10)
    return validate_loaded_unit(raw, Path('/etc/systemd/system') / name, argv, user, group)


def quiesce_previous_relay(state, previous):
    verify_system_artifacts(previous)
    coordinated_network(state, previous, 'close-ingress')
    command(['systemctl', 'stop', 'paranoid-turn.service'])
    found = properties(command(['systemctl', 'show', 'paranoid-turn.service',
                                '--property=MainPID,ControlPID,ActiveState'], timeout=10))
    if (found.get('MainPID') != '0' or found.get('ControlPID') != '0'
            or found.get('ActiveState') not in ('inactive', 'failed')):
        raise ValueError('previous owned relay did not stop; no cutover')


def wait_relay_active(value):
    # This is PID/executable readiness, not CLI, expiry, ACL or media acceptance.
    verify_system_artifacts(value)
    manifest = verify_kit(Path(value['kit_path']))
    release = Path('/opt/paranoid-turn') / manifest['components']['relay']['release']
    executable = release / 'bin/turnserver'
    expected = verify_component(release)['sha256']['bin/turnserver']
    for _ in range(100):
        found = properties(command(['systemctl', 'show', 'paranoid-turn.service',
                                    '--property=MainPID,ControlPID,ActiveState'], timeout=5))
        pid = found.get('MainPID', '')
        if found.get('ActiveState') == 'active' and re.fullmatch(r'[1-9][0-9]*', pid):
            path = Path('/proc') / pid / 'exe'
            try:
                # Following this kernel-generated link is intentional and limited
                # to the trusted manager's exact owned service MainPID.
                if os.readlink(path) == str(executable):
                    fd = os.open(path, os.O_RDONLY)
                    with os.fdopen(fd, 'rb') as stream:
                        meta = os.fstat(stream.fileno())
                        data = stream.read(MAX_FILE + 1)
                    if (stat.S_ISREG(meta.st_mode) and meta.st_uid == 0 and meta.st_nlink == 1
                            and len(data) <= MAX_FILE and sha(data) == expected):
                        again = properties(command(['systemctl', 'show', 'paranoid-turn.service',
                                                    '--property=MainPID,ActiveState'], timeout=5))
                        if again == {'MainPID': pid, 'ActiveState': 'active'}:
                            return {'main_pid': int(pid), 'executable_sha256': expected,
                                    'claim': 'active packaged executable only'}
            except (OSError, ValueError):
                pass
        time.sleep(0.1)
    raise ValueError('expected packaged relay executable is not active')


def restart_previous_relay(state, previous):
    verify_system_artifacts(previous)
    coordinated_network(state, previous, 'apply')
    command(['systemctl', 'start', 'paranoid-voice-policy.service'])
    command(['systemctl', 'start', 'paranoid-turn.service'])
    ready = wait_relay_active(previous)
    opened = coordinated_network(state, previous, 'open-ingress')
    require_network_active(previous['intent'], previous['kit_path'], opened)
    return ready


def verify_system_artifacts(value):
    root = Path(value['kit_path'])
    verify_root_kit(root)
    manifest = verify_kit(root)
    if sha(read_file(root / 'manifest.json')) != value['intent']['kit_sha256']:
        raise ValueError('installed kit artifact changed')
    relay = Path('/opt/paranoid-turn') / manifest['components']['relay']['release']
    if verify_component(relay) != verify_component(root / 'relay'):
        raise ValueError('installed relay bytes changed')
    for name, expected in value['system_unit_sha256'].items():
        if sha(read_file(Path('/etc/systemd/system') / name, owner=0)) != expected:
            raise ValueError('installed system unit changed')
    system_loaded('paranoid-turn.service', ['/usr/bin/python3', '-I', '-B',
                  str(relay / 'runtime.py'), 'run'], 'paranoid-turn', 'paranoid-turn')
    network = network_module(root)
    spec = network_spec(value['intent'])
    state = coordinator_state(value['intent'])
    system_loaded('paranoid-voice-policy.service', ['/usr/bin/python3', '-I', '-B',
                  str(root / 'single_host_network.py'), 'apply', '--spec', str(state / 'network-spec.json'),
                  '--expected-policy-sha', sha(network.render_nft(spec)), '--receipt',
                  str(state / 'network-receipt.json')], 'root', 'root')


def stop_owned(state, value):
    result = {'relay_stopped': None, 'message_stopped': None}
    if value.get('relay_staged'):
        try:
            path = Path('/etc/systemd/system/paranoid-turn.service')
            expected = value.get('system_unit_sha256', {}).get(path.name)
            if expected is None or sha(read_file(path, owner=0)) != expected:
                raise ValueError('cannot stop unrecognized relay unit')
            verify_system_artifacts(value)
            command(['systemctl', 'stop', 'paranoid-turn.service'])
            fields = command(['systemctl', 'show', 'paranoid-turn.service',
                              '-p', 'MainPID', '-p', 'ControlPID', '-p', 'ActiveState']).decode()
            result['relay_stopped'] = ('MainPID=0\n' in fields and 'ControlPID=0\n' in fields
                                       and 'ActiveState=active\n' not in fields)
        except Exception:
            result['relay_stopped'] = False
    if value.get('message_attempted'):
        try:
            reply = worker(value['intent'], value['kit_path'], 'stop', value['transaction'])
            result['message_stopped'] = reply.get('stopped') is True
        except Exception:
            result['message_stopped'] = False
    return result


def record_incomplete_recovery(state, value):
    result = stop_owned(state, value)  # each owned stop is attempted independently
    value['phase'] = 'recovery-incomplete'
    value['recovery'] = result
    save_state(state, value)
    return result


def stage_relay(state, value, secret):
    source = Path(value['kit_path']) / 'relay'
    component = verify_component(source)
    parent = Path('/opt/paranoid-turn')
    if not os.path.lexists(parent):
        parent.mkdir(mode=0o755)
        fsync_dir(parent.parent)
    trusted_directory(parent, 0)
    target = parent / component['release']
    if os.path.lexists(target):
        if verify_component(target) != component:
            raise ValueError('relay release collision')
    else:
        copy_tree(source, target, public=True)
    config = Path('/etc/paranoid-turn')
    make_private(config)
    for name, mode in (('master.secret', 0o600), ('relay.secret', 0o400)):
        path = config / name
        if os.path.lexists(path):
            if read_file(path, 64, 0, private=True) != secret:
                raise ValueError('retained relay credential differs')
        else:
            atomic_write(path, secret, mode, exclusive=True)
    network = network_module(value['kit_path'])
    spec = network_spec(value['intent'])
    spec_path = state / 'network-spec.json'
    spec_bytes = canonical(spec)
    if os.path.lexists(spec_path) and read_file(spec_path, private=True) != spec_bytes:
        raise ValueError('network specification drift')
    if not os.path.lexists(spec_path):
        atomic_write(spec_path, spec_bytes, exclusive=True)
    receipt_path = state / 'network-receipt.json'
    if not os.path.lexists(receipt_path):
        receipt = network.prepare_receipt(spec, network.observe(spec), value['acceptance_sha256'])
        atomic_write(receipt_path, canonical(receipt), exclusive=True)
    policy = network.render_policy_unit(Path(value['kit_path']) / 'single_host_network.py',
                                        spec_path, sha(network.render_nft(spec)), receipt_path)
    relay = read_file(target / 'paranoid-turn.service.in').replace(b'@RELEASE@', component['release'].encode())
    unit_root = Path('/etc/systemd/system')
    transaction = state / 'transactions' / value['transaction']
    for name, data in (('paranoid-voice-policy.service', policy), ('paranoid-turn.service', relay)):
        path = unit_root / name
        if os.path.lexists(path):
            old = read_file(path, owner=0)
            if value['previous_transaction'] is None:
                raise ValueError('unrecognized existing system unit')
            prior = decode_json(read_file(state / 'transactions' / value['previous_transaction'] / 'journal.json', private=True))
            if sha(old) != prior.get('system_unit_sha256', {}).get(name):
                raise ValueError('retained prior system unit drift')
            atomic_write(transaction / (name + '.before'), old, exclusive=True)
        value.setdefault('system_unit_sha256', {})[name] = sha(data)
        save_state(state, value)
        atomic_write(path, data, 0o644)
    command(['systemd-analyze', 'verify', unit_root / 'paranoid-voice-policy.service',
             unit_root / 'paranoid-turn.service'], timeout=20)
    command(['systemctl', 'daemon-reload'], timeout=20)


def recover(state, value):
    production = relay_profile(value['intent']['profile'])
    previous = None
    if production and value.get('previous_transaction'):
        previous = decode_json(read_file(state / 'transactions' / value['previous_transaction'] / 'journal.json', private=True))
    if previous is not None and value.get('prior_relay_stop_intent') and not value.get('relay_staged'):
        restart_previous_relay(state, previous)
        value['phase'] = 'rolled-back'
        save_state(state, value)
        return {'phase': 'rolled-back', 'transaction': value['transaction'], 'retained_data': True}
    if production and os.path.lexists(state / 'network-receipt.json'):
        coordinated_network(state, previous or value, 'close-ingress')
    if production and value.get('relay_staged'):
        verify_system_artifacts(value)
        command(['systemctl', 'stop', 'paranoid-turn.service'])
    if value.get('message_attempted'):
        worker(value['intent'], value['kit_path'], 'rollback', value['transaction'])
        if value['intent']['mode'] == 'fresh':
            # Rollback preserves all fresh data but deactivates only its owned unit.
            user = account(value['intent'], 'message')
            for action in ('stop', 'disable'):
                args = ['env', '-i', 'PATH=/usr/bin:/bin', 'HOME=' + user.pw_dir,
                        'XDG_RUNTIME_DIR=/run/user/' + str(user.pw_uid),
                        'systemctl', '--user', action, value['intent']['message']['unit']]
                if os.geteuid() == 0:
                    args = ['runuser', '--user', user.pw_name, '--'] + args
                command(args)
    if production and value.get('relay_staged'):
        transaction = state / 'transactions' / value['transaction']
        if value['previous_transaction'] is None:
            command(['systemctl', 'disable', 'paranoid-turn.service'])
            coordinated_network(state, value, 'remove')
            command(['systemctl', 'stop', 'paranoid-voice-policy.service'])
            for name, digest in value['system_unit_sha256'].items():
                path = Path('/etc/systemd/system') / name
                if sha(read_file(path, owner=0)) != digest:
                    raise ValueError('system unit drift; no rollback overwrite')
                path.unlink()
                fsync_dir(path.parent)
            command(['systemctl', 'daemon-reload'])
        else:
            for name, digest in value['system_unit_sha256'].items():
                path = Path('/etc/systemd/system') / name
                before = read_file(transaction / (name + '.before'), private=True)
                current_hash = sha(read_file(path, owner=0))
                if current_hash not in (digest, sha(before)):
                    raise ValueError('system unit drift; no rollback overwrite')
                if current_hash != sha(before):
                    atomic_write(path, before, 0o644)
            command(['systemctl', 'daemon-reload'])
            restart_previous_relay(state, previous)
    value['phase'] = 'rolled-back'
    save_state(state, value)
    return {'phase': 'rolled-back', 'transaction': value['transaction'], 'retained_data': True}


def apply(intent, kit_root, acceptance, expected_plan, updating=False):
    if relay_profile(intent['profile']) and os.geteuid() != 0:
        raise ValueError('production or VM apply requires root before loading a kit')
    desired = plan(intent, kit_root)
    if intent['profile'] == VM_FIXTURE:
        boundary = vm_boundary(intent, kit_root)
    validate_acceptance(acceptance, intent['profile'], intent['kit_sha256'], desired['plan_sha256'], kit_root, intent)
    if intent['profile'] == VM_FIXTURE:
        isolation = acceptance['gates']['current-boot-isolation']
        if isolation['boot_id'] != boundary['boot_id'] or isolation['evidence_sha256'] != boundary['isolation_sha256']:
            raise ValueError('acceptance must match the actual current guest isolation')
    if desired['plan_sha256'] != expected_plan:
        raise ValueError('reviewed plan digest mismatch')
    production = relay_profile(intent['profile'])
    if production and os.geteuid() != 0:
        raise ValueError('production apply requires root')
    if not production:
        fixture_boundary(intent)
    state = coordinator_state(intent)
    if os.path.lexists(state / 'current.json'):
        previous = state_record(state)
        if previous['phase'] == 'active' and previous['plan_sha256'] == expected_plan:
            result = status(state)
            result['phase'] = 'already-applied'
            return result
        if not updating or previous['phase'] != 'active':
            raise ValueError('existing transaction requires explicit update or rollback')
        status(state)
    else:
        previous = None
        if updating:
            raise ValueError('update requires recognized coordinated installation')
    # No files, locks, accounts or credentials exist before actual receipt+preflight pass.
    preflight(intent, kit_root)
    make_private(state)
    with exclusive_lock(state / 'operator.lock'):
        # A concurrent operator may have completed after our first read.
        if os.path.lexists(state / 'current.json'):
            now = state_record(state)
            if previous is None or now != previous:
                raise ValueError('coordinator state changed while acquiring lock')
        checked = preflight(intent, kit_root)
        make_private(state / 'transactions')
        transaction = secrets.token_hex(16)
        make_private(state / 'transactions' / transaction)
        manifest = verify_kit(kit_root)
        value = {'v': 1, 'phase': 'intent', 'transaction': transaction,
                 'plan_sha256': expected_plan, 'intent': intent, 'kit_path': str(kit_root),
                 'acceptance_sha256': sha(canonical(acceptance)),
                 'previous_transaction': None if previous is None else previous['transaction']}
        if production:
            value['message_ingress_sha256'] = checked['message_ingress_sha256']
        save_state(state, value)
        try:
            if production:
                if intent['mode'] == 'fresh':
                    create_account(intent['message'], message=True)
                if account(intent, 'relay', must_exist=False) is None:
                    create_account(intent['relay'])
            target = installed_kit(kit_root, state, manifest, production)
            value['kit_path'] = str(target)
            value['phase'] = 'staged'
            save_state(state, value)
            secret = None
            if production:
                if os.path.lexists('/etc/paranoid-turn/master.secret'):
                    secret = read_file('/etc/paranoid-turn/master.secret', 64, 0, private=True)
                else:
                    secret = secrets.token_hex(32).encode()
            if production and previous is not None:
                value['prior_relay_stop_intent'] = True
                value['phase'] = 'prior-relay-stop-intent'
                save_state(state, value)
                quiesce_previous_relay(state, previous)
            if production:
                # Mark before the first unit write so interruption cannot orphan installed state.
                value['relay_staged'] = True
                save_state(state, value)
                stage_relay(state, value, secret)
                verify_system_artifacts(value)
            value['message_attempted'] = True
            value['phase'] = 'message-intent'
            save_state(state, value)
            value['message_result'] = worker(intent, target, 'apply', transaction, secret)
            del secret
            if production:
                value['phase'] = 'egress-intent'
                save_state(state, value)
                coordinated_network(state, value, 'apply')
                command(['systemctl', 'start', 'paranoid-voice-policy.service'])
                command(['systemctl', 'start', 'paranoid-turn.service'])
                value['relay_runtime'] = wait_relay_active(value)
                verify_system_artifacts(value)
                opened = coordinated_network(state, value, 'open-ingress')
                require_network_active(intent, target, opened)
                command(['systemctl', 'enable', 'paranoid-turn.service'])
            value['phase'] = 'active'
            save_state(state, value)
            return status(state)
        except BaseException as error:
            try:
                recover(state, value)
            except BaseException:
                record_incomplete_recovery(state, value)
                raise RuntimeError('coordinated operation/recovery incomplete; inspect exact private transaction') from None
            if isinstance(error, KeyboardInterrupt):
                raise
            raise RuntimeError('coordinated operation failed; recorded rollback completed') from None


def rollback(state, transaction, expected_state):
    state = simple_path(str(state))
    value = state_record(state)
    if value['transaction'] != transaction or sha(read_file(state / 'current.json')) != expected_state:
        raise ValueError('exact current transaction/state required')
    if value['intent']['profile'] == FIXTURE:
        fixture_boundary(value['intent'])
    elif value['intent']['profile'] == VM_FIXTURE:
        vm_boundary(value['intent'], value['kit_path'])
    elif os.geteuid() != 0:
        raise ValueError('production rollback requires root')
    with exclusive_lock(state / 'operator.lock'):
        if value != state_record(state):
            raise ValueError('rollback state changed')
        return recover(state, value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('extract', 'plan', 'preflight', 'apply', 'status', 'update', 'rollback'))
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--archive-sha256')
    parser.add_argument('--config', type=Path)
    parser.add_argument('--kit', type=Path)
    parser.add_argument('--acceptance', type=Path)
    parser.add_argument('--expect-plan')
    parser.add_argument('--state', type=Path)
    parser.add_argument('--transaction')
    parser.add_argument('--expect-state')
    args = parser.parse_args()
    if args.operation == 'extract':
        result = extract_kit(args.archive, args.destination, args.archive_sha256)
    elif args.operation == 'status':
        result = status(simple_path(str(args.state)))
    elif args.operation == 'rollback':
        result = rollback(args.state, args.transaction, args.expect_state)
    else:
        intent = validate_intent(decode_json(read_file(args.config, 128 * 1024)))
        if args.operation == 'plan':
            result = plan(intent, args.kit)
        elif args.operation == 'preflight':
            result = preflight(intent, args.kit)
        else:
            receipt = decode_json(read_file(args.acceptance, 128 * 1024, private=True))
            result = apply(intent, args.kit, receipt, args.expect_plan, args.operation == 'update')
    print(canonical(result).decode(), end='')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except FullRehearsalUnavailable:
        print(canonical({'error': 'full-relay-rehearsal-unavailable', 'mutations': False}).decode(), end='', file=sys.stderr)
        raise SystemExit(2) from None
    except KeyboardInterrupt:
        print('coordinator interrupted; inspect the exact retained transaction', file=sys.stderr)
        raise SystemExit(130) from None
    except Exception:
        print('coordinator failed validation or operation; retained state requires inspection', file=sys.stderr)
        raise SystemExit(1) from None
