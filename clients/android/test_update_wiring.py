import unittest
from pathlib import Path
# Only parses the checked-in local manifest, not downloaded/untrusted XML.
import xml.etree.ElementTree as ET
R=Path(__file__).resolve().parent
A='{http://schemas.android.com/apk/res/android}'
class UpdateWiring(unittest.TestCase):
    def test_large_session_copy_is_off_ui_and_commit_is_foreground_gated(self):
        c=(R/'src/org/paranoid/text/UpdateController.java').read_text()
        fallback=c[c.index('private void sessionInstall('):c.index('public static final String INSTALL_STATUS')]
        self.assertIn('WORK.execute(',fallback)
        self.assertLess(fallback.index('WORK.execute('),fallback.index('session.openWrite('))
        self.assertLess(fallback.index('session.fsync('),fallback.index('activity.runOnUiThread('))
        self.assertIn('if(!alive() || !activity.hasWindowFocus())',fallback)
        self.assertLess(fallback.index('if(!alive() || !activity.hasWindowFocus())'),fallback.index('session.commit('))
        self.assertIn('session.abandon()',fallback)
        self.assertIn('session.close()',fallback)
        self.assertIn('finish();',fallback)
        self.assertIn('},true);',c) # caller transfers BUSY ownership to fallback

    def test_explicit_update_ui_and_narrow_provider(self):
        m=ET.parse(R/'AndroidManifest.xml').getroot()
        self.assertEqual(m.get(A+'versionCode'),'27')
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES',[p.get(A+'name') for p in m.findall('uses-permission')])
        # Package visibility: the installer intent must be declared so resolveActivity() can see the system installer on targetSdk>=30.
        queries=[(i.find('action').get(A+'name'),i.find('data').get(A+'mimeType')) for i in m.findall('queries/intent')]
        self.assertIn(('android.intent.action.INSTALL_PACKAGE','application/vnd.android.package-archive'),queries)
        self.assertEqual(m.findall('queries/package'),[],'no package-name enumeration')
        providers=[p for p in m.findall('application/provider') if p.get(A+'name')=='org.paranoid.text.UpdateProvider'];self.assertEqual(len(providers),1)
        # v20: the only other provider is Firebase's init provider, not exported.
        others=[p for p in m.findall('application/provider') if p not in providers]
        self.assertEqual([(p.get(A+'name'),p.get(A+'exported')) for p in others],[('com.google.firebase.provider.FirebaseInitProvider','false')])
        p=providers[0];self.assertEqual(p.get(A+'exported'),'false');self.assertEqual(p.get(A+'grantUriPermissions'),'false')
        self.assertEqual(p.get(A+'authorities'),'global.paranoid.messenger.updates')
        self.assertEqual([g.get(A+'path') for g in p.findall('grant-uri-permission')],['/verified.apk'])
        ui=(R/'src/org/paranoid/text/MainActivity.java').read_text()
        self.assertIn('new UpdateController(this,engine',ui)
        controller=(R/'src/org/paranoid/text/UpdateController.java').read_text()
        for text in ['Обновить','Скачать','Установить','Обновлений пока нет','Повторить','canRequestPackageInstalls','ACTION_MANAGE_UNKNOWN_APP_SOURCES','FLAG_GRANT_READ_URI_PERMISSION','ACTION_INSTALL_PACKAGE','UpdateClient.verifyBytes','AndroidUpdateVerifier.verify']:
            self.assertIn(text,controller)
        self.assertIn('if(!activity.hasWindowFocus())',controller)
        # v19: PackageInstaller session fallback after the intent path, with the same re-verified file, user confirmation kept.
        for text in ['PackageInstaller.SessionParams.MODE_FULL_INSTALL','session.commit(','STATUS_PENDING_USER_ACTION','session.abandon()','Диагностика: intent']:
            self.assertIn(text,controller)
        self.assertLess(controller.index('UpdateClient.verifyBytes(ready,manifest);AndroidUpdateVerifier.verify(activity,ready,manifest);'),controller.index('sessionInstall(ready,intentFailure);'))
        self.assertIn('UpdateController.installStatus(this,intent)',ui)
        self.assertIn('UpdateController.installStatus(this,getIntent())',ui)
        self.assertIn('FLAG_ACTIVITY_SINGLE_TOP|Intent.FLAG_ACTIVITY_CLEAR_TOP',controller)
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
