import org.paranoid.text.QrCodec;
import java.util.Random;
import java.util.UUID;
public class QrDiverseSmoke {
 public static void main(String[] args) throws Exception {
  Random r = new Random(20260908L);
  for(int i=0;i<200;i++) {
   String text="{\"type\":\"paranoid-grant-v1\",\"id\":\""+new UUID(r.nextLong(),r.nextLong())+"\",\"credential\":\""+hex(r)+"\",\"realm\":\"https://127.0.0.2:38443\",\"pin\":\""+hex(r)+"\",\"slot\":1,\"expires\":1788900000}";
   byte[] pixels=QrCodec.encode(text,640);
   try {if(!text.equals(QrCodec.decode(pixels,640,640)))throw new AssertionError("mismatch");}
   catch(Exception e){throw new AssertionError("deterministic public fixture QR index="+i+" seed=20260908",e);}
  }
  System.out.println("PASS 200 deterministic diverse public grant QR render/decode roundtrips");
 }
 static String hex(Random r){StringBuilder s=new StringBuilder();for(int i=0;i<32;i++)s.append(String.format("%02x",r.nextInt(256)));return s.toString();}
}
