import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent
class OnboardingContract(unittest.TestCase):
    def test_typed_scanner_and_display_are_wired_with_cancel_safe_lifecycle(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        self.assertIn('QrCodec.encode',ui,'public descriptors must be displayed as actual QR')
        self.assertIn('QrScanActivity',ui)
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('android.permission.CAMERA',manifest)
        scanner=(ROOT/'src/org/paranoid/text/QrScanActivity.java').read_text()
        self.assertIn('QrCodec.decode',scanner)
        self.assertIn('onPause()',scanner)
        self.assertIn('camera.release()',scanner)
    def test_phone_ui_uses_key_workflow_not_manual_bearer_roles(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        self.assertIn('engine.createIdentity()',ui,'Create ID must be the onboarding action')
        self.assertNotIn('Spinner',ui)
        self.assertNotIn('Личный токен',ui)
        self.assertIn('KeyClient',engine)
        self.assertNotIn('"Bearer "+',engine)
        self.assertIn('paranoid-text-state-v0',engine)
        self.assertIn('text-state.enc',engine)
if __name__=='__main__':unittest.main()
