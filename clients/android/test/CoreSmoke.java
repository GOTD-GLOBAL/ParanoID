import org.paranoid.text.CoreBridge;

public final class CoreSmoke {
    public static void main(String[] args) {
        String initialized = CoreBridge.command("", "{\"op\":\"init\",\"device\":\"alice\",\"realm\":\"https://test.invalid\"}");
        if (initialized == null || !initialized.contains("\"state\"") || !initialized.contains("\"public\"")) throw new AssertionError("JNI initialization failed");
        String rejected = CoreBridge.command("invalid-state", "{}");
        if (rejected == null || !rejected.contains("\"error\"")) throw new AssertionError("JNI did not reject invalid request");
        System.out.println("JNI string boundary: PASS (Linux JVM, not Android device)");
    }
}
