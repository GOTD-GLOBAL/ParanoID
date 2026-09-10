"""REQ-DEPLOY-003: synthetic parser fixtures, never runtime acceptance receipts."""
import copy
import importlib.util
import os
from pathlib import Path
import sys
import stat
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


kit = module('single_host')
vm = module('single_host_vm')


class VmIntentTests(unittest.TestCase):
    def intent(self):
        return {'v': 1, 'profile': kit.VM_FIXTURE, 'mode': 'fresh',
                'ip': kit.PUBLIC_IP, 'kit_sha256': 'a' * 64, 'expected': None,
                'interface': 'vr-relay',
                'message': {'user': 'paranoid', 'uid': 1901, 'gid': 1901,
                            'root': '/home/paranoid/paranoid-alpha',
                            'unit': 'paranoid-alpha.service'},
                'relay': {'user': 'paranoid-turn', 'uid': 1902, 'gid': 1902}}

    def test_profile_has_separate_prerequisites_and_exact_production_layout(self):
        value = self.intent()
        kit.validate_intent(value)
        self.assertEqual(kit.coordinator_state(value), kit.STATE)
        self.assertEqual(kit.GATES[kit.VM_FIXTURE], ('design-review', 'offline-tests',
                         'artifact-verification', 'current-boot-isolation'))
        self.assertLessEqual(kit.FULL_REHEARSAL_PROFILES, {kit.VM_FIXTURE})
        for change in ({'interface': 'eth0'}, {'ip': '127.0.0.1'},
                       {'message': {**value['message'], 'root': '/tmp/fixture'}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                kit.validate_intent({**value, **change})

    def test_vm_requires_a_distinct_boundary_before_preflight_mutation(self):
        value = self.intent()
        with patch.object(kit, 'plan', return_value={}), \
                patch.object(kit, 'vm_boundary', side_effect=ValueError('no guest boundary')) as boundary, \
                patch.object(kit, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'guest boundary'):
                kit.preflight(value, HERE)
        boundary.assert_called_once_with(value, HERE)
        command.assert_not_called()

    def test_root_check_precedes_loading_any_full_profile_kit(self):
        for profile in (kit.PRODUCTION, kit.VM_FIXTURE):
            with patch.object(kit.os, 'geteuid', return_value=1003), patch.object(kit, 'plan') as planned:
                with self.assertRaisesRegex(ValueError, 'root before loading'):
                    kit.apply({'profile': profile}, HERE, {}, 'a' * 64)
                planned.assert_not_called()

    def test_production_interface_requires_initial_alphanumeric(self):
        original = {**self.intent(), 'profile': kit.PRODUCTION}
        for interface in ('-eth0', '.eth0'):
            with self.assertRaises(ValueError):kit.validate_intent({**original, 'interface': interface})


class RehearsalFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='paranoid-vm-parser-unit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Only ownership is simulated for this unprivileged parser suite.
        # All real files, hashes, kit membership and schema checks still execute.
        self.api = types.SimpleNamespace(**{k: getattr(kit, k) for k in dir(kit)})
        # Exercise the candidate parser only; production availability stays closed
        # until the separate full runner and exact artifacts have been reviewed.
        self.api.FULL_REHEARSAL_PROFILES = frozenset({kit.VM_FIXTURE})
        self.evidence_reads = []
        def read(path, limit=kit.MAX_FILE, owner=None, private=False):
            self.evidence_reads.append((Path(path), owner))
            return kit.read_file(path, limit, owner=os.geteuid(), private=private)
        self.api.read_file = read
        self.root_verifications = []
        def root_kit(root):
            self.root_verifications.append(root)
            return [self.api.read_file(Path(root) / name, owner=0) for name in kit.tree_files(root)]
        self.api.verify_root_kit = root_kit
        code = self.root / 'code'
        code.mkdir()
        for name in kit.BASE_FILES | kit.RELAY_FILES | kit.VM_FILES:
            source = HERE / ('single_host_README.md' if name == 'README.md' else name)
            (code / name).write_bytes(source.read_bytes() if name not in kit.VM_FILES else b'SYNTHETIC UNIT TEST: runner')
        components = []
        for name in ('message', 'relay'):
            directory = self.root / name
            directory.mkdir()
            (directory / 'component').write_bytes(('synthetic ' + name).encode())
            hashes = {'component': kit.sha((directory / 'component').read_bytes())}
            (directory / 'manifest.json').write_bytes(kit.canonical(
                {'release': kit.component_id(hashes), 'sha256': hashes}))
            components.append(directory)
        self.production = self.root / 'production'
        self.fixture = self.root / 'fixture'
        self.production_manifest = kit.build_kit(kit.PRODUCTION, *components, self.production, code)
        self.fixture_manifest = kit.build_kit(kit.VM_FIXTURE, *components, self.fixture, code)
        self.production_sha = kit.sha((self.production / 'manifest.json').read_bytes())
        self.fixture_sha = kit.sha((self.fixture / 'manifest.json').read_bytes())
        self.intent = {**VmIntentTests().intent(), 'profile': kit.PRODUCTION,
                       'interface': 'eth0', 'kit_sha256': self.production_sha}
        self.plan_sha = kit.plan(self.intent, self.production)['plan_sha256']
        expected = {key: 'a' * 64 for key in kit.IDENTITY}
        expected.update(release='a' * 20, pg_system_id='123')
        self.boots = {'fresh': '11111111-1111-4111-8111-111111111111',
                      'existing-v8': '22222222-2222-4222-8222-222222222222'}
        fixture_intents = {self.boots[mode]: {**copy.deepcopy(self.intent), 'profile': kit.VM_FIXTURE,
                          'interface': 'vr-relay', 'kit_sha256': self.fixture_sha,
                          'mode': mode, 'expected': None if mode == 'fresh' else expected}
                           for mode in ('fresh', 'existing-v8')}
        self.driver_sha = self.fixture_manifest['sha256']['single_host_vm_runner.py']
        self.report = {'v': 1, 'profile': kit.VM_FIXTURE, 'result': 'FULL_REHEARSAL_OBSERVED',
                       'run_id': '1' * 32, 'production_kit_sha256': self.production_sha,
                       'production_plan_sha256': self.plan_sha,
                       'fixture_kit_sha256': self.fixture_sha, 'driver_sha256': self.driver_sha,
                       'boot_ids': list(self.boots.values()), 'cases': {},
                       'fixture_intents': fixture_intents,
                       'fixture_plan_sha256': {mode: kit.plan(value, self.fixture)['plan_sha256']
                                               for mode, value in fixture_intents.items()}}
        for name, checks in vm.REQUIRED_CASES.items():
            mode = 'fresh' if name == 'fresh' else 'existing-v8'
            boot = self.boots[mode]
            log = {k: self.report[k] for k in ('run_id', 'production_kit_sha256',
                   'production_plan_sha256', 'fixture_kit_sha256', 'driver_sha256')}
            log.update(v=1, case=name, boot_id=boot, result='OBSERVED',
                       fixture_mode=mode,
                       fixture_plan_sha256=self.report['fixture_plan_sha256'][boot],
                       started_monotonic_ns=1, finished_monotonic_ns=2,
                       checks={key: True for key in checks},
                       measurements={'synthetic_unit_test': True},
                       commands=[{'argv': ['synthetic-unit-test'], 'exit_code': 0,
                                  'expected_exit_code': 0, 'output': 'synthetic unit test\n',
                                  'output_sha256': kit.sha(b'synthetic unit test\n')}])
            path = self.root / (name + '.json')
            path.write_bytes(kit.canonical(log))
            self.report['cases'][name] = {'path': path.name, 'sha256': kit.sha(path.read_bytes())}
        self.report['isolation_cases'] = {}
        for boot in self.report['boot_ids']:
            self.add_isolation(boot)
        self.gate = {'result': 'PASS', 'fixture_profile': kit.VM_FIXTURE,
                     'fixture_kit_sha256': self.fixture_sha, 'fixture_kit_path': str(self.fixture),
                     'evidence_path': str(self.root / 'report.json'), 'evidence_sha256': ''}
        self.save_report()
        self.validate()  # Every negative starts from a fully valid synthetic document.

    def save_report(self):
        data = kit.canonical(self.report)
        (self.root / 'report.json').write_bytes(data)
        self.gate['evidence_sha256'] = kit.sha(data)

    def add_isolation(self, boot):
        original = self.root / self.report['cases']['fixture-isolation']['path']
        log = kit.decode_json(original.read_bytes())
        log.update(boot_id=boot, fixture_mode=self.report['fixture_intents'][boot]['mode'],
                   fixture_plan_sha256=self.report['fixture_plan_sha256'][boot])
        path = self.root / ('isolation-' + boot + '.json')
        path.write_bytes(kit.canonical(log))
        self.report['isolation_cases'][boot] = {'path': path.name, 'sha256': kit.sha(path.read_bytes())}

    def validate(self):
        return vm.verify_rehearsal(self.api, self.gate, self.production,
                                   self.production_sha, self.plan_sha, self.intent)

    def test_real_referenced_files_are_required_even_with_well_formed_hashes(self):
        self.validate()
        (self.root / 'report.json').unlink()
        with self.assertRaises((ValueError, OSError)):
            self.validate()

    def test_report_hash_plan_and_kit_binding_are_enforced(self):
        for field in ('production_kit_sha256', 'production_plan_sha256', 'fixture_kit_sha256', 'driver_sha256'):
            before = self.report[field]
            self.report[field] = 'e' * 64
            self.save_report()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate()
            self.report[field] = before
        self.save_report()
        self.gate['evidence_sha256'] = 'f' * 64
        with self.assertRaises(ValueError):
            self.validate()

    def test_legacy_profile_wrong_kit_and_changed_shared_bytes_rejected(self):
        for profile in (kit.FIXTURE, kit.PRODUCTION):
            self.gate['fixture_profile'] = profile
            with self.assertRaises(ValueError):
                self.validate()
        self.gate['fixture_profile'] = kit.VM_FIXTURE
        self.gate['fixture_kit_path'] = str(self.production)
        with self.assertRaises(ValueError):
            self.validate()
        self.gate['fixture_kit_path'] = str(self.fixture)
        (self.fixture / 'single_host_network.py').write_text('changed policy')
        with self.assertRaises(ValueError):
            self.validate()

    def test_hash_only_and_unbound_logs_cannot_authorize(self):
        name = next(iter(vm.REQUIRED_CASES))
        entry = self.report['cases'][name]
        path = self.root / entry['path']
        original = path.read_bytes()
        for data in (b'{"result":"PASS"}', kit.canonical({**kit.decode_json(original),
                      'production_plan_sha256': '0' * 64}), kit.canonical({**kit.decode_json(original),
                      'commands': []}), kit.canonical({**kit.decode_json(original), 'checks': {}})):
            path.write_bytes(data)
            entry['sha256'] = kit.sha(data)
            self.save_report()
            with self.assertRaises(ValueError):
                self.validate()

    def test_failed_check_output_corruption_missing_log_and_escape_refused(self):
        name = next(iter(vm.REQUIRED_CASES))
        entry = self.report['cases'][name]
        path = self.root / entry['path']
        original = kit.decode_json(path.read_bytes())
        failed = copy.deepcopy(original)
        failed['checks'][next(iter(failed['checks']))] = False
        corrupt = copy.deepcopy(original)
        corrupt['commands'][0]['output'] = 'changed'
        for data in (kit.canonical(failed), kit.canonical(corrupt)):
            path.write_bytes(data); entry['sha256'] = kit.sha(data); self.save_report()
            with self.assertRaises(ValueError):
                self.validate()
        path.unlink()
        with self.assertRaises((ValueError, OSError)):
            self.validate()
        entry['path'] = '../outside.json'; self.save_report()
        with self.assertRaises(ValueError):
            self.validate()

    def test_production_apply_cannot_accept_a_hash_only_receipt(self):
        # Owner decision 2026-09-10: the frozen VM rehearsal gate was removed
        # from production. A legacy receipt carrying it must fail the exact
        # artifact-bound acceptance shape instead of reaching the old verifier.
        receipt = {'v': 1, 'profile': kit.PRODUCTION, 'kit_sha256': self.production_sha,
                   'plan_sha256': self.plan_sha, 'gates': {name: {'result': 'PASS',
                   'evidence_sha256': 'a' * 64} for name in kit.GATES[kit.PRODUCTION]}}
        receipt['gates']['coordinated-full-rehearsal'] = {
            'result': 'PASS', 'evidence_sha256': 'a' * 64,
            'fixture_profile': kit.VM_FIXTURE, 'fixture_kit_sha256': self.fixture_sha,
            'evidence_path': '/x', 'fixture_kit_path': '/y'}
        with patch.object(kit, 'FULL_REHEARSAL_PROFILES', frozenset({kit.VM_FIXTURE})):
            with self.assertRaises(ValueError) as caught:
                kit.validate_acceptance(receipt, kit.PRODUCTION, self.production_sha,
                                        self.plan_sha, self.production, self.intent)
        self.assertNotIsInstance(caught.exception, kit.FullRehearsalUnavailable)

    def test_production_kit_never_contains_a_fixture_runner(self):
        path = self.production / 'single_host_vm_runner.py'
        path.write_text('unrequested runner')
        manifest = copy.deepcopy(self.production_manifest)
        manifest['sha256'][path.name] = kit.sha(path.read_bytes())
        manifest['release'] = kit.sha(kit.canonical(
            {'profile': manifest['profile'], 'sha256': manifest['sha256']}))[:20]
        (self.production / 'manifest.json').write_bytes(kit.canonical(manifest))
        with self.assertRaisesRegex(ValueError, 'profile-forbidden kit member'):
            kit.verify_kit(self.production)

    def test_report_and_case_reads_request_root_ownership(self):
        self.validate()
        self.assertIn(self.fixture, self.root_verifications)
        for path in [self.root / 'report.json', *(self.root / value['path'] for value in self.report['cases'].values())]:
            self.assertIn((path, 0), self.evidence_reads)
        with self.assertRaises(ValueError):kit.read_file(self.root / 'report.json', owner=0)

    def test_service_configuration_and_mode_coverage_bind_to_production(self):
        original = copy.deepcopy(self.report['fixture_intents'])
        self.report['fixture_intents'][self.boots['existing-v8']]['relay']['uid'] += 1
        self.save_report()
        with self.assertRaisesRegex(ValueError, 'layout|identities'):self.validate()
        self.report['fixture_intents'] = original
        del self.report['fixture_intents'][self.boots['fresh']]; self.save_report()
        with self.assertRaises(ValueError):self.validate()

    def test_each_disposable_boot_binds_its_actual_synthetic_prior_identity(self):
        boot = '33333333-3333-4333-8333-333333333333'
        intent = copy.deepcopy(self.report['fixture_intents'][self.boots['existing-v8']])
        intent['expected']['tls_spki'] = 'b' * 64
        self.report['boot_ids'].append(boot)
        self.report['fixture_intents'][boot] = intent
        planned = kit.plan(intent, self.fixture)['plan_sha256']
        self.report['fixture_plan_sha256'][boot] = planned
        self.add_isolation(boot)
        entry = self.report['cases']['failure-recovery']
        path = self.root / entry['path']
        log = kit.decode_json(path.read_bytes())
        log.update(boot_id=boot, fixture_plan_sha256=planned)
        path.write_bytes(kit.canonical(log)); entry['sha256'] = kit.sha(path.read_bytes())
        self.save_report(); self.validate()
        log['fixture_plan_sha256'] = self.report['fixture_plan_sha256'][self.boots['existing-v8']]
        path.write_bytes(kit.canonical(log)); entry['sha256'] = kit.sha(path.read_bytes())
        self.save_report()
        with self.assertRaises(ValueError):self.validate()

    def test_failed_cleanup_on_any_reported_boot_rejects_full_rehearsal(self):
        entry = self.report['isolation_cases'][self.boots['fresh']]
        path = self.root / entry['path']
        log = kit.decode_json(path.read_bytes())
        log['checks']['final_lo_only_no_routes'] = False
        path.write_bytes(kit.canonical(log)); entry['sha256'] = kit.sha(path.read_bytes())
        self.save_report()
        with self.assertRaises(ValueError):self.validate()

    def test_matching_production_gates_must_reference_verified_case_hashes(self):
        # Owner decision 2026-09-10: production no longer carries the frozen
        # coordinated-full-rehearsal gate, so a receipt naming it is rejected
        # at the acceptance shape even when the frozen verifier is available.
        # The VM report verifier itself (self.validate) remains covered above.
        receipt = {'v': 1, 'profile': kit.PRODUCTION, 'kit_sha256': self.production_sha,
                   'plan_sha256': self.plan_sha, 'gates': {name: {'result': 'PASS',
                   'evidence_sha256': self.report['cases'].get(name, {}).get('sha256', 'a' * 64)}
                   for name in kit.GATES[kit.PRODUCTION]}}
        receipt['gates']['coordinated-full-rehearsal'] = self.gate
        verified = self.validate()
        self.assertIn('cases', verified)
        proxy = types.SimpleNamespace(verify_rehearsal=lambda *args: verified)
        with patch.object(kit, 'FULL_REHEARSAL_PROFILES', frozenset({kit.VM_FIXTURE})), \
                patch.object(kit, 'vm_module', return_value=proxy):
            with self.assertRaisesRegex(ValueError, 'exact artifact-bound'):
                kit.validate_acceptance(receipt, kit.PRODUCTION, self.production_sha,
                                        self.plan_sha, self.production, self.intent)


class GuestObservationTests(unittest.TestCase):
    def observed(self):
        return {'product': vm.DMI_PRODUCT, 'boot_id': '11111111-1111-4111-8111-111111111111',
                'physical_devices': [], 'namespaces': [{'name': 'vr-client'}],
                'network_pci': [], 'links': [{'ifname': 'lo', 'ifindex': 1},
                    {'ifname': 'vr-relay', 'ifindex': 2, 'link_index': 3, 'linkinfo': {'info_kind': 'veth'}}],
                'client_links': [{'ifname': 'lo', 'ifindex': 1},
                    {'ifname': 'vr-client', 'ifindex': 3, 'link_index': 2, 'linkinfo': {'info_kind': 'veth'}}],
                'routes': {'relay': {'-4': [{'dst': vm.CLIENT_IP, 'dev': 'vr-relay'}], '-6': []},
                           'vr-client': {'-4': [{'dst': kit.PUBLIC_IP, 'dev': 'vr-client'}], '-6': []}},
                'client_route': [{'dst': vm.CLIENT_IP, 'dev': 'vr-relay', 'type': 'unicast'}]}

    def test_real_host_nic_default_route_and_local_client_classification_refused(self):
        observed = self.observed()
        vm.validate_guest_observation(observed)
        changes = [dict(product='ordinary host'), dict(network_pci=['0000:00:03.0']),
                   dict(links=[{'ifname': 'lo'}, {'ifname': 'eth0'}]),
                   dict(client_route=[{'dst': vm.CLIENT_IP, 'dev': 'lo', 'type': 'local'}]),
                   dict(routes={}), dict(physical_devices=['usb0']),
                   dict(namespaces=[{'name': 'vr-client'}, {'name': 'unexpected'}])]
        default = copy.deepcopy(observed['routes'])
        default['relay']['-4'].append({'dst': 'default', 'dev': 'vr-relay', 'gateway': '1.2.3.4'})
        changes.append(dict(routes=default))
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                vm.validate_guest_observation({**observed, **change})

    def test_guest_boundary_never_runs_as_unprivileged_or_production_profile(self):
        for profile, uid in [(kit.VM_FIXTURE, 1003), (kit.PRODUCTION, 0)]:
            with patch.object(vm.os, 'geteuid', return_value=uid), self.assertRaises(ValueError):
                vm.boundary(kit, {'profile': profile}, HERE)

    def test_isolation_digest_is_derived_from_observed_topology(self):
        before = self.observed()
        original = kit.sha(kit.canonical(vm.normalized_observation(before)))
        before['boot_id'] = '22222222-2222-4222-8222-222222222222'
        self.assertNotEqual(original, kit.sha(kit.canonical(vm.normalized_observation(before))))

    def test_same_names_on_non_veth_or_unpaired_interfaces_do_not_prove_isolation(self):
        original = self.observed()
        for changed in ({'linkinfo': {'info_kind': 'bridge'}}, {'link_index': 7}):
            observed = copy.deepcopy(original)
            observed['links'][1].update(changed)
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                vm.validate_guest_observation(observed)


class DescriptorTests(unittest.TestCase):
    def test_bounded_read_mode_and_nofollow_use_the_actual_open_descriptor(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); path = root / 'observation'; path.write_bytes(b'observed'); path.chmod(0o400)
            actual = os.fstat
            def root_uid(fd):
                meta = actual(fd)
                # Simulated root UID only; mode/type/link count and stability are real.
                return types.SimpleNamespace(**{name: 0 if name == 'st_uid' else getattr(meta, name)
                    for name in ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_size', 'st_ctime_ns')})
            with patch.object(vm.os, 'fstat', side_effect=root_uid):
                self.assertEqual(vm.descriptor_bytes(path, 16, mode=0o400), b'observed')
                with self.assertRaises(ValueError):vm.descriptor_bytes(path, 2, mode=0o400)
                path.chmod(0o600)
                with self.assertRaises(ValueError):vm.descriptor_bytes(path, 16, mode=0o400)
                alias = root / 'alias'; alias.symlink_to(path)
                with self.assertRaises(OSError):vm.descriptor_bytes(alias, 16)
                alias.unlink(); os.link(path, alias)
                with self.assertRaises(ValueError):vm.descriptor_bytes(path, 16)


if __name__ == '__main__':
    unittest.main()
