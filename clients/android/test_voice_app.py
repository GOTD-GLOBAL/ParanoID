"""Real UI acceptance for a separately built, same-signer local test APK.

Requires the owned emulator, observation instrumentation8870 and actual
JNI/TLS/Olm/aiortc peer already running. Never points at a physical phone or
production network. Product source has only the documented local realm/pin
fixture delta; test instrumentation is a separate APK.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET


class Lab:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.evidence_dir)
        self.out.mkdir(parents=True, exist_ok=False)
        self.steps = []

    def adb(self, *args, raw=False):
        result = subprocess.run([self.args.adb, '-s', self.args.serial, *args], capture_output=True, check=True)
        return result.stdout if raw else result.stdout.decode().strip()

    def rpc(self, url, value):
        request = urllib.request.Request(url, json.dumps(value).encode(), {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=25) as response:
            result = json.load(response)
        if 'error' in result or 'fixture_error' in result:
            raise RuntimeError(result)
        return result

    def app(self, command='view', **values):
        return self.rpc(self.args.app_url, dict(command=command, **values))

    def host(self, operation='view', **values):
        return self.rpc(self.args.peer_url, dict(operation=operation, **values))

    def dump(self):
        self.adb('shell', 'uiautomator', 'dump', '/sdcard/voice-window.xml')
        return self.adb('exec-out', 'cat', '/sdcard/voice-window.xml')

    def tap(self, label):
        tree = ET.fromstring(self.dump())
        for node in tree.iter('node'):
            attrs = node.attrib
            if any(label.casefold() == attrs.get(key, '').casefold() for key in ['text', 'content-desc', 'resource-id']):
                assert attrs.get('enabled') == 'true', 'Disabled UI action: ' + label
                left, top, right, bottom = map(int, re.findall(r'\d+', attrs['bounds']))
                self.adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))
                time.sleep(.4)
                return
        raise AssertionError('UI action absent: ' + label)

    def wait(self, predicate, seconds=20, answer_host=False):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = self.app()
            if answer_host and self.host()['call']['state'] == 'incoming':
                self.host('answer')
            if predicate(value):
                return value
            time.sleep(.1)
        raise AssertionError('Actual app deadline: ' + json.dumps(value['call']))

    def save(self, name, value=None):
        if value is None:
            value = dict(app=self.app(), host=self.host())
        (self.out / (name + '.json')).write_text(json.dumps(value, indent=2, ensure_ascii=False, default=str))
        self.steps.append(name)

    def screenshot(self, name):
        time.sleep(.4)
        (self.out / (name + '.png')).write_bytes(self.adb('exec-out', 'screencap', '-p', raw=True))
        (self.out / (name + '.xml')).write_text(self.dump())
        self.save(name)

    def open_chat(self):
        labels = [n.attrib.get('content-desc', '') for n in ET.fromstring(self.dump()).iter('node')]
        if 'Аудиозвонок' not in labels:
            self.tap('Контакт ' + self.host()['account'][:6])

    def start(self, answer=True):
        self.open_chat()
        self.tap('Аудиозвонок')
        self.tap('Позвонить')
        if answer:
            return self.wait(lambda v: v['call']['state'] == 'connected', answer_host=True)

    def cleanup(self):
        return self.wait(lambda v: v['call']['state'] == 'ended' and not v['media_present']
                         and v['media_closing'] == 0 and v['active_recordings'] == 0
                         and v['audio_mode'] == 0 and not v['speaker'])

    def permission(self):
        self.start(answer=False)
        self.screenshot('permission-request')
        self.tap('com.android.permissioncontroller:id/permission_allow_foreground_only_button')
        self.wait(lambda v: v['call']['state'] == 'connected', seconds=15, answer_host=True)
        self.screenshot('first-grant-connected')
        self.host('hangup')
        self.cleanup()
        self.tap('Закрыть')

    def deferred(self):
        self.start()
        self.app('hold_media_owner')
        try:
            self.tap('Завершить')
            self.tap('Закрыть')
            self.start(answer=False)
            self.wait(lambda v: v['call']['state'] == 'outgoing' and v['media_closing'] == 1 and not v['media_present'], seconds=5)
            self.tap('Выключить микрофон')
            self.save('deferred-muted-intent')
        finally:
            self.app('release_media_owner')
        self.wait(lambda v: v['call']['state'] == 'connected', seconds=15, answer_host=True)
        actual = self.app('media_settings')
        self.save('actual-sdk-after-deferred-creation', dict(app=self.app(), sdk=actual, host=self.host()))
        assert self.app()['call']['muted'], 'UI mute intent lost'
        assert actual['engine_muted'] and not actual['track_enabled'], 'Deferred SDK engine lost mute intent'
        self.screenshot('deferred-muted-green')
        self.tap('Включить микрофон')
        assert self.app('media_settings')['track_enabled']
        self.host('hangup')
        self.cleanup()
        self.tap('Закрыть')

    def acceptance(self):
        account = self.app()['text']['account']
        before = self.app()['text']
        self.open_chat()
        self.host('start', account=account)
        incoming = self.wait(lambda v: v['call']['state'] == 'incoming')
        assert not incoming['media_present'] and incoming['active_recordings'] == 0
        old = incoming['call']
        self.screenshot('incoming-no-capture')
        self.tap('Отклонить')
        self.cleanup()
        self.screenshot('rejected')
        self.tap('Закрыть')
        self.host('start', account=account)
        self.wait(lambda v: v['call']['state'] == 'incoming')
        self.tap('Ответить')
        self.wait(lambda v: v['call']['state'] == 'connected')
        time.sleep(2)
        stats = self.app('media_stats')
        assert any(s.get('type') == 'inbound-rtp' and s.get('packetsReceived', 0) > 40 for s in stats['stats'])
        assert self.host()['media']['decoded_frames'] > 20
        self.save('actual-bidirectional-rtp', dict(android=stats, host=self.host()))
        self.screenshot('connected')
        self.tap('Выключить микрофон')
        actual = self.app('media_settings')
        assert actual['engine_muted'] and not actual['track_enabled']
        self.screenshot('muted')
        self.tap('Включить микрофон')
        assert self.app('media_settings')['track_enabled']
        self.tap('Громкая связь')
        self.wait(lambda v: v['speaker'])
        self.screenshot('speaker')
        self.tap('Телефонный динамик')
        self.wait(lambda v: not v['speaker'])
        live_id = self.app()['call']['call_id']
        self.app('stale_stop', call_id=old['call_id'], generation=old['generation'])
        time.sleep(.5)
        assert self.app()['call']['call_id'] == live_id and self.app()['call']['state'] == 'connected'
        self.save('stale-notification-preserves-current-call')
        self.tap('К переписке')
        self.tap('Сообщение')
        marker = 'voice-text-' + str(int(time.time()))
        self.adb('shell', 'input', 'text', marker)
        self.tap('Отправить сообщение')
        self.adb('shell', 'input', 'keyevent', '4')
        end = time.monotonic() + 10
        while marker not in json.dumps(self.host()['dialogs']):
            assert time.monotonic() < end, 'Text during audio failed'
            time.sleep(.1)
        self.screenshot('text-during-call')
        self.adb('shell', 'input', 'keyevent', '3')
        time.sleep(3)
        assert self.app()['call']['state'] == 'connected'
        services = self.adb('shell', 'dumpsys', 'activity', 'services', 'global.paranoid.messenger')
        (self.out / 'foreground-service.txt').write_text(services)
        assert 'VoiceCallService' in services and 'isForeground=true' in services
        self.save('background-active-call')
        self.adb('shell', 'am', 'start', '-n', 'global.paranoid.messenger/org.paranoid.text.MainActivity')
        time.sleep(.5)
        self.host('hangup')
        self.cleanup()
        self.save('remote-hangup-cleanup')
        self.start(answer=False)
        self.wait(lambda v: v['call']['state'] == 'outgoing')
        self.screenshot('outgoing')
        self.tap('Завершить')
        self.cleanup()
        self.screenshot('caller-cancel')
        self.tap('Закрыть')
        self.start()
        self.tap('Завершить')
        self.cleanup()
        self.screenshot('local-hangup')
        assert self.app()['text']['account'] == before['account'] and self.app()['text']['contact'] == before['contact']
        assert all(m in self.app()['text']['dialogs'][0]['messages'] for m in before['dialogs'][0]['messages'])
        self.save('identity-history-retained')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:18870/')
    parser.add_argument('--peer-url', default='http://127.0.0.1:18871/')
    parser.add_argument('--evidence-dir', required=True)
    parser.add_argument('--scenario', choices=['permission', 'deferred', 'acceptance'], required=True)
    args = parser.parse_args()
    assert args.serial.startswith('emulator-'), 'Only owned test emulators are supported'
    assert args.app_url.startswith('http://127.0.0.1:') and args.peer_url.startswith('http://127.0.0.1:')
    lab = Lab(args)
    result = dict(scenario=args.scenario, boundary='actual app UI + signed/E2EE control + native Android/aiortc media; synthetic identities')
    try:
        getattr(lab, args.scenario)()
        result['pass'] = True
    except Exception as error:
        result.update({'pass': False, 'failure': repr(error)})
        raise
    finally:
        result['steps'] = lab.steps
        (lab.out / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
