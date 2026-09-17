import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent
class OnboardingContract(unittest.TestCase):
    def test_missed_notice_rechecks_foreground_on_ui_delivery(self):
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        self.assertIn('if(missed)ui.post(()->{if(listener==null)VoiceCallService.missed(context);});',engine)
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        opened=ui[ui.index('private void openChat('):ui.index('private void restoreDraft(')]
        self.assertIn('VoiceCallService.clearMissed(this)',opened)

    def test_call_repaint_preserves_status_and_unknown_anchor(self):
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        finished=engine.split('public void finished(JSONObject termination){',1)[1].split('ui.post(new Runnable()',1)[0]
        self.assertIn('publish(lastPublishedStatus)',finished)
        self.assertIn('String anchor="unavailable";',finished)
        self.assertIn('anchor="";',finished)
        publish=engine.split('private void publish(String status) {',1)[1]
        self.assertIn('lastPublishedStatus=status;',publish)

    def test_upgrade_candidate_keeps_package_and_advances_version(self):
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('package="global.paranoid.messenger"',manifest)
        self.assertIn('android:versionCode="22"',manifest)
        self.assertIn('android:versionName="0.0.22-push"',manifest)

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
        # Screen stays on only while the video stage is shown; flag lives on the call window (owner request 2026-09-12).
        self.assertIn('if(showStage)callDialog.getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);',ui)
        self.assertIn('else callDialog.getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);',ui)
        self.assertNotIn('getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)',ui.replace('callDialog.getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)',''))
        self.assertIn('boolean earpiece = !speaker && connected && !videoEnabled;',media)
        self.assertIn('Видео и звук защищены сквозным шифрованием',ui)
        # Engine: camera capture only through applyVideo after explicit setVideo; H.264 first, VP8 mandatory.
        self.assertIn('throw new SecurityException("Camera permission required")',media)
        self.assertIn('if (fallback.isEmpty()) throw new IllegalStateException("VP8 unavailable")',media)
        self.assertLess(media.index('mime.equals("video/h264")'),media.index('mime.equals("video/vp8")'))
        self.assertIn('localVideo.setEnabled(false);\n        peer.addTrack(localVideo',media)
        # Controller: video on -> speaker unless headset; off restores route; port checks CAMERA.
        self.assertIn('c.speakerBeforeVideo=c.speaker;c.speaker=true;',controller)
        self.assertIn('throw new SecurityException("camera permission")',engine)
        # Engine: an attached headset wins over the speakerphone while the camera is on (SDK>=31 and legacy).
        self.assertIn('if (speaker && attached != null && videoEnabled)',media)
        self.assertIn('boolean useSpeaker = speaker && !(videoEnabled && headset);',media)
        # A video-call start with the microphone already granted requests CAMERA alone under the microphone
        # request code; the result handler must decide on the real microphone grant, not on the array contents.
        handler=ui[ui.index('if(request==MICROPHONE_PERMISSION){'):ui.index('if(request==CAMERA_PERMISSION){')]
        self.assertIn('boolean microphone=checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED;',handler)
        self.assertNotIn('RECORD_AUDIO.equals(permissions[n])',handler)

    def test_v18_contact_names_tones_and_network_reconnect(self):
        ui=(ROOT/'src/org/paranoid/text/MainActivity.java').read_text()
        engine=(ROOT/'src/org/paranoid/text/TextEngine.java').read_text()
        tones=(ROOT/'src/org/paranoid/text/CallTones.java').read_text()
        names=(ROOT/'src/org/paranoid/text/ContactNames.java').read_text()
        loop=(ROOT/'src/org/paranoid/text/RealtimeLoop.java').read_text()
        service=(ROOT/'src/org/paranoid/text/VoiceCallService.java').read_text()
        # 1. Local-only contact names: every title site uses ContactNames; stored outside the encrypted snapshot.
        self.assertNotIn('MessagePresentation.title(',ui)
        self.assertEqual(ui.count('ContactNames.title(this,'),4)
        self.assertIn('setPositiveButton("Переименовать"',ui)
        self.assertIn('paranoid-contact-names-v1',names)
        for token in ['text-state.enc','SnapshotCodec','KeyStore','sendCall','client.']:
            self.assertNotIn(token,names)
        # 2/4. Audible progress from the authenticated controller state only: incoming ring, outgoing ringback, busy.
        self.assertIn('tones.changed(view);',engine)
        for token in ['TYPE_RINGTONE','RINGER_MODE_SILENT','TONE_SUP_RINGTONE','TONE_SUP_BUSY','STREAM_VOICE_CALL','VibrationEffect.createWaveform','MAX_RING_MS']:
            self.assertIn(token,tones)
        for token in ['mediaVideo','mediaMute','RECORD_AUDIO','CAMERA','startCapture']:
            self.assertNotIn(token,tones)
        self.assertIn('setPriority(Notification.PRIORITY_MAX)',service)
        # 3. Delivery: default-network change restarts the long-poll immediately (no FCM exists in this build).
        self.assertIn('registerDefaultNetworkCallback',engine)
        self.assertIn('public void restart(){',loop)
        self.assertIn('if(changed)realtime.restart();startConnection();',engine)
        # v20: FCM wake is content-free and only reconnects; the token goes over the signed session.
        push=(ROOT/'src/org/paranoid/text/PushService.java').read_text()
        manifest=(ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('if(!"wake".equals(message.getData().get("t")))return;',push)
        for token in ['getNotification','NotificationManager','Toast','sendCall','client.']:
            self.assertNotIn(token,push)
        self.assertIn('client.sessionRequest(context.context,"push",token)',loop)
        self.assertIn('catch(Exception ignored){pushedSession=null;',loop,'push registration never blocks the send lane')
        self.assertIn('pushedSession=context;pushedToken=token;\n        try {',loop)
        # A wake never restarts a live loop or touches an active call (v22 regression: call setup froze).
        self.assertIn('if(callActive||callDraining||connected){realtime.nudge();return;}',engine)
        self.assertNotIn('realtime.restart();startConnection();realtime.nudge()',engine)
        self.assertIn('public void nudge(){synchronized(lifecycle){nudges++;lifecycle.notifyAll();}kick();}',loop)
        self.assertIn('CrashLog.install(context);',engine)
        self.assertIn('<service android:name="org.paranoid.text.PushService" android:exported="false">',manifest)
        self.assertIn('android:authorities="global.paranoid.messenger.firebaseinitprovider"',manifest)
        self.assertIn('com.google.android.c2dm.permission.RECEIVE',manifest)
        values=(ROOT/'res/values/firebase.xml').read_text()
        self.assertIn('<string name="project_id" translatable="false">para-no-id</string>',values)

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
