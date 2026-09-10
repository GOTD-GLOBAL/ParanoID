#!/usr/bin/env python3
"""REQ-DEPLOY-003: owned NIC-less guest runner, under construction.

Never imported by production. Incomplete case registration refuses before guest
mutation. Exact runner, supplemental inputs and boot artifact require independent
review before execution; this source does not grant its own prerequisites.
"""
import json
import base64
import hashlib
import hmac
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import single_host as kit
import single_host_vm as vm
import single_host_message as message
import single_host_vm_packets as packets

FIXTURE_ROOT = Path('/opt/voice-fixture')
KIT_ROOT = FIXTURE_ROOT / 'fixture-kit'
PRODUCTION_KIT = FIXTURE_ROOT / 'production-kit'
OLD_RELEASE = FIXTURE_ROOT / 'old-v8-release'
INPUT = FIXTURE_ROOT / 'run-input.json'
OUTPUT = Path('/run/paranoid-voice-fixture/results')
MESSAGE_ROOT = Path('/home/paranoid/paranoid-alpha')
PAM_TYPES = ('auth', 'account', 'password', 'session', 'session-noninteractive')
MAX_OUTPUT = 1024 * 1024
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C',
       'PYTHONDONTWRITEBYTECODE': '1', 'DEBIAN_FRONTEND': 'noninteractive'}


class Trace:
    """Retain actual output and failed observations before propagating failure."""
    def __init__(self, root, bindings, mode):
        self.root = Path(root)
        self.bindings = dict(bindings)
        self.mode = mode
        self.cases = {}
        self.active = None
        self.deadline = time.monotonic() + 1800

    def begin(self, name):
        if name not in vm.REQUIRED_CASES or name in self.cases:
            raise ValueError('fixed unique case required')
        self.cases[name] = {**self.bindings, 'v': 1, 'case': name,
                            'fixture_mode': self.mode, 'result': 'RUNNING',
                            'started_monotonic_ns': time.monotonic_ns(),
                            'finished_monotonic_ns': None, 'checks': {},
                            'measurements': {}, 'commands': []}
        self.active = name
        self.save()

    def select(self, name):
        if name not in self.cases or self.cases[name]['result'] != 'RUNNING':
            raise ValueError('existing unfinished case required')
        self.active = name

    @property
    def case(self):
        if self.active is None:
            raise ValueError('actual active observation required')
        return self.cases[self.active]

    def save(self):
        kit.atomic_write(self.root / (self.active + '.json'), kit.canonical(self.case))

    def check(self, name, observation):
        if name not in vm.REQUIRED_CASES[self.active] or type(observation) is not bool:
            raise ValueError('fixed boolean observation required')
        if name in self.case['checks']:
            raise ValueError('an observation may not be overwritten')
        self.case['checks'][name] = observation
        self.save()

    def measure(self, name, observation):
        if name in self.case['measurements']:
            raise ValueError('a measurement may not be overwritten')
        self.case['measurements'][name] = observation
        self.save()

    def failed(self, category):
        self.case.update(result='FAILED', failure=category,
                         finished_monotonic_ns=time.monotonic_ns())
        self.save()

    def finish(self):
        if set(self.case['checks']) != set(vm.REQUIRED_CASES[self.active]):
            raise ValueError('incomplete case observations')
        if self.case['result'] == 'FAILED' or any(v is not True for v in self.case['checks'].values()):
            raise ValueError('failed observation cannot become acceptance')
        if not self.case['commands'] or not self.case['measurements']:
            raise ValueError('actual commands and measurements required')
        self.case.update(result='OBSERVED', finished_monotonic_ns=time.monotonic_ns())
        self.save()
        return self.case

    def command(self, argv, data=None, timeout=60, expected=0, env=None):
        if time.monotonic() >= self.deadline:
            self.failed('suite_deadline')
            raise TimeoutError('guest suite deadline')
        argv = [str(arg) for arg in argv]
        record = {'argv': argv, 'exit_code': None, 'expected_exit_code': expected,
                  'output': '', 'output_sha256': kit.sha(b'')}
        self.case['commands'].append(record)
        self.save()
        try:
            completed = subprocess.run(argv, input=data, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=min(timeout, self.deadline - time.monotonic()),
                env=ENV if env is None else env)
        except subprocess.TimeoutExpired as error:
            raw = error.output or b''
            record['output'] = raw[:MAX_OUTPUT].decode(errors='backslashreplace')
            record['output_sha256'] = kit.sha(record['output'].encode())
            self.failed('command_timeout')
            raise
        record['exit_code'] = completed.returncode
        if len(completed.stdout) > MAX_OUTPUT:
            record['output'] = completed.stdout[:MAX_OUTPUT].decode(errors='backslashreplace')
            record['output_sha256'] = kit.sha(record['output'].encode())
            self.failed('command_output_bound')
            raise ValueError('actual command output exceeds bound')
        try:
            record['output'] = completed.stdout.decode('utf8', errors='strict')
        except UnicodeDecodeError:
            kit.atomic_write(self.root / (self.active + '-invalid-output.bin'), completed.stdout, exclusive=True)
            self.failed('command_output_not_utf8')
            raise
        record['output_sha256'] = kit.sha(completed.stdout)
        self.save()
        if completed.returncode != expected:
            self.failed('command_exit')
            raise RuntimeError('actual command failed')
        return completed.stdout


def require_initial_observation(value):
    if (value.get('product') != vm.DMI_PRODUCT or value.get('links') != ['lo']
            or value.get('network_pci') or value.get('physical_devices')
            or value.get('namespaces') or set(value.get('routes', {})) != {'-4', '-6'}):
        raise ValueError('pristine NIC-less guest boundary required')
    for family, routes in value['routes'].items():
        for route in routes:
            if (route.get('dev') != 'lo' or route.get('dst') not in
                    ({'127.0.0.0/8', '127.0.0.1', '127.255.255.255'} if family == '-4' else {'::1'})
                    or 'gateway' in route):
                raise ValueError('external or unexpected initial route')


def initial_observation(command):
    if os.getresuid() != (0, 0, 0):
        raise ValueError('owned guest root required')
    value = {'product': vm.descriptor_bytes('/sys/class/dmi/id/product_name', 256).decode().strip(),
             'physical_devices': sorted(p.parent.name for p in Path('/sys/class/net').glob('*/device')),
             'network_pci': [p.parent.name for p in Path('/sys/bus/pci/devices').glob('*/class')
                             if int(vm.descriptor_bytes(p, 32), 16) >> 16 == 2]}
    # DMI and physical/PCI checks precede even read-only ip commands.
    if value['product'] != vm.DMI_PRODUCT or value['physical_devices'] or value['network_pci']:
        raise ValueError('NIC-less owned guest required before commands')
    value['links'] = sorted(p['ifname'] for p in kit.decode_json(command(['ip', '-j', 'link', 'show'])))
    value['namespaces'] = kit.decode_json(command(['ip', '-j', 'netns', 'list']))
    value['routes'] = {family: kit.decode_json(command(['ip', '-j', family, 'route', 'show', 'table', 'all']))
                       for family in ('-4', '-6')}
    require_initial_observation(value)
    return value


def require_pristine_pam(root=Path('/')):
    root = Path(root)
    for name in PAM_TYPES:
        if os.path.lexists(root / 'etc/pam.d' / ('common-' + name)):
            raise ValueError('pristine PAM package initialization only; no overwrite')
    state = root / 'var/lib/pam'
    if os.path.lexists(state) and (not state.is_dir() or state.is_symlink() or any(state.iterdir())):
        raise ValueError('pristine PAM state required')


def prepare_guest_os(trace, inputs):
    """Complete vendor first-install setup in this new rootfs, never on the host."""
    require_pristine_pam()
    for name in ('libpam-runtime.postinst', 'libpam-runtime.templates'):
        path = Path('/var/lib/dpkg/info') / name
        if kit.sha(vm.descriptor_bytes(path, 1024 * 1024)) != inputs['pam_control_sha256'][name]:
            raise ValueError('exact signed PAM package control input required')
    for argv in (['ldconfig'], ['systemd-sysusers'], ['depmod', '-a']):
        trace.command(argv, timeout=90)
    # The exact signed vendor script selects its own FIRST-INSTALL branch after
    # our stronger empty-root check. Never force-replace a retained PAM policy.
    trace.command(['/bin/sh', '/var/lib/dpkg/info/libpam-runtime.postinst', 'configure'], timeout=60)
    pam = {name: vm.descriptor_bytes(Path('/etc/pam.d') / ('common-' + name), 16384)
           for name in PAM_TYPES}
    if any(b'pam_unix.so' not in data or b'pam_deny.so' not in data for data in pam.values()):
        raise ValueError('complete standard Unix PAM stack required')
    trace.measure('generated_vendor_pam_sha256', {name: kit.sha(data) for name, data in pam.items()})


def create_guest_links(trace):
    trace.command(['ip', 'link', 'add', 'vr-relay', 'type', 'veth', 'peer', 'name', 'vr-client'])
    before = kit.decode_json(trace.command(['ip', '-j', 'address', 'show']))
    if ({link['ifname'] for link in before} != {'lo', 'vr-relay', 'vr-client'}
            or any(link.get('addr_info') for link in before if link['ifname'] != 'lo')):
        raise ValueError('exact pre-assignment veth inventory required')
    trace.measure('pre_assignment_interfaces', before)
    trace.check('pre_assignment_link_inventory', True)
    for argv in (['ip', 'netns', 'add', vm.CLIENT_NS],
                 ['ip', 'link', 'set', 'vr-client', 'netns', vm.CLIENT_NS],
                 ['ip', 'address', 'add', kit.PUBLIC_IP + '/32', 'dev', 'vr-relay'],
                 ['ip', '-n', vm.CLIENT_NS, 'address', 'add', vm.CLIENT_IP + '/32', 'dev', 'vr-client'],
                 ['ip', 'link', 'set', 'vr-relay', 'up'],
                 ['ip', '-n', vm.CLIENT_NS, 'link', 'set', 'lo', 'up'],
                 ['ip', '-n', vm.CLIENT_NS, 'link', 'set', 'vr-client', 'up'],
                 ['ip', 'route', 'add', vm.CLIENT_IP + '/32', 'dev', 'vr-relay'],
                 ['ip', '-n', vm.CLIENT_NS, 'route', 'add', kit.PUBLIC_IP + '/32', 'dev', 'vr-client']):
        trace.command(argv)


def bootstrap(inputs, trace):
    trace.begin('fixture-isolation')
    first = initial_observation(trace.command)
    trace.measure('initial_kernel_observation', first)
    trace.check('initial_lo_only_no_routes', True)
    prepare_guest_os(trace, inputs)
    create_guest_links(trace)
    observed = vm.observe_guest(kit)
    vm.validate_guest_observation(observed)
    manifest = kit.verify_kit(KIT_ROOT)
    record = {'v': 1, 'profile': vm.PROFILE, 'boot_id': observed['boot_id'],
              'kit_sha256': kit.sha(kit.read_file(KIT_ROOT / 'manifest.json', owner=0)),
              'controller_sha256': manifest['sha256']['single_host.py'],
              'driver_sha256': manifest['sha256']['single_host_vm_runner.py'],
              'isolation_sha256': kit.sha(kit.canonical(vm.normalized_observation(observed)))}
    kit.atomic_write(vm.BOUNDARY, kit.canonical(record), 0o400, exclusive=True)
    trace.measure('current_boot_boundary', record)
    # Prerequisite only, identical tuple to production's existing messaging rule.
    trace.command(['ufw', 'allow', 'in', 'on', 'vr-relay', 'proto', 'tcp', 'from', 'any',
                   'to', kit.PUBLIC_IP, 'port', '38443', 'comment', 'owned-voice-fixture-message'])
    trace.command(['ufw', '--force', 'enable'])
    loopback = {}
    for executable in ('iptables-save', 'ip6tables-save'):
        lines = trace.command([executable]).decode().splitlines()
        for chain, interface in (('ufw-before-input', '-i'), ('ufw-before-output', '-o')):
            first_rule = next((line for line in lines if line.startswith('-A ' + chain + ' ')), None)
            loopback[executable + ':' + chain] = first_rule
            if first_rule != '-A ' + chain + ' ' + interface + ' lo -j ACCEPT':
                raise ValueError('first UFW loopback accept required')
    trace.measure('effective_ufw_loopback_first', loopback)
    trace.check('ufw_loopback_accept_first', True)
    return record


def message_worker(operation, request):
    """Fixed guest-only helper, executed as the actual messaging UID/GID."""
    if (os.getresuid() != (1003, 1003, 1003) or os.getresgid() != (1004, 1004, 1004)
            or vm.descriptor_bytes('/sys/class/dmi/id/product_name', 256).decode().strip() != vm.DMI_PRODUCT
            or Path(__file__).resolve() != KIT_ROOT / 'single_host_vm_runner.py'):
        raise ValueError('exact owned guest message worker required')
    kit.verify_root_kit(KIT_ROOT)
    if kit.verify_kit(KIT_ROOT)['profile'] != vm.PROFILE:
        raise ValueError('guest fixture kit required')
    alpha = message.load_alpha(KIT_ROOT / 'message')
    if operation == 'bootstrap-old':
        if request or os.path.lexists(MESSAGE_ROOT):
            raise ValueError('new synthetic baseline only; never adopt or reset')
        kit.verify_root_kit(OLD_RELEASE)
        old = message.load_alpha(OLD_RELEASE)
        message.install_fresh_guarded(old, MESSAGE_ROOT, kit.PUBLIC_IP, OLD_RELEASE, 'paranoid-alpha.service')
        return {'identity': message.identity(old, MESSAGE_ROOT, 'paranoid-alpha.service')}
    if operation == 'identity':
        if request:
            raise ValueError('no identity query payload')
        return {'identity': message.identity(alpha, MESSAGE_ROOT, 'paranoid-alpha.service')}
    if operation == 'history':
        if (not isinstance(request, dict) or set(request) != {'through_sequence'}
                or type(request['through_sequence']) is not int or not 0 <= request['through_sequence'] <= 10000):
            raise ValueError('bounded synthetic history observation required')
        last = int(alpha.sql(MESSAGE_ROOT, 'SELECT sequence FROM ss_meta').strip())
        through = request['through_sequence'] or last
        raw = alpha.sql(MESSAGE_ROOT, 'SELECT row_to_json(t) FROM (SELECT * FROM ss_messages '
                        'WHERE sequence <= ' + str(through) + ' ORDER BY sequence) t')
        if len(raw) > MAX_OUTPUT:
            raise ValueError('synthetic retained-history observation bound')
        return {'through_sequence': through, 'current_sequence': last,
                'count': len(raw.splitlines()), 'sha256': kit.sha(raw)}
    if operation == 'public-connection':
        if request:
            raise ValueError('no public connection query payload')
        realm, pin = alpha.public_realm(MESSAGE_ROOT)
        return {'realm': realm, 'pin': pin}
    raise ValueError('unknown message fixture operation')


def as_message(trace, operation, request=None):
    argv = ['runuser', '--user', 'paranoid', '--', 'env', '-i',
            'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'LANG=C', 'HOME=/home/paranoid',
            'USER=paranoid', 'LOGNAME=paranoid', 'XDG_RUNTIME_DIR=/run/user/1003',
            '/usr/bin/python3', '-I', '-B', str(KIT_ROOT / 'single_host_vm_runner.py'),
            '--message-worker', operation]
    return kit.decode_json(trace.command(argv, kit.canonical({} if request is None else request), timeout=300))


class JvmPair:
    """Real current JNI/Olm/TLS clients; private IPC and sealed guest snapshots."""
    def __init__(self, trace, connection):
        self.trace = trace
        self.connection = connection
        self.processes = {}
        self.records = {}
        self.stderr = {}
        self.buffers = {}
        self.views = {}

    def start(self, fresh):
        if (self.connection['realm'] != 'https://' + kit.PUBLIC_IP + ':38443'
                or not kit.is_hash(self.connection['pin'])):
            raise ValueError('exact verified guest TLS connection required')
        root = Path('/var/lib/paranoid-voice-fixture-clients')
        if not root.exists():
            root.mkdir(mode=0o700)
            os.chown(root, 1903, 1903)
        elif root.is_symlink() or root.stat().st_uid != 1903 or root.stat().st_mode & 0o077:
            raise ValueError('private owned synthetic client state required')
        for name in ('one', 'two'):
            path = root / name
            if fresh and path.exists():
                raise ValueError('fresh client cannot reset prior state')
            if not fresh and not (path / 'fixture.enc').is_file():
                raise ValueError('retained sealed client snapshot required')
            argv = ['ip', 'netns', 'exec', vm.CLIENT_NS, 'setpriv', '--reuid', '1903',
                    '--regid', '1903', '--clear-groups', 'java',
                    '-Djava.library.path=/opt/voice-fixture/jni', '-cp',
                    '/opt/voice-fixture/voice-jvm:/opt/voice-fixture/json.jar:/opt/voice-fixture/zxing.jar',
                    'VoicePeerBridge', str(path), self.connection['realm'], self.connection['pin']]
            record = {'argv': argv, 'exit_code': None, 'expected_exit_code': 0,
                      'output': '', 'output_sha256': kit.sha(b'')}
            self.trace.case['commands'].append(record)
            self.records[name] = record
            log = self.trace.root / (self.trace.active + '-jvm-' + str(len(self.trace.case['commands'])) + '-' + name + '.stderr')
            stream = log.open('xb')
            self.stderr[name] = (stream, log)
            self.processes[name] = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=stream, env={**ENV, 'HOME': str(root)}, bufsize=0)
            self.buffers[name] = b''
            self.rpc(name, {'operation': 'create' if fresh else 'resume'})
        self.await_views(lambda views: all(v.get('active') is True and v.get('connected') is True
                                          for v in views.values()), 30)
        if fresh:
            self.rpc('one', {'operation': 'pair', 'contact': json.dumps(self.views['two']['contact'])})
            self.rpc('two', {'operation': 'pair', 'contact': json.dumps(self.views['one']['contact'])})
        return self

    def rpc(self, name, request):
        encoded = kit.canonical(request)
        if len(encoded) > 65536:
            raise ValueError('private client IPC bound')
        process = self.processes[name]
        if process.poll() is not None:
            raise RuntimeError('owned JNI client exited')
        process.stdin.write(encoded)
        process.stdin.flush()
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while b'\n' not in self.buffers[name]:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError('owned private JNI response deadline')
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('owned JNI response ended')
                self.buffers[name] += chunk
                if len(self.buffers[name]) > MAX_OUTPUT:
                    raise ValueError('private JNI response bound')
        line, self.buffers[name] = self.buffers[name].split(b'\n', 1)
        value = kit.decode_json(line)
        if 'error' in value:
            raise RuntimeError('actual JNI operation failed')
        self.views[name] = value
        return value

    def await_views(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for name in ('one', 'two'):
                self.rpc(name, {'operation': 'view'})
            if predicate(self.views):
                return
            time.sleep(0.2)
        raise TimeoutError('actual JNI registration/text observation deadline')

    @staticmethod
    def texts(view):
        return [m.get('text') for d in view.get('dialogs', []) for m in d.get('messages', [])]

    def exchange(self, marker):
        if marker not in ('before-update', 'after-update', 'after-rollback', 'fresh-message'):
            raise ValueError('fixed synthetic text marker required')
        for name, other in (('one', 'two'), ('two', 'one')):
            text = 'owned-voice-fixture-' + marker + '-' + name
            self.rpc(name, {'operation': 'text', 'account': self.views[other]['account'], 'text': text})
        expected = {'owned-voice-fixture-' + marker + '-' + name for name in ('one', 'two')}
        self.await_views(lambda views: all(expected <= set(self.texts(v)) for v in views.values()), 20)
        self.trace.measure('actual_decrypted_' + marker,
            {'both_clients': True, 'texts_sha256': kit.sha(kit.canonical(sorted(expected))),
             'native_engine': 'current JNI/Olm', 'transport': 'pinned TLS38443'})

    def require_retained(self, markers):
        expected = {'owned-voice-fixture-' + marker + '-' + name
                    for marker in markers for name in ('one', 'two')}
        self.await_views(lambda views: all(expected <= set(self.texts(v)) for v in views.values()), 20)
        return {'both_sealed_clients_reopened': True, 'text_count': len(expected),
                'texts_sha256': kit.sha(kit.canonical(sorted(expected)))}

    def close(self):
        failure = None
        for name, process in self.processes.items():
            try:
                if process.poll() is None:
                    process.stdin.close()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                        failure = RuntimeError('JNI fixture did not close normally')
                self.records[name]['exit_code'] = process.returncode
                if process.returncode != 0:
                    failure = RuntimeError('JNI fixture exit failed')
            finally:
                process.stdout.close()
                stream, path = self.stderr[name]
                stream.close()
                with path.open('rb') as incoming:
                    raw = incoming.read(MAX_OUTPUT + 1)
                if len(raw) > MAX_OUTPUT:
                    raise ValueError('owned JVM diagnostic output bound')
                self.records[name]['output'] = raw.decode(errors='strict')
                self.records[name]['output_sha256'] = kit.sha(raw)
                self.trace.save()
        if failure:
            raise failure


def stable_identity(before, after):
    fields = ('pg_system_id', 'tls_cert_sha256', 'tls_key_sha256', 'tls_spki')
    return all(key in before and key in after and before[key] == after[key] for key in fields)


def retained_history(before, after):
    return (before['through_sequence'] == after['through_sequence']
            and before['count'] == after['count'] and before['count'] > 0
            and before['sha256'] == after['sha256']
            and after['current_sequence'] >= before['current_sequence'])


def recovery_data_observed(before, admitted, restored, views):
    return (admitted['current_sequence'] > before['current_sequence']
            and admitted['count'] > before['count']
            and retained_history(admitted, restored) and set(views) == {'one', 'two'}
            and all(v.get('active') is True and v.get('connected') is True for v in views.values()))


def bind_guest_plan(context):
    """Bind this boot's newly observed synthetic baseline, never production keys."""
    intent = context['intent']
    planned = kit.plan(intent, KIT_ROOT)
    context['plan'] = planned
    trace = context['trace']
    bindings = {'fixture_plan_sha256': planned['plan_sha256']}
    trace.bindings.update(bindings)
    for case in trace.cases.values():
        case.update(bindings)
    kit.atomic_write(trace.root / 'fixture-intent.json', kit.canonical(intent), exclusive=True)
    kit.atomic_write(trace.root / 'fixture-plan.json', kit.canonical(planned), exclusive=True)


def acceptance_for_boot(context):
    """Consume external actual prerequisites; cannot author review/test success."""
    inputs, trace = context['inputs'], context['trace']
    raw = vm.descriptor_bytes(FIXTURE_ROOT / 'prerequisites.json', 2 * 1024 * 1024, mode=0o400)
    if kit.sha(raw) != inputs['prerequisites_sha256']:
        raise ValueError('frozen external prerequisite report required')
    proof = kit.decode_json(raw)
    if (set(proof) != {'v', 'scope', 'fixture_kit_sha256', 'driver_sha256', 'gates'}
            or proof['v'] != 1 or proof['scope'] != 'exact-full-vm-source-artifact-prerequisites'
            or proof['fixture_kit_sha256'] != context['intent']['kit_sha256']
            or proof['driver_sha256'] != trace.bindings['driver_sha256']
            or set(proof['gates']) != {'design-review', 'offline-tests', 'artifact-verification'}):
        raise ValueError('exact external reviewed fixture prerequisites required')
    for name, entry in proof['gates'].items():
        if (set(entry) != {'result', 'evidence_sha256', 'evidence_path'}
                or entry['result'] != 'PASS' or not kit.is_hash(entry['evidence_sha256'])
                or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,80}\.json', entry['evidence_path'])):
            raise ValueError('actual externally verified prerequisite file required')
        actual = vm.descriptor_bytes(FIXTURE_ROOT / 'prerequisites' / entry['evidence_path'], 2 * 1024 * 1024)
        if kit.sha(actual) != entry['evidence_sha256']:
            raise ValueError('prerequisite evidence bytes changed')
        value = kit.decode_json(actual)
        if name == 'offline-tests':
            if (value.get('kind') != 'single-host-offline-test-report' or value.get('result') != 'PASS'
                    or type(value.get('exit_code')) is not int or value['exit_code'] != 0
                    or type(value.get('test_count')) is not int or value['test_count'] < 80
                    or not isinstance(value.get('source_sha256'), dict)):
                raise ValueError('actual full offline test report required')
            manifest = kit.verify_kit(KIT_ROOT)
            for source in ('single_host.py', 'single_host_message.py', 'single_host_network.py',
                           'single_host_vm.py', 'single_host_vm_runner.py'):
                if value['source_sha256'].get(source) != manifest['sha256'][source]:
                    raise ValueError('offline-tested runtime source differs')
            if value['source_sha256'].get('single_host_vm_packets.py') != manifest['sha256']['single_host_vm_packets.py']:
                raise ValueError('offline-tested packet source differs')
            log = vm.descriptor_bytes(FIXTURE_ROOT / 'prerequisites/offline-tests.log', MAX_OUTPUT)
            matches = re.findall(rb'\nRan ([1-9][0-9]*) tests? in [0-9.]+s\n\nOK\n\Z', log)
            if (kit.sha(log) != value.get('log_sha256') or len(matches) != 1
                    or int(matches[0]) != value['test_count'] or b'FAILED' in log or b'ERROR' in log):
                raise ValueError('actual successful offline output required')
        elif name == 'design-review':
            if (value.get('kind') != 'independent-full-vm-review' or value.get('disposition') != 'APPROVED'
                    or value.get('fixture_kit_sha256') != proof['fixture_kit_sha256']
                    or value.get('driver_sha256') != proof['driver_sha256']
                    or not isinstance(value.get('actual_model'), str)):
                raise ValueError('actual independent exact source/artifact approval required')
            result = vm.descriptor_bytes(FIXTURE_ROOT / 'prerequisites/independent-review-result.json', 2 * 1024 * 1024)
            review = kit.decode_json(result)
            if (kit.sha(result) != value.get('review_result_sha256') or review.get('is_error') is not False
                    or review.get('subtype') != 'success' or review.get('permission_denials')
                    or value['actual_model'] not in review.get('modelUsage', {})):
                raise ValueError('independent review provenance differs')
        elif (value.get('result') != 'EXACT_FIXTURE_ARTIFACT_VERIFIED'
                or value.get('fixture_kit_sha256') != proof['fixture_kit_sha256']
                or value.get('production_kit_sha256') != trace.bindings['production_kit_sha256']):
            raise ValueError('actual exact artifact verification required')
    isolation = vm.boundary(kit, context['intent'], KIT_ROOT)
    receipt = {'v': 1, 'profile': vm.PROFILE, 'kit_sha256': context['intent']['kit_sha256'],
               'plan_sha256': context['plan']['plan_sha256'],
               'gates': {name: {'result': entry['result'], 'evidence_sha256': entry['evidence_sha256']}
                         for name, entry in proof['gates'].items()}}
    receipt['gates']['current-boot-isolation'] = {'result': 'PASS',
        'boot_id': isolation['boot_id'], 'evidence_sha256': isolation['isolation_sha256']}
    kit.atomic_write(trace.root / 'fixture-prerequisites.json', kit.canonical(receipt), 0o400, exclusive=True)
    return receipt


def coordinated_apply(context):
    trace = context['trace']
    argv = ['/usr/bin/python3', '-I', '-B', str(KIT_ROOT / 'single_host.py'), 'apply',
            '--config', str(trace.root / 'fixture-intent.json'), '--kit', str(KIT_ROOT),
            '--acceptance', str(trace.root / 'fixture-prerequisites.json'),
            '--expect-plan', context['plan']['plan_sha256']]
    return kit.decode_json(trace.command(argv, timeout=600))


def prepare_baseline(context):
    trace = context['trace']
    role = context['inputs']['role']
    trace.begin('fresh' if role == 'fresh' else 'failure-recovery' if role == 'failure' else 'existing-v8')
    trace.measure('private_jvm_io_scope', 'stdin/stdout are private IPC; command output records stderr only')
    if role != 'fresh':
        kit.create_account(context['intent']['message'], message=True)
        prior = as_message(trace, 'bootstrap-old')['identity']
        context['prior_identity'] = prior
        context['intent']['expected'] = prior
        pair = JvmPair(trace, as_message(trace, 'public-connection'))
        try:
            pair.start(fresh=True)
            pair.exchange('before-update')
        finally:
            pair.close()
        context['before_history'] = as_message(trace, 'history', {'through_sequence': 0})
        trace.measure('actual_old_v8_identity', prior)
        trace.measure('actual_old_v8_ciphertext_history', context['before_history'])
    bind_guest_plan(context)
    context['acceptance'] = acceptance_for_boot(context)


def install_case(context):
    trace = context['trace']
    outcome = coordinated_apply(context)
    context['active'] = outcome
    trace.measure('actual_apply_readback', outcome)
    trace.check('active', outcome.get('phase') == 'active' and outcome.get('verified') is True)
    pair = JvmPair(trace, as_message(trace, 'public-connection'))
    try:
        fresh = context['intent']['mode'] == 'fresh'
        pair.start(fresh=fresh)
        if fresh:
            pair.exchange('fresh-message')
            trace.check('registration_text', all(v.get('active') is True for v in pair.views.values()))
        else:
            trace.measure('reopened_prior_e2ee_history', pair.require_retained(['before-update']))
            after = as_message(trace, 'history', {'through_sequence': context['before_history']['through_sequence']})
            trace.measure('retained_ciphertext_after_apply', after)
            trace.check('retained_history_preserved', retained_history(context['before_history'], after))
            trace.check('identity_preserved', stable_identity(context['prior_identity'], outcome['identity']))
            pair.exchange('after-update')
            context['after_history'] = as_message(trace, 'history', {'through_sequence': 0})
            trace.measure('new_ciphertext_after_apply', context['after_history'])
            trace.check('new_text_preserved', context['after_history']['current_sequence'] > context['before_history']['current_sequence'])
    finally:
        pair.close()
    if context['intent']['mode'] == 'fresh':
        relay = outcome.get('relay_runtime', {})
        expected = kit.verify_component(KIT_ROOT / 'relay')['sha256']['bin/turnserver']
        trace.check('relay_active', type(relay.get('main_pid')) is int and relay['main_pid'] > 0
                    and relay.get('executable_sha256') == expected)
        config = kit.decode_json(kit.read_file(MESSAGE_ROOT / 'config.json', owner=1003, private=True))
        trace.check('issuer_enabled', config.get('voice_turn') == {'v': 1, 'relay_ip': kit.PUBLIC_IP})
    trace.finish()


def idempotence_case(context):
    trace = context['trace']
    trace.begin('idempotence')
    network = kit.network_module(KIT_ROOT)
    before = network.normalize_nft_json(trace.command(['nft', '--json', '--numeric', 'list', 'table', 'inet', network.TABLE]))
    transactions = sorted(p.name for p in (kit.STATE / 'transactions').iterdir())
    state_sha = kit.sha(vm.descriptor_bytes(kit.STATE / 'current.json', 256 * 1024))
    outcome = coordinated_apply(context)
    after = network.normalize_nft_json(trace.command(['nft', '--json', '--numeric', 'list', 'table', 'inet', network.TABLE]))
    trace.measure('actual_repeat_apply', outcome)
    trace.measure('before_transaction_names', transactions)
    trace.check('no_new_transaction', outcome.get('phase') == 'already-applied'
        and sorted(p.name for p in (kit.STATE / 'transactions').iterdir()) == transactions
        and kit.sha(vm.descriptor_bytes(kit.STATE / 'current.json', 256 * 1024)) == state_sha)
    trace.check('identity_preserved', outcome.get('identity') == context['active']['identity'])
    trace.check('rules_unchanged', before == after)
    trace.finish()


def rollback_case(context):
    trace = context['trace']
    trace.begin('rollback')
    status = kit.decode_json(trace.command(['/usr/bin/python3', '-I', '-B', str(KIT_ROOT / 'single_host.py'),
                                           'status', '--state', str(kit.STATE)]))
    result = kit.decode_json(trace.command(['/usr/bin/python3', '-I', '-B', str(KIT_ROOT / 'single_host.py'),
        'rollback', '--state', str(kit.STATE), '--transaction', status['transaction'],
        '--expect-state', status['state_sha256']], timeout=600))
    restored = as_message(trace, 'identity')['identity']
    history = as_message(trace, 'history', {'through_sequence': context['after_history']['through_sequence']})
    trace.measure('actual_coordinated_rollback', result)
    trace.measure('restored_identity', restored)
    trace.measure('retained_ciphertext_history', history)
    trace.check('previous_code_config_units_restored', restored == context['prior_identity'])
    trace.check('current_data_preserved', retained_history(context['after_history'], history))
    network = kit.network_module(KIT_ROOT)
    observed = network.observe(kit.network_spec(context['intent']))
    trace.measure('post_rollback_network', observed)
    desired = network.desired_ufw_rules(kit.network_spec(context['intent']))
    trace.check('relay_ingress_closed', not any(rule['comment'] in {r['comment'] for r in desired}
                                               for rule in observed['ufw']))
    pair = JvmPair(trace, as_message(trace, 'public-connection'))
    try:
        pair.start(fresh=False)
        trace.measure('actual_reopened_e2ee_after_rollback', pair.require_retained(['before-update', 'after-update']))
        pair.exchange('after-rollback')
    finally:
        pair.close()
    trace.finish()


def failure_case(context):
    """One explicit in-process fault after actual relay startup, before ingress."""
    trace = context['trace']
    original = kit.coordinated_network
    injected = []
    def fail_owned_ingress(state, value, operation):
        if operation == 'open-ingress' and not injected:
            injected.append({'phase': operation, 'relay': kit.wait_relay_active(value)})
            pair = JvmPair(trace, as_message(trace, 'public-connection'))
            try:
                pair.start(fresh=False)
                trace.measure('actual_history_before_injected_fault', pair.require_retained(['before-update']))
                pair.exchange('after-update')
            finally:
                pair.close()
            context['admitted_history'] = as_message(trace, 'history', {'through_sequence': 0})
            trace.measure('actual_post_cutover_ciphertext', context['admitted_history'])
            raise RuntimeError('owned fixture one-shot ingress operation fault')
        return original(state, value, operation)
    kit.coordinated_network = fail_owned_ingress
    failed = False
    try:
        kit.apply(context['intent'], KIT_ROOT, context['acceptance'], context['plan']['plan_sha256'])
    except RuntimeError as error:
        if str(error) != 'coordinated operation failed; recorded rollback completed':
            raise
        failed = True
    finally:
        kit.coordinated_network = original
    restored = as_message(trace, 'identity')['identity']
    if not failed or 'admitted_history' not in context:
        raise ValueError('the reviewed fault requires actual post-cutover accepted messages')
    history = as_message(trace, 'history', {'through_sequence': context['admitted_history']['through_sequence']})
    trace.measure('actual_injected_stage', injected)
    trace.measure('fault_mechanism', 'one fixture-owned in-process exception; shipped coordinator unchanged')
    trace.measure('actual_restored_identity', restored)
    trace.measure('actual_current_history', history)
    trace.check('failure_observed', failed and len(injected) == 1)
    pair = JvmPair(trace, as_message(trace, 'public-connection'))
    try:
        pair.start(fresh=False)
        trace.measure('reopened_e2ee_after_recovery', pair.require_retained(['before-update', 'after-update']))
        pair.exchange('after-rollback')
        trace.check('prior_runtime_restored', restored == context['prior_identity']
            and all(v.get('active') is True and v.get('connected') is True for v in pair.views.values()))
        trace.check('current_data_preserved', recovery_data_observed(context['before_history'],
            context['admitted_history'], history, pair.views))
    finally:
        pair.close()
    trace.finish()


def packet_argv(location='client', uid=1903):
    if location not in ('root', 'client') or uid not in (1902, 1903):
        raise ValueError('fixed owned packet identity required')
    return (['ip', 'netns', 'exec', vm.CLIENT_NS] if location == 'client' else []) + [
        'setpriv', '--reuid', str(uid), '--regid', str(uid), '--clear-groups',
        '/usr/bin/python3', '-I', '-B', str(KIT_ROOT / 'single_host_vm_packets.py')]


def packet_command(context, request, location='client', uid=1903, timeout=115):
    packets.validate_request(request)
    if request.get('target') == 'bogon':
        if 'bogon_baseline' not in context:
            raise ValueError('owned bogon subcase not established')
        current = vm.normalized_observation(vm.observe_guest(kit))
        validate_bogon_observation(context['bogon_baseline'], current)
    else:
        vm.boundary(kit, context['intent'], KIT_ROOT)
    result = kit.decode_json(context['trace'].command(packet_argv(location, uid),
        kit.canonical(request), timeout=timeout))
    if not isinstance(result, dict) or 'error_class' in result:
        raise ValueError('actual owned packet operation failed')
    return result


def validate_bogon_observation(baseline, current):
    # Remove only the separately specified, actually present owned alias routes
    # from a copy, then require byte-identical prior topology. The coordinator's
    # own boundary file/validator is never rewritten or bypassed by this helper.
    adjusted = kit.decode_json(kit.canonical(current))
    removed = {}
    for namespace in ('relay', vm.CLIENT_NS):
        routes = adjusted['routes'][namespace]['-4']
        added = [r for r in routes if r['dst'] in (packets.BOGON, packets.BOGON + '/32')]
        required = {'type': 'unicast' if namespace == 'relay' else 'local',
                    'dev': 'vr-relay' if namespace == 'relay' else 'lo', 'gateway': None}
        if len(added) != 1 or any(added[0].get(k) != v for k, v in required.items()):
            raise ValueError('exact single owned bogon route per namespace required')
        adjusted['routes'][namespace]['-4'] = [r for r in routes if r not in added]
        removed[namespace] = added
    if adjusted != baseline:
        raise ValueError('unrelated guest topology drift during owned bogon subcase')
    return removed


def synthetic_credential(label, seconds):
    if label not in ('baseline', 'expiry', 'control', 'owned-peer') or seconds not in (8, 180):
        raise ValueError('fixed bounded own-guest temporary credential required')
    secret = kit.read_file('/etc/paranoid-turn/relay.secret', 64, owner=0, private=True)
    if not re.fullmatch(b'[0-9a-f]{64}', secret):
        raise ValueError('owned synthetic master format differs')
    expires = int(time.time()) + seconds
    username = str(expires) + ':voice-fixture:' + label
    return {'username': username, 'password': base64.b64encode(hmac.new(secret,
        username.encode(), hashlib.sha1).digest()).decode(), 'expires': expires}


def issuer_case(context):
    trace = context['trace']
    trace.begin('issuer-interoperability')
    pair = JvmPair(trace, as_message(trace, 'public-connection'))
    try:
        pair.start(fresh=False)
        response = pair.rpc('one', {'operation': 'start', 'account': pair.views['two']['account']})
        deadline, issued = time.monotonic() + 10, None
        while time.monotonic() < deadline:
            for command in response.get('media_commands', []):
                if command.get('operation') == 'offer' and 'relay' in command:
                    issued = command['relay']
            if issued is not None:
                break
            time.sleep(0.1)
            response = pair.rpc('one', {'operation': 'view'})
        urls = ['turn:' + kit.PUBLIC_IP + ':34781?transport=' + proto for proto in ('udp', 'tcp')]
        if (not isinstance(issued, dict) or set(issued) != {'urls', 'username', 'credential'}
                or issued['urls'] != urls or not re.match(r'^[0-9]{10}:', issued['username'])):
            raise ValueError('actual current-client authenticated issuer response required')
        credential = {'username': issued['username'], 'password': issued['credential'],
                      'expires': int(issued['username'].split(':', 1)[0])}
        remaining = credential['expires'] - int(time.time())
        if not 1180 <= remaining <= 1200:
            raise ValueError('actual issuer TTL differs')
        pair.rpc('one', {'operation': 'hangup'})
        trace.measure('actual_issuer_provenance', {'route': 'current JNI authenticated requestVoiceRelay',
            'configured_urls': urls, 'remaining_seconds': remaining,
            'raw_credentials_or_sdp_saved': False})
        trace.check('issuer_credentials_used', True)
        for transport in ('udp', 'tcp'):
            result = packet_command(context, {'mode': 'media', 'transport': transport, 'credential': credential}, timeout=50)
            trace.measure('actual_' + transport + '_decoded_media', result)
            trace.check(transport + '_relay_media', packets.media_observed(result))
            context[transport + '_media'] = result
    finally:
        pair.close()
    trace.finish()


def relay_cli_case(context):
    trace = context['trace']
    trace.begin('relay-cli')
    sockets = trace.command(['ss', '-H', '-lntup']).decode()
    trace.measure('actual_listener_inventory_sha256', kit.sha(sockets.encode()))
    for location in ('root', 'client'):
        result = packet_command(context, {'mode': 'cli', 'location': location}, location=location)
        trace.measure('actual_' + location + '_5766', result)
        trace.check(('local' if location == 'root' else 'client') + '5766closed',
            result['connected'] is False and result['connect_errno'] in (111, 110, 113)
            and not re.search(r':5766\s', sockets))
    state = kit.state_record(kit.STATE)
    kit.verify_system_artifacts(state)
    config = kit.read_file('/run/paranoid-turn/turnserver.conf', owner=1902, private=True)
    trace.check('console_disabled', config.splitlines().count(b'cli=0') == 1
                and not any(line.startswith(b'cli=') and line != b'cli=0' for line in config.splitlines()))
    trace.measure('actual_private_config_sha256', kit.sha(config))
    trace.finish()


class OwnedOutputChild:
    """Own one finite helper, retaining its actual bounded output and exit."""
    def __init__(self, trace, argv, request=None, env=None):
        self.trace, self.argv, self.buffer, self.lines = trace, list(map(str, argv)), b'', []
        self.record = {'argv': self.argv, 'exit_code': None, 'expected_exit_code': 0,
                       'output': '', 'output_sha256': kit.sha(b'')}
        trace.case['commands'].append(self.record)
        trace.save()
        self.process = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=ENV if env is None else env, bufsize=0)
        if request is not None:
            self.process.stdin.write(kit.canonical(request))
            self.process.stdin.flush()
        self.process.stdin.close()

    def line(self, timeout):
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b'\n' not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError('owned helper observation deadline')
                raw = os.read(self.process.stdout.fileno(), 65536)
                if not raw:
                    raise RuntimeError('owned helper output ended early')
                self.buffer += raw
                if sum(map(len, self.lines)) + len(self.buffer) > MAX_OUTPUT:
                    raise ValueError('owned helper output bound')
        line, self.buffer = self.buffer.split(b'\n', 1)
        self.lines.append(line + b'\n')
        return kit.decode_json(line)

    def close(self, planned_stop=False):
        forced = False
        if planned_stop and self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forced = True
            self.process.kill()
            self.process.wait(timeout=5)
        raw = b''.join(self.lines) + self.buffer + self.process.stdout.read(MAX_OUTPUT + 1)
        self.process.stdout.close()
        self.record['exit_code'] = self.process.returncode
        if len(raw) > MAX_OUTPUT:
            self.trace.failed('owned_helper_output_bound')
            raise ValueError('owned helper output bound')
        self.record['output'], self.record['output_sha256'] = raw.decode(errors='strict'), kit.sha(raw)
        self.trace.save()
        if forced or self.process.returncode != 0:
            self.trace.failed('owned_helper_exit')
            raise RuntimeError('owned helper failed or did not exit normally')


def denial_case(context, target, real_relay=False):
    trace = context['trace']
    request = {'mode': 'sink', 'target': target, 'marker': 'owned-' + uuid.uuid4().hex}
    location = 'root' if target in ('local', 'ipv6') else 'client'
    sink = OwnedOutputChild(trace, packet_argv(location), request)
    final = None
    try:
        if sink.line(3) != {'ready': True, 'target': target}:
            raise ValueError('exact own dummy readiness required')
        positive = packet_command(context, {**request, 'mode': 'udp-send'}, location='root')
        if sink.line(2) != {'positive_received': 1, 'target': target}:
            raise ValueError('identical destination positive packet must arrive before denial')
        if real_relay:
            negative = packet_command(context, {'mode': 'peer-denial', 'credential': synthetic_credential('owned-peer', 180),
                'marker': request['marker']}, timeout=15)
        else:
            negative = packet_command(context, {**request, 'mode': 'udp-send'}, location='root', uid=1902)
        final = sink.line(6)
    finally:
        sink.close()
    result = {'positive_received': final['counts']['positive'], 'negative_received': final['counts']['negative'],
              'positive_attempted': positive['attempted'], 'negative_attempted': negative['attempted'],
              'window_seconds': final['window_seconds'], 'same_target': positive['target'] == negative['target'] == target,
              'positive_uid': positive['uid'], 'negative_uid': 1902 if real_relay else negative['uid'],
              'sink_exit': sink.process.returncode, 'target': target, 'via_real_relay': real_relay,
              'unexpected_received': final['counts']['other']}
    if not packets.denial_observed(result) or result['unexpected_received'] != 0:
        trace.measure('failed_denial_' + target, result)
        raise ValueError('actual same-target positive/negative observations did not establish denial')
    return result


def acl_case(context):
    trace = context['trace']
    trace.begin('turn-acl02')
    state = kit.state_record(kit.STATE)
    relay = kit.wait_relay_active(state)
    pid = relay['main_pid']
    namespace = os.stat('/proc/' + str(pid) + '/ns/net').st_ino
    own_namespace = os.stat('/proc/self/ns/net').st_ino
    network = kit.network_module(KIT_ROOT)
    actual = network.normalize_nft_json(trace.command(['nft', '--json', '--numeric', 'list', 'table', 'inet', network.TABLE]))
    trace.measure('effective_policy', actual)
    trace.measure('namespace_inodes', {'turn_main_pid': pid, 'turn_net': namespace, 'nft_net': own_namespace})
    trace.check('namespace_match', namespace == own_namespace)
    trace.check('effective_rules_exact', actual == network._objects(kit.network_spec(context['intent'])))
    results = {}
    for target in ('local', 'ipv6', 'other'):
        results[target] = denial_case(context, target)
    results['real-relay-local'] = denial_case(context, 'local', real_relay=True)
    # The bogon destination is NONLOCAL at the relay. An exact owned client /32
    # and host route temporarily isolate the bogon rule from deny-local. No
    # default route, host interface or third-party endpoint is involved.
    vm.boundary(kit, context['intent'], KIT_ROOT)
    context['bogon_baseline'] = vm.normalized_observation(vm.observe_guest(kit))
    trace.command(['ip', '-n', vm.CLIENT_NS, 'address', 'add', packets.BOGON + '/32', 'dev', 'lo'])
    route_added = False
    try:
        trace.command(['ip', 'route', 'add', packets.BOGON + '/32', 'dev', 'vr-relay'])
        route_added = True
        route = kit.decode_json(trace.command(['ip', '-j', 'route', 'get', packets.BOGON]))
        if len(route) != 1 or route[0].get('type', 'unicast') != 'unicast' or route[0].get('dev') != 'vr-relay':
            raise ValueError('owned bogon must be unicast at relay, not local')
        trace.measure('owned_bogon_route', route)
        # packet_command normally requires the exact baseline route set. This
        # reviewed subcase verifies the precise extra /32 below instead; it does
        # not change the coordinator boundary or expose a skip option.
        results['bogon'] = denial_case(context, 'bogon')
    finally:
        if route_added:
            trace.command(['ip', 'route', 'delete', packets.BOGON + '/32', 'dev', 'vr-relay'])
        trace.command(['ip', '-n', vm.CLIENT_NS, 'address', 'delete', packets.BOGON + '/32', 'dev', 'lo'])
        context.pop('bogon_baseline')
    vm.boundary(kit, context['intent'], KIT_ROOT)
    trace.measure('actual_identical_target_denials', results)
    trace.check('positive_controls', all(packets.denial_observed(value) for value in results.values()))
    trace.check('local_out_of_range_denied', all(packets.denial_observed(results[name]) for name in ('local', 'real-relay-local')))
    trace.check('ipv6_denied', packets.denial_observed(results['ipv6']))
    trace.check('bogon_denied', packets.denial_observed(results['bogon']))
    trace.check('other_denied', packets.denial_observed(results['other']))
    # This is a new live media observation in this case, not a copied PASS.
    media = packet_command(context, {'mode': 'media', 'transport': 'udp',
                                     'credential': synthetic_credential('control', 180)}, timeout=50)
    trace.measure('actual_same_host_in_range_media', media)
    trace.check('same_host_in_range_media', packets.media_observed(media))
    trace.finish()


def lifecycle_snapshot(context):
    trace = context['trace']
    state = kit.state_record(kit.STATE)
    active = kit.wait_relay_active(state)
    pid = active['main_pid']
    properties = kit.properties(trace.command(['systemctl', 'show', 'paranoid-turn.service',
        '--property=User,Group,DynamicUser,NoNewPrivileges,StandardOutput,StandardError,MainPID,LoadCredential']))
    proc = Path('/proc') / str(pid)
    status = vm.descriptor_bytes(proc / 'status', 32768).decode()
    fields = dict(line.split(':', 1) for line in status.splitlines() if ':' in line)
    uids = [int(v) for v in fields['Uid'].split()]
    gids = [int(v) for v in fields['Gid'].split()]
    secret = kit.read_file('/etc/paranoid-turn/relay.secret', 64, owner=0, private=True)
    argv = vm.descriptor_bytes(proc / 'cmdline', 32768)
    environ = vm.descriptor_bytes(proc / 'environ', 32768)
    config_path = Path('/run/paranoid-turn/turnserver.conf')
    directory = config_path.parent.lstat()
    config_meta = config_path.lstat()
    raw = kit.read_file(config_path, owner=1902, private=True)
    template = kit.read_file(KIT_ROOT / 'relay/turnserver.conf.in', owner=0)
    expected = template.replace(b'@SECRET@', secret).replace(b'@RUNTIME@', str(config_path.parent).encode())
    unit = kit.read_file('/etc/systemd/system/paranoid-turn.service', owner=0)
    runtime = kit.read_file(KIT_ROOT / 'relay/runtime.py', owner=0)
    runtime_path = '/opt/paranoid-turn/' + kit.verify_component(KIT_ROOT / 'relay')['release'] + '/runtime.py'
    return {'pid': pid, 'executable_sha256': active['executable_sha256'],
            'uid': uids, 'gid': gids, 'unit_properties': properties,
            'runtime_source_sha256': kit.sha(runtime), 'actual_config_sha256': kit.sha(raw),
            'config_metadata': {'uid': config_meta.st_uid, 'mode': stat.S_IMODE(config_meta.st_mode),
                'nlink': config_meta.st_nlink, 'inode': config_meta.st_ino, 'ctime_ns': config_meta.st_ctime_ns},
            'directory_metadata': {'uid': directory.st_uid, 'mode': stat.S_IMODE(directory.st_mode),
                'inode': directory.st_ino, 'ctime_ns': directory.st_ctime_ns},
            'persistent_reader': ('ExecStart=/usr/bin/python3 -I -B ' + runtime_path + ' run\n').encode() in unit
                and b'LoadCredential=voice-turn-secret:/etc/paranoid-turn/relay.secret\n' in unit
                and raw == expected,
            'static_uid': uids == [1902] * 4 and gids == [1902] * 4
                and properties.get('DynamicUser') == 'no' and properties.get('User') == 'paranoid-turn'
                and properties.get('Group') == 'paranoid-turn',
            'generation_private': config_meta.st_uid == directory.st_uid == 1902
                and stat.S_IMODE(config_meta.st_mode) == 0o600 and config_meta.st_nlink == 1
                and stat.S_IMODE(directory.st_mode) == 0o700,
            'secret_not_exported': secret not in argv and secret not in environ
                and b'static-auth-secret=' not in argv + environ
                and argv.split(b'\0') == [b'turnserver', b'-c', str(config_path).encode(), b'']
                and properties.get('StandardOutput') == properties.get('StandardError') == 'null'
                and properties.get('NoNewPrivileges') == 'yes' and fields['NoNewPrivs'].strip() == '1'}


def relay_baseline(context):
    trace = context['trace']
    trace.begin('turn-rt01')
    binary = FIXTURE_ROOT / 'baseline-turnserver'
    if kit.sha(kit.read_file(binary, owner=0)) != context['inputs']['baseline_binary_sha256']:
        raise ValueError('exact reviewed stock coturn baseline required')
    directory = Path('/run/paranoid-voice-baseline')
    directory.mkdir(mode=0o700)
    config_path = directory / 'turnserver.conf'
    secret = kit.read_file('/etc/paranoid-turn/relay.secret', 64, owner=0, private=True)
    template = kit.read_file(KIT_ROOT / 'relay/turnserver.conf.in', owner=0)
    config = template.replace(b'@SECRET@', secret).replace(b'@RUNTIME@', str(directory).encode())
    kit.atomic_write(config_path, config, 0o600, exclusive=True)
    os.chown(config_path, 1902, 1902)
    os.chown(directory, 1902, 1902)
    release = kit.verify_component(KIT_ROOT / 'relay')['release']
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'OPENSSL_CONF': '/dev/null',
                   'LD_LIBRARY_PATH': '/opt/paranoid-turn/' + release + '/lib'}
    process = None
    try:
        process = OwnedOutputChild(trace, ['setpriv', '--reuid', '1902', '--regid', '1902',
            '--clear-groups', '--no-new-privs', str(binary), '-c', str(config_path)], env=environment)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.process.poll() is not None:
                raise ValueError('owned stock baseline exited before observation')
            try:
                if os.readlink('/proc/' + str(process.process.pid) + '/exe') == str(binary):
                    sockets = trace.command(['ss', '-H', '-lntup']).decode()
                    if (re.search(r'udp\s.*' + re.escape(kit.PUBLIC_IP) + r':34781\s', sockets)
                            and re.search(r'tcp\s.*' + re.escape(kit.PUBLIC_IP) + r':34781\s', sockets)):
                        break
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        else:
            raise TimeoutError('owned stock baseline readiness deadline')
        trace.measure('stock_baseline_process', {'pid': process.process.pid,
            'binary_sha256': context['inputs']['baseline_binary_sha256'],
            'netns_inode': os.stat('/proc/' + str(process.process.pid) + '/ns/net').st_ino,
            'configured_max_allocate_lifetime': 60})
        result = packet_command(context, {'mode': 'baseline', 'credential': synthetic_credential('baseline', 8)}, timeout=20)
        trace.measure('actual_unmodified_baseline_red', result)
        trace.check('baseline_red_observed', result.get('zero_request_bypassed_cap') is True
                    and result.get('expired_cached_refresh_accepted') is True)
    finally:
        if process is not None:
            process.close(planned_stop=True)
        # Only this exclusively-created synthetic baseline's files may be removed.
        for path in directory.iterdir():
            if path.name not in ('turnserver.conf', 'turnserver.pid') or path.is_symlink() or not path.is_file():
                raise ValueError('unexpected owned baseline cleanup member')
            path.unlink()
        directory.rmdir()


def lifecycle_case(context):
    trace = context['trace']
    trace.begin('relay-credentials-lifecycle')
    first = lifecycle_snapshot(context)
    trace.measure('first_actual_generation', first)
    trace.command(['systemctl', 'stop', 'paranoid-turn.service'], timeout=20)
    stopped = kit.properties(trace.command(['systemctl', 'show', 'paranoid-turn.service',
        '--property=MainPID,ControlPID,ActiveState,SubState']))
    cleanup = (stopped == {'MainPID': '0', 'ControlPID': '0', 'ActiveState': 'inactive', 'SubState': 'dead'}
               and not os.path.lexists('/run/paranoid-turn')
               and not os.path.lexists('/run/credentials/paranoid-turn.service')
               and not Path('/proc/' + str(first['pid'])).exists())
    trace.measure('actual_stopped_unit', stopped)
    trace.check('stop_cleanup', cleanup)
    if not cleanup:
        raise ValueError('actual persistent unit cleanup failed')
    relay_baseline(context)
    trace.select('relay-credentials-lifecycle')
    trace.command(['systemctl', 'start', 'paranoid-turn.service'], timeout=30)
    second = lifecycle_snapshot(context)
    trace.measure('second_actual_generation', second)
    for check, field in (('persistent_path_reader', 'persistent_reader'), ('static_uid', 'static_uid'),
                         ('generation_private', 'generation_private'), ('secret_not_exported', 'secret_not_exported')):
        trace.check(check, first[field] is True and second[field] is True)
    trace.check('restart_fresh_pid', first['pid'] != second['pid']
        and first['config_metadata']['ctime_ns'] < second['config_metadata']['ctime_ns'])
    trace.finish()


def rt01_case(context):
    trace = context['trace']
    trace.select('turn-rt01')
    # Both native binaries are explicit extracted-function units, with doubled
    # dependencies. Their deterministic delivery order is not a socket race.
    units = {}
    for name, expected_exit in (('baseline', 1), ('patched', 0)):
        binary = FIXTURE_ROOT / ('callback-' + name)
        if kit.sha(kit.read_file(binary, owner=0)) != context['inputs']['callback_binary_sha256'][name]:
            raise ValueError('exact reviewed native callback unit required')
        units[name] = kit.decode_json(trace.command(['setpriv', '--reuid', '1903', '--regid', '1903',
            '--clear-groups', '--no-new-privs', str(binary)], expected=expected_exit))
    trace.measure('native_callback_order_units', units)
    trace.measure('callback_claim', 'callback-order deterministic unit (exact extracted definition, doubled dependencies) + real async integration on the packaged binary')
    # Fresh timestamps are created immediately before the one finite worker.
    result = packet_command(context, {'mode': 'expiry', 'control_credential': synthetic_credential('control', 180),
                                      'credential': synthetic_credential('expiry', 8)}, timeout=115)
    trace.measure('actual_packaged_expiry_and_drain', result)
    for check, field in (('expired_allocate_rejected', 'expired_allocate_rejected'),
                         ('cached_credentials_expired_rejected', 'cached_controls_rejected'),
                         ('lifetime_clamped', 'lifetime_clamped'), ('refresh_capped', 'refresh_capped')):
        trace.check(check, result.get(field) is True)
    sockets = trace.command(['ss', '-H', '-unap']).decode()
    absent = not re.search(re.escape(kit.PUBLIC_IP) + ':' + str(result['expired_allocation_port']) + r'\s', sockets)
    trace.check('allocation_expired', absent and result.get('late_received') is False)
    trace.check('drain_bounded', result.get('before_received') is True and result.get('residual_received') is True
        and result.get('receiver_refreshed') is True and result.get('late_received') is False
        and result.get('wrong_password_rejected') is True and absent)
    # Final callback schema is deliberately checked strictly; pending native
    # review conditions cannot be converted to a synthetic successful field.
    expected = {'normal_success', 'expired_after_success_cleared', 'mismatch_after_success_cleared',
                'failure_then_success', 'failure_then_failure', 'success_then_success',
                'asymmetric_key_only', 'asymmetric_password_only', 'closing_session_cleared',
                'missing_session_no_resume', 'missing_socket_no_resume'}
    trace.check('callback_race_rejected', all(units['patched'].get(k) is True for k in expected)
        and units['baseline'].get('expired_after_success_cleared') is False
        and units['baseline'].get('mismatch_after_success_cleared') is False
        and result.get('overlap_invariants') is True and result.get('cached_controls_rejected') is True)
    trace.finish()


# A populated, independently reviewed implementation is required before ANY
# mutation. Individual source slices are not a permitted partial runtime suite.
RUNNERS = {}


def execute_suite(inputs, trace):
    if set(RUNNERS) != set(vm.REQUIRED_CASES) - {'fixture-isolation'}:
        raise ValueError('complete reviewed suite required before guest mutation')
    bootstrap(inputs, trace)


def main():
    # Keep the construction phase visibly unavailable, even if somebody packages
    # this intermediate file. No mode/skip/force option can open its execution.
    if set(RUNNERS) != set(vm.REQUIRED_CASES) - {'fixture-isolation'}:
        raise ValueError('complete reviewed suite required before guest mutation')
    raise ValueError('full runner construction has not reached artifact review')


if __name__ == '__main__':
    main()
