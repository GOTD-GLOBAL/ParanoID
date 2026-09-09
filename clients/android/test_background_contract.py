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
        self.assertEqual(len(services),2)
        service=next(s for s in services if s.get(A+'name')=='org.paranoid.text.BackgroundConnectionService')
        self.assertEqual(service.get(A+'name'),'org.paranoid.text.BackgroundConnectionService')
        self.assertEqual(service.get(A+'exported'),'false')
        self.assertEqual(service.get(A+'foregroundServiceType'),'specialUse')
        self.assertEqual(len(service.findall('property')),1)
        self.assertEqual(manifest.findall('application/receiver'),[])
        self.assertIn('android.permission.WAKE_LOCK',permissions)
        voice=next(s for s in services if s.get(A+'name')=='org.paranoid.text.VoiceCallService')
        self.assertEqual(voice.get(A+'exported'),'false')
        self.assertEqual(voice.get(A+'foregroundServiceType'),'microphone')
        self.assertTrue({'android.permission.RECORD_AUDIO','android.permission.FOREGROUND_SERVICE_MICROPHONE','android.permission.MODIFY_AUDIO_SETTINGS'}<=permissions)
        self.assertNotIn('android.permission.RECEIVE_BOOT_COMPLETED',permissions)

if __name__=='__main__':unittest.main()
