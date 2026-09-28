#!/usr/bin/env python3
"""Run selected server test targets against a fresh unprivileged PostgreSQL cluster.

Same isolation as check-server.py (private socket, TCP disabled, removed afterwards),
but accepts cargo test arguments, e.g. `--test identity_v3`. Never touches production.
"""
import getpass
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main(args):
    if os.geteuid() == 0:
        raise SystemExit("Run as an unprivileged development user, not root")
    pg_bin = Path(os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin"))
    with tempfile.TemporaryDirectory(prefix="paranoid-server-test-") as directory:
        root = Path(directory)
        root.chmod(0o700)
        socket = root / "socket"
        socket.mkdir(mode=0o700)
        env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        with (root / "postgres.log").open("w+") as log:
            subprocess.run([str(pg_bin / "initdb"), "-D", str(root / "data"),
                            "--auth-local=trust", "--auth-host=scram-sha-256",
                            "--no-locale", "-E", "UTF8"],
                           check=True, env=env, stdout=log, stderr=log)
            process = subprocess.Popen([str(pg_bin / "postgres"), "-D", str(root / "data"),
                                        "-k", str(socket), "-c", "listen_addresses=",
                                        "-c", "unix_socket_permissions=0700",
                                        "-c", "max_connections=60", "-c", "shared_buffers=32MB"],
                                       env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if subprocess.run([str(pg_bin / "psql"), "-h", str(socket), "-U",
                                       getpass.getuser(), "-d", "postgres", "-Atc", "SELECT 1"],
                                      env=env, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, timeout=2).returncode == 0:
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError("Private test PostgreSQL did not become ready")
                env["PARANOID_TEST_DATABASE_URL"] = (
                    f"postgresql://{getpass.getuser()}@localhost/postgres?host={socket}")
                print("Fresh private PostgreSQL ready; TCP disabled", flush=True)
                result = subprocess.run(["cargo", "test", "--locked", "--offline",
                                         "--manifest-path", "server/Cargo.toml", *args],
                                        cwd=ROOT, env=env)
            finally:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    print("Disposable PostgreSQL stopped and removed", flush=True)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
