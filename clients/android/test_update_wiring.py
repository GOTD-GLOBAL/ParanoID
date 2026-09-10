import unittest
from pathlib import Path
# Only parses the checked-in local manifest, not downloaded/untrusted XML.
import xml.etree.ElementTree as ET
R=Path(__file__).resolve().parent
A='{http://schemas.android.com/apk/res/android}'
class UpdateWiring(unittest.TestCase):
    def test_explicit_update_ui_and_narrow_provider(self):
        m=ET.parse(R/'AndroidManifest.xml').getroot()
        self.assertEqual(m.get(A+'versionCode'),'11')
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES',[p.get(A+'name') for p in m.findall('uses-permission')])
        providers=m.findall('application/provider');self.assertEqual(len(providers),1)
        p=providers[0];self.assertEqual(p.get(A+'exported'),'false');self.assertEqual(p.get(A+'grantUriPermissions'),'false')
        self.assertEqual(p.get(A+'authorities'),'org.paranoid.devtext.updates')
        self.assertEqual([g.get(A+'path') for g in p.findall('grant-uri-permission')],['/verified.apk'])
        ui=(R/'src/org/paranoid/text/MainActivity.java').read_text()
        self.assertIn('new UpdateController(this,engine',ui)
        controller=(R/'src/org/paranoid/text/UpdateController.java').read_text()
        for text in ['Обновить','Скачать','Установить','Обновлений пока нет','Повторить','canRequestPackageInstalls','ACTION_MANAGE_UNKNOWN_APP_SOURCES','FLAG_GRANT_READ_URI_PERMISSION','ACTION_INSTALL_PACKAGE','UpdateClient.verifyBytes','AndroidUpdateVerifier.verify']:
            self.assertIn(text,controller)
        self.assertIn('if(!activity.hasWindowFocus())',controller)
        for text in ['text-state.enc','KeyStore','createIdentity','FLAG_GRANT_WRITE_URI_PERMISSION','file://','ACTION_PACKAGE_ADDED']:
            self.assertNotIn(text,controller)
        engine=(R/'src/org/paranoid/text/TextEngine.java').read_text()
        self.assertIn('client.updateTrust()',engine)
        provider=(R/'src/org/paranoid/text/UpdateProvider.java').read_text()
        for text in ['UpdatePolicy.providerFile','O_NOFOLLOW','O_RDONLY','st_nlink','st_uid','getType','query','openFile']:
            self.assertIn(text,provider)
        verifier=(R/'src/org/paranoid/text/AndroidUpdateVerifier.java').read_text()
        for text in ['getPackageArchiveInfo','GET_SIGNING_CERTIFICATES','GET_SIGNATURES','getSigningCertificateHistory','getApkContentsSigners','UpdatePolicy.verifyIdentity','minSdkVersion','SUPPORTED_ABIS']:
            self.assertIn(text,verifier)
if __name__=='__main__':unittest.main()
