import org.paranoid.text.SnapshotCodec;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import java.security.GeneralSecurityException;
import java.util.Arrays;

public final class StorageSmoke {
    public static void main(String[] args) throws Exception {
        KeyGenerator generator=KeyGenerator.getInstance("AES");generator.init(256);
        SecretKey key=generator.generateKey();String text="[TEST ONLY] секрет и сообщение 🎈";
        byte[] first=SnapshotCodec.seal(key,text), second=SnapshotCodec.seal(key,text);
        if(Arrays.equals(first,second))throw new AssertionError("nonce reused");
        if(!SnapshotCodec.open(key,first).equals(text))throw new AssertionError("roundtrip failed");
        byte[] tampered=first.clone();tampered[tampered.length-1]^=1;
        try {SnapshotCodec.open(key,tampered);throw new AssertionError("tampering accepted");}catch(GeneralSecurityException expected){}
        try {SnapshotCodec.open(generator.generateKey(),first);throw new AssertionError("wrong key accepted");}catch(GeneralSecurityException expected){}
        tampered=first.clone();tampered[0]=2;
        try {SnapshotCodec.open(key,tampered);throw new AssertionError("unknown version accepted");}catch(GeneralSecurityException expected){}
        System.out.println("Snapshot codec: PASS (JVM crypto, not Android Keystore)");
    }
}
