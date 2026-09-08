#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
PLATFORM="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
mkdir -p out/classes out/dex
javac --release 8 -encoding UTF-8 -classpath "$PLATFORM" -d out/classes src/org/paranoid/bootstrap/MainActivity.java
"$TOOLS/d8" --lib "$PLATFORM" --min-api 26 --output out/dex out/classes/org/paranoid/bootstrap/MainActivity.class
"$TOOLS/aapt" package -f -M AndroidManifest.xml -I "$PLATFORM" -F out/unsigned.apk
python -c 'import zipfile; z = zipfile.ZipFile("out/unsigned.apk", "a", compression=zipfile.ZIP_DEFLATED); z.write("out/dex/classes.dex", "classes.dex"); z.close()'
"$TOOLS/zipalign" -f 4 out/unsigned.apk out/aligned.apk
# Local disposable TEST signing identity, never a production signing key.
if [ ! -f out/debug.keystore ]; then
  keytool -genkeypair -keystore out/debug.keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 365 -dname "CN=ParanoID Disposable Test"
fi
"$TOOLS/apksigner" sign --ks out/debug.keystore --ks-pass pass:android --key-pass pass:android --out out/paranoid-bootstrap.apk out/aligned.apk
"$TOOLS/apksigner" verify --verbose out/paranoid-bootstrap.apk
python test_apk.py
