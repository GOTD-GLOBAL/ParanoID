import org.paranoid.text.*;
import org.json.*;
import java.util.*;

/** Cross-language characterization of the Rust-tested populated migration. No network. */
public final class SelfServiceMigrationSmoke {
    static JSONObject core(JSONObject state,JSONObject request)throws Exception {
        JSONObject r=new JSONObject(CoreBridge.command(state==null?"":state.toString(),request.toString()));
        if(r.has("error"))throw new AssertionError("JNI fixture operation rejected");return r;
    }
    public static void main(String[] args)throws Exception {
        String realm="https://127.0.0.2:38443",pin=new String(new char[64]).replace('\0','a');
        JSONObject a=core(null,new JSONObject().put("op","init").put("device","alice").put("realm",realm));
        JSONObject b=core(null,new JSONObject().put("op","init").put("device","bob").put("realm",realm));
        a=core(a.getJSONObject("state"),new JSONObject().put("op","pair").put("peer",b.getJSONObject("public")).put("verified",true));
        b=core(b.getJSONObject("state"),new JSONObject().put("op","pair").put("peer",a.getJSONObject("public")).put("verified",true));
        b=core(b.getJSONObject("state"),new JSONObject().put("op","send").put("text","История до обновления"));
        JSONObject message=new JSONObject(b.getJSONArray("outbox").getJSONObject(0).toString());message.remove("recipient");message.put("sender","bob").put("sequence",1);
        a=core(a.getJSONObject("state"),new JSONObject().put("op","receive").put("message",message));
        String token=new String(new char[64]).replace('\0','b');
        for(JSONObject participant:new JSONObject[]{a,b}) {
            JSONObject original=participant.getJSONObject("state");
            String outer=new JSONObject().put("realm",realm).put("tls_pin",pin).put("token",token).put("state",original).toString();
            for(boolean rooted:new boolean[]{false,true}) {
                final String[] disk={outer};
                if(rooted){KeyClient old=new KeyClient(outer,value->disk[0]=value);old.createIdentity();}
                JSONObject before=new JSONObject(disk[0]).getJSONObject("state");
                SelfServiceClient client=new SelfServiceClient(disk[0],value->disk[0]=value);
                client.createIdentity();JSONObject snapshot=new JSONObject(disk[0]);JSONObject after=snapshot.getJSONObject("state").getJSONObject("legacy");
                Iterator<String> keys=before.keys();while(keys.hasNext()) {
                    String k=keys.next();if(!Objects.toString(before.get(k)).equals(Objects.toString(after.get(k))))throw new AssertionError("retained field changed: "+k);
                }
                if(!snapshot.getString("token").equals(token)||!snapshot.getString("tls_pin").equals(pin)||!snapshot.getString("realm").equals(realm))throw new AssertionError("retained trust/material changed");
                String account=client.publicView().getString("account");String saved=disk[0];client.createIdentity();
                if(!saved.equals(disk[0]))throw new AssertionError("migration retry changed state");
                client=new SelfServiceClient(disk[0],value->disk[0]=value);
                if(!client.publicView().getString("account").equals(account))throw new AssertionError("root changed across JNI reopen");
            }
        }
        System.out.println("PASS populated migration on actual JVM/JNI: v0 rootless and v1 rooted snapshots retain every original field, consumed OTK, ratchets, history, exact pending envelopes, trust and keys; reload stable. Not Android Keystore evidence.");
    }
}
