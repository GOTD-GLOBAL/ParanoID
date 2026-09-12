#!/usr/bin/env python3
"""Exact WebRTC 150.7871.01 xcframework extraction for the manual iOS build (RFC-0019).

webrtc-sdk/Specs publishes one zip carrying eight Apple slices. Validate the
whole pinned archive and every selected slice binary before writing anything,
then re-extract only the iOS device and simulator slices into the SwiftPM
binary target on every build, so a modified extracted cache never silently
substitutes for the verified archive (same discipline as
clients/android/webrtc_dependency.py). Never rewrite the binaries locally.
"""
import argparse
import hashlib
import io
import plistlib
import shutil
import stat
import sys
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

VERSION = "150.7871.01"
ARTIFACT = "WebRTC.xcframework.zip"
URL = "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip"
SIZE = 69079305
ARCHIVE_SHA256 = "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
# SHA-256 of WebRTC.framework/WebRTC inside each selected xcframework slice
# (LibraryIdentifier from the archive's Info.plist). Other slices are neither
# pinned nor extracted.
SLICE_SHA256 = {
    "ios-arm64": "53c02ea619245badf789eea2dc5f0d0064e14a45c277598c0358ca45f74eec57",
    "ios-arm64_x86_64-simulator": "b6a75fc3283c7cdf55a5e4a47fa274465c61fb294caa7d0cf5ab512d53b24dca",
}
XCFRAMEWORK = "WebRTC.xcframework"

IOS_DIR = Path(__file__).resolve().parent
DEFAULT_DEPS_DIR = IOS_DIR / "out" / "deps"
DEFAULT_OUTPUT = IOS_DIR / "ParanoidKit" / "Binaries" / XCFRAMEWORK


def fetch(deps_dir, offline=False):
    """Return the verified archive bytes, downloading once into deps_dir."""
    deps_dir = Path(deps_dir)
    deps_dir.mkdir(parents=True, exist_ok=True)
    archive = deps_dir / ARTIFACT
    if archive.exists():
        if archive.stat().st_size != SIZE:
            raise RuntimeError("WebRTC dependency integrity: wrong length")
        data = archive.read_bytes()
    elif offline:
        raise RuntimeError("WebRTC dependency offline: missing " + str(archive))
    else:
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(SIZE + 1)
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
        raise RuntimeError("WebRTC dependency integrity: wrong SHA256")
    if not archive.exists():
        archive.write_bytes(data)
    return data


def _binary_member(library):
    binary = library.get("BinaryPath")
    if not binary:
        binary = library["LibraryPath"] + "/" + PurePosixPath(library["LibraryPath"]).stem
    return XCFRAMEWORK + "/" + library["LibraryIdentifier"] + "/" + binary


def _check_member(info):
    path = PurePosixPath(info.filename)
    if path.is_absolute() or ".." in path.parts:
        raise RuntimeError("WebRTC archive unsafe member: " + info.filename)
    if stat.S_ISLNK(info.external_attr >> 16):
        raise RuntimeError("WebRTC archive symlink member: " + info.filename)


def verify(data):
    """Check every pinned slice inside verified archive bytes without writing.

    Returns the open archive, the trimmed xcframework Info.plist and the
    members of the selected slices.
    """
    archive = zipfile.ZipFile(io.BytesIO(data))
    names = set(archive.namelist())
    if XCFRAMEWORK + "/Info.plist" not in names:
        raise RuntimeError("WebRTC archive missing " + XCFRAMEWORK + "/Info.plist")
    if XCFRAMEWORK + "/LICENSE" not in names:
        raise RuntimeError("WebRTC archive missing " + XCFRAMEWORK + "/LICENSE")
    plist = plistlib.loads(archive.read(XCFRAMEWORK + "/Info.plist"))
    libraries = {lib["LibraryIdentifier"]: lib for lib in plist.get("AvailableLibraries", [])}
    for identifier, expected in SLICE_SHA256.items():
        library = libraries.get(identifier)
        if library is None or _binary_member(library) not in names:
            raise RuntimeError("WebRTC slice missing from archive: " + identifier)
        if hashlib.sha256(archive.read(_binary_member(library))).hexdigest() != expected:
            raise RuntimeError("WebRTC slice integrity: " + identifier)
    prefixes = tuple(XCFRAMEWORK + "/" + identifier + "/" for identifier in SLICE_SHA256)
    members = [info for info in archive.infolist() if info.filename.startswith(prefixes)]
    for info in members:
        _check_member(info)
    plist["AvailableLibraries"] = [
        lib for lib in plist["AvailableLibraries"] if lib["LibraryIdentifier"] in SLICE_SHA256
    ]
    return archive, plist, members


def _remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def extract(data, output):
    """Re-extract only the pinned slices from verified bytes; replace output wholesale."""
    output = Path(output)
    archive, plist, members = verify(data)
    staging = output.parent / (output.name + ".staging")
    _remove(staging)
    staging.mkdir(parents=True)
    (staging / "Info.plist").write_bytes(plistlib.dumps(plist))
    (staging / "LICENSE").write_bytes(archive.read(XCFRAMEWORK + "/LICENSE"))
    for info in members:
        relative = PurePosixPath(info.filename).relative_to(XCFRAMEWORK)
        target = staging.joinpath(*relative.parts)
        if info.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(info))
        mode = (info.external_attr >> 16) & 0o777
        if mode:
            target.chmod(mode)
    _remove(output)
    staging.rename(output)
    return [lib["LibraryIdentifier"] for lib in plist["AvailableLibraries"]]


def prepare(deps_dir=DEFAULT_DEPS_DIR, output=DEFAULT_OUTPUT, offline=False):
    slices = extract(fetch(deps_dir, offline), output)
    print("Verified WebRTC " + VERSION + ": " + str(len(slices)) + " slices")
    print("  " + ", ".join(slices) + " -> " + str(output))
    return slices


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--deps-dir", type=Path, default=DEFAULT_DEPS_DIR,
                        help="cache directory for the pinned archive (default: clients/ios/out/deps)")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="extracted xcframework path (default: ParanoidKit/Binaries/WebRTC.xcframework)")
    parser.add_argument("--offline", action="store_true",
                        help="never download; fail unless the cached archive already exists")
    args = parser.parse_args(argv)
    prepare(args.deps_dir, args.output, args.offline)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        sys.exit("error: " + str(error))
