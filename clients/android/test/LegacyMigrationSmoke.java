import org.paranoid.text.*;
import org.json.*;
import javax.crypto.spec.SecretKeySpec;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;

/** Populated genuine v0 Olm state: old history, pins, ratchets, cursor and retry bytes. */
public final class LegacyMigrationSmoke {
    static JSONObject core(JSONObject state,JSONObject request)throws Exception {
        JSONObject result=new JSONObject(CoreBridge.command(state==null?"":state.toString(),request.toString()));
        if(result.has("error"))throw new AssertionError("legacy fixture core rejected operation");return result;
    }
    public static void main(String[] args)throws Exception {
        Path root=Paths.get(args[0]);Files.createDirectories(root);String realm=args[1],pin=args[2];
        JSONObject a=core(null,new JSONObject().put("op","init").put("device","alice").put("realm",realm));
        JSONObject b=core(null,new JSONObject().put("op","init").put("device","bob").put("realm",realm));
        a=core(a.getJSONObject("state"),new JSONObject().put("op","pair").put("peer",b.getJSONObject("public")).put("verified",true));
        b=core(b.getJSONObject("state"),new JSONObject().put("op","pair").put("peer",a.getJSONObject("public")).put("verified",true));
        a=core(a.getJSONObject("state"),new JSONObject().put("op","send").put("text","До миграции"));
        JSONObject envelope=a.getJSONArray("outbox").getJSONObject(0);
        JSONObject incoming=new JSONObject(envelope.toString());incoming.remove("recipient");incoming.put("sender","alice").put("sequence",1);
        b=core(b.getJSONObject("state"),new JSONObject().put("op","receive").put("message",incoming));
        Files.write(root.resolve("legacy-envelope.json"),envelope.toString().getBytes(StandardCharsets.UTF_8),StandardOpenOption.CREATE_NEW);
        JSONObject[] clients={a,b};String[] names={"one","two"};
        for(int n=0;n<2;n++) {
            JSONObject old=clients[n].getJSONObject("state");String token=new String(new char[64]).replace('\0',n==0?'a':'b');
            String outer=new JSONObject().put("realm",realm).put("tls_pin",pin).put("token",token).put("state",old).toString();
            final String[] saved={null};KeyClient migrated=new KeyClient(outer,value->saved[0]=value);
            migrated.createIdentity();JSONObject next=new JSONObject(saved[0]).getJSONObject("state");
            Iterator<String> keys=old.keys();while(keys.hasNext()) {String k=keys.next();if(!Objects.toString(old.get(k)).equals(Objects.toString(next.get(k))))throw new AssertionError("legacy field changed: "+k);}
            if(!new JSONObject(saved[0]).getString("token").equals(token))throw new AssertionError("legacy sealed material was discarded");
            // Invalid explicit slot cannot modify even a migrated local candidate.
            JSONObject credential=migrated.publicView().getJSONObject("request").getJSONObject("credential");
            String response=CoreBridge.command("",new JSONObject().put("op","validate_request").put("descriptor",migrated.publicView().getJSONObject("request")).toString());
            String fp=new JSONObject(response).getString("fingerprint");
            JSONObject wrong=new JSONObject().put("type","paranoid-grant-v1").put("id",UUID.randomUUID().toString()).put("credential",fp).put("realm",realm).put("pin",pin).put("slot",1-n).put("expires",9999999999L);
            try{migrated.importGrant(wrong.toString());throw new AssertionError("wrong legacy mapping accepted");}catch(java.io.IOException expected){}
            byte[] key=new byte[32];new SecureRandom().nextBytes(key);Files.write(root.resolve(names[n]+".key"),key,StandardOpenOption.CREATE_NEW);
            Files.write(root.resolve(names[n]+".enc"),SnapshotCodec.seal(new SecretKeySpec(key,"AES"),outer),StandardOpenOption.CREATE_NEW);
        }
        System.out.println("PASS: populated v0 rootless Olm states migrate locally without changing any old field; wrong legacy slot denied. Encrypted v0 fixtures saved privately for real TLS cutover.");
    }
}
