"""Source/manifest integration gate; APK/runtime checks are separate."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
R=Path(__file__).resolve().parent
A='{http://schemas.android.com/apk/res/android}'
class Integration(unittest.TestCase):
    def test_devnet_is_internal_to_existing_messenger(self):
        root=ET.parse(R/'AndroidManifest.xml').getroot()
        self.assertEqual(root.get('package'),'global.paranoid.messenger')
        activities=root.findall('application/activity')
        devnet=[a for a in activities if a.get(A+'name')=='org.paranoid.devnet.MainActivity']
        self.assertEqual(len(devnet),1,'Devnet must be inside main APK, not a second app')
        self.assertEqual(devnet[0].get(A+'exported'),'false')
        self.assertEqual(devnet[0].findall('intent-filter'),[])
        launchers=[a for a in activities if a.find('intent-filter/category') is not None]
        self.assertEqual([a.get(A+'name') for a in launchers],['org.paranoid.text.MainActivity'])
        source=(R/'src/org/paranoid/text/MainActivity.java').read_text()
        self.assertIn('org.paranoid.devnet.MainActivity.class',source)
        self.assertIn('Ник в Devnet',source)
        method=source.split('private void openDevnet()',1)[1].split('\n    }',1)[0]
        self.assertIn('engine.calls().active()',method)
        self.assertNotIn('engine.restart',method)
        devnet_source=(R.parent/'android-devnet/src/org/paranoid/devnet/MainActivity.java').read_text()
        self.assertIn('final String result=DevnetWork.run(',devnet_source)
        build=(R/'build.sh').read_text()
        self.assertIn('libparanoid_devnet_client.so',build)
        self.assertIn('../android-devnet/src/org/paranoid/devnet/*.java',build)
if __name__=='__main__':unittest.main()
