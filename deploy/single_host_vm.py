"""REQ-DEPLOY-003: full rehearsal file binding and the distinct guest boundary.

This verifier executes no fixture and creates no acceptance record. Root-owned
execution evidence still requires independent source/artifact/runtime review.
"""
import os
from pathlib import Path
import re
import stat

PROFILE = 'paranoid-single-host-vm-fixture-v1'
DMI_PRODUCT = 'ParanoID Voice Fixture v1'
BOUNDARY = Path('/run/paranoid-voice-fixture/boundary.json')
CLIENT_IP = '65.108.43.251'
CLIENT_NS = 'vr-client'
BOOT_ID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
REQUIRED_CASES = {
    'fixture-isolation': ('initial_lo_only_no_routes', 'pre_assignment_link_inventory',
                          'final_lo_only_no_routes', 'message_ingress_exact', 'ufw_loopback_accept_first'),
    'fresh': ('active', 'relay_active', 'issuer_enabled', 'registration_text'),
    'existing-v8': ('active', 'identity_preserved', 'retained_history_preserved', 'new_text_preserved'),
    'idempotence': ('no_new_transaction', 'identity_preserved', 'rules_unchanged'),
    'rollback': ('previous_code_config_units_restored', 'current_data_preserved', 'relay_ingress_closed'),
    'failure-recovery': ('failure_observed', 'prior_runtime_restored', 'current_data_preserved'),
    'issuer-interoperability': ('issuer_credentials_used', 'udp_relay_media', 'tcp_relay_media'),
    'turn-rt01': ('expired_allocate_rejected', 'cached_credentials_expired_rejected',
                  'allocation_expired', 'callback_race_rejected', 'lifetime_clamped',
                  'refresh_capped', 'drain_bounded', 'baseline_red_observed'),
    'turn-acl02': ('effective_rules_exact', 'namespace_match', 'positive_controls',
                   'local_out_of_range_denied', 'same_host_in_range_media',
                   'ipv6_denied', 'bogon_denied', 'other_denied'),
    'relay-cli': ('local5766closed', 'client5766closed', 'console_disabled'),
    'relay-credentials-lifecycle': ('persistent_path_reader', 'static_uid',
                                    'generation_private', 'restart_fresh_pid',
                                    'secret_not_exported', 'stop_cleanup'),
}
BINDINGS = ('run_id', 'production_kit_sha256', 'production_plan_sha256',
            'fixture_kit_sha256', 'driver_sha256')


def validate_execution(api, value, report, name):
    fields = {'v', 'case', 'boot_id', 'result', 'fixture_mode', 'fixture_plan_sha256', 'started_monotonic_ns',
              'finished_monotonic_ns', 'checks', 'measurements', 'commands', *BINDINGS}
    if (not isinstance(value, dict) or set(value) != fields or type(value['v']) is not int
            or value['v'] != 1 or value['case'] != name or value['result'] != 'OBSERVED'
            or value['boot_id'] not in report['boot_ids']
            or value['fixture_mode'] not in ('fresh', 'existing-v8')
            or value['fixture_plan_sha256'] != report['fixture_plan_sha256'][value['fixture_mode']]
            or (name in ('fresh', 'existing-v8') and value['fixture_mode'] != name)
            or any(value[field] != report[field] for field in BINDINGS)
            or type(value['started_monotonic_ns']) is not int
            or type(value['finished_monotonic_ns']) is not int
            or not 0 < value['started_monotonic_ns'] < value['finished_monotonic_ns']
            or not isinstance(value['checks'], dict)
            or set(value['checks']) != set(REQUIRED_CASES[name])
            or any(observed is not True for observed in value['checks'].values())
            or not isinstance(value['measurements'], dict) or not value['measurements']
            or not isinstance(value['commands'], list) or not 1 <= len(value['commands']) <= 1024):
        raise ValueError('complete source-bound actual case observations required')
    for command in value['commands']:
        if (not isinstance(command, dict) or set(command) != {'argv', 'exit_code',
                'expected_exit_code', 'output', 'output_sha256'}
                or not isinstance(command['argv'], list) or not 1 <= len(command['argv']) <= 128
                or any(not isinstance(arg, str) or not arg or len(arg) > 4096 for arg in command['argv'])
                or type(command['exit_code']) is not int or type(command['expected_exit_code']) is not int
                or command['exit_code'] != command['expected_exit_code']
                or not isinstance(command['output'], str) or len(command['output']) > 1024 * 1024
                or api.sha(command['output'].encode()) != command['output_sha256']):
            raise ValueError('actual bounded command/output correspondence required')


def verify_rehearsal(api, gate, production_root, production_sha, plan_sha, production_intent):
    if (gate.get('fixture_profile') != PROFILE or PROFILE not in api.FULL_REHEARSAL_PROFILES
            or production_root is None):
        raise ValueError('exact available full-relay rehearsal profile and production kit required')
    production_root = api.simple_path(str(production_root))
    production = api.verify_kit(production_root)
    if (production['profile'] != api.PRODUCTION
            or api.sha(api.read_file(production_root / 'manifest.json', owner=0)) != production_sha):
        raise ValueError('production kit binding differs')
    intent = api.validate_intent(production_intent)
    if (intent['profile'] != api.PRODUCTION or intent['kit_sha256'] != production_sha
            or api.plan(intent, production_root)['plan_sha256'] != plan_sha):
        raise ValueError('exact production intent and plan required')
    fixture_root = api.simple_path(gate['fixture_kit_path'])
    api.verify_root_kit(fixture_root)
    fixture = api.verify_kit(fixture_root)
    if (fixture['profile'] != PROFILE
            or api.sha(api.read_file(fixture_root / 'manifest.json', owner=0)) != gate['fixture_kit_sha256']
            or fixture['components'] != production['components']):
        raise ValueError('reviewed fixture kit/component binding differs')
    for name in api.BASE_FILES | api.RELAY_FILES:
        if fixture['sha256'][name] != production['sha256'][name]:
            raise ValueError('tested shared implementation differs from production')
    path = api.simple_path(gate['evidence_path'])
    data = api.read_file(path, 4 * 1024 * 1024, owner=0)
    if api.sha(data) != gate['evidence_sha256']:
        raise ValueError('actual rehearsal report checksum differs')
    report = api.decode_json(data)
    fields = {'v', 'profile', 'result', 'boot_ids', 'cases', 'fixture_intents', 'fixture_plan_sha256', *BINDINGS}
    if (not isinstance(report, dict) or set(report) != fields or type(report['v']) is not int
            or report['v'] != 1 or report['profile'] != PROFILE
            or report['result'] != 'FULL_REHEARSAL_OBSERVED'
            or not isinstance(report['run_id'], str) or not re.fullmatch(r'[0-9a-f]{32}', report['run_id'])
            or report['production_kit_sha256'] != production_sha
            or report['production_plan_sha256'] != plan_sha
            or report['fixture_kit_sha256'] != gate['fixture_kit_sha256']
            or report['driver_sha256'] != fixture['sha256']['single_host_vm_runner.py']
            or not isinstance(report['boot_ids'], list) or not 1 <= len(report['boot_ids']) <= 8
            or any(not isinstance(boot, str) or not BOOT_ID.fullmatch(boot) for boot in report['boot_ids'])
            or len(set(report['boot_ids'])) != len(report['boot_ids'])
            or not isinstance(report['fixture_intents'], dict)
            or set(report['fixture_intents']) != {'fresh', 'existing-v8'}
            or not isinstance(report['fixture_plan_sha256'], dict)
            or set(report['fixture_plan_sha256']) != {'fresh', 'existing-v8'}
            or not isinstance(report['cases'], dict) or set(report['cases']) != set(REQUIRED_CASES)):
        raise ValueError('complete exact production-plan-bound rehearsal required')
    for mode, candidate in report['fixture_intents'].items():
        configured = api.validate_intent(candidate)
        if (configured['profile'] != PROFILE or configured['mode'] != mode
                or configured['kit_sha256'] != report['fixture_kit_sha256']
                or any(configured[field] != intent[field] for field in ('ip', 'message', 'relay'))
                or api.plan(configured, fixture_root)['plan_sha256'] != report['fixture_plan_sha256'][mode]):
            raise ValueError('guest service layout, identities, mode coverage or plan differs')
    paths = set()
    for name, entry in report['cases'].items():
        if (not isinstance(entry, dict) or set(entry) != {'path', 'sha256'}
                or not isinstance(entry['path'], str)
                or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,80}\.json', entry['path'])
                or entry['path'] in paths or not api.is_hash(entry['sha256'])):
            raise ValueError('unique contained execution log reference required')
        paths.add(entry['path'])
        raw = api.read_file(path.parent / entry['path'], 8 * 1024 * 1024, owner=0)
        if api.sha(raw) != entry['sha256']:
            raise ValueError('referenced execution log checksum differs')
        validate_execution(api, api.decode_json(raw), report, name)
    return report


def descriptor_bytes(path, limit, mode=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or before.st_nlink != 1
                or before.st_mode & 0o022 or (mode is not None and stat.S_IMODE(before.st_mode) != mode)):
            raise ValueError('bounded root-owned observation descriptor required')
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_size', 'st_ctime_ns')
        if len(data) > limit or any(getattr(before, field) != getattr(after, field) for field in fields):
            raise ValueError('observation size or descriptor identity changed')
        return data


def observe_guest(api):
    # Kernel-owned guest observation only. No host/Android process is inspected.
    product = descriptor_bytes('/sys/class/dmi/id/product_name', 256).decode().strip()
    boot_id = descriptor_bytes('/proc/sys/kernel/random/boot_id', 64).decode().strip()
    pci = sorted(Path('/sys/bus/pci/devices').glob('*/class'))
    if len(pci) > 64:
        raise ValueError('unexpected guest PCI inventory')
    network_pci = [str(path.parent.name) for path in pci if int(descriptor_bytes(path, 32).strip(), 16) >> 16 == 2]
    physical_devices = sorted(path.parent.name for path in Path('/sys/class/net').glob('*/device'))
    namespaces = api.decode_json(api.command(['ip', '-j', 'netns', 'list'], timeout=10))
    links = api.decode_json(api.command(['ip', '-j', '-d', 'link', 'show'], timeout=10))
    clients = api.decode_json(api.command(['ip', '-n', CLIENT_NS, '-j', '-d', 'link', 'show'], timeout=10))
    routes = {}
    for namespace in (None, CLIENT_NS):
        prefix = ['ip'] if namespace is None else ['ip', '-n', namespace]
        routes[namespace or 'relay'] = {family: api.decode_json(api.command(
            prefix + ['-j', family, 'route', 'show', 'table', 'all'], timeout=10)) for family in ('-4', '-6')}
    route = api.decode_json(api.command(['ip', '-j', '-4', 'route', 'get', CLIENT_IP], timeout=10))
    return {'product': product, 'boot_id': boot_id, 'network_pci': network_pci,
            'physical_devices': physical_devices, 'namespaces': namespaces,
            'links': links, 'client_links': clients, 'routes': routes, 'client_route': route}


def validate_guest_observation(observed):
    if (observed['product'] != DMI_PRODUCT or not BOOT_ID.fullmatch(observed['boot_id'])
            or observed['network_pci']
            or observed['physical_devices']
            or len(observed['namespaces']) != 1 or observed['namespaces'][0].get('name') != CLIENT_NS
            or {link['ifname'] for link in observed['links']} != {'lo', 'vr-relay'}
            or {link['ifname'] for link in observed['client_links']} != {'lo', 'vr-client'}
            or not isinstance(observed['routes'], dict)
            or set(observed['routes']) != {'relay', CLIENT_NS}):
        raise ValueError('exact NIC-less guest and veth boundary required')
    relay = next(link for link in observed['links'] if link['ifname'] == 'vr-relay')
    client = next(link for link in observed['client_links'] if link['ifname'] == 'vr-client')
    if (relay.get('linkinfo', {}).get('info_kind') != 'veth'
            or client.get('linkinfo', {}).get('info_kind') != 'veth'
            or type(relay.get('ifindex')) is not int or type(client.get('ifindex')) is not int
            or relay.get('link_index') != client['ifindex'] or client.get('link_index') != relay['ifindex']):
        raise ValueError('actual paired guest veth interfaces required')
    for namespace, families in observed['routes'].items():
        if not isinstance(families, dict) or set(families) != {'-4', '-6'}:
            raise ValueError('complete guest route families required')
        allowed_devices = {'lo', 'vr-relay' if namespace == 'relay' else 'vr-client'}
        for family, routes in families.items():
            if not isinstance(routes, list) or len(routes) > 64:
                raise ValueError('bounded guest route inventory required')
            for route in routes:
                destination = route.get('dst', 'default')
                if destination in ('default', '0.0.0.0/0', '::/0') or route.get('dev') not in allowed_devices or 'gateway' in route:
                    raise ValueError('external guest route forbidden')
                if family == '-4' and destination not in {
                        '127.0.0.0/8', '127.0.0.1', '127.255.255.255',
                        '157.180.49.125', '157.180.49.125/32', CLIENT_IP, CLIENT_IP + '/32'}:
                    raise ValueError('unplanned guest IPv4 route')
                if family == '-6' and destination != '::1' and not destination.startswith(('fe80:', 'ff00:')):
                    raise ValueError('unplanned guest IPv6 route')
    routes = observed['client_route']
    if (len(routes) != 1 or routes[0].get('type', 'unicast') != 'unicast'
            or routes[0].get('dev') != 'vr-relay' or routes[0].get('dst') != CLIENT_IP
            or 'gateway' in routes[0]):
        raise ValueError('client must be guest-only unicast, not a local destination')


def normalized_observation(observed):
    # Bind stable topology fields, not route-cache timestamps or changing counters.
    def route(value):
        return {field: value.get(field, 'unicast' if field == 'type' else None)
                for field in ('type', 'dst', 'dev', 'gateway')}
    def links(values):
        return sorted(({'ifname': value['ifname'], 'ifindex': value['ifindex'],
                        'link_index': value.get('link_index'),
                        'kind': value.get('linkinfo', {}).get('info_kind')} for value in values),
                      key=lambda value: value['ifname'])
    return {'product': observed['product'], 'boot_id': observed['boot_id'],
            'network_pci': sorted(observed['network_pci']),
            'physical_devices': sorted(observed['physical_devices']),
            'namespaces': sorted(value['name'] for value in observed['namespaces']),
            'links': links(observed['links']),
            'client_links': links(observed['client_links']),
            'routes': {namespace: {family: sorted((route(value) for value in values), key=lambda v: repr(sorted(v.items())))
                                  for family, values in families.items()}
                       for namespace, families in observed['routes'].items()},
            'client_route': [route(value) for value in observed['client_route']]}


def boundary(api, intent, kit_root):
    if intent['profile'] != PROFILE or os.geteuid() != 0:
        raise ValueError('VM fixture requires guest root and its distinct profile')
    api.verify_root_kit(kit_root)
    manifest = api.verify_kit(kit_root)
    if manifest['profile'] != PROFILE:
        raise ValueError('exact VM fixture kit required')
    api.trusted_directory(BOUNDARY.parent, 0, private=True)
    raw = descriptor_bytes(BOUNDARY, 16 * 1024, mode=0o400)
    record = api.decode_json(raw)
    fields = {'v', 'profile', 'boot_id', 'kit_sha256', 'controller_sha256',
              'driver_sha256', 'isolation_sha256'}
    if (not isinstance(record, dict) or set(record) != fields or type(record['v']) is not int
            or record['v'] != 1 or record['profile'] != PROFILE
            or record['kit_sha256'] != intent['kit_sha256']
            or record['kit_sha256'] != api.sha(api.read_file(Path(kit_root) / 'manifest.json', owner=0))
            or record['controller_sha256'] != manifest['sha256']['single_host.py']
            or record['controller_sha256'] != api.sha(api.read_file(Path(api.__file__).resolve(), owner=0))
            or record['driver_sha256'] != manifest['sha256']['single_host_vm_runner.py']
            or not api.is_hash(record['isolation_sha256'])):
        raise ValueError('source and artifact bound fixture manifest required')
    observed = observe_guest(api)
    validate_guest_observation(observed)
    if record['boot_id'] != observed['boot_id']:
        raise ValueError('fixture manifest belongs to another boot')
    actual_isolation = api.sha(api.canonical(normalized_observation(observed)))
    if record['isolation_sha256'] != actual_isolation:
        raise ValueError('fixture isolation digest differs from actual current observation')
    record['isolation_sha256'] = actual_isolation
    return record
