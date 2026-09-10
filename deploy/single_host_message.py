#!/usr/bin/env python3
"""Unprivileged private-PG/TLS transaction worker; structured stdin, redacted output."""
import importlib.util
import os
from pathlib import Path
import re
import signal
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import single_host as kit


def load_alpha(release):
    release = Path(release)
    kit.verify_component(release)
    spec = importlib.util.spec_from_file_location('coordinated_alpha', release / 'alpha.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_secret(root, value):
    if not isinstance(value, bytes) or not re.fullmatch(b'[0-9a-f]{64}', value):
        raise ValueError('exact private synthetic or deployment credential required')
    directory = Path(root) / 'voice-turn'
    if not os.path.lexists(directory):
        directory.mkdir(mode=0o700)
        kit.fsync_dir(directory.parent)
    kit.trusted_directory(directory, os.geteuid(), private=True)
    source = directory / 'issuer.secret'
    if os.path.lexists(source):
        if kit.read_file(source, 64, os.geteuid(), private=True) != value:
            raise ValueError('existing credential differs; no automatic rotation')
    else:
        kit.atomic_write(source, value, 0o400, exclusive=True)


def switch_then_config(alpha, root, release, identifier, config, enable_voice=True):
    # alpha checks exact original config across its encrypted backup/code switch.
    alpha.switch_v2_locked(root, release, identifier)
    if not enable_voice:
        return
    updated = {**config, 'voice_turn': {'v': 1, 'relay_ip': config['ip']}}
    kit.atomic_write(root / 'config.json', kit.canonical(updated))


def identity(alpha, root, unit):
    config = alpha.config(root)
    if config.get('deployment') != 'self-service-v2':
        raise ValueError('recognized v2 installation required')
    release = alpha.current_release(root)
    return {'release': alpha.verify(release)['release'],
            'manifest_sha256': kit.sha(kit.read_file(release / 'manifest.json')),
            'pg_system_id': alpha.cluster_identifier(root),
            'config_sha256': kit.sha(kit.read_file(root / 'config.json', private=True)),
            'tls_cert_sha256': kit.sha(kit.read_file(root / 'tls/server.crt', private=True)),
            'tls_key_sha256': kit.sha(kit.read_file(root / 'tls/server.key', private=True)),
            'tls_spki': alpha.public_realm(root)[1],
            'unit_sha256': kit.sha(kit.read_file(root / unit, private=True))}


def manager(alpha, action, name):
    return alpha.command(['systemctl', '--user', action, name], timeout=75)


def verify_fragment(alpha, root, unit):
    raw = alpha.command(['systemctl', '--user', 'show', unit,
                         '--property=FragmentPath,DropInPaths,NeedDaemonReload,ExecStart,User,Group'], timeout=10)
    kit.validate_loaded_unit(raw, root / unit,
                            ['/usr/bin/python3', str(root / 'current/alpha.py'), 'run', '--root', str(root)])


def prerequisites():
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if not all((Cipher, algorithms.AES, modes.GCM, AESGCM)):
        raise ValueError('cryptography API prerequisite')


def preflight(alpha, intent, release):
    prerequisites()  # Never discover the backup dependency while service is stopped.
    message = intent['message']
    if os.geteuid() != message['uid'] or os.getegid() != message['gid'] or os.geteuid() == 0:
        raise ValueError('verified dedicated unprivileged identity required')
    root = Path(message['root'])
    alpha.root_path(root)
    if len(str(root / 'socket').encode()) + len('/.s.PGSQL.5432') >= 108:
        raise ValueError('private PostgreSQL socket path exceeds platform limit')
    alpha.v2_capability(alpha.verify(release), release)
    alpha.voice_turn_capability(release)
    if intent['mode'] == 'fresh':
        if os.path.lexists(root):
            raise ValueError('fresh root exists; never adopt or reset')
        load = alpha.command(['systemctl', '--user', 'show', message['unit'],
                              '-p', 'LoadState', '--value'], timeout=10).strip()
        if load != b'not-found':
            raise ValueError('fresh unit already exists')
        return {'mode': 'fresh', 'identity': None}
    alpha.v2_preflight(root, release, intent['expected']['pg_system_id'])
    alpha.v2_unit(root, message['unit'])
    verify_fragment(alpha, root, message['unit'])
    found = identity(alpha, root, message['unit'])
    if found != intent['expected']:
        raise ValueError('retained installation identity drift')
    return {'mode': 'existing-v8', 'identity': found}


def transaction_dir(root, transaction, create=False):
    if not isinstance(transaction, str) or not re.fullmatch(r'[0-9a-f]{32}', transaction):
        raise ValueError('exact transaction identifier required')
    base = root / 'single-host-state'
    if create and not os.path.lexists(base):
        base.mkdir(mode=0o700)
        kit.fsync_dir(root)
    kit.trusted_directory(base, os.geteuid(), private=True)
    target = base / transaction
    if create:
        target.mkdir(mode=0o700)  # No blind resumption of a partly applied transaction.
        kit.fsync_dir(base)
    kit.trusted_directory(target, os.geteuid(), private=True)
    return target


def save_journal(target, value):
    kit.atomic_write(target / 'journal.json', kit.canonical(value))


def snapshot(alpha, intent, release, transaction):
    root = Path(intent['message']['root'])
    unit = intent['message']['unit']
    target = transaction_dir(root, transaction, create=True)
    old_config = kit.read_file(root / 'config.json', private=True)
    old_unit = kit.read_file(root / unit, private=True)
    kit.atomic_write(target / 'config.before', old_config, exclusive=True)
    kit.atomic_write(target / 'unit.before', old_unit, exclusive=True)
    config = kit.decode_json(old_config)
    new_config = {**config, 'voice_turn': {'v': 1, 'relay_ip': config['ip']}}
    state = {'v': 1, 'phase': 'prepared', 'mode': intent['mode'], 'unit': unit,
             'identity': identity(alpha, root, unit),
             'candidate_release': alpha.verify(release)['release'],
             'config_after_sha256': kit.sha(kit.canonical(new_config)) if intent['profile'] == kit.PRODUCTION else kit.sha(old_config),
             'unit_after_sha256': None}
    save_journal(target, state)
    return target, state, config


def restore(alpha, root, target, state):
    unit = state['unit']
    before = state['identity']
    # Fail on a changed authority instead of overwriting an operator's new bytes.
    found = identity(alpha, root, unit)
    for key in ('pg_system_id', 'tls_cert_sha256', 'tls_key_sha256', 'tls_spki'):
        if found[key] != before[key]:
            raise ValueError('recovery identity drift; retained bytes preserved')
    if (found['release'] not in (before['release'], state['candidate_release'])
            or found['config_sha256'] not in (before['config_sha256'], state['config_after_sha256'])
            or found['unit_sha256'] not in (before['unit_sha256'], state['unit_after_sha256'])):
        raise ValueError('recovery code/config/unit drift; no overwrite')
    old_config = kit.read_file(target / 'config.before', private=True)
    old_unit = kit.read_file(target / 'unit.before', private=True)
    if kit.sha(old_config) != before['config_sha256'] or kit.sha(old_unit) != before['unit_sha256']:
        raise ValueError('recovery snapshot integrity failure')
    verify_fragment(alpha, root, unit)
    manager(alpha, 'stop', unit)
    # Old v8 parser cannot see voice_turn, even with a made-up disabled version.
    kit.atomic_write(root / 'config.json', old_config)
    kit.atomic_write(root / unit, old_unit)
    previous = root / 'releases' / before['release']
    alpha.v2_preflight(root, previous, before['pg_system_id'])
    with alpha.lock(root):
        alpha.point_v2(root, previous)
    alpha.command(['systemctl', '--user', 'daemon-reload'], timeout=15)
    verify_fragment(alpha, root, unit)
    manager(alpha, 'start', unit)
    alpha.wait_health(root)
    state['phase'] = 'rolled-back'
    save_journal(target, state)
    return {'phase': 'rolled-back', 'identity': identity(alpha, root, unit)}


def apply_existing(alpha, intent, release, transaction, secret):
    root = Path(intent['message']['root'])
    unit = intent['message']['unit']
    with alpha.v2_operation_lock(root):
        preflight(alpha, intent, release)
        target, state, config = snapshot(alpha, intent, release, transaction)
        if intent['profile'] == kit.PRODUCTION:
            install_secret(root, secret)
        elif secret is not None or 'voice_turn' in config:
            raise ValueError('fixture cannot enable or adopt issuer credentials')
        try:
            manager(alpha, 'stop', unit)
            state['phase'] = 'switch-intent'
            save_journal(target, state)
            switch_then_config(alpha, root, release, state['identity']['pg_system_id'], config,
                               enable_voice=intent['profile'] == kit.PRODUCTION)
            new_unit = alpha.unit(root).encode()
            state['unit_after_sha256'] = kit.sha(new_unit)
            state['phase'] = 'unit-intent'
            save_journal(target, state)
            kit.atomic_write(root / unit, new_unit)
            alpha.command(['systemd-analyze', '--user', 'verify', root / unit], timeout=20)
            alpha.command(['systemctl', '--user', 'daemon-reload'], timeout=15)
            verify_fragment(alpha, root, unit)
            manager(alpha, 'start', unit)
            alpha.wait_health(root)
            after = identity(alpha, root, unit)
            if any(after[key] != state['identity'][key] for key in
                   ('pg_system_id', 'tls_cert_sha256', 'tls_key_sha256', 'tls_spki')):
                raise ValueError('postflight identity changed')
            state['phase'] = 'active'
            save_journal(target, state)
            return {'phase': 'active', 'identity': after, 'transaction': transaction}
        except BaseException as error:
            try:
                restore(alpha, root, target, state)
            except BaseException:
                # Stop only a unit whose retained fragment still belongs to us.
                verify_fragment(alpha, root, unit)
                manager(alpha, 'stop', unit)
                state['phase'] = 'failed-stopped'
                save_journal(target, state)
                raise RuntimeError('message update and recovery failed; retained installation stopped') from None
            if isinstance(error, KeyboardInterrupt):
                raise
            raise RuntimeError('message update failed; previous exact config/code restored on current data') from None


def install_fresh_guarded(alpha, root, ip, release, unit):
    # Preserve alpha's existing initialization/data algorithms and lock order.
    # Its install_v2 uses enable--now, which offers no loaded-unit guard boundary.
    alpha.reviewed_v2_ip(ip, ip)
    alpha.v2_capability(alpha.verify(release), release)
    alpha.service_name(unit)
    alpha.initialize(root, ip)  # Exclusive fresh root; no adoption or reset.
    with alpha.lock(root):
        alpha.point(root, alpha.stage(root, release))
    alpha.fresh_v2(root, release, ip)  # Acquires its own operation/data locks.
    with alpha.v2_operation_lock(root):
        path = root / unit
        kit.atomic_write(path, alpha.unit(root).encode(), exclusive=True)
        alpha.command(['systemd-analyze', '--user', 'verify', path], timeout=20)
        alpha.command(['systemctl', '--user', 'link', path], timeout=15)
        alpha.command(['systemctl', '--user', 'daemon-reload'], timeout=15)
        verify_fragment(alpha, root, unit)
        alpha.command(['systemctl', '--user', 'enable', path], timeout=15)
        manager(alpha, 'start', unit)
        alpha.wait_health(root)


def apply_fresh(alpha, intent, release, transaction, secret):
    preflight(alpha, intent, release)
    root = Path(intent['message']['root'])
    unit = intent['message']['unit']
    try:
        install_fresh_guarded(alpha, root, intent['ip'], release, unit)
        updated = {**intent, 'mode': 'existing-v8', 'expected': identity(alpha, root, unit)}
        result = apply_existing(alpha, updated, release, transaction, secret)
        result['created_fresh'] = True
        return result
    except BaseException:
        if os.path.lexists(root / unit):
            verify_fragment(alpha, root, unit)
            manager(alpha, 'stop', unit)
            manager(alpha, 'disable', unit)
        raise RuntimeError('fresh installation incomplete; retained private root requires inspection') from None


def main():
    request = kit.decode_json(sys.stdin.buffer.read(128 * 1024 + 1))
    if not isinstance(request, dict) or set(request) != {'operation', 'intent', 'release', 'transaction', 'secret'}:
        raise ValueError('exact worker request required')
    intent = kit.validate_intent(request['intent'])
    release = kit.simple_path(request['release'])
    alpha = load_alpha(release)
    if os.geteuid() != intent['message']['uid'] or os.getegid() != intent['message']['gid'] or os.geteuid() == 0:
        raise ValueError('dedicated worker identity required')
    operation = request['operation']
    if operation == 'preflight':
        if request['secret'] is not None or request['transaction'] is not None:
            raise ValueError('preflight must contain no credential or transaction')
        result = preflight(alpha, intent, release)
    elif operation == 'apply':
        secret = request['secret'].encode('ascii') if intent['profile'] == kit.PRODUCTION else None
        if intent['profile'] == kit.FIXTURE and request['secret'] is not None:
            raise ValueError('fixture cannot receive issuer credentials')
        result = (apply_fresh if intent['mode'] == 'fresh' else apply_existing)(
            alpha, intent, release, request['transaction'], secret)
    elif operation in ('status', 'rollback', 'stop'):
        if request['secret'] is not None:
            raise ValueError('read/recovery must contain no credential')
        root = Path(intent['message']['root'])
        if operation == 'stop':
            target = transaction_dir(root, request['transaction'])
            state = kit.decode_json(kit.read_file(target / 'journal.json', 128 * 1024, private=True))
            unit = intent['message']['unit']
            digest = kit.sha(kit.read_file(root / unit, private=True))
            if digest not in (state['identity']['unit_sha256'], state['unit_after_sha256']):
                raise ValueError('unrecognized message unit cannot be stopped')
            verify_fragment(alpha, root, unit)
            manager(alpha, 'stop', unit)
            fields = alpha.command(['systemctl', '--user', 'show', unit, '-p', 'MainPID', '-p', 'ControlPID', '-p', 'ActiveState']).decode()
            result = {'stopped': 'MainPID=0\n' in fields and 'ControlPID=0\n' in fields and 'ActiveState=active\n' not in fields}
        elif operation == 'status':
            alpha.v2_unit(root, intent['message']['unit'])
            verify_fragment(alpha, root, intent['message']['unit'])
            alpha.health(root)
            result = {'identity': identity(alpha, root, intent['message']['unit'])}
        else:
            target = transaction_dir(root, request['transaction'])
            state = kit.decode_json(kit.read_file(target / 'journal.json', 128 * 1024, private=True))
            with alpha.v2_operation_lock(root):
                result = restore(alpha, root, target, state)
    else:
        raise ValueError('unknown worker operation')
    print(kit.canonical(result).decode(), end='')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except Exception:
        # No exception text: subprocess diagnostics can contain private configuration.
        print('message worker failed; inspect private transaction state', file=sys.stderr)
        raise SystemExit(1) from None
