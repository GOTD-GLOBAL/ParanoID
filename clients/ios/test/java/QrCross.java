import org.json.JSONObject;
import org.paranoid.text.QrCodec;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;

/**
 * Host-only ZXing side of the QR cross-check between iOS and Android.
 *
 * <p>One JSON object per input line, one per output line, the same private
 * pipe discipline as {@code clients/android/test/VoiceCoreBridge.java}. The
 * caller is {@code clients/ios/test_qr_cross.py}: it asks Swift's
 * {@code QrCodec} for a code, hands the PNG here to be decoded by the very
 * ZXing build the Android client ships, then asks for a ZXing-encoded PNG of
 * the same contact and hands that back to Swift.
 *
 * <p>Requests:
 *
 * <pre>
 * {"op":"encode","text":"&lt;payload&gt;","size":640}
 *   -&gt; {"png":"&lt;base64&gt;","width":N,"height":N,"sha256":"&lt;hex&gt;"}
 * {"op":"decode","png":"&lt;base64&gt;"}
 *   -&gt; {"text":"&lt;payload&gt;","width":N,"height":N}
 * </pre>
 *
 * <p>The image travels as base64 inside the line rather than as a file, so no
 * path of this machine reaches an evidence file and no temporary copy of a
 * contact is left on disk. Both bounds belong to
 * {@code clients/android/src/org/paranoid/text/QrCodec.java}: at most 2048
 * UTF-8 bytes of payload, sides between 256 and 1280 pixels. Nothing here
 * parses a contact or confers trust — a QR carries public data only, and the
 * fingerprint is still compared on the other phone
 * ({@code docs/protocol/first-contact-v1.md:90-91}).
 *
 * <p>{@code encode} writes an 8-bit grayscale PNG straight from the luma
 * plane ZXing produced, one byte per pixel, so the file is exactly the
 * modules with no interpolation. {@code decode} accepts any PNG readable by
 * {@code ImageIO} — Swift's {@code CIQRCodeGenerator} output is RGB — and
 * folds it to the luma plane {@code QrCodec.decode} expects with the BT.601
 * integer weights; alpha is ignored, as both encoders composite over white.
 * A failure answers {@code {"qr_error":"&lt;exception class&gt;"}} only.
 */
public final class QrCross {
    /** Longest accepted request line: the PNG bound plus base64 overhead. */
    private static final int LINE_LIMIT = 8 * 1024 * 1024;
    /** Largest PNG this fixture will decode, before any pixel is touched. */
    private static final int PNG_LIMIT = 4 * 1024 * 1024;
    /** Largest side, the frame bound of {@code QrCodec.java:23}. */
    private static final int SIDE_LIMIT = 1280;

    private QrCross() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 0) {
            System.err.println("usage: QrCross (JSON lines on stdin)");
            System.exit(64);
        }
        // No display is ever opened; ImageIO only needs the raster.
        System.setProperty("java.awt.headless", "true");
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            JSONObject result;
            try {
                if (line.length() > LINE_LIMIT) throw new IllegalArgumentException();
                JSONObject request = new JSONObject(line);
                String op = request.getString("op");
                if (op.equals("encode")) {
                    int size = request.getInt("size");
                    byte[] png = encode(request.getString("text"), size);
                    result = new JSONObject()
                        .put("png", Base64.getEncoder().encodeToString(png))
                        .put("width", size)
                        .put("height", size)
                        .put("sha256", sha256(png));
                } else if (op.equals("decode")) {
                    byte[] png = Base64.getDecoder().decode(request.getString("png"));
                    if (png.length > PNG_LIMIT) throw new IllegalArgumentException();
                    BufferedImage image = ImageIO.read(new ByteArrayInputStream(png));
                    if (image == null) throw new IOException("not an image");
                    int width = image.getWidth();
                    int height = image.getHeight();
                    if (width < 1 || height < 1 || width > SIDE_LIMIT || height > SIDE_LIMIT) {
                        throw new IOException("frame limit");
                    }
                    result = new JSONObject()
                        .put("text", QrCodec.decode(luma(image, width, height), width, height))
                        .put("width", width)
                        .put("height", height);
                } else {
                    throw new IllegalArgumentException();
                }
            } catch (Throwable error) {
                // Only the exception class travels: a ZXing or JSON message
                // must never carry the payload of a scanned contact.
                result = new JSONObject().put("qr_error", error.getClass().getSimpleName());
            }
            System.out.println(result.toString());
            System.out.flush();
        }
    }

    /** The shipped ZXing encoder, rendered as an 8-bit grayscale PNG. */
    private static byte[] encode(String text, int size) throws IOException {
        byte[] plane = QrCodec.encode(text, size);
        BufferedImage image = new BufferedImage(size, size, BufferedImage.TYPE_BYTE_GRAY);
        image.getRaster().setDataElements(0, 0, size, size, plane);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (!ImageIO.write(image, "png", out)) throw new IOException("no PNG writer");
        return out.toByteArray();
    }

    /** One luma byte per pixel, the plane {@code QrCodec.decode} reads. */
    private static byte[] luma(BufferedImage image, int width, int height) {
        int[] pixels = image.getRGB(0, 0, width, height, null, 0, width);
        byte[] plane = new byte[width * height];
        for (int index = 0; index < plane.length; index++) {
            int pixel = pixels[index];
            int red = (pixel >> 16) & 0xff;
            int green = (pixel >> 8) & 0xff;
            int blue = pixel & 0xff;
            plane[index] = (byte) ((77 * red + 150 * green + 29 * blue) >> 8);
        }
        return plane;
    }

    private static String sha256(byte[] value) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
        StringBuilder text = new StringBuilder(digest.length * 2);
        for (byte b : digest) text.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        return text.toString();
    }
}
