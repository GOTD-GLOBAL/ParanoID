package org.paranoid.devnet;
import org.json.*;
import javax.net.ssl.HttpsURLConnection;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Fixed Devnet endpoint with platform PKI, no redirects/proxies/arbitrary URL. */
final class DevnetRpc implements RegistrationFlow.Chain {
    private static final JSONObject PINS=loadPins();
    static final String URL=PINS.optString("rpc");
    static final String GENESIS=PINS.optString("genesis");
    static final String PROGRAM=PINS.optString("program");
    private static JSONObject loadPins() {
        try { return SolanaBridge.run(new JSONObject().put("op","program_info")); }
        catch(Exception e) { throw new ExceptionInInitializerError(e); }
    }
    private long requestId;
    public Object call(String method,JSONArray params)throws Exception {
        if(!java.util.Arrays.asList("getGenesisHash","getAccountInfo","getMultipleAccounts","getBalance","getLatestBlockhash","getBlockHeight","getSignatureStatuses","getFeeForMessage","getMinimumBalanceForRentExemption","sendTransaction","requestAirdrop").contains(method))throw new IOException("rpc_method");
        if(CookieHandler.getDefault()!=null)throw new IOException("ambient_cookies");
        long id=++requestId;
        byte[] body=new JSONObject().put("jsonrpc","2.0").put("id",id).put("method",method).put("params",params).toString().getBytes(StandardCharsets.UTF_8);
        if(body.length>8192)throw new IOException("rpc_request_limit");
        HttpsURLConnection c=(HttpsURLConnection)new java.net.URL(URL).openConnection(Proxy.NO_PROXY);
        c.setConnectTimeout(8000);c.setReadTimeout(15000);c.setInstanceFollowRedirects(false);c.setUseCaches(false);
        c.setRequestMethod("POST");c.setRequestProperty("Content-Type","application/json");c.setDoOutput(true);c.setFixedLengthStreamingMode(body.length);
        try {
            try(OutputStream out=c.getOutputStream()){out.write(body);}
            int status=c.getResponseCode();if(status==429)throw new IOException("rpc_rate_limit");if(status!=200)throw new IOException("rpc_unavailable");
            byte[] reply;
            try(InputStream in=c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream()) {
                byte[] chunk=new byte[8192];int n;
                while((n=in.read(chunk))!=-1){if(out.size()+n>1_048_576)throw new IOException("rpc_response_limit");out.write(chunk,0,n);}reply=out.toByteArray();
            }
            JSONObject result=new JSONObject(new String(reply,StandardCharsets.UTF_8));
            if(result.getLong("id")!=id||!"2.0".equals(result.getString("jsonrpc")))throw new IOException("rpc_response_id");
            if(result.has("error"))throw new IOException("rpc_error");
            return result.get("result");
        }finally{c.disconnect();}
    }
    public String cluster()throws Exception {String value=(String)call("getGenesisHash",new JSONArray());if(!GENESIS.equals(value))throw new IOException("wrong_cluster");return value;}
    static JSONObject finalized()throws Exception{return new JSONObject().put("commitment","finalized");}
    JSONObject account(String address)throws Exception {
        Object v=((JSONObject)call("getAccountInfo",new JSONArray().put(address).put(finalized().put("encoding","base64")))).get("value");
        return v==JSONObject.NULL?null:(JSONObject)v;
    }
    public void program()throws Exception {
        cluster();
        // One finalized bank context for Program and its canonical ProgramData PDA.
        JSONArray addresses=new JSONArray().put(PROGRAM).put(PINS.getString("programdata"));
        JSONObject response=(JSONObject)call("getMultipleAccounts",new JSONArray().put(addresses).put(finalized().put("encoding","base64")));
        JSONArray accounts=response.getJSONArray("value");
        if(accounts.length()!=2||accounts.isNull(0)||accounts.isNull(1))throw new IOException("program_not_deployed");
        ProgramPin.verify(PINS,accounts.getJSONObject(0),accounts.getJSONObject(1));
    }
}
