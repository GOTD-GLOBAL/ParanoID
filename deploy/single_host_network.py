#!/usr/bin/env python3
"""REQ-DEPLOY-003: fixed production network plan and journaled owned operations.

This module's offline tests do not prove kernel/UFW enforcement. No fixture
profile is accepted. The coordinator creates the private receipt only after its
full production acceptance gate; an authority digest is provenance, not proof.
"""
import argparse
import contextlib
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile

PROFILE = 'paranoid-single-host-v1'
TABLE = 'paranoid_voice'
CHAIN = 'output'
MAX_BYTES = 262144
OPERATIONS = ('check', 'apply', 'open-ingress', 'close-ingress', 'remove')
BOGONS = (('0.0.0.0', '0.255.255.255'), ('10.0.0.0', '10.255.255.255'),
          ('100.64.0.0', '100.127.255.255'), ('127.0.0.0', '127.255.255.255'),
          ('169.254.0.0', '169.254.255.255'), ('172.16.0.0', '172.31.255.255'),
          ('192.0.0.0', '192.0.0.255'), ('192.0.2.0', '192.0.2.255'),
          ('192.168.0.0', '192.168.255.255'), ('198.18.0.0', '198.19.255.255'),
          ('198.51.100.0', '198.51.100.255'), ('203.0.113.0', '203.0.113.255'),
          ('224.0.0.0', '255.255.255.255'))


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def decode_json(raw):
    if isinstance(raw, str):
        raw = raw.encode()
    if not isinstance(raw, bytes) or len(raw) > MAX_BYTES:
        raise ValueError('bounded JSON required')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate JSON key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('finite JSON required')))


def validate_spec(spec):
    if (not isinstance(spec, dict)
            or set(spec) != {'v', 'profile', 'ip', 'interface', 'relay_uid'}
            or type(spec['v']) is not int or spec['v'] != 1
            or spec['profile'] != PROFILE or spec['ip'] != '157.180.49.125'
            or type(spec['relay_uid']) is not int or not 1 <= spec['relay_uid'] <= 4294967294
            or not isinstance(spec['interface'], str)
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,14}', spec['interface'])):
        raise ValueError('unsupported production network spec')
    return dict(spec)


def _match(left, right, op='=='):
    return {'match': {'op': op, 'left': left, 'right': right}}


def _meta(key):
    return {'meta': {'key': key}}


def _payload(protocol, field):
    return {'payload': {'protocol': protocol, 'field': field}}


def _objects(spec):
    validate_spec(spec)
    objects = [{'table': {'family': 'inet', 'name': TABLE}},
               {'chain': {'family': 'inet', 'table': TABLE, 'name': CHAIN,
                          'type': 'filter', 'hook': 'output', 'prio': -10, 'policy': 'accept'}}]
    def rule(name, expressions):
        objects.append({'rule': {'family': 'inet', 'table': TABLE, 'chain': CHAIN,
                                'comment': PROFILE + ':' + name, 'expr': expressions}})
    def udp():
        return [_match(_meta('nfproto'), 'ipv4'), _match(_meta('l4proto'), 'udp')]
    relay_range = {'range': [40000, 40015]}
    rule('other-uids', [_match(_meta('skuid'), spec['relay_uid'], '!='), {'return': None}])
    rule('deny-ipv6', [_match(_meta('nfproto'), 'ipv6'), {'drop': None}])
    rule('same-host-media', udp() + [_match(_payload('ip', 'saddr'), spec['ip']),
                                   _match(_payload('ip', 'daddr'), spec['ip']),
                                   _match(_payload('udp', 'sport'), relay_range),
                                   _match(_payload('udp', 'dport'), relay_range), {'accept': None}])
    rule('deny-local', [_match({'fib': {'result': 'type', 'flags': ['daddr']}}, 'local'), {'drop': None}])
    for index, (low, high) in enumerate(BOGONS):
        rule('deny-bogon-' + str(index), [_match(_meta('nfproto'), 'ipv4'),
                                        _match(_payload('ip', 'daddr'), {'range': [low, high]}),
                                        {'drop': None}])
    rule('listener-udp', udp() + [_match(_payload('ip', 'saddr'), spec['ip']),
                                _match(_payload('udp', 'sport'), 34781), {'accept': None}])
    rule('listener-tcp', [_match(_meta('nfproto'), 'ipv4'), _match(_meta('l4proto'), 'tcp'),
                          _match(_payload('ip', 'saddr'), spec['ip']),
                          _match(_payload('tcp', 'sport'), 34781),
                          _match({'ct': {'key': 'state'}}, 'established', 'in'), {'accept': None}])
    rule('relay-udp', udp() + [_match(_payload('ip', 'saddr'), spec['ip']),
                             _match(_payload('udp', 'sport'), relay_range), {'accept': None}])
    rule('deny-other', [{'drop': None}])
    return objects


def render_nft(spec):
    """Atomic JSON transaction, with exclusive table creation, never flush/add-to-existing."""
    objects = _objects(spec)
    return canonical({'nftables': [{'create': objects[0]}] + [{'add': obj} for obj in objects[1:]]})


def normalize_nft_json(raw):
    value = decode_json(raw) if isinstance(raw, (bytes, str)) else copy.deepcopy(raw)
    if not isinstance(value, dict) or set(value) != {'nftables'} or not isinstance(value['nftables'], list):
        raise ValueError('unsupported nft JSON')
    if len(value['nftables']) > 80:
        raise ValueError('unexpected nft object count')
    result = []
    schemas = {'table': ({'family', 'name'}, {'handle'}),
               'chain': ({'family', 'table', 'name', 'type', 'hook', 'prio', 'policy'}, {'handle'}),
               'rule': ({'family', 'table', 'chain', 'expr'}, {'handle', 'comment'})}
    for obj in value['nftables']:
        if not isinstance(obj, dict) or len(obj) != 1:
            raise ValueError('unexpected nft object')
        kind, body = next(iter(obj.items()))
        if kind == 'metainfo':
            if not isinstance(body, dict):
                raise ValueError('invalid nft metadata')
            continue
        if kind not in schemas or not isinstance(body, dict):
            raise ValueError('unreviewed nft object')
        required, optional = schemas[kind]
        if not required <= set(body) <= required | optional:
            raise ValueError('unreviewed nft object fields')
        if body['family'] != 'inet' or body.get('table', body.get('name')) != TABLE:
            raise ValueError('foreign nft table')
        if 'handle' in body and (type(body['handle']) is not int or body['handle'] < 0):
            raise ValueError('invalid nft handle')
        body.pop('handle', None)
        if kind == 'rule':
            body['expr'] = canonical_expr(body['expr'])
        result.append({kind: body})
    return result


# Kernel readback (observed on nftables v1.0.9) rewrites semantically identical
# rules: symbolic enum values become numeric (nfproto ipv6 -> 10, fib type
# local -> 2, l4proto tcp/udp -> 6/17) and redundant meta matches are dropped
# when a payload match already fixes the protocol. Canonicalize both the
# rendered and the read-back expression lists to the same reduced form so the
# drift check compares meaning, not dialect. Any unexpected shape is kept
# verbatim and will still fail the comparison.
_NFT_ENUMS = {'nfproto': {2: 'ipv4', 10: 'ipv6'},
              'l4proto': {6: 'tcp', 17: 'udp'}}
_FIB_TYPES = {2: 'local'}
# conntrack state bitmask values as returned by kernel readback
_CT_STATES = {2: 'established', 4: 'related', 8: 'new', 1: 'invalid'}


def _is_meta_match(item, key):
    return (isinstance(item, dict) and set(item) == {'match'}
            and isinstance(item['match'], dict)
            and isinstance(item['match'].get('left'), dict)
            and item['match']['left'] == {'meta': {'key': key}})


def canonical_expr(expr):
    if not isinstance(expr, list):
        raise ValueError('unreviewed nft rule expression')
    payload_protocols = set()
    for item in expr:
        if (isinstance(item, dict) and set(item) == {'match'}
                and isinstance(item['match'], dict)
                and isinstance(item['match'].get('left'), dict)
                and isinstance(item['match']['left'].get('payload'), dict)):
            payload_protocols.add(item['match']['left']['payload'].get('protocol'))
    result = []
    for item in copy.deepcopy(expr):
        # Drop meta matches made redundant by an explicit payload protocol.
        if _is_meta_match(item, 'nfproto') and item['match'].get('right') in ('ipv4', 2) \
                and 'ip' in payload_protocols:
            continue
        if _is_meta_match(item, 'l4proto'):
            right = item['match'].get('right')
            named = _NFT_ENUMS['l4proto'].get(right, right)
            if named in payload_protocols:
                continue
        # Map remaining numeric enum values onto their symbolic names.
        if isinstance(item, dict) and set(item) == {'match'} and isinstance(item['match'], dict):
            left, right = item['match'].get('left'), item['match'].get('right')
            for key, mapping in _NFT_ENUMS.items():
                if _is_meta_match(item, key) and right in mapping:
                    item['match']['right'] = mapping[right]
            if (isinstance(left, dict) and isinstance(left.get('fib'), dict)
                    and left['fib'].get('result') == 'type' and right in _FIB_TYPES):
                item['match']['right'] = _FIB_TYPES[right]
            if (isinstance(left, dict) and left.get('ct') == {'key': 'state'}
                    and right in _CT_STATES):
                item['match']['right'] = _CT_STATES[right]
        result.append(item)
    return result


def ufw_display(arguments):
    return 'ufw ' + shlex.join(arguments)


def desired_ufw_rules(spec):
    validate_spec(spec)
    result = []
    owner = digest(canonical(spec))[:20]
    for name, proto, port in [('turn-tcp', 'tcp', '34781'), ('turn-udp', 'udp', '34781'),
                              ('relay-udp', 'udp', '40000:40015')]:
        comment = PROFILE + ':' + owner + ':' + name
        args = ['allow', 'in', 'on', spec['interface'], 'proto', proto, 'from', 'any',
                'to', spec['ip'], 'port', port, 'comment', comment]
        result.append({'id': name, 'comment': comment,
                       'add_argv': ['/usr/sbin/ufw', *args],
                       'delete_argv': ['/usr/sbin/ufw', '--force', 'delete', *args],
                       'semantic': _parse_ufw_rule(['ufw', *args])})
    return tuple(result)


def _port(value):
    if value == 'any':
        return [1, 65535]
    if not re.fullmatch(r'[0-9]{1,5}(?::[0-9]{1,5})?', value):
        raise ValueError('unsupported UFW port syntax')
    numbers = [int(part) for part in value.split(':')]
    if len(numbers) == 1:
        numbers *= 2
    if not 1 <= numbers[0] <= numbers[1] <= 65535:
        raise ValueError('invalid UFW port')
    return numbers


def _address(value):
    if value == 'any':
        return value
    try:
        return str(ipaddress.ip_network(value, strict=False))
    except ValueError:
        raise ValueError('unsupported UFW address or application profile') from None


def _parse_ufw_rule(args):
    if not args or args.pop(0) != 'ufw' or not args:
        raise ValueError('unsupported UFW command')
    action = args.pop(0)
    if action not in ('allow', 'deny', 'reject', 'limit'):
        raise ValueError('unsupported UFW action')
    rule = {'action': action, 'direction': 'in', 'interface': 'any', 'proto': 'any',
            'src': 'any', 'src_port': [1, 65535], 'dst': 'any',
            'dst_port': [1, 65535], 'comment': '', 'log': ''}
    if 'comment' in args:
        index = args.index('comment')
        if index != len(args) - 2 or len(args[-1]) > 256:
            raise ValueError('unsupported UFW comment')
        rule['comment'] = args[-1]
        args = args[:index]
    if args and args[0] in ('in', 'out'):
        rule['direction'] = args.pop(0)
    if args[:1] == ['on']:
        if len(args) < 2 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,14}', args[1]):
            raise ValueError('unsupported UFW interface')
        rule['interface'] = args[1]
        args = args[2:]
    if args and args[0] in ('log', 'log-all'):
        rule['log'] = args.pop(0)
    if len(args) == 1:
        token = args.pop()
        simple = token.split('/')
        if re.fullmatch(r'[0-9]{1,5}(?::[0-9]{1,5})?(?:/(?:tcp|udp))?', token):
            rule['dst_port'] = _port(simple[0])
            if len(simple) == 2:
                rule['proto'] = simple[1]
            return rule
        if re.fullmatch(r'[A-Za-z][A-Za-z0-9 _.+-]{0,63}', token):
            # Neighboring application-profile rule (e.g. 'ufw allow OpenSSH').
            # Ports are unknown at parse time: record the profile and keep the
            # conservative full range so any potential overlap is visible until
            # the observer resolves the profile's actual ports.
            rule['app'] = token
            return rule
        raise ValueError('unsupported UFW simple rule')
    seen = set()
    while args:
        key = args.pop(0)
        if key not in ('proto', 'from', 'to') or key in seen or not args:
            raise ValueError('unsupported UFW rule syntax')
        seen.add(key)
        value = args.pop(0)
        if key == 'proto':
            if value not in ('tcp', 'udp', 'any'):
                raise ValueError('unsupported UFW protocol')
            rule['proto'] = value
        else:
            prefix = 'src' if key == 'from' else 'dst'
            rule[prefix] = _address(value)
            if args[:1] == ['port']:
                if len(args) < 2:
                    raise ValueError('missing UFW port')
                rule[prefix + '_port'] = _port(args[1])
                args = args[2:]
    if not seen:
        raise ValueError('empty UFW rule')
    return rule


def parse_ufw_added(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_BYTES:
        raise ValueError('bounded UFW observation required')
    result = []
    for line in raw.decode('utf-8').splitlines():
        if not line.strip() or line.startswith('Added user rules'):
            continue
        if not line.startswith('ufw '):
            raise ValueError('unsupported UFW output')
        result.append(_parse_ufw_rule(shlex.split(line)))
    return result


def _app_ports(raw):
    """Parse `ufw app info NAME` output into exact (proto, [lo, hi]) pairs."""
    if not isinstance(raw, bytes) or len(raw) > MAX_BYTES:
        raise ValueError('bounded UFW app observation required')
    result, in_ports = [], False
    for line in raw.decode('utf-8').splitlines():
        if line.startswith(('Ports:', 'Port:')):
            in_ports = True
            continue
        if in_ports:
            if not line.startswith((' ', '\t')):
                break
            match = re.fullmatch(r'([0-9,:]+)(?:/(tcp|udp))?', line.strip())
            if not match:
                raise ValueError('unsupported UFW application profile ports')
            for piece in match.group(1).split(','):
                for proto in ((match.group(2),) if match.group(2) else ('tcp', 'udp')):
                    result.append((proto, _port(piece)))
    if not result:
        raise ValueError('unsupported UFW application profile ports')
    return result


def resolve_app_rules(rules, runner):
    """Expand neighbor application-profile rules into their exact resolved
    ports so overlap checks compare real scopes, never a guessed range."""
    resolved = []
    for rule in rules:
        if 'app' not in rule:
            resolved.append(rule)
            continue
        for proto, ports in _app_ports(runner(['/usr/sbin/ufw', 'app', 'info', rule['app']])):
            expanded = {key: value for key, value in rule.items() if key != 'app'}
            expanded['proto'] = proto
            expanded['dst_port'] = ports
            resolved.append(expanded)
    return resolved


def _overlaps(rule, target):
    if rule['direction'] != 'in' or rule['interface'] not in ('any', target['interface']):
        return False
    if rule['proto'] not in ('any', target['proto']):
        return False
    if rule['dst'] != 'any':
        destination = ipaddress.ip_network(rule['dst'])
        address = ipaddress.ip_network(target['dst']).network_address
        if address not in destination:
            return False
    return max(rule['dst_port'][0], target['dst_port'][0]) <= min(rule['dst_port'][1], target['dst_port'][1])


def command(argv, input=None):
    """No shell, no inherited secrets, bounded commands; errors are redacted."""
    completed = subprocess.run(argv, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C', 'LC_ALL': 'C'},
                               timeout=15, check=False)
    if completed.returncode or len(completed.stdout) > MAX_BYTES or len(completed.stderr) > MAX_BYTES:
        raise RuntimeError('network helper command failed')
    return completed.stdout


def _trusted_path(path, owner, trusted_base=None):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('absolute trusted path required')
    base = Path('/') if trusted_base is None else Path(trusted_base)
    if not path.is_relative_to(base):
        raise ValueError('path escapes trusted root')
    for parent in reversed((path.parent, *path.parent.parents)):
        if not parent.is_relative_to(base):
            continue
        meta = parent.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != owner or meta.st_mode & 0o022:
            raise ValueError('untrusted path ancestor')
    return path


def _read_regular(path, owner=0, private=False, trusted_base=None):
    path = _trusted_path(path, owner, trusted_base)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        mode = stat.S_IMODE(info.st_mode)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != owner
                or mode & 0o022 or mode & 0o7000 or (private and mode != 0o600)):
            raise ValueError('trusted regular file required')
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('file exceeds bound')
    return raw


def read_private_json(path, owner=0, trusted_base=None):
    return decode_json(_read_regular(path, owner=owner, private=True, trusted_base=trusted_base))


def observe(spec, runner=command, read=_read_regular):
    validate_spec(spec)
    status = runner(['/usr/sbin/ufw', 'status', 'verbose']).decode('utf-8')
    # 'disabled (routed)' and the stricter 'deny (routed)' are both supported:
    # the relay never forwards traffic, and deny-routed (observed on the
    # authorized host, where Docker manages its own FORWARD chains) only
    # tightens the boundary. Any other incoming/outgoing default is refused.
    if ('Status: active\n' not in status
            or not any('Default: deny (incoming), allow (outgoing), ' + routed in status
                       for routed in ('disabled (routed)', 'deny (routed)'))):
        raise ValueError('unsupported UFW active/default policy')
    if b'(nf_tables)' not in runner(['/usr/sbin/iptables', '--version']):
        raise ValueError('unsupported UFW backend')
    before = read(Path('/etc/ufw/before.rules')).decode('utf-8')
    lines = [shlex.split(line) for line in before.splitlines() if line.startswith('-A ')]
    # Merely finding an ACCEPT somewhere is insufficient: an earlier DROP/jump
    # may shadow it. This supported profile requires the exact first rule in both
    # chains, and deliberately refuses custom earlier rules rather than guessing.
    for chain, direction in (('ufw-before-input', '-i'), ('ufw-before-output', '-o')):
        chain_rules = [line for line in lines if line[:2] == ['-A', chain]]
        if not chain_rules or chain_rules[0] != ['-A', chain, direction, 'lo', '-j', 'ACCEPT']:
            raise ValueError('unsupported UFW loopback policy')
    ufw = resolve_app_rules(parse_ufw_added(runner(['/usr/sbin/ufw', 'show', 'added'])), runner)
    listing = decode_json(runner(['/usr/sbin/nft', '--json', '--numeric', 'list', 'tables']))
    if not isinstance(listing, dict) or set(listing) != {'nftables'} or not isinstance(listing['nftables'], list):
        raise ValueError('unsupported nft table listing')
    matches = 0
    for entry in listing['nftables']:
        if not isinstance(entry, dict) or len(entry) != 1 or not set(entry) <= {'metainfo', 'table'}:
            raise ValueError('unsupported nft table listing')
        if 'table' in entry:
            table = entry['table']
            if not isinstance(table, dict) or not {'family', 'name'} <= set(table):
                raise ValueError('unsupported nft table listing')
            if table['family'] == 'inet' and table['name'] == TABLE:
                matches += 1
    if matches > 1:
        raise ValueError('ambiguous nft table')
    table = None if not matches else normalize_nft_json(runner(
        ['/usr/sbin/nft', '--json', '--numeric', 'list', 'table', 'inet', TABLE]))
    return {'v': 1, 'table': table, 'ufw': ufw, 'ufw_supported': True}


def validate_receipt(spec, receipt):
    keys = {'v', 'profile', 'spec_sha256', 'policy_sha256', 'authority_sha256', 'egress', 'ingress', 'pending'}
    if (not isinstance(receipt, dict) or set(receipt) != keys
            or type(receipt['v']) is not int or receipt['v'] != 1 or receipt['profile'] != PROFILE
            or receipt['spec_sha256'] != digest(canonical(validate_spec(spec)))
            or receipt['policy_sha256'] != digest(render_nft(spec))
            or not isinstance(receipt['authority_sha256'], str)
            or not re.fullmatch('[0-9a-f]{64}', receipt['authority_sha256'])
            or receipt['egress'] not in ('absent', 'present')
            or not isinstance(receipt['ingress'], list)
            or any(value not in ('turn-tcp', 'turn-udp', 'relay-udp') for value in receipt['ingress'])
            or len(set(receipt['ingress'])) != len(receipt['ingress'])):
        raise ValueError('invalid or mismatched network receipt')
    pending = receipt['pending']
    if pending is not None:
        if not isinstance(pending, dict) or pending.get('op') not in OPERATIONS[1:]:
            raise ValueError('invalid pending network operation')
        expected = {'op', 'rule'} if pending['op'] in ('open-ingress', 'close-ingress') else {'op'}
        if set(pending) != expected or ('rule' in pending and pending['rule'] not in ('turn-tcp', 'turn-udp', 'relay-udp')):
            raise ValueError('invalid pending network operation')
    return receipt


def classify_ownership(spec, observation, receipt=None):
    validate_spec(spec)
    if receipt is not None:
        validate_receipt(spec, receipt)
    if not isinstance(observation, dict) or observation.get('ufw_supported') is not True:
        raise ValueError('supported network observation required')
    table = observation['table']
    pending = receipt['pending'] if receipt else None
    may_own = receipt is not None and (receipt['egress'] == 'present' or pending == {'op': 'apply'})
    if table is not None:
        if not may_own:
            raise ValueError('unowned nft table exists')
        # Compare canonical semantics: the kernel readback of an identical
        # policy differs syntactically (enum numerics, dropped redundant meta
        # matches), so both sides go through canonical_expr.
        expected = [{kind: dict(body, expr=canonical_expr(body['expr'])) if kind == 'rule' else body}
                    for obj in _objects(spec) for kind, body in obj.items()]
        if table != expected:
            raise ValueError('nft policy drift')
    elif receipt and receipt['egress'] == 'present' and pending != {'op': 'remove'}:
        # A reboot legitimately starts with an empty table. Only apply may restore
        # the exact committed policy; check reports absence without adoption.
        pass
    present = []
    for wanted in desired_ufw_rules(spec):
        matching = [rule for rule in observation['ufw'] if _overlaps(rule, wanted['semantic'])]
        owned = receipt is not None and (wanted['id'] in receipt['ingress'] or
                  pending == {'op': 'open-ingress', 'rule': wanted['id']})
        if matching:
            if not owned or matching != [wanted['semantic']]:
                raise ValueError('ingress conflict or ownership drift')
            present.append(wanted['id'])
        elif receipt and wanted['id'] in receipt['ingress'] and pending != {
                'op': 'close-ingress', 'rule': wanted['id']}:
            raise ValueError('owned ingress absence is drift')
    return {'egress': 'present' if table is not None else 'absent', 'ingress': present,
            'pending': copy.deepcopy(pending)}


def prepare_receipt(spec, observation, authority_sha256):
    state = classify_ownership(spec, observation)
    if state['egress'] != 'absent' or state['ingress']:
        raise ValueError('absent network baseline required')
    receipt = {'v': 1, 'profile': PROFILE, 'spec_sha256': digest(canonical(spec)),
               'policy_sha256': digest(render_nft(spec)), 'authority_sha256': authority_sha256,
               'egress': 'absent', 'ingress': [], 'pending': None}
    return validate_receipt(spec, receipt)


def _relay_stopped(runner):
    raw = runner(['/usr/bin/systemctl', 'show', 'paranoid-turn.service',
                  '--property=LoadState,ActiveState,SubState,MainPID,ControlPID']).decode('utf-8')
    fields = {}
    for line in raw.splitlines():
        if '=' not in line:
            raise ValueError('unknown relay lifecycle state')
        key, value = line.split('=', 1)
        if key in fields:
            raise ValueError('ambiguous relay lifecycle state')
        fields[key] = value
    if (set(fields) != {'LoadState', 'ActiveState', 'SubState', 'MainPID', 'ControlPID'}
            or fields['LoadState'] not in ('loaded', 'not-found')
            or fields['ActiveState'] not in ('inactive', 'failed')
            or fields['SubState'] not in ('dead', 'failed')
            or fields['MainPID'] != '0' or fields['ControlPID'] != '0'):
        raise ValueError('relay must be confirmed stopped')


def run_operation(operation, spec, receipt, save, runner=command, read=_read_regular):
    if operation not in OPERATIONS:
        raise ValueError('unknown network operation')
    validate_receipt(spec, receipt)
    def state():
        return classify_ownership(spec, observe(spec, runner=runner, read=read), receipt)
    def journal(pending):
        receipt['pending'] = pending
        save(copy.deepcopy(receipt))
    def finish(current):
        receipt['egress'] = current['egress']
        receipt['ingress'] = current['ingress']
        journal(None)
        return {'v': 1, 'egress': receipt['egress'], 'ingress': list(receipt['ingress']),
                'policy_sha256': receipt['policy_sha256'], 'pending': None}
    current = state()
    if operation == 'check':
        return {'v': 1, **current, 'policy_sha256': receipt['policy_sha256']}
    if operation == 'apply':
        if receipt['pending'] not in (None, {'op': 'apply'}):
            raise ValueError('pending network recovery required')
        if current['egress'] == 'absent':
            journal({'op': 'apply'})
            runner(['/usr/sbin/nft', '--json', '--file', '-'], input=render_nft(spec))
        current = state()
        if current['egress'] != 'present':
            raise ValueError('egress installation readback failed')
        return finish(current)
    if operation == 'open-ingress':
        if current['egress'] != 'present':
            raise ValueError('verified egress required before ingress')
        if receipt['pending'] is not None and receipt['pending']['op'] != 'open-ingress':
            raise ValueError('pending network recovery required')
        for wanted in desired_ufw_rules(spec):
            current = state()  # immediate semantic ownership check before each UFW add
            if wanted['id'] not in current['ingress']:
                journal({'op': 'open-ingress', 'rule': wanted['id']})
                runner(wanted['add_argv'])
                current = state()
                if wanted['id'] not in current['ingress']:
                    raise ValueError('ingress installation readback failed')
            finish(current)
        return finish(state())
    if operation == 'close-ingress':
        if receipt['pending'] is not None and receipt['pending']['op'] not in ('open-ingress', 'close-ingress'):
            raise ValueError('pending network recovery required')
        # Record a completed pending add privately before beginning its reverse.
        finish(current)
        for wanted in reversed(desired_ufw_rules(spec)):
            current = state()
            if wanted['id'] in current['ingress']:
                journal({'op': 'close-ingress', 'rule': wanted['id']})
                runner(wanted['delete_argv'])
                current = state()
                if wanted['id'] in current['ingress']:
                    raise ValueError('ingress removal readback failed')
            finish(current)
        return finish(state())
    if receipt['pending'] not in (None, {'op': 'remove'}, {'op': 'apply'}):
        raise ValueError('pending network recovery required')
    if current['ingress']:
        raise ValueError('close owned ingress before egress removal')
    _relay_stopped(runner)
    if current['egress'] == 'present':
        # A preceding apply may have written the table before its final receipt
        # save. Preserve that proven pending-apply ownership across deletion
        # failure, so a second exact rollback does not lose its own authority.
        receipt['egress'] = 'present'
        journal({'op': 'remove'})
        runner(['/usr/sbin/nft', '--json', '--file', '-'],
               input=canonical({'nftables': [{'delete': {'table': {'family': 'inet', 'name': TABLE}}}]}))
    current = state()
    if current['egress'] != 'absent':
        raise ValueError('egress removal readback failed')
    return finish(current)


def _unit_path(path):
    value = str(path)
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', value) or '..' in Path(path).parts:
        raise ValueError('safe absolute unit path required')
    return value


def render_policy_unit(helper, spec_file, policy_sha, receipt_file):
    if not re.fullmatch('[0-9a-f]{64}', policy_sha):
        raise ValueError('policy digest required')
    args = [_unit_path(p) for p in (helper, spec_file, receipt_file)]
    return (f'[Unit]\nDescription=ParanoID exact relay egress policy\n'
            f'After=ufw.service nftables.service\nBefore=paranoid-turn.service\n\n'
            f'[Service]\nType=oneshot\nRemainAfterExit=yes\nUser=root\nGroup=root\n'
            f'ExecStart=/usr/bin/python3 -I -B {args[0]} apply --spec {args[1]} '
            f'--expected-policy-sha {policy_sha} --receipt {args[2]}\n'
            f'UMask=0077\nNoNewPrivileges=yes\nTimeoutStartSec=30\nLimitCORE=0\n'
            f'StandardOutput=null\nStandardError=null\n').encode()


def _save_receipt(path, value):
    _read_regular(path, private=True)  # Never overwrite an unknown or redirected file.
    descriptor, temporary = tempfile.mkstemp(prefix='.network-receipt-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


@contextlib.contextmanager
def _network_lock(receipt_path):
    path = receipt_path.parent / 'network.lock'
    _trusted_path(path, 0)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError('unsafe network lock')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=OPERATIONS)
    parser.add_argument('--spec', required=True, type=Path)
    parser.add_argument('--expected-policy-sha', required=True)
    parser.add_argument('--receipt', required=True, type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('root helper required')
    spec = validate_spec(read_private_json(args.spec))
    if args.expected_policy_sha != digest(render_nft(spec)):
        raise ValueError('reviewed policy digest mismatch')
    # A real helper never creates a receipt. Only the coordinator may prepare one
    # after production acceptance; boot reuses that exact root-private record.
    if args.operation == 'check':
        receipt = read_private_json(args.receipt)
        result = run_operation('check', spec, receipt, lambda _: None)
    else:
        validate_receipt(spec, read_private_json(args.receipt))
        with _network_lock(args.receipt):
            receipt = read_private_json(args.receipt)
            result = run_operation(args.operation, spec, receipt,
                                   lambda value: _save_receipt(args.receipt, value))
    print(canonical(result).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('network helper interrupted; inspect private transaction receipt', file=sys.stderr)
        raise SystemExit(130) from None
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError):
        print('network helper refused or failed; preserved receipt requires review', file=sys.stderr)
        raise SystemExit(1) from None
