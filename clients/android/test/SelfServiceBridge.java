import org.paranoid.text.*;
import org.json.JSONObject;
import javax.crypto.spec.SecretKeySpec;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;
import java.lang.reflect.*;

/** Real JNI/network fixture; synthetic encrypted snapshots, public-only RPC output. */
public final class SelfServiceBridge {
    public static void main(String[] args) throws Exception {
        Path root=Paths.get(args[0]);Files.createDirectories(root);
        Map<String,Object> clients=new HashMap<>();
        Class<?> type=SelfServiceClient.class;
        BufferedReader in=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));String line;
        while((line=in.readLine())!=null) {
            JSONObject out;
            try {
                String[] p=line.split("\t",-1);if(!p[0].matches("one|two|three"))throw new IOException("synthetic phone required");
                Object client=clients.get(p[0]);
                if(client==null) {
                    Path snapshot=root.resolve(p[0]+".enc"),keyFile=root.resolve(p[0]+".key");
                    StorageGuard.requireContinuity(Files.exists(snapshot),Files.exists(keyFile));
                    byte[] key;
                    if(Files.exists(keyFile))key=Files.readAllBytes(keyFile);
                    else {key=new byte[32];new SecureRandom().nextBytes(key);Files.write(keyFile,key,StandardOpenOption.CREATE_NEW);}
                    SecretKeySpec wrapping=new SecretKeySpec(key,"AES");
                    String saved=Files.exists(snapshot)?SnapshotCodec.open(wrapping,Files.readAllBytes(snapshot)):null;
                    KeyClient.Commit commit=value->{
                        byte[] encrypted=SnapshotCodec.seal(wrapping,value);Path next=root.resolve(p[0]+".next");
                        try(FileOutputStream f=new FileOutputStream(next.toFile())){f.write(encrypted);f.getFD().sync();}
                        Files.move(next,snapshot,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
                        if(!Arrays.equals(encrypted,Files.readAllBytes(snapshot)))throw new IOException("fixture commit mismatch");
                    };
                    client=type.getConstructor(String.class,KeyClient.Commit.class,String.class,String.class).newInstance(saved,commit,args[1],args[2]);
                    clients.put(p[0],client);
                }
                String value=new String(Base64.getDecoder().decode(p[2]),StandardCharsets.UTF_8);
                switch(p[1]) {
                    case "create":type.getMethod("createIdentity").invoke(client);break;
                    case "pair":
                        value=QrCodec.decode(QrCodec.encode(value,640),640,640);
                        type.getMethod("previewContact",String.class).invoke(client,value);
                        type.getMethod("pair",String.class,boolean.class).invoke(client,value,true);break;
                    case "send":
                        JSONObject data=new JSONObject(value);
                        type.getMethod("send",String.class,String.class).invoke(client,data.getString("account"),data.getString("text"));break;
                    case "sync":type.getMethod("sync").invoke(client);break;
                    case "view":break;
                    default:throw new IOException("unsupported fixture operation");
                }
                out=(JSONObject)type.getMethod("publicView").invoke(client);
                if(out.optJSONObject("contact")!=null) {
                    String raw=out.getJSONObject("contact").toString();
                    if(!raw.equals(QrCodec.decode(QrCodec.encode(raw,640),640,640)))throw new AssertionError("contact QR roundtrip failed");
                }
            } catch(Exception e){
                Throwable cause=e instanceof InvocationTargetException?e.getCause():e;
                out=new JSONObject().put("error",cause instanceof SyncCycle.Rejected?"http_"+((SyncCycle.Rejected)cause).status:cause.getClass().getSimpleName());
            }
            System.out.println(Base64.getEncoder().encodeToString(out.toString().getBytes(StandardCharsets.UTF_8)));System.out.flush();
        }
    }
}
