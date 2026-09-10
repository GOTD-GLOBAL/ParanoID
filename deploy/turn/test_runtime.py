"""REQ-CALL-006: offline credential, config and launcher boundaries; no sockets."""
import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest

import runtime


class RuntimeTests(unittest.TestCase):
    def test_private_exact_secret_and_descriptor_guards(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'secret'
            p.write_bytes(b'a' * 64)
            p.chmod(0o400)
            self.assertEqual(runtime.read_secret(p), 'a' * 64)
            p.chmod(0o600)
            for value in (b'a' * 63, b'a' * 65, b'a' * 64 + b'\n', b'G' * 64):
                p.write_bytes(value)
                with self.assertRaises(ValueError):
                    runtime.read_secret(p)
            p.write_bytes(b'a' * 64)
            p.chmod(0o644)
            with self.assertRaises(ValueError):
                runtime.read_secret(p)
            p.chmod(0o400)
            link = Path(tmp) / 'linked'
            link.symlink_to(p)
            with self.assertRaises((ValueError, OSError)):
                runtime.read_secret(link)
            link.unlink()
            os.link(p, link)
            with self.assertRaises(ValueError):
                runtime.read_secret(p)
            fifo = Path(tmp) / 'fifo'
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(ValueError):
                runtime.read_secret(fifo)

    def test_exact_production_config_private_output_and_clean_environment(self):
        template = (Path(__file__).parent / 'turnserver.conf.in').read_text()
        text = runtime.render_config(template, 'a' * 64, Path('/run/paranoid-turn'))
        self.assertIn('cli=0\n', text)
        self.assertNotIn('no-cli', text)
        self.assertNotIn('mobility', text)
        self.assertNotIn('allow-loopback-peers', text)
        self.assertIn('static-auth-secret=' + 'a' * 64, text)
        for addition in ('\ncli=1\n', '\nunknown-option=1\n', '\nlistening-ip=127.0.0.1\n'):
            with self.assertRaises(ValueError):
                runtime.render_config(template + addition, 'a' * 64, Path('/run/paranoid-turn'))
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            p = runtime.write_config(directory, text)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(p.read_text(), text)
            p.unlink()
            p.symlink_to(directory / 'outside')
            with self.assertRaises((ValueError, OSError)):
                runtime.write_config(directory, text)
            self.assertFalse((directory / 'outside').exists())
        env = runtime.child_environment(Path('/opt/paranoid-turn/release'))
        self.assertEqual(set(env), {'PATH', 'LANG', 'LD_LIBRARY_PATH', 'OPENSSL_CONF'})
        self.assertEqual(env['LD_LIBRARY_PATH'], '/opt/paranoid-turn/release/lib')


if __name__ == '__main__':
    unittest.main()
