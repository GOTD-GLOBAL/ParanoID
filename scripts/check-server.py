#!/usr/bin/env python3
"""Run the server suite against a fresh unprivileged PostgreSQL cluster.

Never connects to an existing cluster, exposes a TCP port, installs packages,
or touches production. Requires Rust and PostgreSQL 16 binaries already installed.
"""
import getpass
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run():
    if os.geteuid() == 0:
        raise SystemExit("Run as an unprivileged development user, not root")
    pg_bin = Path(os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin"))
    for name in ("initdb", "postgres", "psql"):
        if not (pg_bin / name).is_file():
            raise SystemExit(f"PostgreSQL binary missing: {name}; set PG_BIN")
    if not shutil.which("cargo"):
        raise SystemExit("Rust/Cargo is required")
    with tempfile.TemporaryDirectory(prefix="paranoid-server-test-") as directory:
        root = Path(directory)
        root.chmod(0o700)
        socket = root / "socket"
        socket.mkdir(mode=0o700)
        data = root / "data"
        env = os.environ.copy()
        # Avoid inherited libpq defaults selecting a non-test service or host.
        for key in tuple(env):
            if key.startswith("PG"):
                env.pop(key)
        with (root / "postgres.log").open("w+") as log:
            subprocess.run([str(pg_bin / "initdb"), "-D", str(data),
                            "--auth-local=trust", "--auth-host=scram-sha-256",
                            "--no-locale", "-E", "UTF8"],
                           check=True, env=env, stdout=log, stderr=log)
            process = subprocess.Popen([str(pg_bin / "postgres"), "-D", str(data),
                                        "-k", str(socket), "-c", "listen_addresses=",
                                        "-c", "unix_socket_permissions=0700",
                                        "-c", "max_connections=20", "-c", "shared_buffers=32MB"],
                                       env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        raise RuntimeError("Private test PostgreSQL exited before readiness")
                    result = subprocess.run([str(pg_bin / "psql"), "-h", str(socket),
                                             "-U", getpass.getuser(), "-d", "postgres",
                                             "-Atc", "SELECT 1"], env=env,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                            timeout=2)
                    if result.returncode == 0:
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError("Private test PostgreSQL did not become ready")
                env["PARANOID_TEST_DATABASE_URL"] = (
                    f"postgresql://{getpass.getuser()}@localhost/postgres?host={socket}")
                print("Fresh private PostgreSQL ready; TCP disabled", flush=True)
                subprocess.run(["cargo", "test", "--locked", "--manifest-path",
                                "server/Cargo.toml", "--", "--test-threads=1"],
                               cwd=ROOT, env=env, check=True)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    print("Server checks passed; disposable PostgreSQL stopped and removed", flush=True)


if __name__ == "__main__":
    run()
