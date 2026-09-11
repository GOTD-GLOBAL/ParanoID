import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent
class OnboardingContract(unittest.TestCase):
    def test_upgrade_candidate_keeps_package_and_advances_version(self):
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('package="global.paranoid.messenger"',manifest)
        self.assertIn('android:versionCode="16"',manifest)
        self.assertIn('android:versionName="0.0.16-video"',manifest)

    def test_incoming_call_menu_and_update_autocheck_contract(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        service=(ROOT/'src/org/paranoid/text/VoiceCallService.java').read_text()
        audio=(ROOT/'src/org/paranoid/text/WebRtcAudioEngine.java').read_text()
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        # Full incoming call: ringtone channel, full-screen intent, ongoing category call.
        for token in ['setFullScreenIntent','TYPE_RINGTONE','enableVibration(true)','USAGE_NOTIFICATION_RINGTONE','setOngoing(true)']:
            self.assertIn(token,service)
        self.assertIn('android.permission.USE_FULL_SCREEN_INTENT',manifest)
        self.assertIn('android.permission.VIBRATE',manifest)
        # Lock-screen display exists but only tracks the incoming state.
        self.assertIn('setShowWhenLocked(visible)',ui)
        self.assertIn('setTurnScreenOn(visible)',ui)
        self.assertIn('state.equals("incoming")',ui)
        # Bluetooth routing: modern communication-device path plus legacy SCO fallback.
        self.assertIn('android.permission.BLUETOOTH_CONNECT',manifest)
        for token in ['setCommunicationDevice','TYPE_BLE_HEADSET','TYPE_BLUETOOTH_SCO','registerAudioDeviceCallback','startBluetoothSco','stopBluetoothSco','BLUETOOTH_CONNECT']:
            self.assertIn(token,audio)
        # Overflow menu and quiet startup update check with a dismissible banner.
        for caption in ['Проверить обновления','О приложении','Доступна версия ']:
            self.assertIn(caption,ui)
        self.assertIn('updateController.trigger()',ui)
        self.assertIn('update_autocheck_at_v1',ui)
        self.assertIn('6*60*60*1000L',ui)

    def test_self_service_ui_is_contacts_dialogs_and_chat_not_operator_json(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        for caption in ['Контакты','Чаты','Мой ID','Добавить контакт','Создать ID','Отправить']:
            self.assertIn(caption,ui)
        for obsolete in ['Запросить доступ у оператора','одобрени','importGrant','peerCode','descriptor.toString()','alice','bob']:
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

    def test_voice_privacy_is_visible_before_both_consent_actions(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        self.assertIn('оператор ретранслятора видит ваш IP-адрес, время и объём трафика',ui)
        self.assertIn('собеседник может видеть ваш IP-адрес',ui)
        outgoing=ui[ui.index('private void requestCall(boolean video)'):ui.index('private void requestMicrophone')]
        self.assertLess(outgoing.index('video?VIDEO_PRIVACY:VOICE_PRIVACY'),outgoing.index('.setPositiveButton(video?"Видеозвонок":"Позвонить"'))
        incoming=ui[ui.index('private void showCall()'):ui.index('private static String callLabel')]
        self.assertLess(incoming.index('callPrivacy=text(VOICE_PRIVACY'),incoming.index('callAnswer=action("Ответить"'))

    def test_video_calls_require_explicit_camera_toggle_and_pause_in_background(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        media=(ROOT/'src/org/paranoid/text/WebRtcAudioEngine.java').read_text()
        controller=(ROOT/'src/org/paranoid/text/CallController.java').read_text()
        # CAMERA is requested only from the explicit toggle or explicit video-call intent, never on ring.
        self.assertIn('requestPermissions(new String[]{android.Manifest.permission.CAMERA},CAMERA_PERMISSION)',ui)
        answer=ui[ui.index('callAnswer=action("Ответить"'):ui.index('callAnswer=action("Ответить"')+120]
        self.assertNotIn('CAMERA',answer)
        self.assertIn('FLAG_SECURE',ui)
        self.assertIn('videoPausedByBackground=true;engine.calls().video(false)',ui)
        self.assertIn('Видео и звук защищены сквозным шифрованием',ui)
        # Engine: camera capture only through applyVideo after explicit setVideo; H.264 first, VP8 mandatory.
        self.assertIn('throw new SecurityException("Camera permission required")',media)
        self.assertIn('if (fallback.isEmpty()) throw new IllegalStateException("VP8 unavailable")',media)
        self.assertLess(media.index('mime.equals("video/h264")'),media.index('mime.equals("video/vp8")'))
        self.assertIn('localVideo.setEnabled(false);\n        peer.addTrack(localVideo',media)
        # Controller: video on -> speaker unless headset; off restores route; port checks CAMERA.
        self.assertIn('c.speakerBeforeVideo=c.speaker;c.speaker=true;',controller)
        self.assertIn('throw new SecurityException("camera permission")',engine)

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
