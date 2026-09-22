#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
: "${PARANOID_ANDROID_KEYSTORE:?Set the existing signing keystore path; never regenerate}"
: "${PARANOID_ANDROID_KS_PASSWORD:?Set signing password in build environment}"
umask 077
python3 dependencies.py
python3 webrtc_dependency.py
python3 test_webrtc_dependency.py
python3 firebase_dependency.py
python3 test_firebase_dependency.py
# Compile against Android's checked org.json API before expensive native gates.
python3 test_devnet_integration.py
python3 test_sdk_compile.py
python3 test_call_controller.py
python3 test_call_log.py
python3 test_crash_exit.py
python3 test_voice_relay.py
TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
PLATFORM="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
NDK="$ANDROID_SDK_ROOT/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK/aarch64-linux-android26-clang"
export CC_aarch64_linux_android="$NDK/aarch64-linux-android26-clang"
export AR_aarch64_linux_android="$NDK/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
# Clean-install candidate gate (RFC-0014 / REQ-MSG-005). Historical compatibility
# tests remain in source and are run separately with real exits in the handoff;
# unsupported old-snapshot migration is explicitly outside this candidate gate.
# Match the release native profile shipped in the APK; the 3700-control real
# cryptographic stress gate is prohibitively slow in an unoptimized build.
cargo test --offline --locked --release --manifest-path ../core/Cargo.toml --lib --test clean_first_contact --test realtime_signing --test voice_calls
cargo build --offline --locked --manifest-path ../core/Cargo.toml
python3 -c 'from pathlib import Path; import shutil; [(shutil.rmtree(p) if p.exists() else None, p.mkdir(parents=True)) for p in map(Path,("out/host","out/classes","out/dex"))]'
javac --release 8 -d out/host src/org/paranoid/text/CoreBridge.java src/org/paranoid/text/SnapshotCodec.java src/org/paranoid/text/SyncCycle.java test/CoreSmoke.java test/StorageSmoke.java test/SyncSmoke.java
java -Djava.library.path=../core/target/debug -cp out/host CoreSmoke
java -cp out/host StorageSmoke
java -cp out/host SyncSmoke
javac --release 8 -Xlint:-options -cp out/deps/json-20240303.jar:out/deps/zxing-core-3.5.3.jar -d out/host src/org/paranoid/text/{CoreBridge,PinnedTls,SnapshotCodec,SyncCycle,KeyClient,KeyTransport,SelfServiceClient,QrCodec,StorageGuard,DialogPolicy,RealtimeLoop,RealtimeTransport,VoiceRelayConfig,VoiceRelayTransport}.java test/{RegistrationSmoke,CleanSelfServiceSmoke,CleanSnapshotBoundarySmoke,QrSmoke,QrDiverseSmoke,QrDenseSmoke,DialogPolicySmoke,VoiceCommitSmoke}.java
java -Djava.library.path=../core/target/debug -cp out/host:out/deps/json-20240303.jar RegistrationSmoke
java -Djava.library.path=../core/target/debug -cp out/host:out/deps/json-20240303.jar CleanSelfServiceSmoke
java -Djava.library.path=../core/target/debug -cp out/host:out/deps/json-20240303.jar CleanSnapshotBoundarySmoke
java -Djava.library.path=../core/target/debug -cp out/host:out/deps/json-20240303.jar VoiceCommitSmoke
java -cp out/host:out/deps/json-20240303.jar DialogPolicySmoke
java -cp out/host:out/deps/zxing-core-3.5.3.jar QrSmoke
java -cp out/host:out/deps/zxing-core-3.5.3.jar QrDiverseSmoke
java -cp out/host:out/deps/zxing-core-3.5.3.jar QrDenseSmoke
javac --release 8 -Xlint:-options -cp out/host:out/deps/json-20240303.jar:out/deps/zxing-core-3.5.3.jar -d out/host test/PublicQr.java
python3 test_ui_contract.py
python3 test_message_presentation.py
python3 test_message_time.py
python3 test_contact_names.py
python3 test_background_contract.py
python3 test_realtime_transport.py --evidence-dir out/checks/realtime-transport
python3 test_update_wiring.py
python3 test_update_session_worker.py
python3 test_update_artifact_regression.py
cargo build --offline --locked --release --target aarch64-linux-android --manifest-path ../core/Cargo.toml
cargo +1.98.1 test --locked --manifest-path ../../blockchain/solana/client/Cargo.toml
cargo +1.98.1 build --locked --release --target aarch64-linux-android --manifest-path ../../blockchain/solana/client/Cargo.toml
python3 test_devnet_notices.py
# RFC-0020: Firebase Messaging closure (pinned AARs). aapt merges the library resources and generates
# each library's R class (--extra-packages), which their bytecode references; the closure is dexed
# with --release so the 61 artifacts stay a single classes.dex under the 64K method limit.
FCM_CP="$(ls out/deps/fcm-jars/*.jar | paste -sd:)"
FCM_RES="$(for d in out/deps/fcm-res/*/; do printf -- '-S %s ' "$d"; done)"
FCM_PACKAGES="$(paste -sd: out/deps/fcm-packages.txt)"
python3 -c 'from pathlib import Path; import shutil; p=Path("out/gen"); shutil.rmtree(p, ignore_errors=True); p.mkdir()'
"$TOOLS/aapt" package -f -m --auto-add-overlay -M AndroidManifest.xml -S res $FCM_RES -I "$PLATFORM" -J out/gen --extra-packages "$FCM_PACKAGES" -F out/unsigned.apk
javac --release 8 -Xlint:-options -encoding UTF-8 -classpath "$PLATFORM:out/deps/zxing-core-3.5.3.jar:out/deps/webrtc-classes.jar:$FCM_CP" -d out/classes src/org/paranoid/text/*.java ../android-devnet/src/org/paranoid/devnet/*.java $(find out/gen -name R.java)
# R8 shrink-only (see proguard.pro): the closure's own consumer rules (proguard.txt inside each AAR) are
# honoured, ours forbid optimization/renaming. Avoid unnecessary binary growth, without a fixed APK ceiling.
python3 -c 'from pathlib import Path; import shutil; p=Path("out/r8-rules"); shutil.rmtree(p, ignore_errors=True); p.mkdir(); import zipfile
for aar in sorted(Path("out/deps/fcm-archives").glob("*.aar")):
    with zipfile.ZipFile(aar) as z:
        if "proguard.txt" in z.namelist(): (p/(aar.stem+".pro")).write_bytes(z.read("proguard.txt"))'
rm -rf out/dex out/dex-fcm out/dex-app && mkdir -p out/dex out/dex-fcm out/dex-app
# (1) R8 shrinks ONLY Firebase. --classpath resolves types; it is NOT a keep root.
#     Explicit API/manifest keep rules and consumer rules retain required members.
#     (2) d8 dexes app/WebRTC/ZXing untouched (JNI class lookup by
#     name). (3) d8 merges both dex files into one classes.dex (must stay single-dex, <64K methods).
java -cp "$TOOLS/lib/d8.jar" com.android.tools.r8.R8 --release --lib "$PLATFORM" --classpath out/classes --classpath out/deps/webrtc-classes.jar --classpath out/deps/zxing-core-3.5.3.jar --min-api 26 --output out/dex-fcm --pg-conf proguard.pro $(for f in out/r8-rules/*.pro; do printf -- '--pg-conf %s ' "$f"; done) out/deps/fcm-jars/*.jar > out/r8.log 2>&1 || { grep -v "^Warning\|^Info\|does not match anything\|^  \|^}$" out/r8.log; exit 1; }
"$TOOLS/d8" --release --lib "$PLATFORM" --min-api 26 --output out/dex-app $(find out/classes -name '*.class') out/deps/zxing-core-3.5.3.jar out/deps/webrtc-classes.jar
# The packager intentionally supports one DEX. Reject split INPUTS before merging
# rather than silently dropping their second file. API26 itself supports multidex.
test ! -e out/dex-app/classes2.dex && test ! -e out/dex-fcm/classes2.dex
"$TOOLS/d8" --release --lib "$PLATFORM" --min-api 26 --output out/dex out/dex-app/classes.dex out/dex-fcm/classes.dex
test -s out/dex/classes.dex && test ! -e out/dex/classes2.dex
python3 test_dex_shrink.py
python3 -c 'import zipfile; z=zipfile.ZipFile("out/unsigned.apk","a",compression=zipfile.ZIP_DEFLATED); z.write("out/dex/classes.dex","classes.dex"); z.write("../core/target/aarch64-linux-android/release/libparanoid_client_core.so","lib/arm64-v8a/libparanoid_client_core.so",compress_type=zipfile.ZIP_STORED); z.write("out/deps/webrtc/arm64-v8a/libjingle_peerconnection_so.so","lib/arm64-v8a/libjingle_peerconnection_so.so",compress_type=zipfile.ZIP_STORED); z.write("../../blockchain/solana/client/target/aarch64-linux-android/release/libparanoid_devnet_client.so","lib/arm64-v8a/libparanoid_devnet_client.so",compress_type=zipfile.ZIP_STORED); z.write("out/THIRD_PARTY_NOTICES.txt","assets/THIRD_PARTY_NOTICES.txt"); z.close()'
"$TOOLS/zipalign" -P 16 -f 4 out/unsigned.apk out/aligned.apk
# Preserve the existing test signing identity. No key generation/copy or secrets in argv.
"$TOOLS/apksigner" sign --ks "$PARANOID_ANDROID_KEYSTORE" --ks-pass env:PARANOID_ANDROID_KS_PASSWORD --key-pass env:PARANOID_ANDROID_KS_PASSWORD --out out/paranoid-text.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-text.apk
python3 test_apk.py
python3 test_updates.py
