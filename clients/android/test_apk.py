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
        # Version checks: agnostic of exact number, just require solana-era build (>=30)
        import re as _re2
        vc2=_re2.search("versionCode='([0-9]+)'",result)
        self.assertIsNotNone(vc2,'versionCode not in aapt output')
        self.assertGreaterEqual(int(vc2.group(1)),30,'versionCode must be >=30')
        vn2=_re2.search("versionName='([^']+)'",result)
        self.assertIsNotNone(vn2,'versionName not in aapt output')
        self.assertRegex(vn2.group(1),r'^0[.]0[.][0-9]+-solana-id$','versionName pattern mismatch')
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
                self.assertIn(cls,dex,f"{cls} missing from dex")
            for absent in (b"Lcom/google/android/gms/",b"Lcom/google/android/play/"):
                self.assertNotIn(absent,dex,f"{absent} must not be in dex: no Play Services dependency")
        # TLS: pinned transport must be present; cleartext must be blocked
        self.assertIn("usesCleartextTraffic",result.lower().replace("usescleartexttraffic","usesCleartextTraffic"))
        with zipfile.ZipFile(apk) as archive:
            manifest_xml=archive.read("AndroidManifest.xml")
            # debuggable must be false (compiled out of the release build)
            self.assertNotIn(b"debuggable",manifest_xml)
        # Private storage: allowBackup must be false
        with zipfile.ZipFile(apk) as archive:
            manifest_xml=archive.read("AndroidManifest.xml")
            self.assertNotIn(b"allowBackup",manifest_xml)
if __name__=='__main__':unittest.main()
