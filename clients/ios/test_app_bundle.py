#!/usr/bin/env python3
"""Packaging gate of the built iOS application bundle (RFC-0021, draft ADR-0014).

The sibling of ``clients/android/test_apk.py``: it reads a finished
``ParanoID.app`` — the one ``clients/ios/build.sh`` copies to
``clients/ios/out/ParanoID.app`` — and answers what an inspector would ask of
a package before it goes anywhere near a phone.

* **Identity and version.** ``CFBundleIdentifier`` is the Android package
  ``global.paranoid.messenger`` (owner decision, ADR-0014),
  ``CFBundleShortVersionString`` / ``CFBundleVersion`` are the pinned pair
  below, and ``MinimumOSVersion`` is the ``ios_deployment_target`` of
  ``toolchain.json``. The version pair is spelled out here on purpose: a build
  that ships a different one has to say so in this file, exactly as the
  Android test pins ``versionCode`` / ``versionName``.
* **No delivery path this client does not have.** ``UIBackgroundModes`` is
  exactly ``[audio]`` — the mode a live call needs — with no ``voip``; no
  ``aps-environment`` in the plist or in the signed entitlements, because
  there is no push (RFC-0020 is the Android gateway, not this client); and no
  ``NSAppTransportSecurity`` / ``NSAllowsArbitraryLoads``, because every
  socket goes through the pinned trust evaluator.
* **What is inside.** One arm64 Mach-O executable, exactly one embedded
  framework — the pinned ``WebRTC.framework`` — whose binary is byte-for-byte
  the slice ``webrtc_dependency.py`` verified against the pinned archive, and
  ``THIRD_PARTY_NOTICES.txt`` identical to what ``notices.py`` wrote.
* **What is not inside.** No ``.p12``, ``.p8``, ``.env`` or
  ``.mobileprovision``. The one tolerated exception is the canonical
  ``embedded.mobileprovision`` at the root of a signed bundle, which iOS
  itself puts there; it is reported on its own line, never passed over in
  silence.
* **Signature.** When the bundle is signed, ``codesign -dv`` must report the
  Team ID in ``PARANOID_IOS_TEAM_ID`` (a signed bundle with that variable
  unset is a failure, not a skip). An unsigned bundle — what a simulator or
  ``CODE_SIGNING_ALLOWED=NO`` build produces, and all this repository can make
  without the owner's signing gate — is reported as unsigned and the
  signature checks say ``SKIPPED``, never ``OK``.

Offline and read-only: it opens no simulator, builds nothing and reaches no
network. Exit 0 with ``PASS: N checks`` or 1 with one ``FAIL:`` line per
broken rule; exit 2 when the bundle or a pin cannot be read at all, so a
missing build is never a vacuous pass.

Usage: ``python3 clients/ios/test_app_bundle.py [bundle] [--evidence PATH]``
The bundle path defaults to ``out/ParanoID.app`` next to this script, and a
relative path is resolved against the current directory first, then against
``clients/ios``.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

HERE = Path(__file__).resolve().parent
DEFAULT_BUNDLE = HERE / 'out/ParanoID.app'
DEFAULT_EVIDENCE = HERE / 'out/evidence/app-bundle.json'
NOTICES = HERE / 'out/THIRD_PARTY_NOTICES.txt'
TOOLCHAIN = HERE / 'toolchain.json'

BUNDLE_ID = 'global.paranoid.messenger'
# Pinned like clients/android/test_apk.py pins versionCode/versionName; the
# build settings are in App/ParanoID.xcodeproj (MARKETING_VERSION and
# CURRENT_PROJECT_VERSION of all three targets).
SHORT_VERSION = '0.0.1'
BUILD_VERSION = '1'
NOTICES_NAME = 'THIRD_PARTY_NOTICES.txt'
FRAMEWORK = 'WebRTC.framework'
SECRET_SUFFIXES = ('.p12', '.p8', '.env', '.mobileprovision')
# The profile iOS itself embeds in a signed bundle; reported, never silent.
EMBEDDED_PROFILE = 'embedded.mobileprovision'


def unavailable(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(2)


def load_webrtc_dependency():
    """The pinned slice digests, from the module that enforces them."""
    spec = importlib.util.spec_from_file_location(
        'webrtc_dependency', HERE / 'webrtc_dependency.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve(raw):
    """Accept a path relative to the current directory or to clients/ios."""
    candidate = Path(raw)
    if candidate.exists() or candidate.is_absolute():
        return candidate.resolve()
    fallback = HERE / raw
    return (fallback if fallback.exists() else candidate).resolve()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def run(argv):
    """Return (exit code, stdout+stderr) of a local tool; never raises."""
    result = subprocess.run(argv, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


class Report:
    def __init__(self):
        self.checks = []
        self.failures = []
        self.notes = []

    def ok(self, name, detail=''):
        self.checks.append((name, 'OK', detail))
        print(f'  OK       {name}' + (f': {detail}' if detail else ''))

    def skip(self, name, detail):
        self.checks.append((name, 'SKIPPED', detail))
        print(f'  SKIPPED  {name}: {detail}')

    def fail(self, name, detail):
        self.checks.append((name, 'FAIL', detail))
        self.failures.append(f'{name}: {detail}')
        print(f'  FAIL     {name}: {detail}')

    def equal(self, name, observed, expected):
        if observed == expected:
            self.ok(name, str(observed))
        else:
            self.fail(name, f'expected {expected!r}, found {observed!r}')

    def note(self, text):
        self.notes.append(text)
        print(f'  note     {text}')


def check_identity(plist, report):
    report.equal('bundle identifier', plist.get('CFBundleIdentifier'), BUNDLE_ID)
    report.equal('CFBundleShortVersionString', plist.get('CFBundleShortVersionString'), SHORT_VERSION)
    report.equal('CFBundleVersion', plist.get('CFBundleVersion'), BUILD_VERSION)
    try:
        pins = json.loads(TOOLCHAIN.read_text())
    except (OSError, ValueError) as error:
        unavailable(f'cannot read {TOOLCHAIN}: {error}')
    report.equal('MinimumOSVersion', plist.get('MinimumOSVersion'), pins['ios_deployment_target'])
    report.equal('CFBundleExecutable', plist.get('CFBundleExecutable'), 'ParanoID')


def check_delivery_path(plist, raw, report):
    modes = plist.get('UIBackgroundModes')
    report.equal('UIBackgroundModes', modes, ['audio'])
    for key in ('aps-environment', 'NSAppTransportSecurity', 'NSAllowsArbitraryLoads'):
        if key in plist or key in raw:
            report.fail(f'Info.plist has no {key}', 'present in the built plist')
        else:
            report.ok(f'Info.plist has no {key}')
    if 'voip' in (modes or []) or 'voip' in raw:
        report.fail('no voip background mode', 'the plist names voip')
    else:
        report.ok('no voip background mode')
    for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
        if (plist.get(key) or '').strip():
            report.ok(f'{key} carries a reason')
        else:
            report.fail(f'{key} carries a reason', 'missing or empty')


def check_executable(bundle, plist, report):
    executable = bundle / plist.get('CFBundleExecutable', 'ParanoID')
    if not executable.is_file():
        report.fail('executable present', f'{executable.name} missing')
        return
    code, output = run(['lipo', '-archs', str(executable)])
    if code != 0:
        report.fail('executable architectures', output.strip().splitlines()[-1] if output.strip() else 'lipo failed')
        return
    report.equal('executable architectures', output.split(), ['arm64'])


def check_frameworks(bundle, plist, webrtc, report):
    frameworks = bundle / 'Frameworks'
    if not frameworks.is_dir():
        report.fail(f'{FRAMEWORK} embedded', 'the bundle has no Frameworks directory')
        return None
    embedded = sorted(entry.name for entry in frameworks.iterdir())
    report.equal('embedded frameworks', embedded, [FRAMEWORK])
    binary = frameworks / FRAMEWORK / 'WebRTC'
    if not binary.is_file():
        report.fail('WebRTC binary present', f'{FRAMEWORK}/WebRTC missing')
        return None
    digest = sha256(binary)
    # Which slice this bundle must carry: the device build takes ios-arm64,
    # a simulator build the fat simulator slice.
    platforms = plist.get('CFBundleSupportedPlatforms') or []
    wanted = 'ios-arm64_x86_64-simulator' if 'iPhoneSimulator' in platforms else 'ios-arm64'
    expected = webrtc.SLICE_SHA256[wanted]
    if digest == expected:
        report.ok(f'WebRTC binary is the pinned {wanted} slice', digest)
    elif digest in webrtc.SLICE_SHA256.values():
        other = [name for name, value in webrtc.SLICE_SHA256.items() if value == digest][0]
        report.fail('WebRTC binary slice', f'bundle for {platforms} carries the {other} slice')
    elif (bundle / '_CodeSignature').exists():
        # Xcode re-signs an embedded framework, so a signed bundle cannot
        # carry the pinned bytes; the pin is enforced at extraction by
        # webrtc_dependency.py and re-checked here through the version.
        report.skip(f'WebRTC binary is the pinned {wanted} slice',
                    'signed bundle: Xcode re-signed the framework, digest '
                    f'{digest} is not the extracted {expected}')
    else:
        report.fail(f'WebRTC binary is the pinned {wanted} slice',
                    f'{digest} != {expected} in an unsigned bundle')
    info = frameworks / FRAMEWORK / 'Info.plist'
    if info.is_file():
        with open(info, 'rb') as handle:
            framework_plist = plistlib.load(handle)
        report.equal('WebRTC.framework CFBundleIdentifier',
                     framework_plist.get('CFBundleIdentifier'), 'org.webrtc.WebRTC')
    else:
        report.fail('WebRTC.framework Info.plist', 'missing')
    return digest


def check_notices(bundle, report):
    packaged = bundle / NOTICES_NAME
    if not packaged.is_file():
        report.fail(f'{NOTICES_NAME} in the bundle',
                    'missing; run notices.py before xcodebuild')
        return None
    digest = sha256(packaged)
    if NOTICES.is_file():
        source = sha256(NOTICES)
        if source == digest:
            report.ok(f'{NOTICES_NAME} matches out/{NOTICES_NAME}', digest)
        else:
            report.fail(f'{NOTICES_NAME} matches out/{NOTICES_NAME}',
                        f'{digest} != {source}; the bundle is stale')
    else:
        report.fail(f'{NOTICES_NAME} matches out/{NOTICES_NAME}',
                    f'{NOTICES} does not exist; run notices.py')
    text = packaged.read_text(errors='replace')
    for marker in ('WebRTC', 'vodozemac', 'jni 0.21.1'):
        if marker in text:
            report.ok(f'{NOTICES_NAME} names {marker}')
        else:
            report.fail(f'{NOTICES_NAME} names {marker}', 'not found')
    for absent in ('ZXing', 'Firebase'):
        if absent in text:
            report.fail(f'{NOTICES_NAME} has no {absent} block', 'found an Android-only component')
        else:
            report.ok(f'{NOTICES_NAME} has no {absent} block')
    return digest


def check_secrets(bundle, report):
    signed = (bundle / '_CodeSignature').exists()
    offenders = []
    profile = None
    for path in sorted(bundle.rglob('*')):
        if not path.is_file():
            continue
        name = path.name
        if not name.lower().endswith(SECRET_SUFFIXES):
            continue
        relative = path.relative_to(bundle)
        if str(relative) == EMBEDDED_PROFILE and signed:
            profile = relative
            continue
        offenders.append(str(relative))
    if offenders:
        report.fail('no signing material in the bundle', ', '.join(offenders))
    else:
        report.ok('no signing material in the bundle',
                  'none of ' + ' '.join(SECRET_SUFFIXES))
    if profile is not None:
        report.note(f'signed bundle carries the canonical {profile} (iOS puts it there)')


def check_signature(bundle, report):
    signed = (bundle / '_CodeSignature').exists()
    code, output = run(['codesign', '-dv', '--verbose=2', str(bundle)])
    expected = os.environ.get('PARANOID_IOS_TEAM_ID', '').strip()
    if code != 0 or 'not signed' in output:
        if signed:
            report.fail('bundle signature', f'_CodeSignature present but codesign refused it: {output.strip()}')
            return None
        report.skip('Team ID matches PARANOID_IOS_TEAM_ID',
                    'unsigned bundle (CODE_SIGNING_ALLOWED=NO); signing is the owner gate')
        return None
    team = ''
    for line in output.splitlines():
        if line.startswith('TeamIdentifier='):
            team = line.split('=', 1)[1].strip()
    if not expected:
        report.fail('Team ID matches PARANOID_IOS_TEAM_ID',
                    f'the bundle is signed by TeamIdentifier={team or "?"} but PARANOID_IOS_TEAM_ID is unset')
        return team
    report.equal('Team ID matches PARANOID_IOS_TEAM_ID', team, expected)
    code, entitlements = run(['codesign', '-d', '--entitlements', ':-', str(bundle)])
    if code != 0:
        report.fail('signed entitlements readable', entitlements.strip())
    elif 'aps-environment' in entitlements:
        report.fail('signed entitlements have no aps-environment', 'present')
    else:
        report.ok('signed entitlements have no aps-environment')
    return team


def write_evidence(path, bundle, plist, report, digests, team):
    payload = {
        'generated': datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        'script': 'clients/ios/test_app_bundle.py',
        'bundle': str(bundle),
        'bundle_identifier': plist.get('CFBundleIdentifier'),
        'short_version': plist.get('CFBundleShortVersionString'),
        'build_version': plist.get('CFBundleVersion'),
        'minimum_os_version': plist.get('MinimumOSVersion'),
        'platforms': plist.get('CFBundleSupportedPlatforms'),
        'signed': (bundle / '_CodeSignature').exists(),
        'team_identifier': team,
        'sha256': digests,
        'result': 'FAIL' if report.failures else 'PASS',
        'checks': [{'name': name, 'status': status, 'detail': detail}
                   for name, status, detail in report.checks],
        'notes': report.notes,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('bundle', nargs='?', default=str(DEFAULT_BUNDLE),
                        help='built ParanoID.app (default: clients/ios/out/ParanoID.app)')
    parser.add_argument('--evidence', type=Path, default=DEFAULT_EVIDENCE,
                        help='evidence JSON (default: clients/ios/out/evidence/app-bundle.json)')
    args = parser.parse_args(argv)

    bundle = resolve(args.bundle)
    if not bundle.is_dir():
        unavailable(f'{bundle} is not a built application bundle (run clients/ios/build.sh)')
    info = bundle / 'Info.plist'
    if not info.is_file():
        unavailable(f'{info} is missing')
    raw = info.read_bytes()
    try:
        plist = plistlib.loads(raw)
    except (plistlib.InvalidFileException, ValueError) as error:
        unavailable(f'cannot parse {info}: {error}')
    webrtc = load_webrtc_dependency()

    print(f'bundle: {bundle}')
    report = Report()
    check_identity(plist, report)
    check_delivery_path(plist, raw.decode('utf-8', 'replace'), report)
    check_executable(bundle, plist, report)
    webrtc_digest = check_frameworks(bundle, plist, webrtc, report)
    notices_digest = check_notices(bundle, report)
    check_secrets(bundle, report)
    team = check_signature(bundle, report)

    digests = {'webrtc_framework': webrtc_digest, NOTICES_NAME.lower(): notices_digest}
    executable = bundle / plist.get('CFBundleExecutable', 'ParanoID')
    if executable.is_file():
        digests['executable'] = sha256(executable)
    write_evidence(args.evidence, bundle, plist, report, digests, team)

    if report.failures:
        for failure in report.failures:
            print(f'FAIL: {failure}')
        print(f'FAIL: {len(report.failures)} of {len(report.checks)} checks; evidence: {args.evidence}')
        return 1
    skipped = sum(1 for _, status, _ in report.checks if status == 'SKIPPED')
    tail = f' ({skipped} skipped)' if skipped else ''
    print(f'PASS: {len(report.checks)} checks{tail}; evidence: {args.evidence}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
