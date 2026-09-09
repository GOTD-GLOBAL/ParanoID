"""FV2-R01: real SIGINT at AST-anchored boundaries; disposable private PG only.

Run with PARANOID_V2_RELEASE set; PARANOID_TEST_PACKAGED=1 selects its controller.
No host/user-manager calls, backup, imported state, or fixed source line numbers.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import unittest

from test_native import load

HERE = Path(__file__).resolve().parent
RELEASE = Path(os.environ['PARANOID_V2_RELEASE']).resolve()
CONTROLLER = (RELEASE if os.environ.get('PARANOID_TEST_PACKAGED') == '1' else HERE) / 'alpha.py'
alpha = load('interrupt_alpha', CONTROLLER)


def anchor(function, statement, after=False):
    """Resolve exactly one complete statement within the named source function."""
    tree = ast.parse(CONTROLLER.read_text())
    function_node, = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == function]
    expected = ast.dump(ast.parse(statement).body[0], include_attributes=False)
    matches = []
    for parent in ast.walk(function_node):
        for _, value in ast.iter_fields(parent):
            if isinstance(value, list):
                for i, node in enumerate(value):
                    if isinstance(node, ast.stmt) and ast.dump(node, include_attributes=False) == expected:
                        matches.append(value[i + 1].lineno if after else node.lineno)
    line, = matches  # Missing/ambiguous anchors fail, never silently skip a probe.
    return line


def interrupt_child():
    action, root, identifier, phase = sys.argv[2:]
    if phase in ('pre-discard', 'post-discard'):
        function = 'replace_v2'
        statement = ("atomic_config(root, {**c, 'deployment': 'self-service-v2'})"
                     if phase == 'pre-discard' else "shutil.rmtree(root / 'data')")
        line = anchor(function, statement, after=True)
    elif phase == 'fresh-sticky':
        function = 'initialize_v2_locked'
        line = anchor(function, "atomic_config(root, {**c, 'deployment': 'self-service-v2'})", after=True)
    elif action == 'migrate-key':
        function = 'main'
        line = anchor(function, 'migrate_key(root, args.release.absolute())')
    else:
        # Enter actual action, before any manager calls (install) or effects (legacy).
        function = {'install-v2': 'install_v2', 'init': 'initialize', 'migrate-key': 'migrate_key'}[action]
        tree = ast.parse(CONTROLLER.read_text())
        fn, = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == function]
        line = next(n.lineno for n in fn.body if not isinstance(n, ast.Expr) or not isinstance(n.value, ast.Constant))
    def trace(frame, event, arg):
        if (event == 'line' and frame.f_code.co_filename == str(CONTROLLER)
                and frame.f_code.co_name == function and frame.f_lineno == line):
            sys.settrace(None)
            print('SIGINT boundary reached: ' + phase, flush=True)
            os.kill(os.getpid(), signal.SIGINT)
        return trace
    sys.argv = [str(CONTROLLER), action, '--root', root, '--release', str(RELEASE), '--ip', '127.0.0.19']
    if action == 'replace-v2':
        sys.argv += ['--expected-pg-system-id', identifier, '--discard-server-database']
    sys.settrace(trace)
    runpy.run_path(str(CONTROLLER), run_name='__main__')


class V2Interrupts(unittest.TestCase):
    def child(self, action, root, identifier, phase):
        result = subprocess.run([sys.executable, __file__, 'interrupt-child', action, str(root), identifier, phase],
                                capture_output=True, text=True, timeout=45,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.stdout, 'SIGINT boundary reached: ' + phase + '\n')
        print(json.dumps({'action': action, 'phase': phase, 'returncode': result.returncode,
                          'stderr': result.stderr.strip()}), flush=True)
        return result

    def assert_interrupted(self, result, root):
        self.assertEqual(result.returncode, 130, 'interrupted v2 operation must not report success')
        self.assertIn('interrupted', result.stderr.lower())
        self.assertIn('stopped', result.stderr.lower())
        self.assertIn('no automatic rollback', result.stderr.lower())
        self.assertNotIn(str(root), result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertNotIn('PASS', result.stdout + result.stderr)
        if (root / 'config.json').exists():
            c = json.loads((root / 'config.json').read_text())
            for name in ('alice', 'bob'):
                self.assertNotIn(c[name], result.stdout + result.stderr)

    def test_replace_sigint_before_and_after_discard_is_fail_stopped(self):
        os.umask(0o077)
        for phase in ('pre-discard', 'post-discard'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory(prefix='paranoid-r01-') as temp:
                root = Path(temp) / 'paranoid-alpha'
                alpha.initialize(root, '127.0.0.19')
                alpha.point(root, alpha.stage(root, RELEASE))
                c = alpha.config(root)
                alpha.atomic_config(root, {**c, 'deployment': 'key-v1'})
                with alpha.lock(root), alpha.database(root):
                    alpha.sql(root, (RELEASE / 'schema.sql').read_text())
                    alpha.sql(root, 'CREATE DATABASE r01_disposable')
                identifier = alpha.cluster_identifier(root)
                tls = {n: hashlib.sha256((root / 'tls' / n).read_bytes()).hexdigest()
                       for n in ('server.key', 'server.crt')}
                inode = (root / 'lifecycle.lock').stat().st_ino
                pointer = (root / 'current').readlink()
                neighbor = Path(temp) / 'neighbor'
                neighbor.write_bytes(b'outside discard')
                result = self.child('replace-v2', root, identifier, phase)
                self.assertEqual(json.loads((root / 'config.json').read_text()), {**c, 'deployment': 'self-service-v2'})
                self.assertEqual((root / 'data').exists(), phase == 'pre-discard')
                self.assertFalse((root / 'data/postmaster.pid').exists())
                if phase == 'pre-discard':
                    self.assertEqual(alpha.cluster_identifier(root), identifier)
                self.assertEqual((root / 'current').readlink(), pointer)
                self.assertEqual((root / 'lifecycle.lock').stat().st_ino, inode)
                self.assertEqual(tls, {n: hashlib.sha256((root / 'tls' / n).read_bytes()).hexdigest() for n in tls})
                self.assertEqual(list((root / 'backups').iterdir()), [])
                self.assertEqual(neighbor.read_bytes(), b'outside discard')
                with self.assertRaises((ValueError, OSError, RuntimeError)):
                    alpha.replace_v2(root, RELEASE, '127.0.0.19', identifier, True)
                print('PASS containment/sticky/stopped/no-backup/repeat-refusal: ' + phase, flush=True)
                self.assert_interrupted(result, root)

    def test_fresh_sigint_after_sticky_cleans_private_pg_and_fails(self):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-r01-') as temp:
            root = Path(temp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, RELEASE))
            result = self.child('fresh-v2', root, '', 'fresh-sticky')
            self.assertFalse((root / 'data/postmaster.pid').exists())
            self.assertEqual(alpha.config(root)['deployment'], 'self-service-v2')
            self.assertEqual(list((root / 'backups').iterdir()), [])
            self.assert_interrupted(result, root)

    def test_install_sigint_is_failure_before_manager_calls(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-r01-') as temp:
            root = Path(temp) / 'paranoid-alpha'
            result = self.child('install-v2', root, '', 'entry')
            self.assertFalse(root.exists())
            self.assert_interrupted(result, root)

    def test_run_sigint_and_sigterm_remain_graceful(self):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-r01-') as temp:
            root = Path(temp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, RELEASE))
            alpha.fresh_v2(root, RELEASE, '127.0.0.19')
            for sig in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(signal=sig):
                    process = subprocess.Popen([sys.executable, str(CONTROLLER), 'run', '--root', str(root)],
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                    try:
                        alpha.wait_health(root)
                        process.send_signal(sig)
                        stdout, stderr = process.communicate(timeout=40)
                        self.assertEqual(process.returncode, 0)
                        self.assertEqual((stdout, stderr), (b'', b''))
                        self.assertFalse((root / 'data/postmaster.pid').exists())
                        print('PASS actual ready v2 supervisor graceful ' + sig.name, flush=True)
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            process.communicate(timeout=40)

    def test_legacy_interrupt_status_is_unchanged(self):
        for action in ('init', 'migrate-key'):
            with self.subTest(action=action), tempfile.TemporaryDirectory(prefix='paranoid-r01-') as temp:
                root = Path(temp) / 'paranoid-alpha'
                result = self.child(action, root, '', 'entry')
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, '')
                self.assertFalse(root.exists())


if __name__ == '__main__':
    if sys.argv[1:2] == ['interrupt-child']:
        interrupt_child()
    else:
        unittest.main()
