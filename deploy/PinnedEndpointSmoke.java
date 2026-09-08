import java.net.URL;
import java.io.IOException;
import javax.net.ssl.HttpsURLConnection;
import org.paranoid.text.PinnedTls;

/** Actual Android TLS adapter against the native Rust TLS endpoint, no token. */
public final class PinnedEndpointSmoke {
    static void check(String url, String pin, boolean allowed) throws Exception {
        URL endpoint = new URL(url + "/health");
        HttpsURLConnection connection = (HttpsURLConnection) endpoint.openConnection();
        connection.setSSLSocketFactory(PinnedTls.factory(endpoint.getHost(), pin));
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(3000);
        connection.setReadTimeout(3000);
        boolean connected = false;
        try {
            connected = connection.getResponseCode() == 200;
        } catch (IOException rejected) {
            if (allowed) throw rejected;
        } finally {
            connection.disconnect();
        }
        if (connected != allowed) throw new AssertionError("native TLS pin mismatch");
    }
    public static void main(String[] args) throws Exception {
        check(args[0], args[1], true);
        check(args[0], "00".repeat(32), false);
        System.out.println("PASS: Android PinnedTls JVM adapter accepts native Rust TLS SPKI, rejects wrong pin");
    }
}
