#!/usr/bin/env python3
"""Owned loopback messaging/PG rehearsal only; no TURN, firewall, namespace or root."""
import argparse
import os
from pathlib import Path
import pwd
import re
import secrets
import subprocess
import sys
from unittest.mock import patch
import tarfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import single_host as kit
import single_host_message as message

HERE = Path(__file__).resolve().parent
OFFLINE_COMMAND = ['/usr/bin/python3', '-m', 'unittest', 'discover', '-s', str(HERE),
                   '-p', 'test_single_host*.py']


def offline_sources():
    return {p.name: kit.sha(kit.read_build_file(p))
            for p in sorted(HERE.glob('*single_host*.py'))}


def passing_test_count(raw):
    matches = re.findall(rb'\nRan ([1-9][0-9]*) tests? in [0-9.]+s\n\nOK\n\Z', raw)
    if len(matches) != 1 or b'FAILED' in raw or b'ERROR' in raw:
        raise ValueError('complete actual successful offline test output required')
    return int(matches[0])


def validate_offline_report(path, manifest):
    report = kit.decode_json(kit.read_file(path, 128 * 1024))
    fields = {'v', 'kind', 'result', 'command', 'exit_code', 'test_count',
              'source_sha256', 'log', 'log_sha256'}
    if (not isinstance(report, dict) or set(report) != fields or report['v'] != 1
            or report['kind'] != 'single-host-offline-test-report' or report['result'] != 'PASS'
            or type(report['exit_code']) is not int or report['exit_code'] != 0
            or report['command'] != OFFLINE_COMMAND or report['source_sha256'] != offline_sources()):
        raise ValueError('exact successful prior offline report and source identity required')
    raw = kit.read_file(kit.simple_path(report['log']), 1024 * 1024)
    if (kit.sha(raw) != report['log_sha256'] or type(report['test_count']) is not int
            or report['test_count'] != passing_test_count(raw)
            or any(manifest['sha256'][name] != report['source_sha256'][name]
                   for name in ('single_host.py', 'single_host_message.py'))):
        raise ValueError('offline output or packaged code correspondence failure')
    return report


def write_offline_report(output):
    output = kit.simple_path(str(output))
    output.mkdir(mode=0o700)  # New retained report only; never overwrite a failure.
    before = offline_sources()
    completed = subprocess.run(OFFLINE_COMMAND, capture_output=True, timeout=90)
    raw = completed.stdout + completed.stderr
    kit.atomic_write(output / 'tests.log', raw, exclusive=True)
    count = passing_test_count(raw) if completed.returncode == 0 else 0
    result = 'PASS' if completed.returncode == 0 and count and before == offline_sources() else 'FAIL'
    report = {'v': 1, 'kind': 'single-host-offline-test-report', 'result': result,
              'command': OFFLINE_COMMAND, 'exit_code': completed.returncode, 'test_count': count,
              'source_sha256': before, 'log': str(output / 'tests.log'), 'log_sha256': kit.sha(raw)}
    kit.atomic_write(output / 'report.json', kit.canonical(report), exclusive=True)
    if result != 'PASS':
        raise RuntimeError('offline report failed; retained actual output')
    return report


def extract_old(archive, target):
    target.mkdir(mode=0o700)
    with tarfile.open(archive, 'r:') as source:
        members = source.getmembers()
        if len(members) > 16:
            raise ValueError('old release membership bound')
        names = set()
        for entry in members:
            path = Path(entry.name)
            if (not entry.isfile() or len(path.parts) != 2 or path.parts[0] != 'release'
                    or path.name in names or path.name in ('.', '..') or entry.size > kit.MAX_FILE):
                raise ValueError('unsafe old release archive')
            names.add(path.name)
        for entry in members:
            with source.extractfile(entry) as stream:
                data = stream.read(kit.MAX_FILE + 1)
            kit.atomic_write(target / Path(entry.name).name, data,
                             0o700 if entry.mode & 0o111 else 0o600, exclusive=True)
    kit.verify_component(target)


def accepted_fixture(manifest, design, offline, plan_sha256):
    # These are actual prior report hashes, never a production PASS receipt.
    validate_offline_report(offline, manifest)
    return {'v': 1, 'profile': kit.FIXTURE, 'kit_sha256': kit.sha(kit.canonical(manifest)), 'plan_sha256': plan_sha256,
            'gates': {'design-review': {'result': 'PASS', 'evidence_sha256': kit.sha(kit.read_file(design))},
                      'offline-tests': {'result': 'PASS', 'evidence_sha256': kit.sha(kit.read_file(offline))},
                      'artifact-verification': {'result': 'PASS', 'evidence_sha256': kit.sha(kit.canonical(manifest))}}}


def fresh_scenarios(alpha, base, candidate, manifest, args, results):
    root, unit = Path(base['message']['root']), base['message']['unit']
    planned = kit.plan(base, candidate)
    receipt = accepted_fixture(manifest, args.design_report, args.offline_report, planned['plan_sha256'])
    initial = kit.apply(base, candidate, receipt, planned['plan_sha256'])
    assert initial['verified']
    assert not (root / 'voice-turn').exists()
    results['checks'].append('actual fresh coordinated default-disabled message/privatePG/TLS installation')
    alpha.sql(root, "INSERT INTO ss_accounts VALUES ('fixture-a','root-a','active'),('fixture-b','root-b','active'); "
              "INSERT INTO ss_devices VALUES('fixture-a','da','aa','fa','ca'),('fixture-b','db','ab','fb','cb'); "
              "INSERT INTO ss_conversations VALUES('fixture-a','fixture-b'); "
              "INSERT INTO ss_messages VALUES(1,'fixture-a','fixture-b','before',decode('010203','hex'),'fixture-a','fixture-b'); "
              "UPDATE ss_meta SET sequence=1")
    before = message.identity(alpha, root, unit)
    update_source = args.output / 'fixture-update-source'
    kit.copy_tree(candidate / 'message', update_source)
    controller = update_source / 'alpha.py'
    kit.atomic_write(controller, kit.read_file(controller) + b'\n# Fixture-only code-update correspondence marker.\n')
    component = kit.decode_json(kit.read_file(update_source / 'manifest.json'))
    component['sha256']['alpha.py'] = kit.sha(kit.read_file(controller))
    component['release'] = kit.component_id(component['sha256'])
    component['fixture_only'] = True
    component['source_dirty'] = True
    kit.atomic_write(update_source / 'manifest.json', kit.canonical(component))
    update_kit = args.output / 'fixture-update-kit'
    update_manifest = kit.build_kit(kit.FIXTURE, update_source, None, update_kit)
    update_intent = {**base, 'mode': 'existing-v8', 'expected': before,
                     'kit_sha256': kit.sha(kit.read_file(update_kit / 'manifest.json'))}
    update_plan = kit.plan(update_intent, update_kit)
    update_receipt = accepted_fixture(update_manifest, args.design_report, args.offline_report, update_plan['plan_sha256'])
    updated = kit.apply(update_intent, update_kit, update_receipt, update_plan['plan_sha256'], updating=True)
    assert updated['identity']['release'] != before['release']
    results['checks'].append('actual update selects different fixture-only controller release with original native/schema')
    alpha.sql(root, "INSERT INTO ss_messages VALUES(2,'fixture-a','fixture-b','after',decode('040506','hex'),'fixture-a','fixture-b'); UPDATE ss_meta SET sequence=2")
    current = kit.status(kit.coordinator_state(base))
    kit.rollback(kit.coordinator_state(base), current['transaction'], current['state_sha256'])
    assert message.identity(alpha, root, unit) == before
    assert alpha.sql(root, 'SELECT sequence FROM ss_messages ORDER BY sequence').strip() == b'1\n2'
    results['checks'].append('actual explicit rollback preserves fresh identity and post-update row')
    # A test-only function replacement injects exactly one failure after genuine
    # candidate readiness. No diagnostic flag/hook is present in the shipped kit.
    original_health = alpha.wait_health
    injected = []
    def fail_once(checked_root):
        original_health(checked_root)
        if not injected:
            alpha.sql(root, "INSERT INTO ss_messages VALUES(3,'fixture-a','fixture-b','before-failure',decode('070809','hex'),'fixture-a','fixture-b'); UPDATE ss_meta SET sequence=3")
            injected.append(True)
            raise RuntimeError('fixture injected readiness failure')
    failed_intent = {**update_intent, 'expected': before}
    with patch.object(alpha, 'wait_health', side_effect=fail_once):
        try:
            message.apply_existing(alpha, failed_intent, update_kit / 'message', secrets.token_hex(16), None)
        except RuntimeError as error:
            if str(error) != 'message update failed; previous exact config/code restored on current data':
                raise
        else:
            raise AssertionError('injected failure falsely succeeded')
    assert injected == [True]
    assert message.identity(alpha, root, unit) == before
    assert alpha.sql(root, 'SELECT sequence FROM ss_messages ORDER BY sequence').strip() == b'1\n2\n3'
    alpha.health(root)
    results['checks'].append('one injected post-start readiness failure restores exact previous code/config/unit on all current rows')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=('existing', 'fresh'), default='existing')
    parser.add_argument('--message', type=Path, required=True)
    parser.add_argument('--old-tar', type=Path, required=True)
    parser.add_argument('--design-report', type=Path, required=True)
    parser.add_argument('--offline-report', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise ValueError('unprivileged fixture only')
    output = args.output
    output.mkdir(mode=0o700)
    suffix = secrets.token_hex(8)
    root = Path('/var/tmp') / ('paranoid-fixture-' + suffix)
    unit = 'paranoid-alpha-fixture-' + suffix + '.service'
    old = output / 'old-release'
    extract_old(args.old_tar, old)
    candidate = output / 'fixture-kit'
    manifest = kit.build_kit(kit.FIXTURE, args.message, None, candidate)
    alpha = message.load_alpha(candidate / 'message')
    user = pwd.getpwuid(os.geteuid())
    base = {'v': 1, 'profile': kit.FIXTURE, 'mode': 'fresh', 'ip': '127.0.0.73',
            'kit_sha256': kit.sha(kit.read_file(candidate / 'manifest.json')), 'expected': None,
            'message': {'user': user.pw_name, 'uid': os.geteuid(), 'gid': os.getegid(),
                        'root': str(root), 'unit': unit}}
    kit.fixture_boundary(base)
    created = False
    results = {'v': 1, 'profile': kit.FIXTURE, 'scope': 'message-phases-rehearsal',
               'turn_runtime': 'NOT RUN', 'firewall_packets': 'NOT RUN',
               'kit_manifest_sha256': base['kit_sha256'], 'fixture_root': str(root), 'checks': []}
    try:
        if args.scenario == 'fresh':
            created = True  # cleanup still verifies exact owned fragment before stopping
            fresh_scenarios(alpha, base, candidate, manifest, args, results)
            results['result'] = 'PASS'
            return
        # Baseline is the exact old deployed v8 artifact, in a wholly new cluster.
        message.load_alpha(old).install_v2(root, base['ip'], old, unit)
        created = True
        alpha.sql(root, "INSERT INTO ss_accounts VALUES ('fixture-a','root-a','active'),('fixture-b','root-b','active'); "
                  "INSERT INTO ss_devices VALUES('fixture-a','da','aa','fa','ca'),('fixture-b','db','ab','fb','cb'); "
                  "INSERT INTO ss_conversations VALUES('fixture-a','fixture-b'); "
                  "INSERT INTO ss_messages VALUES(1,'fixture-a','fixture-b','before',decode('010203','hex'),'fixture-a','fixture-b'); "
                  "UPDATE ss_meta SET sequence=1")
        before = message.identity(alpha, root, unit)
        intent = {**base, 'mode': 'existing-v8', 'expected': before}
        planned = kit.plan(intent, candidate)
        acceptance = accepted_fixture(manifest, args.design_report, args.offline_report, planned['plan_sha256'])
        outcome = kit.apply(intent, candidate, acceptance, planned['plan_sha256'])
        assert outcome['verified'] and outcome['phase'] == 'active'
        results['checks'].append('actual existing-v8 coordinated default-disabled message update with privatePG/TLS')
        repeat = kit.apply(intent, candidate, acceptance, planned['plan_sha256'])
        assert repeat['phase'] == 'already-applied'
        results['checks'].append('identical apply is verified idempotent')
        alpha.sql(root, "INSERT INTO ss_messages VALUES(2,'fixture-a','fixture-b','after',decode('040506','hex'),'fixture-a','fixture-b'); UPDATE ss_meta SET sequence=2")
        current = kit.status(kit.coordinator_state(intent))
        kit.rollback(kit.coordinator_state(intent), current['transaction'], current['state_sha256'])
        assert message.identity(alpha, root, unit) == before
        assert alpha.sql(root, 'SELECT sequence FROM ss_messages ORDER BY sequence').strip() == b'1\n2'
        assert alpha.sql(root, 'SELECT sequence FROM ss_meta').strip() == b'2'
        results['checks'].append('exact old code/config/unit/TLS/cluster restored with post-update row retained')
        backups = list((root / 'backups').glob('v2-*/manifest.json'))
        assert backups and all(kit.decode_json(kit.read_file(p))['verified'] for p in backups)
        results['checks'].append('actual encrypted backup restored and compared before code cutover')
        results['result'] = 'PASS'
    except BaseException:
        results['result'] = 'FAIL'
        raise
    finally:
        if created and (root / unit).exists():
            message.verify_fragment(alpha, root, unit)
            alpha.command(['systemctl', '--user', 'stop', unit])
            alpha.command(['systemctl', '--user', 'disable', unit])
            state = alpha.command(['systemctl', '--user', 'show', unit, '-p', 'MainPID', '-p', 'ControlPID']).decode()
            results['cleanup'] = 'MainPID=0\n' in state and 'ControlPID=0\n' in state and not (root / 'data/postmaster.pid').exists()
        kit.atomic_write(output / 'result.json', kit.canonical(results), exclusive=True)
        print(kit.canonical(results).decode(), end='')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--write-offline-report':
        print(kit.canonical(write_offline_report(Path(sys.argv[2]))).decode(), end='')
    else:
        main()
