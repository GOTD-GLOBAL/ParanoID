"""Test-only, import-safe observer for one ordinary host caller per arm.

Put the reviewed repository clients/android directory on sys.path first. The
imported Peer and test_voice_media modules have guarded CLI entry points. No
fixture, socket, process, or PeerConnection starts at import or construction.

Use ObservedPeer(runtime, evidence_dir), original async command()/poll()/close(),
and safe_snapshot() for persistence. Original command results remain PRIVATE:
they include contact material and full SDK stats. This module never persists
those results. The evidence argument is accepted for constructor compatibility;
the original raw SDP/stat write sites receive a discard-only sink instead.
"""
from collections import deque
import math
import threading
import time

import numpy as np
from test_voice_app_peer import Peer


_PC = frozenset(("new", "connecting", "connected", "disconnected", "failed", "closed"))
_ICE = _PC | frozenset(("checking", "completed"))
_GATHER = frozenset(("new", "gathering", "complete"))
_CALL = frozenset(("idle", "outgoing", "ringing", "authorizing", "connecting",
                   "connected", "reconnecting", "ended"))
_REASON = frozenset(("", "hangup", "reject", "cancel", "busy", "timeout",
                     "failed", "unavailable"))
_CANDIDATE = frozenset(("host", "srflx", "prflx", "relay"))
_ERROR = frozenset(("InvalidStateError", "OperationError", "TimeoutError",
                    "ConnectionError", "ValueError", "MediaStreamError",
                    "CancelledError", "RuntimeError"))


def _enum(value, allowed):
    return value if isinstance(value, str) and value in allowed else "unknown"


def _number(value, default=0):
    return value if type(value) in (int, float) and math.isfinite(value) else default


class _DiscardWrites:
    """No raw SDP or stats are written, retained, parsed, or returned here."""

    def __truediv__(self, unused_name):
        return self

    def write_text(self, text, *args, **kwargs):
        return len(text)


class ObservedPeer(Peer):
    """Same original peer behavior; observation failures cannot alter delegation.

    The host post-commit event timestamp is IPC receipt, after the bridge's
    committed call callback and controller acceptance. It is not native commit
    source time or transport acceptance time. SDK milestones surround real SDK
    method calls; PC/ICE/gathering callbacks are delivery-time observations.
    """

    def __init__(self, runtime, evidence=None):
        super().__init__(runtime, _DiscardWrites())
        self._observer_lock = threading.RLock()
        self._observed = deque(maxlen=256)
        self._observer_started = time.monotonic()
        self._observer_deadline = self._observer_started + 90.0
        self._observer_finished = False
        self._observer_censored = False
        self._observer_errors = 0
        self._truncated = 0
        self._sequence = 0
        self._first_error = None
        self._last_controller = None
        self._last_media = None
        self._decoded_frames = 0
        self._decoded_samples = 0
        self._decoded_normalized_energy_sum = 0.0
        self._decoded_normalized_peak = 0.0
        self._answer_receipts = 0
        self._remote_answer_successes = 0
        self._observed_instances = 0

    def _observe(self, callback):
        # All access/calculation/mutation belonging to observation stays inside
        # this fence; arguments/result/exception delegation is outside it.
        try:
            with self._observer_lock:
                if self._observer_finished:
                    return
                if time.monotonic() > self._observer_deadline:
                    self._observer_censored = True
                    return
                callback()
        except BaseException:
            self._observer_errors += 1

    def _emit(self, event, **values):
        if len(self._observed) == self._observed.maxlen:
            self._truncated += 1
        self._sequence += 1
        self._observed.append(dict(sequence=self._sequence,
                                   monotonic_ms=(time.monotonic() - self._observer_started) * 1000,
                                   event=event, **values))

    def _failure(self, operation, error):
        value = dict(operation=operation, error=_enum(type(error).__name__, _ERROR))
        self._emit("host_sdk_operation_error", **value)
        if self._first_error is None:
            self._first_error = dict(self._observed[-1])

    def _observe_rpc(self, result):
        # VoicePeerBridge consumes only committed call events, and set_answer is
        # emitted by controller.mediaRemoteAnswer for the accepted current call.
        for event in result.get("media_commands", ()):
            if event.get("operation") == "set_answer":
                self._answer_receipts += 1
                self._emit("host_committed_answer_ipc_received",
                           generation=_number(event.get("generation")),
                           receipt_count=self._answer_receipts)
            elif event.get("operation") == "close":
                self._emit("host_controller_media_close_requested")
        call = result.get("call", {})
        state = dict(state=_enum(call.get("state"), _CALL),
                     reason=_enum(call.get("reason"), _REASON),
                     authenticated_online=result.get("connected") is True)
        if state != self._last_controller:
            self._last_controller = state
            self._emit("host_controller_snapshot", **state)

    def rpc(self, *args, **kwargs):
        # Original runtime exception is preserved, without stringification.
        try:
            result = super().rpc(*args, **kwargs)
        except BaseException as error:
            self._observe(lambda: self._failure("host_ipc", error))
            raise
        self._observe(lambda: self._observe_rpc(result))
        return result

    def _media_snapshot(self, pc):
        selected = []
        dtls = []
        for transceiver in pc.getTransceivers():
            transport = transceiver.sender.transport
            dtls.append(_enum(transport.state, _PC | frozenset(("failed",))))
            connection = transport.transport.iceGatherer._connection
            for pair in connection._nominated.values():
                selected.append(dict(local=_enum(pair.local_candidate.type, _CANDIDATE),
                                     remote=_enum(pair.remote_candidate.type, _CANDIDATE)))
        value = dict(connection=_enum(pc.connectionState, _PC),
                     ice=_enum(pc.iceConnectionState, _ICE),
                     gathering=_enum(pc.iceGatheringState, _GATHER),
                     dtls_states=dtls[:2], selected_candidate_types=selected[:2])
        if value != self._last_media:
            self._last_media = value
            self._emit("host_sdk_state", generation=_number(self.generation), **value)
        if pc.connectionState == "failed" and self._first_error is None:
            self._emit("host_sdk_connection_failed", generation=_number(self.generation))
            self._first_error = dict(self._observed[-1])

    def _operation_success(self, operation, args, pc):
        kind = "unknown"
        if operation in ("setRemoteDescription", "setLocalDescription") and args:
            kind = _enum(getattr(args[0], "type", None), frozenset(("offer", "answer")))
        self._emit("host_sdk_operation_success", operation=operation, kind=kind,
                   generation=_number(self.generation))
        if operation == "setRemoteDescription" and kind == "answer":
            self._remote_answer_successes += 1
            self._emit("host_set_remote_answer_success",
                       generation=_number(self.generation),
                       success_count=self._remote_answer_successes)
        self._media_snapshot(pc)

    def _attach_operation(self, pc, operation):
        original = getattr(pc, operation)

        async def delegated(*args, **kwargs):
            self._observe(lambda: self._emit("host_sdk_operation_requested",
                          operation=operation, generation=_number(self.generation)))
            try:
                result = await original(*args, **kwargs)
            except BaseException as error:
                self._observe(lambda: self._failure(operation, error))
                raise
            self._observe(lambda: self._operation_success(operation, args, pc))
            return result

        setattr(pc, operation, delegated)

    def _frame(self, frame):
        # The returned frame is neither modified nor retained. Only aggregates
        # of actually decoded PCM are recorded, never PCM bytes or arrays.
        pcm = frame.to_ndarray()
        if pcm.dtype.kind in ("i", "u"):
            limits = np.iinfo(pcm.dtype)
            scale = float(max(abs(limits.min), abs(limits.max)))
        elif pcm.dtype.kind == "f":
            scale = 1.0
        else:
            raise TypeError()
        normalized = pcm.astype(np.float64) / scale
        energy = float(np.mean(normalized * normalized))
        peak = float(np.max(np.abs(normalized)))
        if not math.isfinite(energy) or not math.isfinite(peak):
            raise ValueError()
        self._decoded_frames += 1
        self._decoded_samples += int(frame.samples)
        self._decoded_normalized_energy_sum += energy
        self._decoded_normalized_peak = max(self._decoded_normalized_peak, peak)
        if self._decoded_frames == 1:
            self._emit("host_first_decoded_opus_frame", samples=int(frame.samples),
                       sample_rate=int(frame.sample_rate))

    def _attach_track(self, track):
        original = track.recv

        async def delegated(*args, **kwargs):
            # Original exceptions propagate unchanged. Stream-ended during
            # ordinary teardown is not classified as a product error.
            frame = await original(*args, **kwargs)
            self._observe(lambda: self._frame(frame))
            return frame

        track.recv = delegated

    def _attach_pc(self, pc):
        self._observed_instances += 1
        if self._observed_instances != 1:
            self._observer_censored = True
            self._emit("host_extra_media_instance_unobserved")
            return
        for operation in ("createOffer", "createAnswer", "setLocalDescription",
                          "setRemoteDescription", "close"):
            self._attach_operation(pc, operation)
        for name in ("connectionstatechange", "iceconnectionstatechange", "icegatheringstatechange"):
            pc.on(name, lambda: self._observe(lambda: self._media_snapshot(pc)))
        pc.on("track", lambda track: self._observe(lambda: self._attach_track(track)))
        self._emit("host_observer_attached", generation=_number(self.generation))
        self._media_snapshot(pc)

    async def make_pc(self, *args, **kwargs):
        try:
            pc = await super().make_pc(*args, **kwargs)
        except BaseException as error:
            self._observe(lambda: self._failure("make_pc", error))
            raise
        self._observe(lambda: self._attach_pc(pc))
        return pc

    async def command(self, *args, **kwargs):
        result = await super().command(*args, **kwargs)
        self._observe(lambda: self._media_snapshot(self.pc) if self.pc is not None else None)
        return result

    def safe_snapshot(self):
        """Only this allowlisted result is suitable for persisted evidence."""
        with self._observer_lock:
            return self._safe_snapshot()

    def _safe_snapshot(self):
        self._observe(lambda: self._media_snapshot(self.pc) if self.pc is not None else None)
        return dict(coverage="host_ipc_delivery_and_sdk_wrapper",
                    native_commit_source_time="NOT_MEASURED",
                    events=[dict(event) for event in self._observed],
                    truncated_count=self._truncated,
                    observer_error_count=self._observer_errors,
                    observation_censored=self._observer_censored,
                    observer_finished=self._observer_finished,
                    first_error=dict(self._first_error) if self._first_error else None,
                    committed_answer_ipc_receipts=self._answer_receipts,
                    set_remote_answer_successes=self._remote_answer_successes,
                    last_controller=dict(self._last_controller) if self._last_controller else None,
                    last_media=dict(self._last_media) if self._last_media else None,
                    decoded_opus_frames=self._decoded_frames,
                    decoded_sample_frames=self._decoded_samples,
                    normalized_mean_frame_energy=(self._decoded_normalized_energy_sum /
                                                  self._decoded_frames if self._decoded_frames else 0.0),
                    normalized_peak=self._decoded_normalized_peak,
                    media_object_present=self.pc is not None,
                    receiver_task_count=len(self.receiver_tasks))

    def finish_observer(self):
        """Stop observation only; caller still owns ordinary hangup and close."""
        with self._observer_lock:
            self._observe(lambda: self._emit("host_observer_finished"))
            self._observer_finished = True
            return self._safe_snapshot()
