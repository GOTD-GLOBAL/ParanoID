#!/usr/bin/env python3
"""REQ-DEPLOY-003: opt-in inert systemd credentials, never TURN/network evidence.

Default invocation runs only offline helper tests. Runtime integration is not
registered with CI and needs the exact separately reviewed local scope.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = r'''import os, stat, hashlib, hmac, re, sys, json, time

def validate_and_report(path, uid, expected_digest, report, observe=None):
    def note(stage, descriptor=None):
        if observe is not None:
            try:
                observe(stage, descriptor)
            except Exception:
                pass  # An observer cannot change the strict validation outcome.
    note("credential_open")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        meta = os.fstat(fd)
        descriptor = {"uid": meta.st_uid, "mode": stat.S_IMODE(meta.st_mode),
                      "nlink": meta.st_nlink, "type": stat.S_IFMT(meta.st_mode)}
        note("credential_descriptor", descriptor)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid != uid or stat.S_IMODE(meta.st_mode) not in (0o400, 0o600)):
            raise ValueError("credential_descriptor")
        note("credential_format", descriptor)
        value = os.read(fd, 65)
        if re.fullmatch(b"[0-9a-f]{64}", value) is None:
            raise ValueError("credential_format")
        note("credential_content", descriptor)
        if not hmac.compare_digest(hashlib.sha256(value).hexdigest(), expected_digest):
            raise ValueError("credential_content")
        note("success_marker", descriptor)
        report("credential_valid", {"uid": meta.st_uid, "mode": stat.S_IMODE(meta.st_mode),
               "links": meta.st_nlink, "inode": meta.st_ino, "device": meta.st_dev,
               "ctime_ns": meta.st_ctime_ns})
    finally:
        os.close(fd)

def main():
    observation = {"stage": "manifest_open", "descriptor": None}
    def note(stage, descriptor=None):
        observation.update(stage=stage, descriptor=descriptor)
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            note("manifest_parse")
            manifest = json.load(stream)
        note("identity")
        if os.geteuid() != manifest["uid"] or os.geteuid() == 0:
            raise ValueError("identity")
        note("runtime_paths")
        credential_dir = os.environ.get("CREDENTIALS_DIRECTORY")
        runtime_dir = os.environ.get("RUNTIME_DIRECTORY")
        if credential_dir != manifest["credential_dir"] or runtime_dir != manifest["runtime_dir"]:
            raise ValueError("runtime_paths")
        note("runtime_descriptor")
        runtime_meta = os.lstat(runtime_dir)
        if (not stat.S_ISDIR(runtime_meta.st_mode) or runtime_meta.st_uid != os.geteuid()
                or stat.S_IMODE(runtime_meta.st_mode) != 0o700):
            raise ValueError("runtime_descriptor")
        def report(category, details):
            marker = os.path.join(runtime_dir, "result.json")
            fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump({"category": category, "credential": details,
                           "uid": os.geteuid(), "generation": os.getpid()}, stream)
                stream.flush()
                os.fsync(stream.fileno())
            print("credential_valid", flush=True)
        validate_and_report(os.path.join(credential_dir, "synthetic"), os.geteuid(),
                            manifest["expected_digest"], report, observe=note)
        time.sleep(20)
        return 0
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        print(json.dumps({"v": 1, "category": "credential_validation_failed",
                          **observation}, separators=(",", ":")), flush=True)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
'''


class CredentialHelperTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'credential'
        self.value = os.urandom(32).hex().encode()
        self.path.write_bytes(self.value)
        self.path.chmod(0o400)
        self.digest = hashlib.sha256(self.value).hexdigest()
        module = {'__name__': 'inert_helper_test'}
        exec(compile(HELPER, '<inert-helper>', 'exec'), module)
        self.validate = module['validate_and_report']
        self.events = []

    def invoke(self, path=None, uid=None, digest=None):
        self.validate(path or self.path, os.geteuid() if uid is None else uid,
                      digest or self.digest,
                      lambda category, details: self.events.append((category, details)))

    def reject(self, **kwargs):
        with self.assertRaises((OSError, ValueError)):
            self.invoke(**kwargs)
        self.assertEqual(self.events, [])

    def test_malformed_does_not_emit_success(self):
        self.path.chmod(0o600)
        self.path.write_bytes(self.value[:-1])
        self.path.chmod(0o400)
        self.reject()

    def test_private_valid_credential_emits_only_safe_result(self):
        self.invoke()
        self.assertEqual(self.events[0][0], 'credential_valid')
        self.assertEqual(self.events[0][1]['uid'], os.geteuid())
        self.assertNotIn(self.value.decode(), repr(self.events))
        self.assertNotIn(self.digest, repr(self.events))

    def test_world_readable_rejected(self):
        self.path.chmod(0o444)
        self.reject()

    def test_wrong_owner_rejected(self):
        self.reject(uid=os.geteuid() + 10000)

    def test_wrong_digest_rejected(self):
        self.reject(digest='0' * 64)

    def test_missing_rejected(self):
        self.path.unlink()
        self.reject()

    def test_symlink_rejected(self):
        link = self.path.parent / 'symlink'
        link.symlink_to(self.path)
        self.reject(path=link)

    def test_multiple_links_rejected(self):
        os.link(self.path, self.path.parent / 'hardlink')
        self.reject()

    def test_descriptor_observation_precedes_unchanged_strict_rejection(self):
        self.path.chmod(0o444)
        observed = []
        with self.assertRaises(ValueError):
            self.validate(self.path, os.geteuid(), self.digest,
                          lambda category, details: self.events.append((category, details)),
                          observe=lambda stage, descriptor: observed.append((stage, descriptor)))
        self.assertEqual(self.events, [])
        self.assertTrue(observed, 'safe descriptor observation must survive strict rejection')
        stage, descriptor = observed[-1]
        self.assertEqual(stage, 'credential_descriptor')
        self.assertEqual(descriptor['uid'], os.geteuid())
        self.assertEqual(descriptor['mode'], 0o444)
        self.assertEqual(descriptor['nlink'], 1)
        self.assertEqual(descriptor['type'], stat.S_IFREG)
        self.assertNotIn(self.value.decode(), repr(observed))
        self.assertNotIn(self.digest, repr(observed))

    def test_readonly_group_mask_is_still_rejected(self):
        self.path.chmod(0o440)
        self.reject()

    def test_observer_exception_does_not_change_strict_rejection(self):
        self.path.chmod(0o440)
        def broken_observer(stage, descriptor):
            raise RuntimeError('synthetic_observer_failure')
        with self.assertRaises(ValueError):
            self.validate(self.path, os.geteuid(), self.digest,
                          lambda category, details: self.events.append((category, details)),
                          observe=broken_observer)
        self.assertEqual(self.events, [])


def fixture_directory(path, mode, uid, gid):
    path.mkdir(mode=0o700)
    initial = path.lstat()
    if (not stat.S_ISDIR(initial.st_mode) or initial.st_uid != os.geteuid()
            or stat.S_IMODE(initial.st_mode) != 0o700):
        raise SliceFailure('exclusive_case_directory_required')
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    actual = path.lstat()
    if actual.st_uid != uid or actual.st_gid != gid or stat.S_IMODE(actual.st_mode) != mode:
        raise SliceFailure('case_directory_metadata_mismatch')


FAILURE_STAGES = frozenset(('manifest_open', 'manifest_parse', 'identity', 'runtime_paths',
                            'runtime_descriptor', 'credential_open', 'credential_descriptor',
                            'credential_format', 'credential_content', 'success_marker'))


def parse_helper_output(output):
    """Allowlist bounded stdout; arbitrary JSON, paths and raw exceptions never escape."""
    if len(output) > 4096 or len(output.splitlines()) > 4:
        return None
    normalized = []
    diagnostics = []
    for line in output.splitlines():
        if line in (b'credential_valid', b'credential_validation_failed'):
            normalized.append(line.decode('ascii'))
            continue
        try:
            def unique_object(pairs):
                result = {}
                for key, value in pairs:
                    if key in result:
                        raise ValueError('duplicate_key')
                    result[key] = value
                return result
            item = json.loads(line, object_pairs_hook=unique_object)
        except (ValueError, UnicodeError):
            return None
        if (not isinstance(item, dict) or set(item) != {'v', 'category', 'stage', 'descriptor'}
                or type(item['v']) is not int or item['v'] != 1
                or item['category'] != 'credential_validation_failed'
                or not isinstance(item['stage'], str) or item['stage'] not in FAILURE_STAGES):
            return None
        descriptor = item['descriptor']
        if descriptor is not None:
            required = {'uid', 'mode', 'nlink', 'type'}
            if not isinstance(descriptor, dict) or set(descriptor) != required:
                return None
            bounds = {'uid': (0, 2**32 - 1), 'mode': (0, 0o7777), 'nlink': (0, 2**32 - 1),
                      'type': (0, 0o170000)}
            if any(type(descriptor[key]) is not int or not low <= descriptor[key] <= high
                   for key, (low, high) in bounds.items()):
                return None
        diagnostics.append(item)
        normalized.append(json.dumps(item, sort_keys=True, separators=(',', ':')))
    return {'helper_output': ''.join(line + '\n' for line in normalized),
            'helper_diagnostics': diagnostics, 'helper_output_kind': 'allowlisted_normalized'}


def retain_helper_output(path, entry):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('regular_output_required')
            output = stream.read(4097)
        parsed = parse_helper_output(output)
        if parsed is None:
            entry['helper_output'] = 'unrecognized_helper_output'
            entry['helper_output_bytes'] = len(output)
        else:
            entry.update(parsed)
    except (OSError, ValueError):
        entry['helper_output'] = 'output_unavailable'


class FixtureObservationTests(unittest.TestCase):
    def test_requested_traverse_mode_survives_private_umask(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'case'
            previous = os.umask(0o077)
            try:
                fixture_directory(path, 0o750, os.geteuid(), os.getegid())
            finally:
                os.umask(previous)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o750)

    def test_early_helper_failure_survives_fixture_cleanup(self):
        entry = {'result': 'RUNNING'}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'output.log'
            path.write_text('credential_validation_failed\n')
            retain_helper_output(path, entry)
        self.assertEqual(entry.get('helper_output'), 'credential_validation_failed\n')

    def test_structured_failure_survives_early_cleanup(self):
        event = {'v': 1, 'category': 'credential_validation_failed',
                 'stage': 'credential_descriptor',
                 'descriptor': {'uid': 0, 'mode': 0o440, 'nlink': 1,
                                'type': stat.S_IFREG}}
        entry = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'output.log'
            path.write_text(json.dumps(event) + '\n')
            retain_helper_output(path, entry)
        self.assertEqual(entry.get('helper_diagnostics'), [event])

    def test_diagnostic_parser_rejects_extra_private_or_untyped_fields(self):
        event = {'v': 1, 'category': 'credential_validation_failed',
                 'stage': 'credential_descriptor',
                 'descriptor': {'uid': 0, 'mode': 0o440, 'nlink': 1, 'type': stat.S_IFREG}}
        malformed = []
        for key, value in (('path', '/private/synthetic'), ('digest', 'private-digest'),
                           ('stage', 'native arbitrary error'), ('v', True)):
            malformed.append({**event, key: value})
        for key, value in (('uid', True), ('mode', '0440'), ('acl_present', 'true'),
                           ('acl_named_ids', [1234]), ('uid', -1)):
            malformed.append({**event, 'descriptor': {**event['descriptor'], key: value}})
        for item in malformed:
            self.assertIsNone(parse_helper_output(json.dumps(item).encode()))
        self.assertIsNone(parse_helper_output(b'{"v":1,"v":1}'))
        self.assertIsNone(parse_helper_output(b'x' * 4097))
        self.assertIsNone(parse_helper_output(b'credential_valid\n' * 5))

    def test_diagnostic_plan_is_exactly_one_system_good_fixture(self):
        cases = fixture_specs('f' * 32, os.geteuid(), Path('/var/tmp/cred-audit-test'), diagnostic=True)
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0]['manager'], 'system')
        self.assertEqual(cases[0]['scenario'], 'good')
        self.assertIn('-diagnostic-', cases[0]['unit'])


PROPERTIES = {
    'Type': 'exec', 'RuntimeDirectoryMode': '0700', 'UMask': '0077',
    'NoNewPrivileges': 'yes', 'LimitCORE': '0', 'TasksMax': '4',
    'MemoryMax': '64M', 'RuntimeMaxSec': '30', 'TimeoutStopSec': '3',
    'TimeoutStartSec': '5', 'Restart': 'no',
    'RestrictAddressFamilies': 'AF_UNIX', 'SystemCallFilter': '~@network-io',
    'StandardError': 'inherit',
}
SHOW_PROPERTIES = (
    'LoadState', 'ActiveState', 'SubState', 'MainPID', 'ExecMainCode',
    'ExecMainStatus', 'Result', 'User', 'Group', 'RuntimeDirectory',
    'RuntimeDirectoryMode', 'UMask', 'NoNewPrivileges', 'LimitCORE',
    'TasksMax', 'MemoryMax', 'RuntimeMaxUSec', 'TimeoutStopUSec', 'Restart',
    'RestrictAddressFamilies', 'SystemCallFilter', 'LoadCredential', 'CollectMode',
    'ActiveEnterTimestampMonotonic', 'ExecMainStartTimestampMonotonic',
)


class SliceFailure(RuntimeError):
    """Fixed category only; never include credential content or expected digest."""


def fixture_specs(run_id, uid, fixture_root, diagnostic=False):
    cases = []
    selected = [('system', 'good')] if diagnostic else [
        (manager, scenario) for manager in ('system', 'user') for scenario in ('good', 'missing', 'malformed')]
    for manager, scenario in selected:
        label = 'diagnostic' if diagnostic else scenario
        stem = 'cred-audit-' + manager + '-' + label + '-' + run_id
        runtime_base = Path('/run') if manager == 'system' else Path('/run/user') / str(uid)
        cases.append({'manager': manager, 'scenario': scenario, 'unit': stem + '.service',
                      'stem': stem, 'runtime_dir': str(runtime_base / stem),
                      'credential_dir': str(runtime_base / 'credentials' / (stem + '.service')),
                      'fixture_dir': str(fixture_root / (manager + '-' + scenario))})
    return cases


def integration(evidence, diagnostic=False):
    """Six-fixture acceptance OR one separate non-acceptance diagnostic.

    Run as root only via the already authorized local sudo capability. The user
    manager receives commands as existing codex; the system unit uses User=codex.
    The helper and every created path/name are exclusively owned by this run.
    Diagnostic mode runs only one system-good helper, without a restart. Its
    observed failure or lack of failure cannot mark any acceptance gate PASS.
    """
    account = pwd.getpwnam('codex')
    uid, gid = account.pw_uid, account.pw_gid
    if os.geteuid() != 0 or uid == 0 or os.environ.get('SUDO_UID') != str(uid):
        raise SliceFailure('explicit_codex_sudo_invocation_required')
    evidence = Path(evidence)
    allowed = Path('/home/codex/paranoid-self-service-evidence')
    if (not evidence.is_absolute() or allowed not in evidence.parents
            or evidence.resolve() != evidence or evidence.stat().st_uid != uid):
        raise SliceFailure('owned_evidence_directory_required')
    evidence = evidence / 'runtime'
    evidence.mkdir(mode=0o700)
    os.chown(evidence, uid, gid)
    os.umask(0o077)
    run_id = secrets.token_hex(16)
    fixture_root = Path('/var/tmp') / ('cred-audit-' + run_id)
    cases = fixture_specs(run_id, uid, fixture_root, diagnostic=diagnostic)
    result = {'scope': 'inert systemd primitive only; no coturn, sockets, namespaces, firewall or accounts',
              'purpose': 'single failure diagnostic, not acceptance' if diagnostic else 'bounded primitive acceptance',
              'helper_sha256': hashlib.sha256(HELPER.encode()).hexdigest(),
              'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'run_id': run_id, 'cases': [{**case, 'result': 'NOT_RUN'} for case in cases],
              'commands': [], 'cleanup': {}, 'result': 'RUNNING',
              'TURN_RT01': 'NOT_RUN', 'TURN_ACL02': 'NOT_RUN',
              'relay_unit_cli_lifecycle': 'NOT_RUN'}
    private_values = []
    created = []
    stop_attempted = set()
    owned_root_identity = None

    def safe_text(value):
        if any(secret.decode() in value for secret in private_values):
            raise SliceFailure('unexpected_private_material_in_output')
        return value

    def save(name, value):
        data = json.dumps(value, indent=2) + '\n'
        safe_text(data)
        path = evidence / name
        temporary = evidence / ('.' + name + '.tmp')
        with temporary.open('x') as output:
            output.write(data)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)

    def command(args, label, manager=None, timeout=10):
        if manager == 'user':
            args = ['sudo', '-n', '-u', 'codex', 'env',
                    'XDG_RUNTIME_DIR=/run/user/' + str(uid),
                    'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + str(uid) + '/bus',
                    *args]
        try:
            completed = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            result['commands'].append({'label': label, 'argv': args, 'result': 'TIMEOUT'})
            save('result.json', result)
            raise SliceFailure('bounded_command_timeout') from None
        record = {'label': label, 'argv': args, 'exit_code': completed.returncode,
                  'stdout': safe_text(completed.stdout), 'stderr': safe_text(completed.stderr)}
        result['commands'].append(record)
        save('result.json', result)
        return completed

    def control(case, verb):
        args = ['systemctl'] + (['--user'] if case['manager'] == 'user' else [])
        return command([*args, verb, case['unit']], verb + ':' + case['unit'], case['manager'])

    def show(case, label):
        args = ['systemctl'] + (['--user'] if case['manager'] == 'user' else [])
        response = command([*args, 'show', case['unit'],
                            '--property=' + ','.join(SHOW_PROPERTIES)],
                           label + ':' + case['unit'], case['manager'])
        if response.returncode not in (0, 4):
            raise SliceFailure('manager_property_read_refused')
        return dict(line.split('=', 1) for line in response.stdout.splitlines() if '=' in line)

    def private_file(path, data, owner, group, mode):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(path, owner, group)
        os.chmod(path, mode)

    def wait_marker(case):
        path = Path(case['runtime_dir']) / 'result.json'
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.is_file() and path.stat().st_size:
                try:
                    value = json.loads(path.read_text())
                except json.JSONDecodeError:
                    time.sleep(0.025)
                    continue
                if value.get('category') != 'credential_valid' or value.get('uid') != uid:
                    raise SliceFailure('unexpected_helper_result')
                return value
            time.sleep(0.05)
        raise SliceFailure('success_marker_not_observed')

    def live_evidence(case):
        marker = wait_marker(case)
        properties = show(case, 'live')
        pid = int(properties.get('MainPID', '0'))
        if (properties.get('ActiveState') != 'active' or properties.get('SubState') != 'running'
                or pid <= 0 or pid != marker['generation']):
            raise SliceFailure('live_identity_mismatch')
        expected = {'RestrictAddressFamilies': 'AF_UNIX', 'NoNewPrivileges': 'yes',
                    'RuntimeDirectoryMode': '0700', 'UMask': '0077', 'MemoryMax': '67108864',
                    'TasksMax': '4', 'LimitCORE': '0', 'Restart': 'no'}
        if any(properties.get(key) != value for key, value in expected.items()):
            raise SliceFailure('required_property_not_effective')
        filters = properties.get('SystemCallFilter', '')
        if not filters.startswith('~') or not ('@network-io' in filters or 'socket' in filters.split()):
            raise SliceFailure('required_network_syscall_filter_not_effective')
        proc = Path('/proc') / str(pid)
        cmdline = (proc / 'cmdline').read_bytes()
        environ = (proc / 'environ').read_bytes()
        process_status = (proc / 'status').read_text()
        fields = dict(line.split(':', 1) for line in process_status.splitlines() if ':' in line)
        if (str(uid) != fields['Uid'].split()[1] or fields['NoNewPrivs'].strip() != '1'
                or fields['Seccomp'].strip() != '2'):
            raise SliceFailure('helper_identity_or_confinement_mismatch')
        if str(fixture_root / 'helper.py').encode() not in cmdline:
            raise SliceFailure('owned_process_command_mismatch')
        log = Path(case['fixture_dir']) / 'output.log'
        output = log.read_bytes()
        leaks = any(value in cmdline or value in environ or value in output for value in private_values)
        if leaks:
            raise SliceFailure('private_material_exposed')
        return {'properties': properties, 'marker': marker,
                'private_material_absent_argv_environ_output': True,
                'actual_euid_matches': True, 'NoNewPrivs': 1, 'Seccomp': 2,
                'output': safe_text(output.decode())}

    def stop_and_check(case):
        properties = show(case, 'before-stop')
        pid = int(properties.get('MainPID', '0'))
        if properties.get('LoadState') != 'not-found':
            if case['unit'] in stop_attempted:
                raise SliceFailure('stop_already_attempted_no_retry')
            stop_attempted.add(case['unit'])
            stopped = control(case, 'stop')
            if stopped.returncode != 0:
                raise SliceFailure('owned_unit_stop_refused')
        after = show(case, 'after-stop')
        clean = (after.get('LoadState') == 'not-found' and int(after.get('MainPID', '0')) == 0
                 and not Path(case['runtime_dir']).exists()
                 and not Path(case['credential_dir']).exists()
                 and (pid == 0 or not (Path('/proc') / str(pid)).exists()))
        return {'clean': clean, 'properties': after, 'former_main_pid_absent': pid == 0 or not (Path('/proc') / str(pid)).exists(),
                'runtime_absent': not Path(case['runtime_dir']).exists(),
                'credential_directory_absent': not Path(case['credential_dir']).exists()}

    neighbors = [{'manager': 'system', 'unit': 'nginx.service'},
                 {'manager': 'system', 'unit': 'paranoid-turn.service'},
                 {'manager': 'user', 'unit': 'paranoid-alpha.service'}]
    try:
        # Freeze the finite fixture list before any privileged service creation.
        save('plan.json', {'cases': cases, 'fixed_properties': PROPERTIES,
                           'fixture_root': str(fixture_root), 'positive_restart_count': 0 if diagnostic else 1,
                           'negative_executions_per_name': 0 if diagnostic else 1})
        for case in cases:
            if show(case, 'preflight')['LoadState'] != 'not-found':
                raise SliceFailure('preexisting_fixture_unit')
        result['neighbors_before'] = {case['manager'] + ':' + case['unit']: show(case, 'neighbor-before')
                                      for case in neighbors}
        fixture_root.mkdir(mode=0o700)
        initial = fixture_root.lstat()
        if not stat.S_ISDIR(initial.st_mode) or initial.st_uid != 0 or stat.S_IMODE(initial.st_mode) != 0o700:
            raise SliceFailure('exclusive_root_ownership')
        owned_root_identity = (initial.st_dev, initial.st_ino)
        os.chown(fixture_root, 0, gid)
        os.chmod(fixture_root, 0o750)
        private_file(fixture_root / 'helper.py', HELPER.encode(), 0, gid, 0o440)
        for index, case in enumerate(cases):
            entry = result['cases'][index]
            case_root = Path(case['fixture_dir'])
            system = case['manager'] == 'system'
            fixture_directory(case_root, 0o750 if system else 0o700, 0 if system else uid, gid)
            source_dir = case_root / 'private'
            source_dir.mkdir(mode=0o700)
            os.chown(source_dir, 0 if system else uid, 0 if system else gid)
            value = secrets.token_hex(32).encode()
            if case['scenario'] == 'malformed':
                value = value[:-1]
            expected_digest = hashlib.sha256(value).hexdigest()
            private_values.extend((value, expected_digest.encode()))
            source = source_dir / 'synthetic'
            if case['scenario'] != 'missing':
                private_file(source, value, 0 if system else uid, 0 if system else gid, 0o400)
                meta = source.lstat()
                entry['source_descriptor'] = {'uid': meta.st_uid, 'mode': stat.S_IMODE(meta.st_mode),
                                              'links': meta.st_nlink, 'bytes': meta.st_size}
                if (meta.st_uid != (0 if system else uid) or stat.S_IMODE(meta.st_mode) != 0o400
                        or meta.st_nlink != 1 or not stat.S_ISREG(meta.st_mode)):
                    raise SliceFailure('source_descriptor_mismatch')
            manifest = {'uid': uid, 'expected_digest': expected_digest,
                        'runtime_dir': case['runtime_dir'], 'credential_dir': case['credential_dir']}
            manifest_path = case_root / 'manifest.json'
            private_file(manifest_path, json.dumps(manifest).encode(), 0 if system else uid, gid,
                         0o440 if system else 0o400)
            log = case_root / 'output.log'
            private_file(log, b'', 0 if system else uid, gid, 0o600)
            props = {**PROPERTIES, 'RuntimeDirectory': case['stem'],
                     'LoadCredential': 'synthetic:' + str(source), 'StandardOutput': 'append:' + str(log)}
            if system:
                props.update(User='codex', Group='codex')
            argv = ['systemd-run'] + (['--user'] if not system else [])
            argv += ['--collect', '--unit=' + case['unit']]
            if case['scenario'] != 'good':
                argv.append('--wait')
            argv += ['--property=' + key + '=' + value for key, value in props.items()]
            argv += ['/usr/bin/python3', '-I', '-B', str(fixture_root / 'helper.py'), str(manifest_path)]
            created.append(case)
            entry['result'] = 'RUNNING'
            response = command(argv, 'start:' + case['unit'], case['manager'], timeout=12)
            if diagnostic:
                if response.returncode:
                    entry['refusal'] = {'exit_code': response.returncode, 'stderr': safe_text(response.stderr)}
                    raise SliceFailure('diagnostic_start_refused_no_retry')
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if log.stat().st_size:
                        break
                    time.sleep(0.05)
                retain_helper_output(log, entry)
                entry['manager_after_observation'] = show(case, 'diagnostic-observation')
                if entry.get('helper_diagnostics'):
                    entry['result'] = 'DIAGNOSTIC_FAILURE_OBSERVED'
                elif entry.get('helper_output') == 'credential_valid\n':
                    entry['result'] = 'DIAGNOSTIC_NO_FAILURE_OBSERVED'
                else:
                    raise SliceFailure('diagnostic_output_unavailable')
                entry['acceptance'] = 'NOT_RUN_DIAGNOSTIC_ONLY'
            elif case['scenario'] == 'good':
                if response.returncode:
                    entry['refusal'] = {'exit_code': response.returncode,
                                        'stderr': safe_text(response.stderr)}
                    raise SliceFailure('positive_unit_start_refused_no_retry')
                entry['first_start'] = live_evidence(case)
                restarted = control(case, 'restart')
                if restarted.returncode:
                    raise SliceFailure('planned_restart_refused_no_retry')
                entry['after_restart'] = live_evidence(case)
                first, second = entry['first_start']['marker'], entry['after_restart']['marker']
                if first['generation'] == second['generation'] or first['credential'] == second['credential']:
                    raise SliceFailure('restart_did_not_regenerate_process_and_credential')
                entry['prior_pid_absent_after_restart'] = not (Path('/proc') / str(first['generation'])).exists()
                if not entry['prior_pid_absent_after_restart']:
                    raise SliceFailure('previous_helper_process_retained')
                entry['credential_regenerated'] = True
            else:
                entry['execution_exit_code'] = response.returncode
                retain_helper_output(log, entry)
                entry['output'] = entry['helper_output']
                if response.returncode == 0 or (Path(case['runtime_dir']) / 'result.json').exists():
                    raise SliceFailure('negative_fixture_did_not_fail_closed')
                malformed_observed = (entry['output'].strip() == 'credential_validation_failed'
                                      or any(item['stage'] == 'credential_format'
                                             for item in entry.get('helper_diagnostics', [])))
                if case['scenario'] == 'malformed' and not malformed_observed:
                    raise SliceFailure('malformed_helper_failure_not_observed')
                if case['scenario'] == 'missing' and entry['output']:
                    raise SliceFailure('missing_source_unexpected_helper_output')
                entry['no_success_marker'] = True
            entry['cleanup'] = stop_and_check(case)
            if not entry['cleanup']['clean']:
                raise SliceFailure('owned_runtime_cleanup_incomplete')
            if not diagnostic:
                entry['result'] = 'PASS'
            save('result.json', result)
        result['result'] = 'DIAGNOSTIC_COMPLETE' if diagnostic else 'PASS'
    except (OSError, ValueError, KeyError, SliceFailure) as error:
        result['result'] = 'STOPPED'
        result['failure_category'] = str(error) if isinstance(error, SliceFailure) else type(error).__name__
        for entry in result['cases']:
            if entry['result'] == 'RUNNING':
                retain_helper_output(Path(entry['fixture_dir']) / 'output.log', entry)
                entry['result'] = 'STOPPED'
        save('result.json', result)
    finally:
        for case in created:
            key = case['manager'] + ':' + case['unit']
            # A completed fixture already has verified cleanup; never stop twice.
            entry = next(item for item in result['cases'] if item['unit'] == case['unit'])
            if entry.get('cleanup', {}).get('clean'):
                result['cleanup'][key] = entry['cleanup']
                continue
            try:
                result['cleanup'][key] = stop_and_check(case)
            except (OSError, ValueError, KeyError, SliceFailure) as error:
                result['cleanup'][key] = {'clean': False, 'failure_category': type(error).__name__}
        if owned_root_identity is not None:
            current = fixture_root.lstat()
            if ((current.st_dev, current.st_ino) == owned_root_identity
                    and stat.S_ISDIR(current.st_mode) and current.st_uid == 0
                    and shutil.rmtree.avoids_symlink_attacks):
                shutil.rmtree(fixture_root)
                result['fixture_sources_removed'] = not fixture_root.exists()
            else:
                result['fixture_sources_removed'] = False
        result['neighbors_after'] = {case['manager'] + ':' + case['unit']: show(case, 'neighbor-after')
                                     for case in neighbors}
        result['neighbors_unchanged'] = result.get('neighbors_before') == result['neighbors_after']
        save('result.json', result)
    return 0 if result['result'] in ('PASS', 'DIAGNOSTIC_COMPLETE') and result['neighbors_unchanged'] else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--diagnostic':
        raise SystemExit(integration(sys.argv[2], diagnostic=True))
    if len(sys.argv) == 3 and sys.argv[1] == '--integration':
        raise SystemExit(integration(sys.argv[2]))
    unittest.main()
