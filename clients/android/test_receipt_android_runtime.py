"""Real Canvas/preferences probe in a disposable, no-network emulator-only APK.

Requires SDK + retained signing environment. Never installs the messenger APK.
Only its UUID-named synthetic package is installed, stopped and uninstalled.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile
import uuid
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
args = parser.parse_args()
if not args.serial.startswith('emulator-'):
    raise SystemExit('Only a local emulator serial is accepted; no physical-device action')
root = Path(__file__).resolve().parent
sdk = Path(os.environ['ANDROID_SDK_ROOT'])
tools = sdk / 'build-tools/35.0.0'
adb = [str(sdk / 'platform-tools/adb'), '-s', args.serial]
package = 'org.paranoid.receiptprobe.p' + uuid.uuid4().hex

def run(command):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, check=True)
    return result.stdout + result.stderr

assert run(adb + ['get-state']).strip() == 'device'
installed = False
with tempfile.TemporaryDirectory(prefix='paranoid-receipt-runtime-') as folder:
    scratch = Path(folder)
    manifest = scratch / 'AndroidManifest.xml'
    manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}">
<uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
<application android:label="Receipt probe" android:allowBackup="false"/>
<instrumentation android:name="org.paranoid.text.ReceiptViewInstrumentation" android:targetPackage="{package}"/>
</manifest>''')
    classes = scratch / 'classes'; classes.mkdir()
    dex = scratch / 'dex'; dex.mkdir()
    sources = [root / 'src/org/paranoid/text' / (n + '.java')
               for n in ['MessagePresentation', 'ReceiptMark', 'ReceiptHint']]
    sources.append(root / 'test/ReceiptViewInstrumentation.java')
    run(['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8', '-cp',
         sdk / 'platforms/android-35/android.jar', '-d', classes, *sources])
    run([tools / 'aapt', 'package', '-f', '-M', manifest, '-I',
         sdk / 'platforms/android-35/android.jar', '-F', scratch / 'raw.apk'])
    run([tools / 'd8', '--release', '--min-api', '26', '--lib',
         sdk / 'platforms/android-35/android.jar', '--output', dex, *classes.rglob('*.class')])
    with zipfile.ZipFile(scratch / 'raw.apk', 'a') as apk:
        apk.write(dex / 'classes.dex', 'classes.dex')
    run([tools / 'zipalign', '-f', '4', scratch / 'raw.apk', scratch / 'aligned.apk'])
    run([tools / 'apksigner', 'sign', '--ks', os.environ['PARANOID_ANDROID_KEYSTORE'],
         '--ks-pass', 'env:PARANOID_ANDROID_KS_PASSWORD', '--key-pass', 'env:PARANOID_ANDROID_KS_PASSWORD',
         '--out', scratch / 'probe.apk', scratch / 'aligned.apk'])
    try:
        run(adb + ['install', '-t', str(scratch / 'probe.apk')]); installed = True
        for phase in ['initial', 'reopen']:
            output = run(adb + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'phase', phase,
                               package + '/org.paranoid.text.ReceiptViewInstrumentation'])
            print(output, flush=True)
            assert 'PASS receipt' in output and 'INSTRUMENTATION_CODE: -1' in output and 'FAIL' not in output
            if phase == 'initial': run(adb + ['shell', 'am', 'force-stop', package])
    finally:
        if installed:
            print(run(adb + ['uninstall', package]), flush=True)
print('PASS: actual Android Canvas/labels at two densities and font scales, hint dismissal and process restart; synthetic package removed')
