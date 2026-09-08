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
# Support Android devices with 16 KB memory pages.
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
cargo test --locked --manifest-path native/Cargo.toml
cargo build --locked --release --target aarch64-linux-android --manifest-path native/Cargo.toml
mkdir -p out/classes out/dex
python notices.py
javac --release 8 -encoding UTF-8 -classpath "$PLATFORM" -d out/classes src/org/paranoid/bootstrap/MainActivity.java
"$TOOLS/d8" --lib "$PLATFORM" --min-api 26 --output out/dex out/classes/org/paranoid/bootstrap/*.class
"$TOOLS/aapt" package -f -M AndroidManifest.xml -I "$PLATFORM" -F out/unsigned.apk
python -c 'import zipfile; z = zipfile.ZipFile("out/unsigned.apk", "a", compression=zipfile.ZIP_DEFLATED); z.write("out/dex/classes.dex", "classes.dex"); z.write("native/target/aarch64-linux-android/release/libparanoid_android_probe.so", "lib/arm64-v8a/libparanoid_android_probe.so", compress_type=zipfile.ZIP_STORED); z.write("out/THIRD_PARTY_NOTICES.txt", "assets/THIRD_PARTY_NOTICES.txt"); z.close()'
"$TOOLS/zipalign" -P 16 -f 4 out/unsigned.apk out/aligned.apk
# Local disposable TEST signing identity, never a production signing key.
if [ ! -f out/debug.keystore ]; then
  keytool -genkeypair -keystore out/debug.keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 365 -dname "CN=ParanoID Disposable Test"
fi
"$TOOLS/apksigner" sign --ks out/debug.keystore --ks-pass pass:android --key-pass pass:android --out out/paranoid-bootstrap.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-bootstrap.apk
python test_apk.py
