"""Offline-only receipt honesty tests; synthetic reports never run a fixture."""
import copy
from pathlib import Path
import tempfile
import unittest

import single_host_rehearsal as rehearsal


class OfflineReportTests(unittest.TestCase):
    def setup_report(self, root):
        raw = b'...\nRan 59 tests in 0.1s\n\nOK\n'
        log = root / 'tests.log'
        log.write_bytes(raw)
        log.chmod(0o600)
        sources = rehearsal.offline_sources()
        manifest = {'sha256': {name: sources[name] for name in ('single_host.py', 'single_host_message.py')}}
        report = {'v': 1, 'kind': 'single-host-offline-test-report', 'result': 'PASS',
                  'command': rehearsal.OFFLINE_COMMAND, 'exit_code': 0, 'test_count': 59,
                  'source_sha256': sources, 'log': str(log), 'log_sha256': rehearsal.kit.sha(raw)}
        return manifest, report

    def check(self, root, manifest, report):
        path = root / 'report.json'
        rehearsal.kit.atomic_write(path, rehearsal.kit.canonical(report))
        return rehearsal.validate_offline_report(path, manifest)

    def test_nonzero_failed_result_wrong_command_or_code_identity_refuses(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-report-unit-') as raw:
            root = Path(raw)
            manifest, report = self.setup_report(root)
            self.check(root, manifest, report)
            variants = [{**report, 'exit_code': 1}, {**report, 'result': 'FAIL'},
                        {**report, 'command': ['/bin/true']}]
            changed = copy.deepcopy(report)
            changed['source_sha256']['single_host_message.py'] = '0' * 64
            variants.append(changed)
            for variant in variants:
                with self.assertRaises(ValueError):
                    self.check(root, manifest, variant)

    def test_import_failure_cannot_be_promoted_by_pass_result_or_matching_hash(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-report-unit-') as raw:
            root = Path(raw)
            manifest, report = self.setup_report(root)
            failed = b'ImportError: missing module\nRan 24 tests in 0.1s\n\nFAILED (errors=1)\n'
            Path(report['log']).write_bytes(failed)
            report['log_sha256'] = rehearsal.kit.sha(failed)
            report['test_count'] = 24
            with self.assertRaises(ValueError):
                self.check(root, manifest, report)

    def test_raw_unstructured_file_and_other_packaged_worker_refuse(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-report-unit-') as raw:
            root = Path(raw)
            manifest, report = self.setup_report(root)
            with self.assertRaises(ValueError):
                rehearsal.validate_offline_report(Path(report['log']), manifest)
            manifest['sha256']['single_host_message.py'] = '0' * 64
            with self.assertRaises(ValueError):
                self.check(root, manifest, report)


if __name__ == '__main__':
    unittest.main()
