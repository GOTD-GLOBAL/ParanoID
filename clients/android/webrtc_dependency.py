"""Exact M150 AAR extraction for the manual Android build (RFC-0017).

Maven publishes the upstream Java17-restamped artifact. Never rewrite its
bytecode locally; validate the whole pinned archive and each selected payload.
"""
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

ARTIFACT = "android-150.7871.01.aar"
URL = "https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/150.7871.01/" + ARTIFACT
SHA256 = "0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0"
SIZE = 49147033
NATIVE_SHA256 = {
    "arm64-v8a": "7b299113fcd743de7dc5559686b21fc2681b2c8598347d8dc0743d2e004995ca",
    "x86_64": "0717afcc43da0c1aabd904f9ef0653efc8f3d37b5750f39a123697e7910b623a",
}


def prepare(dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    archive = dest / ARTIFACT
    if archive.exists():
        if archive.stat().st_size != SIZE:
            raise RuntimeError("WebRTC dependency integrity: wrong length")
        data = archive.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(SIZE + 1)
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise RuntimeError("WebRTC dependency integrity: wrong SHA256")
    if not archive.exists():
        archive.write_bytes(data)
    # Reextract only the allowlisted payload every build, so a modified extracted
    # cache never silently substitutes for the verified AAR.
    with zipfile.ZipFile(io.BytesIO(data)) as aar:
        payloads = {dest / "webrtc-classes.jar": aar.read("classes.jar")}
        for abi, expected in NATIVE_SHA256.items():
            native = aar.read("jni/" + abi + "/libjingle_peerconnection_so.so")
            if hashlib.sha256(native).hexdigest() != expected:
                raise RuntimeError("WebRTC native integrity: " + abi)
            payloads[dest / "webrtc" / abi / "libjingle_peerconnection_so.so"] = native
        for target, payload in payloads.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
    print("Verified WebRTC150.7871.01 AAR, Java and ARM64/x86_64 payloads")


if __name__ == "__main__":
    prepare(Path(__file__).resolve().parent / "out/deps")
