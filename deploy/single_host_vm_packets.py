#!/usr/bin/env python3
"""Finite owned-guest packet observations. Importing this module opens nothing.

Only the separately reviewed NIC-less VM driver calls these fixed helpers. The
production kit must exclude this file. Private credentials arrive on stdin and
never appear in argv, output, errors or saved SDP. No arbitrary target/port exists.
"""
import asyncio
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import struct
import time

PUBLIC = '157.180.49.125'
CLIENT = '65.108.43.251'
BOGON = '10.55.0.1'
TARGETS = {'local': (PUBLIC, 40116), 'ipv6': ('::1', 40116),
           'bogon': (BOGON, 40116), 'other': (CLIENT, 40116)}
MARKER = re.compile(r'owned-[0-9a-f]{32}')
PROGRESS = {}


def validate_request(value):
    if not isinstance(value, dict):
        raise ValueError('fixed owned packet request required')
    mode = value.get('mode')
    fields = {'udp-send': {'mode', 'target', 'marker'},
              'sink': {'mode', 'target', 'marker'},
              'cli': {'mode', 'location'},
              'media': {'mode', 'transport', 'credential'},
              'peer-denial': {'mode', 'credential', 'marker'},
              'baseline': {'mode', 'credential'},
              'expiry': {'mode', 'credential', 'control_credential'}}
    if mode not in fields or set(value) != fields[mode]:
        raise ValueError('fixed packet operation and exact fields required')
    if 'target' in value and value['target'] not in TARGETS:
        raise ValueError('fixed owned target required')
    if 'marker' in value and (not isinstance(value['marker'], str) or not MARKER.fullmatch(value['marker'])):
        raise ValueError('bounded unique synthetic marker required')
    if mode == 'cli' and value['location'] not in ('root', 'client'):
        raise ValueError('fixed console observation location required')
    if mode == 'media' and value['transport'] not in ('udp', 'tcp'):
        raise ValueError('fixed relay transport required')
    for name in ('credential', 'control_credential'):
        if name not in value:
            continue
        credential = value[name]
        if (not isinstance(credential, dict) or set(credential) != {'username', 'password', 'expires'}
                or any(not isinstance(credential[f], str) or not 1 <= len(credential[f]) <= 256
                       or any(ord(c) < 33 or ord(c) > 126 for c in credential[f]) for f in ('username', 'password'))
                or type(credential['expires']) is not int or credential['expires'] < 1):
            raise ValueError('bounded private temporary credentials required')
    return value


def denial_observed(v):
    return (v.get('positive_received') == 1 and v.get('negative_received') == 0
            and v.get('positive_attempted') == 1 and v.get('negative_attempted') == 3
            and type(v.get('window_seconds')) in (int, float) and 1 <= v['window_seconds'] <= 5
            and v.get('same_target') is True and v.get('positive_uid') == 1903
            and v.get('negative_uid') == 1902 and v.get('sink_exit') == 0)


def media_observed(value):
    peers = value.get('peers')
    return (isinstance(peers, list) and len(peers) == 2 and all(
        p.get('codec') == 'audio/opus' and p.get('frames', 0) >= 40 and p.get('samples', 0) >= 38400
        and type(p.get('energy')) in (float, int) and math.isfinite(p['energy']) and p['energy'] > 0
        and p.get('local_type') == p.get('remote_type') == 'relay'
        and p.get('local_ip') == p.get('remote_ip') == PUBLIC
        and type(p.get('local_port')) is int and type(p.get('remote_port')) is int
        and 40000 <= p['local_port'] <= 40015 and 40000 <= p['remote_port'] <= 40015 for p in peers))


def guest_worker_boundary(request):
    uid = os.geteuid()
    if (uid not in (1902, 1903) or os.getresuid() != (uid, uid, uid)
            or Path(__file__).resolve() != Path('/opt/voice-fixture/fixture-kit/single_host_vm_packets.py')
            or Path('/sys/class/dmi/id/product_name').read_text().strip() != 'ParanoID Voice Fixture v1'
            or any(Path('/sys/class/net').glob('*/device'))
            or any(int(p.read_text(), 16) >> 16 == 2 for p in Path('/sys/bus/pci/devices').glob('*/class'))):
        raise ValueError('fixed unprivileged NIC-less guest worker required')
    if uid == 1902 and request['mode'] != 'udp-send':
        raise ValueError('relay UID helper may only perform a fixed owned denial send')
    # Root namespace links differ from the client. The parent also checks the
    # actual current-boot boundary and network namespace inodes before launch.
    names = {p.name for p in Path('/sys/class/net').iterdir()}
    if names not in ({'lo', 'vr-client'}, {'lo', 'vr-relay'}):
        raise ValueError('exact guest network namespace inventory required')
    wants_root = request['mode'] == 'udp-send' or (request['mode'] == 'sink' and request['target'] in ('local', 'ipv6'))
    if request['mode'] == 'cli':
        wants_root = request['location'] == 'root'
    if names != ({'lo', 'vr-relay'} if wants_root else {'lo', 'vr-client'}):
        raise ValueError('worker must use its fixed reviewed namespace')


def udp_send(request):
    target = request['target']
    negative = os.geteuid() == 1902
    address, port = TARGETS[target]
    family = socket.AF_INET6 if target == 'ipv6' else socket.AF_INET
    source = '::1' if family == socket.AF_INET6 else PUBLIC
    source_port = 40117 if target == 'other' else 40015
    marker = (request['marker'] + ('-negative' if negative else '-positive')).encode()
    count = 3 if negative else 1
    with socket.socket(family, socket.SOCK_DGRAM) as stream:
        stream.bind((source, source_port))
        for _ in range(count):
            stream.sendto(marker, (address, port))
            time.sleep(0.02)
    return {'attempted': count, 'uid': os.geteuid(), 'target': target,
            'source_port': source_port, 'marker_sha256': hashlib.sha256(marker).hexdigest()}


def sink(request):
    address = TARGETS[request['target']]
    family = socket.AF_INET6 if request['target'] == 'ipv6' else socket.AF_INET
    counts = {'positive': 0, 'negative': 0, 'other': 0}
    PROGRESS['sink_counts'] = counts
    # READY is a private control message; only final measurements are published.
    with socket.socket(family, socket.SOCK_DGRAM) as stream:
        stream.bind(address)
        print(json.dumps({'ready': True, 'target': request['target']}), flush=True)
        stream.settimeout(0.1)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                data, _ = stream.recvfrom(1024)
            except socket.timeout:
                continue
            kind = next((name for name in ('positive', 'negative')
                         if data == (request['marker'] + '-' + name).encode()), 'other')
            counts[kind] += 1
            if kind == 'positive':
                print(json.dumps({'positive_received': counts[kind], 'target': request['target']}), flush=True)
    return {'counts': counts, 'window_seconds': 5.0, 'target': request['target']}


def console_probe(request):
    address = '127.0.0.1' if request['location'] == 'root' else PUBLIC
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as stream:
        stream.settimeout(1)
        result = stream.connect_ex((address, 5766))
    # Either refusal or timeout alone does not establish CLI configuration.
    # The root runner independently observes sockets and exact unit/config.
    return {'location': request['location'], 'connect_errno': result, 'connected': result == 0}


async def media(request):
    import av
    import numpy as np
    from aiortc import AudioStreamTrack, RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription, RTCRtpSender

    class Tone(AudioStreamTrack):
        def __init__(self, frequency):
            super().__init__()
            self.frequency, self.samples, self.started = frequency, 0, None

        async def recv(self):
            if self.started is None:
                self.started = time.monotonic()
            await asyncio.sleep(max(0, self.started + self.samples / 48000 - time.monotonic()))
            samples = (6000 * np.sin(2 * np.pi * self.frequency
                       * (np.arange(960, dtype=np.float64) + self.samples) / 48000)).astype(np.int16)
            frame = av.AudioFrame.from_ndarray(samples.reshape(1, -1), format='s16', layout='mono')
            frame.sample_rate, frame.pts, frame.time_base = 48000, self.samples, Fraction(1, 48000)
            self.samples += 960
            return frame

    credential = request['credential']
    config = RTCConfiguration(iceServers=[RTCIceServer(
        urls='turn:' + PUBLIC + ':34781?transport=' + request['transport'],
        username=credential['username'], credential=credential['password'])])
    peers = [RTCPeerConnection(config), RTCPeerConnection(config)]
    observations = [{'frames': 0, 'samples': 0, 'energy': 0.0} for _ in peers]
    PROGRESS['decoded_media'] = observations
    tasks = []

    async def consume(track, observation):
        while True:
            frame = await track.recv()
            samples = frame.to_ndarray().astype(np.float64)
            observation['frames'] += 1
            observation['samples'] += frame.samples
            observation['energy'] += float(np.mean(samples * samples))

    def relay_description(description):
        lines = description.sdp.splitlines()
        candidates = [line for line in lines if line.startswith('a=candidate:') and ' typ relay ' in line]
        if not candidates:
            raise ValueError('actual TURN relay candidate required')
        lines = [line for line in lines if not line.startswith('a=candidate:') or line in candidates]
        return RTCSessionDescription(sdp='\r\n'.join(lines) + '\r\n', type=description.type)

    try:
        for index, peer in enumerate(peers):
            peer.addTrack(Tone(440 + index * 220))
            transceiver = peer.getTransceivers()[0]
            transceiver.setCodecPreferences([c for c in RTCRtpSender.getCapabilities('audio').codecs
                                             if c.mimeType.lower() == 'audio/opus'])
            def on_track(track, observation=observations[index]):
                tasks.append(asyncio.create_task(consume(track, observation)))
            peer.on('track', on_track)
        await peers[0].setLocalDescription(await peers[0].createOffer())
        await peers[1].setRemoteDescription(relay_description(peers[0].localDescription))
        await peers[1].setLocalDescription(await peers[1].createAnswer())
        await peers[0].setRemoteDescription(relay_description(peers[1].localDescription))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if any(task.done() for task in tasks):
                for task in tasks:
                    if task.done():
                        task.result()
            if all(o['frames'] >= 100 for o in observations):
                break
            await asyncio.sleep(0.1)
        for peer, observation in zip(peers, observations):
            receiver = peer.getReceivers()[0]
            codecs = receiver._RTCRtpReceiver__codecs
            if {codec.mimeType.lower() for codec in codecs.values()} != {'audio/opus'}:
                raise ValueError('actual negotiated Opus decoder required')
            connection = receiver.transport.transport._connection
            nominated = list(connection._nominated.values())
            if len(nominated) != 1:
                raise ValueError('one actual nominated media component required')
            pair = nominated[0]
            observation['codec'] = 'audio/opus'
            for name in ('local', 'remote'):
                candidate = getattr(pair, name + '_candidate')
                observation.update({name + '_type': candidate.type,
                                    name + '_ip': candidate.host, name + '_port': candidate.port})
        result = {'transport': request['transport'], 'peers': observations}
        if not media_observed(result):
            raise ValueError('actual decoded bidirectional relay Opus observation failed')
        return result
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(peer.close() for peer in peers))


class ManualTurn:
    """Real upstream protocol, no automatic allocation/channel refresh."""
    def __init__(self, credential):
        self.credential = credential
        self.protocol = None
        self.events = []
        self.address = None
        self.received = asyncio.Queue()

    async def start(self):
        from aioice.turn import TurnClientUdpProtocol
        loop = asyncio.get_running_loop()
        _, self.protocol = await loop.create_datagram_endpoint(
            lambda: TurnClientUdpProtocol((PUBLIC, 34781), self.credential['username'],
                self.credential['password'], 60, 500), remote_addr=(PUBLIC, 34781),
            local_addr=(CLIENT, 0))
        owner = self
        class Receiver(asyncio.DatagramProtocol):
            def datagram_received(self, data, address):
                owner.received.put_nowait((data, address))
        self.protocol.receiver = Receiver()
        return self

    async def control(self, method, attributes):
        from aioice import stun
        request = stun.Message(message_method=getattr(stun.Method, method), message_class=stun.Class.REQUEST)
        request.attributes.update(attributes)
        started, wall = time.monotonic_ns(), time.time_ns()
        event = {'method': method, 'started_monotonic_ns': started, 'started_wall_ns': wall,
                 'requested_lifetime': attributes.get('LIFETIME')}
        self.events.append(event)
        PROGRESS.setdefault('control_events', []).append(event)
        try:
            response, _ = await asyncio.wait_for(self.protocol.request_with_retry(request), 3)
            event.update(code=200, lifetime=response.attributes.get('LIFETIME'))
            if 'XOR-RELAYED-ADDRESS' in response.attributes:
                self.address = response.attributes['XOR-RELAYED-ADDRESS']
                if self.address[0] != PUBLIC or not 40000 <= self.address[1] <= 40015:
                    raise ValueError('exact owned allocation address required')
                self.protocol.relayed_address = self.address
                event['relay_port'] = self.address[1]
        except stun.TransactionFailed as error:
            event['code'] = error.response.attributes['ERROR-CODE'][0]
        finally:
            event['finished_monotonic_ns'] = time.monotonic_ns()
        return event

    async def allocate(self, lifetime=60):
        from aioice.turn import UDP_TRANSPORT
        fields = {'REQUESTED-TRANSPORT': UDP_TRANSPORT}
        if lifetime is not None:
            fields['LIFETIME'] = lifetime
        return await self.control('ALLOCATE', fields)

    async def bind(self, address):
        result = await self.control('CHANNEL_BIND', {'CHANNEL-NUMBER': 0x4000, 'XOR-PEER-ADDRESS': address})
        if result['code'] != 200:
            raise ValueError('actual owned TURN channel positive control failed')
        self.protocol.channel_to_peer[0x4000] = address

    def send(self, marker):
        self.protocol._send(struct.pack('!HH', 0x4000, len(marker)) + marker)

    async def receive_marker(self, marker, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                data, _ = await asyncio.wait_for(self.received.get(), deadline - time.monotonic())
            except asyncio.TimeoutError:
                return False
            if data == marker:
                return True
        return False

    async def close(self):
        if self.protocol is not None:
            # Deletion may be refused after expiry; retain that actual outcome,
            # never reauthenticate with another identity on the same allocation.
            if self.address is not None:
                await self.control('REFRESH', {'LIFETIME': 0})
            self.protocol.transport.close()
            self.protocol = None


async def baseline(request):
    client = await ManualTurn(request['credential']).start()
    try:
        allocated = await client.allocate(0)
        await asyncio.sleep(max(0, request['credential']['expires'] + 1.1 - time.time()))
        refreshed = await client.control('REFRESH', {'LIFETIME': 600})
        return {'events': client.events, 'zero_request_bypassed_cap': allocated.get('lifetime', 0) > 60,
                'expired_cached_refresh_accepted': refreshed['code'] == 200,
                'credential_expiry': request['credential']['expires']}
    finally:
        await client.close()


async def expiry(request):
    credential = request['credential']
    if not 2 <= credential['expires'] - time.time() <= 10:
        raise ValueError('finite fresh synthetic real-wall-clock expiry window required')
    clients = []
    async def client(c):
        value = await ManualTurn(c).start()
        clients.append(value)
        return value
    try:
        caps = []
        for lifetime in (None, 599, 600):
            probe = await client(request['control_credential'])
            caps.append(await probe.allocate(lifetime))
            await probe.close()
        first = await client(credential)
        allocated = await first.allocate(0)
        second = await client(request['control_credential'])
        second_allocated = await second.allocate(1)
        wrong = await client({**request['control_credential'], 'password': 'synthetic-wrong-hmac'})
        wrong_allocate = await wrong.allocate()
        await wrong.close()
        capped_refresh = await first.control('REFRESH', {'LIFETIME': 600})
        await first.bind(second.address)
        await second.bind(first.address)
        first.send(b'owned-before-expiry')
        before_received = await second.receive_marker(b'owned-before-expiry', 1)
        await asyncio.sleep(max(0, credential['expires'] + 1.1 - time.time()))
        expired_new = await client(credential)
        expired_allocate = await expired_new.allocate()
        refresh = await first.control('REFRESH', {'LIFETIME': 600})
        permission = await first.control('CREATE_PERMISSION', {'XOR-PEER-ADDRESS': second.address})
        channel = await first.control('CHANNEL_BIND', {'CHANNEL-NUMBER': 0x4001, 'XOR-PEER-ADDRESS': second.address})
        first.send(b'owned-residual-channeldata')
        residual_received = await second.receive_marker(b'owned-residual-channeldata', 1)
        # Live positive receiver gets a genuine refresh well before its own lease
        # ends. The expired sender receives no automatic refresh at any point.
        await asyncio.sleep(max(0, allocated['finished_monotonic_ns'] / 1e9 + 40 - time.monotonic()))
        second_refresh = await second.control('REFRESH', {'LIFETIME': 60})
        margin = max((e['finished_monotonic_ns'] - e['started_monotonic_ns']) / 1e9
                     for c in clients for e in c.events)
        final_wall = credential['expires'] + 60 + 1 + margin
        await asyncio.sleep(max(0, final_wall - time.time()))
        first.send(b'owned-after-drain-bound')
        late_received = await second.receive_marker(b'owned-after-drain-bound', 1)
        return {'events': [event for c in clients for event in c.events],
                'credential_expiry': credential['expires'], 'drain_observed_wall': time.time(),
                'measured_round_trip_upper_bound_seconds': margin,
                'expired_allocation_port': first.address[1],
                'expiry_seconds_simulated': False, 'issuer_1200_seconds_elapsed': False,
                'before_received': before_received, 'residual_received': residual_received,
                'late_received': late_received, 'receiver_refreshed': second_refresh['code'] == 200,
                'expired_allocate_rejected': expired_allocate['code'] == 401,
                'wrong_password_rejected': wrong_allocate['code'] == 401,
                'cached_controls_rejected': all(e['code'] == 401 for e in (refresh, permission, channel)),
                'lifetime_clamped': allocated.get('lifetime') == second_allocated.get('lifetime') == 60
                    and all(e['code'] == 200 and e.get('lifetime') == 60 for e in caps),
                'refresh_capped': capped_refresh.get('lifetime') == 60}
    finally:
        for c in clients:
            await c.close()


async def peer_denial(request):
    client = await ManualTurn(request['credential']).start()
    try:
        allocated = await client.allocate()
        if allocated['code'] != 200:
            raise ValueError('actual positive allocation required')
        await client.bind(TARGETS['local'])
        for _ in range(3):
            client.send((request['marker'] + '-negative').encode())
            await asyncio.sleep(0.02)
        return {'attempted': 3, 'events': client.events, 'target': 'local', 'via_real_relay': True}
    finally:
        await client.close()


def run(request):
    validate_request(request)
    guest_worker_boundary(request)
    import sys
    sys.path.insert(0, '/opt/voice-fixture/python-media')
    sync = {'udp-send': udp_send, 'sink': sink, 'cli': console_probe}
    if request['mode'] in sync:
        return sync[request['mode']](request)
    operation = {'media': media, 'baseline': baseline, 'expiry': expiry, 'peer-denial': peer_denial}[request['mode']]
    return asyncio.run(asyncio.wait_for(operation(request), 110))


if __name__ == '__main__':
    import sys
    try:
        raw = sys.stdin.buffer.readline(65537)
        if len(raw) > 65536 or not raw.endswith(b'\n') or len(sys.argv) != 1:
            raise ValueError('fixed bounded private request required')
        print(json.dumps(run(json.loads(raw)), sort_keys=True), flush=True)
    except Exception as error:
        # Never stringify protocol errors: they may contain temporary credentials.
        print(json.dumps({'error_class': type(error).__name__, 'observations': PROGRESS}), flush=True)
        raise SystemExit(1) from None
