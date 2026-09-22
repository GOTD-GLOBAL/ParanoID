package org.paranoid.devnet;
import org.json.JSONObject;
public final class BridgeSmoke {
    public static void main(String[] args)throws Exception {
        String entropy="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; // public test vector only
        JSONObject identity=SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",entropy));
        if(!identity.getString("owner").equals("3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"))throw new AssertionError("derivation");
        if(identity.has("mnemonic")||identity.has("entropy"))throw new AssertionError("secret in public identity response");
        JSONObject backup=SolanaBridge.run(new JSONObject().put("op","export_mnemonic").put("entropy",entropy));
        JSONObject restored=SolanaBridge.run(new JSONObject().put("op","recover").put("mnemonic",backup.getString("mnemonic")));
        if(!entropy.equals(restored.getString("entropy")))throw new AssertionError("restore");
        JSONObject tx=SolanaBridge.run(new JSONObject().put("op","register").put("entropy",entropy).put("name","alice_test").put("blockhash","11111111111111111111111111111111").put("genesis",DevnetRpc.GENESIS));
        if(tx.getString("signature").isEmpty()||!tx.getString("owner").equals(identity.getString("owner")))throw new AssertionError("transaction");
        try{SolanaBridge.run(new JSONObject().put("op","register").put("entropy",entropy).put("name","alice_test").put("blockhash","11111111111111111111111111111111").put("genesis","mainnet"));throw new AssertionError("cluster gate");}catch(Exception expected){if(!expected.getMessage().equals("wrong_cluster"))throw expected;}
        System.out.println("JNI PASS: real Rust derivation, recovery, transaction creation and wrong-cluster refusal; no network or funded keys");
    }
}
