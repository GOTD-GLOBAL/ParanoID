#!/usr/bin/env python3
"""ParanoID TURN local acceptance harness — gates TURN-RT01 / TURN-ACL02.

Starts a private coturn instance on 127.0.0.1 (loopback only) and runs
acceptance cases with a minimal pure-stdlib TURN/STUN UDP client:

  1. valid REST credential -> Allocate OK, XOR-RELAYED-ADDRESS in 40000-40015
  2. expired-timestamp credential -> Allocate rejected (401/438)
  3. wrong-HMAC credential -> Allocate rejected
  4. user-quota=4 -> fifth concurrent Allocate (same username) rejected 486
  5. ACL: CreatePermission to denied peer 10.0.0.1 -> 403; allowed loopback
     peer works end-to-end (Send/Data indication, echo through relay)
  6. LIFETIME attribute in Allocate <= 60; Refresh with expired credential
     rejected

Loopback only. No sudo, no firewall, no external addresses. Secret is
synthetic, stored 0600, never printed. Committed as acceptance tooling; the
build-machine paths below are explicit inputs of this harness run.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets as pysecrets
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

os.umask(0o077)

BUILD = Path('/home/codex/paranoid-self-service-evidence/voice-ready-20260910T065350Z/turn-credential-build/relocated')
TURNSERVER = BUILD / 'bin' / 'turnserver'
EXPECTED_BIN_SHA = 'e13597df18552665aa445c86c2b2ec111b19ea62a56adc774b2d7a9271ea368c'
EVID = Path('/home/codex/paranoid-self-service-evidence/voice-local-acceptance-20260910')
WORKTREE = Path('/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909')
HOST, PORT = '127.0.0.1', 34781
REALM = 'paranoid-voice-v1'
MAGIC = 0x2112A442
MAGIC_BYTES = struct.pack('!I', MAGIC)

# ---------------------------------------------------------------- STUN codec

ATTR_USERNAME = 0x0006
ATTR_MI = 0x0008
ATTR_ERROR = 0x0009
ATTR_LIFETIME = 0x000D
ATTR_XOR_PEER = 0x0012
ATTR_DATA = 0x0013
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_RELAYED = 0x0016
ATTR_REQ_TRANSPORT = 0x0019
ATTR_XOR_MAPPED = 0x0020

ALLOCATE_REQ, ALLOCATE_OK, ALLOCATE_ERR = 0x0003, 0x0103, 0x0113
REFRESH_REQ, REFRESH_OK, REFRESH_ERR = 0x0004, 0x0104, 0x0114
CREATEPERM_REQ, CREATEPERM_OK, CREATEPERM_ERR = 0x0008, 0x0108, 0x0118
SEND_IND, DATA_IND = 0x0016, 0x0017


def attr(t, v):
    return struct.pack('!HH', t, len(v)) + v + b'\x00' * ((4 - len(v) % 4) % 4)


def build_msg(mtype, tid, attrs, key=None):
    body = b''.join(attrs)
    if key is not None:
        hdr = struct.pack('!HHI', mtype, len(body) + 24, MAGIC) + tid
        mac = hmac.new(key, hdr + body, hashlib.sha1).digest()
        body += attr(ATTR_MI, mac)
    return struct.pack('!HHI', mtype, len(body), MAGIC) + tid + body


def parse_msg(data):
    mtype, length, magic = struct.unpack('!HHI', data[:8])
    tid = data[8:20]
    attrs = {}
    off = 20
    end = 20 + length
    while off + 4 <= end:
        t, l = struct.unpack('!HH', data[off:off + 4])
        attrs.setdefault(t, []).append(data[off + 4:off + 4 + l])
        off += 4 + l + ((4 - l % 4) % 4)
    return mtype, tid, attrs


def xor_addr_decode(v):
    port = struct.unpack('!H', v[2:4])[0] ^ (MAGIC >> 16)
    ip = '.'.join(str(b ^ m) for b, m in zip(v[4:8], MAGIC_BYTES))
    return ip, port


def xor_addr_encode(ip, port):
    raw = bytes(a ^ b for a, b in zip(socket.inet_aton(ip), MAGIC_BYTES))
    return struct.pack('!BBH', 0, 0x01, port ^ (MAGIC >> 16)) + raw


def err_code(attrs):
    vals = attrs.get(ATTR_ERROR)
    if not vals:
        return None
    v = vals[0]
    return (v[2] & 0x07) * 100 + v[3]


# ---------------------------------------------------------------- TURN client

class TurnClient:
    def __init__(self, username, password):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((HOST, 0))
        self.sock.settimeout(2.0)
        self.username = username.encode()
        self.key = hashlib.md5(f'{username}:{REALM}:{password}'.encode()).digest()
        self.realm = None
        self.nonce = None

    def close(self):
        self.sock.close()

    def request(self, mtype, attrs, key=None, retries=3):
        tid = os.urandom(12)
        wire = build_msg(mtype, tid, attrs, key)
        for _ in range(retries):
            self.sock.sendto(wire, (HOST, PORT))
            try:
                while True:
                    data, _ = self.sock.recvfrom(65535)
                    rt, rtid, rattrs = parse_msg(data)
                    if rtid == tid:
                        return rt, rattrs
            except socket.timeout:
                continue
        raise TimeoutError(f'no response for request 0x{mtype:04x}')

    def _auth(self):
        return [attr(ATTR_USERNAME, self.username),
                attr(ATTR_REALM, self.realm),
                attr(ATTR_NONCE, self.nonce)]

    def learn_nonce(self):
        """Unauthenticated Allocate to obtain realm+nonce (expects 401)."""
        rt, ra = self.request(ALLOCATE_REQ,
                              [attr(ATTR_REQ_TRANSPORT, struct.pack('!B3x', 17))])
        code = err_code(ra)
        if rt == ALLOCATE_ERR and code == 401 and ATTR_NONCE in ra:
            self.realm = ra[ATTR_REALM][0]
            self.nonce = ra[ATTR_NONCE][0]
        return rt, code

    def allocate(self, lifetime=None):
        if self.nonce is None:
            rt, code = self.learn_nonce()
            if self.nonce is None:
                return rt, {ATTR_ERROR: [b'\x00\x00' + bytes([(code or 0) // 100, (code or 0) % 100])]}
        extra = [attr(ATTR_REQ_TRANSPORT, struct.pack('!B3x', 17))]
        if lifetime is not None:
            extra.insert(0, attr(ATTR_LIFETIME, struct.pack('!I', lifetime)))
        return self.request(ALLOCATE_REQ, self._auth() + extra, key=self.key)

    def refresh(self, lifetime):
        return self.request(REFRESH_REQ,
                            self._auth() + [attr(ATTR_LIFETIME, struct.pack('!I', lifetime))],
                            key=self.key)

    def create_permission(self, peer_ip):
        return self.request(CREATEPERM_REQ,
                            self._auth() + [attr(ATTR_XOR_PEER, xor_addr_encode(peer_ip, 0))],
                            key=self.key)

    def send_indication(self, peer_ip, peer_port, payload):
        wire = build_msg(SEND_IND, os.urandom(12),
                         [attr(ATTR_XOR_PEER, xor_addr_encode(peer_ip, peer_port)),
                          attr(ATTR_DATA, payload)])
        self.sock.sendto(wire, (HOST, PORT))

    def recv_data_indication(self, timeout=2.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            rt, _tid, rattrs = parse_msg(data)
            if rt == DATA_IND and ATTR_DATA in rattrs:
                peer = xor_addr_decode(rattrs[ATTR_XOR_PEER][0]) if ATTR_XOR_PEER in rattrs else None
                return rattrs[ATTR_DATA][0], peer
        return None, None


# ---------------------------------------------------------------- credentials

def make_cred(secret, expiry_offset=3600, corrupt_hmac=False):
    username = f'{int(time.time()) + expiry_offset}:{pysecrets.token_hex(6)}'
    mac_input = username + ('CORRUPT' if corrupt_hmac else '')
    password = base64.b64encode(
        hmac.new(secret.encode(), mac_input.encode(), hashlib.sha1).digest()).decode()
    return username, password


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


# ---------------------------------------------------------------- cases

def case1_valid_allocate(secret, results):
    obs = {}
    ok = False
    c = TurnClient(*make_cred(secret))
    try:
        rt, ra = c.allocate(lifetime=600)
        obs['response_type'] = f'0x{rt:04x}'
        if rt == ALLOCATE_OK and ATTR_XOR_RELAYED in ra:
            ip, port = xor_addr_decode(ra[ATTR_XOR_RELAYED][0])
            life = struct.unpack('!I', ra[ATTR_LIFETIME][0])[0] if ATTR_LIFETIME in ra else None
            obs.update(relayed_ip=ip, relayed_port=port, lifetime=life)
            ok = ip == '127.0.0.1' and 40000 <= port <= 40015
            c.refresh(0)  # release allocation
        else:
            obs['error_code'] = err_code(ra)
    finally:
        c.close()
    results.append(dict(
        name='TURN-RT01-1 valid REST credential Allocate',
        expected='Allocate success, XOR-RELAYED-ADDRESS 127.0.0.1 port in 40000-40015',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))
    return obs


def case2_expired_credential(secret, results):
    obs = {}
    c = TurnClient(*make_cred(secret, expiry_offset=-3600))
    try:
        rt, ra = c.allocate()
        obs['response_type'] = f'0x{rt:04x}'
        obs['error_code'] = err_code(ra)
        obs['relayed_address_present'] = ATTR_XOR_RELAYED in ra
        ok = rt == ALLOCATE_ERR and obs['error_code'] in (401, 438) and not obs['relayed_address_present']
    finally:
        c.close()
    results.append(dict(
        name='TURN-RT01-2 expired-timestamp credential rejected',
        expected='Allocate error 401/438, no relayed address',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))


def case3_wrong_hmac(secret, results):
    obs = {}
    c = TurnClient(*make_cred(secret, corrupt_hmac=True))
    try:
        rt, ra = c.allocate()
        obs['response_type'] = f'0x{rt:04x}'
        obs['error_code'] = err_code(ra)
        obs['relayed_address_present'] = ATTR_XOR_RELAYED in ra
        ok = rt == ALLOCATE_ERR and obs['error_code'] in (401, 438) and not obs['relayed_address_present']
    finally:
        c.close()
    results.append(dict(
        name='TURN-RT01-3 wrong-HMAC credential rejected',
        expected='Allocate error 401/438, no relayed address',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))


def case4_user_quota(secret, results):
    username, password = make_cred(secret)
    clients, statuses = [], []
    obs = {}
    try:
        for i in range(5):
            c = TurnClient(username, password)
            clients.append(c)
            rt, ra = c.allocate()
            statuses.append({'attempt': i + 1,
                             'response_type': f'0x{rt:04x}',
                             'error_code': err_code(ra)})
        obs['allocations'] = statuses
        first4_ok = all(s['response_type'] == f'0x{ALLOCATE_OK:04x}' for s in statuses[:4])
        fifth = statuses[4]
        ok = first4_ok and fifth['response_type'] == f'0x{ALLOCATE_ERR:04x}' and fifth['error_code'] == 486
    finally:
        for c in clients:
            try:
                c.refresh(0)
            except Exception:
                pass
            c.close()
    results.append(dict(
        name='TURN-RT01-4 user-quota=4 enforced',
        expected='four concurrent Allocates succeed, fifth rejected with 486',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))


def case5_acl(secret, results):
    obs = {}
    ok_denied = ok_allowed = ok_echo = False
    c = TurnClient(*make_cred(secret))
    peer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    peer.bind((HOST, 0))
    peer.settimeout(2.0)
    peer_port = peer.getsockname()[1]
    try:
        rt, ra = c.allocate()
        if rt != ALLOCATE_OK:
            obs['allocate_error'] = err_code(ra)
            raise RuntimeError('allocation failed')
        relay_ip, relay_port = xor_addr_decode(ra[ATTR_XOR_RELAYED][0])
        obs['relayed'] = f'{relay_ip}:{relay_port}'

        rt, ra = c.create_permission('10.0.0.1')
        obs['denied_peer'] = {'response_type': f'0x{rt:04x}', 'error_code': err_code(ra)}
        ok_denied = rt == CREATEPERM_ERR and err_code(ra) == 403

        rt, ra = c.create_permission('127.0.0.1')
        obs['allowed_peer'] = {'response_type': f'0x{rt:04x}', 'error_code': err_code(ra)}
        ok_allowed = rt == CREATEPERM_OK

        if ok_allowed:
            payload = b'paranoid-echo-' + pysecrets.token_hex(4).encode()
            echo, from_peer = None, None
            for _ in range(3):
                c.send_indication('127.0.0.1', peer_port, payload)
                try:
                    data, src = peer.recvfrom(65535)
                except socket.timeout:
                    continue
                obs['peer_received_from'] = f'{src[0]}:{src[1]}'
                obs['peer_payload_match'] = data == payload
                peer.sendto(b'ECHO:' + data, src)
                echo, from_peer = c.recv_data_indication(timeout=3.0)
                break
            obs['data_indication_payload_ok'] = echo == b'ECHO:' + payload
            obs['data_indication_from_peer'] = list(from_peer) if (echo and from_peer) else None
            ok_echo = (obs.get('peer_payload_match') is True
                       and obs['data_indication_payload_ok']
                       and obs.get('peer_received_from') == f'{relay_ip}:{relay_port}')
        c.refresh(0)
    except Exception as exc:
        obs['exception'] = repr(exc)
    finally:
        peer.close()
        c.close()
    ok = ok_denied and ok_allowed and ok_echo
    results.append(dict(
        name='TURN-ACL02-5 peer ACL: denied 10.0.0.1 (403), loopback relay echo works',
        expected='CreatePermission 10.0.0.1 -> 403; 127.0.0.1 -> success; Send/Data echo through relay',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))


def case6_lifetime_and_expired_refresh(secret, results, case1_obs):
    obs = {'allocate_lifetime_from_case1': case1_obs.get('lifetime')}
    ok_life = ok_refresh = False
    c = TurnClient(*make_cred(secret, expiry_offset=8))
    try:
        t0 = time.monotonic()
        rt, ra = c.allocate(lifetime=600)
        if rt != ALLOCATE_OK:
            obs['allocate_error'] = err_code(ra)
            raise RuntimeError('short-cred allocation failed')
        life = struct.unpack('!I', ra[ATTR_LIFETIME][0])[0] if ATTR_LIFETIME in ra else None
        obs['requested_lifetime'] = 600
        obs['granted_lifetime'] = life
        ok_life = life is not None and life <= 60
        time.sleep(10)  # credential (expiry +8s) is now expired
        rt, ra = c.refresh(60)
        obs['refresh_after_expiry'] = {'response_type': f'0x{rt:04x}',
                                       'error_code': err_code(ra),
                                       'waited_s': round(time.monotonic() - t0, 1)}
        ok_refresh = rt == REFRESH_ERR and err_code(ra) in (401, 438)
        if not ok_refresh and rt == REFRESH_OK:
            # fallback: wait for stale-nonce window (<=90s total) and retry
            time.sleep(max(0, 70 - (time.monotonic() - t0)))
            rt, ra = c.refresh(60)
            obs['refresh_after_stale_nonce'] = {'response_type': f'0x{rt:04x}',
                                                'error_code': err_code(ra),
                                                'waited_s': round(time.monotonic() - t0, 1)}
            ok_refresh = rt == REFRESH_ERR and err_code(ra) in (401, 438)
    except Exception as exc:
        obs['exception'] = repr(exc)
    finally:
        c.close()
    ok = ok_life and ok_refresh
    results.append(dict(
        name='TURN-RT01-6 lifetime<=60 and expired-credential Refresh rejected',
        expected='Allocate LIFETIME<=60 despite requesting 600; Refresh with expired credential -> 401/438',
        observed=obs, result='PASS' if ok else 'FAIL', timestamp=now_iso()))


# ---------------------------------------------------------------- runner

def main():
    bin_sha = hashlib.sha256(TURNSERVER.read_bytes()).hexdigest()
    if bin_sha != EXPECTED_BIN_SHA:
        print(f'FATAL: turnserver sha256 mismatch: {bin_sha}', file=sys.stderr)
        return 2
    harness_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    git_head = subprocess.run(['git', '-C', str(WORKTREE), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True).stdout.strip()

    EVID.mkdir(parents=True, exist_ok=True)
    secret = pysecrets.token_hex(32)  # 64 hex chars, synthetic, never printed
    secret_file = EVID / 'turn-acceptance.secret'
    secret_file.write_text(secret)
    secret_file.chmod(0o600)

    log_file = EVID / 'private-turnserver.log'
    conf_lines = [
        'listening-ip=127.0.0.1', 'relay-ip=127.0.0.1', f'listening-port={PORT}',
        'min-port=40000', 'max-port=40015', f'realm={REALM}', 'fingerprint',
        'use-auth-secret', f'static-auth-secret={secret}',
        'user-quota=4', 'total-quota=16',
        'max-allocate-lifetime=60', 'stale-nonce=60', 'relay-threads=1', 'cli=0',
        'no-tls', 'no-stun', 'no-tcp-relay', 'no-multicast-peers', 'no-stdout-log',
        'simple-log', f'log-file={log_file}', 'verbose', 'syslog=0',
        f'pidfile={EVID / "turnserver.pid"}',
        'allow-loopback-peers', 'allowed-peer-ip=127.0.0.1',
        'denied-peer-ip=10.0.0.0-10.255.255.255',
    ]
    conf = EVID / 'acceptance.conf'
    conf.write_text('\n'.join(conf_lines) + '\n')
    conf.chmod(0o600)

    env = {**os.environ, 'LD_LIBRARY_PATH': str(BUILD / 'lib')}
    proc = subprocess.Popen([str(TURNSERVER), '-c', str(conf)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    started = now_iso()
    try:
        # readiness probe: unauthenticated Allocate must draw a 401
        ready = False
        probe = TurnClient('probe', 'probe')
        for _ in range(20):
            if proc.poll() is not None:
                raise RuntimeError('turnserver exited during startup')
            try:
                rt, code = probe.learn_nonce()
                if code == 401:
                    ready = True
                    break
            except TimeoutError:
                time.sleep(0.25)
        probe.close()
        if not ready:
            raise RuntimeError('turnserver did not answer on 127.0.0.1:%d' % PORT)

        c1_obs = case1_valid_allocate(secret, results)
        case2_expired_credential(secret, results)
        case3_wrong_hmac(secret, results)
        case4_user_quota(secret, results)
        case5_acl(secret, results)
        case6_lifetime_and_expired_refresh(secret, results, c1_obs)
    except Exception as exc:
        results.append(dict(name='harness-fatal', expected='clean run',
                            observed={'exception': repr(exc)}, result='FAIL',
                            timestamp=now_iso()))
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)

    report = dict(
        gates=['TURN-RT01', 'TURN-ACL02'],
        scope='loopback-only local acceptance; no public network, no physical phones, no systemd secret delivery',
        started=started, finished=now_iso(),
        binding=dict(turnserver_sha256=bin_sha,
                     harness_sha256=harness_sha,
                     git_head=git_head,
                     turnserver_path=str(TURNSERVER),
                     listener='127.0.0.1:%d/udp' % PORT,
                     relay_range='40000-40015'),
        cases=results,
        overall='PASS' if results and all(r['result'] == 'PASS' for r in results) else 'FAIL',
    )
    (EVID / 'results.json').write_text(json.dumps(report, indent=2) + '\n')

    lines = ['# ParanoID TURN local acceptance — %s' % started,
             '', 'Gates: TURN-RT01, TURN-ACL02. Loopback-only (127.0.0.1:%d, relay 40000-40015).' % PORT,
             '', '| Case | Result |', '|---|---|']
    for r in results:
        lines.append(f"| {r['name']} | {r['result']} |")
    lines += ['', f"Overall: **{report['overall']}**",
              '', f'turnserver sha256: `{bin_sha}`',
              f'harness sha256: `{harness_sha}`',
              f'git HEAD: `{git_head}`',
              '', 'NOT covered: public-network reachability, physical phones/real clients, '
              'systemd secret delivery, TLS, IPv6.']
    (EVID / 'summary.md').write_text('\n'.join(lines) + '\n')

    print(json.dumps({'overall': report['overall'],
                      'cases': [{'name': r['name'], 'result': r['result']} for r in results],
                      'results_json': str(EVID / 'results.json')}, indent=2))
    return 0 if report['overall'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
