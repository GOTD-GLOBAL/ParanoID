"""REQ-DEPLOY-003 offline network plan/ownership tests; never executes networking.

Kernel enforcement, TURN expiry/ACL packets and live UFW remain NOT RUN. Every
external command in these tests is serviced by the in-memory CommandFixture.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import single_host_network as network


SPEC = {'v': 1, 'profile': 'paranoid-single-host-v1', 'ip': '157.180.49.125',
        'interface': 'enp5s0', 'relay_uid': 1977}


class CommandFixture:
    def __init__(self):
        self.table = None
        self.ufw = []
        self.calls = []
        self.relay = {'LoadState': 'loaded', 'ActiveState': 'inactive',
                      'SubState': 'dead', 'MainPID': '0', 'ControlPID': '0'}
        self.fail_add = None
        self.fail_delete_table = False

    def __call__(self, argv, input=None):
        self.calls.append((list(argv), input))
        if argv == ['/usr/sbin/nft', '--json', '--numeric', 'list', 'tables']:
            tables = [{'table': {'family': 'ip', 'name': 'neighbor'}}]
            if self.table is not None:
                tables += [{'table': {'family': 'inet', 'name': 'paranoid_voice'}}]
            return json.dumps({'nftables': tables}).encode()
        if argv == ['/usr/sbin/nft', '--json', '--numeric', 'list', 'table', 'inet', 'paranoid_voice']:
            return json.dumps({'nftables': self.table}).encode()
        if argv == ['/usr/sbin/nft', '--json', '--file', '-']:
            payload = json.loads(input)
            if 'delete' in payload['nftables'][0]:
                if self.fail_delete_table:
                    raise RuntimeError('fixture deletion failure')
                self.table = None
            else:
                if self.table is not None:
                    raise RuntimeError('exclusive create collision')
                self.table = [next(iter(x.values())) for x in payload['nftables']]
            return b''
        if argv == ['/usr/sbin/ufw', 'status', 'verbose']:
            return b'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n'
        if argv == ['/usr/sbin/ufw', 'show', 'added']:
            return ('Added user rules (see ufw status for running firewall):\n' +
                    '\n'.join(self.ufw) + '\n').encode()
        if argv == ['/usr/sbin/iptables', '--version']:
            return b'iptables v1.8.10 (nf_tables)\n'
        if argv[:3] == ['/usr/sbin/ufw', '--force', 'delete']:
            command = network.ufw_display(argv[3:])
            self.ufw.remove(command)
            return b'Rule deleted\n'
        if argv[:2] == ['/usr/sbin/ufw', 'allow']:
            command = network.ufw_display(argv[1:])
            if self.fail_add is not None and len(self.ufw) == self.fail_add:
                raise RuntimeError('fixture add failure')
            self.ufw.append(command)
            return b'Rule added\n'
        if argv[:3] == ['/usr/bin/systemctl', 'show', 'paranoid-turn.service']:
            return ''.join(k + '=' + v + '\n' for k, v in self.relay.items()).encode()
        raise AssertionError('Unexpected command; real subprocess is forbidden: ' + repr(argv))

    def read(self, path):
        if str(path) != '/etc/ufw/before.rules':
            raise AssertionError('Unexpected host read')
        return b'*filter\n-A ufw-before-input -i lo -j ACCEPT\n-A ufw-before-output -o lo -j ACCEPT\nCOMMIT\n'


def snapshot(spec=SPEC):
    return [next(iter(item.values())) for item in json.loads(network.render_nft(spec))['nftables']]


class RenderTests(unittest.TestCase):
    def test_production_shape_rejects_fixture_targets_uid_bool_and_injections(self):
        self.assertEqual(network.validate_spec(SPEC), SPEC)
        for key, value in [('v', True), ('profile', 'paranoid-single-host-fixture-v1'),
                           ('ip', '127.0.0.1'), ('relay_uid', True), ('relay_uid', 0),
                           ('relay_uid', -1), ('interface', 'enp5s0\nflush ruleset'),
                           ('interface', 'x' * 16)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                network.validate_spec({**SPEC, key: value})
        with self.assertRaises(ValueError):
            network.validate_spec({**SPEC, 'port': 3478})
        with self.assertRaises(ValueError):
            network.decode_json(b'{"v":1,"v":1}')

    def test_nft_transaction_is_exclusive_scoped_ordered_and_hash_bound(self):
        raw = network.render_nft(SPEC)
        self.assertEqual(raw, network.render_nft(dict(reversed(list(SPEC.items())))))
        commands = json.loads(raw)['nftables']
        self.assertEqual(commands[0], {'create': {'table': {'family': 'inet', 'name': 'paranoid_voice'}}})
        chain = commands[1]['add']['chain']
        self.assertEqual((chain['hook'], chain['prio'], chain['policy']), ('output', -10, 'accept'))
        rules = [c['add']['rule'] for c in commands[2:]]
        names = [r['comment'].split(':')[-1] for r in rules]
        self.assertLess(names.index('same-host-media'), names.index('deny-local'))
        self.assertLess(names.index('deny-local'), names.index('listener-udp'))
        self.assertEqual(rules[0]['expr'][0]['match']['right'], 1977)
        self.assertEqual(rules[0]['expr'][-1], {'return': None})
        self.assertEqual(rules[-1]['expr'], [{'drop': None}])
        own = rules[names.index('same-host-media')]['expr']
        fields = {e['match']['left']['payload']['field']: e['match']['right']
                  for e in own if 'match' in e and 'payload' in e['match']['left']}
        self.assertEqual(fields['daddr'], SPEC['ip'])
        self.assertEqual(fields['sport'], {'range': [40000, 40015]})
        self.assertEqual(fields['dport'], {'range': [40000, 40015]})
        tcp = rules[names.index('listener-tcp')]['expr']
        self.assertIn({'match': {'op': 'in', 'left': {'ct': {'key': 'state'}}, 'right': 'established'}}, tcp)
        self.assertNotIn('flush', raw.decode())
        self.assertNotIn('80', [str(x) for x in own])
        self.assertNotEqual(hashlib.sha256(raw).hexdigest(),
                            hashlib.sha256(network.render_nft({**SPEC, 'relay_uid': 1978})).hexdigest())

    def test_closed_nft_observation_ignores_only_handles_not_order_or_extra_rules(self):
        original = snapshot()
        observed = copy.deepcopy(original)
        for i, entry in enumerate(observed):
            next(iter(entry.values()))['handle'] = i + 10
        observed.insert(0, {'metainfo': {'version': '1.0.9', 'json_schema_version': 1}})
        self.assertEqual(network.normalize_nft_json({'nftables': observed}), original)
        observed.append({'rule': {'family': 'inet', 'table': 'paranoid_voice',
                                 'chain': 'output', 'expr': [{'accept': None}]}})
        self.assertNotEqual(network.normalize_nft_json({'nftables': observed}), original)
        with self.assertRaises(ValueError):
            network.normalize_nft_json({'nftables': original + [{'set': {'name': 'unreviewed'}}]})

    def test_ingress_is_three_exact_commented_tuples_and_delete_keeps_comment(self):
        rules = network.desired_ufw_rules(SPEC)
        self.assertEqual([r['id'] for r in rules], ['turn-tcp', 'turn-udp', 'relay-udp'])
        for rule in rules:
            self.assertIn('comment', rule['add_argv'])
            self.assertEqual(rule['delete_argv'][:3], ['/usr/sbin/ufw', '--force', 'delete'])
            self.assertEqual(rule['delete_argv'][3:], rule['add_argv'][1:])
            self.assertTrue(rule['comment'].startswith('paranoid-single-host-v1:'))
            self.assertIn('enp5s0', rule['add_argv'])
            self.assertIn(SPEC['ip'], rule['add_argv'])
        self.assertNotIn('38443', repr(rules))

    def test_ufw_parser_preserves_ownership_and_detects_broader_rules(self):
        owned = network.desired_ufw_rules(SPEC)[0]
        decoded = network.parse_ufw_added((network.ufw_display(owned['add_argv'][1:]) + '\n').encode())
        self.assertEqual(decoded[0]['comment'], owned['comment'])
        f = CommandFixture()
        f.ufw = ['ufw allow 34781/tcp comment other-owner']
        observation = network.observe(SPEC, runner=f, read=f.read)
        with self.assertRaisesRegex(ValueError, 'ingress conflict'):
            network.prepare_receipt(SPEC, observation, 'a' * 64)
        f.ufw = ['ufw allow 443/tcp comment web']
        network.prepare_receipt(SPEC, network.observe(SPEC, runner=f, read=f.read), 'a' * 64)
        with self.assertRaises(ValueError):
            network.parse_ufw_added(b'ufw allow UnknownApp\n')

    def test_policy_unit_has_ordering_no_execstop_and_no_shell_or_force_escape(self):
        unit = network.render_policy_unit(Path('/opt/paranoid-single-host/release/single_host_network.py'),
                                          Path('/var/lib/paranoid-single-host/network-spec.json'),
                                          'a' * 64,
                                          Path('/var/lib/paranoid-single-host/network-receipt.json'))
        self.assertIn('Type=oneshot\nRemainAfterExit=yes\n', unit.decode())
        self.assertIn('Before=paranoid-turn.service', unit.decode())
        self.assertNotIn('ExecStop', unit.decode())
        self.assertNotIn('/bin/sh', unit.decode())
        with self.assertRaises(ValueError):
            network.render_policy_unit(Path('/tmp/x%H'), Path('/a'), 'a' * 64, Path('/b'))


class OperationsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = CommandFixture()
        observation = network.observe(SPEC, runner=self.fixture, read=self.fixture.read)
        self.receipt = network.prepare_receipt(SPEC, observation, 'a' * 64)
        self.saved = []

    def run_op(self, operation):
        return network.run_operation(operation, SPEC, self.receipt,
                                     lambda receipt: self.saved.append(copy.deepcopy(receipt)),
                                     runner=self.fixture, read=self.fixture.read)

    def test_apply_installs_only_egress_and_rerun_is_noop_then_owned_rollback(self):
        self.run_op('apply')
        self.assertEqual(self.fixture.ufw, [])
        self.assertEqual(self.receipt['egress'], 'present')
        self.assertEqual(self.saved[0]['pending'], {'op': 'apply'})
        before = sum(c[0][:3] == ['/usr/sbin/nft', '--json', '--file'] for c in self.fixture.calls)
        self.run_op('apply')
        after = sum(c[0][:3] == ['/usr/sbin/nft', '--json', '--file'] for c in self.fixture.calls)
        self.assertEqual(before, after)
        self.run_op('open-ingress')
        self.assertEqual(len(self.fixture.ufw), 3)
        self.run_op('close-ingress')
        self.assertEqual(self.fixture.ufw, [])
        self.run_op('remove')
        self.assertIsNone(self.fixture.table)
        self.assertEqual(self.receipt['egress'], 'absent')

    def test_ingress_cannot_open_without_egress_and_removal_requires_stopped_relay(self):
        with self.assertRaisesRegex(ValueError, 'egress'):
            self.run_op('open-ingress')
        self.run_op('apply')
        self.fixture.relay.update(ActiveState='active', SubState='running', MainPID='421')
        before = copy.deepcopy(self.fixture.table)
        with self.assertRaisesRegex(ValueError, 'relay'):
            self.run_op('remove')
        self.assertEqual(self.fixture.table, before)
        self.fixture.relay.update(ActiveState='inactive', SubState='dead', MainPID='0', ControlPID='422')
        with self.assertRaisesRegex(ValueError, 'relay'):
            self.run_op('remove')

    def test_unowned_same_table_or_rule_cannot_be_adopted_or_deleted(self):
        self.fixture.table = snapshot()
        with self.assertRaisesRegex(ValueError, 'unowned'):
            self.run_op('apply')
        self.fixture.table = None
        self.run_op('apply')
        other = network.desired_ufw_rules(SPEC)[0]['add_argv'][1:]
        other = [*other[:-1], 'other-owner']
        self.fixture.ufw.append(network.ufw_display(other))
        with self.assertRaisesRegex(ValueError, 'ingress conflict'):
            self.run_op('open-ingress')
        self.assertEqual(len(self.fixture.ufw), 1)
        with self.assertRaises(ValueError):
            self.run_op('close-ingress')
        self.assertEqual(len(self.fixture.ufw), 1)

    def test_failed_partial_ingress_preserves_journal_for_exact_safe_recovery(self):
        self.run_op('apply')
        self.fixture.fail_add = 1
        with self.assertRaises(RuntimeError):
            self.run_op('open-ingress')
        self.assertEqual(len(self.fixture.ufw), 1)
        self.assertEqual(self.receipt['ingress'], ['turn-tcp'])
        self.assertEqual(self.receipt['pending'], {'op': 'open-ingress', 'rule': 'turn-udp'})
        self.fixture.fail_add = None
        self.run_op('close-ingress')
        self.assertEqual(self.fixture.ufw, [])
        self.assertEqual(self.receipt['ingress'], [])
        self.assertIsNone(self.receipt['pending'])

    def test_crash_after_apply_write_is_reconciled_only_with_preexisting_pending_intent(self):
        self.receipt['pending'] = {'op': 'apply'}
        self.fixture.table = snapshot()
        self.run_op('apply')
        self.assertEqual(self.receipt['egress'], 'present')
        self.assertIsNone(self.receipt['pending'])
        self.fixture.table[-1]['rule']['expr'] = [{'accept': None}]
        with self.assertRaisesRegex(ValueError, 'drift'):
            self.run_op('remove')

    def test_failed_rollback_of_pending_apply_retains_owned_table_authority(self):
        self.receipt['pending'] = {'op': 'apply'}
        self.fixture.table = snapshot()
        self.fixture.fail_delete_table = True
        with self.assertRaises(RuntimeError):
            self.run_op('remove')
        self.fixture.fail_delete_table = False
        self.run_op('remove')
        self.assertIsNone(self.fixture.table)

    def test_shadowed_loopback_allow_is_not_supported(self):
        standard = self.fixture.read(Path('/etc/ufw/before.rules'))
        shadowed = standard.replace(b'*filter\n', b'*filter\n-A ufw-before-input -j DROP\n')
        with self.assertRaisesRegex(ValueError, 'loopback'):
            network.observe(SPEC, runner=self.fixture, read=lambda _: shadowed)

    def test_missing_owned_ingress_is_drift_not_silently_committed(self):
        self.run_op('apply')
        self.run_op('open-ingress')
        self.fixture.ufw.pop()
        with self.assertRaisesRegex(ValueError, 'drift'):
            self.run_op('check')

    def test_receipt_hash_and_version_refuse_before_any_external_command(self):
        for key, value in [('v', True), ('policy_sha256', '0' * 64),
                           ('spec_sha256', '0' * 64), ('authority_sha256', '')]:
            original = copy.deepcopy(self.receipt)
            self.receipt[key] = value
            before = len(self.fixture.calls)
            with self.assertRaises(ValueError):
                self.run_op('apply')
            self.assertEqual(len(self.fixture.calls), before)
            self.receipt = original

    def test_missing_ufw_preconditions_fail_before_mutation(self):
        original = self.fixture.__call__
        def runner(argv, input=None):
            if argv == ['/usr/sbin/ufw', 'status', 'verbose']:
                return b'Status: active\nDefault: deny (incoming), deny (outgoing), disabled (routed)\n'
            return original(argv, input)
        with self.assertRaisesRegex(ValueError, 'UFW'):
            network.observe(SPEC, runner=runner, read=self.fixture.read)
        with self.assertRaisesRegex(ValueError, 'loopback'):
            network.observe(SPEC, runner=self.fixture, read=lambda _: b'*filter\nCOMMIT\n')


class FileTests(unittest.TestCase):
    def test_private_file_reader_refuses_symlink_hardlink_duplicate_and_bad_mode(self):
        import os
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'receipt.json'
            source.write_bytes(b'{"v":1}')
            source.chmod(0o600)
            self.assertEqual(network.read_private_json(source, owner=os.geteuid(), trusted_base=root), {'v': 1})
            link = root / 'link'
            link.symlink_to(source)
            with self.assertRaises((ValueError, OSError)):
                network.read_private_json(link, owner=os.geteuid(), trusted_base=root)
            link.unlink()
            os.link(source, link)
            with self.assertRaises(ValueError):
                network.read_private_json(source, owner=os.geteuid(), trusted_base=root)
            link.unlink()
            source.chmod(0o644)
            with self.assertRaises(ValueError):
                network.read_private_json(source, owner=os.geteuid(), trusted_base=root)


if __name__ == '__main__':
    unittest.main()
