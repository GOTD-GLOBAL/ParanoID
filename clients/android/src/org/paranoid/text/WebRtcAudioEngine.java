package org.paranoid.text;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.PowerManager;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;
import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RTCStats;
import org.webrtc.RtpCapabilities;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.audio.JavaAudioDeviceModule;

/** One explicitly consented audio call. The controller authenticates all SDP.
 * Native work has one owner; callbacks return to Android's main thread.
 * Construction alone opens no microphone, audio route or PeerConnection.
 */
public final class WebRtcAudioEngine {
    public interface Listener {
        void onLocalDescription(String type, String exactSdp);
        void onConnected();
        void onDisconnected();
        void onError(String safeReason);
    }
    // Only the separately packaged instrumentation has an implementation. No
    // application component, intent or user setting supplies synthetic samples.
    interface Hooks {
        long onCapture(ByteBuffer buffer, int format, int channels, int rate, int bytes, long timestamp);
        void onDecoded(ByteBuffer buffer, int bits, int rate, int channels, int frames, long timestamp);
        void onCaptureStarted();
        void onCaptureStopped();
    }
    private static boolean initialized;
    private final Context context;
    private final Listener listener;
    private final Hooks hooks;
    private final List<PeerConnection.IceServer> iceServers;
    private final boolean relayOnly;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final HandlerThread thread = new HandlerThread("ParanoID-voice-media");
    private final Handler worker;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final List<Runnable> closeCallbacks = new ArrayList<>();
    private boolean cleanupFinished;
    private volatile boolean muted, speaker;
    private PeerConnectionFactory factory;
    private PeerConnection peer;
    private JavaAudioDeviceModule audioDevice;
    private AudioSource source;
    private AudioTrack localTrack;
    private final List<AudioTrack> remoteTracks = new ArrayList<>();
    private AudioTrackSink remoteSink;
    private AudioManager audio;
    private AudioFocusRequest focus;
    private PowerManager.WakeLock proximity;
    private int previousMode;
    private boolean previousSpeaker, routeOwned;
    private AudioDeviceInfo previousDevice;
    private String pendingDescription;
    private boolean localPublished, connected;

    public WebRtcAudioEngine(Context context, Listener listener) {
        this(context, listener, null);
    }
    WebRtcAudioEngine(Context context, Listener listener, Hooks hooks) {
        this(context, listener, hooks, Collections.emptyList(), false);
    }
    WebRtcAudioEngine(Context context, Listener listener, Hooks hooks,
            List<PeerConnection.IceServer> servers, boolean relayOnly) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        this.hooks = hooks;
        this.iceServers = new ArrayList<>(servers);
        this.relayOnly = relayOnly;
        thread.start();
        worker = new Handler(thread.getLooper());
    }

    private static synchronized void initialize(Context context) {
        if (!initialized) {
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context)
                    .setEnableInternalTracer(false).createInitializationOptions());
            initialized = true;
        }
    }
    private void post(Runnable task) {
        if (!closed.get()) worker.post(() -> {
            if (closed.get()) return;
            try { task.run(); } catch (Exception failure) { fail("Audio engine failed"); }
        });
    }
    private void publish(Runnable callback) {
        main.post(() -> { if (!closed.get()) callback.run(); });
    }
    public void createOffer() {
        post(() -> { create(); pendingDescription = "offer"; peer.createOffer(localObserver, new MediaConstraints()); });
    }
    public void createAnswer(String validatedRemoteOffer) {
        post(() -> {
            create();
            peer.setRemoteDescription(new Observer() {
                @Override public void onSetSuccess() {
                    post(() -> { pendingDescription = "answer"; peer.createAnswer(localObserver, new MediaConstraints()); });
                }
            }, new SessionDescription(SessionDescription.Type.OFFER, validatedRemoteOffer));
        });
    }
    public void setAnswer(String validatedRemoteAnswer) {
        post(() -> {
            if (peer == null || !"offer".equals(pendingDescription)) throw new IllegalStateException();
            peer.setRemoteDescription(new Observer(), new SessionDescription(SessionDescription.Type.ANSWER, validatedRemoteAnswer));
        });
    }
    public void setMuted(boolean value) {
        muted = value;
        post(() -> {
            if (localTrack != null) localTrack.setEnabled(!muted);
            if (audioDevice != null) audioDevice.setMicrophoneMute(muted);
        });
    }
    public void setSpeaker(boolean value) {
        speaker = value;
        post(this::applyRoute);
    }

    private void create() {
        if (peer != null) throw new IllegalStateException();
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            throw new SecurityException("Microphone permission required");
        // Native NetworkMonitor treats a Java permission exception as fatal.
        // Refuse before opening media if a packaging error removes normal grants.
        if (context.checkSelfPermission(Manifest.permission.ACCESS_NETWORK_STATE) != PackageManager.PERMISSION_GRANTED
                || context.checkSelfPermission(Manifest.permission.MODIFY_AUDIO_SETTINGS) != PackageManager.PERMISSION_GRANTED)
            throw new SecurityException("Required audio/network permissions missing");
        initialize(context);
        acquireAudio();
        JavaAudioDeviceModule.Builder builder = JavaAudioDeviceModule.builder(context)
                .setUseHardwareAcousticEchoCanceler(true).setUseHardwareNoiseSuppressor(true)
                .setUseStereoInput(false).setUseStereoOutput(false)
                .setAudioRecordErrorCallback(new JavaAudioDeviceModule.AudioRecordErrorCallback() {
                    @Override public void onWebRtcAudioRecordInitError(String message) { post(() -> fail("Microphone unavailable")); }
                    @Override public void onWebRtcAudioRecordStartError(JavaAudioDeviceModule.AudioRecordStartErrorCode code, String message) { post(() -> fail("Microphone unavailable")); }
                    @Override public void onWebRtcAudioRecordError(String message) { post(() -> fail("Microphone unavailable")); }
                }).setAudioTrackErrorCallback(new JavaAudioDeviceModule.AudioTrackErrorCallback() {
                    @Override public void onWebRtcAudioTrackInitError(String message) { post(() -> fail("Audio output unavailable")); }
                    @Override public void onWebRtcAudioTrackStartError(JavaAudioDeviceModule.AudioTrackStartErrorCode code, String message) { post(() -> fail("Audio output unavailable")); }
                    @Override public void onWebRtcAudioTrackError(String message) { post(() -> fail("Audio output unavailable")); }
                });
        if (hooks != null) {
            builder.setAudioBufferCallback(hooks::onCapture)
                    .setAudioRecordStateCallback(new JavaAudioDeviceModule.AudioRecordStateCallback() {
                        @Override public void onWebRtcAudioRecordStart() { hooks.onCaptureStarted(); }
                        @Override public void onWebRtcAudioRecordStop() { hooks.onCaptureStopped(); }
                    });
            remoteSink = hooks::onDecoded;
        }
        audioDevice = builder.createAudioDeviceModule();
        factory = PeerConnectionFactory.builder().setAudioDeviceModule(audioDevice).createPeerConnectionFactory();
        PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(iceServers);
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        config.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
        config.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE;
        config.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED;
        config.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE;
        config.iceCandidatePoolSize = 0;
        if (relayOnly) config.iceTransportsType = PeerConnection.IceTransportsType.RELAY;
        peer = factory.createPeerConnection(config, peerObserver);
        if (peer == null) throw new IllegalStateException();
        MediaConstraints constraints = new MediaConstraints();
        constraints.optional.add(new MediaConstraints.KeyValuePair("googEchoCancellation", "true"));
        constraints.optional.add(new MediaConstraints.KeyValuePair("googAutoGainControl", "true"));
        constraints.optional.add(new MediaConstraints.KeyValuePair("googNoiseSuppression", "true"));
        source = factory.createAudioSource(constraints);
        localTrack = factory.createAudioTrack("voice", source);
        localTrack.setEnabled(!muted);
        audioDevice.setMicrophoneMute(muted);
        peer.addTrack(localTrack, Collections.singletonList("voice"));
        List<RtpCapabilities.CodecCapability> opus = new ArrayList<>();
        for (RtpCapabilities.CodecCapability codec : factory.getRtpSenderCapabilities(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO).codecs)
            if ("audio/opus".equalsIgnoreCase(codec.mimeType)) opus.add(codec);
        if (opus.isEmpty()) throw new IllegalStateException("Opus unavailable");
        for (RtpTransceiver transceiver : peer.getTransceivers()) transceiver.setCodecPreferences(opus);
    }

    private void acquireAudio() {
        audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        previousMode = audio.getMode();
        previousSpeaker = audio.isSpeakerphoneOn();
        if (Build.VERSION.SDK_INT >= 31) previousDevice = audio.getCommunicationDevice();
        focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(change -> {
                    if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
                        post(() -> fail("Audio focus lost"));
                }, main).build();
        if (audio.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
            throw new IllegalStateException("Audio focus unavailable");
        routeOwned = true;
        audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (context.checkSelfPermission(Manifest.permission.WAKE_LOCK) == PackageManager.PERMISSION_GRANTED
                && power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            proximity = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "ParanoID:voice-proximity");
            proximity.setReferenceCounted(false);
        }
        applyRoute();
    }
    private void applyRoute() {
        if (!routeOwned) return;
        if (Build.VERSION.SDK_INT >= 31) {
            if (speaker) {
                boolean selected = false;
                for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices())
                    if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                        selected = audio.setCommunicationDevice(device); break;
                    }
                if (!selected) throw new IllegalStateException("Speaker unavailable");
            } else audio.clearCommunicationDevice();
        } else audio.setSpeakerphoneOn(speaker);
        updateProximity();
    }
    private void updateProximity() {
        if (proximity == null) return;
        boolean earpiece = !speaker && connected;
        if (Build.VERSION.SDK_INT >= 31) {
            AudioDeviceInfo current = audio.getCommunicationDevice();
            earpiece = earpiece && current != null && current.getType() == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE;
        } else earpiece = earpiece && !audio.isWiredHeadsetOn() && !audio.isBluetoothScoOn();
        if (earpiece && !proximity.isHeld()) proximity.acquire(15 * 60 * 1000L);
        if (!earpiece && proximity.isHeld()) proximity.release();
    }
    private void maybePublishDescription() {
        if (peer == null || localPublished || pendingDescription == null
                || peer.iceGatheringState() != PeerConnection.IceGatheringState.COMPLETE) return;
        SessionDescription sdp = peer.getLocalDescription();
        if (sdp == null) return;
        // Android's network monitor can report an initial empty COMPLETE before
        // discovering interfaces. Such an SDP cannot connect two identical peers.
        // Wait for the subsequent candidate callback; controller timeout remains.
        if (!sdp.description.contains("a=candidate:")) return;
        if (sdp.description.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 6144)
            throw new IllegalStateException("SDP exceeds voice limit");
        localPublished = true;
        String type = pendingDescription;
        publish(() -> listener.onLocalDescription(type, sdp.description));
    }
    private class Observer implements SdpObserver {
        @Override public void onCreateSuccess(SessionDescription sdp) { }
        @Override public void onSetSuccess() { }
        @Override public void onCreateFailure(String reason) { post(() -> fail("Audio negotiation failed")); }
        @Override public void onSetFailure(String reason) { post(() -> fail("Audio negotiation failed")); }
    }
    private final SdpObserver localObserver = new Observer() {
        @Override public void onCreateSuccess(SessionDescription description) {
            post(() -> peer.setLocalDescription(new Observer() {
                @Override public void onSetSuccess() { post(WebRtcAudioEngine.this::maybePublishDescription); }
            }, description));
        }
    };
    private void attachRemote(RtpReceiver receiver) {
        if (remoteSink != null && receiver.track() instanceof AudioTrack) {
            AudioTrack track = (AudioTrack) receiver.track();
            if (remoteTracks.isEmpty()) { track.addSink(remoteSink); remoteTracks.add(track); }
        }
    }
    private final PeerConnection.Observer peerObserver = new PeerConnection.Observer() {
        @Override public void onSignalingChange(PeerConnection.SignalingState state) { }
        @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) { }
        @Override public void onIceConnectionReceivingChange(boolean receiving) { }
        @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) { post(WebRtcAudioEngine.this::maybePublishDescription); }
        @Override public void onIceCandidate(IceCandidate candidate) { post(WebRtcAudioEngine.this::maybePublishDescription); }
        @Override public void onIceCandidatesRemoved(IceCandidate[] candidates) { }
        @Override public void onAddStream(MediaStream stream) { }
        @Override public void onRemoveStream(MediaStream stream) { }
        @Override public void onDataChannel(DataChannel channel) { post(() -> fail("Unexpected media channel")); }
        @Override public void onRenegotiationNeeded() { }
        @Override public void onAddTrack(RtpReceiver receiver, MediaStream[] streams) { }
        @Override public void onTrack(RtpTransceiver transceiver) { post(() -> attachRemote(transceiver.getReceiver())); }
        @Override public void onConnectionChange(PeerConnection.PeerConnectionState state) {
            post(() -> {
                if (state == PeerConnection.PeerConnectionState.CONNECTED && !connected) {
                    connected = true; updateProximity(); publish(listener::onConnected);
                } else if (state == PeerConnection.PeerConnectionState.DISCONNECTED) {
                    connected = false; updateProximity(); publish(listener::onDisconnected);
                } else if (state == PeerConnection.PeerConnectionState.FAILED) fail("Audio connection failed");
            });
        }
    };
    void collectStats(Consumer<String> callback) {
        post(() -> {
            if (peer == null) { callback.accept("{}"); return; }
            peer.getStats(report -> {
                JSONObject out = new JSONObject();
                try {
                    JSONArray entries = new JSONArray();
                    for (RTCStats entry : report.getStatsMap().values()) {
                        JSONObject item = new JSONObject().put("id", entry.getId()).put("type", entry.getType());
                        for (Map.Entry<String, Object> member : entry.getMembers().entrySet())
                            item.put(member.getKey(), JSONObject.wrap(member.getValue()));
                        entries.put(item);
                    }
                    out.put("stats", entries);
                } catch (Exception ignored) { }
                callback.accept(out.toString());
            });
        });
    }
    private void fail(String reason) {
        if (!closed.compareAndSet(false, true)) return;
        cleanup();
        main.post(() -> listener.onError(reason));
    }
    public void close() {
        close(null);
    }
    /** Completion runs on main only after all owned media/audio resources release. */
    public void close(Runnable completion) {
        if (completion != null) synchronized (closeCallbacks) {
            if (cleanupFinished) main.post(completion);
            else closeCallbacks.add(completion);
        }
        if (closed.compareAndSet(false, true)) worker.post(this::cleanup);
    }
    private void cleanup() {
        // Each resource is released even if a preceding vendor operation fails.
        try { if (localTrack != null) localTrack.setEnabled(false); } catch (Exception ignored) { }
        for (AudioTrack track : remoteTracks) try { track.removeSink(remoteSink); } catch (Exception ignored) { }
        remoteTracks.clear();
        try { if (peer != null) { peer.close(); peer.dispose(); } } catch (Exception ignored) { }
        peer = null;
        try { if (localTrack != null) localTrack.dispose(); } catch (Exception ignored) { }
        localTrack = null;
        try { if (source != null) source.dispose(); } catch (Exception ignored) { }
        source = null;
        try { if (factory != null) factory.dispose(); } catch (Exception ignored) { }
        factory = null;
        try { if (audioDevice != null) audioDevice.release(); } catch (Exception ignored) { }
        audioDevice = null;
        try { if (proximity != null && proximity.isHeld()) proximity.release(); } catch (Exception ignored) { }
        try {
            if (routeOwned) {
                if (Build.VERSION.SDK_INT >= 31) {
                    if (previousDevice == null) audio.clearCommunicationDevice();
                    else audio.setCommunicationDevice(previousDevice);
                } else audio.setSpeakerphoneOn(previousSpeaker);
                audio.setMode(previousMode);
            }
        } catch (Exception ignored) { }
        try { if (audio != null && focus != null) audio.abandonAudioFocusRequest(focus); } catch (Exception ignored) { }
        routeOwned = false;
        connected = false;
        worker.removeCallbacksAndMessages(null);
        thread.quitSafely();
        synchronized (closeCallbacks) {
            cleanupFinished = true;
            for (Runnable callback : closeCallbacks) main.post(callback);
            closeCallbacks.clear();
        }
    }
}
