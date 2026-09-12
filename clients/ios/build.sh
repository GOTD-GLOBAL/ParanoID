#!/usr/bin/env bash
# The whole iOS client build, in order, with every gate on the way (RFC-0021,
# draft ADR-0014). The counterpart of clients/android/build.sh.
#
# Each step runs after the one before it and the script stops at the first
# failure; a green run means the pinned toolchain matched, the pinned WebRTC
# archive matched, the bridge lock matched clients/core, the shared core and
# the bridge passed their tests, ParanoidKit passed its suite, the pinned TLS
# and transport harnesses passed against real loopback servers, the notices
# were regenerated, the source contracts held, the simulator ran both test
# bundles and the device build produced out/ParanoID.app, which
# test_app_bundle.py then took apart.
#
# What this script does NOT do, and says so out loud when it reaches that
# place in the chain:
#
#   * the Android cross-test (plan steps 33-34) needs a JDK, which this Mac
#     does not have; the step prints SKIP with that reason and the manifest
#     records it as skipped. It is never a silent pass.
#   * the archive and the export are the owner's signing gate. Without
#     PARANOID_IOS_TEAM_ID in the environment the script prints
#     "Archive skipped: PARANOID_IOS_TEAM_ID unset" and exits 0. Nothing here
#     creates, copies or prints a signing identity, and no step contacts the
#     hosted server.
#
# Usage: bash clients/ios/build.sh            (no arguments)
# Environment (all optional):
#   PARANOID_IOS_TEAM_ID    Apple team; set only for an authorized archive.
#   PARANOID_ASC_KEY_ID / PARANOID_ASC_ISSUER_ID / PARANOID_ASC_KEY_PATH
#                           App Store Connect API key for -allowProvisioningUpdates
#                           on a machine without an Xcode account. Read from the
#                           environment only; the .p8 stays outside the repository.
#   PARANOID_IOS_SIMULATOR  xcodebuild -destination for the simulator run.
# Outputs (all git-ignored): out/ParanoID.app, out/logs/, out/evidence/,
# out/evidence/build-manifest.json.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PARANOID_IOS_TOOLCHAIN:-}" ]; then
  PARANOID_IOS_TOOLCHAIN=1 exec bash "$HERE/toolchain.sh" bash "$HERE/build.sh" "$@"
fi
if [ "$#" -ne 0 ]; then
  echo "usage: build.sh (no arguments)" >&2
  exit 64
fi
cd "$HERE"
umask 077

RUST_TOOLCHAIN="1.98.1"
PROJECT="App/ParanoID.xcodeproj"
SCHEME="ParanoID"
SIMULATOR="${PARANOID_IOS_SIMULATOR:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
DERIVED="out/DerivedData-build"
DERIVED_SIGNED="out/DerivedData-build-signed"
APP="out/ParanoID.app"
ARCHIVE="out/ParanoID.xcarchive"
EXPORT_DIR="out/export"
EXPORT_TEMPLATE="App/ExportOptions.plist"
EXPORT_RESOLVED="out/ExportOptions.plist"
MANIFEST="out/evidence/build-manifest.json"
STEPS="out/logs/build-steps.tsv"

mkdir -p out/logs out/evidence
: >"$STEPS"
INDEX=0
CURRENT="startup"
trap 'echo ""; echo "FAIL: step ${INDEX} (${CURRENT}) failed; nothing further ran"' ERR

# record <name> <status> <seconds> <detail>
record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$STEPS"
}

# step <name> <command...> — run one gate, timed, and record it.
step() {
  local name="$1"
  shift
  INDEX=$((INDEX + 1))
  CURRENT="$name"
  local started=$SECONDS
  printf '\n==> [%d] %s\n' "$INDEX" "$name"
  "$@"
  record "$name" ok "$((SECONDS - started))" "$*"
}

# skip <name> <reason> — a gate that did not run, said out loud.
skip() {
  INDEX=$((INDEX + 1))
  printf '\n==> [%d] %s\n' "$INDEX" "$1"
  printf 'SKIP: %s\n' "$2"
  record "$1" skipped 0 "$2"
}

# 1-4. The pins: tools, the WebRTC archive, and the Rust lock against Android.
step "toolchain pins" python3 test_toolchain.py
step "WebRTC xcframework (pinned 150.7871.01)" python3 webrtc_dependency.py
step "WebRTC pin rules" python3 test_webrtc_dependency.py
step "bridge lock == clients/core lock" python3 test_bridge_lock.py

# 5. The shared core, in the release profile the application ships, with the
# same test targets as clients/android/build.sh:25. clients/core is a red zone:
# it is built and tested from here, never modified, and its own target/ is left
# alone (--target-dir out/core-target).
step "shared core tests (release)" \
  cargo "+$RUST_TOOLCHAIN" test --offline --locked --release \
  --manifest-path ../core/Cargo.toml --target-dir out/core-target \
  --lib --test clean_first_contact --test realtime_signing --test voice_calls

# 6. The C-ABI bridge on the host, where the rlib and tests/abi.rs live.
step "bridge ABI tests (host)" \
  cargo "+$RUST_TOOLCHAIN" test --offline --locked \
  --manifest-path bridge/Cargo.toml --target-dir out/bridge-target

# 7-8. The three release slices, the xcframework, and the Swift package suite.
step "ParanoidCore.xcframework" bash build-core.sh
step "ParanoidKit tests" swift test --package-path ParanoidKit --scratch-path out/spm

# 9. Plan steps 33-34. The Java side of the cross-test needs a JDK; when
# java_deps.sh lands and a JDK exists, this becomes a real run.
if [ -x java_deps.sh ] && [ -f test_android_compatibility.py ] && command -v javac >/dev/null 2>&1; then
  step "Android cross-test (Java host)" bash java_deps.sh
  step "iOS <-> Android protocol compatibility" python3 test_android_compatibility.py --evidence-dir out/checks/compat
  step "QR cross-check" python3 test_qr_cross.py
elif [ -x java_deps.sh ] && [ -f test_android_compatibility.py ]; then
  skip "iOS <-> Android cross-test (plan steps 33-34)" \
    "no JDK on this machine: javac not found, so java_deps.sh cannot build the Android facade. Install openjdk@21 and re-run; this gate did NOT pass."
else
  skip "iOS <-> Android cross-test (plan steps 33-34)" \
    "no JDK on this machine (javac not found) and clients/ios/java_deps.sh has not landed. The cross-test did NOT run and did NOT pass."
fi

# 10-11. Real sockets: nine pinned-TLS fixtures and the eight transport rules.
step "pinned TLS handshakes" python3 check-pinned-tls.py
step "realtime transport rules" python3 test_realtime_transport.py --evidence-dir out/checks/transport

# 12-13. The notices that ship inside the bundle, and their own gate.
step "third-party notices" python3 notices.py --offline
step "notices rules" python3 test_notices.py

# 14-15. Source contracts: the captions/stand guard/Info.plist, and the branch
# boundary (no red-zone file may be touched by a committed change).
step "UI contract" python3 test_ui_contract.py
step "component boundary" python3 test_component_boundary.py

# 16. The simulator, unsigned. KeychainStoreTests is excluded here on purpose:
# an unsigned application has no Keychain access of its own, so it runs in 17.
step "simulator tests (unsigned)" \
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$SIMULATOR" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO -skip-testing:ParanoIDTests/KeychainStoreTests

# 17. The same simulator, signed the way a simulator signs itself: ad hoc, no
# team, no identity of the owner's. This is the only run where the application
# owns a Keychain, which is what KeychainStoreTests is about.
step "simulator Keychain tests (ad-hoc signature)" \
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$SIMULATOR" -derivedDataPath "$DERIVED_SIGNED" \
  -only-testing:ParanoIDTests/KeychainStoreTests

# 18. The device build. Release, unsigned, and copied to out/ParanoID.app so
# the bundle gate always reads a freshly built bundle.
build_device() {
  rm -rf "$APP"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build
  ditto "$DERIVED/Build/Products/Release-iphoneos/ParanoID.app" "$APP"
}
step "device build (Release, unsigned)" build_device

# 19. What that bundle actually contains.
step "application bundle" python3 test_app_bundle.py "$APP"

# 20. The owner's signing gate. Everything above runs without it.
archive_and_export() {
  local auth=()
  if [ -n "${PARANOID_ASC_KEY_ID:-}" ] && [ -n "${PARANOID_ASC_ISSUER_ID:-}" ] && [ -n "${PARANOID_ASC_KEY_PATH:-}" ]; then
    if [ ! -f "$PARANOID_ASC_KEY_PATH" ]; then
      echo "FAIL: PARANOID_ASC_KEY_PATH does not point at a file" >&2
      return 1
    fi
    # Values come from the environment; the key file itself is never copied
    # into the repository and never printed.
    auth=(-authenticationKeyID "$PARANOID_ASC_KEY_ID"
          -authenticationKeyIssuerID "$PARANOID_ASC_ISSUER_ID"
          -authenticationKeyPath "$PARANOID_ASC_KEY_PATH")
  fi
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  # DEVELOPMENT_TEAM reaches the build through App/Config/Bundle.xcconfig,
  # which reads $(PARANOID_IOS_TEAM_ID) from this environment; it is not
  # written into the project and not passed on the command line.
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
  python3 - "$EXPORT_TEMPLATE" "$EXPORT_RESOLVED" <<'PY'
import os, plistlib, sys
template, resolved = sys.argv[1], sys.argv[2]
with open(template, "rb") as handle:
    options = plistlib.load(handle)
options["teamID"] = os.environ["PARANOID_IOS_TEAM_ID"]
with open(resolved, "wb") as handle:
    plistlib.dump(options, handle)
print("export options: " + resolved + " (teamID from the environment)")
PY
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_RESOLVED" ${auth[@]+"${auth[@]}"}
  python3 test_app_bundle.py "$ARCHIVE/Products/Applications/ParanoID.app" \
    --evidence out/evidence/app-bundle-signed.json
}
if [ -n "${PARANOID_IOS_TEAM_ID:-}" ]; then
  step "archive and export (owner-authorized)" archive_and_export
else
  INDEX=$((INDEX + 1))
  printf '\n==> [%d] archive and export\n' "$INDEX"
  echo "Archive skipped: PARANOID_IOS_TEAM_ID unset"
  record "archive and export" skipped 0 "PARANOID_IOS_TEAM_ID unset"
fi

# The manifest: what was built, from what, with which versions and digests.
CURRENT="build manifest"
MANIFEST="$MANIFEST" STEPS="$STEPS" APP="$APP" ARCHIVE="$ARCHIVE" \
RUST_TOOLCHAIN="$RUST_TOOLCHAIN" SIMULATOR="$SIMULATOR" python3 - <<'PY'
import hashlib, json, os, plistlib, subprocess
from datetime import datetime, timezone
from pathlib import Path

here = Path.cwd()
app = Path(os.environ["APP"])


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def version(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return f"unavailable: {error}"


steps = []
for line in Path(os.environ["STEPS"]).read_text().splitlines():
    name, status, seconds, detail = line.split("\t", 3)
    steps.append({"step": name, "status": status, "seconds": int(seconds), "detail": detail})

with open(app / "Info.plist", "rb") as handle:
    info = plistlib.load(handle)

artifacts = {}
for label, path in (
    ("ParanoID.app/ParanoID", app / "ParanoID"),
    ("ParanoID.app/Frameworks/WebRTC.framework/WebRTC", app / "Frameworks/WebRTC.framework/WebRTC"),
    ("ParanoID.app/THIRD_PARTY_NOTICES.txt", app / "THIRD_PARTY_NOTICES.txt"),
    ("out/THIRD_PARTY_NOTICES.txt", here / "out/THIRD_PARTY_NOTICES.txt"),
    ("bridge/Cargo.lock", here / "bridge/Cargo.lock"),
    ("../core/Cargo.lock", here / "../core/Cargo.lock"),
):
    if path.is_file():
        artifacts[label] = {"sha256": sha256(path), "size": path.stat().st_size}

bridge = here / "out/evidence/bridge-hashes.json"
manifest = {
    "generated": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "script": "clients/ios/build.sh",
    "commit": version(["git", "-C", str(here), "rev-parse", "HEAD"]),
    "branch": version(["git", "-C", str(here), "rev-parse", "--abbrev-ref", "HEAD"]),
    "toolchain": {
        "rustc": version(["rustc", f"+{os.environ['RUST_TOOLCHAIN']}", "--version"]),
        "cargo": version(["cargo", f"+{os.environ['RUST_TOOLCHAIN']}", "--version"]),
        "swift": version(["swift", "--version"]).splitlines()[0],
        "xcodebuild": " ".join(version(["xcodebuild", "-version"]).split()),
        "ios_sdk": version(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]),
        "python": version(["python3", "--version"]),
        "simulator": os.environ["SIMULATOR"],
    },
    "bundle": {
        "identifier": info.get("CFBundleIdentifier"),
        "short_version": info.get("CFBundleShortVersionString"),
        "build_version": info.get("CFBundleVersion"),
        "minimum_os_version": info.get("MinimumOSVersion"),
        "platforms": info.get("CFBundleSupportedPlatforms"),
        "background_modes": info.get("UIBackgroundModes"),
        "signed": (app / "_CodeSignature").exists(),
        "path": os.environ["APP"],
    },
    "artifacts": artifacts,
    "bridge": json.loads(bridge.read_text()) if bridge.is_file() else None,
    "archive": os.environ["ARCHIVE"] if Path(os.environ["ARCHIVE"]).exists() else None,
    "steps": steps,
}
out = Path(os.environ["MANIFEST"])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
ok = sum(1 for entry in steps if entry["status"] == "ok")
skipped = [entry["step"] for entry in steps if entry["status"] == "skipped"]
print(f"\nmanifest: {os.environ['MANIFEST']}")
print(f"OK: {ok} step(s) passed, {len(skipped)} skipped" + (": " + "; ".join(skipped) if skipped else ""))
print(f"bundle: {os.environ['APP']} {info.get('CFBundleIdentifier')} "
      f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
PY
