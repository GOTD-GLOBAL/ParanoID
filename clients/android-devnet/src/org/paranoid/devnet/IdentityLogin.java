package org.paranoid.devnet;

import java.io.IOException;
import org.json.JSONObject;

/** RFC-0027 identity-v3 login orchestration. Pure logic over three small boundaries so
 * the same code runs on the phone and in the JVM/JNI host test against a real server.
 * The owner key never leaves the Devnet library; the device key never leaves the core.
 */
public final class IdentityLogin {
    public interface Http extends org.paranoid.text.IdentityPorts.Http {}
    public interface Device extends org.paranoid.text.IdentityPorts.Device {}
    public static final String ACTIVE="active",REPLACE_REQUIRED="replace_required",REVOKED="revoked",BANNED="banned";
    public static final String GENESIS="EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",PROGRAM="C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas";
    private IdentityLogin(){}

    static long now(){return System.currentTimeMillis()/1000L;}

    private static JSONObject intent(String purpose,String owner,String identity,String name,JSONObject withFingerprint,String generation){
        try {
            JSONObject credential=new JSONObject(withFingerprint.toString());credential.remove("fingerprint");
            return new JSONObject().put("purpose",purpose).put("operation",java.util.UUID.randomUUID().toString())
                .put("genesis",GENESIS).put("program",PROGRAM).put("identity",identity).put("owner",owner).put("name",name)
                .put("credential_object",credential).put("expected_generation",generation);
        }catch(Exception e){throw new IllegalStateException(e);}
    }

    /** Server auth ingress is 8 requests/second shared by every client; pace this flow and
     * retry only a bounded number of 429s with backoff. Never retry other failures here. */
    private static JSONObject paced(org.paranoid.text.IdentityPorts.Http http,String path,String body)throws Exception {
        for(int attempt=0;;attempt++) {
            Thread.sleep(attempt==0?200:1000L*attempt);
            try{return http.post(path,body);}
            catch(Exception e){
                if(attempt<4&&status(e)==429)continue;
                throw e;
            }
        }
    }
    private static int status(Exception e){
        try{return e.getClass().getField("status").getInt(e);}catch(Exception ignored){return 0;}
    }

    /** One signed round: challenge, both proofs, then the purpose route. A 429 on the
     * challenge is retried; a proof is posted once (a consumed challenge is not reusable). */
    private static JSONObject round(org.paranoid.text.IdentityPorts.Http http,org.paranoid.text.IdentityPorts.Device device,String entropy,JSONObject intent,String realm,String pin)throws Exception {
        // The same intent (same operation id) may be retried: the server treats an exact
        // repeat as idempotent and a rate-limited attempt left nothing committed.
        for(int attempt=0;;attempt++) {
            try{return once(http,device,entropy,intent,realm,pin);}
            catch(Exception e){if(attempt<3&&status(e)==429){Thread.sleep(1500L*(attempt+1));continue;}throw e;}
        }
    }
    private static JSONObject once(org.paranoid.text.IdentityPorts.Http http,org.paranoid.text.IdentityPorts.Device device,String entropy,JSONObject intent,String realm,String pin)throws Exception {
        JSONObject challenge=paced(http,"/v3/identity/challenge",intent.toString());
        long now=now();
        String purpose=intent.getString("purpose");
        JSONObject proof=new JSONObject().put("id",challenge.getString("id"))
            .put("device_signature",device.deviceProof(intent,challenge,now));
        // SolanaBridge's JNI input limit (16 KiB) matches the native command limit.
        if(!purpose.equals("status")) {
            JSONObject owner=SolanaBridge.run(new JSONObject().put("op","identity_owner_proof_v3").put("entropy",entropy)
                .put("intent",intent).put("challenge",challenge).put("realm",realm).put("pin",pin).put("now",now));
            proof.put("owner_signature",owner.getString("owner_signature"));
        }
        String path=purpose.equals("inspect")?"/v3/identity/inspect":purpose.equals("status")?"/v3/identity/status":"/v3/identity/commit";
        Thread.sleep(200);
        return http.post(path,proof.toString());
    }

    /** Log this phone in with the verified Devnet nickname. `replace` must be an explicit
     * user choice: it retires the other phone. Returns one of the public constants. */
    public static String run(org.paranoid.text.IdentityPorts.Device device,org.paranoid.text.IdentityPorts.Http http,String entropy,String name,boolean replace)throws Exception {
        if(name==null||!name.matches("[a-z][a-z0-9_]{2,23}"))throw new IOException("nick_not_verified");
        JSONObject credential=device.credential();
        String realm=credential.getString("realm"),pin=credential.getString("pin");
        JSONObject id=SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",entropy));
        String owner=id.getString("owner");
        JSONObject lookup=SolanaBridge.run(new JSONObject().put("op","lookup").put("owner",owner).put("name",name));
        String identity=lookup.getString("identity");
        // This exact device may already be current (lost reply, reinstall of state) or retired.
        JSONObject status=round(http,device,entropy,intent("status",owner,identity,name,credential,"0"),realm,pin);
        String mode=status.getString("mode");
        if(mode.equals("revoked"))return REVOKED;
        if(mode.equals("banned"))return BANNED;
        if(mode.equals("active")){device.active(activeStatus(credential));return ACTIVE;}
        JSONObject inspect=round(http,device,entropy,intent("inspect",owner,identity,name,credential,"0"),realm,pin);
        String membership=inspect.getString("mode");
        if(membership.equals("banned"))return BANNED;
        JSONObject result;
        if(membership.equals("absent"))
            result=round(http,device,entropy,intent("enroll",owner,identity,name,credential,"0"),realm,pin);
        else if(!replace)return REPLACE_REQUIRED;
        else result=round(http,device,entropy,intent("replace",owner,identity,name,credential,inspect.getString("generation")),realm,pin);
        if(!"active".equals(result.getString("mode"))||!credential.getString("account").equals(result.getString("account"))
            ||!credential.getString("device").equals(result.getString("device")))throw new IOException("login_result_mismatch");
        device.active(activeStatus(credential));
        return ACTIVE;
    }

    /** Status in the exact shape the core already accepts for an active v2 enrollment. */
    static JSONObject activeStatus(JSONObject credential)throws Exception {
        return new JSONObject().put("mode","active").put("account",credential.getString("account"))
            .put("device",credential.getString("device")).put("credential",fingerprint(credential));
    }
    /** SHA256 hex of the canonical credential bytes, computed by the core (never re-implemented here). */
    static String fingerprint(JSONObject credential)throws Exception {
        return credential.getString("fingerprint");
    }
}
