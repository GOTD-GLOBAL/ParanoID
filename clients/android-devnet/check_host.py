#!/usr/bin/env python3
"""Real host JNI and synthetic RPC boundary tests. No live RPC/funded keys.

Set JSON_JAR to org.json:json:20240303 (Maven artifact, digest checked below).
Build native client first: cargo +1.98.1 build --locked --manifest-path
blockchain/solana/client/Cargo.toml. Build SBF with pinned toolchain first.
"""
import hashlib
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "clients/android-devnet"
jar = Path(os.environ["JSON_JAR"]).resolve()
assert hashlib.sha256(jar.read_bytes()).hexdigest() == "3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed", "unexpected org.json jar"
classes = CLIENT / "out/host"
classes.mkdir(parents=True, exist_ok=True)
src = CLIENT / "src/org/paranoid/devnet"
subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-cp", str(jar), "-d", str(classes),
                *[str(src / (name + ".java")) for name in ["SolanaBridge", "ProgramPin", "DevnetRpc", "RegistrationFlow", "UiGeneration", "DevnetWork"]],
                *[str(CLIENT / "test" / (name + ".java")) for name in ["BridgeSmoke", "ProgramPinTest", "RpcProgramTest", "RegistrationFlowTest", "UiGenerationTest", "DevnetWorkTest"]]], check=True, cwd=ROOT)
for name in ["BridgeSmoke", "RpcProgramTest", "RegistrationFlowTest", "UiGenerationTest", "DevnetWorkTest"]:
    subprocess.run(["java", "-Djava.library.path=" + str(ROOT / "blockchain/solana/client/target/debug"),
                    "-cp", str(classes) + os.pathsep + str(jar), "org.paranoid.devnet." + name,
                    str(Path(os.environ.get("SBF_PATH",ROOT / "blockchain/solana/registry/target/deploy/paranoid_devnet_registry.so")))], check=True, cwd=ROOT)
print("HOST CLIENT CHECKS PASS; not device or live-chain evidence")
