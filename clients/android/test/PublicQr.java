import org.paranoid.text.QrCodec;
import org.json.JSONObject;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;
import java.io.OutputStream;
/** Operator-side public descriptor renderer. This does not approve an identity. */
public final class PublicQr {
    public static void main(String[] args)throws Exception {
        if(args.length!=2)throw new IllegalArgumentException("public descriptor JSON and new PNG paths required");
        Path source=Paths.get(args[0]);if(Files.size(source)>4096)throw new IllegalArgumentException("QR limit");
        String text=new String(Files.readAllBytes(source),StandardCharsets.UTF_8);
        String type=new JSONObject(text).getString("type");
        if(!type.equals("paranoid-grant-v1")&&!type.equals("paranoid-request-v1")&&!type.equals("paranoid-contact-v1"))throw new IllegalArgumentException("public descriptor type required");
        byte[] pixels=QrCodec.encode(text,640);if(!text.equals(QrCodec.decode(pixels,640,640)))throw new IllegalStateException("QR self-check failed");
        BufferedImage image=new BufferedImage(640,640,BufferedImage.TYPE_INT_RGB);
        for(int y=0;y<640;y++)for(int x=0;x<640;x++)image.setRGB(x,y,(pixels[y*640+x]&255)==0?0:0xffffff);
        try(OutputStream out=Files.newOutputStream(Paths.get(args[1]),StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE)){if(!ImageIO.write(image,"PNG",out))throw new IllegalStateException("PNG writer missing");}
        System.out.println("Public descriptor QR PNG created and roundtrip-checked");
    }
}
