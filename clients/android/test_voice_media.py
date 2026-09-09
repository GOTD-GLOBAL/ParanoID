"""Real Android libwebrtc <-> aiortc Opus audio; owned emulator instrumentation only.

Run with the separately installed voice instrumentation APK and adb forward
tcp:18869 tcp:8869. SDP travels through this test control socket, so this proves
media-engine interoperability; the application E2EE control fixture is separate.
"""
import argparse
import asyncio
from fractions import Fraction
import json
from pathlib import Path
import time
import urllib.request

import aioice.ice
import av
import numpy as np
from aiortc import AudioStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription, RTCRtpSender


class Tone(AudioStreamTrack):
    def __init__(self, frequency=440):
        super().__init__()
        self.frequency = frequency
        self.samples = 0
        self.started = None

    async def recv(self):
        if self.started is None:
            self.started = time.monotonic()
        await asyncio.sleep(max(0, self.started + self.samples / 48000 - time.monotonic()))
        positions = np.arange(960, dtype=np.float64) + self.samples
        samples = (6000 * np.sin(2 * np.pi * self.frequency * positions / 48000)).astype(np.int16)
        frame = av.AudioFrame.from_ndarray(samples.reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate = 48000
        frame.pts = self.samples
        frame.time_base = Fraction(1, 48000)
        self.samples += 960
        return frame


def rpc(url, command, **values):
    request = urllib.request.Request(url, json.dumps(dict(command=command, **values)).encode(),
                                     {"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)
    if "fixture_error" in result:
        raise RuntimeError(result["fixture_error"])
    return result


async def wait_status(url, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = await asyncio.to_thread(rpc, url, "status")
        if last.get("error"):
            raise AssertionError(last["error"])
        if predicate(last):
            return last
        await asyncio.sleep(0.1)
    raise AssertionError("Android media state timed out: " + json.dumps(last))


async def run(args):
    evidence = Path(args.evidence_dir)
    evidence.mkdir(parents=True, exist_ok=True)
    # Test-only loopback ICE bind. Android sees host loopback as10.0.2.2. This
    # mapping belongs only to the isolated harness and precedes any app signing.
    aioice.ice.get_host_addresses = lambda use_ipv4, use_ipv6: ["127.0.0.1"]
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    tone = Tone()
    sender = pc.addTrack(tone)
    opus = [c for c in RTCRtpSender.getCapabilities("audio").codecs if c.mimeType.lower() == "audio/opus"]
    for transceiver in pc.getTransceivers():
        transceiver.setCodecPreferences(opus)
    received = []
    receiver_tasks = []

    @pc.on("track")
    def on_track(track):
        async def consume():
            while True:
                frame = await track.recv()
                pcm = frame.to_ndarray().astype(np.float64)
                if frame.layout.name == "stereo" and pcm.shape[0] == 1:
                    pcm = pcm.reshape(-1, 2)[:, 0]
                else:
                    pcm = pcm.reshape(-1)
                n = np.arange(len(pcm))
                amplitude = 2 * abs(np.dot(pcm, np.exp(-2j * np.pi * 880 * n / frame.sample_rate))) / len(pcm)
                received.append(dict(time=time.monotonic(), samples=len(pcm), rate=frame.sample_rate,
                                     rms=float(np.sqrt(np.mean(pcm * pcm))), amplitude_880=float(amplitude)))
        receiver_tasks.append(asyncio.create_task(consume()))

    result = {"boundary": "real Android native libwebrtc and aiortc; synthetic PCM; test-only SDP control",
              "third_party_stun_turn": False, "physical_microphone_quality": "NOT RUN"}
    start_values = {"turn": json.loads(Path(args.turn_credentials).read_text())} if args.turn_credentials else {}
    result["isolated_turn_relay"] = bool(start_values)
    try:
        idle = await asyncio.to_thread(rpc, args.url, "status")
        result["idle"] = idle
        assert idle["capture_starts"] == 0, "Idle instrumentation captured microphone"
        await asyncio.to_thread(rpc, args.url, "offer", **start_values)
        offer = await wait_status(args.url, lambda s: s["local_type"] == "offer" and s["local_sdp"])
        (evidence / "android-offer.sdp").write_text(offer["local_sdp"])
        await pc.setRemoteDescription(RTCSessionDescription(offer["local_sdp"], "offer"))
        await pc.setLocalDescription(await pc.createAnswer())
        host_address = "127.0.0.1" if args.turn_credentials else "10.0.2.2"
        answer = "\r\n".join(line for line in pc.localDescription.sdp.replace("127.0.0.1", host_address).splitlines()
                              if not line.startswith("a=fingerprint:") or line.startswith("a=fingerprint:sha-256 ")) + "\r\n"
        (evidence / "aiortc-answer.sdp").write_text(answer)
        await asyncio.to_thread(rpc, args.url, "set_answer", sdp=answer)
        connected = await wait_status(args.url, lambda s: s["connected"] and s["decoded_frames"] > 48000)
        await asyncio.sleep(3)
        unmuted = [r for r in received if r["time"] > time.monotonic() - 2]
        assert len(unmuted) >= 40, "Not enough decoded Android Opus frames"
        assert np.median([r["rms"] for r in unmuted]) > 100, "Android audio decoded as silence"
        assert np.median([r["amplitude_880"] for r in unmuted]) > 100, "880Hz Android test tone absent"
        android = await asyncio.to_thread(rpc, args.url, "status")
        assert android["decoded_rms"] > 100 and android["decoded_440_amplitude"] > 100, "440Hz host tone absent on Android"
        before_mute = time.monotonic()
        await asyncio.to_thread(rpc, args.url, "mute", muted=True)
        await asyncio.sleep(3)
        muted = [r for r in received if r["time"] > before_mute + 1.5]
        # Disabling the actual libwebrtc track may stop RTP/capture altogether.
        # Silence frames and no frames are both valid, provided the peer stays
        # connected and the reverse audio path continues to decode.
        muted_android = await asyncio.to_thread(rpc, args.url, "status")
        assert pc.connectionState == "connected" and muted_android["connected"], "Mute disconnected the call"
        assert muted_android["decoded_frames"] > android["decoded_frames"], "Reverse audio stopped during mute"
        assert not muted or np.median([r["rms"] for r in muted]) < 50, "Mute still transmits tone"
        before_unmute = time.monotonic()
        await asyncio.to_thread(rpc, args.url, "mute", muted=False)
        await asyncio.sleep(3)
        resumed = [r for r in received if r["time"] > before_unmute + 1]
        assert len(resumed) >= 20 and np.median([r["amplitude_880"] for r in resumed]) > 100, "Unmute did not restore tone"
        await asyncio.to_thread(rpc, args.url, "speaker", speaker=True)
        await asyncio.to_thread(rpc, args.url, "speaker", speaker=False)
        result["android"] = await asyncio.to_thread(rpc, args.url, "status")
        result["android_stats"] = await asyncio.to_thread(rpc, args.url, "stats")
        if args.turn_credentials:
            stats_map = {entry["id"]: entry for entry in result["android_stats"]["stats"]}
            selected = [entry for entry in stats_map.values() if entry["type"] == "transport"
                        and "selectedCandidatePairId" in entry]
            assert selected, "No selected TURN candidate pair"
            pair = stats_map[selected[0]["selectedCandidatePairId"]]
            assert stats_map[pair["localCandidateId"]]["candidateType"] == "relay", "Media bypassed TURN relay"
        stats = await pc.getStats()
        result["aiortc_stats"] = [dict(vars(v), timestamp=v.timestamp.isoformat()) for v in stats.values()]
        assert pc.connectionState == "connected", "Host DTLS/ICE not connected"
        assert any(v.type == "inbound-rtp" and v.packetsReceived > 40 for v in stats.values()), "No actual received RTP packets"
        result["frames"] = len(received)
        result["unmuted_rms_median"] = float(np.median([r["rms"] for r in unmuted]))
        result["mute_received_frames"] = len(muted)
        result["muted_rms_median"] = float(np.median([r["rms"] for r in muted])) if muted else 0.0
        result["resumed_880_amplitude_median"] = float(np.median([r["amplitude_880"] for r in resumed]))
        await asyncio.to_thread(rpc, args.url, "close")
        closed = await wait_status(args.url, lambda s: s["capture_stops"] >= s["capture_starts"]
                                   and s["close_completions"] >= 1 and not s["connected"]
                                   and s["audio_mode"] == idle["audio_mode"] and s["speaker"] == idle["speaker"])
        capture_count = closed["capture_frames"]
        await asyncio.sleep(1)
        assert (await asyncio.to_thread(rpc, args.url, "status"))["capture_frames"] == capture_count, "Capture continued after close"
        result["closed"] = closed
        # Reuse the process after acknowledged cleanup: a fresh caller offer
        # must open a new recording session and cancel without inheriting routes.
        await asyncio.to_thread(rpc, args.url, "offer", **start_values)
        await wait_status(args.url, lambda s: s["local_type"] == "offer" and s["local_sdp"]
                          and s["capture_starts"] > closed["capture_starts"])
        await asyncio.to_thread(rpc, args.url, "close")
        redial_closed = await wait_status(args.url, lambda s: s["capture_stops"] >= s["capture_starts"]
                                         and s["close_completions"] >= 2 and s["audio_mode"] == idle["audio_mode"]
                                         and s["speaker"] == idle["speaker"])
        result["redial_closed"] = redial_closed
        result["pass"] = True
    except Exception as failure:
        result["pass"] = False
        result["failure"] = repr(failure)
        raise
    finally:
        for task in receiver_tasks:
            task.cancel()
        await pc.close()
        try:
            await asyncio.to_thread(rpc, args.url, "close")
        except Exception:
            pass
        (evidence / "result.json").write_text(json.dumps(result, indent=2, default=str))
        (evidence / "received-frame-metrics.json").write_text(json.dumps(received, indent=2))
        print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:18869/")
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--turn-credentials", help="Private synthetic credentials file for loopback-only TURN fixture")
    asyncio.run(run(parser.parse_args()))
