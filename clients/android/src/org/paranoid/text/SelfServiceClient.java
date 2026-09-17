package org.paranoid.text;

import org.json.JSONObject;
import org.json.JSONArray;
import java.io.IOException;

/** Clean first-contact application adapter over the unchanged v2 opaque transport. */
public final class SelfServiceClient {
    public static final class UnsupportedSnapshot extends IOException {
        public UnsupportedSnapshot(){super("unsupported snapshot; clean installation required; retained data unchanged");}
    }
    private final KeyClient.Commit commit;
    private String state="", realm=KeyClient.DEFAULT_REALM, pin=KeyClient.DEFAULT_PIN, legacyToken="";
    private boolean broken=false;
    public interface CallListener {void received(JSONObject event) throws Exception;}
    public interface AcceptedListener {void accepted(String id);}
    private CallListener callListener;
    private AcceptedListener acceptedListener;
    /** Invoked on the state owner only after the entire candidate committed. */
    public void setCallListener(CallListener listener){callListener=listener;}
    public void setAcceptedListener(AcceptedListener listener){acceptedListener=listener;}
    private long lastProof=0;
    public SelfServiceClient(String saved,KeyClient.Commit commit) throws Exception {
        this.commit=commit;
        if(saved!=null) {
            JSONObject snapshot=new JSONObject(saved);int version=snapshot.optInt("version",0);
            if(version!=4)throw new UnsupportedSnapshot();
            realm=KeyClient.checkedRealm(snapshot.getString("realm"));pin=PinnedTls.checkedPin(snapshot.getString("tls_pin"));
            legacyToken=snapshot.getString("token");
            if(!legacyToken.isEmpty()&&!legacyToken.matches("[0-9a-f]{64}"))throw new IOException("invalid legacy snapshot");
            JSONObject retained=snapshot.getJSONObject("state");
            if(retained.getInt("version")!=0 && retained.getInt("version")!=3)throw new UnsupportedSnapshot();
            state=retained.toString();
            if(retained.getInt("version")==0) {
                // A crash may leave the freshly created identity before schema completion.
                // Let the native clean upgrader validate pristine state without committing.
                try {
                    JSONObject candidate=nativeCall(new JSONObject().put("op","upgrade_v2"));
                    if(candidate.getJSONObject("state").getInt("version")!=3)throw new UnsupportedSnapshot();
                } catch(Exception error) {throw new UnsupportedSnapshot();}
            }
            if(!view().getJSONObject("public").getString("realm").equals(realm))throw new IOException("realm mismatch");
        }
    }
    /** Explicit loopback-fixture trust; saved trust always wins. */
    public SelfServiceClient(String saved,KeyClient.Commit commit,String fixtureRealm,String fixturePin) throws Exception {
        this(saved,commit);
        if(saved==null){realm=KeyClient.checkedRealm(fixtureRealm);pin=PinnedTls.checkedPin(fixturePin);}
        else if(!realm.equals(fixtureRealm)||!pin.equals(fixturePin))throw new IOException("saved trust wins");
    }
    public boolean broken(){return broken;}
    /** Public transport trust only; never returns a credential or mutates the snapshot. */
    public String[] updateTrust() throws IOException {healthy();return new String[]{realm,pin};}
    private void healthy() throws IOException {if(broken)throw new IOException("local state frozen");}
    private JSONObject nativeCall(JSONObject request) throws Exception {
        healthy();String raw=CoreBridge.command(state,request.toString());
        if(raw==null)throw new IOException("native failure");
        JSONObject result=new JSONObject(raw);
        if(result.has("error"))throw new IOException("core rejected operation: "+result.getString("error"));
        return result;
    }
    private JSONObject view() throws Exception {return nativeCall(new JSONObject().put("op","view"));}
    private void apply(JSONObject request) throws Exception {
        JSONObject candidate=nativeCall(request);
        if(request.getString("op").equals("receive_v2")) {
            String disposition=candidate.optString("acceptance","");
            if(!disposition.equals("accepted") && !disposition.equals("exact_duplicate") && !disposition.equals("rejected"))
                throw new IOException("missing authenticated receive disposition");
        }
        JSONObject nextState=candidate.getJSONObject("state");
        if(nextState.getInt("version")!=0 && nextState.getInt("version")!=3)throw new UnsupportedSnapshot();
        String next=nextState.toString();
        if(next.equals(state))return;
        JSONObject saved=new JSONObject().put("version",4).put("realm",realm).put("tls_pin",pin).put("token",legacyToken).put("state",new JSONObject(next));
        try{commit.save(saved.toString());}catch(Exception error){broken=true;throw new IOException("local commit failed");}
        state=next;
        if(request.getString("op").equals("receive_v2")&&candidate.optString("acceptance").equals("accepted")&&candidate.has("call_event")&&callListener!=null)
            callListener.received(candidate.getJSONObject("call_event"));
    }
    public void createIdentity() throws Exception {
        healthy();
        if(state.isEmpty() || view().isNull("request"))apply(new JSONObject().put("op","create_identity").put("realm",realm).put("pin",pin));
        apply(new JSONObject().put("op","upgrade_v2"));
    }
    private boolean active() throws Exception {
        if(state.isEmpty()||new JSONObject(state).getInt("version")!=3)return false;
        JSONObject status=view().optJSONObject("enrollment");return status!=null&&status.optString("mode").equals("active");
    }
    public JSONObject previewContact(String raw) throws Exception {
        return nativeCall(new JSONObject().put("op","contact_text_v2").put("text",raw));
    }
    public void pair(String raw,boolean verified) throws Exception {
        apply(new JSONObject().put("op","pair_contact_v2").put("text",raw).put("verified",verified));
    }
    public void block(String account,boolean blocked) throws Exception {
        apply(new JSONObject().put("op","block_contact_v2").put("account",account).put("blocked",blocked));
    }
    public void send(String account,String text) throws Exception {
        if(!active())throw new IOException("registration required");
        // The core keeps no clock: a message carries the time of the phone that wrote or
        // received it, passed with the operation and never transmitted.
        apply(new JSONObject().put("op","send_v2").put("account",account).put("text",text).put("now_ms",System.currentTimeMillis()));
    }
    /** Returns immutable envelope ID; this is durable enqueue, not server acceptance. */
    public String sendCall(String account,JSONObject body) throws Exception {
        if(!active())throw new IOException("registration required");
        java.util.Set<String> before=new java.util.HashSet<>();
        JSONArray previous=pending();for(int n=0;n<previous.length();n++)before.add(previous.getJSONObject(n).getString("id"));
        apply(new JSONObject().put("op","send_call_v1").put("account",account).put("body",body));
        JSONArray next=pending();String id=null;
        for(int n=0;n<next.length();n++){JSONObject envelope=next.getJSONObject(n);if(!before.contains(envelope.getString("id"))){if(id!=null)throw new IOException("call enqueue invariant");id=envelope.getString("id");}}
        if(id==null)throw new IOException("call enqueue missing");return id;
    }
    private JSONObject signed(String purpose,String method,String path,String body) throws Exception {
        healthy();JSONObject current=view();
        long wait=600000000L-(System.nanoTime()-lastProof);if(wait>0)Thread.sleep((wait+999999)/1000000);
        lastProof=System.nanoTime();
        byte[] bytes=java.security.MessageDigest.getInstance("SHA-256").digest(body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        StringBuilder hex=new StringBuilder();for(byte b:bytes)hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        JSONObject intent=new JSONObject().put("purpose",purpose).put("method",method).put("path",path).put("body",hex.toString());
        if(purpose.equals("register"))intent.put("credential",current.getJSONObject("request").getJSONObject("credential"));
        else {
            JSONObject status=current.getJSONObject("enrollment");
            intent.put("account",status.getString("account")).put("device",status.getString("device")).put("credential",status.getString("credential"));
        }
        JSONObject challenge=KeyTransport.call(realm,pin,"POST",purpose.equals("register")?"/v2/registration/challenge":"/v2/auth/challenge",intent.toString(),null);
        JSONObject proof=nativeCall(new JSONObject().put("op","sign_request_v2").put("challenge",challenge).put("method",method).put("path",path).put("body",body));
        return KeyTransport.call(realm,pin,method,path,body,proof.getString("authorization"));
    }
    public void sync() throws Exception {
        healthy();if(state.isEmpty())return;
        createIdentity(); // clean identity/channel schema is durable before the first network request
        JSONObject status=active()?signed("status","POST","/v2/auth/verify","{}")
            :signed("register","POST","/v2/registration/commit","{}");
        apply(new JSONObject().put("op","server_status_v2").put("status",status));
        apply(new JSONObject().put("op","prepare_contact_v2"));
        // Receive does not depend on a successful outbound batch. No v1 fallback.
        SyncCycle.run(this::flush,this::receivePage,()->broken);
    }
    private void flush() throws Exception {
        JSONArray outbox=view().getJSONArray("outbox");java.util.List<JSONObject> batch=new java.util.ArrayList<>();
        for(int n=0;n<outbox.length();n++)batch.add(outbox.getJSONObject(n));
        SyncCycle.drain(batch,envelope->{
            JSONObject accepted=signed("message","POST","/v2/messages",envelope.toString());
            if(!accepted.getString("id").equals(envelope.getString("id"))||accepted.getLong("sequence")<1)throw new IOException("invalid acceptance");
            apply(new JSONObject().put("op","accepted_v2").put("id",envelope.getString("id")));
        },()->broken);
    }
    private void receivePage() throws Exception {
        long cursor=view().getLong("cursor");
        JSONArray messages=signed("message","GET","/v2/messages?after="+cursor+"&limit=20","").getJSONArray("messages");
        if(messages.length()>20)throw new IOException("page limit");
        for(int n=0;n<messages.length();n++)apply(new JSONObject().put("op","receive_v2").put("message",messages.getJSONObject(n)).put("now_ms",System.currentTimeMillis()));
    }
    public JSONObject publicView() throws Exception {
        healthy();JSONObject safe=new JSONObject().put("identity",false).put("active",false).put("configured",!state.isEmpty()).put("dialogs",new JSONArray());
        if(!state.isEmpty()) {
            JSONObject v=view();JSONObject request=v.optJSONObject("request");
            safe.put("identity",request!=null).put("active",active()).put("request",request)
                .put("account",request==null?"":request.getJSONObject("credential").getString("account"))
                .put("contact",v.optJSONObject("contact")).put("contact_fingerprint",v.optString("contact_fingerprint",""))
                .put("dialogs",v.optJSONArray("dialogs")==null?new JSONArray():v.getJSONArray("dialogs"))
                .put("rejected_count",v.optLong("rejected_count",0));
        }
        return safe;
    }

    // Short state-owner actions for RealtimeLoop. These methods never wait on
    // network, sleep, or expose private state. Historical sync() remains a
    // compatibility/test path, never used by the asynchronous Android engine.
    public boolean registered() throws Exception {healthy();return active();}
    public boolean hasIdentity() throws Exception {healthy();return !state.isEmpty();}
    public JSONObject challengeIntent(String purpose,String method,String path,String body)throws Exception {
        healthy();JSONObject current=view();
        byte[] hash=java.security.MessageDigest.getInstance("SHA-256").digest(body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        StringBuilder hex=new StringBuilder();for(byte b:hash)hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        JSONObject intent=new JSONObject().put("purpose",purpose).put("method",method).put("path",path).put("body",hex.toString());
        if(purpose.equals("register"))intent.put("credential",current.getJSONObject("request").getJSONObject("credential"));
        else {
            JSONObject enrollment=current.getJSONObject("enrollment");
            intent.put("account",enrollment.getString("account")).put("device",enrollment.getString("device")).put("credential",enrollment.getString("credential"));
        }
        return intent;
    }
    public String requestProof(JSONObject challenge,String method,String path,String body)throws Exception {
        return nativeCall(new JSONObject().put("op","sign_request_v2").put("challenge",challenge).put("method",method).put("path",path).put("body",body)).getString("authorization");
    }
    public void registrationResult(JSONObject status)throws Exception {
        apply(new JSONObject().put("op","server_status_v2").put("status",status));
        apply(new JSONObject().put("op","prepare_contact_v2"));
    }
    public JSONObject sessionRequest(JSONObject session,String operation,String id)throws Exception {
        JSONObject request=new JSONObject().put("op","sign_session_v2").put("session",session).put("operation",operation);
        if(id!=null)request.put("id",id);
        return nativeCall(request);
    }
    public JSONArray pending()throws Exception {healthy();return view().getJSONArray("outbox");}
    public long receiveCursor()throws Exception {healthy();return view().getLong("cursor");}
    public void accepted(JSONObject envelope,JSONObject response)throws Exception {
        healthy();
        if(!response.getString("id").equals(envelope.getString("id"))||response.getLong("sequence")<1)throw new IOException("invalid acceptance");
        apply(new JSONObject().put("op","accepted_v2").put("id",envelope.getString("id")));
        if(acceptedListener!=null)acceptedListener.accepted(envelope.getString("id"));
    }
    public void received(JSONObject message)throws Exception {
        apply(new JSONObject().put("op","receive_v2").put("message",message).put("now_ms",System.currentTimeMillis()));
    }
}
