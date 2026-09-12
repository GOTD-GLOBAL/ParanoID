#!/usr/bin/env python3
"""Static Android exposure gate; actual service lifecycle requires emulator/device."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parent
A='{http://schemas.android.com/apk/res/android}'

class BackgroundContract(unittest.TestCase):
    def test_explicit_private_user_visible_service_without_boot_or_push_provider(self):
        manifest=ET.parse(ROOT/'AndroidManifest.xml').getroot()
        permissions={p.get(A+'name') for p in manifest.findall('uses-permission')}
        self.assertTrue({'android.permission.FOREGROUND_SERVICE','android.permission.FOREGROUND_SERVICE_SPECIAL_USE','android.permission.POST_NOTIFICATIONS'}<=permissions)
        services=manifest.findall('application/service')
        own=[s for s in services if s.get(A+'name').startswith('org.paranoid.text.')]
        self.assertEqual(sorted(s.get(A+'name') for s in own),['org.paranoid.text.BackgroundConnectionService','org.paranoid.text.PushService','org.paranoid.text.VoiceCallService'])
        # v20 (RFC-0020): the remaining services/receivers belong to the Firebase Messaging closure; none is
        # a foreground service, none is exported except the FCM receiver guarded by Google's SEND permission.
        library=[s for s in services if s not in own]
        self.assertTrue(all(s.get(A+'exported')=='false' and s.get(A+'foregroundServiceType') is None for s in library),[s.get(A+'name') for s in library])
        push=next(s for s in own if s.get(A+'name')=='org.paranoid.text.PushService')
        self.assertEqual(push.get(A+'exported'),'false');self.assertIsNone(push.get(A+'foregroundServiceType'))
        service=next(s for s in services if s.get(A+'name')=='org.paranoid.text.BackgroundConnectionService')
        self.assertEqual(service.get(A+'name'),'org.paranoid.text.BackgroundConnectionService')
        self.assertEqual(service.get(A+'exported'),'false')
        self.assertEqual(service.get(A+'foregroundServiceType'),'specialUse')
        self.assertEqual(len(service.findall('property')),1)
        receivers=manifest.findall('application/receiver')
        watchdog=[r for r in receivers if r.get(A+'name')=='org.paranoid.text.ConnectionWatchdog']
        self.assertEqual(len(watchdog),1)
        self.assertEqual(watchdog[0].get(A+'exported'),'false')
        self.assertEqual(watchdog[0].findall('intent-filter'),[],'watchdog must not listen to broadcasts like BOOT_COMPLETED')
        exported=[(r.get(A+'name'),r.get(A+'permission')) for r in receivers if r.get(A+'exported')=='true']
        self.assertEqual(exported,[('com.google.firebase.iid.FirebaseInstanceIdReceiver','com.google.android.c2dm.permission.SEND')])
        for r in receivers:
            for action in r.findall('intent-filter/action'):
                self.assertNotIn('BOOT_COMPLETED',action.get(A+'name'))
        self.assertIn('android.permission.WAKE_LOCK',permissions)
        voice=next(s for s in services if s.get(A+'name')=='org.paranoid.text.VoiceCallService')
        self.assertEqual(voice.get(A+'exported'),'false')
        self.assertEqual(voice.get(A+'foregroundServiceType'),'microphone|camera')
        self.assertIn('android.permission.FOREGROUND_SERVICE_CAMERA',permissions)
        self.assertTrue({'android.permission.RECORD_AUDIO','android.permission.FOREGROUND_SERVICE_MICROPHONE','android.permission.MODIFY_AUDIO_SETTINGS'}<=permissions)
        self.assertNotIn('android.permission.RECEIVE_BOOT_COMPLETED',permissions)
        self.assertNotIn('android.permission.SCHEDULE_EXACT_ALARM',permissions)
        self.assertNotIn('android.permission.USE_EXACT_ALARM',permissions)

    def test_threat_model_describes_current_restart_policy(self):
        threat=(ROOT.parent.parent/'docs/security/realtime-v1-threats.md').read_text()
        self.assertIn('START_STICKY',threat)
        self.assertIn('ConnectionWatchdog',threat)
        self.assertIn('best effort',threat)
        self.assertNotIn('restarts are non-sticky',threat)

    def test_watchdog_restarts_only_user_enabled_background_channel(self):
        service=(ROOT/'src/org/paranoid/text/BackgroundConnectionService.java').read_text()
        watchdog=(ROOT/'src/org/paranoid/text/ConnectionWatchdog.java').read_text()
        # Firmware kills of the user-enabled channel are recovered by the system restart
        # policy plus an inexact ~15-minute alarm; никогда не boot-start.
        self.assertIn('return START_STICKY;',service)
        self.assertIn('ConnectionWatchdog.enable(this)',service)
        self.assertIn('ConnectionWatchdog.disable(',service)
        self.assertIn('setInexactRepeating',watchdog)
        self.assertIn('ELAPSED_REALTIME_WAKEUP',watchdog)
        self.assertIn('15*60*1000L',watchdog)
        self.assertIn('BackgroundConnectionService.running()',watchdog)
        self.assertIn('startForegroundService',watchdog)
        self.assertIn('catch(RuntimeException',watchdog)
        self.assertIn("getBoolean(ENABLED_KEY,false)",watchdog)
        self.assertNotIn('setExact',watchdog)
        self.assertNotIn('BOOT_COMPLETED',watchdog)

if __name__=='__main__':unittest.main()
