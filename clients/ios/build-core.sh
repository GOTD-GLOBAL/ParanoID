#!/usr/bin/env bash
# Build the Rust core bridge for iOS and assemble ParanoidCore.xcframework.
#
# Three `--locked --release` slices of `bridge/` (device, simulator, macOS host
# for the Swift unit tests) are built with the pinned toolchain into
# out/bridge-target, then combined with `xcodebuild -create-xcframework` into
# ParanoidKit/Binaries/ParanoidCore.xcframework (git-ignored, referenced by the
# SwiftPM binaryTarget without any `..`). Only the `staticlib`
# (libparanoid_ios_bridge.a) enters the xcframework; the `rlib` is a host-test
# artefact. SHA-256 digests of the three archives, of the exported headers and
# the tool versions are written to out/evidence/bridge-hashes.json.
#
# Usage: bash clients/ios/build-core.sh
# Re-executes itself through toolchain.sh so ~/.cargo/bin is on PATH in
# non-interactive shells. Logs: out/logs/build-core.log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PARANOID_IOS_TOOLCHAIN:-}" ]; then
  PARANOID_IOS_TOOLCHAIN=1 exec bash "$HERE/toolchain.sh" bash "$HERE/build-core.sh" "$@"
fi
if [ "$#" -ne 0 ]; then
  echo "usage: build-core.sh (no arguments)" >&2
  exit 64
fi

RUST_TOOLCHAIN="1.98.1"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
LIBRARY="libparanoid_ios_bridge.a"
MANIFEST="$HERE/bridge/Cargo.toml"
HEADERS="$HERE/bridge/include"
OUT="$HERE/out"
TARGET_DIR="$OUT/bridge-target"
XCFRAMEWORK="$HERE/ParanoidKit/Binaries/ParanoidCore.xcframework"
EVIDENCE="$OUT/evidence/bridge-hashes.json"
LOG="$OUT/logs/build-core.log"

mkdir -p "$OUT/logs" "$OUT/evidence" "$(dirname "$XCFRAMEWORK")"
: >"$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; log "log: $LOG"; exit 1; }

log "build-core: toolchain $RUST_TOOLCHAIN, targets ${TARGETS[*]}"
for tool in cargo rustc xcodebuild lipo plutil python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found on PATH (run through toolchain.sh)"
done

# 1. Three locked release builds; the archive path is fixed by cargo.
ARCHIVES=()
for target in "${TARGETS[@]}"; do
  log "cargo build --locked --release --target $target"
  cargo "+$RUST_TOOLCHAIN" build --locked --release --target "$target" \
    --manifest-path "$MANIFEST" --target-dir "$TARGET_DIR" >>"$LOG" 2>&1 \
    || fail "cargo build for $target failed"
  archive="$TARGET_DIR/$target/release/$LIBRARY"
  [ -f "$archive" ] || fail "missing $archive"
  case "$(lipo -info "$archive" 2>>"$LOG")" in
    *"is architecture: arm64") ;;
    *) fail "$archive is not a single-architecture arm64 archive" ;;
  esac
  ARCHIVES+=("$archive")
done

# 2. Assemble the xcframework from the static libraries only (never the rlib).
# xcodebuild refuses to overwrite, so the previous bundle is removed first.
rm -rf "$XCFRAMEWORK"
XCARGS=()
for archive in "${ARCHIVES[@]}"; do
  XCARGS+=(-library "$archive" -headers "$HEADERS")
done
log "xcodebuild -create-xcframework -> ${XCFRAMEWORK#"$HERE/"}"
xcodebuild -create-xcframework "${XCARGS[@]}" -output "$XCFRAMEWORK" >>"$LOG" 2>&1 \
  || fail "xcodebuild -create-xcframework failed"
slices="$(plutil -p "$XCFRAMEWORK/Info.plist" | grep -c LibraryIdentifier || true)"
[ "$slices" = "${#TARGETS[@]}" ] || fail "expected ${#TARGETS[@]} xcframework slices, found $slices"
for archive in "$XCFRAMEWORK"/*/"$LIBRARY"; do
  case "$(lipo -info "$archive" 2>>"$LOG")" in
    *"is architecture: arm64") ;;
    *) fail "$archive inside the xcframework is not arm64" ;;
  esac
  [ -f "$(dirname "$archive")/Headers/paranoid_core.h" ] || fail "headers missing next to $archive"
done

# 3. Evidence: SHA-256 of every slice archive and header plus tool versions
# (same hashlib.sha256 discipline as clients/android/test_realtime.py).
HERE="$HERE" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" TARGET_DIR="$TARGET_DIR" LIBRARY="$LIBRARY" \
XCFRAMEWORK="$XCFRAMEWORK" HEADERS="$HEADERS" EVIDENCE="$EVIDENCE" TARGETS="${TARGETS[*]}" \
python3 - <<'PY' >>"$LOG" 2>&1 || fail "evidence generation failed"
import hashlib, json, os, plistlib, subprocess
from datetime import datetime, timezone
from pathlib import Path

here = Path(os.environ["HERE"])
toolchain = os.environ["RUST_TOOLCHAIN"]
xcframework = Path(os.environ["XCFRAMEWORK"])
headers = Path(os.environ["HEADERS"])


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version(argv):
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()


def rel(path):
    return str(path.relative_to(here))


with open(xcframework / "Info.plist", "rb") as handle:
    plist = plistlib.load(handle)
identifiers = {}
for entry in plist["AvailableLibraries"]:
    identifiers[entry["LibraryIdentifier"]] = entry

slices = {}
for target in os.environ["TARGETS"].split():
    archive = Path(os.environ["TARGET_DIR"]) / target / "release" / os.environ["LIBRARY"]
    slices[target] = {
        "library": rel(archive),
        "size": archive.stat().st_size,
        "sha256": sha256(archive),
    }
for identifier, entry in identifiers.items():
    installed = xcframework / identifier / entry["LibraryPath"]
    digest = sha256(installed)
    match = [t for t, s in slices.items() if s["sha256"] == digest]
    if len(match) != 1:
        raise SystemExit(f"xcframework slice {identifier} does not match exactly one built archive")
    slices[match[0]].update({
        "library_identifier": identifier,
        "platform": entry.get("SupportedPlatform"),
        "platform_variant": entry.get("SupportedPlatformVariant"),
        "architectures": entry.get("SupportedArchitectures"),
    })

commit = version(["git", "-C", str(here), "rev-parse", "HEAD"])
evidence = {
    "generated": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "commit": commit,
    "script": rel(here / "build-core.sh"),
    "toolchain": {
        "rustc": version(["rustc", f"+{toolchain}", "--version"]),
        "cargo": version(["cargo", f"+{toolchain}", "--version"]),
        "xcodebuild": " ".join(version(["xcodebuild", "-version"]).split()),
        "ios_sdk": version(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]),
    },
    "bridge_lock_sha256": sha256(here / "bridge" / "Cargo.lock"),
    "headers": {rel(path): sha256(path) for path in sorted(headers.iterdir()) if path.is_file()},
    "slices": slices,
    "xcframework": {
        "path": rel(xcframework),
        "info_plist_sha256": sha256(xcframework / "Info.plist"),
        "library_identifiers": sorted(identifiers),
    },
}
out = Path(os.environ["EVIDENCE"])
out.write_text(json.dumps(evidence, indent=2) + "\n")
print(f"evidence: {out}")
PY

log "OK: ${XCFRAMEWORK#"$HERE/"} ($slices slices, arm64), evidence ${EVIDENCE#"$HERE/"}"
