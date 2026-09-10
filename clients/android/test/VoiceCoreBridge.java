import org.paranoid.text.CoreBridge;
import org.paranoid.text.SelfServiceClient;
import org.paranoid.text.SnapshotCodec;
import org.json.JSONObject;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/** Test-only private pipe bridge. Snapshot/keys are never written to a log/file. */
public final class VoiceCoreBridge {
    public static void main(String[] args) throws Exception {
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            JSONObject result;
            try {
                if (line.length() > 10 * 1024 * 1024) throw new IllegalArgumentException();
                JSONObject request = new JSONObject(line);
                if (request.getString("kind").equals("core")) {
                    result = new JSONObject(CoreBridge.command(request.getString("state"), request.getJSONObject("request").toString()));
                } else if (request.getString("kind").equals("sealed_reopen")) {
                    String saved = request.getJSONObject("snapshot").toString();
                    KeyGenerator generator = KeyGenerator.getInstance("AES");
                    generator.init(256);
                    SecretKey key = generator.generateKey();
                    byte[] encrypted = SnapshotCodec.seal(key, saved);
                    String reopened = SnapshotCodec.open(key, encrypted);
                    if (!saved.equals(reopened)) throw new AssertionError("codec changed snapshot");
                    int[] writes = {0};
                    SelfServiceClient client = new SelfServiceClient(reopened, value -> writes[0]++);
                    if (writes[0] != 0) throw new AssertionError("opening wrote snapshot");
                    result = new JSONObject().put("view", client.publicView()).put("writes", writes[0])
                        .put("sealed_bytes", encrypted.length).put("unchanged", saved.equals(reopened));
                } else throw new IllegalArgumentException();
            } catch (Throwable error) {
                // Error messages from JSON/native code must never dump private inputs.
                result = new JSONObject().put("fixture_error", error.getClass().getSimpleName());
            }
            System.out.println(result.toString());
            System.out.flush();
        }
    }
}
