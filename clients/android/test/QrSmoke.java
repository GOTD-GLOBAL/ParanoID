import org.paranoid.text.QrCodec;
import java.io.IOException;
public final class QrSmoke {
    public static void main(String[] args) throws Exception {
        String value="{\"type\":\"paranoid-request-v1\",\"public\":\"Тест\"}";
        byte[] pixels=QrCodec.encode(value,640);
        if(!value.equals(QrCodec.decode(pixels,640,640)))throw new AssertionError("OSS QR roundtrip failed");
        try {QrCodec.encode(new String(new char[4097]).replace('\0','x'),640);throw new AssertionError("QR oversized accepted");}catch(IOException expected){}
        try {QrCodec.decode(new byte[9],640,640);throw new AssertionError("invalid frame accepted");}catch(IOException expected){}
        System.out.println("PASS: ZXing QR encode/decode UTF-8 roundtrip, input/frame bounds; camera/OPPO NOT RUN");
    }
}
