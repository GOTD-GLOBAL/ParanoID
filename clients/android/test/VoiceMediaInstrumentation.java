package org.paranoid.text;

import android.app.Instrumentation;
import android.os.Bundle;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Separate, same-signer instrumentation APK only. Never packaged in the app.
 * Drives the actual Android WebRTC engine over an adb-forwarded loopback socket.
 * Synthetic PCM traverses native APM/Opus/DTLS-SRTP; decoded PCM is measured here.
 */
public final class VoiceMediaInstrumentation extends Instrumentation {
    private volatile WebRtcAudioEngine engine;
    private volatile boolean running = true;
    private volatile boolean connected;
    private volatile String descriptionType = "", description = "", error = "";
    private volatile int captureStarts, captureStops, closeCompletions;
    private volatile int immediateRedials, modeAtImmediateRedial = -1;
    private volatile long captureFrames, decodedFrames, decodedSamples;
    private double decodedSquare, decoded440Cos, decoded440Sin;
    private long capturedSamples;
    private int port = 8869;

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        if (args != null && args.containsKey("port")) port = Integer.parseInt(args.getString("port"));
        start();
    }

    private final WebRtcAudioEngine.Listener listener = new WebRtcAudioEngine.Listener() {
        @Override public void onLocalDescription(String type, String sdp) {
            descriptionType = type;
            description = sdp;
        }
        @Override public void onConnected() { connected = true; }
        @Override public void onDisconnected() { connected = false; }
        @Override public void onError(String reason) { error = reason; connected = false; }
    };

    private final WebRtcAudioEngine.Hooks hooks = new WebRtcAudioEngine.Hooks() {
        @Override public long onCapture(ByteBuffer buffer, int format, int channels,
                int rate, int bytes, long timestamp) {
            ByteBuffer pcm = buffer.duplicate().order(ByteOrder.nativeOrder());
            // 880 Hz identifies the Android->peer direction independently of peer->Android 440 Hz.
            int frames = bytes / 2 / channels;
            for (int frame = 0; frame < frames; frame++) {
                short sample = (short) (6000.0 * Math.sin(2.0 * Math.PI * 880.0 * capturedSamples++ / rate));
                for (int channel = 0; channel < channels; channel++) pcm.putShort((frame * channels + channel) * 2, sample);
            }
            captureFrames += frames;
            return timestamp;
        }
        @Override public synchronized void onDecoded(ByteBuffer buffer, int bits, int rate,
                int channels, int frames, long timestamp) {
            if (bits != 16) { error = "Unexpected decoded PCM format"; return; }
            ByteBuffer pcm = buffer.duplicate().order(ByteOrder.nativeOrder());
            for (int frame = 0; frame < frames; frame++) {
                short sample = pcm.getShort(frame * channels * 2);
                double angle = 2.0 * Math.PI * 440.0 * decodedSamples / rate;
                decodedSquare += (double) sample * sample;
                decoded440Cos += sample * Math.cos(angle);
                decoded440Sin += sample * Math.sin(angle);
                decodedSamples++;
            }
            decodedFrames += frames;
        }
        @Override public void onCaptureStarted() { captureStarts++; }
        @Override public void onCaptureStopped() { captureStops++; }
    };

    private JSONObject status() throws Exception {
        JSONObject out = new JSONObject();
        out.put("connected", connected).put("error", error)
                .put("local_type", descriptionType).put("local_sdp", description)
                .put("capture_starts", captureStarts).put("capture_stops", captureStops)
                .put("close_completions", closeCompletions)
                .put("immediate_redials", immediateRedials).put("mode_at_immediate_redial", modeAtImmediateRedial)
                .put("capture_frames", captureFrames).put("decoded_frames", decodedFrames)
                .put("decoded_samples", decodedSamples);
        android.media.AudioManager audio = (android.media.AudioManager) getTargetContext()
                .getSystemService(android.content.Context.AUDIO_SERVICE);
        out.put("audio_mode", audio.getMode()).put("speaker", audio.isSpeakerphoneOn());
        synchronized (hooks) {
            out.put("decoded_rms", decodedSamples == 0 ? 0 : Math.sqrt(decodedSquare / decodedSamples));
            out.put("decoded_440_amplitude", decodedSamples == 0 ? 0 :
                    2.0 * Math.hypot(decoded440Cos, decoded440Sin) / decodedSamples);
        }
        return out;
    }

    private JSONObject command(JSONObject request) throws Exception {
        String kind = request.getString("command");
        if (kind.equals("status")) return status();
        if (kind.equals("offer") || kind.equals("answer_offer")) {
            if (engine != null) throw new IllegalStateException("Close previous fixture call first");
            description = descriptionType = error = "";
            connected = false;
            if (request.has("turn")) {
                JSONObject turn = request.getJSONObject("turn");
                org.webrtc.PeerConnection.IceServer server = org.webrtc.PeerConnection.IceServer
                        .builder("turn:127.0.0.1:34781?transport=tcp")
                        .setUsername(turn.getString("username")).setPassword(turn.getString("password")).createIceServer();
                engine = new WebRtcAudioEngine(getTargetContext(), listener, hooks,
                        java.util.Collections.singletonList(server), true);
            } else engine = new WebRtcAudioEngine(getTargetContext(), listener, hooks);
            engine.setMuted(request.optBoolean("initial_muted"));
            engine.setSpeaker(request.optBoolean("initial_speaker"));
            if (kind.equals("offer")) engine.createOffer();
            else engine.createAnswer(request.getString("sdp"));
        } else if (kind.equals("close_then_offer")) {
            if (engine == null) throw new IllegalStateException("No previous call to close");
            WebRtcAudioEngine previous = engine;
            engine = null;
            connected = false;
            description = descriptionType = error = "";
            previous.close(() -> {
                closeCompletions++;
                android.media.AudioManager audio = (android.media.AudioManager) getTargetContext()
                        .getSystemService(android.content.Context.AUDIO_SERVICE);
                modeAtImmediateRedial = audio.getMode();
                engine = new WebRtcAudioEngine(getTargetContext(), listener, hooks);
                engine.setMuted(request.optBoolean("initial_muted"));
                engine.setSpeaker(request.optBoolean("initial_speaker"));
                engine.createOffer();
                immediateRedials++;
            });
        } else if (kind.equals("set_answer")) {
            engine.setAnswer(request.getString("sdp"));
        } else if (kind.equals("mute")) {
            engine.setMuted(request.getBoolean("muted"));
        } else if (kind.equals("speaker")) {
            engine.setSpeaker(request.getBoolean("speaker"));
        } else if (kind.equals("stats")) {
            final String[] value = {"{}"};
            CountDownLatch ready = new CountDownLatch(1);
            engine.collectStats(json -> { value[0] = json; ready.countDown(); });
            if (!ready.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Stats timed out");
            return new JSONObject(value[0]);
        } else if (kind.equals("close") || kind.equals("finish")) {
            if (engine != null) engine.close(() -> closeCompletions++);
            engine = null;
            connected = false;
            if (kind.equals("finish")) running = false;
        } else throw new IllegalArgumentException("Unknown test command");
        return status();
    }

    private static String line(InputStream in) throws Exception {
        ByteArrayOutputStream value = new ByteArrayOutputStream();
        while (value.size() < 1024) {
            int b = in.read();
            if (b < 0) throw new IllegalStateException("HTTP EOF");
            if (b == '\n') return value.toString("US-ASCII").trim();
            value.write(b);
        }
        throw new IllegalArgumentException("Header too large");
    }

    @Override public void onStart() {
        try (ServerSocket server = new ServerSocket(port, 4, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(1200000);
            while (running) {
                try (Socket socket = server.accept()) {
                    socket.setSoTimeout(10000);
                    InputStream input = socket.getInputStream();
                    if (!line(input).equals("POST / HTTP/1.1")) throw new IllegalArgumentException("POST required");
                    int length = -1;
                    for (int i = 0; i < 32; i++) {
                        String header = line(input);
                        if (header.isEmpty()) break;
                        if (header.toLowerCase(java.util.Locale.ROOT).startsWith("content-length:"))
                            length = Integer.parseInt(header.substring(15).trim());
                    }
                    if (length < 0 || length > 16384) throw new IllegalArgumentException("Body limit");
                    byte[] body = new byte[length];
                    int read = 0;
                    while (read < length) {
                        int count = input.read(body, read, length - read);
                        if (count < 0) throw new IllegalStateException("Body EOF");
                        read += count;
                    }
                    JSONObject reply;
                    try { reply = command(new JSONObject(new String(body, StandardCharsets.UTF_8))); }
                    catch (Exception problem) { reply = new JSONObject().put("fixture_error", problem.toString()); }
                    byte[] bytes = reply.toString().getBytes(StandardCharsets.UTF_8);
                    OutputStream output = socket.getOutputStream();
                    output.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                            + bytes.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    output.write(bytes);
                    output.flush();
                }
            }
            finish(0, new Bundle());
        } catch (Exception failure) {
            Bundle result = new Bundle();
            result.putString("fixture_error", failure.toString());
            finish(1, result);
        } finally {
            if (engine != null) engine.close();
        }
    }
}
