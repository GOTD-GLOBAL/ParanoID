package org.paranoid.text;

import org.json.JSONObject;
import java.io.IOException;
import java.net.URL;

/** Single-owner phone workflow, shared by Android and real JVM/JNI fixtures. */
public final class KeyClient {
    public static final String DEFAULT_REALM="https://157.180.49.125:38443";
    public static final String DEFAULT_PIN="8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba";
    public interface Commit { void save(String snapshot) throws Exception; }
    private final Commit commit;
    private String state="", realm=DEFAULT_REALM, pin=DEFAULT_PIN, legacyToken="";
    private boolean broken=false;
    private long lastProof=0;
    /** Explicit public fixture trust input; never overrides any saved origin/pin. */
    public KeyClient(String saved,Commit commit,String fixtureRealm,String fixturePin) throws Exception {
        this(saved,commit);
        if(saved==null){realm=checkedRealm(fixtureRealm);pin=PinnedTls.checkedPin(fixturePin);}
        else if(!realm.equals(fixtureRealm)||!pin.equals(fixturePin))throw new IOException("saved trust wins");
    }
    public KeyClient(String saved,Commit commit) throws Exception {
        this.commit=commit;
        if(saved!=null) {
            JSONObject snapshot=new JSONObject(saved);
            int version=snapshot.optInt("version",0);
            if(version!=0 && version!=2)throw new IOException("unsupported snapshot");
            realm=checkedRealm(snapshot.getString("realm"));pin=PinnedTls.checkedPin(snapshot.getString("tls_pin"));
            legacyToken=snapshot.getString("token");
            if(!legacyToken.isEmpty() && !legacyToken.matches("[0-9a-f]{64}"))throw new IOException("invalid legacy snapshot");
            state=snapshot.getJSONObject("state").toString();
            if(!view().getJSONObject("public").getString("realm").equals(realm))throw new IOException("realm mismatch");
        }
    }
    public boolean broken(){return broken;}
    private void healthy() throws IOException {if(broken)throw new IOException("local state frozen");}
    static String checkedRealm(String raw) throws Exception {
        URL u=new URL(raw);
        if(!u.getProtocol().equals("https") || u.getHost().isEmpty() || u.getUserInfo()!=null || u.getQuery()!=null || u.getRef()!=null || !u.getPath().isEmpty() || raw.length()>512)throw new IOException("HTTPS origin required");
        return raw;
    }
    private JSONObject nativeCall(JSONObject request) throws Exception {
        healthy();String raw=CoreBridge.command(state,request.toString());
        if(raw==null)throw new IOException("native failure");
        JSONObject result=new JSONObject(raw);
        if(result.has("error"))throw new IOException("core rejected operation");return result;
    }
    private JSONObject view() throws Exception {return nativeCall(new JSONObject().put("op","view"));}
    private void apply(JSONObject request) throws Exception {
        JSONObject candidate=nativeCall(request);
        String next=candidate.getJSONObject("state").toString();
        if(next.equals(state))return;
        JSONObject snapshot=new JSONObject().put("version",2).put("realm",realm).put("tls_pin",pin).put("token",legacyToken).put("state",new JSONObject(next));
        try {commit.save(snapshot.toString());}catch(Exception error){broken=true;throw new IOException("local commit failed");}
        state=next;
    }
    public void createIdentity() throws Exception {
        healthy();
        if(!state.isEmpty() && !view().isNull("request"))return;
        apply(new JSONObject().put("op","create_identity").put("realm",realm).put("pin",pin));
    }
    public void importGrant(String raw) throws Exception {
        if(raw.length()>4096)throw new IOException("QR limit");
        apply(new JSONObject().put("op","import_grant_text").put("text",raw));
    }
    public JSONObject previewContact(String raw) throws Exception {
        if(raw.length()>4096)throw new IOException("QR limit");
        return nativeCall(new JSONObject().put("op","contact_text").put("text",raw));
    }
    public void pair(String raw,boolean verified) throws Exception {
        if(raw.length()>4096)throw new IOException("QR limit");
        apply(new JSONObject().put("op","contact_text").put("text",raw).put("verified",verified));
    }
    public void send(String text) throws Exception {
        if(!active())throw new IOException("key activation required");
        apply(new JSONObject().put("op","send").put("text",text));
    }
    private boolean active() throws Exception {
        if(state.isEmpty())return false;
        JSONObject status=view().optJSONObject("enrollment");return status!=null && status.optString("mode").equals("active");
    }
    private JSONObject signed(String purpose,String method,String path,String body) throws Exception {
        healthy();JSONObject grant=view().getJSONObject("grant");
        long wait=550000000L-(System.nanoTime()-lastProof);if(wait>0)Thread.sleep((wait+999999)/1000000);
        lastProof=System.nanoTime();
        byte[] digest=java.security.MessageDigest.getInstance("SHA-256").digest(body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        JSONObject intent=new JSONObject().put("grant",grant.getString("id")).put("credential",grant.getString("credential"))
            .put("purpose",purpose).put("method",method).put("path",path).put("body",hex.toString());
        JSONObject challenge=KeyTransport.call(realm,pin,"POST",purpose.equals("enroll")?"/v1/enrollment/challenge":"/v1/auth/challenge",intent.toString(),null);
        JSONObject proof=nativeCall(new JSONObject().put("op","sign_request").put("challenge",challenge).put("method",method).put("path",path).put("body",body));
        return KeyTransport.call(realm,pin,method,path,body,proof.getString("authorization"));
    }
    public void sync() throws Exception {
        healthy();if(state.isEmpty() || view().isNull("grant"))return;
        JSONObject status;
        try {status=signed("status","POST","/v1/auth/verify","{}");}
        catch(SyncCycle.Rejected failure) {
            if(failure.status!=401 || !view().isNull("enrollment"))throw failure;
            signed("enroll","POST","/v1/enrollment/commit","{}");
            status=signed("status","POST","/v1/auth/verify","{}");
        }
        apply(new JSONObject().put("op","server_status").put("status",status));
        if(!active()) {
            // Candidate mapping and every old ratchet/outbox byte are durable BEFORE activation.
            status=signed("activate","POST","/v1/enrollment/activate","{}");
            apply(new JSONObject().put("op","server_status").put("status",status));
        }
        if(new JSONObject(state).isNull("peer"))return;
        SyncCycle.run(this::flush,this::receivePage,()->broken);
    }
    private void flush() throws Exception {
        org.json.JSONArray outbox=view().getJSONArray("outbox");java.util.List<JSONObject> snapshot=new java.util.ArrayList<>();
        for(int n=0;n<outbox.length();n++)snapshot.add(outbox.getJSONObject(n));
        SyncCycle.drain(snapshot,envelope->{
            JSONObject accepted=signed("message","POST","/v1/messages",envelope.toString());
            if(!accepted.getString("id").equals(envelope.getString("id")) || accepted.getLong("sequence")<1)throw new IOException("invalid acceptance");
            apply(new JSONObject().put("op","accepted").put("id",envelope.getString("id")));
        },()->broken);
    }
    private void receivePage() throws Exception {
        long cursor=view().getLong("cursor");
        org.json.JSONArray messages=signed("message","GET","/v1/messages?after="+cursor+"&limit=20","").getJSONArray("messages");
        if(messages.length()>20)throw new IOException("page limit");
        for(int n=0;n<messages.length();n++)apply(new JSONObject().put("op","receive").put("message",messages.getJSONObject(n)));
    }
    public JSONObject publicView() throws Exception {
        healthy();JSONObject safe=new JSONObject().put("identity",false).put("active",false).put("paired",false).put("configured",!state.isEmpty()).put("realm",realm).put("tls_pin",pin);
        if(!state.isEmpty()) {
            JSONObject view=view();
            safe.put("identity",!view.isNull("request")).put("request",view.optJSONObject("request"))
                .put("public",view.getJSONObject("public")).put("messages",view.getJSONArray("messages"))
                .put("active",active()).put("paired",!new JSONObject(state).isNull("peer"))
                .put("contact",view.optJSONObject("contact")).put("contact_fingerprint",view.optString("contact_fingerprint",""))
                .put("awaiting_grant",view.isNull("grant")).put("rejected_count",view.optLong("rejected_count",0));
        }
        return safe;
    }
}
