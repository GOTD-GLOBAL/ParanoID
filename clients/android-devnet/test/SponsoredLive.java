package org.paranoid.devnet;

import org.json.*;

/** LIVE Devnet: register a fresh random nick with the server sponsor paying, from the real
 * JNI library and the real RegistrationFlow, then verify finalized registry readback.
 * Args: realm pin. Prints only public values (owner address, name, signature). */
public final class SponsoredLive {
    public static void main(String[] a)throws Exception {
        String realm=a[0],pin=a[1];
        byte[] e=new byte[16];new java.security.SecureRandom().nextBytes(e);
        final JSONObject[] box={new JSONObject().put("entropy",java.util.Base64.getEncoder().encodeToString(e)).put("program",DevnetRpc.PROGRAM)
            .put("genesis",DevnetRpc.GENESIS).put("backup",true).put("attempts",new JSONArray())};
        RegistrationFlow.Store store=new RegistrationFlow.Store(){
            public JSONObject load()throws Exception{return new JSONObject(box[0].toString());}
            public void save(JSONObject s)throws Exception{box[0]=new JSONObject(s.toString());}
        };
        RegistrationFlow.Sponsor sponsor=new RegistrationFlow.Sponsor(){
            public JSONObject prepare()throws Exception{return org.paranoid.text.KeyTransport.call(realm,pin,"POST","/v3/sponsor/prepare",new JSONObject().put("genesis",DevnetRpc.GENESIS).toString(),null);}
            public String cosign(String owner,String name,String blockhash,String sig)throws Exception{
                return org.paranoid.text.KeyTransport.call(realm,pin,"POST","/v3/sponsor/register",new JSONObject().put("owner",owner).put("name",name).put("blockhash",blockhash).put("owner_signature",sig).toString(),null).getString("payer_signature");}
        };
        DevnetRpc rpc=new DevnetRpc();
        String owner=SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",box[0].getString("entropy"))).getString("owner");
        long before=((JSONObject)rpc.call("getBalance",new JSONArray().put(owner).put(new JSONObject().put("commitment","finalized")))).getLong("value");
        if(before!=0)throw new AssertionError("fresh owner must be unfunded");
        String name="sp"+Long.toString(System.nanoTime()%1_000_000_000L,36);
        System.out.println("owner="+owner+" name="+name+" owner_balance=0");
        try{System.out.println("register: "+RegistrationFlow.registerSponsored(store,rpc,sponsor,name).replace((char)10,(char)32));}catch(org.paranoid.text.SyncCycle.Rejected x){throw new AssertionError("rejected "+x.status+" "+x.code);}
        String sig=box[0].getJSONArray("attempts").getJSONObject(0).getString("signature");
        System.out.println("signature="+sig);
        for(int i=0;i<40&&!box[0].optBoolean("verified");i++){Thread.sleep(3000);RegistrationFlow.check(store,rpc);}
        if(!box[0].optBoolean("verified"))throw new AssertionError("not finalized/verified in 120 s");
        long after=((JSONObject)rpc.call("getBalance",new JSONArray().put(owner).put(new JSONObject().put("commitment","finalized")))).getLong("value");
        if(after!=0)throw new AssertionError("owner paid something");
        System.out.println("PASS live Devnet sponsored registration: @"+name+" verified (finalized paired records), owner spent 0 lamports");
        // Same owner, second different name through the sponsor is refused by the program; the
        // exact repeat is idempotent success.
        System.out.println("repeat: "+RegistrationFlow.registerSponsored(store,rpc,sponsor,name).replace('\n',' '));
    }
}
