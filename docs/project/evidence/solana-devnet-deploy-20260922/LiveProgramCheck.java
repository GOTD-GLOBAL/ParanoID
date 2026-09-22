package org.paranoid.devnet;
import org.json.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
/** Read-only live probe using the unchanged reviewed JNI and client gate. */
public final class LiveProgramCheck {
    public static void main(String[] args) throws Exception {
        JSONObject pins=SolanaBridge.run(new JSONObject().put("op","program_info"));
        DevnetRpc rpc=new DevnetRpc();
        String genesis=rpc.cluster();
        rpc.program();
        JSONObject response=(JSONObject)rpc.call("getMultipleAccounts",new JSONArray().put(new JSONArray().put(pins.getString("program")).put(pins.getString("programdata"))).put(DevnetRpc.finalized().put("encoding","base64")));
        JSONArray accounts=response.getJSONArray("value");
        ProgramPin.verify(pins,accounts.getJSONObject(0),accounts.getJSONObject(1));
        JSONObject receipt=new JSONObject().put("result","PASS").put("genesis",genesis).put("slot",response.getJSONObject("context").getLong("slot")).put("pins",pins);
        for(int i=0;i<2;i++){
            JSONObject a=accounts.getJSONObject(i);byte[] bytes=Base64.getDecoder().decode(a.getJSONArray("data").getString(0));
            receipt.put(i==0?"program_account":"programdata_account",new JSONObject().put("bytes",bytes.length).put("owner",a.getString("owner")).put("lamports",a.getLong("lamports")).put("executable",a.getBoolean("executable")));
        }
        Files.write(Paths.get(args[0]),receipt.toString(2).getBytes(StandardCharsets.UTF_8));
        System.out.println(receipt.toString(2));
    }
}
