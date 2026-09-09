"""REG-03/06 regressions: PG lock loss and completed-request TLS slots."""
import http.client
import json
import os
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from test_native import load

HERE = Path(__file__).resolve().parent
alpha = load('runtime_alpha', HERE / 'alpha.py')


class RuntimeBoundary(unittest.TestCase):
    def test_binary_declares_bounded_deployment_capability_without_environment(self):
        binary = Path(os.environ['PARANOID_KEY_RELEASE']) / 'paranoid-server'
        result = subprocess.run([binary, 'deployment-capabilities'], env=alpha.clean_env(), capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {'deployment_api': 1,
                         'runtime': 'key-v1-local-lock-close-v1',
                         'schema': alpha.V0_SCHEMA, 'key_schema': alpha.KEY_SCHEMA})

    def test_single_worker_survives_database_lock_loss_and_restart(self):
        self.exercise(lock_loss=True)

    def test_completed_requests_release_tls_slots(self):
        self.exercise(lock_loss=False)

    def test_idle_completed_handshake_has_absolute_lifetime(self):
        self.exercise(lock_loss=False, idle=True)

    def test_alpn_offer_h2_and_http1_selects_supported_http1(self):
        self.exercise(lock_loss=False, alpn=True)

    def exercise(self, lock_loss, idle=False, alpn=False):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-runtime-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.20')
            release = Path(os.environ['PARANOID_KEY_RELEASE'])
            alpha.point(root, alpha.stage(root, release))
            env = alpha.environment(root)
            realm, pin = alpha.public_realm(root)
            env.update(PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin)
            children = []
            def pg_start():
                process = subprocess.Popen([alpha.PG / 'postgres', '-D', root / 'data', '-k', root / 'socket'],
                                           env=alpha.clean_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                children.append(process)
                for _ in range(100):
                    try:
                        if alpha.sql(root, 'SELECT 1').strip() == b'1':
                            return process
                    except subprocess.CalledProcessError:
                        time.sleep(.05)
                self.fail('PG startup')
            def server(ip):
                process = subprocess.Popen([release / 'paranoid-server'], env={**env, 'PARANOID_MODE': 'closed-alpha-key-v1', 'PARANOID_BIND': ip + ':38443'},
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                children.append(process)
                return process
            context = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
            if alpn:
                context.set_alpn_protocols(['h2', 'http/1.1'])
            def connect():
                return context.wrap_socket(socket.create_connection(('127.0.0.20', 38443), timeout=2), server_hostname='127.0.0.20')
            try:
                pg = pg_start()
                subprocess.run([release / 'paranoid-server', 'key-admin-init'], env=env, capture_output=True, check=True)
                first = server('127.0.0.20')
                for _ in range(100):
                    try:
                        with connect():
                            break
                    except OSError:
                        time.sleep(.05)
                else:
                    self.fail('TLS startup')
                if lock_loss:
                    pid = alpha.sql(root, "SELECT pid FROM pg_locks WHERE locktype='advisory' AND granted").strip().decode()
                    self.assertTrue(pid.isdigit())
                    alpha.sql(root, f'SELECT pg_terminate_backend({pid})')
                    for restart in (False, True):
                        if restart:
                            pg.send_signal(signal.SIGINT)
                            pg.wait(timeout=15)
                            pg = pg_start()
                        duplicate = server('127.0.0.21')
                        try:
                            duplicate.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            self.fail('second worker started after database lock loss')
                        self.assertNotEqual(duplicate.returncode, 0)
                    self.assertIsNone(first.poll(), 'lifetime OS lock permits original worker to continue safely')
                    first.kill()
                    first.wait(timeout=10)
                    replacement = server('127.0.0.20')
                    for _ in range(100):
                        try:
                            with connect():
                                break
                        except OSError:
                            time.sleep(.05)
                    else:
                        self.fail('replacement cannot start after original process exit')
                    self.assertIsNone(replacement.poll())
                elif idle:
                    with connect() as sock:
                        sock.settimeout(17)
                        self.assertEqual(sock.recv(1), b'', 'idle TLS socket must close within 15 seconds')
                else:
                    with connect() as sock:
                        if alpn:
                            self.assertEqual(sock.selected_alpn_protocol(), 'http/1.1',
                                             'HTTP/1-only server must never negotiate h2')
                        sock.sendall(b'GET /health HTTP/1.1\r\nHost: 127.0.0.20\r\nConnection: keep-alive\r\n\r\n')
                        response = http.client.HTTPResponse(sock)
                        response.begin()
                        self.assertEqual(response.status, 200)
                        response.read()
                        self.assertEqual(sock.recv(1), b'', 'completed request must close TLS connection')
            finally:
                for process in reversed(children):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=20)


if __name__ == '__main__':
    unittest.main()
