#!/usr/bin/env python3
"""Local stand for the iOS client: the unchanged server binary plus a private PostgreSQL 16.

What one run does, in order (nothing under ``server/`` is modified):

1. ``cargo +1.98.1 build --locked --release --manifest-path server/Cargo.toml
   --target-dir clients/ios/out/server-target`` (skipped with ``--server-binary``);
2. ``initdb`` of a private cluster that listens only on a Unix socket under
   ``clients/ios/out/paranoid-stand-*/socket`` (``pg_bin`` from ``toolchain.json``);
3. ``scripts/create-test-tls.py --ip <bind> --port <port>``: a disposable
   self-signed identity whose SPKI digest becomes the pin;
4. ``paranoid-server self-service-init`` with ``PARANOID_KEY_REALM``/``PARANOID_KEY_PIN``;
5. the server in ``PARANOID_MODE=self-service-v2-local`` with
   ``PARANOID_BIND``, ``PARANOID_TLS_CERT`` and ``PARANOID_TLS_KEY``
   (names from ``server/src/main.rs``); TURN is not started, so
   ``/v2/voice/turn`` answers ``404 turn_disabled`` and calls use direct ICE.

The stand never contacts the hosted server or an existing PostgreSQL cluster.
On exit (Ctrl-C, SIGTERM, or the end of ``--run``) the server and PostgreSQL
are stopped and the stand directory is removed (``--keep`` retains it); the
log stays under ``clients/ios/out/logs/``.

``--bind`` defaults to ``127.0.0.1``. In ``self-service-v2-local`` mode the
server accepts loopback binds only (``main.rs`` ``bind_allowed``), so for a
LAN address (a phone on Wi-Fi) the server still listens on ``127.0.0.1:<port>``
and this script runs a plain TCP relay on ``<bind>:<port>``; TLS is end to end
(the certificate names the LAN address), exactly like the front/back split of
``clients/android/test_realtime.py``.

Usage:
  python3 clients/ios/local_stand.py                       # run until Ctrl-C
  python3 clients/ios/local_stand.py --print-descriptor    # also print the realm/pin JSON
  python3 clients/ios/local_stand.py --run 'curl -s --cacert $TLS_CRT $URL/health'
  python3 clients/ios/local_stand.py --bind 192.168.1.20 --print-descriptor

``--run CMD`` executes CMD with ``sh -c`` once the server answers ``/health``,
then stops everything and exits with the command's status. The command sees:
``URL`` (= ``REALM``, the saved HTTPS origin), ``PIN`` (SPKI SHA-256),
``TLS_CRT``, ``TLS_KEY``, ``PG_SOCKET``, ``PG_BIN``, ``DATABASE_URL``,
``SERVER_BINARY``, ``STAND_DIR`` and ``STAND_LOG``.

``--print-descriptor`` prints one JSON line on stdout with ``server_url``,
``tls_spki_sha256``, ``tls_cert`` and ``launch_arguments`` (the
``-paranoid-realm <url> -paranoid-pin <hex>`` pair for the iOS app).
"""
import argparse
import getpass
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOLCHAIN = HERE / 'toolchain.json'
DEFAULT_WORK_DIR = HERE / 'out'
SERVER_TARGET_DIR = HERE / 'out/server-target'
SERVER_MANIFEST = ROOT / 'server/Cargo.toml'
CREATE_TEST_TLS = ROOT / 'scripts/create-test-tls.py'
RUST_TOOLCHAIN = '1.98.1'
MODE = 'self-service-v2-local'
HEALTH = {'status': 'ok', 'protocol': 'paranoid-self-service-v2', 'realtime': 'signed-long-poll-v1'}
# Unix socket paths are limited to 104 bytes on macOS (sun_path); leave room for ".s.PGSQL.<port>".
SOCKET_PATH_LIMIT = 104 - len('/.s.PGSQL.65535')


class StandError(Exception):
    """A readable failure; printed as ``ERROR: ...`` with exit status 2."""


def log_line(message):
    print(f'local_stand: {message}', file=sys.stderr, flush=True)


def clean_environment():
    """Parent environment without libpq/ParanoID variables, with ~/.cargo/bin on PATH."""
    env = {key: value for key, value in os.environ.items() if not key.startswith(('PG', 'PARANOID_'))}
    cargo_bin = str(Path.home() / '.cargo/bin')
    path = env.get('PATH', '')
    if cargo_bin not in path.split(os.pathsep):
        env['PATH'] = cargo_bin + os.pathsep + path if path else cargo_bin
    return env


def load_pg_bin(override):
    if override is not None:
        pg_bin = Path(override)
    else:
        try:
            pg_bin = Path(json.loads(TOOLCHAIN.read_text())['pg_bin'])
        except (OSError, ValueError, KeyError) as error:
            raise StandError(f'cannot read pg_bin from {TOOLCHAIN}: {error}')
    missing = [name for name in ('initdb', 'postgres', 'pg_isready', 'psql') if not (pg_bin / name).is_file()]
    if missing:
        raise StandError(f'{pg_bin} lacks {", ".join(missing)} (PostgreSQL 16; see toolchain.json pg_bin)')
    return pg_bin


def build_server(env, log):
    """Release build of the unchanged server into clients/ios/out/server-target."""
    if shutil.which('cargo', path=env['PATH']) is None:
        raise StandError('cargo not found; install rustup toolchain 1.98.1 (~/.cargo/bin is added to PATH here)')
    argv = ['cargo', f'+{RUST_TOOLCHAIN}', 'build', '--locked', '--release',
            '--manifest-path', str(SERVER_MANIFEST), '--target-dir', str(SERVER_TARGET_DIR)]
    log_line('building server: ' + ' '.join(argv))
    completed = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=log, check=False)
    if completed.returncode != 0:
        raise StandError(f'server build failed (exit {completed.returncode}); see the log')
    binary = SERVER_TARGET_DIR / 'release/paranoid-server'
    if not binary.is_file():
        raise StandError(f'server build produced no {binary}')
    return binary


def socket_address(ip, port):
    return f'[{ip}]:{port}' if ip.version == 6 else f'{ip}:{port}'


def free_port(front_ip, requested):
    """A TCP port that is free on 127.0.0.1 (server) and on the front address (relay)."""
    family = socket.AF_INET6 if front_ip.version == 6 else socket.AF_INET
    for _ in range(64):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            try:
                probe.bind(('127.0.0.1', requested))
            except OSError as error:
                if requested:
                    raise StandError(f'port {requested} is not free on 127.0.0.1: {error}; never kill another process')
                continue
            port = probe.getsockname()[1]
        if front_ip.is_loopback and front_ip == ipaddress.ip_address('127.0.0.1'):
            return port
        with socket.socket(family, socket.SOCK_STREAM) as probe:
            try:
                probe.bind((str(front_ip), port))
            except OSError as error:
                if requested:
                    raise StandError(f'port {requested} is not free on {front_ip}: {error}; never kill another process')
                continue
        return port
    raise StandError('no free port found')


class TcpRelay:
    """Plain TCP forwarder <front> -> <back>; TLS remains end to end with the server."""

    def __init__(self, front, back):
        self.back = back
        family = socket.AF_INET6 if ipaddress.ip_address(front[0]).version == 6 else socket.AF_INET
        try:
            self.listener = socket.create_server(front, family=family, backlog=64)
        except OSError as error:
            raise StandError(f'cannot listen on {front[0]}:{front[1]} (is it an address of this Mac?): {error}')
        self.listener.settimeout(0.5)
        self.closing = threading.Event()
        self.thread = threading.Thread(target=self.accept_loop, name='relay-accept', daemon=True)
        self.thread.start()

    def accept_loop(self):
        while not self.closing.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.bridge, args=(client,), daemon=True).start()

    def bridge(self, client):
        try:
            upstream = socket.create_connection(self.back, timeout=5)
        except OSError:
            client.close()
            return
        upstream.settimeout(None)
        client.settimeout(None)

        def pump(source, sink):
            try:
                while True:
                    data = source.recv(65536)
                    if not data:
                        break
                    sink.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    sink.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        forward = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        forward.start()
        pump(upstream, client)
        forward.join()
        client.close()
        upstream.close()

    def close(self):
        self.closing.set()
        self.listener.close()
        self.thread.join(timeout=2)


class Stand:
    def __init__(self, args):
        self.args = args
        self.bind_ip = ipaddress.ip_address(args.bind)
        self.pg_bin = load_pg_bin(args.pg_bin)
        self.work_dir = Path(args.work_dir).resolve()
        self.env = clean_environment()
        self.log = None
        self.log_path = None
        self.root = None
        self.socket_dir = None
        self.postgres = None
        self.server = None
        self.relay = None
        self.descriptor = None
        self.server_binary = None

    # -- lifecycle -----------------------------------------------------------------

    def start(self):
        self.work_dir.mkdir(parents=True, exist_ok=True)
        logs = self.work_dir / 'logs'
        logs.mkdir(parents=True, exist_ok=True)
        self.log_path = logs / time.strftime('local-stand-%Y%m%dT%H%M%S.log', time.gmtime())
        self.log = self.log_path.open('w')
        log_line(f'log: {self.log_path}')
        if self.args.server_binary:
            self.server_binary = Path(self.args.server_binary).resolve()
            if not self.server_binary.is_file():
                raise StandError(f'server binary {self.server_binary} does not exist')
        else:
            self.server_binary = build_server(self.env, self.log)
        # `paranoid-*` parent, 0700 dirs and a canonical absolute socket path are what
        # `development_database_allowed` and `worker_guard` in the server require.
        self.root = Path(tempfile.mkdtemp(prefix='paranoid-stand-', dir=self.work_dir)).resolve()
        self.socket_dir = self.root / 'socket'
        self.socket_dir.mkdir(mode=0o700)
        if len(str(self.socket_dir)) > SOCKET_PATH_LIMIT:
            raise StandError(f'socket path {self.socket_dir} exceeds the Unix socket limit; use --work-dir')
        self.start_postgres()
        port = free_port(self.bind_ip, self.args.port)
        self.create_tls(port)
        server_ip = self.bind_ip if self.bind_ip.is_loopback else ipaddress.ip_address('127.0.0.1')
        self.env.update(
            PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={self.socket_dir}',
            PARANOID_KEY_REALM=self.descriptor['server_url'],
            PARANOID_KEY_PIN=self.descriptor['tls_spki_sha256'],
            PARANOID_MODE=MODE,
            PARANOID_BIND=socket_address(server_ip, port),
            PARANOID_TLS_CERT=str(self.root / 'tls/server.crt'),
            PARANOID_TLS_KEY=str(self.root / 'tls/server.key'),
        )
        log_line('self-service-init')
        completed = subprocess.run([str(self.server_binary), 'self-service-init'], env=self.env,
                                   stdout=self.log, stderr=self.log, check=False)
        if completed.returncode != 0:
            raise StandError(f'paranoid-server self-service-init failed (exit {completed.returncode}); see the log')
        if server_ip != self.bind_ip:
            log_line(f'server binds {socket_address(server_ip, port)}; relay on {socket_address(self.bind_ip, port)}')
            self.relay = TcpRelay((str(self.bind_ip), port), ('127.0.0.1', port))
        self.start_server()
        log_line(f'ready: {self.descriptor["server_url"]} (pin {self.descriptor["tls_spki_sha256"]})')

    def start_postgres(self):
        data = self.root / 'pg'
        log_line('initdb (private cluster, Unix socket only)')
        completed = subprocess.run([str(self.pg_bin / 'initdb'), '-D', str(data), '--auth-local=trust',
                                    '--auth-host=scram-sha-256', '--no-locale', '-E', 'UTF8'],
                                   env=self.env, stdout=self.log, stderr=self.log, check=False)
        if completed.returncode != 0:
            raise StandError(f'initdb failed (exit {completed.returncode}); see the log')
        self.postgres = subprocess.Popen(
            [str(self.pg_bin / 'postgres'), '-D', str(data), '-k', str(self.socket_dir),
             '-c', 'listen_addresses=', '-c', 'unix_socket_permissions=0700',
             '-c', 'log_statement=none', '-c', 'log_min_error_statement=panic',
             '-c', 'log_parameter_max_length_on_error=0'],
            env=self.env, stdout=self.log, stderr=self.log)
        for _ in range(200):
            if self.postgres.poll() is not None:
                raise StandError('private PostgreSQL exited before readiness; see the log')
            ready = subprocess.run([str(self.pg_bin / 'pg_isready'), '-h', str(self.socket_dir), '-d', 'postgres'], env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if ready.returncode == 0:
                return
            time.sleep(0.05)
        raise StandError('private PostgreSQL did not become ready')

    def create_tls(self, port):
        output = self.root / 'tls'
        completed = subprocess.run([sys.executable, str(CREATE_TEST_TLS), '--ip', str(self.bind_ip),
                                    '--port', str(port), '--output', str(output)],
                                   env=self.env, stdout=self.log, stderr=self.log, check=False)
        if completed.returncode != 0:
            raise StandError(f'create-test-tls.py failed (exit {completed.returncode}); see the log')
        public = json.loads((output / 'public-connection.json').read_text())
        self.descriptor = {
            'server_url': public['server_url'],
            'tls_spki_sha256': public['tls_spki_sha256'],
            'tls_cert': str(output / 'server.crt'),
            'launch_arguments': ['-paranoid-realm', public['server_url'], '-paranoid-pin', public['tls_spki_sha256']],
        }

    def start_server(self):
        log_line(f'starting {self.server_binary.name} ({MODE})')
        self.server = subprocess.Popen([str(self.server_binary)], env=self.env, stdout=self.log, stderr=self.log)
        context = ssl.create_default_context(cafile=self.descriptor['tls_cert'])
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
        for _ in range(200):
            if self.server.poll() is not None:
                raise StandError(f'server exited before readiness (exit {self.server.returncode}); see the log')
            try:
                with opener.open(self.descriptor['server_url'] + '/health', timeout=2) as response:
                    body = json.loads(response.read())
            except (OSError, ValueError):
                time.sleep(0.05)
                continue
            if body != HEALTH:
                raise StandError(f'unexpected /health body: {body}')
            return
        raise StandError('server did not answer /health within 10 s; see the log')

    def stop(self):
        if self.relay is not None:
            self.relay.close()
            self.relay = None
        self.stop_process('server', self.server, signal.SIGTERM, 10)
        self.server = None
        self.stop_process('postgres', self.postgres, signal.SIGINT, 15)
        self.postgres = None
        if self.root is not None and self.root.is_dir():
            if self.args.keep:
                log_line(f'kept {self.root}')
            else:
                shutil.rmtree(self.root, ignore_errors=True)
        self.root = None
        if self.log is not None:
            self.log.close()
            self.log = None

    @staticmethod
    def stop_process(name, process, signum, timeout):
        if process is None or process.poll() is not None:
            return
        log_line(f'stopping {name}')
        process.send_signal(signum)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    # -- consumer side ---------------------------------------------------------------

    def command_environment(self):
        env = dict(os.environ)
        env.update(
            URL=self.descriptor['server_url'],
            REALM=self.descriptor['server_url'],
            PIN=self.descriptor['tls_spki_sha256'],
            TLS_CRT=self.descriptor['tls_cert'],
            TLS_KEY=self.env['PARANOID_TLS_KEY'],
            PG_SOCKET=str(self.socket_dir),
            PG_BIN=str(self.pg_bin),
            DATABASE_URL=self.env['PARANOID_DATABASE_URL'],
            SERVER_BINARY=str(self.server_binary),
            STAND_DIR=str(self.root),
            STAND_LOG=str(self.log_path),
        )
        return env

    def run_command(self, command):
        log_line(f'running: {command}')
        # The operator's own command line, expanded by sh so $URL/$TLS_CRT work as documented.
        completed = subprocess.run(['/bin/sh', '-c', command], env=self.command_environment(), cwd=ROOT, check=False)
        return completed.returncode

    def wait_forever(self):
        log_line('press Ctrl-C to stop')
        while True:
            if self.server.poll() is not None:
                raise StandError(f'server exited (exit {self.server.returncode}); see the log')
            if self.postgres.poll() is not None:
                raise StandError('private PostgreSQL exited; see the log')
            time.sleep(0.5)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='\n'.join(__doc__.splitlines()[1:]))
    parser.add_argument('--bind', default='127.0.0.1',
                        help='address the clients connect to (default 127.0.0.1; a LAN address is relayed)')
    parser.add_argument('--port', type=int, default=0, help='TCP port (default: a free one)')
    parser.add_argument('--print-descriptor', action='store_true',
                        help='print the realm/pin descriptor JSON on stdout once the server is up')
    parser.add_argument('--run', metavar='CMD', help='run CMD with sh -c against the stand, then stop')
    parser.add_argument('--server-binary', metavar='PATH', help='use this paranoid-server instead of building')
    parser.add_argument('--pg-bin', metavar='DIR', help='PostgreSQL 16 bin directory (default: toolchain.json)')
    parser.add_argument('--work-dir', default=str(DEFAULT_WORK_DIR),
                        help='where the stand directory and logs/ go (default: clients/ios/out)')
    parser.add_argument('--keep', action='store_true', help='keep the stand directory (cluster, TLS) on exit')
    args = parser.parse_args(argv)
    try:
        ipaddress.ip_address(args.bind)
    except ValueError:
        parser.error(f'--bind {args.bind!r} is not an IP address')
    if args.port and not 1024 <= args.port <= 65535:
        parser.error('--port must be 1024..65535')
    return args


def main(argv=None):
    args = parse_args(argv)
    if os.geteuid() == 0:
        print('ERROR: run as an unprivileged user', file=sys.stderr)
        return 2
    os.umask(0o077)

    def interrupt(signum, _frame):
        raise KeyboardInterrupt(signal.Signals(signum).name)

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    stand = None
    try:
        stand = Stand(args)
        stand.start()
        if args.print_descriptor:
            print(json.dumps(stand.descriptor), flush=True)
        if args.run is not None:
            return stand.run_command(args.run)
        stand.wait_forever()
        return 0
    except KeyboardInterrupt as stop:
        log_line(f'stopping on {stop}')
        return 130
    except StandError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2
    finally:
        if stand is not None:
            stand.stop()


if __name__ == '__main__':
    sys.exit(main())
