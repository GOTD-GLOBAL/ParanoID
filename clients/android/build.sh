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
python3 test_call_controller.py
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
python3 test_contact_names.py
python3 test_background_contract.py
python3 test_realtime_transport.py --evidence-dir out/checks/realtime-transport
python3 test_update_wiring.py
python3 test_update_artifact_regression.py
cargo build --offline --locked --release --target aarch64-linux-android --manifest-path ../core/Cargo.toml
python3 notices.py
javac --release 8 -Xlint:-options -encoding UTF-8 -classpath "$PLATFORM:out/deps/zxing-core-3.5.3.jar:out/deps/webrtc-classes.jar" -d out/classes src/org/paranoid/text/*.java
"$TOOLS/d8" --lib "$PLATFORM" --min-api 26 --output out/dex out/classes/org/paranoid/text/*.class out/deps/zxing-core-3.5.3.jar out/deps/webrtc-classes.jar
"$TOOLS/aapt" package -f -M AndroidManifest.xml -S res -I "$PLATFORM" -F out/unsigned.apk
python3 -c 'import zipfile; z=zipfile.ZipFile("out/unsigned.apk","a",compression=zipfile.ZIP_DEFLATED); z.write("out/dex/classes.dex","classes.dex"); z.write("../core/target/aarch64-linux-android/release/libparanoid_client_core.so","lib/arm64-v8a/libparanoid_client_core.so",compress_type=zipfile.ZIP_STORED); z.write("out/deps/webrtc/arm64-v8a/libjingle_peerconnection_so.so","lib/arm64-v8a/libjingle_peerconnection_so.so",compress_type=zipfile.ZIP_STORED); z.write("out/THIRD_PARTY_NOTICES.txt","assets/THIRD_PARTY_NOTICES.txt"); z.close()'
"$TOOLS/zipalign" -P 16 -f 4 out/unsigned.apk out/aligned.apk
# Preserve the existing test signing identity. No key generation/copy or secrets in argv.
"$TOOLS/apksigner" sign --ks "$PARANOID_ANDROID_KEYSTORE" --ks-pass env:PARANOID_ANDROID_KS_PASSWORD --key-pass env:PARANOID_ANDROID_KS_PASSWORD --out out/paranoid-text.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-text.apk
python3 test_apk.py
python3 test_updates.py
