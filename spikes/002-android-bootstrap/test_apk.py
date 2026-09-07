import os
from pathlib import Path
import subprocess
import unittest
import zipfile

class ApkTest(unittest.TestCase):
    def test_installable_diagnostic_package(self):
        apk = Path(__file__).parent / 'out/paranoid-bootstrap.apk'
        self.assertTrue(apk.exists(), 'APK has not been built')
        with zipfile.ZipFile(apk) as z:
            self.assertIn('classes.dex', z.namelist())
            self.assertIn('AndroidManifest.xml', z.namelist())
        tools = Path(os.environ['ANDROID_SDK_ROOT']) / 'build-tools/35.0.0'
        subprocess.run([str(tools / 'apksigner'), 'verify', str(apk)], check=True)
        dump = subprocess.check_output([str(tools / 'aapt'), 'dump', 'badging', str(apk)], text=True)
        self.assertIn("name='org.paranoid.bootstrap'", dump)
        self.assertIn("launchable-activity: name='org.paranoid.bootstrap.MainActivity'", dump)
        self.assertNotIn('android.permission.INTERNET', dump)

if __name__ == '__main__':
    unittest.main()
