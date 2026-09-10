#!/usr/bin/env python3
"""Real pinned HTTPS/JNI lane regression with synthetic enrollment/session/outcomes.

The real PostgreSQL issuer authorization and actual relay media have separate gates.
Only generated private loopback TLS and temporary classes are created here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "clients/android"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jni-library-dir", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=False)
    names = ["CoreBridge", "PinnedTls", "SnapshotCodec", "StorageGuard", "SyncCycle",
             "KeyClient", "KeyTransport", "SelfServiceClient", "RealtimeLoop", "RealtimeTransport",
             "VoiceRelayConfig", "VoiceRelayTransport"]
    sources = [ANDROID / f"src/org/paranoid/text/{name}.java" for name in names]
    sources.append(ANDROID / "test/VoiceRelayLaneSmoke.java")
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [*sources, Path(__file__).resolve()]}
    native = args.jni_library_dir.resolve() / "libparanoid_client_core.so"
    result = {"status": "RUNNING", "scope": "Actual production loop/transport and JNI signatures over generated pinned HTTPS; synthetic enrollment/session/HTTP outcomes, no PostgreSQL issuer or media",
              "source_sha256": hashes, "jni_sha256": hashlib.sha256(native.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="paranoid-voice-lane-") as directory:
        tmp = Path(directory)
        subprocess.run(["python3", str(ROOT / "scripts/create-test-tls.py"), "--ip", "127.0.0.1", "--output", str(tmp / "tls")], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["openssl", "pkcs12", "-export", "-in", str(tmp / "tls/server.crt"), "-inkey", str(tmp / "tls/server.key"), "-name", "tls", "-out", str(tmp / "server.p12"), "-passout", "pass:test-only"], check=True)
        cp = str(ANDROID / "out/deps/json-20240303.jar")
        subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-encoding", "UTF-8", "-cp", cp, "-d", str(tmp), *map(str, sources)], check=True)
        command = ["java", "-Djava.library.path=" + str(native.parent), "-cp", str(tmp) + ":" + cp, "VoiceRelayLaneSmoke", str(tmp / "server.p12")]
        with (args.evidence_dir / "runtime.log").open("w") as log:
            executed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=70)
        result.update(status="PASS" if executed.returncode == 0 else "FAIL", exit_code=executed.returncode)
        (args.evidence_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print((args.evidence_dir / "runtime.log").read_text(), end="")
        raise SystemExit(executed.returncode)


if __name__ == "__main__":
    main()
