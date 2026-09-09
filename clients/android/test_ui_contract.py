import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent
class OnboardingContract(unittest.TestCase):
    def test_upgrade_candidate_keeps_package_and_advances_version(self):
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('package="org.paranoid.devtext"',manifest)
        self.assertIn('android:versionCode="8"',manifest)
        self.assertIn('android:versionName="0.0.8-realtime"',manifest)

    def test_self_service_ui_is_contacts_dialogs_and_chat_not_operator_json(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        for caption in ['Контакты','Чаты','Мой ID','Добавить контакт','Создать ID','Отправить']:
            self.assertIn(caption,ui)
        for obsolete in ['оператор','одобрени','importGrant','peerCode','descriptor.toString()','alice','bob']:
            self.assertNotIn(obsolete,ui)
        self.assertIn('SelfServiceClient',engine)
        # RFC-0015 replaces the blocking v7 sync with separate network lanes.
        # Real actor/registration/commit tests are in test_realtime.py.
        self.assertIn('client.createIdentity()',engine)
        self.assertIn('new RealtimeLoop(worker,client',engine)
        self.assertNotIn('client.sync()',engine)
        self.assertIn('client.send(account,text)',engine)
        self.assertIn('selectedAccount',ui)
        self.assertIn('DialogPolicy.trustLabel(dialog)',ui)
        self.assertIn('DialogPolicy.canReply(',ui)
        self.assertIn('engine.block(',ui)

    def test_first_contact_badge_reply_and_block_are_visible(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        self.assertIn('Личность не проверена',ui)
        self.assertIn('Заблокировать контакт',ui)
        self.assertIn('Разблокировать контакт',ui)
        self.assertIn('Сообщения собеседников появятся здесь автоматически',ui)
        self.assertIn('client.block(account,blocked)',engine)
        self.assertNotIn('Сохранённый контакт — подтвердите QR',ui)

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
        self.assertIn('SelfServiceClient',engine)
        self.assertNotIn('"Bearer "+',engine)
        self.assertIn('paranoid-text-state-v0',engine)
        self.assertIn('text-state.enc',engine)
if __name__=='__main__':unittest.main()
