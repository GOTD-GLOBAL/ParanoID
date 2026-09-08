#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
PLATFORM="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
NDK="$ANDROID_SDK_ROOT/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK/aarch64-linux-android26-clang"
export CC_aarch64_linux_android="$NDK/aarch64-linux-android26-clang"
export AR_aarch64_linux_android="$NDK/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
cargo fetch --locked --manifest-path ../core/Cargo.toml
cargo test --locked --manifest-path ../core/Cargo.toml
cargo build --locked --manifest-path ../core/Cargo.toml
mkdir -p out/host out/classes out/dex
javac --release 8 -d out/host src/org/paranoid/text/CoreBridge.java src/org/paranoid/text/SnapshotCodec.java src/org/paranoid/text/SyncCycle.java test/CoreSmoke.java test/StorageSmoke.java test/SyncSmoke.java
java -Djava.library.path=../core/target/debug -cp out/host CoreSmoke
java -cp out/host StorageSmoke
java -cp out/host SyncSmoke
cargo build --locked --release --target aarch64-linux-android --manifest-path ../core/Cargo.toml
python3 notices.py
javac --release 8 -encoding UTF-8 -classpath "$PLATFORM" -d out/classes src/org/paranoid/text/*.java
"$TOOLS/d8" --lib "$PLATFORM" --min-api 26 --output out/dex out/classes/org/paranoid/text/*.class
"$TOOLS/aapt" package -f -M AndroidManifest.xml -I "$PLATFORM" -F out/unsigned.apk
python3 -c 'import zipfile; z=zipfile.ZipFile("out/unsigned.apk","a",compression=zipfile.ZIP_DEFLATED); z.write("out/dex/classes.dex","classes.dex"); z.write("../core/target/aarch64-linux-android/release/libparanoid_client_core.so","lib/arm64-v8a/libparanoid_client_core.so",compress_type=zipfile.ZIP_STORED); z.write("out/THIRD_PARTY_NOTICES.txt","assets/THIRD_PARTY_NOTICES.txt"); z.close()'
"$TOOLS/zipalign" -P 16 -f 4 out/unsigned.apk out/aligned.apk
# Disposable development signature, never use this key/password for production.
if [ ! -f out/test.keystore ]; then
  keytool -genkeypair -keystore out/test.keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 365 -dname "CN=ParanoID Text Disposable Test"
fi
"$TOOLS/apksigner" sign --ks out/test.keystore --ks-pass pass:android --key-pass pass:android --out out/paranoid-text.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-text.apk
python3 test_apk.py
