#!/usr/bin/env python3
"""Bundle the locked iOS client license texts; no legal/security approval implied.

Same algorithm as clients/android/notices.py: resolve the dependency graph
once, walk it from the root so only crates that actually link are counted,
and copy every license text those crates ship, verbatim. A linked crate whose
package carries no license text is a build error, never a silent skip; the
three crates that publish none upstream (matrix-pickle, matrix-pickle-derive,
jni-sys-macros) are served from the pinned copies recorded in
licenses/README.md.

What differs from the APK: the graph is rooted at bridge/Cargo.toml and
filtered for aarch64-apple-ios, so it carries whatever the shared core pulls
in (call-v2 video calls included); the WebRTC notices are the Apple
xcframework's (licenses/webrtc-150.7871.01/, pinned by webrtc_dependency.py);
and there is no ZXing, no org.json and no Firebase, because this client scans
QR with Vision, parses JSON in Rust and has no push gateway. jni stays in the
graph: the core depends on it unconditionally, so its notices ship here too.

Usage: python3 clients/ios/notices.py [--offline] [--manifest-path P]
       [--output out/THIRD_PARTY_NOTICES.txt]
"""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = IOS_DIR.parent.parent
LICENSES_DIR = IOS_DIR / "licenses"
WEBRTC_NOTICES = LICENSES_DIR / "webrtc-150.7871.01"
MATRIX_PICKLE_LICENSE = (REPO_ROOT / "spikes" / "002-android-bootstrap" / "licenses"
                         / "matrix-pickle-LICENSE")
DEFAULT_MANIFEST = IOS_DIR / "bridge" / "Cargo.toml"
DEFAULT_OUTPUT = IOS_DIR / "out" / "THIRD_PARTY_NOTICES.txt"

TARGET = "aarch64-apple-ios"
HEADER = "Third-party notices for the ParanoID iOS client"
LICENSE_PREFIXES = ("license", "licence", "copying", "notice", "copyright")
# webrtc-sdk/webrtc source commit behind the pinned release, as recorded in
# licenses/webrtc-150.7871.01/PROVENANCE.md. Same source commit as Android.
WEBRTC_SOURCE_COMMIT = "73cb8180f7258ee292878d6edd05177f41883962"


def cargo():
    """The cargo to ask for metadata.

    Non-interactive shells on this Mac do not carry ~/.cargo/bin, and this
    script is also run outside toolchain.sh (the plan's check line runs it
    directly), so fall back to the rustup proxy the wrapper would have added.
    """
    executable = os.environ.get("CARGO", "cargo")
    if shutil.which(executable):
        return executable
    fallback = Path.home() / ".cargo" / "bin" / "cargo"
    if fallback.is_file():
        return str(fallback)
    return executable


def load_metadata(manifest_path=DEFAULT_MANIFEST, offline=False):
    """Resolve the locked graph for the iOS device triple."""
    command = [cargo(), "metadata", "--locked", "--format-version", "1",
               "--filter-platform", TARGET, "--manifest-path", str(manifest_path)]
    if offline:
        command.insert(2, "--offline")
    try:
        return json.loads(subprocess.check_output(command, text=True))
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("cargo metadata failed: " + str(error))


def linked_packages(metadata):
    """Registry crates reachable from the resolve root, sorted by name/version.

    Path packages (the bridge, the core, key-protocol) carry the project's own
    licence and are not third-party notices; unreachable packages are resolved
    for other platforms and never link into the app.
    """
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    if root is None:
        raise RuntimeError("cargo metadata has no resolve root: " + str(metadata.get("workspace_root")))
    active, pending = set(), [root]
    while pending:
        current = pending.pop()
        if current in active:
            continue
        active.add(current)
        pending.extend(dependency["pkg"] for dependency in nodes[current]["deps"])
    return [package for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"]))
            if package["source"] is not None and package["id"] in active]


def pinned_license_files(name):
    """Pinned copies for crates whose published package ships no license text."""
    if name in ("matrix-pickle", "matrix-pickle-derive"):
        return [MATRIX_PICKLE_LICENSE]
    if name == "jni-sys-macros":
        return sorted(LICENSES_DIR.glob("jni-sys-macros-LICENSE-*"))
    return []


def license_texts(package):
    """Return [(label, text)] for one crate, or raise when it has no license text."""
    root = Path(package["manifest_path"]).parent
    packaged = sorted(path for path in root.rglob("*")
                      if path.is_file() and path.name.lower().startswith(LICENSE_PREFIXES))
    if packaged:
        return [(str(path.relative_to(root)), path.read_text(errors="replace")) for path in packaged]
    pinned = [path for path in pinned_license_files(package["name"]) if path.is_file()]
    if not pinned:
        raise RuntimeError("Missing license text: " + package["name"] + " " + package["version"])
    return [(path.name, path.read_text(errors="replace")) for path in pinned]


def crate_notice(package):
    """One crate's block: header line, repository, then every license text."""
    parts = ["\n{0} {1} — {2}\n{3}".format(package["name"], package["version"],
                                           package["license"], package["repository"])]
    for label, text in license_texts(package):
        parts.append(label + "\n" + text)
    return parts


def webrtc_notice():
    """The pinned WebRTC xcframework block: the exact artefact, then its notices."""
    dependency = load_webrtc_dependency()
    parts = ["\nWebRTC SDK for Apple {0} — BSD-3-Clause; upstream notices below\n"
             "https://github.com/webrtc-sdk/Specs/releases/tag/{0}\n"
             "https://github.com/webrtc-sdk/webrtc/tree/{1}\n"
             "Exact artefacts (SHA256-pinned in webrtc_dependency.py):\n"
             "  {2}  {3}".format(dependency.VERSION, WEBRTC_SOURCE_COMMIT,
                                 dependency.ARTIFACT, dependency.ARCHIVE_SHA256)]
    for identifier, digest in sorted(dependency.SLICE_SHA256.items()):
        parts.append("  " + identifier + "  " + digest)
    files = sorted(path for path in WEBRTC_NOTICES.iterdir() if path.is_file()) \
        if WEBRTC_NOTICES.is_dir() else []
    if not files:
        raise RuntimeError("Missing license text: WebRTC " + dependency.VERSION)
    for path in files:
        parts.append(path.name + "\n" + path.read_text(errors="replace"))
    return parts


def load_webrtc_dependency():
    """Import webrtc_dependency.py for the pinned version and hashes."""
    source = IOS_DIR / "webrtc_dependency.py"
    spec = importlib.util.spec_from_file_location("webrtc_dependency", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render(metadata):
    """The whole notices file for a resolved graph."""
    parts = [HEADER]
    for package in linked_packages(metadata):
        parts.extend(crate_notice(package))
    parts.extend(webrtc_notice())
    return "\n".join(parts)


def write(manifest_path=DEFAULT_MANIFEST, output=DEFAULT_OUTPUT, offline=False):
    """Resolve, render and write the notices; return (crate count, byte count)."""
    metadata = load_metadata(manifest_path, offline)
    text = render(metadata)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)
    return len(linked_packages(metadata)), len(text.encode())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest-path", type=Path, default=DEFAULT_MANIFEST,
                        help="crate whose locked graph is bundled (default: clients/ios/bridge/Cargo.toml)")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="notices file to write (default: clients/ios/out/THIRD_PARTY_NOTICES.txt)")
    parser.add_argument("--offline", action="store_true",
                        help="never let cargo touch the network; fail on a missing registry source")
    args = parser.parse_args(argv)
    crates, size = write(args.manifest_path, args.output, args.offline)
    print("Wrote " + str(args.output) + ": " + str(crates) + " crates + WebRTC "
          + load_webrtc_dependency().VERSION + ", " + str(size) + " bytes")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        sys.exit("error: " + str(error))
