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
import org.webrtc.Camera2Enumerator;
import org.webrtc.CameraEnumerator;
import org.webrtc.CameraVideoCapturer;
import org.webrtc.DefaultVideoDecoderFactory;
import org.webrtc.DefaultVideoEncoderFactory;
import org.webrtc.EglBase;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoSink;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;

/** One explicitly consented call: audio, plus camera video only after an explicit toggle. The controller authenticates all SDP.
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
    /** Optional: a Listener may also implement this to learn that the camera could not start (call continues as audio). */
    public interface VideoListener { void onVideoUnavailable(String safeReason); }
    // Only the separately packaged instrumentation has an implementation. No
    // application component, intent or user setting supplies synthetic samples.
    interface Hooks {
        long onCapture(ByteBuffer buffer, int format, int channels, int rate, int bytes, long timestamp);
        void onDecoded(ByteBuffer buffer, int bits, int rate, int channels, int frames, long timestamp);
        void onCaptureStarted();
        void onCaptureStopped();
    }
    private static boolean initialized;
    private static final int VIDEO_WIDTH = 640, VIDEO_HEIGHT = 480, VIDEO_FPS = 24;
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
    // Video: the transceiver is pre-negotiated (sendrecv) so camera on/off needs no renegotiation.
    private EglBase egl;
    private VideoSource videoSource;
    private VideoTrack localVideo, remoteVideo;
    private CameraVideoCapturer capturer;
    private SurfaceTextureHelper surfaceHelper;
    private VideoSink localSink, remoteSink2;
    private volatile boolean videoEnabled, frontCamera = true;
    private String videoCodec = "";
    private AudioManager audio;
    private AudioFocusRequest focus;
    private PowerManager.WakeLock proximity;
    private int previousMode;
    private boolean previousSpeaker, routeOwned;
    private AudioDeviceInfo previousDevice;
    private android.media.AudioDeviceCallback deviceCallback;
    private boolean legacyScoStarted;
    private String pendingDescription;
    private boolean localPublished, connected;
    private boolean localSetSucceeded, relayPublicationScheduled, relayPublicationWindowElapsed;
    private final Runnable relayPublication = () -> {
        if (closed.get()) return;
        relayPublicationWindowElapsed = true;
        try { maybePublishDescription(); }
        catch (Exception failure) { fail("Audio negotiation failed"); }
    };

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
    /** Camera on/off. Requires CAMERA permission at call time; a denied grant fails the toggle, not the call. */
    public void setVideo(boolean value) {
        videoEnabled = value;
        post(() -> { if (peer != null) { applyVideoSafely(); applyRoute(); } });
    }
    private void applyVideoSafely() {
        try { applyVideo(); }
        catch (Exception failure) {
            videoEnabled = false;
            try { if (localVideo != null) localVideo.setEnabled(false); } catch (Exception ignored) { }
            stopCapture();
            if (listener instanceof VideoListener) publish(() -> ((VideoListener) listener).onVideoUnavailable("Camera unavailable"));
        }
    }
    public void switchCamera() {
        post(() -> { if (capturer != null) { frontCamera = !frontCamera; capturer.switchCamera(null); } });
    }
    /** Renderers are attached from the UI thread and must outlive the call view; detach with null. */
    public void setLocalSink(VideoSink sink) { post(() -> { if (localVideo != null && localSink != null) localVideo.removeSink(localSink); localSink = sink; if (localVideo != null && sink != null) localVideo.addSink(sink); }); }
    public void setRemoteSink(VideoSink sink) { post(() -> { if (remoteVideo != null && remoteSink2 != null) remoteVideo.removeSink(remoteSink2); remoteSink2 = sink; if (remoteVideo != null && sink != null) remoteVideo.addSink(sink); }); }
    public EglBase.Context eglContext() { return egl == null ? null : egl.getEglBaseContext(); }
    public String negotiatedVideoCodec() { return videoCodec; }

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
        egl = EglBase.create();
        // Owner decision 2026-09-11: H.264 (hardware) first, VP8 mandatory fallback; no VP9/AV1.
        factory = PeerConnectionFactory.builder().setAudioDeviceModule(audioDevice)
                .setVideoEncoderFactory(new DefaultVideoEncoderFactory(egl.getEglBaseContext(), false, true))
                .setVideoDecoderFactory(new DefaultVideoDecoderFactory(egl.getEglBaseContext()))
                .createPeerConnectionFactory();
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
        // Pre-negotiated video section: track exists but stays disabled (black/no frames) until an explicit toggle.
        videoSource = factory.createVideoSource(false);
        localVideo = factory.createVideoTrack("video", videoSource);
        localVideo.setEnabled(false);
        peer.addTrack(localVideo, Collections.singletonList("voice"));
        List<RtpCapabilities.CodecCapability> videoCodecs = new ArrayList<>(), fallback = new ArrayList<>(), helpers = new ArrayList<>();
        for (RtpCapabilities.CodecCapability codec : factory.getRtpSenderCapabilities(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO).codecs) {
            String mime = codec.mimeType == null ? "" : codec.mimeType.toLowerCase(java.util.Locale.ROOT);
            if (mime.equals("video/h264")) videoCodecs.add(codec);
            else if (mime.equals("video/vp8")) fallback.add(codec);
            else if (mime.equals("video/rtx") || mime.equals("video/red") || mime.equals("video/ulpfec") || mime.equals("video/flexfec-03")) helpers.add(codec);
        }
        if (fallback.isEmpty()) throw new IllegalStateException("VP8 unavailable");
        videoCodecs.addAll(fallback); videoCodecs.addAll(helpers);
        for (RtpTransceiver transceiver : peer.getTransceivers())
            if (transceiver.getMediaType() == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) transceiver.setCodecPreferences(videoCodecs);
        if (localSink != null) localVideo.addSink(localSink);
    }
    private void applyVideo() {
        if (videoEnabled) {
            if (capturer == null) {
                if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
                    throw new SecurityException("Camera permission required");
                CameraEnumerator enumerator = new Camera2Enumerator(context);
                String chosen = null;
                for (String name : enumerator.getDeviceNames()) if (frontCamera == enumerator.isFrontFacing(name)) { chosen = name; break; }
                if (chosen == null) for (String name : enumerator.getDeviceNames()) { chosen = name; break; }
                if (chosen == null) throw new IllegalStateException("No camera");
                capturer = enumerator.createCapturer(chosen, null);
                surfaceHelper = SurfaceTextureHelper.create("ParanoID-camera", egl.getEglBaseContext());
                capturer.initialize(surfaceHelper, context, videoSource.getCapturerObserver());
                capturer.startCapture(VIDEO_WIDTH, VIDEO_HEIGHT, VIDEO_FPS);
            }
            localVideo.setEnabled(true);
        } else {
            localVideo.setEnabled(false);
            stopCapture();
        }
    }
    private void stopCapture() {
        try { if (capturer != null) capturer.stopCapture(); } catch (Exception ignored) { }
        try { if (capturer != null) capturer.dispose(); } catch (Exception ignored) { }
        capturer = null;
        try { if (surfaceHelper != null) surfaceHelper.dispose(); } catch (Exception ignored) { }
        surfaceHelper = null;
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
        // Re-route when a headset (Bluetooth/wired) appears or disappears mid-call.
        deviceCallback = new android.media.AudioDeviceCallback() {
            @Override public void onAudioDevicesAdded(AudioDeviceInfo[] added) { post(WebRtcAudioEngine.this::applyRoute); }
            @Override public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) { post(WebRtcAudioEngine.this::applyRoute); }
        };
        audio.registerAudioDeviceCallback(deviceCallback, main);
    }
    private void applyRoute() {
        if (!routeOwned) return;
        if (Build.VERSION.SDK_INT >= 31) {
            // Owner decision 2026-09-11: an attached wired/Bluetooth headset always wins over the speakerphone.
            AudioDeviceInfo attached = preferredHeadset();
            if (speaker && attached != null && videoEnabled) {
                if (!audio.setCommunicationDevice(attached)) audio.clearCommunicationDevice();
            } else if (speaker) {
                boolean selected = false;
                for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices())
                    if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                        selected = audio.setCommunicationDevice(device); break;
                    }
                if (!selected) throw new IllegalStateException("Speaker unavailable");
            } else {
                // Explicit speaker off: prefer a Bluetooth headset, then wired, then earpiece.
                AudioDeviceInfo headset = preferredHeadset();
                if (headset == null || !audio.setCommunicationDevice(headset)) audio.clearCommunicationDevice();
            }
        } else {
            boolean headset = legacyBluetoothAvailable() || audio.isWiredHeadsetOn();
            boolean useSpeaker = speaker && !(videoEnabled && headset);
            legacyBluetooth(!useSpeaker && legacyBluetoothAvailable());
            audio.setSpeakerphoneOn(useSpeaker);
        }
        updateProximity();
    }
    /** SDK>=31 headset priority: BLE/SCO Bluetooth (with runtime BLUETOOTH_CONNECT) over wired. */
    private AudioDeviceInfo preferredHeadset() {
        if (Build.VERSION.SDK_INT < 31) return null;
        boolean allowed = context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        AudioDeviceInfo bluetooth = null, wired = null;
        for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices()) {
            int type = device.getType();
            if (allowed && bluetooth == null
                    && (type == AudioDeviceInfo.TYPE_BLE_HEADSET || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO)) bluetooth = device;
            if (wired == null && (type == AudioDeviceInfo.TYPE_WIRED_HEADSET || type == AudioDeviceInfo.TYPE_USB_HEADSET)) wired = device;
        }
        return bluetooth != null ? bluetooth : wired;
    }
    /** Simplified pre-31 fallback: classic SCO only when a Bluetooth output is attached. */
    private boolean legacyBluetoothAvailable() {
        if (!audio.isBluetoothScoAvailableOffCall()) return false;
        for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS))
            if (device.getType() == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) return true;
        return false;
    }
    private void legacyBluetooth(boolean enable) {
        try {
            if (enable && !legacyScoStarted) { audio.startBluetoothSco(); audio.setBluetoothScoOn(true); legacyScoStarted = true; }
            else if (!enable && legacyScoStarted) { audio.setBluetoothScoOn(false); audio.stopBluetoothSco(); legacyScoStarted = false; }
        } catch (RuntimeException ignored) { /* A failed SCO switch must not end the call. */ }
    }
    private void updateProximity() {
        if (proximity == null) return;
        // The proximity sensor must never blank the screen while the local camera is on (the user looks at the screen).
        boolean earpiece = !speaker && connected && !videoEnabled;
        if (Build.VERSION.SDK_INT >= 31) {
            AudioDeviceInfo current = audio.getCommunicationDevice();
            earpiece = earpiece && current != null && current.getType() == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE;
        } else earpiece = earpiece && !audio.isWiredHeadsetOn() && !audio.isBluetoothScoOn();
        if (earpiece && !proximity.isHeld()) proximity.acquire(15 * 60 * 1000L);
        if (!earpiece && proximity.isHeld()) proximity.release();
    }
    private void maybePublishDescription() {
        if (closed.get() || peer == null || localPublished || !localSetSucceeded
                || pendingDescription == null) return;
        SessionDescription sdp = peer.getLocalDescription();
        if (sdp == null || !pendingDescription.equals(sdp.type.canonicalForm())) return;
        boolean complete = peer.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE;
        if (relayOnly) {
            if (!hasUsableRelayCandidate(sdp.description)) return;
            if (!complete && !relayPublicationWindowElapsed) {
                if (!relayPublicationScheduled) {
                    relayPublicationScheduled = true;
                    worker.postDelayed(relayPublication, 500);
                }
                return;
            }
        } else if (!complete) return;
        // Android's network monitor can report an initial empty COMPLETE before
        // discovering interfaces. Such an SDP cannot connect two identical peers.
        // Wait for the subsequent candidate callback; controller timeout remains.
        if (!sdp.description.contains("a=candidate:")) return;
        if (sdp.description.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 12288)
            throw new IllegalStateException("SDP exceeds call limit");
        localPublished = true;
        worker.removeCallbacks(relayPublication);
        String type = pendingDescription;
        publish(() -> listener.onLocalDescription(type, sdp.description));
    }
    // Readiness from our SDK's local snapshot only. Native validation remains
    // mandatory before signaling; related raddr/rport may legitimately be zero.
    private static boolean hasUsableRelayCandidate(String sdp) {
        for (String line : sdp.split("\\r?\\n")) {
            if (!line.startsWith("a=candidate:") || line.length() > 512) continue;
            String[] tokens = line.split("[ \\t]+");
            if (tokens.length < 8 || tokens[0].length() <= 12 || !tokens[1].equals("1")
                    || !tokens[2].equalsIgnoreCase("udp") || !tokens[6].equals("typ")
                    || !tokens[7].equals("relay") || !isRelayAddress(tokens[4])) continue;
            if (!tokens[3].matches("[0-9]{1,10}") || !tokens[5].matches("[0-9]{1,5}")) continue;
            long priority = Long.parseLong(tokens[3]);
            int port = Integer.parseInt(tokens[5]);
            if (priority <= 0xffffffffL && port > 0 && port <= 65535) return true;
        }
        return false;
    }
    private static boolean isRelayAddress(String address) {
        // The validated issuer config has one canonical IPv4 relay only.
        String[] octets = address.split("\\.", -1);
        if (octets.length != 4 || address.equals("0.0.0.0")) return false;
        for (String octet : octets) {
            if (!octet.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(octet) > 255) return false;
        }
        return true;
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
                @Override public void onSetSuccess() {
                    post(() -> { localSetSucceeded = true; maybePublishDescription(); });
                }
            }, description));
        }
    };
    private void attachRemote(RtpReceiver receiver) {
        if (remoteSink != null && receiver.track() instanceof AudioTrack) {
            AudioTrack track = (AudioTrack) receiver.track();
            if (remoteTracks.isEmpty()) { track.addSink(remoteSink); remoteTracks.add(track); }
        }
        if (receiver.track() instanceof VideoTrack && remoteVideo == null) {
            remoteVideo = (VideoTrack) receiver.track();
            remoteVideo.setEnabled(true);
            if (remoteSink2 != null) remoteVideo.addSink(remoteSink2);
        }
    }
    private void recordVideoCodec() {
        if (peer == null) return;
        peer.getStats(report -> {
            for (RTCStats entry : report.getStatsMap().values()) {
                if (!"codec".equals(entry.getType())) continue;
                Object mime = entry.getMembers().get("mimeType");
                if (mime != null && mime.toString().toLowerCase(java.util.Locale.ROOT).startsWith("video/")) { videoCodec = mime.toString(); }
            }
        });
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
                    connected = true; updateProximity(); if (videoEnabled) applyVideoSafely(); recordVideoCodec(); publish(listener::onConnected);
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
        try { if (localVideo != null) localVideo.setEnabled(false); } catch (Exception ignored) { }
        stopCapture();
        try { if (localVideo != null && localSink != null) localVideo.removeSink(localSink); } catch (Exception ignored) { }
        try { if (remoteVideo != null && remoteSink2 != null) remoteVideo.removeSink(remoteSink2); } catch (Exception ignored) { }
        remoteVideo = null;
        for (AudioTrack track : remoteTracks) try { track.removeSink(remoteSink); } catch (Exception ignored) { }
        remoteTracks.clear();
        try { if (peer != null) { peer.close(); peer.dispose(); } } catch (Exception ignored) { }
        peer = null;
        try { if (localTrack != null) localTrack.dispose(); } catch (Exception ignored) { }
        localTrack = null;
        try { if (source != null) source.dispose(); } catch (Exception ignored) { }
        source = null;
        try { if (localVideo != null) localVideo.dispose(); } catch (Exception ignored) { }
        localVideo = null;
        try { if (videoSource != null) videoSource.dispose(); } catch (Exception ignored) { }
        videoSource = null;
        try { if (factory != null) factory.dispose(); } catch (Exception ignored) { }
        factory = null;
        try { if (audioDevice != null) audioDevice.release(); } catch (Exception ignored) { }
        audioDevice = null;
        try { if (egl != null) egl.release(); } catch (Exception ignored) { }
        egl = null;
        try { if (proximity != null && proximity.isHeld()) proximity.release(); } catch (Exception ignored) { }
        try { if (deviceCallback != null && audio != null) audio.unregisterAudioDeviceCallback(deviceCallback); } catch (Exception ignored) { }
        deviceCallback = null;
        try {
            if (routeOwned) {
                if (Build.VERSION.SDK_INT >= 31) {
                    if (previousDevice == null) audio.clearCommunicationDevice();
                    else audio.setCommunicationDevice(previousDevice);
                } else { legacyBluetooth(false); audio.setSpeakerphoneOn(previousSpeaker); }
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
