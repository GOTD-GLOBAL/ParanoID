import org.paranoid.text.*;
import org.json.JSONObject;
import javax.crypto.spec.SecretKeySpec;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;

/** Disposable encrypted phone snapshots. No private data is returned over stdout. */
public final class RegistrationBridge {
    public static void main(String[] args) throws Exception {
        Path root=Paths.get(args[0]);Files.createDirectories(root);
        Map<String,KeyClient> clients=new HashMap<>();
        BufferedReader in=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));String line;
        while((line=in.readLine())!=null) {
            JSONObject out;
            try {
                String[] p=line.split("\t",-1);if(!p[0].equals("one")&&!p[0].equals("two"))throw new IOException("fixture phone required");
                KeyClient client=clients.get(p[0]);
                if(client==null) {
                    Path snapshot=root.resolve(p[0]+".enc"),keyFile=root.resolve(p[0]+".key");
                    byte[] key;
                    if(Files.exists(keyFile))key=Files.readAllBytes(keyFile);
                    else {if(Files.exists(snapshot))throw new IOException("missing fixture storage key");key=new byte[32];new SecureRandom().nextBytes(key);Files.write(keyFile,key,StandardOpenOption.CREATE_NEW);}
                    SecretKeySpec wrapping=new SecretKeySpec(key,"AES");
                    String saved=Files.exists(snapshot)?SnapshotCodec.open(wrapping,Files.readAllBytes(snapshot)):null;
                    client=new KeyClient(saved,value->{
                        byte[] encrypted=SnapshotCodec.seal(wrapping,value);Path next=root.resolve(p[0]+".next");
                        try(FileOutputStream f=new FileOutputStream(next.toFile())){f.write(encrypted);f.getFD().sync();}
                        Files.move(next,snapshot,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
                        if(!Arrays.equals(encrypted,Files.readAllBytes(snapshot)))throw new IOException("fixture commit mismatch");
                    },args[1],args[2]);
                    clients.put(p[0],client);
                }
                String value=new String(Base64.getDecoder().decode(p[2]),StandardCharsets.UTF_8);
                if(p[1].equals("grant")||p[1].equals("pair"))value=QrCodec.decode(QrCodec.encode(value,640),640,640);
                switch(p[1]) {
                    case "create":client.createIdentity();break;
                    case "grant":client.importGrant(value);client.sync();break;
                    case "pair":client.pair(value,true);break;
                    case "send":client.send(value);client.sync();break;
                    case "sync":client.sync();break;
                    case "view":break;
                    default:throw new IOException("unsupported fixture operation");
                }
                out=client.publicView();
                for(String type:new String[]{"request","contact"})if(out.has(type)) {
                    String raw=out.getJSONObject(type).toString();
                    if(!raw.equals(QrCodec.decode(QrCodec.encode(raw,640),640,640)))throw new AssertionError("typed public QR roundtrip failed");
                }
            } catch(Exception e){
                System.err.println("Fixture exception type: "+e.getClass().getName());
                for(StackTraceElement frame:e.getStackTrace())System.err.println(frame.toString());
                out=new JSONObject().put("error",e instanceof SyncCycle.Rejected?"http_"+((SyncCycle.Rejected)e).status:"fixture_operation_failed");
            }
            System.out.println(Base64.getEncoder().encodeToString(out.toString().getBytes(StandardCharsets.UTF_8)));System.out.flush();
        }
    }
}
