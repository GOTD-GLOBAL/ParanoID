"""Actual JNI/TLS/Olm call controller paired with aiortc for Android app tests.

The retained server and VoicePeerBridge run in an isolated local fixture.
Only the host's own SDP gets the emulator loopback mapping before native signing.
This endpoint is a test driver, never included in the application APK.
"""
import argparse
import asyncio
import json
from pathlib import Path
import socket
import time

import aioice.ice
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription, RTCRtpSender

from test_voice_media import Tone


class Peer:
    def __init__(self, runtime, evidence):
        self.runtime = runtime
        self.evidence = evidence
        self.lock = asyncio.Lock()
        self.events = []
        self.states = []
        self.view = {}
        self.pc = None
        self.generation = 0
        self.frames = 0
        self.samples = 0
        self.receiver_tasks = []
        self.runs = []
        self.started = time.monotonic()

    def rpc(self, operation, values):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(20)
            sock.connect(self.runtime['rpc_socket'])
            payload = values['contact'] if operation == 'pair' else values
            sock.sendall((json.dumps(dict(operation=operation, value=payload)) + '\n').encode())
            data = sock.makefile('rb').readline(200000)
        result = json.loads(data)
        if 'error' in result:
            raise RuntimeError(str(result))
        return result

    async def exchange(self, operation, **values):
        self.view = await asyncio.to_thread(self.rpc, operation, values)
        self.events.extend(self.view.pop('media_commands', []))

    async def save_media(self):
        if not self.pc:
            return
        stats = await self.pc.getStats()
        report = dict(generation=self.generation, connection=self.pc.connectionState,
                      decoded_frames=self.frames, decoded_samples=self.samples,
                      stats=[dict(vars(v), timestamp=v.timestamp.isoformat()) for v in stats.values()])
        self.runs.append(report)
        (self.evidence / 'media-runs.json').write_text(json.dumps(self.runs, indent=2, default=str))

    async def close(self):
        if self.pc:
            await self.save_media()
            pc = self.pc
            self.pc = None
            await pc.close()
        for task in self.receiver_tasks:
            task.cancel()
        self.receiver_tasks = []

    async def make_pc(self, generation):
        await self.close()
        self.generation = generation
        self.frames = self.samples = 0
        pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.pc = pc
        pc.addTrack(Tone())
        opus = [c for c in RTCRtpSender.getCapabilities('audio').codecs if c.mimeType.lower() == 'audio/opus']
        for transceiver in pc.getTransceivers():
            transceiver.setCodecPreferences(opus)

        @pc.on('track')
        def on_track(track):
            async def consume():
                while True:
                    frame = await track.recv()
                    self.frames += 1
                    self.samples += frame.samples
            self.receiver_tasks.append(asyncio.create_task(consume()))

        @pc.on('connectionstatechange')
        def state():
            if self.pc is pc:
                value = pc.connectionState
                if value in ('connected', 'disconnected', 'failed'):
                    self.states.append((generation, value))
        return pc

    async def local(self, pc, kind):
        description = await (pc.createOffer() if kind == 'offer' else pc.createAnswer())
        await pc.setLocalDescription(description)
        sdp = '\r\n'.join(line for line in pc.localDescription.sdp.replace('127.0.0.1', '10.0.2.2').splitlines()
                          if not line.startswith('a=fingerprint:') or line.startswith('a=fingerprint:sha-256 ')) + '\r\n'
        # These are the actual self-owned media parameters. The same strict
        # native parser as Android validates them before Olm encryption/signing.
        fields = {}
        for line in sdp.splitlines():
            if line.startswith('a=fingerprint:sha-256 '):
                fields['fingerprint'] = line[22:].replace(':', '').lower()
            elif line.startswith('a=ice-ufrag:'):
                fields['ice_ufrag'] = line[12:]
            elif line.startswith('a=ice-pwd:'):
                fields['ice_pwd'] = line[10:]
        (self.evidence / f'host-{self.generation}-{kind}.sdp').write_text(sdp)
        await self.exchange('local_description', generation=self.generation, sdp=sdp, **fields)

    async def drain(self):
        for _ in range(64):
            if self.events:
                event = self.events.pop(0)
                operation = event['operation']
                if operation in ('offer', 'answer_offer'):
                    pc = await self.make_pc(event['generation'])
                    if operation == 'answer_offer':
                        (self.evidence / f'android-{self.generation}-offer.sdp').write_text(event['sdp'])
                        await pc.setRemoteDescription(RTCSessionDescription(event['sdp'], 'offer'))
                    await self.local(pc, 'offer' if operation == 'offer' else 'answer')
                elif operation == 'set_answer' and self.pc and event['generation'] == self.generation:
                    (self.evidence / f'android-{self.generation}-answer.sdp').write_text(event['sdp'])
                    await self.pc.setRemoteDescription(RTCSessionDescription(event['sdp'], 'answer'))
                elif operation == 'close':
                    await self.close()
            elif self.states:
                generation, state = self.states.pop(0)
                await self.exchange('media_state', generation=generation, state=state)
            else:
                return
        raise RuntimeError('fixture command queue exceeded bound')

    async def command(self, command, values):
        async with self.lock:
            await self.exchange(command, **values)
            await self.drain()
            await self.exchange('view')
            await self.drain()
            result = dict(self.view)
            result['media'] = dict(connection=self.pc.connectionState if self.pc else 'closed',
                                   generation=self.generation, decoded_frames=self.frames,
                                   decoded_samples=self.samples)
            if command == 'view' and self.pc:
                stats = await self.pc.getStats()
                result['media']['stats'] = [dict(vars(v), timestamp=v.timestamp.isoformat()) for v in stats.values()]
            return result

    async def poll(self):
        while True:
            await self.command('view', {})
            await asyncio.sleep(.1)


async def run(args):
    evidence = Path(args.evidence_dir)
    evidence.mkdir(parents=True, exist_ok=False)
    aioice.ice.get_host_addresses = lambda use_ipv4, use_ipv6: ['127.0.0.1']
    peer = Peer(json.loads(Path(args.runtime).read_text()), evidence)

    async def request(reader, writer):
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            length = next(int(line.split(b':', 1)[1]) for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:'))
            if not 0 < length < 65536:
                raise ValueError('request bound')
            value = json.loads(await asyncio.wait_for(reader.readexactly(length), 5))
            operation = value.pop('operation')
            answer = await peer.command(operation, value)
        except Exception as error:
            answer = dict(error=type(error).__name__, detail=str(error))
        body = json.dumps(answer, default=str).encode()
        writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
        await writer.drain()
        writer.close()

    server = await asyncio.start_server(request, '127.0.0.1', args.port)
    print(json.dumps(dict(port=args.port, boundary='owned loopback test driver; real app signaling and native media')), flush=True)
    try:
        async with server:
            await asyncio.gather(server.serve_forever(), peer.poll())
    finally:
        await peer.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--evidence-dir', required=True)
    parser.add_argument('--port', type=int, default=18871)
    asyncio.run(run(parser.parse_args()))
