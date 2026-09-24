package org.paranoid.devnet;
import org.json.*;
/** Real JNI signing plus synthetic RPC/store boundaries; no live/funded keys. */
public final class RegistrationFlowTest {
    static final String ENTROPY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    static final String GENESIS="EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
    static final class Store implements RegistrationFlow.Store {
        JSONObject value; boolean failSave; int saves;
        Store(JSONObject v){value=v;}
        public JSONObject load()throws Exception{return new JSONObject(value.toString());}
        public void save(JSONObject v)throws Exception{if(failSave)throw new java.io.IOException("storage_frozen");value=new JSONObject(v.toString());saves++;}
    }
    static class Chain implements RegistrationFlow.Chain {
        Store store;long height=10;int sends,builds;String wire,signature;boolean loseReply;
        Chain(Store s){store=s;}
        public String cluster(){return GENESIS;} public void program(){}
        public Object call(String method,JSONArray args)throws Exception {
            if(method.equals("getMultipleAccounts"))return new JSONObject().put("value",new JSONArray().put(JSONObject.NULL).put(JSONObject.NULL));
            if(method.equals("getSignatureStatuses")){JSONArray v=new JSONArray();for(int i=0;i<args.getJSONArray(0).length();i++)v.put(JSONObject.NULL);return new JSONObject().put("value",v);}
            if(method.equals("getAccountInfo"))return new JSONObject().put("value",JSONObject.NULL);
            if(method.equals("getBlockHeight"))return height;
            if(method.equals("getLatestBlockhash")){builds++;return new JSONObject().put("value",new JSONObject().put("blockhash","11111111111111111111111111111111").put("lastValidBlockHeight",height+100));}
            if(method.equals("getMinimumBalanceForRentExemption"))return 1300480L;
            if(method.equals("getFeeForMessage"))return new JSONObject().put("value",5000L);
            if(method.equals("getBalance"))return new JSONObject().put("value",10000000L);
            if(method.equals("sendTransaction")){
                JSONObject retained=store.value.getJSONArray("attempts").getJSONObject(store.value.getJSONArray("attempts").length()-1);
                if(!args.getString(0).equals(retained.getString("transaction")))throw new AssertionError("not durable before send");
                wire=args.getString(0);signature=retained.getString("signature");sends++;
                if(loseReply)throw new java.io.IOException("rpc_unavailable");return signature;
            }
            throw new AssertionError(method);
        }
    }
    static JSONObject state()throws Exception {return new JSONObject().put("entropy",ENTROPY).put("backup",true).put("attempts",new JSONArray());}
    static JSONObject attempt()throws Exception {
        JSONObject tx=SolanaBridge.run(new JSONObject().put("op","register").put("entropy",ENTROPY).put("name","test_alice").put("blockhash","11111111111111111111111111111111").put("genesis",GENESIS));
        return new JSONObject().put("transaction",tx.getString("transaction")).put("signature",tx.getString("signature")).put("last_valid_height",100).put("broadcasts",1);
    }
    public static void main(String[] args)throws Exception {
        JSONObject a=attempt();Store s=new Store(state().put("name","test_alice").put("attempts",new JSONArray().put(a)));Chain rpc=new Chain(s);
        RegistrationFlow.register(s,rpc,"test_alice");
        if(rpc.sends!=1||rpc.builds!=0||!a.getString("transaction").equals(rpc.wire))throw new AssertionError("pending retry must rebroadcast same bytes, not rebuild");
        if(s.value.getJSONArray("attempts").getJSONObject(0).getInt("broadcasts")!=2)throw new AssertionError("broadcast bound must persist before send");
        Store expired=new Store(state().put("name","test_alice").put("attempts",new JSONArray().put(attempt()).put(attempt()).put(attempt())));
        Chain afterExpiry=new Chain(expired);afterExpiry.height=200;
        RegistrationFlow.register(expired,afterExpiry,"test_alice");
        if(afterExpiry.sends!=1||afterExpiry.builds!=1||expired.value.getJSONArray("attempts").length()!=1)throw new AssertionError("expired ledger must reconcile and allow user retry, not lifetime dead end");
        String status=RegistrationFlow.check(expired,afterExpiry);
        if(status.contains("подтверждён в Devnet")||!status.contains("ещё"))throw new AssertionError("submission is not confirmed registration");
        afterExpiry.height=400;
        RegistrationFlow.register(expired,afterExpiry,"test_bob");
        if(!expired.value.getString("name").equals("test_bob"))throw new AssertionError("explicit name change after expiry and absent identity must be possible");
        // Additional regressions exercise existing fail-closed paths, not live RPC.
        Store failed=new Store(state());failed.failSave=true;Chain failedRpc=new Chain(failed);
        try{RegistrationFlow.register(failed,failedRpc,"test_alice");throw new AssertionError("failed save accepted");}catch(java.io.IOException expected){}
        if(failedRpc.sends!=0)throw new AssertionError("send after storage failure");
        Store pending=new Store(state().put("name","test_alice").put("attempts",new JSONArray().put(attempt())));Chain pendingRpc=new Chain(pending);
        try{RegistrationFlow.register(pending,pendingRpc,"test_bob");throw new AssertionError("pending name changed");}catch(java.io.IOException expected){if(!expected.getMessage().equals("different_name_pending"))throw expected;}
        pending.value.getJSONArray("attempts").getJSONObject(0).put("broadcasts",3);
        RegistrationFlow.register(pending,pendingRpc,"test_alice");if(pendingRpc.sends!=0||pendingRpc.builds!=0)throw new AssertionError("broadcast limit ignored");
        for(final boolean highRent:new boolean[]{true,false}){
            Store denied=new Store(state());Chain deniedRpc=new Chain(denied){public Object call(String method,JSONArray args)throws Exception{
                if(highRent&&method.equals("getMinimumBalanceForRentExemption"))return 6000000L;
                if(!highRent&&method.equals("getBalance"))return new JSONObject().put("value",0L);
                return super.call(method,args);
            }};
            try{RegistrationFlow.register(denied,deniedRpc,"test_alice");throw new AssertionError("cost/funds gate ignored");}catch(java.io.IOException expected){if(!expected.getMessage().equals(highRent?"cost_limit":"insufficient_devnet_sol"))throw expected;}
            if(deniedRpc.sends!=0||denied.saves!=0)throw new AssertionError("denied transaction persisted/sent");
        }
        Store unknown=new Store(state());Chain lost=new Chain(unknown);lost.loseReply=true;
        try{RegistrationFlow.register(unknown,lost,"test_alice");throw new AssertionError("expected lost reply");}catch(java.io.IOException expected){}
        String retained=unknown.value.getJSONArray("attempts").getJSONObject(0).getString("transaction");
        Chain retry=new Chain(unknown);RegistrationFlow.register(unknown,retry,"test_alice");
        if(retry.builds!=0||retry.sends!=1||!retained.equals(retry.wire))throw new AssertionError("lost response did not preserve exact wire");
        System.out.println("REGISTRATION FLOW PASS: same-wire retry, expiry, name switch, storage failure, pending-name guard, broadcast bound, costs/funds and lost response");
    }
}
