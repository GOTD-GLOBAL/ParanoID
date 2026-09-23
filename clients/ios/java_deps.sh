#!/usr/bin/env bash
# Prepare the host Java side of the iOS/Android cross-checks.
#
# The iOS client is checked against the Android client by running both over the
# same shared Rust core on this Mac. This script builds that host side and
# nothing else: it never installs a package, never touches a phone or a server,
# and never writes anywhere but out/ (git-ignored).
#
# What it does, in order:
#   1. Reads the JDK pin from toolchain.json (`java_home`, `jdk`) and refuses a
#      different javac/java. JDK 21 is installed already; this script does not
#      install one.
#   2. Builds the shared core as a host cdylib with the pinned Rust toolchain
#      into out/core-target, so libparanoid_client_core.dylib exists for the
#      JNI facade. clients/core and its own target/ are never written to.
#   3. Names every source of clients/android/src/org/paranoid/text/ exactly
#      once and refuses an unnamed one, refuses to compile any Java source
#      carrying an `import android` line, checks that every class named
#      Android-only still carries one, and checks that the classes left out
#      for another reason carry none.
#   4. Fetches the two pinned Maven jars, whose SHA-256 digests are imported
#      from clients/android/dependencies.py, into out/host-java. The Android
#      tree stays read-only: nothing is written under clients/android/, and the
#      import of that module runs with bytecode caching off so it leaves no
#      __pycache__ behind either.
#   5. Compiles the named Android facade classes plus the four host fixtures
#      with `javac --release 8 -Xlint:-options`, the flags of
#      .github/workflows/server.yml:111. The other Android compilation of the
#      same facade, clients/android/test_voice_v8_compatibility.py:128, shares
#      the `--release 8` target but does not pass -Xlint:-options.
#   6. Writes out/evidence/java-host.json: tool versions, the digest of the
#      cdylib and of every jar, and the SHA-256 of every compiled Java file,
#      each one marked identical to or advanced past the Android v15 reference
#      commit fe9c26c, beside the two left-out groups by name and the count of
#      facade sources the three groups account for.
#
# Usage: bash clients/ios/java_deps.sh
# Re-executes itself through toolchain.sh so ~/.cargo/bin is on PATH in
# non-interactive shells. Logs: out/logs/java-deps.log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PARANOID_IOS_TOOLCHAIN:-}" ]; then
  PARANOID_IOS_TOOLCHAIN=1 exec bash "$HERE/toolchain.sh" bash "$HERE/java_deps.sh" "$@"
fi
if [ "$#" -ne 0 ]; then
  echo "usage: java_deps.sh (no arguments)" >&2
  exit 64
fi

ROOT="$(cd "$HERE/../.." && pwd)"
RUST_TOOLCHAIN="1.98.1"
# Android v15, the behavioural reference of this client. Two of the compiled
# classes have moved past it on main (call-v2 video, the push wake gateway);
# the evidence says which, per file, instead of claiming the whole set is v15.
ANDROID_REFERENCE="fe9c26c"
LIBRARY="libparanoid_client_core.dylib"
OUT="$HERE/out"
TARGET_DIR="$OUT/core-target"
HOST_JAVA="$OUT/host-java"
CLASSES="$HOST_JAVA/classes"
EVIDENCE="$OUT/evidence/java-host.json"
LOG="$OUT/logs/java-deps.log"

# The named list of Android facade classes compiled for the host JVM. Every
# one of them is free of the Android framework and reaches the core through
# CoreBridge's JNI entry point.
FACADE=(CoreBridge SelfServiceClient SnapshotCodec KeyClient KeyTransport PinnedTls
        SyncCycle QrCodec StorageGuard DialogPolicy MessagePresentation RealtimeLoop
        RealtimeTransport VoiceRelayConfig VoiceRelayTransport CallController)
# Android classes deliberately left out: each one imports the Android
# framework, so it has no host counterpart and nothing here compiles it.
ANDROID_ONLY=(MainActivity TextEngine QrScanActivity WebRtcAudioEngine VoiceCallService
              BackgroundConnectionService ConnectionWatchdog UpdateController UpdateProvider
              AndroidUpdateVerifier CallTones ContactNames CrashLog)
# Left out although free of the Android framework, so the split above is not
# read as "everything else compiles here": PushService extends Firebase's
# messaging service, a Google SDK that is not on this host classpath (the iOS
# wake path is APNs, RFC-0020); UpdateClient, UpdateManifest and UpdatePolicy
# are the Android in-app APK update flow, which the iOS client does not have
# (its builds are installed by hand; no TestFlight build exists yet). Nothing
# on the iOS side compares against any of the four.
NOT_COMPARED=(PushService UpdateClient UpdateManifest UpdatePolicy)
# Host fixtures: the Android JNI/codec pipe, the Android stand client, and the
# two iOS cross-check pipes.
FIXTURES=(clients/android/test/VoiceCoreBridge.java
          clients/android/test/CleanSelfServiceBridge.java
          clients/ios/test/java/JavaCodecVector.java
          clients/ios/test/java/QrCross.java)

mkdir -p "$OUT/logs" "$OUT/evidence" "$HOST_JAVA"
: >"$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; log "log: $LOG"; exit 1; }

pin() {
  python3 -c 'import json,sys
data = json.load(open(sys.argv[1]))
if sys.argv[2] not in data:
    raise SystemExit(1)
print(data[sys.argv[2]])' "$HERE/toolchain.json" "$1" 2>/dev/null
}

JAVA_HOME_PIN="$(pin java_home)" || fail "toolchain.json lacks the java_home pin"
JDK_PIN="$(pin jdk)" || fail "toolchain.json lacks the jdk pin"
JAVAC="$JAVA_HOME_PIN/bin/javac"
JAVA_TOOL="$JAVA_HOME_PIN/bin/java"
log "java_deps: JDK $JDK_PIN at $JAVA_HOME_PIN, Rust $RUST_TOOLCHAIN"

# 1. The pinned JDK, and only it. The keg-only Homebrew JDK is not on PATH.
for tool in "$JAVAC" "$JAVA_TOOL"; do
  [ -x "$tool" ] || fail "$tool is not executable (expected the pinned JDK of toolchain.json)"
done
for tool in cargo rustc python3 git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found on PATH (run through toolchain.sh)"
done
JAVAC_VERSION="$("$JAVAC" -version 2>&1 | head -1)"
JAVA_VERSION_LINE="$("$JAVA_TOOL" -version 2>&1 | head -1)"
JAVA_VERSION="$(printf '%s' "$JAVA_VERSION_LINE" | sed -n 's/.*"\([^"]*\)".*/\1/p')"
[ "$JAVAC_VERSION" = "javac $JDK_PIN" ] \
  || fail "expected javac $JDK_PIN, got '$JAVAC_VERSION'"
[ "$JAVA_VERSION" = "$JDK_PIN" ] \
  || fail "expected java $JDK_PIN, got '$JAVA_VERSION_LINE'"
log "$JAVAC_VERSION"
log "java $JAVA_VERSION"

# 2. The shared core as a host cdylib. The core's own target/ is never used.
log "cargo build --locked (host cdylib) -> ${TARGET_DIR#"$HERE/"}"
cargo "+$RUST_TOOLCHAIN" build --locked --manifest-path "$ROOT/clients/core/Cargo.toml" \
  --target-dir "$TARGET_DIR" >>"$LOG" 2>&1 || fail "cargo build of the host core failed"
NATIVE="$TARGET_DIR/debug/$LIBRARY"
[ -f "$NATIVE" ] || fail "missing $NATIVE"

# 3. Every source of the facade directory is named exactly once by the three
# lists above, and each list is checked in both directions, so neither the
# split nor the coverage can rot silently as the Android client grows: nothing
# carrying the Android framework is compiled, nothing named Android-only has
# stopped carrying it, and nothing left out for another reason carries it.
FACADE_DIR="clients/android/src/org/paranoid/text"
NAMED=("${FACADE[@]}" "${ANDROID_ONLY[@]}" "${NOT_COMPARED[@]}")
FACADE_COUNT=0
for path in "$ROOT/$FACADE_DIR"/*.java; do
  name="$(basename "$path" .java)"
  times=0
  for named in "${NAMED[@]}"; do
    if [ "$named" = "$name" ]; then times=$((times + 1)); fi
  done
  [ "$times" -eq 1 ] \
    || fail "$FACADE_DIR/$name.java is named $times times in java_deps.sh; each source there is compiled, Android-only or left out host-free, exactly once"
  FACADE_COUNT=$((FACADE_COUNT + 1))
done
[ "$FACADE_COUNT" -eq "${#NAMED[@]}" ] \
  || fail "java_deps.sh names ${#NAMED[@]} classes but $FACADE_DIR holds $FACADE_COUNT sources"
SOURCES=()
for name in "${FACADE[@]}"; do
  SOURCES+=("$FACADE_DIR/$name.java")
done
SOURCES+=("${FIXTURES[@]}")
ABSOLUTE=()
for relative in "${SOURCES[@]}"; do
  path="$ROOT/$relative"
  [ -f "$path" ] || fail "missing $relative"
  ! grep -q '^import android' "$path" \
    || fail "$relative imports the Android framework and cannot be compiled for the host"
  ABSOLUTE+=("$path")
done
for name in "${ANDROID_ONLY[@]}"; do
  path="$ROOT/$FACADE_DIR/$name.java"
  [ -f "$path" ] || fail "missing $FACADE_DIR/$name.java"
  grep -q '^import android' "$path" \
    || fail "$name is excluded from the host build but no longer imports the Android framework"
done
for name in "${NOT_COMPARED[@]}"; do
  path="$ROOT/$FACADE_DIR/$name.java"
  [ -f "$path" ] || fail "missing $FACADE_DIR/$name.java"
  ! grep -q '^import android' "$path" \
    || fail "$name is left out as free of the Android framework but now imports it; it belongs in the Android-only list"
done
log "sources: ${#ABSOLUTE[@]} compiled, ${#ANDROID_ONLY[@]} Android-only and ${#NOT_COMPARED[@]} host-free left out, all $FACADE_COUNT facade sources named"

# 4. The two pinned jars, digests imported from clients/android/dependencies.py
# so there is one set of pins. Nothing is written under clients/android/: the
# interpreter runs with -B, so importing that module writes no __pycache__ next
# to it. The module is read for its pins only; it executes no network call.
JAR_LIST="$HOST_JAVA/pinned-jars.txt"
rm -f "$JAR_LIST"
ROOT="$ROOT" HOST_JAVA="$HOST_JAVA" JAR_LIST="$JAR_LIST" \
python3 -B - <<'PY' >>"$LOG" 2>&1 || fail "dependency integrity check failed"
import hashlib, importlib.util, os, sys, urllib.request
from pathlib import Path

# -B already sets this; setting it here too keeps the guarantee with the code
# that depends on it, whoever runs the block.
sys.dont_write_bytecode = True

root = Path(os.environ["ROOT"])
destination = Path(os.environ["HOST_JAVA"])
spec = importlib.util.spec_from_file_location("android_dependencies", root / "clients/android/dependencies.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
names = []
for name, (path, expected) in sorted(module.DEPS.items()):
    target = destination / name
    if target.exists():
        data = target.read_bytes()
    else:
        with urllib.request.urlopen("https://repo.maven.apache.org/maven2/" + path, timeout=30) as response:
            data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit("dependency integrity check failed: " + name)
    if not target.exists():
        target.write_bytes(data)
    names.append(name)
    print("Verified SHA256: " + name)
# The classpath is built from these names, never from a glob, so a jar left
# behind by some other run cannot slip into the compilation or the evidence.
Path(os.environ["JAR_LIST"]).write_text("\n".join(names) + "\n")
PY
JARS=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -f "$HOST_JAVA/$name" ] || fail "pinned jar $name is missing from ${HOST_JAVA#"$HERE/"}"
  JARS+=("$HOST_JAVA/$name")
done <"$JAR_LIST"
[ "${#JARS[@]}" -gt 0 ] || fail "clients/android/dependencies.py declared no jar"
CLASSPATH="$(IFS=:; printf '%s' "${JARS[*]}")"
log "dependencies: ${#JARS[@]} pinned jars in ${HOST_JAVA#"$HERE/"}"

# 5. One compilation, the flags of server.yml:111. A stale class directory
# would hide a source that stopped compiling, so it is rebuilt from scratch.
rm -rf "$CLASSES"
mkdir -p "$CLASSES"
log "javac --release 8 -Xlint:-options -> ${CLASSES#"$HERE/"}"
"$JAVAC" --release 8 -Xlint:-options -cp "$CLASSPATH" -d "$CLASSES" "${ABSOLUTE[@]}" \
  >>"$LOG" 2>&1 || fail "host Java compilation failed"
CLASS_COUNT="$(find "$CLASSES" -name '*.class' | wc -l | tr -d ' ')"
[ "$CLASS_COUNT" -gt 0 ] || fail "compilation produced no class files"

# 6. Evidence. Every path is repository-relative and the text is refused if it
# carries anything of this machine, the standard of test_voice_sim.py:490-504.
ROOT="$ROOT" HERE="$HERE" EVIDENCE="$EVIDENCE" NATIVE="$NATIVE" CLASSES="$CLASSES" \
HOST_JAVA="$HOST_JAVA" JAR_LIST="$JAR_LIST" CLASS_COUNT="$CLASS_COUNT" REFERENCE="$ANDROID_REFERENCE" \
SOURCES="${SOURCES[*]}" ANDROID_ONLY="${ANDROID_ONLY[*]}" NOT_COMPARED="${NOT_COMPARED[*]}" \
FACADE_COUNT="$FACADE_COUNT" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" \
JAVA_HOME_PIN="$JAVA_HOME_PIN" JDK_PIN="$JDK_PIN" JAVAC_VERSION="$JAVAC_VERSION" \
JAVA_VERSION="$JAVA_VERSION" \
python3 - <<'PY' >>"$LOG" 2>&1 || fail "evidence generation failed"
import hashlib, json, os, re, subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ["ROOT"])
reference = os.environ["REFERENCE"]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.run(["git", "-C", str(root), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def version(argv):
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()


def at_reference(relative):
    """The blob of `relative` at the reference commit, or None when absent."""
    completed = subprocess.run(["git", "-C", str(root), "show", f"{reference}:{relative}"],
                               capture_output=True, check=False)
    return completed.stdout if completed.returncode == 0 else None


reference_sha = git("rev-parse", f"{reference}^{{commit}}")
compiled = {}
for relative in os.environ["SOURCES"].split():
    raw = (root / relative).read_bytes()
    original = at_reference(relative)
    if original is None:
        state = "not in reference"
    elif original == raw:
        state = "identical to reference"
    else:
        state = "advanced past reference"
    compiled[relative] = {"sha256": sha256(raw), "bytes": len(raw), "android_v15": state}

jars = {}
host_java = Path(os.environ["HOST_JAVA"])
for name in Path(os.environ["JAR_LIST"]).read_text().split():
    data = (host_java / name).read_bytes()
    jars[name] = {"sha256": sha256(data), "bytes": len(data)}

native = Path(os.environ["NATIVE"])
evidence = {
    "generated": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "commit": git("rev-parse", "HEAD"),
    "script": "clients/ios/java_deps.sh",
    "android_reference": {
        "commit": reference_sha,
        "label": "Android client v15",
        "note": "Two compiled classes have moved past v15 on main (call-v2 video, "
                "the push wake gateway); android_v15 below says which, per file.",
    },
    "toolchain": {
        "java_home": os.environ["JAVA_HOME_PIN"],
        "jdk": os.environ["JDK_PIN"],
        "javac": os.environ["JAVAC_VERSION"],
        "java": os.environ["JAVA_VERSION"],
        "javac_flags": ["--release", "8", "-Xlint:-options"],
        "rustc": version(["rustc", f"+{os.environ['RUST_TOOLCHAIN']}", "--version"]),
        "cargo": version(["cargo", f"+{os.environ['RUST_TOOLCHAIN']}", "--version"]),
    },
    "core_library": {
        "path": str(native.relative_to(root)),
        "sha256": sha256(native.read_bytes()),
        "bytes": native.stat().st_size,
    },
    "dependencies": jars,
    "compiled": compiled,
    # The three lists together account for every source of the Android facade
    # directory; the run fails if one of them is unnamed there.
    "facade_sources": int(os.environ["FACADE_COUNT"]),
    "android_only_not_compiled": sorted(os.environ["ANDROID_ONLY"].split()),
    "host_free_not_compared": sorted(os.environ["NOT_COMPARED"].split()),
    "classes": {
        "path": str(Path(os.environ["CLASSES"]).relative_to(root)),
        "class_files": int(os.environ["CLASS_COUNT"]),
    },
}
text = json.dumps(evidence, indent=2, sort_keys=True) + "\n"


def strings(value, path=()):
    """Every string in the evidence, with the member path that holds it."""
    if isinstance(value, dict):
        for member, nested in value.items():
            yield from strings(nested, path + (member,))
    elif isinstance(value, list):
        for item in value:
            yield from strings(item, path)
    elif isinstance(value, str):
        yield path, value


# Nothing of this Mac travels into a pull request: no home directory, no
# account name, no address. Every path above is repository-relative; the JDK
# prefix is the pin already committed in toolchain.json.
for secret in (os.environ.get("HOME", ""), os.environ.get("USER", "")):
    if secret and secret in text:
        raise SystemExit("evidence carries the home directory or account of this machine")
for path, value in strings(evidence):
    # `toolchain` holds only `javac -version`, `java -version`, the two cargo
    # version lines and the committed pins. A four-part tool version such as
    # the JDK's own 21.0.12.1 reads like an address to the check below, so
    # that subtree is compared against the pins instead of scanned.
    if path[:1] == ("toolchain",):
        continue
    if re.search(r"\b\d{1,3}(\.\d{1,3}){3}\b", value):
        raise SystemExit(f"evidence member {'.'.join(path)} carries an address of this machine")
if evidence["toolchain"]["javac"] != f"javac {os.environ['JDK_PIN']}" \
        or evidence["toolchain"]["java"] != os.environ["JDK_PIN"]:
    raise SystemExit("evidence toolchain does not match the JDK pin of toolchain.json")
out = Path(os.environ["EVIDENCE"])
out.write_text(text)
print("evidence: " + str(out.relative_to(root)))
PY

log "core library: ${NATIVE#"$ROOT/"}"
log "sha256: $(shasum -a 256 "$NATIVE" | cut -d' ' -f1)"
log "classes: ${CLASSES#"$HERE/"} ($CLASS_COUNT class files)"
log "evidence: ${EVIDENCE#"$ROOT/"}"
log ""
log "Run a host fixture with, from the repository root:"
log "  \"\$(python3 -c 'import json;print(json.load(open(\"clients/ios/toolchain.json\"))[\"java_home\"])')/bin/java\" \\"
log "    -Djava.library.path=clients/ios/out/core-target/debug \\"
log "    -cp clients/ios/out/host-java/classes:clients/ios/out/host-java/json-20240303.jar \\"
log "    VoiceCoreBridge"
log "OK: ${#ABSOLUTE[@]} Java files compiled, ${#JARS[@]} pinned jars, host core built"
