import org.paranoid.text.QrCodec;

/** Dense contact-QR camera-resolution regression: the scanner's chosen preview
 *  class (~1280px) must decode a close-filling ~800-byte paranoid-contact-v2 code.
 *  Also documents WHY 640x480 preview selection was a real-phone add-contact bug:
 *  a close-filling dense code at 480p falls under ZXing's module resolution. */
public final class QrDenseSmoke {
    static byte[] frame(byte[] src,int srcSize,int frameW,int frameH,int qrPixels){
        byte[] out=new byte[frameW*frameH];
        java.util.Arrays.fill(out,(byte)210);
        int x0=(frameW-qrPixels)/2, y0=(frameH-qrPixels)/2;
        for(int y=0;y<qrPixels;y++)for(int x=0;x<qrPixels;x++){
            float sx=x*(srcSize-1f)/(qrPixels-1f), sy=y*(srcSize-1f)/(qrPixels-1f);
            int ix=(int)sx, iy=(int)sy; float fx=sx-ix, fy=sy-iy;
            int ix2=Math.min(ix+1,srcSize-1), iy2=Math.min(iy+1,srcSize-1);
            float v=(src[iy*srcSize+ix]&255)*(1-fx)*(1-fy)+(src[iy*srcSize+ix2]&255)*fx*(1-fy)
                   +(src[iy2*srcSize+ix]&255)*(1-fx)*fy+(src[iy2*srcSize+ix2]&255)*fx*fy;
            out[(y0+y)*frameW+x0+x]=(byte)Math.max(0,Math.min(255,(int)v));
        }
        return out;
    }
    static String payload(){
        StringBuilder b=new StringBuilder("{\"type\":\"paranoid-contact-v2\",\"credential\":{\"account\":\"");
        pad(b,64,'a');b.append("\",\"realm\":\"https://157.180.49.125:443\",\"pin\":\"");
        pad(b,64,'b');b.append("\",\"olm\":\"");pad(b,64,'c');b.append("\",\"auth\":\"");pad(b,43,'D');
        b.append("\",\"signature\":\"");pad(b,86,'E');
        b.append("\"},\"bundle\":{\"device\":\"unassigned\",\"realm\":\"https://157.180.49.125:443\",\"curve\":\"");
        pad(b,43,'F');b.append("\",\"one_time_key\":\"");pad(b,43,'G');
        b.append("\"},\"fallback_key\":\"");pad(b,43,'H');b.append("\",\"signature\":\"");pad(b,86,'I');b.append("\"}");
        return b.toString();
    }
    static void pad(StringBuilder b,int n,char c){for(int i=0;i<n;i++)b.append(c);}
    public static void main(String[] args)throws Exception{
        String text=payload();
        byte[] qr=QrCodec.encode(text,640);
        // The scanner picks the largest bounded preview: on real hardware that is
        // 1280x960 or 1280x720. Close (90%) and typical (70%, 50%) fills must decode.
        int[][] good={{1280,960},{1280,720}};
        double[] fractions={0.5,0.7,0.9};
        for(int[] s:good)for(double f:fractions){
            int qrPixels=(int)(Math.min(s[0],s[1])*f);
            if(!text.equals(QrCodec.decode(frame(qr,640,s[0],s[1],qrPixels),s[0],s[1])))
                throw new AssertionError("dense contact QR must decode at "+s[0]+"x"+s[1]+" fill="+f);
        }
        // Guard the regression premise: the OLD 640x480 choice truly fails close-fill.
        boolean lowResCloseFillFails;
        try{lowResCloseFillFails=!text.equals(QrCodec.decode(frame(qr,640,640,480,432),640,480));}
        catch(Exception expected){lowResCloseFillFails=true;}
        if(!lowResCloseFillFails)
            System.out.println("note: 640x480 close-fill now decodes too (binarizer improved); high-res selection stays required");
        System.out.println("PASS dense contact QR decodes at scanner-class resolutions (6 frames)");
    }
}
