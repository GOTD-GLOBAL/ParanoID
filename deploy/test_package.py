"""Real native package tests; never production connections."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

class PackageTests(unittest.TestCase):
    def test_ipv6_rejected_before_creating_state(self):
        spec = importlib.util.spec_from_file_location('alpha', HERE / 'alpha.py')
        assert spec and spec.loader
        alpha = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alpha)
        with tempfile.TemporaryDirectory(prefix='paranoid-package-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            with self.assertRaises(ValueError):
                alpha.initialize(root, '::1')
            self.assertFalse(root.exists())

    def test_init_private_and_refuses_overwrite(self):
        self.assertTrue((HERE / 'alpha.py').exists(), 'package controller missing')
        spec = importlib.util.spec_from_file_location('alpha', HERE / 'alpha.py')
        assert spec and spec.loader
        alpha = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alpha)
        with tempfile.TemporaryDirectory(prefix='paranoid-package-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.1')
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertEqual((root / 'config.json').stat().st_mode & 0o777, 0o600)
            import json
            descriptor = json.loads((root / 'tls/public-connection.json').read_text())
            self.assertEqual(descriptor['server_url'], 'https://127.0.0.1:38443')
            original = (root / 'config.json').read_bytes()
            with self.assertRaises(FileExistsError):
                alpha.initialize(root, '127.0.0.1')
            self.assertEqual(original, (root / 'config.json').read_bytes())

if __name__ == '__main__':
    unittest.main()
