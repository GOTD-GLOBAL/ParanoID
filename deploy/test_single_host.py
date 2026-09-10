"""REQ-DEPLOY-003: pure planning and immutable profile safety, no host services."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('single_host', HERE / 'single_host.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class IntentTests(unittest.TestCase):
    def fixture(self):
        return {'v': 1, 'profile': installer.FIXTURE, 'mode': 'fresh',
                'ip': '127.0.0.23', 'kit_sha256': 'a' * 64, 'expected': None,
                'message': {'user': 'codex', 'uid': os.geteuid(), 'gid': os.getegid(),
                            'root': '/var/tmp/paranoid-fixture-aabbccdd',
                            'unit': 'paranoid-alpha-fixture-aabbccdd.service'}}

    def test_fixture_rejects_public_address_production_names_and_network_keys(self):
        original = self.fixture()
        installer.validate_intent(original)
        cases = [{**original, 'ip': '157.180.49.125'},
                 {**original, 'interface': 'enp5s0'},
                 {**original, 'message': {**original['message'], 'root': '/home/paranoid/paranoid-alpha'}},
                 {**original, 'message': {**original['message'], 'unit': 'paranoid-alpha.service'}}]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                installer.validate_intent(value)

    def test_existing_requires_explicit_complete_identity(self):
        with self.assertRaises(ValueError):
            installer.validate_intent({**self.fixture(), 'mode': 'existing-v8'})

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaises(ValueError):
            installer.decode_json(b'{"v":1,"v":2}')

    def test_profile_gate_lists_are_fixed_and_fixture_cannot_satisfy_production(self):
        self.assertEqual(installer.GATES[installer.FIXTURE],
                         ('design-review', 'offline-tests', 'artifact-verification'))
        self.assertIn('turn-rt01', installer.GATES[installer.PRODUCTION])
        self.assertIn('local-loopback-acceptance', installer.GATES[installer.PRODUCTION])
        self.assertNotIn('coordinated-full-rehearsal', installer.GATES[installer.PRODUCTION])
        receipt = {'v': 1, 'profile': installer.FIXTURE, 'kit_sha256': 'a' * 64, 'plan_sha256': 'c' * 64,
                   'gates': {name: {'result': 'PASS', 'evidence_sha256': 'b' * 64}
                             for name in installer.GATES[installer.FIXTURE]}}
        installer.validate_acceptance(receipt, installer.FIXTURE, 'a' * 64, 'c' * 64)
        with self.assertRaises(ValueError):
            installer.validate_acceptance(receipt, installer.PRODUCTION, 'a' * 64, 'c' * 64)
        with self.assertRaises(ValueError):
            installer.validate_acceptance(receipt, installer.FIXTURE, 'a' * 64, 'd' * 64)
        receipt['gates']['offline-tests']['result'] = 'NOT RUN'
        with self.assertRaises(ValueError):
            installer.validate_acceptance(receipt, installer.FIXTURE, 'a' * 64, 'c' * 64)

    def test_read_refuses_symlink_hardlink_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-installer-unit-') as raw:
            root = Path(raw)
            source = root / 'source'
            source.write_bytes(b'preserve')
            source.chmod(0o600)
            alias = root / 'alias'
            alias.symlink_to(source)
            with self.assertRaises((ValueError, OSError)):
                installer.read_file(alias)
            alias.unlink()
            os.link(source, alias)
            with self.assertRaises((ValueError, OSError)):
                installer.read_file(source)
            self.assertEqual(source.read_bytes(), b'preserve')

    def test_lock_never_replaces_redirected_path(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-installer-unit-') as raw:
            root = Path(raw)
            source = root / 'source'
            source.write_bytes(b'preserve')
            source.chmod(0o600)
            target = root / 'operator.lock'
            target.symlink_to(source)
            with self.assertRaises((ValueError, OSError)):
                with installer.exclusive_lock(target):
                    self.fail('redirected lock accepted')
            self.assertEqual(source.read_bytes(), b'preserve')
            self.assertTrue(target.is_symlink())


class KitTests(unittest.TestCase):
    def test_fixture_members_exclude_all_relay_and_network_code(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-installer-kit-') as raw:
            root = Path(raw)
            message = root / 'message'
            message.mkdir(mode=0o700)
            content = b'synthetic immutable message component'
            (message / 'alpha.py').write_bytes(content)
            hashes = {'alpha.py': installer.sha(content)}
            manifest = {'release': installer.component_id(hashes), 'sha256': hashes}
            (message / 'manifest.json').write_bytes(installer.canonical(manifest))
            code = root / 'code'
            code.mkdir(mode=0o700)
            for name in installer.BASE_FILES:
                (code / name).write_text('fixture ' + name)
            target = root / 'kit'
            result = installer.build_kit(installer.FIXTURE, message, None, target, code)
            installer.verify_kit(target)
            self.assertEqual(result['profile'], installer.FIXTURE)
            self.assertFalse((target / 'relay').exists())
            self.assertFalse((target / 'single_host_network.py').exists())
            (target / 'single_host_network.py').write_text('unrequested network code')
            with self.assertRaises(ValueError):
                installer.verify_kit(target)
            self.assertEqual((message / 'alpha.py').read_bytes(), content)

    def test_modified_component_and_existing_output_refuse(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-installer-kit-') as raw:
            root = Path(raw)
            component = root / 'message'
            component.mkdir(mode=0o700)
            (component / 'alpha.py').write_bytes(b'changed')
            hashes = {'alpha.py': installer.sha(b'original')}
            (component / 'manifest.json').write_bytes(installer.canonical(
                {'release': installer.component_id(hashes), 'sha256': hashes}))
            with self.assertRaises(ValueError):
                installer.verify_component(component)


class CoordinatorBoundaryTests(unittest.TestCase):
    def test_network_status_requires_all_real_enforcement_state(self):
        intent = {'profile': installer.PRODUCTION, 'ip': installer.PUBLIC_IP,
                  'interface': 'enp5s0', 'relay': {'uid': 1999}}
        network = installer.network_module(HERE)
        ids = [r['id'] for r in network.desired_ufw_rules(installer.network_spec(intent))]
        exact = {'egress': 'present', 'ingress': ids, 'pending': None}
        installer.require_network_active(intent, HERE, exact)
        for changed in ({**exact, 'egress': 'absent'}, {**exact, 'ingress': ids[:-1]},
                        {**exact, 'pending': {'op': 'apply'}}):
            with self.assertRaises(ValueError):
                installer.require_network_active(intent, HERE, changed)

    def test_network_mutation_uses_locking_helper_cli(self):
        from unittest.mock import patch
        value = {'kit_path': str(HERE), 'intent': {'profile': installer.PRODUCTION,
                 'ip': installer.PUBLIC_IP, 'interface': 'enp5s0', 'relay': {'uid': 1999}}}
        with patch.object(installer, 'command', return_value=b'{"v":1}') as invoked:
            installer.coordinated_network(Path('/var/lib/paranoid-single-host'), value, 'apply')
        argv = invoked.call_args.args[0]
        self.assertEqual(argv[:3], ['/usr/bin/python3', '-I', '-B'])
        self.assertIn('single_host_network.py', str(argv[3]))
        self.assertIn('--receipt', argv)
        self.assertIn('apply', argv)

    def test_failed_recovery_reports_incomplete_and_attempts_independent_stops(self):
        from unittest.mock import patch
        value = {'phase': 'message-intent'}
        with patch.object(installer, 'stop_owned', return_value={'relay_stopped': False, 'message_stopped': True}) as stop, \
                patch.object(installer, 'save_state'):
            result = installer.record_incomplete_recovery(Path('/var/tmp/unused'), value)
        stop.assert_called_once()
        self.assertEqual(value['phase'], 'recovery-incomplete')
        self.assertFalse(result['relay_stopped'])


class StickyCreationTests(unittest.TestCase):
    def test_exclusive_private_state_below_root_owned_sticky_parent(self):
        import secrets
        root = Path('/var/tmp') / ('paranoid-coordinator-unit-' + secrets.token_hex(12))
        try:
            installer.make_private(root)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            installer.trusted_directory(root, os.geteuid(), private=True)
        finally:
            if root.exists():
                root.rmdir()


class FullRehearsalBoundaryTests(unittest.TestCase):
    def loopback_report(self):
        return {'gates': ['TURN-RT01', 'TURN-ACL02'],
                'scope': 'loopback-only local acceptance',
                'binding': {'turnserver_sha256': 'e' * 64, 'git_head': 'f' * 40},
                'cases': [{'name': f'case-{n}', 'result': 'PASS', 'observed': {'n': n}}
                          for n in range(6)],
                'overall': 'PASS'}

    def receipt(self, evidence_path, evidence_sha):
        gates = {name: {'result': 'PASS', 'evidence_sha256': 'b' * 64}
                 for name in installer.GATES[installer.PRODUCTION]}
        gates['local-loopback-acceptance'] = {'result': 'PASS', 'evidence_sha256': evidence_sha,
                                              'evidence_path': evidence_path}
        gates['turn-rt01']['evidence_sha256'] = evidence_sha
        gates['turn-acl02']['evidence_sha256'] = evidence_sha
        return {'v': 1, 'profile': installer.PRODUCTION, 'kit_sha256': 'a' * 64,
                'plan_sha256': 'c' * 64, 'gates': gates}

    def test_loopback_gate_requires_real_bound_executed_report(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-loopback-unit-') as raw:
            root = Path(raw)
            root.chmod(0o700)
            path = root / 'results.json'
            data = installer.canonical(self.loopback_report())
            path.write_bytes(data)
            good = self.receipt(str(path), installer.sha(data))
            installer.validate_acceptance(good, installer.PRODUCTION, 'a' * 64, 'c' * 64)
            with self.assertRaises(ValueError):
                installer.validate_acceptance(self.receipt(str(path), 'd' * 64),
                                              installer.PRODUCTION, 'a' * 64, 'c' * 64)
            with self.assertRaises((ValueError, OSError)):
                installer.validate_acceptance(self.receipt(str(root / 'absent.json'), installer.sha(data)),
                                              installer.PRODUCTION, 'a' * 64, 'c' * 64)
            failed = self.loopback_report()
            failed['cases'][0]['result'] = 'FAIL'
            bad = installer.canonical(failed)
            path.write_bytes(bad)
            with self.assertRaisesRegex(ValueError, 'complete executed loopback'):
                installer.validate_acceptance(self.receipt(str(path), installer.sha(bad)),
                                              installer.PRODUCTION, 'a' * 64, 'c' * 64)
            path.write_bytes(data)
            unbound = self.receipt(str(path), installer.sha(data))
            unbound['gates']['turn-rt01']['evidence_sha256'] = 'b' * 64
            with self.assertRaisesRegex(ValueError, 'reference the loopback'):
                installer.validate_acceptance(unbound, installer.PRODUCTION, 'a' * 64, 'c' * 64)

    def test_frozen_vm_rehearsal_gate_is_no_longer_accepted_in_production_receipts(self):
        receipt = {'v': 1, 'profile': installer.PRODUCTION, 'kit_sha256': 'a' * 64,
                   'plan_sha256': 'c' * 64, 'gates': {
                       name: {'result': 'PASS', 'evidence_sha256': 'b' * 64}
                       for name in installer.GATES[installer.PRODUCTION]}}
        receipt['gates']['coordinated-full-rehearsal'] = {
            'result': 'PASS', 'evidence_sha256': 'b' * 64,
            'fixture_profile': installer.FIXTURE, 'fixture_kit_sha256': 'd' * 64,
            'evidence_path': '/x', 'fixture_kit_path': '/y'}
        with self.assertRaisesRegex(ValueError, 'exact artifact-bound'):
            installer.validate_acceptance(receipt, installer.PRODUCTION, 'a' * 64, 'c' * 64)

    def test_only_exact_retained_message_ingress_is_supported(self):
        intent = {'ip': installer.PUBLIC_IP, 'interface': 'enp5s0'}
        network = installer.network_module(HERE)
        exact = network.parse_ufw_added(
            b'ufw allow in on enp5s0 proto tcp from any to 157.180.49.125 port 38443\n')
        installer.require_message_ingress(intent, {'ufw': exact})
        for rules in ([], exact * 2, network.parse_ufw_added(b'ufw allow 38443/tcp\n')):
            with self.assertRaises(ValueError):
                installer.require_message_ingress(intent, {'ufw': rules})


class LoadedRuntimeBoundaryTests(unittest.TestCase):
    def raw(self, **overrides):
        values = {'FragmentPath': '/etc/systemd/system/paranoid-turn.service',
                  'DropInPaths': '', 'NeedDaemonReload': 'no',
                  'ExecStart': '{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 -I -B /opt/owned/runtime.py run ; ignore_errors=no ; }',
                  'User': 'paranoid-turn', 'Group': 'paranoid-turn'}
        values.update(overrides)
        return ''.join(k+'='+v+'\n' for k,v in values.items()).encode()

    def test_loaded_authority_rejects_dropins_stale_manager_or_changed_exec(self):
        path = Path('/etc/systemd/system/paranoid-turn.service')
        argv = ['/usr/bin/python3','-I','-B','/opt/owned/runtime.py','run']
        installer.validate_loaded_unit(self.raw(), path, argv, 'paranoid-turn', 'paranoid-turn')
        for raw in (self.raw(DropInPaths='/etc/systemd/system/service.d/override.conf'),
                    self.raw(NeedDaemonReload='yes'), self.raw(User='root'),
                    self.raw(ExecStart='{ path=/bin/false ; argv[]=/bin/false ; }')):
            with self.assertRaises(ValueError):
                installer.validate_loaded_unit(raw,path,argv,'paranoid-turn','paranoid-turn')

    def test_previous_relay_is_closed_stopped_and_read_back_before_cutover(self):
        from unittest.mock import patch
        calls=[]
        with patch.object(installer,'verify_system_artifacts',side_effect=lambda v:calls.append('verify')), \
             patch.object(installer,'coordinated_network',side_effect=lambda s,v,o:calls.append(o)), \
             patch.object(installer,'command',side_effect=lambda a,**k:calls.append(a[1]) or b'MainPID=0\nControlPID=0\nActiveState=inactive\n'):
            installer.quiesce_previous_relay(Path('/var/lib/paranoid-single-host'),{})
        self.assertEqual(calls,['verify','close-ingress','stop','show'])

    def test_recovery_never_reopens_ingress_before_verified_old_runtime(self):
        from unittest.mock import patch
        calls=[]
        with patch.object(installer,'verify_system_artifacts'), \
             patch.object(installer,'coordinated_network',side_effect=lambda s,v,o:calls.append(o)), \
             patch.object(installer,'command',return_value=b''), \
             patch.object(installer,'wait_relay_active',side_effect=RuntimeError('fixture runtime not ready')):
            with self.assertRaises(RuntimeError):
                installer.restart_previous_relay(Path('/var/lib/paranoid-single-host'),{})
        self.assertNotIn('open-ingress',calls)


if __name__ == '__main__':
    unittest.main()
