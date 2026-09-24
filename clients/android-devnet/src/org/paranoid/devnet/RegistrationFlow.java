package org.paranoid.devnet;

import java.io.IOException;
import org.json.*;

/** Serialized registration owner. Store must commit/read back before any send. */
final class RegistrationFlow {
    interface Store { JSONObject load()throws Exception; void save(JSONObject state)throws Exception; }
    interface Chain { Object call(String method,JSONArray params)throws Exception; String cluster()throws Exception; void program()throws Exception; }
    static JSONObject required(Store store)throws Exception {JSONObject s=store.load();if(s==null)throw new IOException("identity_required");return s;}
    static JSONObject identity(JSONObject s)throws Exception {return SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",s.getString("entropy")));}
    static JSONObject finalized()throws Exception {return new JSONObject().put("commitment","finalized");}
    static long integer(Object value)throws IOException {if(!(value instanceof Long)&&!(value instanceof Integer))throw new IOException("rpc_integer");long n=((Number)value).longValue();if(n<0)throw new IOException("rpc_integer");return n;}
    private static String data(JSONObject account)throws Exception {
        if(account.getBoolean("executable"))throw new IOException("executable_record");JSONArray a=account.getJSONArray("data");
        if(a.length()!=2||!"base64".equals(a.getString(1)))throw new IOException("record_encoding");return a.getString(0);
    }
    private static boolean readback(Chain rpc,JSONObject state,String owner,String name,String genesis)throws Exception {
        JSONObject lookup=SolanaBridge.run(new JSONObject().put("op","lookup").put("owner",owner).put("name",name));
        JSONArray values=((JSONObject)rpc.call("getMultipleAccounts",new JSONArray().put(new JSONArray().put(lookup.getString("identity")).put(lookup.getString("nickname"))).put(finalized().put("encoding","base64")))).getJSONArray("value");
        if(values.length()!=2)throw new IOException("record_count");
        if(values.isNull(0)&&values.isNull(1)){state.put("verified",false);return false;}
        if(values.isNull(0)||values.isNull(1))throw new IOException("name_conflict_or_partial_record");
        JSONObject id=values.getJSONObject(0),nick=values.getJSONObject(1);
        SolanaBridge.run(new JSONObject().put("op","verify").put("owner",owner).put("name",name).put("identity_data",data(id)).put("nickname_data",data(nick)).put("identity_program",id.getString("owner")).put("nickname_program",nick.getString("owner")).put("genesis",genesis));
        state.put("verified",true).put("name",name);return true;
    }
    private static boolean expired(Chain rpc,JSONArray attempts)throws Exception {
        if(attempts.length()==0)return true;
        JSONArray signatures=new JSONArray();long expiry=0;
        for(int i=0;i<attempts.length();i++){JSONObject a=attempts.getJSONObject(i);signatures.put(a.getString("signature"));expiry=Math.max(expiry,a.getLong("last_valid_height"));}
        JSONArray status=((JSONObject)rpc.call("getSignatureStatuses",new JSONArray().put(signatures).put(new JSONObject().put("searchTransactionHistory",true)))).getJSONArray("value");
        if(status.length()!=attempts.length())throw new IOException("signature_status_count");
        return integer(rpc.call("getBlockHeight",new JSONArray().put(finalized())))>expiry;
    }
    private static String broadcast(Store store,Chain rpc,JSONObject state,JSONObject attempt)throws Exception {
        int count=attempt.optInt("broadcasts",1);
        if(count>=3)return "Транзакция ещё может подтвердиться. Лимит повторной отправки достигнут — нажмите проверку позже.";
        attempt.put("broadcasts",count+1);store.save(state);
        Object signature=rpc.call("sendTransaction",new JSONArray().put(attempt.getString("transaction")).put(new JSONObject().put("encoding","base64").put("skipPreflight",false).put("preflightCommitment","finalized").put("maxRetries",0)));
        if(!attempt.getString("signature").equals(signature))throw new IOException("signature_reply_mismatch");
        return "Транзакция отправлена. Регистрация ещё не подтверждена — нажмите «Проверить ник».";
    }
    static String check(Store store,Chain rpc)throws Exception {
        JSONObject s=required(store),p=identity(s);String genesis=rpc.cluster();rpc.program();
        String name=s.optString("name");
        if(name.isEmpty()){
            Object value=((JSONObject)rpc.call("getAccountInfo",new JSONArray().put(p.getString("identity")).put(finalized().put("encoding","base64")))).get("value");
            if(value!=JSONObject.NULL){
                JSONObject a=(JSONObject)value;
                if(!p.getString("program").equals(a.getString("owner")))throw new IOException("wrong_program_owner");
                byte[] bytes=java.util.Base64.getDecoder().decode(data(a));
                if(bytes.length!=128||!"PNDID001".equals(new String(bytes,0,8,java.nio.charset.StandardCharsets.US_ASCII))||bytes[8]!=1)throw new IOException("invalid_record");
                int length=bytes[74]&255;if(length<3||length>24)throw new IOException("invalid_record");
                name=new String(bytes,75,length,java.nio.charset.StandardCharsets.US_ASCII);
            }
        }
        if(!name.isEmpty()&&readback(rpc,s,p.getString("owner"),name,genesis)){store.save(s);return "Ник @"+name+" подтверждён в Devnet.\nАдрес: "+p.getString("owner");}
        boolean ended=expired(rpc,s.getJSONArray("attempts"));
        long balance=integer(((JSONObject)rpc.call("getBalance",new JSONArray().put(p.getString("owner")).put(finalized()))).get("value"));
        return "Devnet · адрес: "+p.getString("owner")+"\nБаланс: "+java.math.BigDecimal.valueOf(balance,9).toPlainString()+" тестовых SOL.\n"+(ended?"Ник ещё не подтверждён. Можно повторить регистрацию.":"Транзакция ещё ожидается. Повтор регистрации отправит те же байты.");
    }
    static String register(Store store,Chain rpc,String name)throws Exception {
        JSONObject s=required(store);if(!s.optBoolean("backup"))throw new IOException("backup_confirmation_required");
        String genesis=rpc.cluster();rpc.program();JSONObject p=identity(s);String owner=p.getString("owner");
        if(!s.optString("name").isEmpty()&&!name.equals(s.getString("name"))){
            if(!expired(rpc,s.getJSONArray("attempts")))throw new IOException("different_name_pending");
            Object id=((JSONObject)rpc.call("getAccountInfo",new JSONArray().put(p.getString("identity")).put(finalized().put("encoding","base64")))).get("value");
            if(id!=JSONObject.NULL)throw new IOException("identity_already_registered");
            // Explicit new choice after every old attempt is expired and identity absent.
            s.put("attempts",new JSONArray()).remove("name");s.put("verified",false);
        }
        if(readback(rpc,s,owner,name,genesis)){store.save(s);return "Ник @"+name+" подтверждён в Devnet.";}
        JSONArray attempts=s.getJSONArray("attempts");
        if(!expired(rpc,attempts))return broadcast(store,rpc,s,attempts.getJSONObject(attempts.length()-1));
        // Expiry must be finalized; re-read after the height check before pruning.
        if(readback(rpc,s,owner,name,genesis)){store.save(s);return "Ник @"+name+" подтверждён в Devnet.";}
        JSONObject block=((JSONObject)rpc.call("getLatestBlockhash",new JSONArray().put(finalized()))).getJSONObject("value");
        String blockhash=block.getString("blockhash");
        JSONObject prepared=SolanaBridge.run(new JSONObject().put("op","prepare").put("owner",owner).put("name",name).put("blockhash",blockhash).put("genesis",genesis));
        long rent=integer(rpc.call("getMinimumBalanceForRentExemption",new JSONArray().put(128).put(finalized())));
        long fee=integer(((JSONObject)rpc.call("getFeeForMessage",new JSONArray().put(prepared.getString("message")).put(finalized()))).get("value"));
        if(rent>5000000||fee>100000)throw new IOException("cost_limit");
        long balance=integer(((JSONObject)rpc.call("getBalance",new JSONArray().put(owner).put(finalized()))).get("value"));
        if(balance<rent*2+fee)throw new IOException("insufficient_devnet_sol");
        JSONObject tx=SolanaBridge.run(new JSONObject().put("op","register").put("entropy",s.getString("entropy")).put("name",name).put("blockhash",blockhash).put("genesis",genesis));
        if(!prepared.getString("message").equals(tx.getString("message")))throw new IOException("prepared_message_mismatch");
        JSONObject attempt=new JSONObject().put("signature",tx.getString("signature")).put("transaction",tx.getString("transaction")).put("last_valid_height",integer(block.get("lastValidBlockHeight"))).put("broadcasts",0);
        // Only finalized-expired attempts disappear; never lose outstanding signatures.
        s.put("attempts",new JSONArray().put(attempt)).put("name",name);
        return broadcast(store,rpc,s,attempt);
    }
}
