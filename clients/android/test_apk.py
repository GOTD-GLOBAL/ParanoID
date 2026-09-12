import os
from pathlib import Path
import subprocess
import unittest
import zipfile

class PackageTest(unittest.TestCase):
    def test_text_apk_has_native_core_tls_boundary_and_private_storage(self):
        apk=Path(os.environ.get("PARANOID_APK",str(Path(__file__).parent / "out/paranoid-text.apk")))
        self.assertTrue(apk.exists(),"text APK has not been built")
        tools=Path(os.environ["ANDROID_SDK_ROOT"])/"build-tools/35.0.0"
        result=subprocess.run([str(tools/"aapt"),"dump","badging",str(apk)],capture_output=True,text=True,check=True).stdout
        self.assertIn("package: name='global.paranoid.messenger'",result)
        self.assertIn("versionCode='24'",result)
        self.assertIn("versionName='0.0.24-push'",result)
        self.assertIn("sdkVersion:'26'",result)
        self.assertIn("native-code: 'arm64-v8a'",result)
        self.assertIn("application-icon-",result)
        self.assertIn("mipmap",result)
        self.assertIn("android.permission.CAMERA",result)
        self.assertIn("android.permission.INTERNET",result)
        self.assertIn("com.google.android.c2dm.permission.RECEIVE",result)
        self.assertNotIn("android.permission.READ_EXTERNAL_STORAGE",result)
        with zipfile.ZipFile(apk) as archive:
            self.assertIn("lib/arm64-v8a/libparanoid_client_core.so",archive.namelist())
            self.assertIn("assets/THIRD_PARTY_NOTICES.txt",archive.namelist())
            self.assertIn(b"ZXing core 3.5.3",archive.read("assets/THIRD_PARTY_NOTICES.txt"))
            self.assertIn(b"Firebase Cloud Messaging closure",archive.read("assets/THIRD_PARTY_NOTICES.txt"))
            dex=archive.read("classes.dex")
            for cls in (b"Lorg/paranoid/text/PushService;",b"Lcom/google/firebase/messaging/FirebaseMessagingService;",b"Lcom/google/firebase/provider/FirebaseInitProvider;"):
                self.assertIn(cls,dex)
            self.assertNotIn("classes2.dex",archive.namelist(),"single dex expected")
            # Only our two native libraries; the Firebase closure ships no JNI.
            self.assertEqual(sorted(n for n in archive.namelist() if n.startswith("lib/")),["lib/arm64-v8a/libjingle_peerconnection_so.so","lib/arm64-v8a/libparanoid_client_core.so"])
            self.assertFalse(any(any(s in name.lower() for s in ("keystore",".key",".env","grant.json","request.json")) for name in archive.namelist()))
        xml=subprocess.run([str(tools/"aapt"),"dump","xmltree",str(apk),"AndroidManifest.xml"],capture_output=True,text=True,check=True).stdout
        self.assertRegex(xml,r"allowBackup[^\n]*0x0")
        self.assertRegex(xml,r"usesCleartextTraffic[^\n]*0x0")
        subprocess.run([str(tools/"apksigner"),"verify",str(apk)],check=True)
        signature=subprocess.check_output([str(tools/"apksigner"),"verify","--print-certs",str(apk)],text=True)
        self.assertIn("82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926",signature)
        subprocess.run([str(tools/"zipalign"),"-c","-P","16","4",str(apk)],check=True)

if __name__=="__main__":unittest.main()
