"""Run the real audio harness through an owned, loopback-only coturn fixture.

The separate instrumentation APK must already be installed/running on an owned
emulator with its control port forwarded. No production configuration is read.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time


def run(args):
    adb = Path(os.environ["ANDROID_SDK_ROOT"]) / "platform-tools/adb"
    device = [str(adb), "-s", args.emulator]
    assert args.emulator.startswith("emulator-"), "Only an explicitly owned emulator is supported"
    assert subprocess.check_output(device + ["shell", "getprop", "ro.kernel.qemu"], text=True).strip() == "1"
    version = subprocess.check_output([args.turnserver, "--version"], text=True).strip()
    assert version == "4.18.0", "Use the exact reviewed coturn release"
    # Refuse an occupied listener instead of reusing or stopping its owner.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 34781))
    evidence = Path(args.evidence_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    evidence.chmod(0o700)
    secret = secrets.token_hex(32)
    username = str(int(time.time()) + 600) + ":android-fixture"
    password = base64.b64encode(hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()).decode()
    credentials = evidence / "credentials.json"
    credentials.write_text(json.dumps(dict(username=username, password=password)))
    credentials.chmod(0o600)
    config = "\n".join([
        "listening-ip=127.0.0.1", "relay-ip=127.0.0.1", "listening-port=34781",
        "min-port=40000", "max-port=40015", "no-udp", "no-tls", "no-cli",
        "no-stun", "no-multicast-peers", "allow-loopback-peers", "fingerprint",
        "use-auth-secret", "static-auth-secret=" + secret, "realm=voice-local-test.invalid",
        "user-quota=2", "total-quota=4", "max-bps=128000", "max-allocate-lifetime=60",
        "denied-peer-ip=0.0.0.0-126.255.255.255",
        "denied-peer-ip=128.0.0.0-255.255.255.255", "relay-threads=1", "simple-log",
        "log-file=" + str(evidence / "turn.log"), "pidfile=" + str(evidence / "turn.pid"), "",
    ])
    path = evidence / "turn.conf"
    path.write_text(config)
    path.chmod(0o600)
    (evidence / "config-redacted.txt").write_text(config.replace(secret, "[REDACTED]"))
    server = None
    reverse = False
    try:
        with (evidence / "launcher.log").open("w") as log:
            server = subprocess.Popen([args.turnserver, "-c", str(path)], stdout=log, stderr=log)
        for attempt in range(50):
            if server.poll() is not None:
                raise RuntimeError("Owned coturn exited; inspect its private fixture log")
            try:
                with socket.create_connection(("127.0.0.1", 34781), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("Owned coturn listener did not become ready")
        subprocess.run(device + ["reverse", "--no-rebind", "tcp:34781", "tcp:34781"], check=True)
        reverse = True
        subprocess.run([sys.executable, str(Path(__file__).with_name("test_voice_media.py")),
                        "--url", args.url, "--turn-credentials", str(credentials),
                        "--evidence-dir", str(evidence / "media")], check=True)
    finally:
        if reverse:
            subprocess.run(device + ["reverse", "--remove", "tcp:34781"], check=False)
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        path.unlink(missing_ok=True)
        credentials.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--turnserver", required=True, help="Locally built coturn 4.18.0 executable")
    parser.add_argument("--emulator", required=True, help="Explicitly owned emulator serial")
    parser.add_argument("--url", default="http://127.0.0.1:18869/")
    parser.add_argument("--evidence-dir", required=True, help="New private output directory")
    run(parser.parse_args())
