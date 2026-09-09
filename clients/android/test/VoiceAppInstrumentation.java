package org.paranoid.text;

import android.app.Instrumentation;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;

/** Separate same-signer test APK: observes the real app; UI owns call consent. */
public final class VoiceAppInstrumentation extends Instrumentation {
    private static final int PORT = 8870;
    private volatile boolean running = true;
    private TextEngine engine;
    private CountDownLatch heldMediaOwner;
    private static final Set<String> STATS = new HashSet<>(Arrays.asList(
        "id", "type", "bytesReceived", "bytesSent", "packetsReceived", "packetsSent",
        "packetsLost", "jitter", "jitterBufferDelay", "jitterBufferEmittedCount",
        "jitterBufferTargetDelay", "jitterBufferMinimumDelay", "totalSamplesReceived",
        "totalSamplesDuration", "totalAudioEnergy", "audioLevel", "concealedSamples",
        "silentConcealedSamples", "insertedSamplesForDeceleration", "removedSamplesForAcceleration",
        "totalDecodeTime", "codecId", "mimeType", "clockRate", "channels", "roundTripTime",
        "currentRoundTripTime", "availableOutgoingBitrate", "selectedCandidatePairId",
        "dtlsState", "iceState", "state", "nominated", "localCandidateId", "remoteCandidateId",
        "candidateType", "protocol", "address", "port", "transportId", "kind", "mediaType"));

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }

    private static Object field(Object object, String name) throws Exception {
        Field field = object.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(object);
    }

    private JSONObject view() throws Exception {
        ExecutorService owner = (ExecutorService) field(engine, "worker");
        String text = owner.submit(() -> {
            SelfServiceClient client = (SelfServiceClient) field(engine, "client");
            return client == null ? "{}" : client.publicView().toString();
        }).get(5, TimeUnit.SECONDS);
        final JSONObject[] result = {null};
        final Exception[] failure = {null};
        runOnMainSync(() -> {
            try {
                AudioManager audio = (AudioManager) getTargetContext().getSystemService(Context.AUDIO_SERVICE);
                result[0] = new JSONObject().put("text", new JSONObject(text)).put("call", engine.calls().snapshot())
                    .put("media_present", field(engine, "media") != null).put("media_closing", field(engine, "mediaClosing"))
                    .put("audio_mode", audio.getMode()).put("speaker", audio.isSpeakerphoneOn())
                    .put("active_recordings", audio.getActiveRecordingConfigurations().size())
                    .put("media_owner_held", heldMediaOwner != null && heldMediaOwner.getCount() != 0);
            } catch (Exception error) { failure[0] = error; }
        });
        if (failure[0] != null) throw failure[0];
        return result[0];
    }

    private JSONObject mediaStats() throws Exception {
        final WebRtcAudioEngine[] current = {null};
        final Exception[] failure = {null};
        runOnMainSync(() -> { try { current[0] = (WebRtcAudioEngine) field(engine, "media"); }
                            catch (Exception error) { failure[0] = error; } });
        if (failure[0] != null) throw failure[0];
        if (current[0] == null) return new JSONObject().put("media_present", false).put("stats", new JSONArray());
        final String[] raw = {"{}"};
        CountDownLatch ready = new CountDownLatch(1);
        current[0].collectStats(value -> { raw[0] = value; ready.countDown(); });
        if (!ready.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("stats deadline");
        JSONArray input = new JSONObject(raw[0]).optJSONArray("stats"), output = new JSONArray();
        if (input != null) for (int n = 0; n < input.length(); n++) {
            JSONObject stat = input.getJSONObject(n), safe = new JSONObject();
            for (String key : STATS) if (stat.has(key)) safe.put(key, stat.get(key));
            if (!safe.optString("type").equals("certificate")) output.put(safe);
        }
        return new JSONObject().put("media_present", true).put("stats", output);
    }

    private JSONObject mediaSettings() throws Exception {
        final WebRtcAudioEngine[] current = {null};
        final JSONObject[] observed = {null};
        final Exception[] failure = {null};
        final long[] generation = {-1};
        runOnMainSync(() -> {
            try {
                current[0] = (WebRtcAudioEngine) field(engine, "media");
                generation[0] = engine.calls().snapshot().optLong("generation");
            } catch (Exception error) { failure[0] = error; }
        });
        if (failure[0] != null) throw failure[0];
        if (current[0] == null) return new JSONObject().put("media_present", false)
                .put("generation", generation[0]);
        android.os.Handler owner = (android.os.Handler) field(current[0], "worker");
        CountDownLatch ready = new CountDownLatch(1);
        if (!owner.post(() -> {
            try {
                org.webrtc.AudioTrack track = (org.webrtc.AudioTrack) field(current[0], "localTrack");
                observed[0] = new JSONObject().put("media_present", true)
                        .put("generation", generation[0])
                        .put("engine_muted", field(current[0], "muted"))
                        .put("engine_speaker", field(current[0], "speaker"))
                        .put("track_present", track != null)
                        .put("track_enabled", track == null ? JSONObject.NULL : track.enabled())
                        .put("engine_closed", ((java.util.concurrent.atomic.AtomicBoolean)
                                field(current[0], "closed")).get())
                        .put("observed_on_media_owner", android.os.Looper.myLooper() == owner.getLooper());
            } catch (Exception error) { failure[0] = error; }
            finally { ready.countDown(); }
        })) throw new IllegalStateException("media owner stopped");
        if (!ready.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("media settings deadline");
        if (failure[0] != null) throw failure[0];
        final boolean[] same = {false};
        runOnMainSync(() -> {
            try { same[0] = field(engine, "media") == current[0]
                    && engine.calls().snapshot().optLong("generation") == generation[0]; }
            catch (Exception error) { failure[0] = error; }
        });
        if (failure[0] != null) throw failure[0];
        return observed[0].put("still_current", same[0]);
    }

    private JSONObject command(JSONObject request) throws Exception {
        String name = request.getString("command");
        if (name.equals("view")) return view();
        if (name.equals("media_stats")) return mediaStats();
        if (name.equals("media_settings")) return mediaSettings();
        if (name.equals("hold_media_owner")) {
            if (heldMediaOwner != null && heldMediaOwner.getCount() != 0)
                throw new IllegalStateException("media owner already held");
            final Object[] current = {null};
            final Exception[] failure = {null};
            runOnMainSync(() -> { try { current[0] = field(engine, "media"); }
                                catch (Exception error) { failure[0] = error; } });
            if (failure[0] != null) throw failure[0];
            if (current[0] == null) throw new IllegalStateException("actual media required");
            android.os.Handler owner = (android.os.Handler) field(current[0], "worker");
            CountDownLatch release = new CountDownLatch(1), entered = new CountDownLatch(1);
            heldMediaOwner = release;
            if (!owner.post(() -> {
                entered.countDown();
                try { release.await(30, TimeUnit.SECONDS); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
                finally { release.countDown(); }
            })) { release.countDown(); throw new IllegalStateException("media owner stopped"); }
            if (!entered.await(3, TimeUnit.SECONDS)) {
                release.countDown(); throw new IllegalStateException("media owner barrier deadline");
            }
            return new JSONObject().put("media_owner_held", true).put("watchdog_ms", 30000);
        }
        if (name.equals("release_media_owner")) {
            if (heldMediaOwner != null) heldMediaOwner.countDown();
            heldMediaOwner = null;
            return new JSONObject().put("media_owner_held", false);
        }
        if (name.equals("clipboard")) {
            String value = request.getString("text");
            if (value.length() > 4096 || !new JSONObject(value).optString("type").equals("paranoid-contact-v2"))
                throw new IllegalArgumentException("public contact required");
            runOnMainSync(() -> ((ClipboardManager) getTargetContext().getSystemService(Context.CLIPBOARD_SERVICE))
                .setPrimaryClip(ClipData.newPlainText("Synthetic public contact", value)));
            return new JSONObject().put("clipboard_set", true);
        }
        if (name.equals("stale_stop")) {
            String id = request.getString("call_id");
            if (!id.matches("[0-9a-f-]{36}")) throw new IllegalArgumentException("call id required");
            long generation = request.getLong("generation");
            runOnMainSync(() -> getTargetContext().startService(new Intent(getTargetContext(), VoiceCallService.class)
                .setAction("org.paranoid.devtext.END_CALL").setData(Uri.parse("paranoid-call-end:" + id))
                .putExtra("call_id", id).putExtra("generation", generation)));
            return new JSONObject().put("stop_dispatched", true);
        }
        if (name.equals("finish")) {
            if (heldMediaOwner != null) heldMediaOwner.countDown();
            running = false; return new JSONObject().put("finished", true);
        }
        throw new IllegalArgumentException("unsupported test command");
    }

    private static String line(InputStream input) throws Exception {
        ByteArrayOutputStream value = new ByteArrayOutputStream();
        while (value.size() < 1024) {
            int b = input.read();
            if (b < 0) throw new IllegalStateException("HTTP EOF");
            if (b == '\n') return value.toString("US-ASCII").trim();
            value.write(b);
        }
        throw new IllegalArgumentException("header bound");
    }

    private static JSONObject request(Socket socket) throws Exception {
        InputStream input = socket.getInputStream();
        if (!line(input).equals("POST / HTTP/1.1")) throw new IllegalArgumentException("POST required");
        int length = -1;
        boolean terminated = false;
        for (int count = 0; count < 32; count++) {
            String header = line(input);
            if (header.isEmpty()) { terminated = true; break; }
            if (header.toLowerCase(Locale.ROOT).startsWith("content-length:")) {
                if (length != -1) throw new IllegalArgumentException("duplicate length");
                length = Integer.parseInt(header.substring(15).trim());
            }
        }
        if (!terminated || length < 0 || length > 8192) throw new IllegalArgumentException("body bound");
        byte[] body = new byte[length];
        int read = 0;
        while (read < length) {
            int count = input.read(body, read, length - read);
            if (count < 0) throw new IllegalStateException("body EOF");
            read += count;
        }
        return new JSONObject(new String(body, StandardCharsets.UTF_8));
    }

    @Override public void onStart() {
        try {
            runOnMainSync(() -> engine = TextEngine.get(getTargetContext()));
            try (ServerSocket server = new ServerSocket(PORT, 4, InetAddress.getByName("127.0.0.1"))) {
                server.setSoTimeout(1_200_000);
                while (running) try (Socket socket = server.accept()) {
                    socket.setSoTimeout(10000);
                    JSONObject reply;
                    try { reply = command(request(socket)); }
                    catch (Exception error) { reply = new JSONObject().put("fixture_error", error.getClass().getSimpleName()); }
                    byte[] bytes = reply.toString().getBytes(StandardCharsets.UTF_8);
                    OutputStream out = socket.getOutputStream();
                    out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + bytes.length
                        + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    out.write(bytes); out.flush();
                }
            }
            finish(0, new Bundle());
        } catch (Exception error) {
            Bundle result = new Bundle();
            result.putString("fixture_error", error.getClass().getSimpleName());
            finish(1, result);
        } finally { if (heldMediaOwner != null) heldMediaOwner.countDown(); }
    }
}
