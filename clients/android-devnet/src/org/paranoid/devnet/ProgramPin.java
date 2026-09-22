package org.paranoid.devnet;

import java.io.IOException;
import java.util.Arrays;
import java.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;

/** Exact upgradeable-loader-v3 account gate. RPC remains a trusted data source. */
final class ProgramPin {
    private static byte[] data(JSONObject account) throws Exception {
        JSONArray encoded=account.getJSONArray("data");
        if(encoded.length()!=2||!"base64".equals(encoded.getString(1)))throw new IOException("program_encoding");
        String text=encoded.getString(0);
        if(text.length()>200000)throw new IOException("program_size");
        byte[] bytes=Base64.getDecoder().decode(text);
        if(!Base64.getEncoder().encodeToString(bytes).equals(text))throw new IOException("program_encoding");
        return bytes;
    }
    static void verify(JSONObject pins, JSONObject program, JSONObject programdata) throws Exception {
        if(program==null||programdata==null)throw new IOException("program_not_deployed");
        String loader=pins.getString("loader");
        if(!program.getBoolean("executable")||!loader.equals(program.getString("owner"))
            ||programdata.getBoolean("executable")||!loader.equals(programdata.getString("owner")))throw new IOException("unexpected_program");
        byte[] p=data(program),d=data(programdata);
        if(p.length!=36||p[0]!=2||p[1]!=0||p[2]!=0||p[3]!=0
            ||!Arrays.equals(Arrays.copyOfRange(p,4,36),Base64.getDecoder().decode(pins.getString("programdata_bytes"))))throw new IOException("program_link");
        if(d.length!=45+pins.getInt("sbf_size")||d[0]!=3||d[1]!=0||d[2]!=0||d[3]!=0||d[12]!=1
            ||!Arrays.equals(Arrays.copyOfRange(d,13,45),Base64.getDecoder().decode(pins.getString("authority_bytes"))))throw new IOException("program_authority");
        java.security.MessageDigest sha=java.security.MessageDigest.getInstance("SHA-256");
        sha.update(d,45,d.length-45);
        StringBuilder hex=new StringBuilder();
        for(byte b:sha.digest())hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        if(!hex.toString().equals(pins.getString("sbf_sha256")))throw new IOException("program_bytecode");
    }
}
