import org.json.JSONObject;
import org.paranoid.text.SnapshotCodec;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;

/**
 * Host-only snapshot-codec vector generator for the iOS cross-check.
 *
 * <p>One JSON object per input line, one per output line, the same private
 * pipe discipline as {@code clients/android/test/VoiceCoreBridge.java}: the
 * key and the plaintext arrive on stdin and leave on stdout, never through
 * argv (where {@code ps} would show them) and never through a file. The
 * caller is {@code clients/ios/test_android_compatibility.py}, which holds
 * both sides of the vector and compares them itself.
 *
 * <p>Requests:
 *
 * <pre>
 * {"op":"seal","key":"&lt;base64 32 bytes&gt;","text":"&lt;plaintext&gt;"}
 *   -&gt; {"sealed":"&lt;base64&gt;","bytes":N}
 * {"op":"open","key":"&lt;base64 32 bytes&gt;","sealed":"&lt;base64&gt;"}
 *   -&gt; {"text":"&lt;plaintext&gt;","bytes":N}
 * </pre>
 *
 * <p>{@code seal} answers a blob for Swift's {@code SnapshotCodec.open} to
 * read; {@code open} reads a blob Swift's {@code SnapshotCodec.seal} wrote.
 * The format is the one both sides implement:
 * {@code [0x01][12-byte nonce][ciphertext‖16-byte tag]} with the version byte
 * as AES-GCM associated data
 * ({@code clients/android/src/org/paranoid/text/SnapshotCodec.java:13-37},
 * {@code ParanoidKit/Sources/ParanoidKit/Storage/SnapshotCodec.swift}).
 *
 * <p>The key is always 32 bytes: AES-256 is what the Android Keystore alias
 * {@code paranoid-text-state-v0} and the iOS Keychain item of the same name
 * hold. A failure answers {@code {"vector_error":"&lt;exception class&gt;"}}
 * and nothing else, so a refused input never echoes private material.
 */
public final class JavaCodecVector {
    /** Longest accepted request line: the codec bound plus base64 overhead. */
    private static final int LINE_LIMIT = 12 * 1024 * 1024;
    /** AES-256, the only key size either storage adapter uses. */
    private static final int KEY_BYTES = 32;

    private JavaCodecVector() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 0) {
            System.err.println("usage: JavaCodecVector (JSON lines on stdin)");
            System.exit(64);
        }
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            JSONObject result;
            byte[] key = null;
            try {
                if (line.length() > LINE_LIMIT) throw new IllegalArgumentException();
                JSONObject request = new JSONObject(line);
                String op = request.getString("op");
                key = decode(request.getString("key"));
                if (key.length != KEY_BYTES) throw new IllegalArgumentException();
                SecretKey secret = new SecretKeySpec(key, "AES");
                if (op.equals("seal")) {
                    byte[] sealed = SnapshotCodec.seal(secret, request.getString("text"));
                    result = new JSONObject()
                        .put("sealed", Base64.getEncoder().encodeToString(sealed))
                        .put("bytes", sealed.length);
                } else if (op.equals("open")) {
                    byte[] sealed = decode(request.getString("sealed"));
                    String text = SnapshotCodec.open(secret, sealed);
                    result = new JSONObject()
                        .put("text", text)
                        .put("bytes", sealed.length);
                } else {
                    throw new IllegalArgumentException();
                }
            } catch (Throwable error) {
                // Only the exception class travels: a JSON or codec message
                // must never carry the key, the box or the plaintext.
                result = new JSONObject().put("vector_error", error.getClass().getSimpleName());
            } finally {
                if (key != null) Arrays.fill(key, (byte) 0);
            }
            System.out.println(result.toString());
            System.out.flush();
        }
    }

    private static byte[] decode(String value) {
        return Base64.getDecoder().decode(value);
    }
}
