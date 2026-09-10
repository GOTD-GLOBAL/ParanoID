"""REQ-DEPLOY-003: transaction ordering and guarded same-data recovery."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('single_host_message', HERE / 'single_host_message.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MessageTests(unittest.TestCase):
    def test_secret_retries_never_overwrite_or_hardlink(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-message-unit-') as raw:
            root = Path(raw)
            secret = b'a' * 64
            worker.install_secret(root, secret)
            source = root / 'voice-turn/issuer.secret'
            before = source.stat()
            worker.install_secret(root, secret)
            self.assertEqual(source.stat().st_ino, before.st_ino)
            self.assertEqual(source.stat().st_mode & 0o777, 0o400)
            self.assertEqual(source.stat().st_nlink, 1)
            with self.assertRaises(ValueError):
                worker.install_secret(root, b'b' * 64)
            self.assertEqual(source.read_bytes(), secret)

    def test_config_mutation_occurs_only_after_successful_code_switch(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-message-unit-') as raw:
            root = Path(raw)
            original = b'{"deployment":"self-service-v2","ip":"127.0.0.23"}'
            (root / 'config.json').write_bytes(original)
            (root / 'config.json').chmod(0o600)
            fake = Mock()
            fake.switch_v2_locked.side_effect = RuntimeError('synthetic switch failure')
            with self.assertRaises(RuntimeError):
                worker.switch_then_config(fake, root, root / 'candidate', '123',
                                          {'deployment': 'self-service-v2', 'ip': '127.0.0.23'})
            self.assertEqual((root / 'config.json').read_bytes(), original)


class FragmentTests(unittest.TestCase):
    def test_linked_systemd_fragment_resolves_only_to_exact_owned_unit(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-fragment-unit-') as raw:
            root = Path(raw)
            name = 'paranoid-alpha-fixture-0011223344.service'
            (root / name).write_text('synthetic unit')
            link = root / 'manager-link.service'
            link.symlink_to(root / name)
            alpha = Mock()
            def properties(fragment, dropins=''):
                argv = f'/usr/bin/python3 {root}/current/alpha.py run --root {root}'
                return (f'FragmentPath={fragment}\nDropInPaths={dropins}\nNeedDaemonReload=no\n'
                        f'ExecStart={{ path=/usr/bin/python3 ; argv[]={argv} ; }}\nUser=\nGroup=\n').encode()
            alpha.command.return_value = properties(link)
            worker.verify_fragment(alpha, root, name)
            alpha.command.return_value = properties(link, '/etc/systemd/user/service.d/override.conf')
            with self.assertRaises(ValueError):
                worker.verify_fragment(alpha, root, name)
            alpha.command.return_value = properties(root / 'neighbor.service')
            with self.assertRaises(ValueError):
                worker.verify_fragment(alpha, root, name)


class FixtureIssuerBoundaryTests(unittest.TestCase):
    def test_fixture_code_switch_preserves_absent_issuer_and_exact_config_bytes(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-disabled-fixture-') as raw:
            root = Path(raw)
            original = b'{"deployment": "self-service-v2", "ip": "127.0.0.23"}'
            (root / 'config.json').write_bytes(original)
            (root / 'config.json').chmod(0o600)
            alpha = Mock()
            worker.switch_then_config(alpha, root, root / 'candidate', '123',
                                      {'deployment': 'self-service-v2', 'ip': '127.0.0.23'},
                                      enable_voice=False)
            alpha.switch_v2_locked.assert_called_once()
            self.assertEqual((root / 'config.json').read_bytes(), original)
            self.assertFalse((root / 'voice-turn').exists())


class FreshStartBoundaryTests(unittest.TestCase):
    def test_fresh_merged_unit_refusal_never_enables_or_starts(self):
        from contextlib import nullcontext
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(prefix='paranoid-fresh-boundary-') as raw:
            root = Path(raw)
            alpha = Mock()
            alpha.lock.side_effect = lambda _: nullcontext()
            alpha.v2_operation_lock.side_effect = lambda _: nullcontext()
            alpha.unit.return_value = 'exact synthetic unit'
            with patch.object(worker, 'verify_fragment', side_effect=ValueError('unreviewed drop-in')):
                with self.assertRaisesRegex(ValueError, 'drop-in'):
                    worker.install_fresh_guarded(alpha, root, '127.0.0.73', root / 'release', 'owned.service')
            calls = [list(map(str, call.args[0])) for call in alpha.command.call_args_list]
            self.assertIn(['systemctl', '--user', 'link', str(root / 'owned.service')], calls)
            self.assertFalse(any('enable' in call or 'start' in call or '--now' in call for call in calls))
            alpha.wait_health.assert_not_called()

    def test_fresh_start_follows_actual_loaded_authority_guard(self):
        from contextlib import nullcontext
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(prefix='paranoid-fresh-boundary-') as raw:
            root = Path(raw)
            alpha = Mock()
            alpha.lock.side_effect = lambda _: nullcontext()
            alpha.v2_operation_lock.side_effect = lambda _: nullcontext()
            alpha.unit.return_value = 'exact synthetic unit'
            events = []
            alpha.command.side_effect = lambda argv, **_: events.append(list(map(str, argv)))
            with patch.object(worker, 'verify_fragment', side_effect=lambda *args: events.append(['guard'])):
                worker.install_fresh_guarded(alpha, root, '127.0.0.73', root / 'release', 'owned.service')
            guarded = events.index(['guard'])
            self.assertGreater(events.index(['systemctl', '--user', 'enable', str(root / 'owned.service')]), guarded)
            self.assertGreater(events.index(['systemctl', '--user', 'start', 'owned.service']), guarded)
            alpha.wait_health.assert_called_once_with(root)


if __name__ == '__main__':
    unittest.main()
