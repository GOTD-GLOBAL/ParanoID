package org.paranoid.text;
import com.google.zxing.*;
import com.google.zxing.common.*;
import com.google.zxing.qrcode.*;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.*;
/** Local-only bounded ZXing core adapter. QR contents never confer trust alone. */
public final class QrCodec {
    private QrCodec(){}
    public static byte[] encode(String raw,int size) throws IOException {
        if(raw==null || raw.isEmpty() || raw.getBytes(StandardCharsets.UTF_8).length>2048 || size<256 || size>1280)throw new IOException("QR limit");
        try {
            Map<EncodeHintType,Object> hints=new EnumMap<>(EncodeHintType.class);
            hints.put(EncodeHintType.CHARACTER_SET,"UTF-8");hints.put(EncodeHintType.ERROR_CORRECTION,ErrorCorrectionLevel.M);hints.put(EncodeHintType.MARGIN,4);
            BitMatrix matrix=new QRCodeWriter().encode(raw,BarcodeFormat.QR_CODE,size,size,hints);
            byte[] out=new byte[size*size];for(int y=0;y<size;y++)for(int x=0;x<size;x++)out[y*size+x]=(byte)(matrix.get(x,y)?0:255);
            return out;
        }catch(Exception error){throw new IOException("QR encoding failed");}
    }
    public static String decode(byte[] luma,int width,int height) throws IOException {
        if(width<1 || height<1 || width>1280 || height>1280 || luma==null || luma.length<width*height || luma.length>1280*1280*2)throw new IOException("frame limit");
        try {
            LuminanceSource source=new PlanarYUVLuminanceSource(luma,width,height,0,0,width,height,false);
            BinaryBitmap bitmap=new BinaryBitmap(new HybridBinarizer(source));
            String raw;
            try {raw=new QRCodeReader().decode(bitmap).getText();}
            catch(ReaderException notDecoded) {
                // Finder heuristics can miss or mislocate pristine axis-aligned QR.
                // Preserve perspective-aware camera detection first; the fallback
                // still runs ZXing's format/ECC decoder and all caller validation.
                Map<DecodeHintType,Object> hints=new EnumMap<>(DecodeHintType.class);
                hints.put(DecodeHintType.PURE_BARCODE,Boolean.TRUE);
                raw=new QRCodeReader().decode(bitmap,hints).getText();
            }
            if(raw.getBytes(StandardCharsets.UTF_8).length>2048)throw new IOException("QR limit");return raw;
        }catch(Exception error){throw new IOException("QR not recognized");}
    }
}
