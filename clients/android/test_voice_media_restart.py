"""Actual native regression: close callback redial and mute set before creation."""
import argparse
import asyncio
import json
from pathlib import Path
import time

import aioice.ice
import numpy as np
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from test_voice_media import Tone, rpc, wait_status


async def connect(url, offer, received):
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    pc.addTrack(Tone())

    @pc.on("track")
    def track_ready(track):
        async def consume():
            while True:
                frame = await track.recv()
                pcm = frame.to_ndarray().astype(np.float64).reshape(-1)
                received.append((time.monotonic(), float(np.sqrt(np.mean(pcm * pcm)))))
        pc.test_task = asyncio.create_task(consume())

    await pc.setRemoteDescription(RTCSessionDescription(offer, "offer"))
    await pc.setLocalDescription(await pc.createAnswer())
    answer = "\r\n".join(line for line in pc.localDescription.sdp.replace("127.0.0.1", "10.0.2.2").splitlines()
                          if not line.startswith("a=fingerprint:") or line.startswith("a=fingerprint:sha-256 ")) + "\r\n"
    await asyncio.to_thread(rpc, url, "set_answer", sdp=answer)
    return pc


async def run(args):
    aioice.ice.get_host_addresses = lambda use_ipv4, use_ipv6: ["127.0.0.1"]
    evidence = Path(args.evidence_dir)
    evidence.mkdir(parents=True, exist_ok=False)
    result = {"boundary": "Actual Android libwebrtc, callback-immediate engine replacement, synthetic PCM"}
    peers = []
    try:
        initial = await asyncio.to_thread(rpc, args.url, "status")
        assert initial["capture_starts"] == 0
        result["original_audio_mode"] = initial["audio_mode"]
        result["original_speaker"] = initial["speaker"]
        await asyncio.to_thread(rpc, args.url, "offer", initial_speaker=True)
        first = await wait_status(args.url, lambda s: bool(s["local_sdp"]))
        first_received = []
        peers.append(await connect(args.url, first["local_sdp"], first_received))
        first = await wait_status(args.url, lambda s: s["connected"] and s["capture_frames"] > 8000)
        assert first["speaker"], "Speaker desired before creation was lost"
        # The new constructor runs inside close completion itself. No polling or
        # delay for route restoration precedes the new engine's acquisition.
        await asyncio.to_thread(rpc, args.url, "close_then_offer", initial_muted=True, initial_speaker=False)
        second = await wait_status(args.url, lambda s: s["immediate_redials"] == 1 and bool(s["local_sdp"]))
        result["mode_at_immediate_redial"] = second["mode_at_immediate_redial"]
        assert second["capture_starts"] == first["capture_starts"], "Initially muted redial started capture"
        assert second["capture_stops"] == first["capture_starts"], "Previous capture did not stop before redial"
        second_received = []
        peers.append(await connect(args.url, second["local_sdp"], second_received))
        muted = await wait_status(args.url, lambda s: s["connected"] and s["decoded_frames"] > second["decoded_frames"] + 48000)
        await asyncio.sleep(1)
        result["initial_mute_capture_starts"] = muted["capture_starts"] - first["capture_starts"]
        result["initial_mute_host_frames"] = len(second_received)
        result["initial_mute_host_max_rms"] = max((value for _, value in second_received), default=0)
        # On initial negotiation the SDK may initialize AudioRecord even for a
        # disabled track. The consented call must transmit no microphone audio;
        # capture lifetime remains separately measured and must end at close.
        assert result["initial_mute_host_max_rms"] < 50, "Initially muted call transmitted audio"
        result["reverse_audio_while_initially_muted"] = True
        await asyncio.to_thread(rpc, args.url, "mute", muted=False)
        await wait_status(args.url, lambda s: s["capture_frames"] > muted["capture_frames"])
        await asyncio.sleep(2)
        recent = [value for when, value in second_received if when > time.monotonic() - 1]
        assert len(recent) >= 20 and np.median(recent) > 100, "Unmute did not produce decoded real RTP"
        result["unmuted_host_rms_median"] = float(np.median(recent))
        await asyncio.to_thread(rpc, args.url, "close")
        final = await wait_status(args.url, lambda s: s["close_completions"] >= 2
                                 and s["capture_starts"] == s["capture_stops"]
                                 and s["audio_mode"] == initial["audio_mode"]
                                 and s["speaker"] == initial["speaker"])
        result["capture_starts"] = final["capture_starts"]
        result["capture_stops"] = final["capture_stops"]
        result["restored_audio_mode"] = final["audio_mode"]
        result["restored_speaker"] = final["speaker"]
        result["pass"] = True
    except Exception as failure:
        result["pass"] = False
        result["failure"] = repr(failure)
        raise
    finally:
        for peer in peers:
            if hasattr(peer, "test_task"):
                peer.test_task.cancel()
            await peer.close()
        try:
            await asyncio.to_thread(rpc, args.url, "close")
        except Exception:
            pass
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:19869/")
    parser.add_argument("--evidence-dir", required=True)
    asyncio.run(run(parser.parse_args()))
