#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ANDROID_SDK_ROOT:?}"
: "${PARANOID_ANDROID_KEYSTORE:?existing test signer required}"
: "${PARANOID_ANDROID_KS_PASSWORD:?}"
umask 077
TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
PLATFORM="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
NDK="$ANDROID_SDK_ROOT/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK/aarch64-linux-android26-clang"
export CC_aarch64_linux_android="$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
export AR_aarch64_linux_android="$NDK/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'
cargo +1.98.1 test --locked --manifest-path ../../blockchain/solana/client/Cargo.toml
cargo +1.98.1 build --locked --release --target aarch64-linux-android --manifest-path ../../blockchain/solana/client/Cargo.toml
mkdir -p out/classes out/dex
javac --release 8 -Xlint:-options -encoding UTF-8 -cp "$PLATFORM" -d out/classes src/org/paranoid/devnet/*.java ../android/src/org/paranoid/text/SnapshotCodec.java
"$TOOLS/aapt" package -f -M AndroidManifest.xml -I "$PLATFORM" -F out/unsigned.apk
python3 - "$TOOLS/d8" "$PLATFORM" <<'PY'
from pathlib import Path
import subprocess,sys,zipfile
subprocess.run([sys.argv[1],'--release','--lib',sys.argv[2],'--min-api','26','--output','out/dex',*map(str,Path('out/classes').rglob('*.class'))],check=True)
assert not Path('out/dex/classes2.dex').exists()
with zipfile.ZipFile('out/unsigned.apk','a') as z:
    z.write('out/dex/classes.dex','classes.dex',compress_type=zipfile.ZIP_DEFLATED)
    z.write('../../blockchain/solana/client/target/aarch64-linux-android/release/libparanoid_devnet_client.so','lib/arm64-v8a/libparanoid_devnet_client.so',compress_type=zipfile.ZIP_STORED)
PY
"$TOOLS/zipalign" -P 16 -f 4 out/unsigned.apk out/aligned.apk
"$TOOLS/apksigner" sign --ks "$PARANOID_ANDROID_KEYSTORE" --ks-pass env:PARANOID_ANDROID_KS_PASSWORD --key-pass env:PARANOID_ANDROID_KS_PASSWORD --out out/paranoid-devnet.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-devnet.apk
"$TOOLS/zipalign" -c -P 16 4 out/paranoid-devnet.apk
