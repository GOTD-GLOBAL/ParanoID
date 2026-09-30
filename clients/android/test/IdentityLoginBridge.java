import org.paranoid.text.*;
import org.paranoid.devnet.IdentityLogin;
import org.json.*;
import javax.crypto.spec.SecretKeySpec;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;

/** RFC-0027 host fixture: real server + real JNI core + real Devnet library, synthetic phones.
 * stdin: phone \t op \t base64(value); stdout: base64(JSON public result). Never prints keys. */
public final class IdentityLoginBridge {
    static final Map<String,SelfServiceClient> clients=new HashMap<>();
    static String realm,pin;
    static SelfServiceClient client(Path root,String phone)throws Exception {
        SelfServiceClient c=clients.get(phone);if(c!=null)return c;
        Path snapshot=root.resolve(phone+".enc"),keyFile=root.resolve(phone+".key");
        StorageGuard.requireContinuity(Files.exists(snapshot),Files.exists(keyFile));
        byte[] key;
        if(Files.exists(keyFile))key=Files.readAllBytes(keyFile);
        else{key=new byte[32];new SecureRandom().nextBytes(key);Files.write(keyFile,key,StandardOpenOption.CREATE_NEW);}
        SecretKeySpec wrapping=new SecretKeySpec(key,"AES");
        String saved=Files.exists(snapshot)?SnapshotCodec.open(wrapping,Files.readAllBytes(snapshot)):null;
        KeyClient.Commit commit=value->{
            byte[] encrypted=SnapshotCodec.seal(wrapping,value);Path next=root.resolve(phone+".next");
            try(FileOutputStream f=new FileOutputStream(next.toFile())){f.write(encrypted);f.getFD().sync();}
            Files.move(next,snapshot,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        };
        c=new SelfServiceClient(saved,commit,realm,pin);clients.put(phone,c);return c;
    }
    /** Host stand-in for the finalized registry: the server's owner->name fixture file. */
    static IdentityPorts.Registry fixtureRegistry(Path file){
        return (owner,name,identity)->{
            JSONObject table=new JSONObject(new String(Files.readAllBytes(file),StandardCharsets.UTF_8));
            if(!name.equals(table.optString(owner,null)))throw new IOException("name_not_registered");
            Class<?> bridge=Class.forName("org.paranoid.devnet.SolanaBridge");
            java.lang.reflect.Method run=bridge.getDeclaredMethod("run",JSONObject.class);run.setAccessible(true);
            JSONObject lookup=(JSONObject)run.invoke(null,new JSONObject().put("op","lookup").put("owner",owner).put("name",name));
            if(!lookup.getString("identity").equals(identity))throw new IOException("identity_mismatch");
        };
    }
    public static void main(String[] args)throws Exception {
        if(args[0].equals("--owner")) {
            // Public Devnet owner address only; the entropy is a public synthetic test value.
            Class<?> bridge=Class.forName("org.paranoid.devnet.SolanaBridge");
            java.lang.reflect.Method run=bridge.getDeclaredMethod("run",JSONObject.class);run.setAccessible(true);
            System.out.println(((JSONObject)run.invoke(null,new JSONObject().put("op","identity").put("entropy",args[1]))).getString("owner"));
            return;
        }
        Path root=Paths.get(args[0]);Files.createDirectories(root);realm=args[1];pin=args[2];
        BufferedReader in=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));String line;
        while((line=in.readLine())!=null) {
            JSONObject out;
            try {
                String[] p=line.split("\t",-1);if(!p[0].matches("one|two|three"))throw new IOException("synthetic phone required");
                String value=new String(Base64.getDecoder().decode(p[2]),StandardCharsets.UTF_8);
                SelfServiceClient c=client(root,p[0]);
                switch(p[1]) {
                    case "create":c.createIdentity();out=c.publicView();break;
                    case "login":{
                        JSONObject v=new JSONObject(value);
                        String mode=IdentityLogin.run(c.identityDevice(),c.identityHttp(),v.getString("entropy"),v.getString("name"),v.optBoolean("replace"));
                        out=c.publicView().put("login",mode);break;
                    }
                    case "pair":c.previewContact(value);c.pair(value,true);out=c.publicView();break;
                    case "send":{JSONObject d=new JSONObject(value);c.send(d.getString("account"),d.getString("text"));out=c.publicView();break;}
                    case "sync":c.sync();out=c.publicView();break;
                    case "view":out=c.publicView();break;
                    // RFC-0028 directory over a real signed session. `registry` replaces live
                    // Solana with the same owner->name fixture file the server uses.
                    case "publish":out=c.directory("directory_card",null);break;
                    case "visibility":out=c.directory("directory_visibility",value);break;
                    case "directory":out=c.directory("directory_search",value);break;
                    case "add_found":{
                        JSONObject v=new JSONObject(value);JSONObject entry=v.getJSONObject("entry");
                        JSONObject verified=c.verifyDirectoryEntry(entry);
                        fixtureRegistry(Paths.get(v.getString("registry"))).verify(entry.getString("owner"),entry.getString("name"),entry.getString("identity"));
                        c.pairDirectoryEntry(entry);out=c.publicView().put("verified",verified);break;
                    }
                    default:throw new IOException("unsupported fixture operation");
                }
            } catch(Throwable e) {
                Throwable cause=e instanceof java.lang.reflect.InvocationTargetException?e.getCause():e;
                String code=cause instanceof SyncCycle.Rejected?"http_"+((SyncCycle.Rejected)cause).status+":"+((SyncCycle.Rejected)cause).code:cause.getClass().getSimpleName()+":"+cause.getMessage();
                out=new JSONObject().put("error",code);
            }
            System.out.println(Base64.getEncoder().encodeToString(out.toString().getBytes(StandardCharsets.UTF_8)));System.out.flush();
        }
    }
}
