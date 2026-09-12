import org.paranoid.text.*;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** REQ-CALL-003/004: real JNI/Olm call events cannot escape sealed commit. */
public final class VoiceCommitSmoke {
    static final class Peer {
        String saved; boolean fail; final SelfServiceClient client;
        Peer() throws Exception {
            client=new SelfServiceClient(null,next->{if(fail)throw new IOException("synthetic save fault");saved=next;});
            client.createIdentity();
            JSONObject c=client.publicView().getJSONObject("request").getJSONObject("credential");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(bytes);
            for(String field:new String[]{"paranoid-credential-v1",c.getString("root"),c.getString("account"),c.getString("device"),c.getString("auth"),c.getString("realm"),c.getString("pin"),c.getString("olm")}) {
                byte[] value=field.getBytes(StandardCharsets.UTF_8);out.writeInt(value.length);out.write(value);
            }
            StringBuilder hex=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()))hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
            // Synthetic enrollment; tests below exercise actual production native bindings.
            client.registrationResult(new JSONObject().put("mode","active").put("account",c.getString("account")).put("device",c.getString("device")).put("credential",hex.toString()));
        }
        String account() throws Exception{return client.publicView().getString("account");}
        String contact() throws Exception{return client.publicView().getJSONObject("contact").toString();}
    }
    static JSONObject knock() throws Exception {
        long now=System.currentTimeMillis();
        return new JSONObject().put("v",2).put("video",true).put("kind","knock").put("call_id",java.util.UUID.randomUUID().toString())
            .put("caller_nonce","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").put("callee_nonce","")
            .put("seq",0).put("sent_ms",now).put("expires_ms",now+45000)
            .put("sdp","").put("fingerprint","").put("ice_ufrag","").put("ice_pwd","").put("offer_digest","").put("reason","");
    }
    static JSONObject envelope(Peer from,Peer to,long sequence) throws Exception {
        from.client.sendCall(to.account(),knock());
        JSONObject result=new JSONObject(from.client.pending().getJSONObject(from.client.pending().length()-1).toString());
        result.remove("recipient");return result.put("sender",from.account()).put("sequence",sequence);
    }
    static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    public static void main(String[] args) throws Exception {
        Peer a=new Peer(),b=new Peer();a.client.pair(b.contact(),true);b.client.pair(a.contact(),true);
        int[] events={0};b.client.setCallListener(event->{
            check(new JSONObject(b.saved).getJSONObject("state").getLong("cursor")>0,"event preceded durable cursor/ratchet commit");
            check(event.getString("account").equals(a.account()),"event used unauthenticated sender");events[0]++;
        });
        JSONObject first=envelope(a,b,1);b.client.received(first);check(events[0]==1,"accepted call not emitted once");
        check(b.client.publicView().getJSONArray("dialogs").getJSONObject(0).getJSONArray("messages").length()==0,"call became text");
        check(b.client.pending().length()==0,"call queued receipt");
        try{b.client.received(first);}catch(IOException expected){}check(events[0]==1,"duplicate emitted call");
        SelfServiceClient reopened=new SelfServiceClient(b.saved,next->b.saved=next);reopened.setCallListener(event->{throw new AssertionError("reopened replay emitted call");});try{reopened.received(first);}catch(IOException expected){}
        Peer unknown=new Peer();a.client.pair(unknown.contact(),true);unknown.client.setCallListener(event->{throw new AssertionError("unknown sender gained call authority");});
        unknown.client.received(envelope(a,unknown,1));check(unknown.client.publicView().getJSONArray("dialogs").length()==0,"unknown call allocated contact");
        b.client.block(a.account(),true);b.client.received(envelope(a,b,2));check(events[0]==1,"blocked call emitted");b.client.block(a.account(),false);
        String before=b.saved;b.fail=true;
        try{b.client.received(envelope(a,b,3));throw new AssertionError("failed save accepted");}catch(IOException expected){}
        check(b.client.broken()&&events[0]==1&&before.equals(b.saved),"failed save leaked event or overwrote state");
        System.out.println("PASS actual JNI/Olm voice adapter: commit-before-event, duplicate/reopen, unknown/block, no text/receipt, failed-save freeze");
    }
}
