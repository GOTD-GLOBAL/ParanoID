#!/usr/bin/env python3
"""Run the server suite against a fresh unprivileged PostgreSQL cluster.

Never connects to an existing cluster, exposes a TCP port, installs packages,
or touches production. Requires Rust and PostgreSQL 16 binaries already installed.

With no argument it runs every server test, as before. CI splits the same suite
into the SHARDS below and runs them in parallel on separate runners with
`--shard NAME`. Every test still runs once, unchanged and with its real waits.
Each shard first proves its selection: libtest's own `--list`, run with the
shard's filters, must name exactly the tests the shard owns. A named shard owns
the tests listed for it. The catch-all shard `rest` owns every other test,
including every test added later, so a new test cannot fall between shards.

Usage:
  python3 scripts/check-server.py                 # the whole suite
  python3 scripts/check-server.py --shard rest    # one CI shard
"""
import argparse
from collections import Counter
import getpass
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CARGO_TEST = ["cargo", "test", "--locked", "--manifest-path", "server/Cargo.toml"]

# Tests that wait on real time, grouped so that the shards take about the same
# wall time. Seconds are from `main` run 38931374750 (2026-10-16). Rebalance by
# moving names; the only shard without names is the catch-all `rest`.
SHARDS = {
    "realtime-expiry": (
        "realtime_real_five_minute_expiry_rejects_old_authority_and_allows_new_session",  # 303
        "realtime_empty_wait_returns_after_bounded_timeout_without_advancing_cursor",  # 21
    ),
    "realtime-limits": (
        "realtime_nonce_ledger_is_bounded_without_evicting_replay_history",  # 161
        "realtime_actual_tls_pool_nested_deadlines_and_absolute_socket_lifetime",  # 130
        "realtime_global_session_and_wait_caps_are_shared_and_release_after_revocation",  # 38
    ),
    "rest": (),  # every other test (about 320 s) and every new test
}


def validate_shards(shards):
    """The shard table itself: one catch-all, and no test owned twice."""
    owned = [name for names in shards.values() for name in names]
    duplicated = sorted(name for name, count in Counter(owned).items() if count > 1)
    if duplicated:
        raise SystemExit(f"tests listed in more than one shard: {duplicated}")
    catch_all = [shard for shard, names in shards.items() if not names]
    if catch_all != ["rest"]:
        raise SystemExit(f"exactly one catch-all shard named rest is required, found {catch_all}")


def filters(shard, shards=SHARDS):
    """libtest arguments that select one shard; no shard selects everything."""
    if shard is None:
        return []
    if shards[shard]:
        return ["--exact", *shards[shard]]
    others = [name for names in shards.values() for name in names]
    return ["--exact", *(arg for name in others for arg in ("--skip", name))]


def owned(inventory, shard, shards=SHARDS):
    """The part of the full inventory that the shard must run."""
    named = set(shards[shard])
    if named:
        return Counter({name: count for name, count in inventory.items() if name in named})
    claimed = {name for names in shards.values() for name in names}
    return Counter({name: count for name, count in inventory.items() if name not in claimed})


def check_selection(inventory, selected, shard, shards=SHARDS):
    """Problems with a shard's selection; an empty list means it is exact."""
    problems = [f"shard {shard} names {name}, which is not a server test: "
                "renamed or removed? update SHARDS in scripts/check-server.py"
                for name in shards[shard] if not inventory[name]]
    expected = owned(inventory, shard, shards)
    missing = sorted((expected - selected).elements())
    extra = sorted((selected - expected).elements())
    if missing:
        problems.append(f"shard {shard} would not run: {missing}")
    if extra:
        problems.append(f"shard {shard} would also run tests it does not own: {extra}")
    if not selected:
        problems.append(f"shard {shard} selects no test at all")
    return problems


def listed(extra):
    """Test names libtest would run with these filters, counted per name."""
    output = subprocess.run([*CARGO_TEST, "--", "--list", *extra], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE, text=True).stdout
    return Counter(line[:-len(": test")] for line in output.splitlines()
                   if line.endswith(": test"))


def prove_shard(shard):
    inventory = listed([])
    selected = listed(filters(shard))
    problems = check_selection(inventory, selected, shard)
    if problems:
        raise SystemExit("\n".join(problems))
    print(f"Shard {shard}: {sum(selected.values())} of {sum(inventory.values())} server tests, "
          "exactly the ones it owns", flush=True)


def run(shard=None):
    if os.geteuid() == 0:
        raise SystemExit("Run as an unprivileged development user, not root")
    pg_bin = Path(os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin"))
    for name in ("initdb", "postgres", "psql"):
        if not (pg_bin / name).is_file():
            raise SystemExit(f"PostgreSQL binary missing: {name}; set PG_BIN")
    if not shutil.which("cargo"):
        raise SystemExit("Rust/Cargo is required")
    validate_shards(SHARDS)
    if shard is not None:
        prove_shard(shard)
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
                subprocess.run([*CARGO_TEST, "--", "--test-threads=1", *filters(shard)],
                               cwd=ROOT, env=env, check=True)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    scope = f"shard {shard}" if shard else "all server tests"
    print(f"Server checks passed ({scope}); disposable PostgreSQL stopped and removed", flush=True)


def main():
    parser = argparse.ArgumentParser(
        description="Server suite on a fresh private PostgreSQL cluster.")
    parser.add_argument("--shard", choices=sorted(SHARDS),
                        help="run one CI shard instead of the whole suite")
    run(parser.parse_args().shard)


if __name__ == "__main__":
    main()
